import Foundation
import AppKit
import Combine

/// crop 配置重链/去腐纯函数集（无 actor 隔离，可独立单测）。
enum DisplayCropStateReconciler {

    /// 当前屏身份快照（不依赖真实 NSScreen，便于单测）。
    struct ScreenIdentitySnapshot: Equatable {
        let screenID: String
        let fingerprint: String
    }

    /// 去掉无序列号显示器指纹中的 `:position:` 后缀，得到位置无关的稳定部分。
    /// 有硬件序列号的指纹不含该后缀，原样返回。
    static func stableFingerprintPart(_ fp: String) -> String {
        guard let range = fp.range(of: ":position:") else { return fp }
        return String(fp[..<range.lowerBound])
    }

    /// 指纹匹配：精确相等，或仅桌面位置变化（稳定部分一致）。
    static func isFingerprintMatch(_ recorded: String, _ actual: String) -> Bool {
        recorded == actual || stableFingerprintPart(recorded) == stableFingerprintPart(actual)
    }

    /// 用当前在线屏对持久化条目做重链 + 去腐（纯函数，返回 nil 表示无需变化）。
    ///
    /// Pass 1（fingerprint 认领）：条目跟着它记录的物理显示器指纹走，而不是跟着
    ///   screenID 走——修复重启后双屏 displayID 互换导致的 A/B 设置串台。
    ///   第一轮精确匹配，第二轮忽略 position（显示器仅桌面位置变化的场景）。
    /// Pass 2（同 ID 兜底）：同 screenID 条目若记录的指纹与当前屏不匹配
    ///   （displayID 被新屏回收复用），丢弃旧条目回退默认；没记录过指纹的历史
    ///   条目（旧版 update(forScreenID:) 路径）信任并补记指纹。
    /// 未被认领的孤儿条目原样保留（显示器暂时断开不丢配置，重插后仍可按指纹重链）。
    static func reconciledCropState(
        settingsByScreen: [String: DisplayCropSettings],
        fingerprints: [String: String],
        currentScreens: [ScreenIdentitySnapshot]
    ) -> (settings: [String: DisplayCropSettings], fingerprints: [String: String])? {
        guard !currentScreens.isEmpty else { return nil }
        let currentIDs = Set(currentScreens.map(\.screenID))

        var newSettings: [String: DisplayCropSettings] = [:]
        var newFingerprints: [String: String] = [:]
        var consumed = Set<String>()

        for pass in 0..<2 {
            for screen in currentScreens {
                guard newSettings[screen.screenID] == nil else { continue }
                guard let entryID = fingerprints.first(where: { entryID, recordedFp in
                    !consumed.contains(entryID)
                        && (pass == 0
                            ? recordedFp == screen.fingerprint
                            : isFingerprintMatch(recordedFp, screen.fingerprint))
                })?.key,
                   let s = settingsByScreen[entryID] else { continue }
                newSettings[screen.screenID] = s
                newFingerprints[screen.screenID] = screen.fingerprint
                consumed.insert(entryID)
            }
        }

        for screen in currentScreens {
            let id = screen.screenID
            guard newSettings[id] == nil, let s = settingsByScreen[id] else { continue }
            if let recorded = fingerprints[id] {
                // 记录的指纹与当前同 ID 屏不匹配 → displayID 被回收/复用，丢弃旧条目。
                guard isFingerprintMatch(recorded, screen.fingerprint) else { continue }
            }
            // 补记/更新指纹（含仅 position 变化的场景）。
            newSettings[id] = s
            newFingerprints[id] = screen.fingerprint
            consumed.insert(id)
        }

        for (id, s) in settingsByScreen where !consumed.contains(id) && !currentIDs.contains(id) {
            newSettings[id] = s
            if let fp = fingerprints[id] { newFingerprints[id] = fp }
        }

        guard newSettings != settingsByScreen || newFingerprints != fingerprints else { return nil }
        return (newSettings, newFingerprints)
    }
}

/// 每屏可视区域配置存储。独立于现有 5+ manager，screenID 键 + fingerprint 重链。
/// App 端持久化到 UserDefaults；扩展端通过 App Group JSON 共享。
@MainActor
final class DisplayCropSettingsStore: ObservableObject {

    static let shared = DisplayCropSettingsStore()

    /// crop 配置变更通知（渲染器监听以实时刷新）。userInfo["screenID"] = String。
    static let cropDidChangeNotification = Notification.Name("DisplayCropSettingsDidChange")

    @Published private(set) var settingsByScreen: [String: DisplayCropSettings] = [:]
    private var settingsByFingerprint: [String: DisplayCropSettings] = [:]
    private var fingerprints: [String: String] = [:]   // screenID → fingerprint

    private let defaults: UserDefaults
    private let stateKey = "display_crop_settings_v2"
    private let fingerprintKey = "display_crop_fingerprints_v1"

    /// 共享给扩展端的 App Group identifier（与 LockScreenWallpaperService 一致）。
    private let appGroupID = "group.com.waifux.app"
    /// 共享给扩展端的 App Group JSON 文件名。
    private let sharedJSONName = "waifux-crop-prefs.json"

    // MARK: - Init

    init(testDefaults: UserDefaults? = nil) {
        self.defaults = testDefaults ?? UserDefaults.standard
        load()
        // 启动时做一次重链 + 去腐：修复重启后 displayID 互换导致的设置串台。
        reconcileWithCurrentScreens()
        observeScreenChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Read

    func settings(forScreenID screenID: String) -> DisplayCropSettings {
        // displayID 回收/串台守卫：条目记录的指纹与当前同 ID 屏不匹配 → 视为陈旧，回退默认。
        // （CGDirectDisplayID 在重启/重插后会被重新分配甚至复用，历史条目可能挂在新屏的 ID 上。）
        if let recorded = fingerprints[screenID],
           let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }),
           !DisplayCropStateReconciler.isFingerprintMatch(recorded, screen.wallpaperScreenFingerprint) {
            return .defaultSettings
        }
        return settingsByScreen[screenID] ?? .defaultSettings
    }

    func settings(for screen: NSScreen) -> DisplayCropSettings {
        settings(forScreenID: screen.wallpaperScreenIdentifier)
    }

    // MARK: - Write

    /// 更新指定屏配置。
    /// - interactive: true=拖拽/滚轮等高频中间态，只触发**本地即时刷新通知**，不写 UserDefaults
    ///   持久化、不广播 Darwin、不重启 wgpu 进程；只写 App Group JSON 和 crop-control JSON 让
    ///   渲染端能在下一次帧/轮询中拾取。
    ///   false（默认）= 落定/菜单操作，完整持久化 + Darwin 广播 + wgpu 进程重启。
    func update(forScreenID screenID: String, interactive: Bool = false, _ mutate: (inout DisplayCropSettings) -> Void) {
        var s = settings(forScreenID: screenID)
        mutate(&s)
        settingsByScreen[screenID] = s
        if !interactive { persist() }
        notifyChange(screenID: screenID, interactive: interactive)
    }

    func update(for screen: NSScreen, interactive: Bool = false, _ mutate: (inout DisplayCropSettings) -> Void) {
        let screenID = screen.wallpaperScreenIdentifier
        update(forScreenID: screenID, interactive: interactive, mutate)
        // 同步 fingerprint 映射（落定态才持久化）
        let fp = screen.wallpaperScreenFingerprint
        if !fp.isEmpty {
            fingerprints[screenID] = fp
            settingsByFingerprint[fp] = settingsByScreen[screenID]
            if !interactive { persistFingerprints() }
        }
    }

    func reset(forScreenID screenID: String) {
        settingsByScreen[screenID] = .defaultSettings
        persist()
        notifyChange(screenID: screenID, interactive: false)
    }

    func reset(for screen: NSScreen) {
        reset(forScreenID: screen.wallpaperScreenIdentifier)
    }

    func clear(forScreenID screenID: String) {
        settingsByScreen.removeValue(forKey: screenID)
        if let fp = fingerprints[screenID] {
            settingsByFingerprint.removeValue(forKey: fp)
        }
        fingerprints.removeValue(forKey: screenID)
        persist()
        persistFingerprints()
        notifyChange(screenID: screenID, interactive: false)
    }

    /// 拖拽结束时手动调用一次"落定"：把当前内存状态持久化 + 广播一次 Darwin + 通知 wgpu 重启。
    /// overlay 在 mouseUp / ESC 退出时调用。
    func commitInteractive(for screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        persist()
        let fp = screen.wallpaperScreenFingerprint
        if !fp.isEmpty {
            fingerprints[screenID] = fp
            settingsByFingerprint[fp] = settingsByScreen[screenID]
            persistFingerprints()
        }
        notifyChange(screenID: screenID, interactive: false)
    }

    // MARK: - Persistence (App 端)

    private func load() {
        // v1 → v2 迁移：pan 从 [-1,1]/0=居中 改为 [0,1]/0.5=居中，公式 newPan = oldPan/2 + 0.5。
        let legacyKey = "display_crop_settings_v1"
        if let legacyData = defaults.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode([String: DisplayCropSettings].self, from: legacyData) {
            var migrated: [String: DisplayCropSettings] = [:]
            for (k, var s) in decoded {
                // 仅迁移旧语义的 pan（[-1,1] → [0,1]）；zoom/isEnabled 等不变。
                s.pan = CGPoint(x: s.pan.x / 2 + 0.5, y: s.pan.y / 2 + 0.5)
                migrated[k] = s
            }
            settingsByScreen = migrated
            defaults.removeObject(forKey: legacyKey)
            persist()
        }
        if let data = defaults.data(forKey: stateKey),
           let decoded = try? JSONDecoder().decode([String: DisplayCropSettings].self, from: data) {
            settingsByScreen = decoded
        }
        if let fpData = defaults.data(forKey: fingerprintKey),
           let fp = try? JSONDecoder().decode([String: String].self, from: fpData) {
            fingerprints = fp
            for (screenID, f) in fp {
                if let s = settingsByScreen[screenID] {
                    settingsByFingerprint[f] = s
                }
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settingsByScreen) {
            defaults.set(data, forKey: stateKey)
        }
    }

    private func persistFingerprints() {
        if let data = try? JSONEncoder().encode(fingerprints) {
            defaults.set(data, forKey: fingerprintKey)
        }
    }

    // MARK: - Fingerprint 重链 + 去腐

    /// 对当前在线屏执行一次重链 + 去腐，有变化时持久化并刷新共享 JSON。
    /// App 启动与 didChangeScreenParametersNotification 时调用。
    @discardableResult
    private func reconcileWithCurrentScreens() -> Bool {
        let snapshots = NSScreen.screens.map {
            DisplayCropStateReconciler.ScreenIdentitySnapshot(
                screenID: $0.wallpaperScreenIdentifier,
                fingerprint: $0.wallpaperScreenFingerprint)
        }
        guard let next = DisplayCropStateReconciler.reconciledCropState(
            settingsByScreen: settingsByScreen,
            fingerprints: fingerprints,
            currentScreens: snapshots) else { return false }
        settingsByScreen = next.settings
        fingerprints = next.fingerprints
        settingsByFingerprint = [:]
        for (id, fp) in fingerprints {
            if let s = settingsByScreen[id] { settingsByFingerprint[fp] = s }
        }
        persist()
        persistFingerprints()
        writeSharedCropPrefs()
        return true
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func handleScreenParametersChanged() {
        // 热插拔 / 重排 / 分辨率协商后重链：设置按物理显示器指纹跟随，displayID 复用条目去腐。
        if reconcileWithCurrentScreens() {
            NotificationCenter.default.post(
                name: Self.cropDidChangeNotification, object: nil,
                userInfo: ["screenID": "*", "interactive": false])
        }
    }

    // MARK: - 扩展端共享（App Group JSON）

    /// 把当前 settingsByScreen 按 displayID 写入 App Group JSON。
    /// screenID 本身就是 CGDirectDisplayID 的字符串形式（见 NSScreen.wallpaperScreenIdentifier），
    /// 可直接解析为 UInt32；解析失败的（fallback 格式 "name:x:y"）跳过——
    /// 这些 fallback 屏的扩展端走不到，丢失无影响。
    func writeSharedCropPrefs() {
        guard let containerURL = sharedContainerURL() else { return }
        var dict: [String: DisplayCropSettings] = [:]
        for (screenID, s) in settingsByScreen {
            guard let displayID = UInt32(screenID) else { continue }
            dict["display-\(displayID)"] = s
        }
        let url = containerURL.appendingPathComponent(sharedJSONName)
        do {
            let data = try JSONEncoder().encode(dict)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[CropStore] 写共享 JSON 失败: \(error)")
        }
    }

    /// 扩展端读取：[displayID: settings]。nonisolated：仅读 JSON 文件，无 actor 状态。
    nonisolated static func readSharedCropPrefs() -> [UInt32: DisplayCropSettings] {
        guard let containerURL = sharedContainerURL() else { return [:] }
        let url = containerURL.appendingPathComponent("waifux-crop-prefs.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: DisplayCropSettings].self, from: data) else {
            return [:]
        }
        var result: [UInt32: DisplayCropSettings] = [:]
        for (key, s) in dict where key.hasPrefix("display-") {
            if let id = UInt32(key.dropFirst("display-".count)) {
                result[id] = s
            }
        }
        return result
    }

    /// 扩展端按 displayID 读取单屏配置。
    /// nonisolated：仅读 App Group JSON 文件，不触碰 @MainActor 实例状态，可在后台队列调用。
    nonisolated static func sharedSettings(forDisplayID displayID: UInt32) -> DisplayCropSettings {
        readSharedCropPrefs()[displayID] ?? .defaultSettings
    }

    private nonisolated static func sharedContainerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.waifux.app")
    }

    private func sharedContainerURL() -> URL? {
        Self.sharedContainerURL()
    }

    // 测试用：不写文件，直接返回 [displayID: settings]（取任一屏）。
    func writeSharedCropPrefsForTesting(displayID: UInt32 = 42) -> [UInt32: DisplayCropSettings] {
        var result: [UInt32: DisplayCropSettings] = [:]
        for (_, s) in settingsByScreen {
            result[displayID] = s
            break
        }
        return result
    }

    // MARK: - Notify

    /// 通用通知。
    /// interactive=true（拖拽中）：
    ///   - 写 App Group JSON（扩展端下次 acquire 才会读，但**不广播 Darwin**，不重 acquire）
    ///   - 播 cropDidChangeNotification（原生视频 layer 即时刷新，本进程内零成本）
    /// interactive=false（落定）：
    ///   - 上述全部 + 广播 Darwin 通知（扩展端 re-acquire 一次）
    ///   - Bridge 在收到 notification + interactive=false 时才重启 wgpu 进程
    private func notifyChange(screenID: String, interactive: Bool) {
        writeSharedCropPrefs()

        if !interactive {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(
                center,
                CFNotificationName("com.waifux.app.wallpaper.prefsChanged" as CFString),
                nil, nil, true
            )
        }

        NotificationCenter.default.post(
            name: Self.cropDidChangeNotification,
            object: nil,
            userInfo: ["screenID": screenID, "interactive": interactive])
    }
}
