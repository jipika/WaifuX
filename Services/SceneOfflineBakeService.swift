import AppKit
import Foundation

enum SceneOfflineBakeError: LocalizedError {
    case cliNotFound
    case ineligible
    case contentRootMissing
    case insufficientMemory
    case concurrentBakeInProgress
    case bakeProcessFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "未找到 wallpaperengine-cli"
        case .ineligible: return "当前 Scene 不适合离线烘焙（资格不足）"
        case .contentRootMissing: return "内容目录不存在，请重新下载"
        case .insufficientMemory: return LocalizationService.shared.t("sceneBake.error.insufficientMemory.bake")
        case .concurrentBakeInProgress: return LocalizationService.shared.t("sceneBake.error.concurrent")
        case .bakeProcessFailed(let msg): return msg
        }
    }
}

extension Notification.Name {
    /// Scene 离线烘焙完成（成功或失败）。`object` 为 `SceneBakeArtifact?`，失败时为 `nil`。
    static let sceneOfflineBakeDidComplete = Notification.Name("sceneOfflineBakeDidComplete")
}

/// 全局只允许一个 `wallpaperengine-cli bake` 子进程，避免重叠渲染导致内存成倍上涨。
private actor SceneOfflineBakeConcurrencyGate {
    static let shared = SceneOfflineBakeConcurrencyGate()
    private var busy = false

    func tryEnter() -> Bool {
        if busy { return false }
        busy = true
        return true
    }

    func leave() {
        busy = false
    }
}

/// 调用 `wallpaperengine-cli bake` 将 Workshop Scene 预渲染为循环 MP4，并写入下载记录。
enum SceneOfflineBakeService {
    /// 缓存文件路径：`analysisId + 分辨率 + fps + 时长`（根目录为 `DownloadPathManager.sceneBakesFolderURL`）
    private static func cacheVideoURL(
        baseDir: URL,
        itemID: String,
        analysisId: UUID,
        width: Int,
        height: Int,
        fps: Int,
        durationSeconds: Double
    ) -> URL {
        let safeID = itemID.replacingOccurrences(of: "/", with: "_")
        let dir = baseDir.appendingPathComponent(safeID, isDirectory: true)
        let name =
            "\(analysisId.uuidString)_\(width)x\(height)_\(fps)fps_\(Int(durationSeconds))s.mp4"
        return dir.appendingPathComponent(name)
    }

    /// 无媒体库记录时（例如仅能从 Steam 目录解析到工程）用于缓存目录名的稳定 ID。
    static func stableOrphanCacheItemID(contentRootPath: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for b in contentRootPath.utf8 {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return "orphan_\(hash)"
    }

    /// 与资格快照配套；`cacheItemID` 通常等于 `MediaItem.id`，无记录时用 `stableOrphanCacheItemID`。
    /// - Parameter persistArtifactToItemID: 非 nil 时将成品写回对应下载记录。
    static func bake(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double = 15,
        fps: Int32 = 30,
        persistArtifactToItemID: String? = nil
    ) async throws -> SceneBakeArtifact {
        let entered = await SceneOfflineBakeConcurrencyGate.shared.tryEnter()
        guard entered else {
            throw SceneOfflineBakeError.concurrentBakeInProgress
        }
        do {
            let result = try await bakeCore(
                eligibility: eligibility,
                contentRoot: contentRoot,
                cacheItemID: cacheItemID,
                durationSeconds: durationSeconds,
                fps: fps,
                persistArtifactToItemID: persistArtifactToItemID
            )
            await SceneOfflineBakeConcurrencyGate.shared.leave()
            await MainActor.run {
                NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: result)
            }
            return result
        } catch {
            await SceneOfflineBakeConcurrencyGate.shared.leave()
            await MainActor.run {
                NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: nil)
            }
            throw error
        }
    }

    private static func bakeCore(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double,
        fps: Int32,
        persistArtifactToItemID: String?
    ) async throws -> SceneBakeArtifact {
        guard FileManager.default.fileExists(atPath: contentRoot.path) else {
            throw SceneOfflineBakeError.contentRootMissing
        }
        guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
            throw SceneOfflineBakeError.insufficientMemory
        }

        guard let cli = WallpaperEngineXBridge.resolvedCLIExecutableURL() else {
            throw SceneOfflineBakeError.cliNotFound
        }

        let main = NSScreen.main
        let scale = main?.backingScaleFactor ?? 2
        let w = max(64, Int((main?.frame.width ?? 1920) * scale))
        let h = max(64, Int((main?.frame.height ?? 1080) * scale))
        let evenW = (w / 2) * 2
        let evenH = (h / 2) * 2

        let sceneBakesRoot = await MainActor.run {
            DownloadPathManager.shared.sceneBakesFolderURL
        }
        let outURL = cacheVideoURL(
            baseDir: sceneBakesRoot,
            itemID: cacheItemID,
            analysisId: eligibility.analysisId,
            width: evenW,
            height: evenH,
            fps: Int(fps),
            durationSeconds: durationSeconds
        )

        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: outURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
           let sz = attrs[.size] as? NSNumber, sz.intValue > 10_000 {
            let artifact = SceneBakeArtifact(
                analysisId: eligibility.analysisId,
                videoPath: outURL.path,
                width: evenW,
                height: evenH,
                fps: Int(fps),
                durationSeconds: durationSeconds,
                bakedAt: (attrs[.creationDate] as? Date) ?? .now
            )
            if let itemID = persistArtifactToItemID {
                await MainActor.run {
                    MediaLibraryService.shared.attachSceneBakeArtifact(itemID: itemID, artifact: artifact)
                }
            }
            return artifact
        }

        await MainActor.run {
            WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
        }
        // 与 stop 子进程错开，降低与即将启动的 bake 进程争抢 GPU/内存导致被系统 SIGKILL（退出码常表现为 9）。
        try await Task.sleep(nanoseconds: 250_000_000)

        let task = Process()
        task.executableURL = cli
        task.arguments = [
            "bake",
            contentRoot.path,
            outURL.path,
            String(evenW),
            String(evenH),
            String(fps),
            String(Int(durationSeconds))
        ]
        var env = ProcessInfo.processInfo.environment
        env["LSUIElement"] = "1"
        let execDir = cli.deletingLastPathComponent()
        let dylibCandidates = [
            execDir.path,
            execDir.appendingPathComponent("Resources").path,
            execDir.deletingLastPathComponent().appendingPathComponent("Frameworks").path
        ]
        var libPaths: [String] = []
        if let existing = env["DYLD_LIBRARY_PATH"], !existing.isEmpty {
            libPaths.append(existing)
        }
        for candidate in dylibCandidates {
            let p = candidate + "/liblinux-wallpaperengine-renderer.dylib"
            if FileManager.default.fileExists(atPath: p) {
                libPaths.append(candidate)
            }
        }
        if !libPaths.isEmpty {
            env["DYLD_LIBRARY_PATH"] = libPaths.joined(separator: ":")
        }
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        // `waitUntilExit` 为阻塞调用：放在独立线程执行，避免占满 Swift 并发线程池导致
        // `Task.detached` 管道读取任务无法推进，进而死锁或长时间不返回。
        let processTask = Task.detached(priority: .userInitiated) { () throws -> (Int32, Process.TerminationReason?, String) in
            let outTask = Task.detached {
                outPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let errTask = Task.detached {
                errPipe.fileHandleForReading.readDataToEndOfFile()
            }
            try task.run()
            task.waitUntilExit()
            let stdout = await outTask.value
            let stderr = await errTask.value
            var pieces: [String] = []
            if !stdout.isEmpty, let s = String(data: stdout, encoding: .utf8), !s.isEmpty { pieces.append(s) }
            if !stderr.isEmpty, let s = String(data: stderr, encoding: .utf8), !s.isEmpty { pieces.append(s) }
            let merged = pieces.joined(separator: "\n")
            let reason: Process.TerminationReason?
            if #available(macOS 10.15, *) {
                reason = task.terminationReason
            } else {
                reason = nil
            }
            return (task.terminationStatus, reason, merged)
        }

        // 外部 Task 取消时（如用户关闭 Sheet）必须终止子进程，否则 bake CLI 会继续占用 GPU/内存。
        let (termStatus, termReason, output) = try await withTaskCancellationHandler {
            try await processTask.value
        } onCancel: {
            if task.isRunning {
                task.terminate()
            }
            processTask.cancel()
        }

        // 子进程已退出后偶现文件系统尚未可见输出文件，短暂轮询避免误判失败。
        if termStatus == 0 {
            for attempt in 0 ..< 15 {
                if FileManager.default.fileExists(atPath: outURL.path),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
                   let sz = attrs[.size] as? NSNumber, sz.intValue > 10_000 {
                    break
                }
                if attempt == 14 { break }
                try await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        guard termStatus == 0, FileManager.default.fileExists(atPath: outURL.path) else {
            let status = termStatus
            var hint = ""
            if #available(macOS 10.15, *) {
                if termReason == .uncaughtSignal, status == 9 {
                    hint = "（退出码 9 多为 SIGKILL：内存压力或系统终止子进程；可关闭其它占用 GPU/内存的应用后重试）"
                }
            } else if status == 9 {
                hint = "（若 stderr 无明确错误，退出码 9 常为 SIGKILL）"
            }
            let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = tail.isEmpty ? "bake 退出码 \(status)\(hint)" : tail + (hint.isEmpty ? "" : "\n\(hint)")
            throw SceneOfflineBakeError.bakeProcessFailed(base)
        }

        // 生成 Web 叠加层（视频背景 + 动态元素 overlay）
        generateWebOverlayDirectory(
            contentRoot: contentRoot,
            videoPath: outURL.path,
            sceneWidth: evenW,
            sceneHeight: evenH
        )

        let artifact = SceneBakeArtifact(
            analysisId: eligibility.analysisId,
            videoPath: outURL.path,
            width: evenW,
            height: evenH,
            fps: Int(fps),
            durationSeconds: durationSeconds,
            bakedAt: .now
        )
        if let itemID = persistArtifactToItemID {
            await MainActor.run {
                MediaLibraryService.shared.attachSceneBakeArtifact(itemID: itemID, artifact: artifact)
            }
        }
        return artifact
    }

    /// 与 `MediaDownloadRecord.sceneBakeEligibility` 配套；默认主屏逻辑分辨率 × scale、8s、30fps。
    static func bake(
        record: MediaDownloadRecord,
        durationSeconds: Double = 15,
        fps: Int32 = 30
    ) async throws -> SceneBakeArtifact {
        guard let eligibility = record.sceneBakeEligibility else {
            throw SceneOfflineBakeError.ineligible
        }
        let contentRoot = URL(fileURLWithPath: eligibility.contentRootPath)
        do {
            let artifact = try await bake(
                eligibility: eligibility,
                contentRoot: contentRoot,
                cacheItemID: record.id,
                durationSeconds: durationSeconds,
                fps: fps,
                persistArtifactToItemID: record.id
            )
            await MainActor.run {
                NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: artifact)
            }
            return artifact
        } catch {
            await MainActor.run {
                NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: nil)
            }
            throw error
        }
    }

    /// 资格写入后后台自动烘焙（推荐/边缘档位）；已有同 `analysisId` 成品则跳过。
    static func scheduleAutoBakeAfterEligibility(itemID: String) {
        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let record = await MainActor.run { () -> MediaDownloadRecord? in
                MediaLibraryService.shared.downloadedItems.first { $0.item.id == itemID }
            }
            guard let record,
                  let eligibility = record.sceneBakeEligibility else { return }
            guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
                print("[SceneOfflineBake] auto-bake skipped: insufficient reclaimable memory")
                return
            }
            if let art = record.sceneBakeArtifact,
               art.analysisId == eligibility.analysisId,
               FileManager.default.fileExists(atPath: art.videoPath) {
                return
            }
            do {
                _ = try await bake(record: record)
                print("[SceneOfflineBake] auto-bake finished \(itemID)")
            } catch {
                if case SceneOfflineBakeError.concurrentBakeInProgress = error {
                    print("[SceneOfflineBake] auto-bake skipped (busy) \(itemID)")
                } else {
                    print("[SceneOfflineBake] auto-bake failed \(itemID): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Web Overlay Generation

    /// 生成 Scene 烘焙后的 Web 叠加层目录（.web），包含视频 + index.html + project.json + 字体
    /// 将动态元素（时钟、日期、音频可视化、视差等）从 scene.json 提取出来，
    /// 通过 scene-bake-web-template 在烘焙视频之上叠加渲染。
    private static func generateWebOverlayDirectory(
        contentRoot: URL,
        videoPath: String,
        sceneWidth: Int,
        sceneHeight: Int
    ) {
        // 1. 读取 scene.json
        guard let sceneDict = loadSceneDictionary(from: contentRoot) else {
            print("[WebOverlay] Failed to load scene.json from \(contentRoot.path)")
            return
        }

        // 2. 解析动态元素（文本、效果、视差等已烘焙排除的内容）
        let elements = parseSceneObjectsForOverlay(sceneDict: sceneDict)

        // 没有真正需要动态 overlay 的元素时，直接跳过（不生成 .web 目录，纯静态场景已完整烘焙进视频）
        guard !elements.isEmpty else {
            print("[WebOverlay] No dynamic overlay elements found, skipping .web generation")
            return
        }

        let webDirPath = videoPath.replacingOccurrences(of: ".mp4", with: ".web")
        let webDir = URL(fileURLWithPath: webDirPath)
        let fm = FileManager.default

        do {
            if fm.fileExists(atPath: webDirPath) {
                try fm.removeItem(at: webDir)
            }
            try fm.createDirectory(at: webDir, withIntermediateDirectories: true)
        } catch {
            print("[WebOverlay] Failed to create web directory: \(error)")
            return
        }

        // 3. 从 scene.json 读取场景设计分辨率（orthogonalprojection 优先）
        let designWidth: Int
        let designHeight: Int
        if let general = sceneDict["general"] as? [String: Any],
           let ortho = general["orthogonalprojection"] as? [String: Any],
           let ow = ortho["width"] as? Int,
           let oh = ortho["height"] as? Int {
            designWidth = ow
            designHeight = oh
        } else {
            designWidth = sceneWidth
            designHeight = sceneHeight
        }

        // 4. 构建 __SCENE_BAKE_CONFIG__ 配置
        let config: [String: Any] = [
            "sceneWidth": designWidth,
            "sceneHeight": designHeight,
            "videoSrc": "baked.mp4",
            "elements": elements
        ]

        // 4. 复制模板并注入配置
        guard let templateURL = resolveWebTemplateURL() else {
            print("[WebOverlay] Template not found")
            return
        }
        guard var templateHTML = try? String(contentsOf: templateURL) else {
            print("[WebOverlay] Failed to read template")
            return
        }

        guard let configData = try? JSONSerialization.data(withJSONObject: config, options: []),
              let configJSON = String(data: configData, encoding: .utf8) else {
            print("[WebOverlay] Failed to encode config")
            return
        }

        let configScript = "<script>window.__SCENE_BAKE_CONFIG__ = \(configJSON);</script>"
        if let range = templateHTML.range(of: "</head>") {
            templateHTML.replaceSubrange(range, with: configScript + "\n</head>")
        }

        let indexURL = webDir.appendingPathComponent("index.html")
        do {
            try templateHTML.write(to: indexURL, atomically: true, encoding: .utf8)
        } catch {
            print("[WebOverlay] Failed to write index.html: \(error)")
            return
        }

        // 5. 创建 project.json（CLI Web 渲染器需要）
        let projectJSON: [String: Any] = [
            "type": "web",
            "file": "index.html"
        ]
        if let projectData = try? JSONSerialization.data(withJSONObject: projectJSON, options: [.prettyPrinted]) {
            let projectURL = webDir.appendingPathComponent("project.json")
            try? projectData.write(to: projectURL)
        }

        // 6. 复制烘焙视频到 .web 目录
        let videoURL = URL(fileURLWithPath: videoPath)
        let destVideoURL = webDir.appendingPathComponent("baked.mp4")
        do {
            try fm.copyItem(at: videoURL, to: destVideoURL)
        } catch {
            print("[WebOverlay] Failed to copy video: \(error)")
        }

        // 7. 复制引用的字体文件
        copyReferencedFonts(elements: elements, from: contentRoot, to: webDir)

        print("[WebOverlay] Generated overlay at \(webDirPath) with \(elements.count) elements")
    }

    /// 查找 scene-bake-web-template/index.html 模板路径
    private static func resolveWebTemplateURL() -> URL? {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "scene-bake-web-template") {
            return url
        }
        let candidates = [
            URL(fileURLWithPath: "/Volumes/mac/CodeLibrary/Claude/WallHaven/Resources/scene-bake-web-template/index.html"),
            URL(fileURLWithPath: "/Volumes/mac/CodeLibrary/Claude/WallHaven/build/WaifuX.app/Contents/Resources/scene-bake-web-template/index.html")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 从 Scene 内容根目录加载 scene.json（支持 scene.pkg 和普通文件）
    private static func loadSceneDictionary(from contentRoot: URL) -> [String: Any]? {
        let fm = FileManager.default
        let pkgURL = contentRoot.appendingPathComponent("scene.pkg")

        if fm.fileExists(atPath: pkgURL.path) {
            guard let data = extractSceneJSONFromPKG(pkgURL) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        let sceneJSON = contentRoot.appendingPathComponent("scene.json")
        if fm.fileExists(atPath: sceneJSON.path),
           let data = try? Data(contentsOf: sceneJSON),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        return nil
    }

    /// 从 scene.pkg 中提取 scene.json 数据（简化版，与 SceneBakeEligibilityAnalyzer 对齐）
    private static func extractSceneJSONFromPKG(_ pkgURL: URL) -> Data? {
        extractFileFromPKG(pkgURL, fileName: "scene.json")
    }

    /// 从 scene.pkg 中提取指定文件（通用方法）
    private static func extractFileFromPKG(_ pkgURL: URL, fileName: String) -> Data? {
        guard let data = try? Data(contentsOf: pkgURL) else { return nil }
        var offset = 0

        guard offset + 4 <= data.count else { return nil }
        let slen = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        offset += 4 + Int(slen)

        guard offset + 4 <= data.count else { return nil }
        let nfiles = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        offset += 4

        var entries: [(name: String, offset: UInt32, length: UInt32)] = []
        for _ in 0..<Int(nfiles) {
            guard offset + 4 <= data.count else { return nil }
            let es = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
            offset += 4
            guard offset + Int(es) <= data.count else { return nil }
            let nameData = data.subdata(in: offset..<offset + Int(es))
            guard let name = String(data: nameData, encoding: .utf8) else { return nil }
            offset += Int(es)
            guard offset + 8 <= data.count else { return nil }
            let fileOff = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
            offset += 4
            let fileLen = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
            offset += 4
            entries.append((name, fileOff, fileLen))
        }

        let base = offset
        for e in entries {
            if e.name == fileName || e.name.hasSuffix("/\(fileName)") {
                let start = base + Int(e.offset)
                let end = start + Int(e.length)
                guard end <= data.count else { return nil }
                return data.subdata(in: start..<end)
            }
        }
        return nil
    }

    /// 解析 scene.json objects，提取需要在 Web 叠加层上渲染的动态元素
    private static func parseSceneObjectsForOverlay(sceneDict: [String: Any]) -> [[String: Any]] {
        guard let objects = sceneDict["objects"] as? [[String: Any]] else { return [] }

        var elements: [[String: Any]] = []

        for obj in objects {
            let isVisible = obj["visible"] as? Bool ?? true
            guard isVisible else { continue }

            let textDict = obj["text"] as? [String: Any]
            let hasTextValue = (textDict?["value"] as? String)?.isEmpty == false
            let hasTextScript = (textDict?["script"] as? String)?.isEmpty == false
            let hasText = hasTextValue || hasTextScript
            let hasParallax = obj["mouseparallax"] as? Bool == true

            // 只保留真正需要动态 overlay 的元素：有实际内容的文本、视差
            // effects（blur/glow/xray 等）已烘焙进视频，不单独保留；
            // 仅当文本/视差对象附带 effects 时才作为附加属性保留
            guard hasText || hasParallax else { continue }

            var element: [String: Any] = [:]
            element["name"] = obj["name"] as? String ?? ""
            element["origin"] = obj["origin"] as? String ?? "0 0 0"
            element["scale"] = obj["scale"] as? String ?? "1 1 1"
            element["angle"] = obj["angles"] as? String ?? obj["angle"] as? String ?? "0 0 0"
            element["size"] = obj["size"] as? String ?? "0 0 0"
            element["visible"] = isVisible

            if let alpha = obj["alpha"] as? Double {
                element["opacity"] = alpha
            } else if let alpha = obj["alpha"] as? String, let val = Double(alpha) {
                element["opacity"] = val
            }

            if let color = obj["color"] as? String {
                element["color"] = color
            }

            if let brightness = obj["brightness"] as? Double {
                element["brightness"] = brightness
            } else if let brightness = obj["brightness"] as? String, let val = Double(brightness) {
                element["brightness"] = val
            }

            // 文本属性
            if let text = obj["text"] as? [String: Any] {
                var tp: [String: Any] = [:]
                tp["value"] = text["value"] as? String ?? ""
                tp["script"] = text["script"] as? String ?? ""

                if let font = obj["font"] as? String {
                    tp["font"] = font
                    element["font"] = font
                }
                if let pointsize = obj["pointsize"] as? Double {
                    tp["pointSize"] = pointsize
                } else if let pointsize = obj["pointsize"] as? String, let val = Double(pointsize) {
                    tp["pointSize"] = val
                }
                if let hAlign = obj["horizontalalign"] as? String {
                    tp["horizontalAlign"] = hAlign
                }
                if let vAlign = obj["verticalalign"] as? String {
                    tp["verticalAlign"] = vAlign
                }
                if let bold = obj["bold"] as? Bool {
                    tp["bold"] = bold
                }
                if let bgColor = obj["backgroundcolor"] as? String {
                    tp["backgroundColor"] = bgColor
                }
                if let opaqueBg = obj["opaquebackground"] as? Bool {
                    tp["opaquebackground"] = opaqueBg
                }
                if let padding = obj["padding"] as? Int {
                    tp["padding"] = padding
                } else if let padding = obj["padding"] as? String, let val = Int(padding) {
                    tp["padding"] = val
                }
                if let letterSpacing = obj["letterspacing"] as? Double {
                    tp["letterSpacing"] = letterSpacing
                } else if let letterSpacing = obj["letterspacing"] as? String, let val = Double(letterSpacing) {
                    tp["letterSpacing"] = val
                }
                if let textCase = obj["textcase"] as? String {
                    tp["textCase"] = textCase
                } else if let textCase = obj["texttransform"] as? String {
                    tp["textCase"] = textCase
                }

                element["textProperties"] = tp
                element["type"] = "text"
            }

            // 效果（blur、glow 等）
            if let effects = obj["effects"] as? [[String: Any]], !effects.isEmpty {
                var mappedEffects: [[String: Any]] = []
                for eff in effects {
                    var mapped: [String: Any] = [:]
                    if let file = eff["file"] as? String {
                        mapped["name"] = file
                    }
                    if let passes = eff["passes"] as? [[String: Any]] {
                        var mappedPasses: [[String: Any]] = []
                        for pass in passes {
                            var mappedPass: [String: Any] = [:]
                            if let cshaders = pass["constantshadervalues"] as? [String: Any] {
                                mappedPass["constantshadervalues"] = cshaders
                            }
                            mappedPasses.append(mappedPass)
                        }
                        mapped["passes"] = mappedPasses
                    }
                    mappedEffects.append(mapped)
                }
                element["effects"] = mappedEffects
            }

            // 鼠标视差
            if hasParallax {
                element["mouseParallax"] = true
                if let amount = obj["mouseparallaxamount"] as? String {
                    element["mouseParallaxAmount"] = amount
                }
            }

            elements.append(element)
        }

        return elements
    }

    /// 将 scene.json 中引用的字体文件复制到 .web 目录（优先从文件系统复制， fallback 从 scene.pkg 提取）
    private static func copyReferencedFonts(elements: [[String: Any]], from contentRoot: URL, to webDir: URL) {
        let fm = FileManager.default
        var fontPaths = Set<String>()

        for el in elements {
            if let font = el["font"] as? String {
                fontPaths.insert(font)
            }
            if let tp = el["textProperties"] as? [String: Any], let font = tp["font"] as? String {
                fontPaths.insert(font)
            }
        }

        let pkgURL = contentRoot.appendingPathComponent("scene.pkg")
        let hasPkg = fm.fileExists(atPath: pkgURL.path)

        for fontPath in fontPaths {
            let src = contentRoot.appendingPathComponent(fontPath)
            let dest = webDir.appendingPathComponent(fontPath)

            if fm.fileExists(atPath: src.path) {
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: src, to: dest)
                } catch {
                    print("[WebOverlay] Failed to copy font \(fontPath): \(error)")
                }
            } else if hasPkg, let fontData = extractFileFromPKG(pkgURL, fileName: fontPath) {
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fontData.write(to: dest)
                    print("[WebOverlay] Extracted font \(fontPath) from scene.pkg")
                } catch {
                    print("[WebOverlay] Failed to write extracted font \(fontPath): \(error)")
                }
            } else {
                print("[WebOverlay] Font not found, will use system fallback: \(fontPath)")
            }
        }
    }
}
