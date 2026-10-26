import AppKit
import CoreGraphics

struct WallpaperPosterPixelSize: Hashable, Sendable {
    let width: Int
    let height: Int
}

enum WallpaperPosterGeometry {
    static func evenPixelSize(
        widthPoints: CGFloat,
        heightPoints: CGFloat,
        scale: CGFloat
    ) -> WallpaperPosterPixelSize {
        let rawWidth = max(64, Int((widthPoints * scale).rounded()))
        let rawHeight = max(64, Int((heightPoints * scale).rounded()))
        return WallpaperPosterPixelSize(
            width: max(64, (rawWidth / 2) * 2),
            height: max(64, (rawHeight / 2) * 2)
        )
    }
}

enum WallpaperScreenIdentity {
    /// Resolution/scale and the main-screen origin can change during wake.
    /// Keep this normalization scheduler-specific; rendering has separate ownership rules.
    static func schedulerHardwareKey(_ fingerprint: String) -> String {
        nameTolerantPart(stableFingerprintPart(fingerprint)).replacingOccurrences(
            of: #":\d+x\d+(?=:|$)"#, with: "", options: .regularExpression
        )
    }

    /// 剥掉无序列号指纹里内嵌的本地化屏幕名段。
    ///
    /// `cg:<vendor>:<model>:noserial:<localizedName>:<其余字段>` 的 `<localizedName>`
    /// 跟随**读取进程**的本地化解析：主 App（CFBundleDevelopmentRegion=zh，带 lproj）
    /// 对内建屏读出「内建视网膜显示器」，Helper 子包（=en、无 lproj）对同一块屏
    /// 读出「Built-in Retina Display」（2026-10-26 x86 用户日志实锤，调度器恢复
    /// 日志里同屏两名）。指纹掺名后，跨进程命令解析与调度器重链都会把同一块
    /// 屏误判成「已变化」。vendor/model 已锁定硬件，同型号无序列号多屏本来就靠
    /// position 后缀与组内相对次序区分，屏幕名不提供判别力。
    /// 只用于比较层；生成侧保留原名段，持久化键形态不变，旧记录无需迁移。
    static func nameTolerantPart(_ fingerprint: String) -> String {
        let fields = fingerprint.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count > 5, fields[0] == "cg", fields[3] == "noserial" else {
            return fingerprint
        }
        var normalized = Array(fields[0...3])
        normalized.append(contentsOf: fields[5...])
        return normalized.joined(separator: ":")
    }

    /// Resolve the WHOLE saved topology, including IDs still present but reused.
    /// Never claim a target merely because its numeric ID survived a reboot.
    static func schedulerBindings(
        fingerprints: [String: String],
        screens: [(id: String, fingerprint: String)],
        allowRelativeRank: Bool
    ) -> [String: String] {
        guard Set(screens.map(\.id)).count == screens.count else { return [:] }
        let savedGroups = Dictionary(grouping: fingerprints.keys) {
            schedulerHardwareKey(fingerprints[$0]!)
        }
        let liveGroups = Dictionary(grouping: screens) { schedulerHardwareKey($0.fingerprint) }
        var result: [String: String] = [:]
        for (hardware, saved) in savedGroups {
            let live = liveGroups[hardware] ?? []
            guard saved.count == live.count, !live.isEmpty else { continue }
            if saved.count == 1 {
                result[saved[0]] = live[0].id
                continue
            }
            guard allowRelativeRank else { continue }
            let oldPositions = saved.compactMap { position(fromFingerprint: fingerprints[$0]!) }
            let newPositions = live.compactMap { position(fromFingerprint: $0.fingerprint) }
            // Legacy identical screens without positions, or mirrored positions,
            // have no recoverable ordering. Do not invent one from numeric IDs.
            guard oldPositions.count == saved.count, newPositions.count == live.count,
                  Set(oldPositions.map { "\($0.x),\($0.y)" }).count == saved.count,
                  Set(newPositions.map { "\($0.x),\($0.y)" }).count == live.count else { continue }
            result.merge(pairByRelativeRank(
                orphans: saved.map { (id: $0, position: position(fromFingerprint: fingerprints[$0]!)) },
                screens: live.map { (id: $0.id, position: position(fromFingerprint: $0.fingerprint)!) }
            )) { first, _ in first }
        }
        return result
    }

    /// Include unresolved records in the transaction. Park disconnected owners
    /// whose ID has been reused, so a returning/new monitor cannot overwrite them.
    static func schedulerRelocations(
        keys: Set<String>, bindings: [String: String], liveIDs: Set<String>
    ) -> [String: String] {
        var result = bindings.filter { keys.contains($0.key) }
        var occupied = keys.union(liveIDs).union(result.values)
        for key in keys.sorted() where result[key] == nil {
            if !liveIDs.contains(key), !result.values.contains(key) {
                result[key] = key
                continue
            }
            var parked = "disconnected:\(key)"
            while occupied.contains(parked) { parked = "disconnected:\(parked)" }
            occupied.insert(parked)
            result[key] = parked
        }
        return result
    }

    /// Read exclusively from the pre-migration snapshot, preserving swaps/cycles.
    static func relocatingSchedulerValues<Value>(
        _ values: [String: Value], using relocations: [String: String]
    ) -> [String: Value] {
        Dictionary(uniqueKeysWithValues: values.map { (relocations[$0.key] ?? $0.key, $0.value) })
    }

    /// Shared command resolver; topology can be supplied by regression tests.
    static func commandTargetIndex(
        identifier: String?, fingerprint: String,
        screens: [(id: String, fingerprint: String)]
    ) -> Int? {
        let direct = screens.indices.filter { screens[$0].id == identifier }
        guard direct.count <= 1 else { return nil }
        // A current ID + name-tolerant (position/resolution still strict)
        // fingerprint is authoritative. The App and Helper bundles may read
        // different localized names for the same no-serial display within one
        // boot session, so the direct path must not demand name equality.
        if let index = direct.first,
           nameTolerantPart(screens[index].fingerprint) == nameTolerantPart(fingerprint) { return index }
        let matches = screens.indices.filter { fingerprintsMatch(screens[$0].fingerprint, fingerprint) }
        return matches.count == 1 ? matches[0] : nil
    }

    static func fingerprint(legacyFingerprint: String, hasHardwareSerial: Bool, position: CGPoint) -> String {
        guard !hasHardwareSerial else { return legacyFingerprint }
        return "\(legacyFingerprint):position:\(Int(position.x.rounded()))x\(Int(position.y.rounded()))"
    }

    /// Removes the desktop-position suffix used for displays without a
    /// hardware serial number. The position is useful for distinguishing two
    /// identical displays while they are online, but it can change after a
    /// reconnect or a desktop rearrangement.
    static func stableFingerprintPart(_ fingerprint: String) -> String {
        guard let range = fingerprint.range(of: ":position:") else {
            return fingerprint
        }
        return String(fingerprint[..<range.lowerBound])
    }

    /// 解析指纹中的 `:position:XxY` 后缀（无序列号显示器的桌面排列位置）。
    /// 有序列号指纹与旧版短指纹没有 position 后缀，返回 nil。
    static func position(fromFingerprint fingerprint: String) -> CGPoint? {
        guard let range = fingerprint.range(of: ":position:") else {
            return nil
        }
        let parts = fingerprint[range.upperBound...]
            .split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    /// 同硬件分组内的 1:1 配对：按「x 升序 → y 降序」的组内相对次序配对，而不是绝对坐标。
    ///
    /// AppKit 的屏幕原点是相对当前主屏的坐标。唤醒/重启后主屏锚点可能变化，
    /// 所有屏幕的绝对原点整体平移——组内相对次序不变，而「绝对坐标相等」
    /// 会把 A 屏的旧指纹精确命中到平移后的另一块同型号屏上（配置互换的根源）。
    /// 无坐标的 orphan（旧版短指纹）排在有坐标的之后，按 id 序兜底。
    static func pairByRelativeRank(
        orphans: [(id: String, position: CGPoint?)],
        screens: [(id: String, position: CGPoint)]
    ) -> [String: String] {
        let rankedOrphans = orphans.sorted { lhs, rhs in
            switch (lhs.position, rhs.position) {
            case let (l?, r?):
                if abs(l.x - r.x) > 0.5 { return l.x < r.x }
                if abs(l.y - r.y) > 0.5 { return l.y > r.y }
                return lhs.id < rhs.id
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.id < rhs.id
            }
        }
        let rankedScreens = screens.sorted { lhs, rhs in
            if abs(lhs.position.x - rhs.position.x) > 0.5 { return lhs.position.x < rhs.position.x }
            if abs(lhs.position.y - rhs.position.y) > 0.5 { return lhs.position.y > rhs.position.y }
            return lhs.id < rhs.id
        }
        var pairs: [String: String] = [:]
        for index in 0..<min(rankedOrphans.count, rankedScreens.count) {
            pairs[rankedOrphans[index].id] = rankedScreens[index].id
        }
        return pairs
    }

    /// Matches a physical display fingerprint while tolerating a changed
    /// desktop position and a process-localized screen name. Callers that have
    /// multiple identical no-serial displays must still require a unique
    /// candidate before using this match.
    static func fingerprintsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || nameTolerantPart(stableFingerprintPart(lhs)) == nameTolerantPart(stableFingerprintPart(rhs))
    }

    /// Resolve a fingerprint-keyed value. Exact matches win; position- and
    /// name-tolerant matching is accepted only when there is one unambiguous
    /// candidate.
    static func value<Value>(
        in values: [String: Value],
        forFingerprint fingerprint: String
    ) -> Value? {
        if let exact = values[fingerprint] {
            return exact
        }
        let matches = values.filter { key, _ in
            fingerprintsMatch(key, fingerprint)
        }
        guard matches.count == 1 else {
            return nil
        }
        return matches.first?.value
    }

    /// Whether a fingerprint set contains an exact or uniquely unambiguous
    /// position/name-tolerant match for the current display.
    static func containsFingerprint(
        _ fingerprints: Set<String>,
        matching fingerprint: String
    ) -> Bool {
        if fingerprints.contains(fingerprint) {
            return true
        }
        return fingerprints.filter { fingerprintsMatch($0, fingerprint) }.count == 1
    }

    /// `NSScreen.screens` 的系统顺序在睡眠/唤醒、重插、分辨率协商后可能打乱。
    /// 用「主屏优先 + 从左到右 + 从上到下 + 稳定 id」生成跨进程一致的展示/CLI 索引顺序。
    static func identifier(for screen: NSScreen) -> String {
        if let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber {
            return screenNumber.stringValue
        }
        return "\(screen.localizedName):\(screen.frame.origin.x):\(screen.frame.origin.y)"
    }

    static func orderedScreens(_ screens: [NSScreen]) -> [NSScreen] {
        let mainID = NSScreen.main.map(identifier(for:))
        return screens.sorted { lhs, rhs in
            let lhsIsMain = identifier(for: lhs) == mainID
            let rhsIsMain = identifier(for: rhs) == mainID
            if lhsIsMain != rhsIsMain {
                return lhsIsMain
            }

            let lx = lhs.frame.origin.x
            let rx = rhs.frame.origin.x
            if abs(lx - rx) > 0.5 {
                return lx < rx
            }

            let ly = lhs.frame.origin.y
            let ry = rhs.frame.origin.y
            if abs(ly - ry) > 0.5 {
                // AppKit 坐标 y 向上；maxY 更大的屏更靠上，用户感知上应排在前面。
                return lhs.frame.maxY > rhs.frame.maxY
            }

            return identifier(for: lhs) < identifier(for: rhs)
        }
    }

    static func stableIndex(of screen: NSScreen, in screens: [NSScreen]? = nil) -> Int? {
        let ordered = orderedScreens(screens ?? NSScreen.screens)
        return ordered.firstIndex {
            identifier(for: $0) == identifier(for: screen)
        }
    }
}

extension NSScreen {
    /// 跨模块统一的稳定屏幕顺序（设置页「显示器 N」、选择弹窗、CLI 索引共用）。
    static var screensOrderedForDisplay: [NSScreen] {
        WallpaperScreenIdentity.orderedScreens(NSScreen.screens)
    }

    /// 返回当前枚举中的屏幕路由标识，用于跨模块的屏幕级状态字典 key。
    ///
    /// 优先使用 `NSScreenNumber`（CGDirectDisplayID 的字符串形式）。休眠/重启后
    /// 编号可能变化或被另一块屏复用；持久化配置必须同时校验物理指纹，不能只信此 key。
    ///
    /// 当 `NSScreenNumber` 不可用时（某些外接显示器、AirPlay 屏幕等），
    /// 回退到 `localizedName + 原点坐标`，比单纯的 localizedName 更能区分
    /// 同型号的多块显示器。
    var wallpaperScreenIdentifier: String {
        WallpaperScreenIdentity.identifier(for: self)
    }

    var isBuiltInDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(screenNumber.uint32Value)) != 0
    }

    /// 热插拔检测使用的连接指纹。不要包含分辨率/缩放/位置，否则外接屏刚接入时
    /// macOS 的模式协商或用户重排桌面时会把同一块显示器误判成新连接。
    var externalConnectionFingerprint: String {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "fallback:\(localizedName)"
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let builtin = CGDisplayIsBuiltin(displayID) != 0 ? "builtin" : "external"

        if serial != 0 {
            return "cg:\(vendor):\(model):\(serial):\(builtin)"
        }
        return "cg:\(vendor):\(model):noserial:\(localizedName):\(builtin)"
    }

    /// 调度器配置使用的物理显示器指纹。
    ///
    /// 必须能区分同型号、无硬件序列号的多块外接屏；否则 sleep/wake 后
    /// `NSScreenNumber` 变化时配置会互相串台（设置页「显示器 2/3」对调）。
    /// 有序列号时复用连接指纹；无序列号时与 `wallpaperScreenFingerprint` 一致，
    /// 用桌面排列位置拆开。
    var schedulerConfigFingerprint: String {
        wallpaperScreenFingerprint
    }

    /// 旧版显示器指纹格式，仅用于迁移已保存的状态。
    ///
    /// 无硬件序列号的同型号显示器在旧格式下会共享同一指纹，不能再用于新的持久化键。
    var legacyWallpaperScreenFingerprint: String {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "fallback:\(localizedName):\(Int(frame.width))x\(Int(frame.height))"
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let builtin = CGDisplayIsBuiltin(displayID) != 0 ? "builtin" : "external"
        let pixelWidth = Int(frame.width * backingScaleFactor)
        let pixelHeight = Int(frame.height * backingScaleFactor)

        if serial != 0 {
            return "cg:\(vendor):\(model):\(serial):\(builtin)"
        }
        return "cg:\(vendor):\(model):noserial:\(localizedName):\(pixelWidth)x\(pixelHeight):\(builtin)"
    }

    /// 尽量稳定的物理显示器指纹，用于外接屏断开 / 重连后 `NSScreenNumber` 变化时找回目标屏。
    ///
    /// 当显示器未提供硬件序列号时，厂商/型号/分辨率不足以区分两块同型号屏幕。
    /// 加入桌面排列位置可在重启后的相同显示器布局中保留独立恢复记录。
    var wallpaperScreenFingerprint: String {
        let legacyFingerprint = legacyWallpaperScreenFingerprint
        let hasHardwareSerial: Bool
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            hasHardwareSerial = CGDisplaySerialNumber(CGDirectDisplayID(screenNumber.uint32Value)) != 0
        } else {
            hasHardwareSerial = false
        }
        return WallpaperScreenIdentity.fingerprint(
            legacyFingerprint: legacyFingerprint,
            hasHardwareSerial: hasHardwareSerial,
            position: frame.origin
        )
    }

    /// 用于把历史 fingerprint 映射回当前屏（含旧版无 position 的短指纹）。
    var schedulerFingerprintCandidates: [String] {
        let result = [
            wallpaperScreenFingerprint,
            schedulerConfigFingerprint,
            legacyWallpaperScreenFingerprint,
            externalConnectionFingerprint,
        ]
        // 去重但保序
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    /// 当前显示器的主刷新率（Hz），取整。
    ///
    /// 通过 `CGDisplayCopyDisplayMode` 获取当前分辨率模式的刷新率。
    /// ProMotion / 可变刷新率显示器可能返回 0，此时回退到 60。
    var maxRefreshRate: Int {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 60
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return 60
        }
        let rate = mode.refreshRate
        // ProMotion / 可变刷新率可能返回 0
        if rate <= 0 {
            return 60
        }
        return Int(rate.rounded())
    }
}
