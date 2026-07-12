import Foundation
import AppKit
import Combine

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
        observeScreenChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Read

    func settings(forScreenID screenID: String) -> DisplayCropSettings {
        settingsByScreen[screenID] ?? .defaultSettings
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
        var updatedSettings = settings(for: screen)
        mutate(&updatedSettings)
        let targetScreens = synchronizedTargetScreens(for: screen)
        for targetScreen in targetScreens {
            let screenID = targetScreen.wallpaperScreenIdentifier
            settingsByScreen[screenID] = updatedSettings
            let fingerprint = targetScreen.wallpaperScreenFingerprint
            if !fingerprint.isEmpty {
                fingerprints[screenID] = fingerprint
                settingsByFingerprint[fingerprint] = updatedSettings
            }
        }
        if !interactive {
            persist()
            persistFingerprints()
        }
        for targetScreen in targetScreens {
            notifyChange(screenID: targetScreen.wallpaperScreenIdentifier, interactive: interactive)
        }
    }

    func reset(forScreenID screenID: String) {
        settingsByScreen[screenID] = .defaultSettings
        persist()
        notifyChange(screenID: screenID, interactive: false)
    }

    func reset(for screen: NSScreen) {
        let targetScreens = synchronizedTargetScreens(for: screen)
        for targetScreen in targetScreens {
            settingsByScreen[targetScreen.wallpaperScreenIdentifier] = .defaultSettings
            let fingerprint = targetScreen.wallpaperScreenFingerprint
            if !fingerprint.isEmpty {
                fingerprints[targetScreen.wallpaperScreenIdentifier] = fingerprint
                settingsByFingerprint[fingerprint] = .defaultSettings
            }
        }
        persist()
        persistFingerprints()
        for targetScreen in targetScreens {
            notifyChange(screenID: targetScreen.wallpaperScreenIdentifier, interactive: false)
        }
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
        let targetScreens = synchronizedTargetScreens(for: screen)
        persist()
        for targetScreen in targetScreens {
            let screenID = targetScreen.wallpaperScreenIdentifier
            let fingerprint = targetScreen.wallpaperScreenFingerprint
            if !fingerprint.isEmpty, let settings = settingsByScreen[screenID] {
                fingerprints[screenID] = fingerprint
                settingsByFingerprint[fingerprint] = settings
            }
        }
        persistFingerprints()
        for targetScreen in targetScreens {
            notifyChange(screenID: targetScreen.wallpaperScreenIdentifier, interactive: false)
        }
    }

    private func synchronizedTargetScreens(for screen: NSScreen) -> [NSScreen] {
        guard WallpaperSchedulerService.shared.config.syncAllDisplays else { return [screen] }
        let screens = NSScreen.screens
        return screens.isEmpty ? [screen] : screens
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

    // MARK: - Fingerprint 重链

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func handleScreenParametersChanged() {
        let currentScreens = NSScreen.screens
        let currentScreenIDs = Set(currentScreens.map { $0.wallpaperScreenIdentifier })
        var fpToScreenID: [String: String] = [:]
        for screen in currentScreens {
            fpToScreenID[screen.wallpaperScreenFingerprint] = screen.wallpaperScreenIdentifier
        }
        let orphanedIDs = Set(settingsByScreen.keys).subtracting(currentScreenIDs)
        var migrated = 0
        for orphanedID in orphanedIDs {
            guard let fp = fingerprints[orphanedID],
                  let newID = fpToScreenID[fp],
                  !settingsByScreen.keys.contains(newID),
                  let s = settingsByScreen[orphanedID] else { continue }
            settingsByScreen[newID] = s
            fingerprints[newID] = fp
            settingsByFingerprint[fp] = s
            settingsByScreen.removeValue(forKey: orphanedID)
            fingerprints.removeValue(forKey: orphanedID)
            migrated += 1
        }
        if migrated > 0 {
            persist()
            persistFingerprints()
            writeSharedCropPrefs()
            NotificationCenter.default.post(name: Self.cropDidChangeNotification, object: nil)
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
