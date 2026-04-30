import Foundation

// MARK: - Models（与 scripts/scene_bake_eligibility.py 对齐；analysisId 供后续烘焙缓存键）

struct SceneBakeEligibilityFlags: Codable, Hashable, Sendable {
    var cursorRipple: Bool
    var iris: Bool
    var audioReactive: Bool
    var waterripple: Bool
    var shake: Bool
    /// 检测到 `os.time` / `os.date` 等墙钟 API 或强相关配置；预渲染 MP4 无法随真实时间更新。
    var wallClockTime: Bool

    enum CodingKeys: String, CodingKey {
        case cursorRipple = "cursor_ripple"
        case iris
        case audioReactive = "audio_reactive"
        case waterripple
        case shake
        case wallClockTime = "wall_clock_time"
    }

    init(
        cursorRipple: Bool,
        iris: Bool,
        audioReactive: Bool,
        waterripple: Bool,
        shake: Bool,
        wallClockTime: Bool = false
    ) {
        self.cursorRipple = cursorRipple
        self.iris = iris
        self.audioReactive = audioReactive
        self.waterripple = waterripple
        self.shake = shake
        self.wallClockTime = wallClockTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursorRipple = try c.decode(Bool.self, forKey: .cursorRipple)
        iris = try c.decode(Bool.self, forKey: .iris)
        audioReactive = try c.decode(Bool.self, forKey: .audioReactive)
        waterripple = try c.decode(Bool.self, forKey: .waterripple)
        shake = try c.decode(Bool.self, forKey: .shake)
        wallClockTime = try c.decodeIfPresent(Bool.self, forKey: .wallClockTime) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cursorRipple, forKey: .cursorRipple)
        try c.encode(iris, forKey: .iris)
        try c.encode(audioReactive, forKey: .audioReactive)
        try c.encode(waterripple, forKey: .waterripple)
        try c.encode(shake, forKey: .shake)
        try c.encode(wallClockTime, forKey: .wallClockTime)
    }
}

enum SceneBakeEligibilityTier: String, Codable, Hashable, Sendable {
    case recommended
    case marginal
    case notRecommended = "not_recommended"
}

enum SceneBakeEligibilityIntent: String, Codable, Hashable, Sendable {
    case technical
    case desktopLoop = "desktop-loop"
}

/// 单次分析快照；`analysisId` 建议作为离线烘焙产物缓存命名空间的一部分。
struct SceneBakeEligibilitySnapshot: Codable, Hashable, Sendable {
    var analysisId: UUID
    var analyzedAt: Date
    var score: Int
    var rawDeduction: Int
    var bonus: Int
    var tier: SceneBakeEligibilityTier
    var strict: Bool
    var intent: SceneBakeEligibilityIntent
    var notes: [String]
    var effectCount: Int
    var workshopEffectCount: Int
    var parallaxOn: Bool
    var flags: SceneBakeEligibilityFlags
    /// 分析时使用的内容根目录（Steam workshop content 路径）
    var contentRootPath: String

    /// 是否值得走「预烘焙视频」策略。当前策略：所有 Scene 都允许烘焙，
    /// 动态元素（时钟、日期、音频可视化等）在烘焙前会被预处理排除，仅保留背景；
    /// 被排除的元素由 App 侧 Web 叠加层复现。
    var isEligibleForOfflineBake: Bool {
        true
    }
}

enum SceneBakeEligibilityError: Error {
    case truncatedPackage
    case sceneNotFound
    case invalidPath
    case jsonDecodeFailed
}

// MARK: - Analyzer

enum SceneBakeEligibilityAnalyzer {
    /// 对 Workshop 内容根目录做 eligibility 分析（需已存在 scene.pkg 或 scene.json）。
    static func analyze(
        contentRoot: URL,
        intent: SceneBakeEligibilityIntent = .desktopLoop,
        strict: Bool = false
    ) throws -> SceneBakeEligibilitySnapshot {
        let (sceneDict, _) = try loadScene(root: contentRoot)
        let projectDict = loadProjectOptional(root: contentRoot)
        return buildSnapshot(
            scene: sceneDict,
            project: projectDict,
            contentRootPath: contentRoot.path,
            intent: intent,
            strict: strict
        )
    }

    // MARK: scene.pkg（与 Python 脚本相同布局）

    private static func extractSceneJSONData(fromPkg pkgURL: URL) throws -> Data {
        let data = try Data(contentsOf: pkgURL)
        var o = 0
        let slen = try readU32LE(data, &o)
        guard o + Int(slen) <= data.count else { throw SceneBakeEligibilityError.truncatedPackage }
        o += Int(slen)
        let nfiles = try readU32LE(data, &o)
        var entries: [(name: String, offset: UInt32, length: UInt32)] = []
        for _ in 0 ..< Int(nfiles) {
            let es = try readU32LE(data, &o)
            guard o + Int(es) <= data.count else { throw SceneBakeEligibilityError.truncatedPackage }
            let nameData = data.subdata(in: o ..< o + Int(es))
            o += Int(es)
            let name = String(data: nameData, encoding: .utf8) ?? ""
            let fileOff = try readU32LE(data, &o)
            let fileLen = try readU32LE(data, &o)
            entries.append((name, fileOff, fileLen))
        }
        let base = o
        for e in entries {
            if e.name == "scene.json" || e.name.hasSuffix("/scene.json") {
                let start = base + Int(e.offset)
                let end = start + Int(e.length)
                guard end <= data.count else { throw SceneBakeEligibilityError.truncatedPackage }
                return data.subdata(in: start ..< end)
            }
        }
        throw SceneBakeEligibilityError.sceneNotFound
    }

    private static func readU32LE(_ data: Data, _ o: inout Int) throws -> UInt32 {
        guard o + 4 <= data.count else { throw SceneBakeEligibilityError.truncatedPackage }
        let v = UInt32(data[o])
            | (UInt32(data[o + 1]) << 8)
            | (UInt32(data[o + 2]) << 16)
            | (UInt32(data[o + 3]) << 24)
        o += 4
        return v
    }

    private static func loadScene(root: URL) throws -> ([String: Any], URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else {
            throw SceneBakeEligibilityError.invalidPath
        }

        if isDir.boolValue {
            let pkg = root.appendingPathComponent("scene.pkg")
            if fm.fileExists(atPath: pkg.path) {
                let jsonData = try extractSceneJSONData(fromPkg: pkg)
                guard let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    throw SceneBakeEligibilityError.jsonDecodeFailed
                }
                return (obj, pkg)
            }
            let sj = root.appendingPathComponent("scene.json")
            if fm.fileExists(atPath: sj.path) {
                let jsonData = try Data(contentsOf: sj)
                guard let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    throw SceneBakeEligibilityError.jsonDecodeFailed
                }
                return (obj, sj)
            }
            throw SceneBakeEligibilityError.sceneNotFound
        }

        if root.pathExtension.lowercased() == "pkg" {
            let jsonData = try extractSceneJSONData(fromPkg: root)
            guard let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                throw SceneBakeEligibilityError.jsonDecodeFailed
            }
            return (obj, root)
        }
        if root.lastPathComponent.lowercased() == "scene.json" {
            let jsonData = try Data(contentsOf: root)
            guard let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                throw SceneBakeEligibilityError.jsonDecodeFailed
            }
            return (obj, root)
        }
        throw SceneBakeEligibilityError.invalidPath
    }

    private static func loadProjectOptional(root: URL) -> [String: Any]? {
        let p = root.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: p),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func collectEffectFiles(scene: [String: Any]) -> [String] {
        var out: [String] = []
        guard let objects = scene["objects"] as? [[String: Any]] else { return out }
        for obj in objects {
            guard let effects = obj["effects"] as? [[String: Any]] else { continue }
            for eff in effects {
                if let file = eff["file"] as? String {
                    out.append(file)
                }
            }
        }
        return out
    }

    private static func collectUserPropertyKeys(project: [String: Any]?) -> Set<String> {
        guard let project,
              let general = project["general"] as? [String: Any],
              let props = general["properties"] as? [String: Any] else {
            return []
        }
        return Set(props.keys.map { $0.lowercased() })
    }

    /// 递归取出 JSON 中所有字符串，用于在 scene/project 内嵌脚本里匹配墙钟 API。
    private static func jsonStringValues(_ value: Any) -> [String] {
        switch value {
        case let s as String:
            return [s]
        case let arr as [Any]:
            return arr.flatMap { jsonStringValues($0) }
        case let dict as [String: Any]:
            return dict.values.flatMap { jsonStringValues($0) }
        default:
            return []
        }
    }

    /// 扫描工程目录下文本（Lua / JSON，单文件 ≤2MB，总预算约 6MB），拼接后做墙钟检测。
    private static func collectScriptTextForWallClockScan(contentRoot: URL) -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: contentRoot.path, isDirectory: &isDir), isDir.boolValue else { return "" }
        guard let enumerator = fm.enumerator(
            at: contentRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ""
        }
        var parts: [String] = []
        var budget = 6_000_000
        while let url = enumerator.nextObject() as? URL {
            if budget <= 0 { break }
            let ext = url.pathExtension.lowercased()
            guard ext == "lua" || ext == "json" else { continue }
            guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let sz = vals.fileSize, sz > 0, sz <= 2_000_000 else { continue }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count <= 2_000_000 else { continue }
            guard let s = String(data: data, encoding: .utf8) else { continue }
            parts.append(s)
            budget -= data.count
        }
        return parts.joined(separator: "\n")
    }

    /// Lua 墙钟 API（与 Wallpaper Engine 场景脚本一致）；预渲染 MP4 无法随真实时间更新。
    private static func wallClockSignalsInText(_ text: String) -> Bool {
        let opts: String.CompareOptions = [.regularExpression, .caseInsensitive]
        if text.range(of: #"os\.time\s*\("#, options: opts) != nil { return true }
        if text.range(of: #"os\.date\s*\("#, options: opts) != nil { return true }
        return false
    }

    /// `project.json` user property 键名中的强提示（避免与单纯 `timeout` 等误判，仅取较长子串）。
    private static func wallClockHintsInUserKeys(_ keys: Set<String>) -> Bool {
        keys.contains { k in
            k.contains("wallclock") || k.contains("wall_clock")
                || k.contains("systemtime") || k.contains("system_time")
                || k.contains("unixtimestamp") || k.contains("unix_time")
                || k.contains("localetime") || k.contains("locale_time")
                || k.contains("datetimepicker") || k.contains("digitalclock")
        }
    }

    private static func sceneParallaxMouse(scene: [String: Any]) -> (enabled: Bool, influence: Double) {
        guard let g = scene["general"] as? [String: Any] else {
            return (false, 0)
        }
        let enabled = (g["cameraparallax"] as? Bool) ?? false
        let amount = g["cameraparallaxmouseinfluence"]
        let inf: Double
        if let n = amount as? Double {
            inf = n
        } else if let i = amount as? Int {
            inf = Double(i)
        } else if let s = amount as? String, let d = Double(s) {
            inf = d
        } else {
            inf = 0.5
        }
        return (enabled, inf)
    }

    private static func buildSnapshot(
        scene: [String: Any],
        project: [String: Any]?,
        contentRootPath: String,
        intent: SceneBakeEligibilityIntent,
        strict: Bool
    ) -> SceneBakeEligibilitySnapshot {
        let effectFiles = collectEffectFiles(scene: scene)
        let blob = effectFiles.joined(separator: "\n").lowercased()
        let userKeys = collectUserPropertyKeys(project: project)

        let contentRootURL = URL(fileURLWithPath: contentRootPath)
        let diskScriptBlob = collectScriptTextForWallClockScan(contentRoot: contentRootURL)
        let embeddedJSONBlob = jsonStringValues(scene).joined(separator: "\n")
            + "\n"
            + (project.map { jsonStringValues($0).joined(separator: "\n") } ?? "")
        let wallClockBlob = diskScriptBlob + "\n" + embeddedJSONBlob
        let hasWallClockAPI = wallClockSignalsInText(wallClockBlob)
        let hasWallClockUserKeys = wallClockHintsInUserKeys(userKeys)
        let hasWallClock = hasWallClockAPI || hasWallClockUserKeys

        let hasCursorRipple = blob.contains("cursorripple")
        let hasIris = blob.contains("iris_movement") || blob.contains("2973943998")
        let hasAudioRing = blob.contains("3605510527")
        let hasAudioUser = userKeys.contains { $0.contains("audiovisualizer") }
        let hasWaterripple = blob.contains("waterripple")
        let hasShake = blob.contains("effects/shake") || blob.contains("/shake/effect")
        let workshopFx = effectFiles.filter { $0.lowercased().contains("effects/workshop/") }.count

        var deductions: [(Int, String)] = []

        if hasCursorRipple || userKeys.contains("beermugcursorripple") {
            deductions.append((strict ? 20 : 12, "光标涟漪 / 啤酒杯涟漪（烘焙后不再跟手）"))
        }
        if hasIris || userKeys.contains("eyetracking") {
            deductions.append((strict ? 28 : 14, "眼动或瞳孔跟踪（烘焙后冻结为默认姿态）"))
        }
        if hasAudioRing || hasAudioUser {
            deductions.append((strict ? 24 : 12, "音频频谱/音频可视化相关（烘焙后不再随音乐变化）"))
        }
        if hasWaterripple {
            deductions.append((strict ? 10 : 6, "水面/波纹类效果（通常可烘焙进循环，少数跟光标）"))
        }
        if hasShake {
            deductions.append((strict ? 6 : 3, "抖动类（已包含在视频里，一般无妨）"))
        }

        if workshopFx > 0 {
            var w = min(12, 3 + workshopFx * 2)
            w = Int(Double(w) * (strict ? 1.3 : 1.0))
            deductions.append((w, "Workshop 自定义效果 ×\(workshopFx)（需确认是否依赖实时输入）"))
        }

        let (parallaxOn, parallaxInf) = sceneParallaxMouse(scene: scene)
        if parallaxOn {
            let factor = (strict ? 1.0 : 0.85) * min(1.0, 0.45 + parallaxInf)
            deductions.append((Int(Double(28) * factor), "相机 Parallax + 鼠标影响"))
        }

        if let project {
            if let gen = project["general"] as? [String: Any],
               gen["supportsaudioprocessing"] != nil {
                deductions.append((strict ? 10 : 5, "project 声明 supportsaudioprocessing"))
            }
        }

        if hasWallClock {
            // 轻量扣分供档位参考；不禁止烘焙（用户可直接 CLI 烘焙时 App 也应允许）。
            deductions.append((strict ? 12 : 8, "墙钟：含 os.time/os.date 等（成片内时间不会随真实时间更新）"))
        }

        let totalDeduction = deductions.map(\.0).reduce(0, +)
        var score = max(0, 100 - totalDeduction)
        var notes: [String] = []
        var bonus = 0
        if intent == .desktopLoop {
            bonus = strict ? 14 : 26
            notes.append("+\(bonus) 用途：桌面循环视频（接受交互/音频联动在成片里冻结）")
        }
        score = max(0, min(100, score + bonus))
        for d in deductions {
            notes.append("-\(d.0) \(d.1)")
        }

        let tier: SceneBakeEligibilityTier
        if score >= 62 {
            tier = .recommended
        } else if score >= 42 {
            tier = .marginal
        } else {
            tier = .notRecommended
        }

        let flags = SceneBakeEligibilityFlags(
            cursorRipple: hasCursorRipple,
            iris: hasIris,
            audioReactive: hasAudioRing || hasAudioUser,
            waterripple: hasWaterripple,
            shake: hasShake,
            wallClockTime: hasWallClock
        )

        return SceneBakeEligibilitySnapshot(
            analysisId: UUID(),
            analyzedAt: Date(),
            score: score,
            rawDeduction: totalDeduction,
            bonus: bonus,
            tier: tier,
            strict: strict,
            intent: intent,
            notes: notes,
            effectCount: effectFiles.count,
            workshopEffectCount: workshopFx,
            parallaxOn: parallaxOn,
            flags: flags,
            contentRootPath: contentRootPath
        )
    }
}

// MARK: - 调度（入库：Workshop / 本地导入，只要 project.json type 为 scene）

extension SceneBakeEligibilityAnalyzer {
    /// 解析 `localFileURL` 所在的 Scene 工程根目录（目录本身或单文件的父目录），且 `project.json` 的 type 为 scene。
    static func sceneContentRootIfEligibleForAnalysis(localFileURL: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localFileURL.path, isDirectory: &isDir) else { return nil }
        let root = isDir.boolValue ? localFileURL : localFileURL.deletingLastPathComponent()
        let projectURL = root.appendingPathComponent("project.json")
        guard let pdata = try? Data(contentsOf: projectURL),
              let pjson = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any],
              let typeStr = pjson["type"] as? String,
              typeStr.lowercased() == "scene" else {
            return nil
        }
        return root
    }

    /// 媒体库 `recordDownload` 后调用：**不限** `workshop_`，本地导入的 Scene 同样分析。
    static func scheduleAnalysisForRecordedWorkshop(itemID: String, contentURL: URL) {
        scheduleAnalysisIfSceneProject(itemID: itemID, localFileURL: contentURL)
    }

    static func scheduleAnalysisIfSceneProject(itemID: String, localFileURL: URL) {
        guard let root = sceneContentRootIfEligibleForAnalysis(localFileURL: localFileURL) else { return }
        Task(priority: .utility) {
            await runAnalysisAndAttach(itemID: itemID, contentURL: root)
        }
    }

    private static func runAnalysisAndAttach(itemID: String, contentURL: URL) async {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: contentURL.path, isDirectory: &isDir),
              isDir.boolValue else { return }

        let projectURL = contentURL.appendingPathComponent("project.json")
        guard let pdata = try? Data(contentsOf: projectURL),
              let pjson = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any],
              let typeStr = pjson["type"] as? String,
              typeStr.lowercased() == "scene" else {
            return
        }
        guard SystemMemoryPressure.hasRoomForSceneEligibilityAnalysis() else {
            print("[SceneBakeEligibility] skipped analyze for \(itemID): insufficient reclaimable memory")
            return
        }

        let snapshot: SceneBakeEligibilitySnapshot?
        do {
            snapshot = try analyze(contentRoot: contentURL, intent: .desktopLoop, strict: false)
        } catch {
            print("[SceneBakeEligibility] analyze failed for \(itemID): \(error)")
            snapshot = nil
        }

        await MainActor.run {
            if let snapshot {
                MediaLibraryService.shared.attachSceneBakeEligibility(itemID: itemID, snapshot: snapshot, triggerAutoBake: true)
                print(
                    "[SceneBakeEligibility] \(itemID) tier=\(snapshot.tier.rawValue) score=\(snapshot.score) analysisId=\(snapshot.analysisId.uuidString)"
                )
            }
        }
    }
}
