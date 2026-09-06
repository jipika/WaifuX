import CryptoKit
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

/// 单次分析快照；`analysisId` 作为离线烘焙产物缓存命名空间的一部分。
///
/// **稳定策略：** `analysisId` 由内容根路径 + `project.json` + scene 包指纹派生，
/// 同一工程重复分析应得到同一 UUID，避免 `SceneBakes/<item>/` 堆出多套同参 MP4。
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
    /// 被排除的元素不写入离线 MP4。
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
        let resolvedRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: contentRoot)
        let (sceneDict, _) = try loadScene(root: resolvedRoot)
        let projectDict = loadProjectOptional(root: resolvedRoot)
        return buildSnapshot(
            scene: sceneDict,
            project: projectDict,
            contentRootPath: resolvedRoot.standardizedFileURL.path,
            intent: intent,
            strict: strict
        )
    }

    /// 内容确定性 analysisId：同一工程重复分析返回同一 UUID（不读全量 scene 正文，避免大包 IO）。
    static func stableAnalysisId(for contentRoot: URL) -> UUID {
        let root = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: contentRoot)
            .standardizedFileURL
        var data = Data(root.path.utf8)

        let projectURL = root.appendingPathComponent("project.json")
        if let projectData = try? Data(contentsOf: projectURL) {
            data.append(projectData)
        }
        if let date = try? projectURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            data.append(Data(String(date.timeIntervalSince1970).utf8))
        }

        // project.json 的 file 字段可能指向 gifscene.pkg 等非 scene.pkg 主包
        var sceneCandidates = ["scene.pkg", "scene.json"]
        if let project = loadProjectOptional(root: root),
           let fileField = project["file"] as? String {
            let trimmed = fileField.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sceneCandidates.insert(trimmed, at: 0)
                sceneCandidates.insert((trimmed as NSString).lastPathComponent, at: 0)
            }
        }

        var seen = Set<String>()
        for relative in sceneCandidates {
            let normalized = relative.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            let url = root.appendingPathComponent(normalized)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            data.append(Data(normalized.utf8))
            if let size = values.fileSize {
                data.append(Data("\(size)".utf8))
            }
            if let date = values.contentModificationDate {
                data.append(Data(String(date.timeIntervalSince1970).utf8))
            }
        }

        let digest = Array(SHA256.hash(data: data))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5],
            (digest[6] & 0x0f) | 0x50, digest[7],
            (digest[8] & 0x3f) | 0x80, digest[9],
            digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    /// 规范化比较两个内容根是否为同一 Scene 工程。
    static func isSameContentRoot(_ lhs: String, _ rhs: String) -> Bool {
        let left = WorkshopService.resolveWallpaperEngineProjectRoot(
            startingAt: URL(fileURLWithPath: lhs)
        ).standardizedFileURL.path
        let right = WorkshopService.resolveWallpaperEngineProjectRoot(
            startingAt: URL(fileURLWithPath: rhs)
        ).standardizedFileURL.path
        return left == right
    }

    // MARK: scene.pkg（与 Python 脚本相同布局）

    private static func extractSceneJSONData(fromPkg pkgURL: URL, preferredSceneFileName: String? = nil) throws -> Data {
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

        let fallbackSceneFileName = pkgURL.deletingPathExtension().lastPathComponent + ".json"
        let candidateNames = [
            preferredSceneFileName,
            fallbackSceneFileName,
            "scene.json"
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }

        func entryMatches(_ entryName: String, candidate: String) -> Bool {
            let normalized = entryName.lowercased()
            return normalized == candidate || normalized.hasSuffix("/" + candidate)
        }

        func readEntry(_ entry: (name: String, offset: UInt32, length: UInt32)) throws -> Data {
            let start = base + Int(entry.offset)
            let end = start + Int(entry.length)
            guard end <= data.count else { throw SceneBakeEligibilityError.truncatedPackage }
            return data.subdata(in: start ..< end)
        }

        for candidate in candidateNames {
            if let entry = entries.first(where: { entryMatches($0.name, candidate: candidate) }) {
                return try readEntry(entry)
            }
        }

        // 兼容 gifscene.pkg 这类模板包：主 scene JSON 往往在包根，命名不是 scene.json。
        if let entry = entries.first(where: {
            let normalized = $0.name.lowercased()
            return normalized.hasSuffix(".json")
                && !normalized.contains("/materials/")
                && !normalized.contains("/models/")
                && !normalized.contains("/effects/")
                && !normalized.contains("/particles/")
                && !normalized.contains("/shaders/")
                && !normalized.contains("/fonts/")
        }) {
            return try readEntry(entry)
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
            // 1. 标准 scene.pkg
            let pkg = root.appendingPathComponent("scene.pkg")
            if fm.fileExists(atPath: pkg.path) {
                let jsonData = try extractSceneJSONData(fromPkg: pkg)
                guard let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    throw SceneBakeEligibilityError.jsonDecodeFailed
                }
                return (obj, pkg)
            }

            // 2. project.json 中 "file" 字段指定的场景文件（如 gifscene.pkg）
            let preferredSceneFileName = preferredSceneFileNameFromProject(root: root)
            if let sceneFileURL = resolveSceneFileFromProject(root: root) {
                if sceneFileURL.pathExtension.lowercased() == "pkg" {
                    let jsonData = try extractSceneJSONData(
                        fromPkg: sceneFileURL,
                        preferredSceneFileName: preferredSceneFileName
                    )
                    guard let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                        throw SceneBakeEligibilityError.jsonDecodeFailed
                    }
                    return (obj, sceneFileURL)
                }
                if sceneFileURL.lastPathComponent.lowercased() == "scene.json" {
                    let jsonData = try Data(contentsOf: sceneFileURL)
                    guard let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                        throw SceneBakeEligibilityError.jsonDecodeFailed
                    }
                    return (obj, sceneFileURL)
                }
            }

            // 3. 搜索目录下任意 .pkg 文件（自定义命名）
            if let anyPkg = findAnyPkgFile(in: root) {
                let jsonData = try extractSceneJSONData(
                    fromPkg: anyPkg,
                    preferredSceneFileName: preferredSceneFileName
                )
                guard let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    throw SceneBakeEligibilityError.jsonDecodeFailed
                }
                return (obj, anyPkg)
            }

            // 4. scene.json
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

    /// 从 project.json 的 "file" 字段解析场景文件路径
    private static func resolveSceneFileFromProject(root: URL) -> URL? {
        let projectURL = root.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sceneFile = json["file"] as? String,
              !sceneFile.isEmpty else { return nil }
        let sceneURL = root.appendingPathComponent(sceneFile)
        let fm = FileManager.default
        guard fm.fileExists(atPath: sceneURL.path) else { return nil }
        return sceneURL
    }

    private static func preferredSceneFileNameFromProject(root: URL) -> String? {
        let projectURL = root.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sceneFile = json["file"] as? String,
              !sceneFile.isEmpty else { return nil }
        return URL(fileURLWithPath: sceneFile).lastPathComponent
    }

    /// 递归搜索目录下第一个 .pkg 文件
    private static func findAnyPkgFile(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "pkg" {
                return fileURL
            }
        }
        return nil
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
            analysisId: stableAnalysisId(for: URL(fileURLWithPath: contentRootPath)),
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

        // 已有同工程 eligibility 时跳过重分析，避免无意义 IO 与历史随机 UUID 被反复覆盖。
        // 若已有可用烘焙产物，也一并短路（内容未变时 analysisId 本应稳定）。
        let shouldSkip = await MainActor.run { () -> Bool in
            guard let record = MediaLibraryService.shared.downloadedItems.first(where: {
                $0.item.id == itemID && $0.isActive
            }), let existing = record.sceneBakeEligibility else {
                return false
            }
            guard isSameContentRoot(existing.contentRootPath, contentURL.path) else {
                return false
            }
            if let artifact = SceneOfflineBakeService.usableArtifact(from: record),
               artifact.analysisId == existing.analysisId {
                print("[SceneBakeEligibility] skip re-analyze \(itemID): usable bake already bound")
                return true
            }
            // 内容指纹未变：保留已有 snapshot（含旧随机 UUID 的历史记录），避免换 id 触发无谓 auto-bake。
            let stableId = stableAnalysisId(for: contentURL)
            if existing.analysisId == stableId {
                print("[SceneBakeEligibility] skip re-analyze \(itemID): stable analysisId already present")
                return true
            }
            // 旧随机 UUID 且无可用产物：继续分析以升级到稳定 id。
            return false
        }
        if shouldSkip { return }

        let snapshot: SceneBakeEligibilitySnapshot?
        do {
            snapshot = try await analyzeWithinGate(contentRoot: contentURL, intent: .desktopLoop, strict: false)
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

// MARK: - 分析并发闸门

/// Scene 资格分析并发闸门。
///
/// 批量导入时每个条目都会触发一次分析（此前是裸 `Task(priority: .utility)` 无上限），
/// 而分析会把整个 scene.pkg 读进内存（库内实测最大 198MB/包）。原有的
/// 「480MB 可回收内存」门槛是先检查后分配：N 个任务可以在任何一个开始分配前
/// 全部过检、然后同时分配，内存瞬间叠加几十 GB——叠加烘焙/渲染/补帧通道时
/// 足以把系统拖到重启（2026-09-05 用户实测：批量导入 + 未烘焙完设置壁纸）。
/// 这里把并发收口到 2，且要求**持有槽位期间**才做内存检查与分配，
/// 使「检查→分配」最多只有 2 个任务同时在飞。
private actor SceneAnalysisGate {
    static let shared = SceneAnalysisGate()
    static let maxConcurrent = 2

    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if activeCount < Self.maxConcurrent {
            activeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard activeCount > 0 else { return }
        activeCount -= 1
        guard activeCount < Self.maxConcurrent, !waiters.isEmpty else { return }
        activeCount += 1
        waiters.removeFirst().resume()
    }
}

extension SceneBakeEligibilityAnalyzer {
    /// 在并发闸门内执行分析：拿到槽位后才做内存检查并整包读入 scene.pkg，
    /// 检查失败立即归还槽位。返回 nil 表示可回收内存不足，调用方应跳过本次分析。
    static func analyzeWithinGate(
        contentRoot: URL,
        intent: SceneBakeEligibilityIntent = .desktopLoop,
        strict: Bool = false
    ) async throws -> SceneBakeEligibilitySnapshot? {
        await SceneAnalysisGate.shared.acquire()
        do {
            guard SystemMemoryPressure.hasRoomForSceneEligibilityAnalysis() else {
                await SceneAnalysisGate.shared.release()
                print("[SceneBakeEligibility] skipped analyze: insufficient reclaimable memory (inside gate)")
                return nil
            }
            let snapshot = try analyze(contentRoot: contentRoot, intent: intent, strict: strict)
            await SceneAnalysisGate.shared.release()
            return snapshot
        } catch {
            await SceneAnalysisGate.shared.release()
            throw error
        }
    }
}
