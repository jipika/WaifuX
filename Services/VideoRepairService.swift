import AVFoundation
import Foundation

/// AVFoundation 与 ffmpeg 的容错差异兜底。
///
/// Workshop 视频里存在一类「内容完好但 MP4 元数据损坏」的文件（实测 2026-11-05
/// workshop_3729465875：视频轨 `edts.elst.entry_count` 被写成 `0x10000001`）：
/// ffmpeg 按盒子实际尺寸容错解析、完全可读；AVFoundation 按计数解析则直接
/// `-11869 Cannot Open`，AVAssetImageGenerator / AVPlayerItem 全部静默失败，
/// 表现为「设了壁纸但桌面不动、抽帧 genMS≈1 全部 ok=0」。重下载无法修复——
/// Steam 分发的字节就是这份。
///
/// 设置壁纸前对候选视频统一走本服务校验：AVFoundation 能打开直接放行；打不开
/// 且是本地文件时，用内置 ffmpeg `-c copy` 无损转封装重建 moov，产物存
/// `Application Support/WaifuX/VideoRepairs/`（键 = 文件名+大小+mtime），修复后
/// 仍打不开才报错上浮。纯 remux 秒级完成、不重编码，跨机复用无成本。
enum VideoRepairService {

    // MARK: - 错误

    enum RepairError: LocalizedError {
        case sourceMissing
        case ffmpegNotFound
        case ffmpegFailed(exit: Int32, stderrTail: String)
        case stillUnplayable

        var errorDescription: String? {
            switch self {
            case .sourceMissing:
                return t("壁纸视频文件不存在，请重新下载后再试。")
            case .ffmpegNotFound:
                return t("内置 ffmpeg 缺失，无法自动修复无法播放的壁纸视频。")
            case .ffmpegFailed(let exit, _):
                return String(format: t("壁纸视频自动修复失败（编码工具退出码 %@），无法设置该壁纸。"), String(describing: exit))
            case .stillUnplayable:
                return t("该壁纸视频无法被播放器解码且自动修复无效，请卸载此壁纸并反馈。")
            }
        }
    }

    // MARK: - 对外入口

    /// 返回一个 AVFoundation 可打开的视频 URL：源可播返回原 URL；不可播且可修复
    /// 时返回缓存副本。文件不存在（交由上层既有守卫报「视频文件不存在」）与源在
    /// 容器外的场景不参与修复。
    static func playableVideoURL(for original: URL) async throws -> URL {
        guard original.isFileURL else { return original }
        guard FileManager.default.fileExists(atPath: original.path) else { return original }

        if await canAVFoundationOpen(original) {
            return original
        }

        AppLogger.error(.wallpaper, "[VideoRepair] AVFoundation 无法打开壁纸视频，启动转封装修复", metadata: [
            "video": original.lastPathComponent,
            "path": original.path,
        ])

        let repaired = try await remux(original: original)
        guard await canAVFoundationOpen(repaired) else {
            AppLogger.error(.wallpaper, "[VideoRepair] 转封装后仍不可播，放弃修复", metadata: [
                "video": original.lastPathComponent,
                "repairedPath": repaired.path,
            ])
            throw RepairError.stillUnplayable
        }
        return repaired
    }

    // MARK: - AVFoundation 可播性探测

    private static func canAVFoundationOpen(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0 else { return false }
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard videoTracks.first != nil else { return false }
            return true
        } catch {
            return false
        }
    }

    // MARK: - 转封装产品缓存

    private static let repairsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("VideoRepairs", isDirectory: true)
    }()

    private static let maxKeptRepairs = 6

    /// 缓存键：文件名.大小.修改时间戳_.mp4。源字节不变即命中，源更新（重下载）
    /// 自动失效。
    private static func repairDestination(for original: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: original.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            .map { Int($0) } ?? 0
        let name = original.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        return repairsDirectory
            .appendingPathComponent("\(name).s\(size).t\(mtime).mp4")
    }

    private static func trimCache(keeping newest: URL?) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: repairsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        var entries = contents
        if let newest { entries.removeAll { $0 == newest } }
        guard entries.count > maxKeptRepairs else { return }
        let sorted = entries.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            return db > da // 新的在前
        }
        for stale in sorted.dropFirst(maxKeptRepairs) {
            try? fm.removeItem(at: stale)
        }
    }

    // MARK: - ffmpeg 转封装

    /// 定位内置 ffmpeg（与 AnimeDownloadEngine.locateFFmpeg 同源策略，但自足实现：
    /// 主 App 与 Helper 两个 target 都要能编译本文件）。优先宿主 App 的
    /// Contents/Resources（Helper 进程经 WaifuXHostBundle 定位），再试自身
    /// bundle 嵌套/扁名，Debug 源码运行回退仓库 Resources/ffmpeg。
    private static func locateFFmpeg() -> URL {
        let fm = FileManager.default
        for candidate in WaifuXHostBundle.resourceCandidates(named: "ffmpeg") {
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        if let resourceURL = Bundle.main.resourceURL {
            let nested = resourceURL.appendingPathComponent("Resources/ffmpeg")
            if fm.isExecutableFile(atPath: nested.path) { return nested }
            let flat = resourceURL.appendingPathComponent("ffmpeg")
            if fm.isExecutableFile(atPath: flat.path) { return flat }
        }
        #if DEBUG
        if #filePath.hasSuffix("/WallHaven/Services/VideoRepairService.swift") {
            let repo = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Services
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("Resources/ffmpeg")
            if fm.isExecutableFile(atPath: repo.path) { return repo }
        }
        #endif
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/ffmpeg")
    }

    /// 并发闸门：同一源同时只跑一次 ffmpeg，后来者等待已有任务的结果。
    private actor RepairGate {
        private var tasks: [String: Task<URL, Error>] = [:]

        func result(for key: String, make: () -> Task<URL, Error>) async throws -> URL {
            if let existing = tasks[key] {
                return try await existing.value
            }
            let task = make()
            tasks[key] = task
            do {
                let value = try await task.value
                tasks[key] = nil
                return value
            } catch {
                tasks[key] = nil
                throw error
            }
        }
    }

    private static let gate = RepairGate()

    private static func remux(original: URL) async throws -> URL {
        let destination = repairDestination(for: original)
        let fm = FileManager.default
        // 既有缓存命中（并发或历史轮次产物）直接复用。
        if let attrs = try? fm.attributesOfItem(atPath: destination.path),
           let size = attrs[.size] as? NSNumber, size.intValue > 0 {
            return destination
        }
        do {
            return try await gate.result(for: destination.path) {
                Task<URL, Error> {
                    try await runFFmpegRemux(original: original, destination: destination)
                }
            }
        } catch let error as RepairError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RepairError.stillUnplayable
        }
    }

    private static func runFFmpegRemux(original: URL, destination: URL) async throws -> URL {
        let fm = FileManager.default
        let ffmpegURL = locateFFmpeg()
        guard fm.isExecutableFile(atPath: ffmpegURL.path) else {
            throw RepairError.ffmpegNotFound
        }
        try fm.createDirectory(at: repairsDirectory, withIntermediateDirectories: true)
        let temp = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(destination.lastPathComponent)")
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }

        let process = Process()
        process.executableURL = ffmpegURL
        // --disable-network 构建：输入只能是本地文件。-c copy 纯 remux 不重编码，
        // faststart 顺带把 moov 前置（抽取与锁屏 hard-link 都更快）。
        process.arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-i", original.path,
            "-c", "copy",
            "-movflags", "+faststart",
            temp.path,
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        let started = Date()
        try process.run()
        let drain = Task.detached(priority: .utility) {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        defer { drain.cancel() }

        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        } catch {
            process.terminate()
            try? fm.removeItem(at: temp)
            throw CancellationError()
        }
        let stderrTail = String(
            data: drain.isCancelled ? Data() : stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8)?.suffix(400) ?? ""

        guard process.terminationStatus == 0, fm.fileExists(atPath: temp.path) else {
            try? fm.removeItem(at: temp)
            throw RepairError.ffmpegFailed(exit: process.terminationStatus, stderrTail: String(stderrTail))
        }
        try? fm.replaceItemAt(destination, withItemAt: temp)

        AppLogger.info(.wallpaper, "[VideoRepair] 转封装完成", metadata: [
            "video": original.lastPathComponent,
            "ms": String(Int(Date().timeIntervalSince(started) * 1000)),
            "out": destination.lastPathComponent,
        ])
        trimCache(keeping: destination)
        return destination
    }
}
