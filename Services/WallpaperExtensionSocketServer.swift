//  WaifuX → 壁纸扩展 Unix Socket IPC 服务端
//
//  在主 App 中运行，监听 Unix Domain Socket，处理扩展的请求。
//  当前主要用于：
//  1. 向扩展暴露“显示器实例”列表，供用户在系统设置中手动选择
//  2. 在实例激活后注册 IOSurface，并按显示器持续推送桌面视频帧
//
//  协议：JSON-over-UDS
//    [4字节大端长度][JSON请求]
//    [4字节大端长度][JSON响应]

import AVFoundation
import Foundation
import os

private let appLog = OSLog(subsystem: "com.waifux.app", category: "ExtensionIPC")
private let appWillTerminateNotificationName = "com.waifux.app.wallpaper.appWillTerminate"
private let commandsChangedNotificationName = "com.waifux.app.wallpaper.commandsChanged"

// MARK: - IPC 协议类型（与服务端兼容）

/// 注意：这些类型必须与 WaifuXWallpaperExtension/UnixSocketClient.swift 中的
/// IPCRequest / IPCResponse / IPCVideoInfo 保持 JSON 字段名一致。

// MARK: - IPC 协议类型（服务端定义，与客户端兼容）

struct IPCRequest: Codable {
    let id: String
    let method: String
    let params: [String: String]?
}

struct IPCVideoInfo: Codable {
    let id: String
    let name: String
    let videoPath: String
    let thumbnailPath: String
}

struct IPCResponse: Codable {
    let id: String
    let videos: [IPCVideoInfo]?
    let videoPath: String?
    let error: String?
}

/// App 推送给扩展的命令。
/// 在“显示器实例 + 扩展本地解码”的模型下，命令用于热切换当前视频。
struct IPCCommand: Codable {
    let action: String
    let videoID: String?
    let displayID: UInt32?
}

/// Socket 文件路径
private var socketURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app")?
        .appendingPathComponent("socket/extension.ipc")
}

// MARK: - 服务端

/// 壁纸扩展 IPC 服务端 — 在主 App 中运行，处理来自扩展的 Unix Socket 请求。
///
/// 生命周期由 WaifuXApp/AppDelegate 管理。App 启动时 start()，退出时 stop()。
/// 可用显示器实例列表通过 `updateVideos(_:)` 设置。
final class WallpaperExtensionSocketServer: @unchecked Sendable {
    static let shared = WallpaperExtensionSocketServer()

    private var isRunning = false
    private let queue = DispatchQueue(label: "wallpaper-ext-ipc", qos: .userInitiated)

    /// 当前可用的锁屏实例列表（沿用 IPCVideoInfo 结构）
    private var availableVideos: [IPCVideoInfo] = []

    /// 挂起的命令队列（扩展 poll 时发送）
    private var pendingCommands: [IPCCommand] = []
    private let cmdLock = OSAllocatedUnfairLock(initialState: [IPCCommand]())

    /// 扩展注册的 IOSurface 表面（每显示器双缓冲）
    private var displaySurfaces: [UInt32: [IOSurfaceID]] = [:]
    private let surfLock = OSAllocatedUnfairLock(initialState: [UInt32: [IOSurfaceID]]())

    /// 显示器 → 当前桌面帧源（由 VideoWallpaperManager 同步）
    private var displayVideoMap: [UInt32: (videoID: String, videoURL: URL)] = [:]
    private let videoMapLock = OSAllocatedUnfairLock(initialState: [UInt32: (videoID: String, videoURL: URL)]())
    private let localDecodeVideoLock = OSAllocatedUnfairLock(initialState: [String: URL]())

    private init() {}

    /// 同步视频部署世代号。每调用一次 syncAllDisplayVideosToExtension 递增，
    /// 用于防止旧 Task 的 cacheMirroringSource/enqueueCommand 覆盖新 Task 的状态。
    private nonisolated(unsafe) static var _videoSyncGeneration: UInt64 = 0
    private static let genLock = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// 获取当前世代号并递增，返回新世代号。
    static func nextVideoSyncGeneration() -> UInt64 {
        genLock.withLock { gen in
            gen &+= 1
            _videoSyncGeneration = gen
            return gen
        }
    }

    /// 检查世代号是否匹配当前最新世代。
    static func isCurrentGeneration(_ generation: UInt64) -> Bool {
        genLock.withLock { $0 } == generation
    }

    /// App 调用此方法推送切换壁纸命令。
    /// 当前主路径是扩展本地解码，命令用于让扩展热切换到新的共享容器视频。
    /// - Parameter generation: 视频同步世代号，0 表示不检查（兼容旧调用方）。
    func enqueueCommand(_ command: IPCCommand, generation: UInt64 = 0) {
        // 世代号不匹配说明来自旧 Task，丢弃
        if generation != 0, !Self.isCurrentGeneration(generation) {
            os_log(.debug, log: appLog, "丢弃过期命令 generation=%llu", generation)
            return
        }
        cmdLock.withLock { $0.append(command) }
        os_log(.info, log: appLog, "入队命令: %@ display=%d gen=%llu", command.action, command.displayID ?? 0, generation)
        notifyCommandsChanged()
    }

    private func notifyCommandsChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(commandsChangedNotificationName as CFString),
            nil,
            nil,
            true
        )
    }

    /// 清空所有挂起命令。
    func clearCommands() {
        cmdLock.withLock { $0.removeAll() }
        os_log(.info, log: appLog, "已清空所有挂起命令")
    }

    /// 注册扩展本地解码可直接读取的视频路径。
    func registerLocalDecodeVideo(videoID: String, videoURL: URL) {
        localDecodeVideoLock.withLock { $0[videoID] = videoURL }
        os_log(.info, log: appLog, "注册本地解码视频: %{public}@ path=%{public}@", videoID, videoURL.path)
    }

    /// 清空所有本地解码视频注册。清理锁屏实例时调用，防止扩展通过 get_video_path 获取已删除的视频路径。
    func clearLocalDecodeVideos() {
        localDecodeVideoLock.withLock { $0.removeAll() }
        os_log(.info, log: appLog, "已清空所有本地解码视频注册")
    }

    /// 清空所有已注册的 IOSurface（锁屏实例清理时调用）。
    /// 扩展会在此后的 acquire 中重新注册 surface。
    func clearSurfaces() {
        surfLock.withLock { $0.removeAll() }
        os_log(.info, log: appLog, "已清空所有已注册 IOSurface")
    }

    /// 更新可用锁屏实例列表。
    func updateVideos(_ videos: [IPCVideoInfo]) {
        availableVideos = videos
    }

    /// 兼容旧帧推送管线的显示器视频映射。自解码主链路不再主动注册或启动该映射。
    func registerDisplayVideo(displayID: UInt32, videoID: String, videoURL: URL) {
        videoMapLock.withLock { $0[displayID] = (videoID, videoURL) }
        // 重置该 display 的重试计数：新视频意味着新一轮尝试
        retryLock.lock()
        pendingRetries[displayID]?.cancel()
        pendingRetries.removeValue(forKey: displayID)
        retryCounts.removeValue(forKey: displayID)
        retryLock.unlock()
        // 检查 surface 是否已注册，若是则立即启动推送
        startPusherIfNeeded(displayID: displayID)
    }

    /// 移除显示器对应的视频映射
    func unregisterDisplayVideo(displayID: UInt32) {
        videoMapLock.withLock { $0[displayID] = nil }
        // 取消该 display 的待处理重试
        retryLock.lock()
        pendingRetries[displayID]?.cancel()
        pendingRetries[displayID] = nil
        retryLock.unlock()
        DispatchQueue.main.async {
            LockScreenFramePusher.shared.stopPushing(displayID: displayID)
        }
    }

    /// 清空所有显示器的桌面帧源映射，并停止所有推帧会话。
    /// 注意：不清除已注册的 IOSurface ID（surface 属于扩展侧，切换视频时仍然有效）。
    func clearDisplayVideos() {
        videoMapLock.withLock { $0.removeAll() }
        // 不清除 surfLock — surface 是扩展创建的，切换视频时仍然有效。
        // 旧的 frame pusher 会被 stopAll() 终止，新视频注册后可直接复用已有 surface。
        // 取消所有待处理重试
        retryLock.lock()
        for (_, work) in pendingRetries { work.cancel() }
        pendingRetries.removeAll()
        retryCounts.removeAll()
        retryLock.unlock()
        // 清空挂起命令，防止旧 Task 入队的过期命令在扩展 poll 时被处理
        clearCommands()
        DispatchQueue.main.async {
            LockScreenFramePusher.shared.stopAll()
        }
    }

    /// 通知系统托管的 Wallpaper Extension：主 App 正在退出，
    /// 保留现有 CAContext 并切换为扩展自托管桌面播放。
    func notifyAppWillTerminate() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(appWillTerminateNotificationName as CFString),
            nil,
            nil,
            true
        )
        os_log(.info, log: appLog, "已广播 App 即将退出通知")
    }

    /// 通知扩展重载：App 更新后启动时调用，旧扩展进程退出后 macOS WallpaperAgent 从新 bundle 重新加载。
    func notifyExtensionReload() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.waifux.app.wallpaper.extensionReload" as CFString),
            nil,
            nil,
            true
        )
        os_log(.info, log: appLog, "已广播扩展重载通知")
    }

    /// 检查扩展是否已有活跃的渲染管线（任何显示器）。
    /// 如果已有活跃管线，App 不应自动切换视频或设置静态桌面壁纸。
    var hasActivePipeline: Bool {
        surfLock.withLock { !$0.isEmpty }
    }

    /// 检查指定显示器是否有活跃管线。
    func hasActivePipeline(for displayID: UInt32) -> Bool {
        surfLock.withLock { $0[displayID] != nil }
    }

    /// 扩展是否已注册本地解码视频（自解码模式下扩展自身解码播放）。
    /// 只要有任何注册记录就说明扩展已连接并正常工作，即使 surface 可能因时序未注册。
    var hasLocalDecodeVideos: Bool {
        localDecodeVideoLock.withLock { !$0.isEmpty }
    }

    /// 健康检查：确保所有已注册 surface + video 的显示器都有活跃的帧推送会话。
    /// 如果某个显示器既有 surface 又有 video 但没有 pusher，自动启动。
    /// 用于从主窗口关闭等异常场景中恢复。
    func performHealthCheck() {
        let displayIDs = surfLock.withLock { Array($0.keys) }
        for did in displayIDs {
            guard let videoInfo = videoMapLock.withLock({ $0[did] }) else { continue }
            guard FileManager.default.fileExists(atPath: videoInfo.videoURL.path) else { continue }
            let surfaces = surfLock.withLock { $0[did] ?? [] }
            guard !surfaces.isEmpty else { continue }
            if !LockScreenFramePusher.shared.isPushing(displayID: did) {
                os_log(.info, log: appLog, "🩺 健康检查：display=%d 有 surface+video 但无 pusher，自动恢复", did)
                DispatchQueue.main.async {
                    LockScreenFramePusher.shared.startPushing(
                        displayID: did,
                        videoURL: videoInfo.videoURL,
                        surfaceIDs: surfaces
                    )
                }
            }
        }
    }

    /// 检查指定显示器是否 surface 和视频都就绪，是则启动帧推送
    private func startPusherIfNeeded(displayID: UInt32) {
        let surfaces = surfLock.withLock { $0[displayID] ?? [] }
        guard !surfaces.isEmpty else {
            os_log(.debug, log: appLog, "startPusherIfNeeded: display=%d 等待 surface 注册（当前 video=%{public}@）", displayID, videoMapLock.withLock { $0[displayID]?.videoID ?? "nil" })
            scheduleRetry(displayID: displayID, reason: "waiting for surfaces")
            return
        }
        let videoInfo = videoMapLock.withLock { $0[displayID] }
        guard let (videoID, videoURL) = videoInfo else {
            os_log(.debug, log: appLog, "startPusherIfNeeded: display=%d 等待 video 注册（已有 %d 个 surface）", displayID, surfaces.count)
            scheduleRetry(displayID: displayID, reason: "waiting for video")
            return
        }
        // 验证视频文件存在且为普通文件（非目录）
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: videoURL.path, isDirectory: &isDirectory) else {
            os_log(.error, log: appLog, "startPusherIfNeeded: display=%d video 文件不存在: %{public}@", displayID, videoURL.path)
            return
        }
        guard !isDirectory.boolValue else {
            os_log(.error, log: appLog, "startPusherIfNeeded: display=%d video 路径是目录而非文件: %{public}@", displayID, videoURL.path)
            return
        }
        // 在主线程启动帧推送（LockScreenFramePusher 内部会切后台队列）
        DispatchQueue.main.async {
            // 取消该 display 的待处理重试并重置计数
            self.retryLock.lock()
            self.pendingRetries[displayID]?.cancel()
            self.pendingRetries.removeValue(forKey: displayID)
            self.retryCounts.removeValue(forKey: displayID)
            self.retryLock.unlock()
            LockScreenFramePusher.shared.startPushing(
                displayID: displayID,
                videoURL: videoURL,
                surfaceIDs: surfaces
            )
            os_log(.info, log: appLog, "🔄 surface 就绪 → 自动启动帧推送 display=%d video=%{public}@", displayID, videoID)
        }
    }

    /// 定期重试启动帧推送（处理 surface 和 video 异步注册的竞态）
    private var pendingRetries: [UInt32: DispatchWorkItem] = [:]
    private var retryCounts: [UInt32: Int] = [:]
    private let retryLock = NSLock()
    private let maxRetries = 30  // 最多 30 次（~30 秒），之后静默等待 acquire() 触发注册

    /// 供 LockScreenFramePusher 调用：FramePusher 异常停止后尝试自动恢复。
    /// 与初始注册的重试分开计数，避免被之前的重试耗尽配额。
    func scheduleRetryForRestart(displayID: UInt32) {
        retryLock.lock()
        // 重置重试计数：异常恢复是独立事件，不应受初始注册阶段的重试影响
        retryCounts.removeValue(forKey: displayID)
        pendingRetries[displayID]?.cancel()
        pendingRetries.removeValue(forKey: displayID)
        retryLock.unlock()
        scheduleRetry(displayID: displayID, reason: "FramePusher 异常停止，自动恢复")
    }

    private func scheduleRetry(displayID: UInt32, reason: String) {
        retryLock.lock()
        let count = (retryCounts[displayID] ?? 0) + 1
        retryCounts[displayID] = count

        if count <= maxRetries {
            pendingRetries[displayID]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                os_log(.debug, log: appLog, "🔄 重试启动帧推送 display=%d (attempt=%d, reason: %{public}@)", displayID, count, reason)
                self.startPusherIfNeeded(displayID: displayID)
            }
            pendingRetries[displayID] = work
            retryLock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0, execute: work)
        } else {
            retryLock.unlock()
            os_log(.info, log: appLog, "🛑 已达最大重试次数 display=%d (reason: %{public}@)，等待扩展 acquire() 触发注册", displayID, reason)
        }
    }

    /// 启动监听。在主 App 启动时调用。
    func start() {
        guard !isRunning else { return }
        guard let sockURL = socketURL else {
            os_log(.error, log: appLog, "无法获取共享容器 URL")
            return
        }

        let dir = sockURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 清理旧 socket 文件
        if FileManager.default.fileExists(atPath: sockURL.path) {
            try? FileManager.default.removeItem(at: sockURL)
        }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            os_log(.error, log: appLog, "socket() 失败: %d", errno)
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = sockURL.path.withCString { src in
            Darwin.strncpy(&addr.sun_path.0, src, MemoryLayout.size(ofValue: addr.sun_path))
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafeMutablePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, addrLen) } }) == 0 else {
            os_log(.error, log: appLog, "bind() 失败: %d", errno)
            close(sock)
            return
        }

        guard listen(sock, 5) == 0 else {
            os_log(.error, log: appLog, "listen() 失败: %d", errno)
            close(sock)
            return
        }

        isRunning = true

        // 非阻塞 accept
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        queue.async { [weak self] in
            self?.acceptLoop(sock)
        }

        os_log(.info, log: appLog, "已启动: %@", sockURL.path)
    }

    /// 停止监听。主 App 退出时调用。
    func stop() {
        isRunning = false
        fcLock.withLock { clients in
            for fd in clients {
                shutdown(fd, SHUT_RDWR)
                close(fd)
            }
            clients.removeAll()
        }
        if let sockURL = socketURL {
            try? FileManager.default.removeItem(at: sockURL)
        }
        os_log(.info, log: appLog, "已停止")
    }

    // MARK: - 请求处理

    private func handleRequest(_ data: Data) -> Data? {
        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: data) else {
            return nil
        }

        let response: IPCResponse

        switch request.method {
        case "list_videos":
            response = IPCResponse(
                id: request.id,
                videos: availableVideos.isEmpty ? nil : availableVideos,
                videoPath: nil,
                error: nil
            )

        case "get_video_path":
            guard let videoID = request.params?["videoID"] else {
                response = .init(id: request.id, videos: nil, videoPath: nil, error: "缺少 videoID")
                break
            }
            if let url = localDecodeVideoLock.withLock({ $0[videoID] }),
               FileManager.default.fileExists(atPath: url.path) {
                response = .init(id: request.id, videos: nil, videoPath: url.path, error: nil)
                break
            }
            guard let video = availableVideos.first(where: { $0.id == videoID }) else {
                response = .init(id: request.id, videos: nil, videoPath: nil, error: "未找到视频: \(videoID)")
                break
            }
            // 将视频用 hard link 放到共享容器（扩展只能访问共享容器）
            let linkedPath = copyVideoToSharedContainer(videoPath: video.videoPath, videoID: videoID)
            if let linkedPath {
                response = .init(id: request.id, videos: nil, videoPath: linkedPath, error: nil)
            } else {
                response = .init(id: request.id, videos: nil, videoPath: nil, error: "链接视频到共享容器失败")
            }

        case "set_active_video":
            // 扩展通知 App 用户选择了某个视频，提前链接到共享容器
            if let videoID = request.params?["videoID"],
               let video = availableVideos.first(where: { $0.id == videoID }) {
                os_log(.info, log: appLog, "预链接视频: %@", videoID)
                _ = copyVideoToSharedContainer(videoPath: video.videoPath, videoID: videoID)
            }
            response = .init(id: request.id, videos: nil, videoPath: nil, error: nil)

        case "register_surfaces":
            if let didStr = request.params?["displayID"], let did = UInt32(didStr),
               let id1Str = request.params?["surfaceID0"], let id1 = IOSurfaceID(id1Str),
               let id2Str = request.params?["surfaceID1"], let id2 = IOSurfaceID(id2Str) {
                // 检查 surface ID 是否真的变了（避免无意义的重启）
                let oldIDs = surfLock.withLock { $0[did] }
                let isNew = oldIDs == nil || oldIDs! != [id1, id2]
                surfLock.withLock { $0[did] = [id1, id2] }
                if isNew {
                    os_log(.info, log: appLog, "注册 surfaces: display=%d [%d, %d]", did, id1, id2)
                }
                os_log(.info, log: appLog, "register_surfaces: 自解码模式下仅确认 surface display=%d", did)
                response = .init(id: request.id, videos: nil, videoPath: nil, error: nil)
            } else {
                response = .init(id: request.id, videos: nil, videoPath: nil, error: "invalid_params")
            }


        case "poll_commands":
            // 扩展轮询挂起命令
            let cmd = cmdLock.withLock { commands -> IPCCommand? in
                guard !commands.isEmpty else { return nil }
                return commands.removeFirst()
            }
            // 响应体复用 videoPath 字段传输 JSON 编码的命令
            // 简单场景：最多返回一个命令
            if let cmd, let cmdData = try? JSONEncoder().encode(cmd) {
                let cmdStr = String(data: cmdData, encoding: .utf8)
                response = .init(id: request.id, videos: nil, videoPath: cmdStr, error: nil)
            } else {
                response = .init(id: request.id, videos: nil, videoPath: nil, error: nil)
            }

        default:
            response = IPCResponse(id: request.id, videos: nil, videoPath: nil, error: "未知方法: \(request.method)")
        }

        return try? JSONEncoder().encode(response)
    }

    // MARK: - 视频复制

    /// 从原始路径复制视频到共享容器，返回扩展可访问的路径。
    /// 返回 nil 表示复制失败。
    private func copyVideoToSharedContainer(videoPath: String, videoID: String) -> String? {
        // 防御：videoPath 为空时直接返回 nil（availableVideos 的 videoPath 通常为空）
        guard !videoPath.isEmpty else {
            os_log(.debug, log: appLog, "copyVideoToSharedContainer: videoPath 为空，跳过 videoID=%{public}@", videoID)
            return nil
        }
        let sourceURL = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            os_log(.error, log: appLog, "视频文件不存在: %@", videoPath)
            return nil
        }

        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
            return nil
        }

        let destDir = container.appendingPathComponent("WallpaperVideos/\(videoID)")
        let destURL = destDir.appendingPathComponent(sourceURL.lastPathComponent)

        // 已存在则跳过
        if FileManager.default.fileExists(atPath: destURL.path) {
            return destURL.path
        }

        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        do {
            // 使用 hard link 而非 copy，省空间省时间
            try FileManager.default.linkItem(at: sourceURL, to: destURL)
            os_log(.info, log: appLog, "已链接视频到共享容器: %@", destURL.path)
        } catch {
            // fallback: 实际复制
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                os_log(.info, log: appLog, "已复制视频到共享容器: %@", destURL.path)
            } catch {
                os_log(.error, log: appLog, "复制视频失败: %@", error.localizedDescription)
                return nil
            }
        }

        return destURL.path
    }

    // MARK: - 帧通道

    /// 帧通道客户端连接列表
    private var frameClients: [Int32] = []
    private let fcLock = OSAllocatedUnfairLock(initialState: [Int32]())

    /// 获取指定显示器注册的 IOSurface ID 列表
    func surfaceIDs(for displayID: UInt32) -> [IOSurfaceID] {
        surfLock.withLock { $0[displayID] ?? [] }
    }

    /// App 调用此方法推送一帧到扩展
    func pushFrame(displayID: UInt32, surfaceID: UInt32, pts: CMTime, duration: CMTime) {
        let durVal = UInt32(max(1, Int(duration.value * 600 / Int64(duration.timescale))))

        var packet = Data(count: 25)
        packet[0] = 0x01
        encodeUInt32LE(displayID, into: &packet, at: 1)
        encodeUInt32LE(surfaceID, into: &packet, at: 5)
        encodeUInt64LE(UInt64(pts.value), into: &packet, at: 9)
        encodeUInt32LE(UInt32(pts.timescale), into: &packet, at: 17)
        encodeUInt32LE(durVal, into: &packet, at: 21)

        let packetData = packet
        fcLock.withLock { clients in
            if clients.isEmpty {
                os_log(.debug, log: appLog, "丢弃帧：没有帧通道客户端 display=%d surface=%d", displayID, surfaceID)
                return
            }
            clients.removeAll { fd in
                let failed = !writeFully(fd, data: packetData)
                if failed {
                    os_log(.error, log: appLog, "推送帧失败 fd=%d expected=%d errno=%d", fd, packetData.count, errno)
                }
                return failed
            }
        }
    }

    private func writeFully(_ fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return false }
            var totalWritten = 0
            while totalWritten < ptr.count {
                let n = write(fd, base + totalWritten, ptr.count - totalWritten)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                totalWritten += n
            }
            return true
        }
    }

    private func encodeUInt32LE(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func encodeUInt64LE(_ value: UInt64, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
        data[offset + 4] = UInt8((value >> 32) & 0xFF)
        data[offset + 5] = UInt8((value >> 40) & 0xFF)
        data[offset + 6] = UInt8((value >> 48) & 0xFF)
        data[offset + 7] = UInt8((value >> 56) & 0xFF)
    }

    /// 处理帧通道订阅：保持连接打开，持续推送帧事件
    private func handleFrameChannel(client: Int32) {
        // 防止写入已断开的 socket 时触发 SIGPIPE 导致 App 崩溃
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        fcLock.withLock { clients in
            for fd in clients {
                close(fd)
            }
            clients.removeAll()
            clients.append(client)
        }
        os_log(.info, log: appLog, "帧通道已连接 (fd=%d)", client)
    }

    // MARK: - Socket 循环

    private func acceptLoop(_ sock: Int32) {
        defer { close(sock) }

        while isRunning {
            var addr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(sock, $0, &addrLen) } })

            guard client >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(100_000) // 100ms
                    continue
                }
                if isRunning { os_log(.error, log: appLog, "accept 错误: %d", errno) }
                break
            }

            // 防止写入已断开的 socket 时触发 SIGPIPE 导致 App 崩溃
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            // 读取 4 字节长度前缀
            var lenBytes: UInt32 = 0
            guard read(client, &lenBytes, 4) == 4 else { close(client); continue }
            let payloadLen = Int(UInt32(bigEndian: lenBytes))
            guard payloadLen > 0, payloadLen < 1_000_000 else { close(client); continue }

            // 读取 payload
            let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: payloadLen, alignment: 1)
            defer { buf.deallocate() }
            var totalRead = 0
            while totalRead < payloadLen {
                let n = read(client, buf.baseAddress! + totalRead, payloadLen - totalRead)
                guard n > 0 else { break }
                totalRead += n
            }

            // 检查是否帧通道订阅请求（兼容 16/17 字节：含或不含 \0 结尾）
            let expectedData = "subscribe_frames".data(using: .utf8)!
            if payloadLen == expectedData.count || payloadLen == expectedData.count + 1 {
                let receivedData = Data(bytes: buf.baseAddress!, count: expectedData.count)
                if receivedData == expectedData {
                    handleFrameChannel(client: client)
                    continue
                }
            }

            let payload = Data(bytes: buf.baseAddress!, count: payloadLen)
            if let responseData = handleRequest(payload) {
                var respLen = UInt32(responseData.count).bigEndian
                write(client, &respLen, 4)
                _ = responseData.withUnsafeBytes { ptr in
                    write(client, ptr.baseAddress!, responseData.count)
                }
            }
            close(client)
        }
    }
}
