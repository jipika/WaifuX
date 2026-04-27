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
    /// - Parameter requireEligibility: 为 `false` 时跳过 `isEligibleForOfflineBake`（与手动调用 `wallpaperengine-cli bake` 一致，「设为壁纸」路径使用）。
    static func bake(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double = 15,
        fps: Int32 = 30,
        persistArtifactToItemID: String? = nil,
        requireEligibility: Bool = true
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
                persistArtifactToItemID: persistArtifactToItemID,
                requireEligibility: requireEligibility
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
        persistArtifactToItemID: String?,
        requireEligibility: Bool
    ) async throws -> SceneBakeArtifact {
        if requireEligibility {
            guard eligibility.isEligibleForOfflineBake else {
                throw SceneOfflineBakeError.ineligible
            }
        }
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
        guard let eligibility = record.sceneBakeEligibility, eligibility.isEligibleForOfflineBake else {
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
                  let eligibility = record.sceneBakeEligibility,
                  eligibility.isEligibleForOfflineBake else { return }
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
}
