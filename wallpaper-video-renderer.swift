// wallpaper-video-renderer.swift
//
// 视频壁纸独立渲染子进程。
// 将 AVPlayer + 桌面层 NSWindow 从主进程隔离到独立进程，
// 使主进程不再持有 onscreen 窗口，从而不被 Screen Time 计入使用时长。
//
// 架构（对齐 wallpaper-wgpu / wallpaperengine-cli 的进程隔离模式）：
//   主进程 WaifuX（accessory，无可见窗口）
//     └─ Unix Socket IPC → wallpaper-video-renderer（本进程，LSUIElement）
//           ├─ 屏A: AVPlayerLayer + 桌面层 NSWindow
//           ├─ 屏B: AVPlayerLayer + 桌面层 NSWindow（可与屏A共享 AVQueuePlayer）
//           └─ 内部完整保留多屏共享解码逻辑
//
// 编译：./scripts/build-wallpaper-video-renderer.sh
// 运行：由 VideoWallpaperManager 通过 Process 启动，传入 socket 路径参数。

import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import ExceptionHandling
import Foundation
import os

// MARK: - 日志（子进程独立，不依赖主进程 AppLogger）

private let logger = Logger(subsystem: "com.waifux", category: "video-renderer")

private enum LogCategory { case wallpaper }
private enum AppLogger {
    static func info(_ cat: LogCategory, _ msg: String, metadata: [String: String]? = nil) {
        logger.info("\(msg, privacy: .public)")
    }
    static func error(_ cat: LogCategory, _ msg: String) {
        logger.error("\(msg, privacy: .public)")
    }
}

// MARK: - 常量

private let SOCKET_PATH_ARG = "--socket"
private let PARENT_PID_ARG = "--parent-pid"
private let VERSION_ARG = "--version"
private let DAEMON_PID_ENV = "WAIFUX_VIDEO_RENDERER_PID_PATH"

/// 单帧 IPC body 上限（8MB，与 wallpaperengine-cli 一致，预留 poster base64 等大 payload）
private let MAX_FRAME_BYTES = 8 * 1024 * 1024

/// The host and the standalone renderer do not necessarily receive
/// `NSScreen.screens` in the same raw order. Resolve each `set` by the stable
/// display identifier first, then use this deterministic order for renderer
/// local screen bookkeeping.
private enum RendererScreenIdentity {
    static func identifier(for screen: NSScreen) -> String {
        if let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber {
            return screenNumber.stringValue
        }
        return "\(screen.localizedName):\(screen.frame.origin.x):\(screen.frame.origin.y)"
    }

    static func fingerprint(for screen: NSScreen) -> String {
        guard let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return "fallback:\(screen.localizedName):\(Int(screen.frame.width))x\(Int(screen.frame.height)):position:\(Int(screen.frame.origin.x.rounded()))x\(Int(screen.frame.origin.y.rounded()))"
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let builtin = CGDisplayIsBuiltin(displayID) != 0 ? "builtin" : "external"
        if serial != 0 {
            return "cg:\(vendor):\(model):\(serial):\(builtin)"
        }
        let pixelWidth = Int(screen.frame.width * screen.backingScaleFactor)
        let pixelHeight = Int(screen.frame.height * screen.backingScaleFactor)
        return "cg:\(vendor):\(model):noserial:\(screen.localizedName):\(pixelWidth)x\(pixelHeight):\(builtin):position:\(Int(screen.frame.origin.x.rounded()))x\(Int(screen.frame.origin.y.rounded()))"
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
                return lhs.frame.maxY > rhs.frame.maxY
            }

            return identifier(for: lhs) < identifier(for: rhs)
        }
    }

    static func resolvedIndex(
        proposedIndex: Int,
        stableID: String
    ) -> Int {
        let ordered = orderedScreens(NSScreen.screens)
        if let index = ordered.firstIndex(where: {
            identifier(for: $0) == stableID
        }) {
            return index
        }
        if let index = ordered.firstIndex(where: {
            fingerprint(for: $0) == stableID
        }) {
            return index
        }
        if ordered.indices.contains(proposedIndex) {
            return proposedIndex
        }
        return proposedIndex
    }
}

// MARK: - IPC 协议

/// 主进程 → 子进程的命令枚举
private enum IPCCommand: String, Codable {
    case set            // 设置/切换壁纸
    case pause
    case resume
    case stop           // 停止指定屏或全部
    case seek
    case setVolume
    case setMuted
    case setRate
    case setCrop        // crop pan/zoom（高频，fire-and-forget + revision）
    case updatePoster   // 更新封面路径但不改变当前显示状态
    case showPoster     // 显示封面图
    case hidePoster
    case setGrainOverlay
    case bringToFront
    case revealPreparedWindow
    case commitTransition
    case cancelTransition
    case forceCommit
    case pruneInactiveScreens
    case prewarm        // 预建下一张播完即换视频的解码管线（preroll 暖机，不挂窗口）
    case ping           // 存活探测
    case refreshPlaybackState // 重新读取主进程共享的锁屏/唤醒状态
    case shutdown       // 优雅退出
}

/// 子进程 → 主进程的上报事件
private enum IPCEvent: String, Codable {
    case ready              // daemon 已就绪
    case windowCreated      // 某屏窗口已创建
    case firstFrameReady    // 某屏首帧已就绪（触发跨类型交接）
    case playbackEnded      // 某屏播放结束（触发播完即换）
    case error              // 错误上报
    case stopped            // 某屏已停止
}

/// IPC 消息体（扁平 Codable struct，命令字段决定哪些参数有效）
// MARK: - 切换路径诊断打点（定位黑闪用，问题解决后移除）

private let vrLogStart = Date()
private func vlog(_ msg: String) {
    let ms = Int(Date().timeIntervalSince(vrLogStart) * 1000)
    FileHandle.standardError.write(Data("WAIFUX_DIAG:+\(ms)ms \(msg)\n".utf8))
}

private struct IPCMessage: Codable {
    var command: IPCCommand
    /// Fire-and-forget 命令不需要服务端回包。高频 crop/前台调整不再因为
    /// 客户端已关闭写端而挤占 renderer 主线程或产生无意义的 EPIPE。
    var expectsResponse: Bool?
    // 通用
    var screen: Int?            // 目标屏索引（NSScreen.screens 的稳定排序索引）
    var screenID: String?       // 主进程稳定屏幕标识，事件回传优先使用
    var requestID: String?      // 当前 set/reload 请求 ID，过滤迟到事件
    // set
    var path: String?           // 视频文件路径
    var screenFrameX: Double?
    var screenFrameY: Double?
    var screenFrameW: Double?
    var screenFrameH: Double?
    var muted: Bool?
    var volume: Double?
    var rate: Double?
    var audioEffectiveVolume: Double?
    var audioOutputDeviceStrategy: String?
    var audioOutputDeviceUniqueID: String?
    var enableLooping: Bool?    // 是否循环播放（false = 播完即换模式）
    var usesSharedDecoder: Bool? // 是否使用全局共享解码器
    var forceNewPipeline: Bool? // 同路径文件被原子替换时强制重建 AVPlayerItem
    var hdrMetadataEnabled: Bool?
    var deferredPresentation: Bool?
    var transitionDuration: Double?
    var globalPaused: Bool?
    var screenPaused: Bool?
    var globalDisplaySyncEnabled: Bool?
    // seek
    var time: Double?
    // setCrop
    var cropX: Double?
    var cropY: Double?
    var cropW: Double?
    var cropH: Double?
    var viewportX: Double?
    var viewportY: Double?
    var viewportW: Double?
    var viewportH: Double?
    var letterboxColorHex: String?
    var cropRevision: UInt64?
    // showPoster
    var posterPath: String?
    // setGrainOverlay
    var grainIntensity: Double?
    // pruneInactiveScreens
    var activeScreenIDs: [String]?
    // error
    var message: String?
}

/// 上报事件体
private struct IPCEventMessage: Codable {
    var event: IPCEvent
    var screen: Int?
    var screenID: String?
    var requestID: String?
    var message: String?
}

// MARK: - Daemon 主类

/// 视频壁纸渲染 daemon：管理多屏窗口 + AVPlayer，通过 Unix Socket IPC 接收命令。
@MainActor
private final class VideoRendererDaemon {
    static let shared = VideoRendererDaemon()

    // MARK: 多屏状态（原样保留 VideoWallpaperManager 的共享解码逻辑）

    /// 每屏的窗口 + 容器视图
    private var screenStates: [Int: ScreenState] = [:]

    /// 每屏的 AVQueuePlayer（可能被多屏共享）
    private var players: [Int: AVQueuePlayer] = [:]
    /// 每屏的 AVPlayerLooper（非播完即换模式才有）
    private var loopers: [Int: AVPlayerLooper] = [:]
    /// 每屏的 AVPlayerItem
    private var items: [Int: AVPlayerItem] = [:]
    /// 播完即换预热管线（每屏至多一条）：播放当前视频期间预建下一条的
    /// 解码器并 preroll，下一次 set 命中时直接复用，首帧无需现场解码。
    private var prewarmedPipelines: [Int: PrewarmedPipeline] = [:]
    /// 预热管线的 player.status 观察：status 就绪前调用 preroll 会抛
    /// NSInvalidArgumentException 并楔死 IPC 处理循环（实测事故），
    /// 必须由 KVO 门控到 .readyToPlay 之后才允许 preroll。
    private var prewarmStatusObservers: [Int: NSKeyValueObservation] = [:]

    // 共享解码
    private var usesSharedVideoDecoder = false
    /// The host scheduler decides whether an end event advances all displays
    /// as one group or advances each display independently.
    private var isGlobalDisplaySyncEnabled = false
    /// 机会式共享上限（同刷新率屏共享超过 2 块时新建独立 player，避免 VSync 对齐压力）
    private let maxOpportunisticShareScreenCount = 2

    // 全局状态
    private var isMuted = true
    private var volume: Float = 1.0
    private var volumeByScreen: [Int: Float] = [:]
    private var playbackRate: Float = 1.0
    private var playbackRateByScreen: [Int: Float] = [:]
    private var isPaused = false
    private var manualPausedScreens = Set<Int>()
    private var systemPlaybackPaused = false
    private var systemPlaybackStateShowPoster = false
    private var systemPlaybackStateGeneration: UInt64?
    private var audioOutputDeviceStrategy = "systemDefault"
    private var audioOutputDeviceUniqueID: String?
    private var playbackStateObserver: NSObjectProtocol?
    private var playbackStateFilePath: String?

    // IPC
    private var serverSocket: Int32 = -1
    private var socketPath: String = ""
    private var clientSocket: Int32 = -1  // 主进程连接（用于上报事件）
    private nonisolated(unsafe) var keepRunning = true
    private var signalSources: [DispatchSourceSignal] = []
    private var parentWatchdog: DispatchSourceTimer?
    private var parentExitSource: DispatchSourceProcess?
    /// Commands arrive over short-lived Unix sockets. Process each fully before
    /// accepting the next one so fire-and-forget maintenance commands cannot
    /// overtake a later `set` and freeze its newly-created player.
    private let commandIngressQueue = DispatchQueue(
        label: "com.waifux.video-renderer.command-ingress",
        qos: .userInitiated
    )
    private var commandSequence: UInt64 = 0

    // 播放结束观察者
    private var playbackEndObservers: [Int: NSObjectProtocol] = [:]
    private var onEndModeScreens = Set<Int>()

    // 首帧就绪 KVO
    private var firstFrameObservers: [Int: NSKeyValueObservation] = [:]
    /// `AVPlayer.preroll` throws an Objective-C exception while the player is
    /// still loading. Wake recovery can rebuild a pipeline before
    /// `AVPlayerStatusReadyToPlay`, so defer the initial preroll/play decision
    /// until the player reports a usable status.
    private var playbackStatusObservers: [Int: NSKeyValueObservation] = [:]
    private var screenGenerations: [Int: UInt64] = [:]
    private var pendingReplacements: [Int: PendingReplacement] = [:]
    private var pendingSharedFollowerScreensByPlayerID: [ObjectIdentifier: Set<Int>] = [:]
    private var sharedFollowerAttachmentTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    struct ScreenState {
        var screenID: String
        /// Stable physical-display fingerprint captured when this state was
        /// bound. NSScreenNumber can change after sleep/reconnect, so the
        /// renderer must not treat a changed numeric ID as a new window.
        var screenFingerprint: String?
        var requestID: String
        var window: NSWindow?
        var containerView: VideoContainerView?
        var videoURL: URL?
        var posterPath: String?
        var screenFrame: CGRect
        var generation: UInt64
        var lastCropRevision: UInt64
        /// Cross-type video warmups keep the renderer window transparent until
        /// the host has snapshotted and retired the old Scene/Web/static layer.
        var deferWindowReveal: Bool
    }

    private struct ReplacementSource {
        let state: ScreenState
        let player: AVQueuePlayer?
        let looper: AVPlayerLooper?
        let item: AVPlayerItem?
        let wasOnEndMode: Bool
    }

    private struct PendingReplacement {
        let requestID: String
        let screen: Int
        let oldState: ScreenState
        let oldPlayer: AVQueuePlayer
        let oldLooper: AVPlayerLooper?
        let oldItem: AVPlayerItem?
        let oldWasOnEndMode: Bool
        let newPlayer: AVQueuePlayer
        let newLooper: AVPlayerLooper?
        let newItem: AVPlayerItem
        let transitionDuration: TimeInterval
        let autoCommitOnReady: Bool
    }

    // MARK: 启动

    func run(socketPath: String, parentPID: pid_t?) {
        self.socketPath = socketPath
        AppLogger.info(.wallpaper, "video-renderer daemon 启动", metadata: ["socket": socketPath])
        installExceptionDiagnostics()

        // 写 PID 文件（主进程用于存活检测）
        let pidPath = ProcessInfo.processInfo.environment[DAEMON_PID_ENV]
            ?? "/tmp/waifux-video-renderer.pid"
        try? "\(getpid())".write(toFile: pidPath, atomically: true, encoding: .utf8)

        // 安装信号处理
        installSignalHandlers()
        installParentWatchdog(parentPID: parentPID)
        installPlaybackStateObservers()

        // 启动 IPC 服务端
        guard startServer(path: socketPath) else {
            AppLogger.error(.wallpaper, "video-renderer IPC 服务端启动失败")
            _exit(1)
        }

        // 向主进程上报 ready
        sendEvent(.ready, screen: nil, message: nil)

        // 运行 NSApplication run loop（AVPlayer 需要 run loop）
        NSApplication.shared.run()
    }

    // MARK: 锁屏 / 睡眠状态

    private struct ExternalPlaybackState: Decodable {
        let isScreenLocked: Bool
        let isDisplayAsleep: Bool
        let shouldPauseVideo: Bool
        let shouldShowPoster: Bool
        let transitionGeneration: UInt64?
    }

    private func installPlaybackStateObservers() {
        playbackStateFilePath = ProcessInfo.processInfo.environment["WAIFUX_VIDEO_RENDERER_LOCK_STATE_PATH"]
        playbackStateObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("com.waifux.wallpaper.lockScreenPlaybackStateDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPlaybackStateFromSharedSource()
            }
        }
        refreshPlaybackStateFromSharedSource()
    }

    @discardableResult
    private func refreshPlaybackStateFromSharedSource() -> Bool {
        guard let playbackStateFilePath else {
            return false
        }
        let url = URL(fileURLWithPath: playbackStateFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ExternalPlaybackState.self, from: data) else {
            AppLogger.error(.wallpaper, "video-renderer 无法读取锁屏状态文件: \(url.path)")
            return false
        }
        applySystemPlaybackState(
            paused: state.shouldPauseVideo,
            showPoster: state.shouldShowPoster,
            generation: state.transitionGeneration
        )
        return true
    }

    private func applySystemPlaybackState(
        paused: Bool,
        showPoster: Bool,
        generation: UInt64? = nil
    ) {
        let stateChanged = systemPlaybackPaused != paused
            || systemPlaybackStateShowPoster != showPoster
            || (generation != nil && systemPlaybackStateGeneration != generation)
        guard stateChanged else { return }
        systemPlaybackPaused = paused
        systemPlaybackStateShowPoster = showPoster
        if let generation {
            systemPlaybackStateGeneration = generation
        }

        var seen = Set<ObjectIdentifier>()
        for (screen, player) in players {
            if paused {
                if showPoster,
                   let posterPath = screenStates[screen]?.posterPath {
                    _ = screenStates[screen]?.containerView?.showPoster(path: posterPath)
                }
                screenStates[screen]?.containerView?.freezeForPause()
                guard seen.insert(ObjectIdentifier(player)).inserted else { continue }
                player.pause()
            } else if !isPaused && !manualPausedScreens.contains(screen) {
                screenStates[screen]?.containerView?.hidePoster()
                screenStates[screen]?.containerView?.resumeFromFreeze()
                guard seen.insert(ObjectIdentifier(player)).inserted else { continue }
                playWallpaperPlayer(player, rate: playbackRate(forScreen: screen))
                kickStalledPlayback(screen: screen, player: player)
            }
        }
    }

    // MARK: IPC 服务端

    private func startServer(path: String) -> Bool {
        // 移除旧 socket
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            AppLogger.error(.wallpaper, "video-renderer socket() 失败")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let sunPathSize = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let count = min(pathBytes.count - 1, sunPathSize - 1)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            for i in 0..<count {
                dest[i] = UInt8(bitPattern: pathBytes[i])
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            AppLogger.error(.wallpaper, "video-renderer bind() 失败: \(errno)")
            close(fd)
            return false
        }

        guard listen(fd, 5) == 0 else {
            AppLogger.error(.wallpaper, "video-renderer listen() 失败: \(errno)")
            close(fd)
            return false
        }

        serverSocket = fd
        AppLogger.info(.wallpaper, "video-renderer IPC 服务端已监听: \(path)")

        // 后台 accept 循环
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while self.keepRunning {
                let clientFd = accept(fd, nil, nil)
                if clientFd < 0 {
                    if errno == EINTR { continue }
                    break
                }
                self.commandIngressQueue.async {
                    self.handleClient(clientFd)
                }
            }
        }
        return true
    }

    private nonisolated func handleClient(_ fd: Int32) {
        // The client may time out and close before the main-thread command
        // finishes. Never let a late response terminate the renderer via SIGPIPE.
        var noSigPipe: Int32 = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        // 读取 4 字节长度（host byte order）
        var length: UInt32 = 0
        let headerSize = MemoryLayout<UInt32>.size
        var headerBuf = [UInt8](repeating: 0, count: headerSize)
        var bytesRead = 0
        while bytesRead < headerSize {
            let n = headerBuf.withUnsafeMutableBufferPointer { buf in
                read(fd, buf.baseAddress! + bytesRead, headerSize - bytesRead)
            }
            if n <= 0 {
                close(fd)
                return
            }
            bytesRead += n
        }
        memcpy(&length, headerBuf, headerSize)
        guard length > 0, length < MAX_FRAME_BYTES else {
            close(fd)
            return
        }

        // 读取 body
        var body = Data(count: Int(length))
        var bodyRead = 0
        while bodyRead < Int(length) {
            let n = body.withUnsafeMutableBytes { buf in
                read(fd, buf.baseAddress! + bodyRead, Int(length) - bodyRead)
            }
            if n <= 0 {
                close(fd)
                return
            }
            bodyRead += n
        }

        // 解码
        guard let msg = try? JSONDecoder().decode(IPCMessage.self, from: body) else {
            sendResponse(fd, "ERROR: invalid JSON")
            close(fd)
            return
        }

        // Keep this socket open until the main-actor command has completed.
        // The ingress queue waits here, which gives all IPC commands one
        // deterministic order instead of relying on concurrent Task scheduling.
        let completion = DispatchSemaphore(value: 0)
        Task { @MainActor in
            defer {
                close(fd)
                completion.signal()
            }
            guard self.keepRunning else { return }
            let commandID = self.nextCommandID()
            let startedAt = Date()
            let result = await self.handleCommand(msg)
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= 0.25 || result.hasPrefix("ERROR") {
                AppLogger.info(.wallpaper, "video-renderer IPC 完成", metadata: [
                    "id": String(commandID),
                    "command": msg.command.rawValue,
                    "screen": msg.screen.map(String.init) ?? "all",
                    "elapsed": String(format: "%.3f", elapsed),
                    "result": result
                ])
            }
            if msg.expectsResponse ?? true {
                self.sendResponse(fd, result)
            }
        }
        completion.wait()
    }

    private nonisolated func sendResponse(_ fd: Int32, _ text: String) {
        let data = text.data(using: .utf8) ?? Data()
        _ = data.withUnsafeBytes { buf in
            send(fd, buf.baseAddress, buf.count, 0)
        }
    }

    private func nextCommandID() -> UInt64 {
        commandSequence &+= 1
        return commandSequence
    }

    private func installExceptionDiagnostics() {
        NSSetUncaughtExceptionHandler { exception in
            let reason = exception.reason ?? "nil"
            let trace = exception.callStackSymbols.prefix(12).joined(separator: " | ")
            FileHandle.standardError.write(Data(
                "WAIFUX_FATAL_EXCEPTION:name=\(exception.name.rawValue) reason=\(reason) trace=\(trace)\n"
                    .utf8
            ))
        }

        guard let handler = NSExceptionHandler.default() else { return }
        handler.setDelegate(VideoRendererExceptionHandler.shared)
        handler.setExceptionHandlingMask(
            NSLogOtherExceptionMask
                | NSLogUncaughtExceptionMask
                | NSHandleUncaughtSystemExceptionMask
        )
    }

    // MARK: 命令处理

    private func resolvedScreenIndex(for msg: IPCMessage) -> Int? {
        guard let requestedScreen = msg.screen else { return nil }
        if let stableScreenID = msg.screenID,
           let existingKey = screenStates.first(where: {
               $0.value.screenID == stableScreenID
                   || $0.value.screenFingerprint == stableScreenID
           })?.key {
            return existingKey
        }
        if let fingerprint = currentFingerprint(matching: msg.screenID),
           let existingKey = screenStates.first(where: {
               $0.value.screenFingerprint == fingerprint
                   || currentFingerprint(matching: $0.value.screenID) == fingerprint
           })?.key {
            return existingKey
        }
        guard let stableScreenID = msg.screenID else {
            return requestedScreen
        }
        return RendererScreenIdentity.resolvedIndex(
            proposedIndex: requestedScreen,
            stableID: stableScreenID
        )
    }

    private func currentFingerprint(matching screenID: String?) -> String? {
        guard let screenID else { return nil }
        let ordered = RendererScreenIdentity.orderedScreens(NSScreen.screens)
        if let screen = ordered.first(where: {
            RendererScreenIdentity.identifier(for: $0) == screenID
                || RendererScreenIdentity.fingerprint(for: $0) == screenID
        }) {
            return RendererScreenIdentity.fingerprint(for: screen)
        }
        return nil
    }

    private func handleCommand(_ msg: IPCMessage) async -> String {
        // seek 命令需要 await，单独处理
        if msg.command == .seek {
            guard let screen = resolvedScreenIndex(for: msg),
                  let time = msg.time,
                  let player = players[screen] else {
                return "ERROR: missing seek params"
            }
            await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            return "OK"
        }
        switch msg.command {
        case .seek:
            // 已在前置 if 中处理，此处不会到达
            return "OK"

        case .ping:
            return "OK"

        case .refreshPlaybackState:
            return refreshPlaybackStateFromSharedSource()
                ? "OK"
                : "ERROR: playback state unavailable"

        case .set:
            guard let requestedScreen = msg.screen,
                  let path = msg.path,
                  let x = msg.screenFrameX, let y = msg.screenFrameY,
                  let w = msg.screenFrameW, let h = msg.screenFrameH else {
                return "ERROR: missing set params"
            }
            let stableScreenID = msg.screenID ?? "screen-index-\(requestedScreen)"
            let screen = resolvedScreenIndex(for: msg) ?? requestedScreen
            if screen != requestedScreen {
                AppLogger.info(
                    .wallpaper,
                    "video-renderer 校正跨进程屏幕索引",
                    metadata: [
                        "requested": String(requestedScreen),
                        "resolved": String(screen),
                        "screenID": stableScreenID
                    ]
                )
            }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            let screenFingerprint = currentScreenFingerprint(at: screen)
            guard FileManager.default.fileExists(atPath: path) else {
                return "ERROR: video file unavailable"
            }
            guard frame.width > 0, frame.height > 0 else {
                return "ERROR: invalid screen frame"
            }

            // A display reconnect can change NSScreenNumber while an old
            // state is still held under the previous local index. Rebinding
            // that display must leave exactly one desktop window behind;
            // otherwise the stale AVPlayer window can remain alive underneath
            // the new one and both timelines continue to advance.
            let duplicateScreens = screenStates.compactMap { key, state -> Int? in
                guard key != screen else { return nil }
                let sameID = state.screenID == stableScreenID
                    || state.screenFingerprint == stableScreenID
                let sameFingerprint = screenFingerprint != nil
                    && state.screenFingerprint == screenFingerprint
                guard sameID || sameFingerprint else { return nil }
                return key
            }.sorted()
            for duplicateScreen in duplicateScreens {
                AppLogger.info(.wallpaper, "video-renderer 清理同一显示器重复窗口", metadata: [
                    "screen": String(duplicateScreen),
                    "replacementScreen": String(screen),
                    "screenID": stableScreenID,
                    "fingerprint": screenFingerprint ?? "nil"
                ])
                teardownScreen(duplicateScreen)
            }

            if let staleState = screenStates[screen],
               staleState.screenID != stableScreenID {
                let newIDAlreadyOwned = screenStates.contains {
                    $0.key != screen && $0.value.screenID == stableScreenID
                }
                if newIDAlreadyOwned {
                    AppLogger.info(
                        .wallpaper,
                        "video-renderer 清理被新显示器占用的旧管线",
                        metadata: [
                            "screen": String(screen),
                            "oldScreenID": staleState.screenID,
                            "newScreenID": stableScreenID
                        ]
                    )
                    teardownScreen(screen)
                } else {
                    // 睡眠/重插后 NSScreenNumber 会变，但有序槽位通常还是同一块屏。
                    // 这时拆窗会露出黑底；只重绑稳定 ID，保住现有桌面窗。
                    AppLogger.info(
                        .wallpaper,
                        "video-renderer 重绑显示器稳定 ID",
                        metadata: [
                            "screen": String(screen),
                            "oldScreenID": staleState.screenID,
                            "newScreenID": stableScreenID
                        ]
                    )
                    screenStates[screen]?.screenID = stableScreenID
                    screenStates[screen]?.screenFingerprint = screenFingerprint
                }
            } else if let existing = screenStates[screen],
                      existing.screenID != stableScreenID,
                      currentFingerprint(matching: existing.screenID) != nil,
                      currentFingerprint(matching: existing.screenID)
                        == currentFingerprint(matching: stableScreenID) {
                screenStates[screen]?.screenID = stableScreenID
                screenStates[screen]?.screenFingerprint = screenFingerprint
            }
            let videoURL = URL(fileURLWithPath: path)
            let muted = msg.muted ?? self.isMuted
            let vol = msg.volume ?? Double(self.volume)
            let rate = msg.rate.map { max(0.5, min(2.0, $0)) } ?? Double(self.playbackRate)
            let looping = msg.enableLooping ?? true
            let shared = msg.usesSharedDecoder ?? false
            let forceNewPipeline = msg.forceNewPipeline ?? false
            let hdrMetadataEnabled = msg.hdrMetadataEnabled ?? false
            let deferredPresentation = msg.deferredPresentation ?? false
            let transitionDuration = msg.transitionDuration ?? 0.28
            let globalPaused = msg.globalPaused ?? false
            let screenPaused = msg.screenPaused ?? false
            let globalDisplaySyncEnabled = msg.globalDisplaySyncEnabled ?? false
            let requestID = msg.requestID ?? UUID().uuidString
            // 唤醒/解锁的分布式通知可能丢失或晚于主进程 reconfigure 的 set
            // 到达；每次 set 前重读共享状态文件对齐 systemPlaybackPaused，
            // 否则唤醒后新管线只 preroll 不播。
            refreshPlaybackStateFromSharedSource()
            updateAudioPolicy(
                muted: muted,
                volume: vol,
                strategy: msg.audioOutputDeviceStrategy,
                deviceUID: msg.audioOutputDeviceUniqueID
            )
            return await setWallpaper(screen: screen, videoURL: videoURL, screenFrame: frame,
                                      muted: muted, volume: vol, rate: rate, enableLooping: looping,
                                      usesSharedDecoder: shared,
                                      forceNewPipeline: forceNewPipeline,
                                      hdrMetadataEnabled: hdrMetadataEnabled,
                                      deferredPresentation: deferredPresentation,
                                      transitionDuration: transitionDuration,
                                      globalPaused: globalPaused,
                                      screenPaused: screenPaused,
                                      globalDisplaySyncEnabled: globalDisplaySyncEnabled,
                                      screenID: stableScreenID,
                                      requestID: requestID,
                                      posterPath: msg.posterPath)

        case .prewarm:
            guard let screen = resolvedScreenIndex(for: msg),
                  let path = msg.path else {
                return "ERROR: missing screen/path"
            }
            return prewarmPipeline(
                screen: screen,
                videoURL: URL(fileURLWithPath: path),
                volume: msg.volume ?? Double(volume),
                hdrMetadataEnabled: msg.hdrMetadataEnabled ?? false
            )

        case .pause:
            if let screen = resolvedScreenIndex(for: msg) {
                return pauseScreen(screen)
                    ? "OK"
                    : "ERROR: screen not found"
            } else {
                return pauseAll()
                    ? "OK"
                    : "ERROR: no active screens"
            }

        case .resume:
            if let screen = resolvedScreenIndex(for: msg) {
                return resumeScreen(screen)
                    ? "OK"
                    : "ERROR: screen not found"
            } else {
                return resumeAll()
                    ? "OK"
                    : "ERROR: no active screens"
            }

        case .stop:
            if let screen = resolvedScreenIndex(for: msg) {
                return stopScreen(screen)
                    ? "OK"
                    : "ERROR: screen not found"
            } else {
                return stopAll()
                    ? "OK"
                    : "ERROR: no active screens"
            }

        case .setVolume:
            let vol = msg.volume.map { max(0, min(1, $0)) } ?? Double(volume)
            if let screen = resolvedScreenIndex(for: msg) {
                guard let player = players[screen] else {
                    return "ERROR: screen not found"
                }
                volumeByScreen[screen] = Float(vol)
                player.volume = (msg.muted ?? isMuted) ? 0 : Float(vol)
                player.isMuted = msg.muted ?? isMuted
                player.audioOutputDeviceUniqueID =
                    msg.audioOutputDeviceStrategy == "builtInNonBluetooth"
                    ? msg.audioOutputDeviceUniqueID
                    : nil
            } else {
                volumeByScreen = Dictionary(
                    uniqueKeysWithValues: players.keys.map { ($0, Float(vol)) }
                )
                updateAudioPolicy(
                    muted: msg.muted ?? isMuted,
                    volume: vol,
                    strategy: msg.audioOutputDeviceStrategy,
                    deviceUID: msg.audioOutputDeviceUniqueID
                )
            }
            return "OK"

        case .setMuted:
            updateAudioPolicy(
                muted: msg.muted ?? isMuted,
                volume: msg.volume ?? Double(volume),
                strategy: msg.audioOutputDeviceStrategy,
                deviceUID: msg.audioOutputDeviceUniqueID
            )
            return "OK"

        case .setRate:
            let rate = Float(max(0.5, min(2.0, msg.rate ?? Double(playbackRate))))
            if let screen = resolvedScreenIndex(for: msg) {
                guard let player = players[screen] else {
                    return "ERROR: screen not found"
                }
                playbackRateByScreen[screen] = rate
                playbackRate = rate
                if !systemPlaybackPaused,
                   !isPaused,
                   !manualPausedScreens.contains(screen) {
                    playWallpaperPlayer(player, rate: rate)
                }
            } else {
                playbackRate = rate
                playbackRateByScreen = Dictionary(
                    uniqueKeysWithValues: players.keys.map { ($0, rate) }
                )
                if !systemPlaybackPaused && !isPaused {
                    var seen = Set<ObjectIdentifier>()
                    for (screen, player) in players {
                        guard !manualPausedScreens.contains(screen) else { continue }
                        let id = ObjectIdentifier(player)
                        guard seen.insert(id).inserted else { continue }
                        playWallpaperPlayer(player, rate: rate)
                    }
                }
            }
            return "OK"

        case .setCrop:
            guard let screen = resolvedScreenIndex(for: msg) else {
                return "ERROR: missing screen"
            }
            return applyCrop(screen: screen, msg: msg)
                ? "OK"
                : "ERROR: screen not found"

        case .updatePoster:
            guard let screen = resolvedScreenIndex(for: msg) else {
                return "ERROR: missing screen"
            }
            return updatePosterPath(screen: screen, path: msg.posterPath)
                ? "OK"
                : "ERROR: screen or poster unavailable"

        case .showPoster:
            guard let screen = resolvedScreenIndex(for: msg),
                  let path = msg.posterPath else {
                return "ERROR: missing poster params"
            }
            return showPoster(screen: screen, path: path)
                ? "OK"
                : "ERROR: poster unavailable"

        case .hidePoster:
            guard let screen = resolvedScreenIndex(for: msg) else {
                return "ERROR: missing screen"
            }
            return hidePoster(screen: screen)
                ? "OK"
                : "ERROR: screen not found"

        case .setGrainOverlay:
            let intensity = msg.grainIntensity ?? 0
            if let screen = resolvedScreenIndex(for: msg) {
                guard setGrainOverlay(screen: screen, intensity: intensity) else {
                    return "ERROR: screen not found"
                }
            } else {
                guard !screenStates.isEmpty else {
                    return "ERROR: no active screens"
                }
                for screen in screenStates.keys {
                    _ = setGrainOverlay(screen: screen, intensity: intensity)
                }
            }
            return "OK"

        case .bringToFront:
            guard let screen = resolvedScreenIndex(for: msg),
                  let window = screenStates[screen]?.window else {
                return "ERROR: screen not found"
            }
            window.orderFrontRegardless()
            window.displayIfNeeded()
            return "OK"

        case .revealPreparedWindow:
            return revealPreparedWindow(screen: resolvedScreenIndex(for: msg))
                ? "OK"
                : "ERROR: screen not found"

        case .commitTransition:
            guard let requestID = msg.requestID else {
                return "ERROR: missing transition request"
            }
            return commitTransitions(requestID: requestID) ? "OK" : "ERROR: transition not found"

        case .cancelTransition:
            guard let requestID = msg.requestID else {
                return "ERROR: missing transition request"
            }
            cancelTransitions(requestID: requestID)
            return "OK"

        case .forceCommit:
            forceCommit(screen: resolvedScreenIndex(for: msg))
            return "OK"

        case .pruneInactiveScreens:
            guard let activeScreenIDs = msg.activeScreenIDs else {
                return "ERROR: missing active screens"
            }
            pruneInactiveScreens(keeping: Set(activeScreenIDs))
            return "OK"

        case .shutdown:
            shutdown()
            return "OK"
        }
    }

    // MARK: setWallpaper（核心：创建窗口 + Player）

    private func setWallpaper(screen: Int, videoURL: URL, screenFrame: CGRect,
                              muted: Bool, volume: Double, rate: Double, enableLooping: Bool,
                              usesSharedDecoder: Bool, forceNewPipeline: Bool,
                              hdrMetadataEnabled: Bool,
                              deferredPresentation: Bool,
                              transitionDuration: TimeInterval,
                              globalPaused: Bool, screenPaused: Bool,
                              globalDisplaySyncEnabled: Bool,
                              screenID: String,
                              requestID: String,
                              posterPath: String?) async -> String {
        self.isMuted = muted
        self.volume = Float(volume)
        volumeByScreen[screen] = Float(max(0, min(1, volume)))
        let clampedRate = Float(max(0.5, min(2.0, rate)))
        self.playbackRate = clampedRate
        playbackRateByScreen[screen] = clampedRate
        self.usesSharedVideoDecoder = usesSharedDecoder
        self.isGlobalDisplaySyncEnabled = globalDisplaySyncEnabled
        self.isPaused = globalPaused
        if screenPaused {
            manualPausedScreens.insert(screen)
        } else {
            manualPausedScreens.remove(screen)
        }

        if pendingReplacements[screen] != nil {
            cancelPendingReplacement(screen: screen)
        }
        // Keep any live desktop window's old pipeline until the incoming layer
        // has a drawable. Host `deferredPresentation` only decides who commits:
        // the host after a staged apply, or this process immediately on first
        // frame (wake/reconfigure/timeout retry).
        let preserveExistingPipeline = screenStates[screen] != nil
        let deferWindowReveal = deferredPresentation && !preserveExistingPipeline
        let autoCommitOnReady = preserveExistingPipeline && !deferredPresentation
        let replacementSource = prepareScreenForReplacement(
            screen,
            preserveOldPipeline: preserveExistingPipeline
        )
        let reusableState = replacementSource?.state
        let isReplacement = reusableState != nil
        let window: VideoWallpaperWindow
        let containerView: VideoContainerView
        if let reusableState,
           let existingWindow = reusableState.window as? VideoWallpaperWindow,
           let existingContainer = reusableState.containerView {
            window = existingWindow
            containerView = existingContainer
            window.setFrame(screenFrame, display: true)
            containerView.frame = CGRect(origin: .zero, size: screenFrame.size)
        } else {
            window = VideoWallpaperWindow(
                contentRect: screenFrame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.setFrame(screenFrame, display: true)
            window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .fullScreenAuxiliary,
                .ignoresCycle
            ]
            // isOpaque=false + alpha=0.99999（常驻近乎不透明）：窗口按半透明层合成，
            // 必须与壁纸层混合 → 壁纸层不被视频层挂起 → 菜单栏 backdrop
            // 懒采样能跟随 poster 更新（alpha=1 时壁纸层被挂起，菜单栏永不
            // 更新——实测验证）。0.99999 与 1 视觉无差别。
            window.isOpaque = false
            window.backgroundColor = .black
            // Stay nearly invisible until the first drawable exists. Flashing
            // A fully revealed window here exposes the black background before play().
            window.alphaValue = 0.02
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.isMovable = false
            window.animationBehavior = .none

            containerView = VideoContainerView(
                frame: CGRect(origin: .zero, size: screenFrame.size)
            )
            containerView.autoresizingMask = [.width, .height]
            window.contentView = containerView
        }

        if !preserveExistingPipeline {
            if let posterPath, !containerView.showPoster(path: posterPath) {
                AppLogger.error(
                    .wallpaper,
                    "video-renderer set poster 加载失败 screen=\(screen) path=\(posterPath)"
                )
            } else if posterPath == nil {
                containerView.hidePoster()
            }
        }

        // The external renderer has its own UserDefaults domain. Restore the
        // persisted visual setting when the main process has not sent an IPC
        // refresh yet, so a newly created window does not lose grain texture.
        let defaults = UserDefaults.standard
        let grainEnabled = defaults.bool(forKey: "grain_texture_enabled")
        let storedGrainIntensity = defaults.double(forKey: "arc_grain_intensity")
        if grainEnabled && !isReplacement {
            containerView.showGrainOverlay(intensity: storedGrainIntensity > 0 ? storedGrainIntensity : 0.5)
        }

        let generation = (screenGenerations[screen] ?? 0) &+ 1
        screenGenerations[screen] = generation
        screenStates[screen] = ScreenState(
            screenID: screenID,
            screenFingerprint: currentScreenFingerprint(at: screen),
            requestID: requestID,
            window: window,
            containerView: containerView,
            videoURL: videoURL,
            posterPath: posterPath,
            screenFrame: screenFrame,
            generation: generation,
            lastCropRevision: reusableState?.lastCropRevision ?? 0,
            deferWindowReveal: deferWindowReveal
        )

        // 解析 Player 组件（含共享解码逻辑）
        let components = resolvePlayerComponents(screen: screen, videoURL: videoURL,
                                                  muted: muted, enableLooping: enableLooping,
                                                  requestID: requestID,
                                                  forceNewPipeline: forceNewPipeline,
                                                  hdrMetadataEnabled: hdrMetadataEnabled)
        // 本轮 set 之后不再保留该屏的预热管线：命中已被 resolve 消费分支取走，
        // 未命中（换片 / 共享复用 / 循环模式）立即丢弃，防止陈旧解码管线驻留。
        releasePrewarmedPipeline(screen)
        let isSharedWarmupFollower = !screenIDsReferencingPlayer(components.player).isEmpty
        players[screen] = components.player
        if let looper = components.looper {
            loopers[screen] = looper
        } else {
            loopers.removeValue(forKey: screen)
        }
        items[screen] = components.item

        containerView.playerLayer.videoGravity = .resizeAspectFill
        if preserveExistingPipeline,
           let replacementSource,
           let oldPlayer = replacementSource.player {
            containerView.attachPlayer(oldPlayer)
            pendingReplacements[screen] = PendingReplacement(
                requestID: requestID,
                screen: screen,
                oldState: replacementSource.state,
                oldPlayer: oldPlayer,
                oldLooper: replacementSource.looper,
                oldItem: replacementSource.item,
                oldWasOnEndMode: replacementSource.wasOnEndMode,
                newPlayer: components.player,
                newLooper: components.looper,
                newItem: components.item,
                transitionDuration: max(0, transitionDuration),
                autoCommitOnReady: autoCommitOnReady
            )
            if isSharedWarmupFollower {
                // 共享解码 follower：transition layer 延迟到串行挂载调度时创建。
                // 多块屏的 layer 同时挂到未起播的共享 player 上时，跨屏场景
                // 部分 layer 可能永远拿不到帧（isReadyForDisplay 不变 true），
                // 该屏窗口会永远停在 alpha 0.02 只显示静态 poster。
                enqueueSharedFollowerAttachment(screen: screen, player: components.player)
            } else {
                let transitionLayer = containerView.preparePlayerForCrossfade(components.player)
                observeFirstFrameReadiness(
                    on: transitionLayer,
                    screen: screen,
                    generation: generation,
                    player: components.player
                )
                notifyFirstFrameIfAlreadyReady(
                    on: transitionLayer,
                    screen: screen,
                    generation: generation,
                    player: components.player
                )
            }
        } else {
            if isSharedWarmupFollower {
                // 同上：follower 一律走串行挂载队列，不再因窗口复用而立即 attach。
                enqueueSharedFollowerAttachment(screen: screen, player: components.player)
            } else {
                containerView.attachPlayer(components.player)
            }
            observeFirstFrameReadiness(
                on: containerView.playerLayer,
                screen: screen,
                generation: generation,
                player: components.player
            )
            if !isSharedWarmupFollower {
                notifyFirstFrameIfAlreadyReady(
                    on: containerView.playerLayer,
                    screen: screen,
                    generation: generation,
                    player: components.player
                )
            }
        }

        // A replacement keeps the old freeze frame fully visible in the same
        // window. A cross-type warmup remains nearly transparent even after
        // its first drawable; the host reveals it only once the outgoing
        // Scene/Web/static presentation is protected by a snapshot.
        window.alphaValue = isReplacement ? 0.99999 : 0.02
        vlog("set: screen=\(screen) req=\(requestID.prefix(6)) isReplacement=\(isReplacement) alpha=\(isReplacement ? 0.99999 : 0.02) deferred=\(deferredPresentation) transition=\(transitionDuration)")
        window.orderFrontRegardless()
        window.orderBack(nil)
        window.displayIfNeeded()
        CATransaction.flush()

        // 上报窗口已创建
        sendEvent(
            .windowCreated,
            screen: screen,
            screenID: screenID,
            requestID: requestID,
            message: nil
        )

        // 启动播放（首帧 reveal 会在 isReadyForDisplay 回调中处理）
        applyAudioPolicy()
        scheduleInitialPlayback(
            screen: screen,
            player: components.player,
            shouldPlay: !systemPlaybackPaused && !globalPaused && !screenPaused
        )

        // A timeout is an error, not a first frame. Reporting readiness here
        // would let the host tear down Scene/Web while this window still has no
        // drawable, recreating the exact black flash the subprocess migration
        // is meant to eliminate.
        let firstFrameTimeout: TimeInterval = forceNewPipeline ? 3.0 : 10.0
        DispatchQueue.main.asyncAfter(deadline: .now() + firstFrameTimeout) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let layerReady = self.pendingReplacements[screen]?.newPlayer === components.player
                    ? containerView.preparedPlayerLayer?.isReadyForDisplay == true
                    : containerView.playerLayer.isReadyForDisplay
                if self.screenStates[screen]?.generation == generation,
                   self.players[screen] === components.player,
                   !layerReady {
                    self.sendEvent(
                        .error,
                        screen: screen,
                        screenID: screenID,
                        requestID: requestID,
                        message: "first frame timeout"
                    )
                    if self.pendingReplacements[screen]?.requestID == requestID {
                        self.cancelPendingReplacement(screen: screen)
                    }
                }
            }
        }

        // 播放结束观察（播完即换模式）
        if !enableLooping {
            onEndModeScreens.insert(screen)
            setupPlaybackEndObserver(screen: screen, player: components.player)
        } else {
            onEndModeScreens.remove(screen)
        }

        return "OK"
    }

    /// Starts a newly bound player without ever calling `preroll` before its
    /// status is ready. The old code did that during wake recovery when the
    /// shared lock state still said "paused", which raised
    /// `NSInvalidArgumentException` on the renderer's main actor and left the
    /// IPC server unresponsive until the host's 30s command timeout expired.
    private func scheduleInitialPlayback(
        screen: Int,
        player: AVQueuePlayer,
        shouldPlay: Bool
    ) {
        playbackStatusObservers[screen]?.invalidate()
        playbackStatusObservers.removeValue(forKey: screen)

        if player.status == .readyToPlay {
            finishInitialPlayback(
                screen: screen,
                player: player,
                shouldPlay: shouldPlay
            )
            return
        }

        guard player.status != .failed else {
            AppLogger.error(
                .wallpaper,
                "video-renderer 新播放器创建失败 screen=\(screen) error=\(player.error?.localizedDescription ?? "unknown")"
            )
            return
        }

        playbackStatusObservers[screen] = player.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self, weak player] observedPlayer, _ in
            guard observedPlayer.status == .readyToPlay
                || observedPlayer.status == .failed else {
                return
            }
            Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
                guard self.players[screen] === player else { return }
                self.playbackStatusObservers[screen]?.invalidate()
                self.playbackStatusObservers.removeValue(forKey: screen)
                if player.status == .readyToPlay {
                    self.finishInitialPlayback(
                        screen: screen,
                        player: player,
                        shouldPlay: shouldPlay
                    )
                } else {
                    AppLogger.error(
                        .wallpaper,
                        "video-renderer 新播放器加载失败 screen=\(screen) error=\(player.error?.localizedDescription ?? "unknown")"
                    )
                }
            }
        }
    }

    private func playWallpaperPlayer(_ player: AVPlayer, rate: Float? = nil) {
        let target = rate ?? playbackRate
        player.rate = max(0.5, min(2.0, target))
    }

    private func playbackRate(forScreen screen: Int) -> Float {
        playbackRateByScreen[screen] ?? playbackRate
    }

    private func finishInitialPlayback(
        screen: Int,
        player: AVQueuePlayer,
        shouldPlay: Bool
    ) {
        guard players[screen] === player else { return }
        guard player.status == .readyToPlay else { return }

        let rate = playbackRate(forScreen: screen)
        let canPlay = shouldPlay
            && !systemPlaybackPaused
            && !isPaused
            && !manualPausedScreens.contains(screen)
        if canPlay {
            playWallpaperPlayer(player, rate: rate)
            return
        }

        // Only call preroll after status becomes ready. Keep the player paused;
        // a later lock/unlock or auto-pause transition owns the actual play().
        player.preroll(atRate: rate) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.players[screen] === player else {
                    return
                }
                if !self.systemPlaybackPaused,
                   !self.isPaused,
                   !self.manualPausedScreens.contains(screen) {
                    self.playWallpaperPlayer(player, rate: self.playbackRate(forScreen: screen))
                }
            }
        }
    }

    // MARK: Player 组件解析（含共享解码逻辑）

    private struct PlayerComponents {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper?
        let item: AVPlayerItem
    }

    /// 解析 Player 组件。优先复用已有 player（机会式共享 / 全局共享）。
    private func resolvePlayerComponents(screen: Int, videoURL: URL,
                                          muted: Bool, enableLooping: Bool,
                                          requestID: String,
                                          forceNewPipeline: Bool,
                                          hdrMetadataEnabled: Bool) -> PlayerComponents {
        // 显式共享与机会式共享都必须按“同文件 + 同 loop 模式”匹配。
        // 显式共享只放宽屏数上限，绝不能复用上一条视频的旧 player。
        if let existing = findReusablePlayerComponents(
            for: videoURL,
            enableLooping: enableLooping,
            unlimited: usesSharedVideoDecoder,
            requestID: forceNewPipeline ? requestID : nil,
            attachingScreen: screen
        ) {
            expandPreferredMaximumResolutionIfNeeded(
                for: existing.item,
                screen: screen
            )
            return PlayerComponents(
                player: existing.player,
                looper: existing.looper,
                item: existing.item
            )
        }

        // 播完即换预热命中：直接取用已 preroll 的管线，首帧无需现场解码。
        // 仅限非循环模式（预热管线只插入一次 item，没有 AVPlayerLooper）。
        if !forceNewPipeline, !enableLooping,
           let prewarmed = prewarmedPipelines.removeValue(forKey: screen) {
            if prewarmed.videoURL.standardizedFileURL == videoURL.standardizedFileURL,
               prewarmed.item.status != .failed {
                vlog("prewarm: HIT screen=\(screen) video=\(videoURL.lastPathComponent)")
                // 消费即摘除 status 观察员：管线已交给正式播放路径，
                // 不允许迟到的 readyToPlay 再对已上屏 player 补 preroll。
                prewarmStatusObservers[screen]?.invalidate()
                prewarmStatusObservers.removeValue(forKey: screen)
                expandPreferredMaximumResolutionIfNeeded(
                    for: prewarmed.item,
                    screen: screen
                )
                return PlayerComponents(
                    player: prewarmed.player,
                    looper: prewarmed.looper,
                    item: prewarmed.item
                )
            }
            // 未命中：管线弃用，同步清掉残留的 status 观察员防泄漏
            vlog("prewarm: MISS screen=\(screen) expected=\(videoURL.lastPathComponent) got=\(prewarmed.videoURL.lastPathComponent) itemStatus=\(prewarmed.item.status.rawValue)")
            prewarmStatusObservers[screen]?.invalidate()
            prewarmStatusObservers.removeValue(forKey: screen)
            prewarmed.player.pause()
            prewarmed.player.replaceCurrentItem(with: nil)
        }

        // 新建独立 player
        let item = AVPlayerItem(url: videoURL)
        configurePlayerItem(
            item,
            videoURL: videoURL,
            screen: screen,
            hdrMetadataEnabled: hdrMetadataEnabled
        )
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .none
        applyPlayerAudioPolicy(
            player,
            volume: volumeByScreen[screen] ?? Float(volume)
        )
        // 模板 item 必须在 AVPlayerLooper 复制它之前关闭音轨；否则即使稍后
        // player.isMuted=true，AVFoundation 仍可能先建立默认（蓝牙）输出链路。
        applyPlayerItemAudioPolicy(item)
        player.automaticallyWaitsToMinimizeStalling = !videoURL.isFileURL
            || Self.isExternalVolume(videoURL)
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper: AVPlayerLooper?
        if enableLooping {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
            looper = nil
        }
        return PlayerComponents(player: player, looper: looper, item: item)
    }

    /// 预热管线载荷：独立 player（on-end 语义，item 只插入一次）
    private struct PrewarmedPipeline {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper?
        let item: AVPlayerItem
        let videoURL: URL
    }

    // MARK: 播完即换预热

    /// 预建下一条视频的独立解码管线并 preroll。不挂任何窗口，纯后台暖机；
    /// 音频在建链前即被静音，预热本身不会唤醒蓝牙音频设备。
    private func prewarmPipeline(
        screen: Int,
        videoURL: URL,
        volume: Double,
        hdrMetadataEnabled: Bool
    ) -> String {
        guard screenStates[screen] != nil else { return "OK no-screen" }
        if let existing = prewarmedPipelines[screen] {
            if existing.videoURL.standardizedFileURL == videoURL.standardizedFileURL,
               existing.item.status != .failed {
                return "OK already-warm"
            }
            releasePrewarmedPipeline(screen)
        }

        let item = AVPlayerItem(url: videoURL)
        configurePlayerItem(
            item,
            videoURL: videoURL,
            screen: screen,
            hdrMetadataEnabled: hdrMetadataEnabled
        )
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .none
        applyPlayerAudioPolicy(player, volume: Float(volume))
        applyPlayerItemAudioPolicy(item)
        player.automaticallyWaitsToMinimizeStalling = !videoURL.isFileURL
            || Self.isExternalVolume(videoURL)
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.insert(item, after: nil)
        prewarmedPipelines[screen] = PrewarmedPipeline(
            player: player,
            looper: nil,
            item: item,
            videoURL: videoURL
        )
        // preroll 门控：player.status 尚为 .unknown 时调用 preroll 会抛
        // NSInvalidArgumentException，异常在 IPC 处理路径上 unwind 会楔死
        // daemon 的命令循环。KVO 等 .readyToPlay 后再暖机；若 item 准备
        // 失败（player .failed）则不 preroll，消费侧按 item.status 丢弃。
        prewarmStatusObservers[screen] = player.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] observedPlayer, _ in
            let isReady = observedPlayer.status == .readyToPlay
            guard isReady else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.prewarmStatusObservers[screen]?.invalidate()
                self.prewarmStatusObservers.removeValue(forKey: screen)
                observedPlayer.preroll(atRate: 1) { _ in }
            }
        }
        return "OK"
    }

    /// 释放某屏的预热管线（消费未命中 / 换片 / 销屏时调用，防陈旧驻留）
    private func releasePrewarmedPipeline(_ screen: Int) {
        prewarmStatusObservers[screen]?.invalidate()
        prewarmStatusObservers.removeValue(forKey: screen)
        guard let pipeline = prewarmedPipelines.removeValue(forKey: screen) else { return }
        pipeline.player.pause()
        pipeline.looper?.disableLooping()
        pipeline.player.replaceCurrentItem(with: nil)
    }

    /// 查找同 URL、同 loop 模式的 player。显式共享模式不受机会式屏数上限约束。
    private func findReusablePlayerComponents(
        for videoURL: URL,
        enableLooping: Bool,
        unlimited: Bool,
        requestID: String?,
        attachingScreen: Int
    ) -> (player: AVQueuePlayer, looper: AVPlayerLooper?, item: AVPlayerItem)? {
        let standardURL = videoURL.standardizedFileURL

        for (screenID, state) in screenStates.sorted(by: { $0.key < $1.key }) {
            guard state.videoURL?.standardizedFileURL == standardURL,
                  let player = players[screenID],
                  let item = items[screenID] else { continue }
            if let requestID, state.requestID != requestID {
                continue
            }
            let existingIsOnEnd = onEndModeScreens.contains(screenID)
            guard existingIsOnEnd == !enableLooping else { continue }
            if !unlimited {
                let attachingRate = maximumFramesPerSecond(for: attachingScreen)
                let sameRateShareCount = screenIDsReferencingPlayer(player)
                    .filter { maximumFramesPerSecond(for: $0) == attachingRate }
                    .count
                guard sameRateShareCount < maxOpportunisticShareScreenCount else {
                    continue
                }
                let existingVolume = volumeByScreen[screenID] ?? volume
                let attachingVolume = volumeByScreen[attachingScreen] ?? volume
                guard isMuted || abs(existingVolume - attachingVolume) < 0.001 else {
                    continue
                }
            }
            return (player, loopers[screenID], item)
        }
        return nil
    }

    private static func isExternalVolume(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey])
        return values?.volumeIsInternal == false
    }

    private func configurePlayerItem(
        _ item: AVPlayerItem,
        videoURL: URL,
        screen: Int,
        hdrMetadataEnabled: Bool
    ) {
        if #available(macOS 11.0, *) {
            item.appliesPerFrameHDRDisplayMetadata = hdrMetadataEnabled
        }
        let scale = backingScaleFactor(for: screen)
        let frame = screenStates[screen]?.screenFrame ?? .zero
        item.preferredMaximumResolution = CGSize(
            width: max(1, frame.width * scale),
            height: max(1, frame.height * scale)
        )
        if #available(macOS 10.15, *) {
            item.seekingWaitsForVideoCompositionRendering = false
        }
        item.audioTimePitchAlgorithm = .timeDomain

        guard videoURL.isFileURL else { return }
        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: videoURL.path
        ))?[.size] as? UInt64 ?? 0
        let isLargeFile = fileSize > 1_000_000_000
        if Self.isExternalVolume(videoURL) {
            item.preferredForwardBufferDuration = isLargeFile ? 20 : 12
        } else {
            item.preferredForwardBufferDuration = isLargeFile ? 2 : 5
        }
    }

    private func expandPreferredMaximumResolutionIfNeeded(
        for item: AVPlayerItem,
        screen: Int
    ) {
        let scale = backingScaleFactor(for: screen)
        let frame = screenStates[screen]?.screenFrame ?? .zero
        item.preferredMaximumResolution = CGSize(
            width: max(item.preferredMaximumResolution.width, frame.width * scale),
            height: max(item.preferredMaximumResolution.height, frame.height * scale)
        )
    }

    private func backingScaleFactor(for screen: Int) -> CGFloat {
        let orderedScreens = RendererScreenIdentity.orderedScreens(NSScreen.screens)
        if let screenID = screenStates[screen]?.screenID,
           let matchingScreen = orderedScreens.first(where: {
               RendererScreenIdentity.identifier(for: $0) == screenID
           }) {
            return matchingScreen.backingScaleFactor
        }
        guard orderedScreens.indices.contains(screen) else { return 2 }
        return orderedScreens[screen].backingScaleFactor
    }

    private func maximumFramesPerSecond(for screen: Int) -> Int {
        let orderedScreens = RendererScreenIdentity.orderedScreens(NSScreen.screens)
        if let screenID = screenStates[screen]?.screenID,
           let matchingScreen = orderedScreens.first(where: {
               RendererScreenIdentity.identifier(for: $0) == screenID
           }) {
            return matchingScreen.maximumFramesPerSecond
        }
        guard orderedScreens.indices.contains(screen) else { return 60 }
        return orderedScreens[screen].maximumFramesPerSecond
    }

    /// 返回引用指定 player 的所有屏 ID
    private func screenIDsReferencingPlayer(_ player: AVQueuePlayer) -> [Int] {
        players.filter { $0.value === player }.map { $0.key }
    }

    // MARK: 首帧就绪

    /// 注册首帧就绪观察。layer ready 后触发 onFirstFrameReady（reveal + 上报主进程）。
    /// follower 屏在串行挂载调度 attach 之后也会调用本函数（deferred 路径观察 transition layer）。
    private func observeFirstFrameReadiness(
        on layer: AVPlayerLayer,
        screen: Int,
        generation: UInt64,
        player: AVQueuePlayer
    ) {
        firstFrameObservers[screen]?.invalidate()
        let observer = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self, weak player] observedLayer, change in
            let isReady = change.newValue ?? observedLayer.isReadyForDisplay
            guard isReady else { return }
            Task { @MainActor in
                guard let self, let player else { return }
                self.onFirstFrameReady(
                    screen: screen,
                    generation: generation,
                    player: player
                )
            }
        }
        firstFrameObservers[screen] = observer
    }

    private func notifyFirstFrameIfAlreadyReady(
        on layer: AVPlayerLayer,
        screen: Int,
        generation: UInt64,
        player: AVQueuePlayer
    ) {
        guard layer.isReadyForDisplay else { return }
        onFirstFrameReady(screen: screen, generation: generation, player: player)
    }

    private func onFirstFrameReady(
        screen: Int,
        generation: UInt64,
        player: AVQueuePlayer
    ) {
        // 幂等闸：KVO 触发与串行挂载调度的主动检查可能重复进入。
        guard firstFrameObservers[screen] != nil else { return }
        guard let state = screenStates[screen],
              state.generation == generation,
              players[screen] === player,
              let containerView = state.containerView,
              (
                  containerView.playerLayer.player === player
                      || containerView.preparedPlayerLayer?.player === player
              ),
              let window = state.window else {
            return
        }

        // 移除观察者
        firstFrameObservers[screen]?.invalidate()
        firstFrameObservers.removeValue(forKey: screen)

        if pendingReplacements[screen]?.newPlayer !== player,
           !state.deferWindowReveal {
            // Brand-new or immediate replacement: reveal as soon as the live
            // layer owns a drawable. Deferred replacements remain on the old
            // layer until the host commits the request.
            containerView.resumeFromFreeze()
            window.alphaValue = 0.99999
            window.orderFrontRegardless()
            window.orderBack(nil)
        }

        // 上报主进程
        sendEvent(
            .firstFrameReady,
            screen: screen,
            screenID: state.screenID,
            requestID: state.requestID,
            message: nil
        )

        if pendingReplacements[screen]?.autoCommitOnReady == true,
           pendingReplacements[screen]?.newPlayer === player {
            commitPendingReplacement(screen: screen, requestID: state.requestID)
        }

        AppLogger.info(.wallpaper, "video-renderer 首帧就绪 screen=\(screen)")
    }

    /// Completes a Scene/Web/static -> video handoff after the host has
    /// captured the old desktop presentation. This is intentionally distinct
    /// from `bringToFront`, which is also used to keep an old video visible
    /// while a different renderer warms up behind it.
    @discardableResult
    private func revealPreparedWindow(screen: Int?) -> Bool {
        guard let screen,
              var state = screenStates[screen],
              let window = state.window,
              let container = state.containerView else {
            return false
        }
        vlog("reveal: screen=\(screen) freezeActive=\(container.isFreezeFrameActive) posterShown=\(container.isShowingPoster) sysPaused=\(systemPlaybackPaused) isPaused=\(isPaused)")

        state.deferWindowReveal = false
        screenStates[screen] = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.resumeFromFreeze()
        window.alphaValue = 0.99999
        window.orderFrontRegardless()
        window.orderBack(nil)
        window.displayIfNeeded()
        CATransaction.commit()
        CATransaction.flush()

        if !systemPlaybackPaused,
           !isPaused,
           !manualPausedScreens.contains(screen) {
            container.hidePoster()
        }
        return true
    }

    // MARK: 播放结束观察（播完即换）

    private func setupPlaybackEndObserver(screen: Int, player: AVQueuePlayer) {
        let alreadyObserved = playbackEndObservers.keys.contains { owner in
            players[owner] === player
        }
        guard !alreadyObserved else { return }
        guard let observedItem = items[screen] ?? player.currentItem else { return }

        // 移除旧观察者
        if let old = playbackEndObservers[screen] {
            NotificationCenter.default.removeObserver(old)
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: observedItem,
            queue: .main
        ) { [weak self, weak player] notification in
            guard notification.object as? AVPlayerItem === observedItem else { return }
            Task { @MainActor [weak self, weak player] in
                guard let self,
                      let player,
                      self.players[screen] === player,
                      self.onEndModeScreens.contains(screen),
                      self.items[screen] === observedItem else {
                    return
                }
                let attachedOnEndScreens = self.screenIDsReferencingPlayer(player)
                    .filter(self.onEndModeScreens.contains)
                    .sorted()
                guard !attachedOnEndScreens.isEmpty else { return }
                // 先冻结最后一帧作为过渡底图：视觉上呈现「最后一帧 → 新视频
                // 淡入」的自然续接，消除 poster 静态图闪烁与结束瞬间的黑帧。
                for attachedScreen in attachedOnEndScreens {
                    self.screenStates[attachedScreen]?.containerView?
                        .freezeForPausePreservingFrame()
                }
                // 冻结失败（无可捕获 drawable）时退回 poster 兜底
                for attachedScreen in attachedOnEndScreens {
                    guard let state = self.screenStates[attachedScreen],
                          state.containerView?.isFreezeFrameActive != true,
                          let posterPath = state.posterPath else { continue }
                    vlog("end: screen=\(attachedScreen) 冻结失败→poster兜底")
                    _ = self.showPoster(screen: attachedScreen, path: posterPath)
                }
                for attachedScreen in attachedOnEndScreens {
                    vlog("end: screen=\(attachedScreen) freezeActive=\(self.screenStates[attachedScreen]?.containerView?.isFreezeFrameActive == true)")
                }
                // Keep the ended player in a deterministic state before the
                // host starts a replacement. This mirrors the in-process
                // renderer and prevents a short clip's stale end position
                // from racing the next set/seek command.
                player.pause()
                // Do not seek(0) here. That briefly publishes a black or first
                // IOSurface and overwrites the last-frame freeze used by the
                // next video->video handoff. The incoming `set` replaces this
                // player; leftover end-time is discarded with it.
                let liveOnEndScreens = attachedOnEndScreens
                let eventScreens = self.isGlobalDisplaySyncEnabled
                    ? Array(liveOnEndScreens.prefix(1))
                    : liveOnEndScreens
                for eventScreen in eventScreens {
                    self.sendEvent(
                        .playbackEnded,
                        screen: eventScreen,
                        screenID: self.screenStates[eventScreen]?.screenID,
                        requestID: self.screenStates[eventScreen]?.requestID,
                        message: nil
                    )
                }
            }
        }
        playbackEndObservers[screen] = observer
    }

    // MARK: 暂停 / 恢复 / 停止

    @discardableResult
    private func pauseScreen(_ screen: Int) -> Bool {
        guard let player = players[screen],
              screenStates[screen] != nil else {
            return false
        }
        manualPausedScreens.insert(screen)
        if let posterPath = screenStates[screen]?.posterPath {
            _ = screenStates[screen]?.containerView?.showPoster(path: posterPath)
        }
        screenStates[screen]?.containerView?.freezeForPause()
        // 共享 player：只有唯一引用者才真正 pause
        let refCount = screenIDsReferencingPlayer(player).count
        if refCount <= 1 {
            player.pause()
        }
        return true
    }

    @discardableResult
    private func pauseAll() -> Bool {
        guard !players.isEmpty else { return false }
        isPaused = true
        manualPausedScreens = Set(players.keys)
        // 去重：多个屏可能共享同一 player
        var seen = Set<ObjectIdentifier>()
        for (screen, player) in players {
            if let posterPath = screenStates[screen]?.posterPath {
                _ = screenStates[screen]?.containerView?.showPoster(path: posterPath)
            }
            screenStates[screen]?.containerView?.freezeForPause()
            let id = ObjectIdentifier(player)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            player.pause()
        }
        return true
    }

    @discardableResult
    private func resumeScreen(_ screen: Int) -> Bool {
        guard let player = players[screen],
              screenStates[screen] != nil else {
            return false
        }
        manualPausedScreens.remove(screen)
        guard !systemPlaybackPaused else { return true }
        screenStates[screen]?.containerView?.hidePoster()
        screenStates[screen]?.containerView?.resumeFromFreeze()
        playWallpaperPlayer(player, rate: playbackRate(forScreen: screen))
        kickStalledPlayback(screen: screen, player: player)
        return true
    }

    @discardableResult
    private func resumeAll() -> Bool {
        guard !players.isEmpty else { return false }
        isPaused = false
        manualPausedScreens.removeAll()
        guard !systemPlaybackPaused else { return true }
        var seen = Set<ObjectIdentifier>()
        for (screen, player) in players {
            screenStates[screen]?.containerView?.hidePoster()
            screenStates[screen]?.containerView?.resumeFromFreeze()
            let id = ObjectIdentifier(player)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            playWallpaperPlayer(player, rate: playbackRate(forScreen: screen))
            kickStalledPlayback(screen: screen, player: player)
        }
        return true
    }

    /// 长期 pause 后解码会话常被系统回收，单纯 play() 不会再出帧，冻帧/封面会一直盖着。
    /// 用当前时间 seek 踢醒管线；仍无帧则再 play 一次。
    private func kickStalledPlayback(screen: Int, player: AVQueuePlayer) {
        let current = player.currentTime()
        player.seek(to: current, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self, let player, self.players[screen] === player else { return }
                guard !self.systemPlaybackPaused,
                      !self.isPaused,
                      !self.manualPausedScreens.contains(screen) else { return }
                self.playWallpaperPlayer(player, rate: self.playbackRate(forScreen: screen))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak player] in
            guard let self, let player, self.players[screen] === player else { return }
            guard !self.systemPlaybackPaused,
                  !self.isPaused,
                  !self.manualPausedScreens.contains(screen) else { return }
            let layer = self.screenStates[screen]?.containerView?.playerLayer
            if layer?.isReadyForDisplay != true || player.rate == 0 {
                self.playWallpaperPlayer(player, rate: self.playbackRate(forScreen: screen))
                self.screenStates[screen]?.containerView?.resumeFromFreeze()
            }
        }
    }

    @discardableResult
    private func stopScreen(_ screen: Int) -> Bool {
        guard let screenID = screenStates[screen]?.screenID else {
            return false
        }
        teardownScreen(screen)
        sendEvent(
            .stopped,
            screen: screen,
            screenID: screenID,
            requestID: nil,
            message: nil
        )
        return true
    }

    @discardableResult
    private func stopAll() -> Bool {
        let screens = Array(screenStates.keys)
        guard !screens.isEmpty else { return false }
        for screen in screens {
            let screenID = screenStates[screen]?.screenID
            teardownScreen(screen)
            sendEvent(
                .stopped,
                screen: screen,
                screenID: screenID,
                requestID: nil,
                message: nil
            )
        }
        return true
    }

    /// Detaches only the old playback pipeline while preserving the desktop
    /// window and its captured freeze layer. This is the video->video handoff
    /// path; stop still uses the full teardown below.
    private func prepareScreenForReplacement(
        _ screen: Int,
        preserveOldPipeline: Bool
    ) -> ReplacementSource? {
        guard let state = screenStates[screen] else { return nil }

        firstFrameObservers[screen]?.invalidate()
        firstFrameObservers.removeValue(forKey: screen)
        let wasOnEndMode = onEndModeScreens.contains(screen)
        if let observer = playbackEndObservers[screen] {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObservers.removeValue(forKey: screen)
        }
        onEndModeScreens.remove(screen)

        // 已有冻结帧（播完即换的最后一帧）时保留不覆盖
        vlog("prepareReplace: screen=\(screen) freezeActive=\(state.containerView?.isFreezeFrameActive == true) posterShown=\(state.containerView?.isShowingPoster == true) preserveOld=\(preserveOldPipeline)")
        state.containerView?.freezeForPausePreservingFrame()
        let oldPlayer = players.removeValue(forKey: screen)
        let oldLooper = loopers.removeValue(forKey: screen)
        let oldItem = items.removeValue(forKey: screen)

        if let oldPlayer {
            if !preserveOldPipeline, screenIDsReferencingPlayer(oldPlayer).isEmpty {
                releasePlayerIfUnused(oldPlayer, looper: oldLooper)
            } else if !screenIDsReferencingPlayer(oldPlayer).isEmpty {
                rehomePlaybackEndObserverIfNeeded(for: oldPlayer)
            }
        }
        return ReplacementSource(
            state: state,
            player: oldPlayer,
            looper: oldLooper,
            item: oldItem,
            wasOnEndMode: wasOnEndMode
        )
    }

    @discardableResult
    private func commitTransitions(requestID: String) -> Bool {
        let screens = pendingReplacements.values
            .filter { $0.requestID == requestID }
            .map(\.screen)
            .sorted()
        guard !screens.isEmpty else { return false }
        for screen in screens {
            commitPendingReplacement(screen: screen, requestID: requestID)
        }
        return true
    }

    private func commitPendingReplacement(screen: Int, requestID: String) {
        guard let pending = pendingReplacements[screen],
              pending.requestID == requestID,
              let state = screenStates[screen],
              let container = state.containerView,
              players[screen] === pending.newPlayer else {
            return
        }

        vlog("commit: screen=\(screen) req=\(requestID.prefix(6)) fade=\(pending.transitionDuration) freezeActive=\(container.isFreezeFrameActive) posterShown=\(container.isShowingPoster)")
        container.crossfadePreparedPlayer(
            pending.newPlayer,
            duration: pending.transitionDuration
        ) { [weak self, weak container] in
            guard let self,
                  let current = self.pendingReplacements[screen],
                  current.requestID == requestID,
                  current.newPlayer === pending.newPlayer else {
                return
            }
            self.pendingReplacements.removeValue(forKey: screen)
            container?.resumeFromFreeze()
            // 播完即换的结束路径已对全屏盖 poster；视频→视频替换提交后，
            // 若该屏仍在播放必须揭开 poster，否则新视频被旧 poster 永久
            // 遮挡（表现为“切换后根本不会播放”，底层 AVPlayer 实际在播）。
            if !self.systemPlaybackPaused,
               !self.isPaused,
               !self.manualPausedScreens.contains(screen) {
                container?.hidePoster()
            }
            state.window?.alphaValue = 0.99999
            state.window?.orderFrontRegardless()
            state.window?.orderBack(nil)
            self.releasePlayerIfUnused(
                pending.oldPlayer,
                looper: pending.oldLooper
            )
        }
    }

    private func cancelTransitions(requestID: String) {
        let screens = pendingReplacements.values
            .filter { $0.requestID == requestID }
            .map(\.screen)
        for screen in screens {
            cancelPendingReplacement(screen: screen)
        }
    }

    private func cancelPendingReplacement(screen: Int) {
        guard let pending = pendingReplacements.removeValue(forKey: screen) else {
            return
        }

        playbackStatusObservers[screen]?.invalidate()
        playbackStatusObservers.removeValue(forKey: screen)
        firstFrameObservers[screen]?.invalidate()
        firstFrameObservers.removeValue(forKey: screen)
        if let observer = playbackEndObservers.removeValue(forKey: screen) {
            NotificationCenter.default.removeObserver(observer)
        }
        onEndModeScreens.remove(screen)

        let currentPlayer = players.removeValue(forKey: screen)
        let currentLooper = loopers.removeValue(forKey: screen)
        items.removeValue(forKey: screen)

        pending.oldState.containerView?.discardPreparedPlayerTransition()
        pending.oldState.containerView?.attachPlayer(pending.oldPlayer)
        screenStates[screen] = pending.oldState
        players[screen] = pending.oldPlayer
        if let oldLooper = pending.oldLooper {
            loopers[screen] = oldLooper
        }
        if let oldItem = pending.oldItem {
            items[screen] = oldItem
        }
        if pending.oldWasOnEndMode {
            onEndModeScreens.insert(screen)
            setupPlaybackEndObserver(screen: screen, player: pending.oldPlayer)
        }

        let shouldRemainPaused = systemPlaybackPaused
            || isPaused
            || manualPausedScreens.contains(screen)
        if shouldRemainPaused {
            pending.oldPlayer.pause()
            if let path = pending.oldState.posterPath {
                _ = pending.oldState.containerView?.showPoster(path: path)
            }
        } else {
            pending.oldState.containerView?.hidePoster()
            pending.oldState.containerView?.resumeFromFreeze()
            playWallpaperPlayer(pending.oldPlayer, rate: playbackRate(forScreen: screen))
        }
        pending.oldState.window?.alphaValue = 0.99999
        pending.oldState.window?.orderFrontRegardless()
        pending.oldState.window?.orderBack(nil)

        if let currentPlayer, currentPlayer !== pending.oldPlayer {
            releasePlayerIfUnused(currentPlayer, looper: currentLooper)
        }
    }

    private func releasePlayerIfUnused(
        _ player: AVQueuePlayer,
        looper: AVPlayerLooper?
    ) {
        guard screenIDsReferencingPlayer(player).isEmpty else { return }
        let retainedByTransition = pendingReplacements.values.contains {
            $0.oldPlayer === player || $0.newPlayer === player
        }
        guard !retainedByTransition else { return }
        looper?.disableLooping()
        player.pause()
        player.rate = 0
        player.removeAllItems()
        player.replaceCurrentItem(with: nil)
    }

    private func enqueueSharedFollowerAttachment(
        screen: Int,
        player: AVQueuePlayer
    ) {
        let playerID = ObjectIdentifier(player)
        pendingSharedFollowerScreensByPlayerID[playerID, default: []].insert(screen)
        scheduleSharedFollowerAttachments(for: player)
    }

    private func scheduleSharedFollowerAttachments(for player: AVQueuePlayer) {
        let playerID = ObjectIdentifier(player)
        guard sharedFollowerAttachmentTasks[playerID] == nil else { return }

        let task = Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            var anchorSeconds = player.currentTime().seconds
            let deadline = Date().addingTimeInterval(30)
            let hasLiveAttachment = self.screenIDsReferencingPlayer(player)
                .contains { !self.manualPausedScreens.contains($0) }
                && !self.systemPlaybackPaused
                && !self.isPaused
            // All screens can be intentionally paused while their pipelines
            // are built (for example an auto-pause rule active at launch).
            // Do not wait 30 seconds for a timebase that we deliberately
            // stopped; attach the follower and let its ready observer handle
            // the first frame once playback resumes.
            var playbackAdvanced = !hasLiveAttachment
            AppLogger.info(.wallpaper, "video-renderer follower 任务启动 initial=\(anchorSeconds) rate=\(player.rate) pending=\(self.pendingSharedFollowerScreensByPlayerID[playerID]?.sorted() ?? [])")

            while !playbackAdvanced, Date() < deadline {
                guard self.screenIDsReferencingPlayer(player).count >= 2 else {
                    AppLogger.error(.wallpaper, "video-renderer follower 任务中止：引用屏数 < 2")
                    self.pendingSharedFollowerScreensByPlayerID.removeValue(forKey: playerID)
                    self.sharedFollowerAttachmentTasks.removeValue(forKey: playerID)
                    return
                }
                let currentSeconds = player.currentTime().seconds
                // AVQueuePlayer 在 rate=1 但 timebase 未建立时 currentTime 会返回
                // NaN；若锚点恰好在那一刻取到，等它变有限后重新锚定，否则会
                // 卡满整个 30s 超时窗口。
                if !anchorSeconds.isFinite, currentSeconds.isFinite {
                    anchorSeconds = currentSeconds
                }
                // leader 屏（非 pending 的引用屏）layer 出帧是共享 player 已开始
                // 供帧的最直接证据，命中后无需再等时间轴推进。
                let followerScreens = self.pendingSharedFollowerScreensByPlayerID[playerID] ?? []
                let leaderLayerReady = self.screenIDsReferencingPlayer(player)
                    .filter { !followerScreens.contains($0) }
                    .contains { refScreen in
                        let container = self.screenStates[refScreen]?.containerView
                        return container?.playerLayer.isReadyForDisplay == true
                            || container?.preparedPlayerLayer?.isReadyForDisplay == true
                    }
                // 循环视频在 loop 边界 currentTime 会跳回 0；时间轴只要动过
                // （含回绕）即视为已起播。
                playbackAdvanced = player.rate > 0 && (
                    leaderLayerReady
                        || (anchorSeconds.isFinite
                            && currentSeconds.isFinite
                            && (currentSeconds - anchorSeconds >= 1.0 / 30.0
                                || currentSeconds < anchorSeconds))
                )
                if !playbackAdvanced {
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }

            if !playbackAdvanced {
                AppLogger.error(.wallpaper, "video-renderer 共享 player 起播等待超时，强制挂载 follower")
            }

            while let screen = self.pendingSharedFollowerScreensByPlayerID[playerID]?.sorted().first {
                self.pendingSharedFollowerScreensByPlayerID[playerID]?.remove(screen)
                guard self.players[screen] === player,
                      let state = self.screenStates[screen],
                      let container = state.containerView else {
                    continue
                }

                // deferred follower：此时才创建 transition layer 并注册首帧观察；
                // 普通 follower：直接 attach 主 layer（首帧观察已在 setWallpaper 注册）。
                let readyLayer: AVPlayerLayer
                if self.pendingReplacements[screen]?.newPlayer === player {
                    let transitionLayer = container.preparePlayerForCrossfade(player)
                    self.observeFirstFrameReadiness(
                        on: transitionLayer,
                        screen: screen,
                        generation: state.generation,
                        player: player
                    )
                    readyLayer = transitionLayer
                    AppLogger.info(.wallpaper, "video-renderer follower attach(deferred) screen=\(screen)")
                } else {
                    container.attachPlayer(player)
                    if self.firstFrameObservers[screen] == nil {
                        self.observeFirstFrameReadiness(
                            on: container.playerLayer,
                            screen: screen,
                            generation: state.generation,
                            player: player
                        )
                    }
                    readyLayer = container.playerLayer
                    AppLogger.info(.wallpaper, "video-renderer follower attach screen=\(screen)")
                }
                CATransaction.flush()

                let layerDeadline = Date().addingTimeInterval(5)
                while Date() < layerDeadline,
                      !readyLayer.isReadyForDisplay {
                    guard self.players[screen] === player else { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }
                if !readyLayer.isReadyForDisplay {
                    AppLogger.error(.wallpaper, "video-renderer follower 首帧等待超时 screen=\(screen)")
                    // Shared followers can sit on a live player whose layer never
                    // flips isReadyForDisplay. Force the host/commit path so the
                    // window does not stay at alpha 0.02 forever.
                    self.onFirstFrameReady(
                        screen: screen,
                        generation: state.generation,
                        player: player
                    )
                } else {
                    // KVO 会错过「attach 时已经 ready」的情况：replacement 下 layer
                    // 换绑到已起播的共享 player 时 isReadyForDisplay 保持 true 无跳变，
                    // 首帧事件会因此永远丢失（副屏停在静态 poster/冻结帧）。
                    // 主动补一次检查（onFirstFrameReady 内部幂等）。
                    self.onFirstFrameReady(
                        screen: screen,
                        generation: state.generation,
                        player: player
                    )
                }
            }

            self.pendingSharedFollowerScreensByPlayerID.removeValue(forKey: playerID)
            self.sharedFollowerAttachmentTasks.removeValue(forKey: playerID)
        }
        sharedFollowerAttachmentTasks[playerID] = task
    }

    private func removeSharedFollower(screen: Int, player: AVQueuePlayer?) {
        guard let player else { return }
        let playerID = ObjectIdentifier(player)
        pendingSharedFollowerScreensByPlayerID[playerID]?.remove(screen)
        if pendingSharedFollowerScreensByPlayerID[playerID]?.isEmpty != false {
            pendingSharedFollowerScreensByPlayerID.removeValue(forKey: playerID)
            sharedFollowerAttachmentTasks[playerID]?.cancel()
            sharedFollowerAttachmentTasks.removeValue(forKey: playerID)
        }
    }

    private func teardownScreen(_ screen: Int) {
        // 移除观察者
        playbackStatusObservers[screen]?.invalidate()
        playbackStatusObservers.removeValue(forKey: screen)
        firstFrameObservers[screen]?.invalidate()
        firstFrameObservers.removeValue(forKey: screen)
        if let observer = playbackEndObservers[screen] {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObservers.removeValue(forKey: screen)
        }
        onEndModeScreens.remove(screen)
        releasePrewarmedPipeline(screen)

        // 清理 player 引用（共享 player 不释放，仅移除本屏引用）
        let pending = pendingReplacements.removeValue(forKey: screen)
        let oldPlayer = players.removeValue(forKey: screen)
        let oldLooper = loopers.removeValue(forKey: screen)
        items.removeValue(forKey: screen)
        removeSharedFollower(screen: screen, player: oldPlayer)
        manualPausedScreens.remove(screen)
        volumeByScreen.removeValue(forKey: screen)

        // Detach the player and visual layers before releasing the window. This
        // also invalidates the freeze/poster/grain view ownership deterministically.
        if let state = screenStates[screen] {
            state.containerView?.detachPlayer()
            state.containerView?.removeVisualOverlays()
            state.window?.contentView = nil
            state.window?.orderOut(nil)
        }
        screenStates.removeValue(forKey: screen)

        if let oldPlayer {
            if screenIDsReferencingPlayer(oldPlayer).isEmpty {
                releasePlayerIfUnused(oldPlayer, looper: oldLooper)
            } else {
                rehomePlaybackEndObserverIfNeeded(for: oldPlayer)
            }
        }
        if let pending {
            pending.oldState.containerView?.discardPreparedPlayerTransition()
            releasePlayerIfUnused(pending.oldPlayer, looper: pending.oldLooper)
        }
    }

    private func pruneInactiveScreens(keeping activeScreenIDs: Set<String>) {
        let liveFingerprints = Set(activeScreenIDs.compactMap(currentFingerprint(matching:)))
        let staleScreens = screenStates
            .filter { _, state in
                if activeScreenIDs.contains(state.screenID)
                    || (state.screenFingerprint.map(activeScreenIDs.contains) == true)
                    || (state.screenFingerprint.map(liveFingerprints.contains) == true) {
                    return false
                }
                if let fingerprint = currentFingerprint(matching: state.screenID),
                   liveFingerprints.contains(fingerprint) {
                    return false
                }
                return true
            }
            .map(\.key)
            .sorted()
        for screen in staleScreens {
            teardownScreen(screen)
        }
        deduplicateScreenStates()
    }

    private func currentScreenFingerprint(at index: Int) -> String? {
        let orderedScreens = RendererScreenIdentity.orderedScreens(NSScreen.screens)
        guard orderedScreens.indices.contains(index) else { return nil }
        return RendererScreenIdentity.fingerprint(for: orderedScreens[index])
    }

    /// Repairs duplicate state left by a display-index reshuffle. Keep the
    /// newest state because its generation/request belongs to the latest host
    /// bind, and tear down the older window/player completely.
    private func deduplicateScreenStates() {
        var ownerByFingerprint: [String: Int] = [:]
        for screen in screenStates.keys.sorted() {
            guard let state = screenStates[screen],
                  let fingerprint = state.screenFingerprint
                    ?? currentFingerprint(matching: state.screenID) else {
                continue
            }
            guard let owner = ownerByFingerprint[fingerprint],
                  let ownerState = screenStates[owner] else {
                ownerByFingerprint[fingerprint] = screen
                continue
            }

            let removeScreen: Int
            if state.generation > ownerState.generation {
                removeScreen = owner
                ownerByFingerprint[fingerprint] = screen
            } else {
                removeScreen = screen
            }
            AppLogger.info(.wallpaper, "video-renderer 去重物理显示器窗口", metadata: [
                "removeScreen": String(removeScreen),
                "keepScreen": String(removeScreen == screen ? owner : screen),
                "fingerprint": fingerprint
            ])
            teardownScreen(removeScreen)
        }
    }

    private func rehomePlaybackEndObserverIfNeeded(for player: AVQueuePlayer) {
        let alreadyObserved = playbackEndObservers.keys.contains { owner in
            players[owner] === player
        }
        guard !alreadyObserved else { return }
        guard let owner = screenIDsReferencingPlayer(player)
            .filter(onEndModeScreens.contains)
            .sorted()
            .first else {
            return
        }
        setupPlaybackEndObserver(screen: owner, player: player)
    }

    private func forceCommit(screen: Int?) {
        let screens = screen.map { [$0] } ?? Array(screenStates.keys)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for screen in screens {
            guard let state = screenStates[screen],
                  let window = state.window,
                  let container = state.containerView else {
                continue
            }
            // Detail-page applies issue forceCommit immediately after `set`.
            // Do not let that maintenance operation expose a cross-type
            // warmup before the host's snapshot-backed handoff has committed.
            guard !state.deferWindowReveal else {
                continue
            }
            window.orderFrontRegardless()
            window.orderBack(nil)
            window.displayIfNeeded()
            // A deferred replacement keeps the old player attached while the
            // incoming player warms up in a separate transition layer. The
            // host may issue forceCommit immediately after `set` returns; do
            // not let that maintenance command bypass the pending crossfade
            // or flush an empty incoming main layer.
            if pendingReplacements[screen] != nil {
                continue
            }
            if let player = players[screen],
               container.playerLayer.player !== player {
                container.attachPlayer(player)
            }
            if let player = players[screen],
               !systemPlaybackPaused,
               !isPaused,
               !manualPausedScreens.contains(screen),
               player.rate == 0 {
                playWallpaperPlayer(player, rate: playbackRate(forScreen: screen))
            }
            container.playerLayer.setNeedsDisplay()
            container.needsDisplay = true
            container.displayIfNeeded()
        }
        CATransaction.commit()
        CATransaction.flush()
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    // MARK: 音频策略

    private func updateAudioPolicy(
        muted: Bool,
        volume: Double,
        strategy: String?,
        deviceUID: String?
    ) {
        isMuted = muted
        self.volume = Float(max(0, min(1, volume)))
        audioOutputDeviceStrategy = strategy ?? audioOutputDeviceStrategy
        audioOutputDeviceUniqueID = deviceUID
        applyAudioPolicy()
    }

    private func applyAudioPolicy() {
        var owners: [ObjectIdentifier: (player: AVQueuePlayer, screen: Int)] = [:]
        for (screen, player) in players {
            let id = ObjectIdentifier(player)
            if owners[id] == nil || screen < owners[id]!.screen {
                owners[id] = (player, screen)
            }
        }
        for owner in owners.values {
            applyPlayerAudioPolicy(
                owner.player,
                volume: volumeByScreen[owner.screen] ?? volume
            )
        }
    }

    private func applyPlayerAudioPolicy(
        _ player: AVQueuePlayer,
        volume playerVolume: Float
    ) {
        player.isMuted = isMuted
        player.volume = isMuted ? 0 : playerVolume
        player.audioOutputDeviceUniqueID = audioOutputDeviceStrategy == "builtInNonBluetooth"
            ? audioOutputDeviceUniqueID
            : nil
        for item in player.items() {
            applyPlayerItemAudioPolicy(item)
        }
    }

    private func applyPlayerItemAudioPolicy(_ item: AVPlayerItem) {
        setLoadedAudioTracksEnabled(!isMuted, for: item)
        guard isMuted else { return }

        Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            _ = try? await item.asset.loadTracks(withMediaType: .audio)
            guard self.isMuted else { return }
            self.setLoadedAudioTracksEnabled(false, for: item)
        }
    }

    private func setLoadedAudioTracksEnabled(
        _ enabled: Bool,
        for item: AVPlayerItem
    ) {
        for track in item.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = enabled
        }
    }

    // MARK: Crop（P2 完整实现，P1 仅 resizeAspectFill）

    @discardableResult
    private func applyCrop(screen: Int, msg: IPCMessage) -> Bool {
        guard let container = screenStates[screen]?.containerView else {
            return false
        }
        if let revision = msg.cropRevision {
            guard revision >= (screenStates[screen]?.lastCropRevision ?? 0) else {
                return true
            }
            screenStates[screen]?.lastCropRevision = revision
        }

        let crop: CGRect?
        if let x = msg.cropX, let y = msg.cropY, let w = msg.cropW, let h = msg.cropH {
            crop = CGRect(x: x, y: y, width: w, height: h)
        } else {
            crop = nil
        }

        let viewport: CGRect?
        if let x = msg.viewportX, let y = msg.viewportY,
           let w = msg.viewportW, let h = msg.viewportH {
            viewport = CGRect(x: x, y: y, width: w, height: h)
        } else {
            viewport = nil
        }

        // Incoming crop belongs to the replacement clip. Applying it during a
        // pending handoff would reshape the outgoing freeze frame and flash
        // black letterbox around A.
        let incomingOnly = pendingReplacements[screen] != nil
        container.applyCrop(
            crop: crop,
            viewport: viewport,
            letterboxColorHex: msg.letterboxColorHex,
            incomingLayerOnly: incomingOnly
        )
        return true
    }

    // MARK: Poster（P2 完整实现）

    @discardableResult
    private func updatePosterPath(screen: Int, path: String?) -> Bool {
        guard var state = screenStates[screen] else { return false }
        if let path, !FileManager.default.fileExists(atPath: path) {
            return false
        }
        state.posterPath = path
        screenStates[screen] = state
        if state.containerView?.isShowingPoster == true {
            if let path {
                return state.containerView?.showPoster(path: path) == true
            }
            state.containerView?.hidePoster()
        }
        return true
    }

    @discardableResult
    private func showPoster(screen: Int, path: String) -> Bool {
        guard let container = screenStates[screen]?.containerView else { return false }
        guard container.showPoster(path: path) else {
            AppLogger.error(.wallpaper, "video-renderer poster 加载失败 screen=\(screen) path=\(path)")
            return false
        }
        screenStates[screen]?.posterPath = path
        return true
    }

    @discardableResult
    private func hidePoster(screen: Int) -> Bool {
        guard pendingReplacements[screen] == nil,
              screenStates[screen]?.deferWindowReveal != true,
              let container = screenStates[screen]?.containerView else {
            return true
        }
        container.hidePoster()
        return true
    }

    @discardableResult
    private func setGrainOverlay(screen: Int, intensity: Double) -> Bool {
        guard let container = screenStates[screen]?.containerView else { return false }
        container.showGrainOverlay(intensity: intensity)
        return true
    }

    // MARK: 上报事件（子进程 → 主进程）

    private func sendEvent(
        _ event: IPCEvent,
        screen: Int?,
        screenID: String? = nil,
        requestID: String? = nil,
        message: String?
    ) {
        let evt = IPCEventMessage(
            event: event,
            screen: screen,
            screenID: screenID,
            requestID: requestID,
            message: message
        )
        guard let data = try? JSONEncoder().encode(evt) else { return }

        // 通过连接到主进程的 socket 发送（主进程在启动子进程时会连接到子进程的 socket 作为 client）
        // 简化：复用同一 socket 路径，主进程作为 client 连接接收事件
        // P1: 通过 stdout 输出事件（主进程读 stdout），或通过反向连接
        // 更可靠：主进程启动子进程时建立双向管道
        // 这里采用：子进程把事件写到 socket 路径的另一个端点
        // 实际实现：主进程会持续 accept 子进程的事件连接
        // 简化 P1：写到 stderr 的特殊前缀，主进程解析
        let prefix = "WAIFUX_EVENT:"
        if let str = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data((prefix + str + "\n").utf8))
        }
    }

    // MARK: 信号处理

    private func installSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)  // fire-and-forget 客户端关闭会触发 EPIPE

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.shutdown()
            }
        }
        sigtermSource.resume()
        signalSources.append(sigtermSource)
        signal(SIGTERM, SIG_IGN)

        let sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        sighupSource.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.shutdownForParentLoss()
            }
        }
        sighupSource.resume()
        signalSources.append(sighupSource)
        signal(SIGHUP, SIG_IGN)

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.shutdown()
            }
        }
        sigintSource.resume()
        signalSources.append(sigintSource)
        signal(SIGINT, SIG_IGN)
    }

    private func installParentWatchdog(parentPID: pid_t?) {
        guard let parentPID, parentPID > 1 else { return }

        // The process source receives the kernel exit event even when the
        // AppKit main actor is busy tearing down AVFoundation objects.
        let exitSource = DispatchSource.makeProcessSource(
            identifier: parentPID,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        exitSource.setEventHandler {
            _exit(0)
        }
        exitSource.resume()
        parentExitSource = exitSource

        // Must stay independent of AppKit/IPC work: a blocked main actor must
        // not leave an orphaned desktop window behind after the parent exits.
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        watchdog.setEventHandler {
            guard getppid() == parentPID, kill(parentPID, 0) == 0 else {
                AppLogger.info(
                    .wallpaper,
                    "video-renderer 检测到主进程退出，自动关闭"
                )
                _exit(0)
            }
        }
        watchdog.resume()
        parentWatchdog = watchdog
    }

    private func shutdown() {
        guard keepRunning else { return }
        AppLogger.info(.wallpaper, "video-renderer shutdown")
        keepRunning = false
        parentWatchdog?.cancel()
        parentWatchdog = nil
        parentExitSource?.cancel()
        parentExitSource = nil
        stopAll()

        // 清理 socket
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)

        // 清理 PID 文件
        let pidPath = ProcessInfo.processInfo.environment[DAEMON_PID_ENV]
            ?? "/tmp/waifux-video-renderer.pid"
        try? FileManager.default.removeItem(atPath: pidPath)

        NSApplication.shared.terminate(nil)
    }

    /// Parent-loss cleanup must not depend on AVPlayer/NSWindow teardown.
    /// The parent is already gone, so close IPC first and let process exit
    /// reclaim the remaining AppKit/AVFoundation objects.
    private func shutdownForParentLoss() {
        guard keepRunning else { return }
        keepRunning = false
        parentWatchdog?.cancel()
        parentWatchdog = nil
        parentExitSource?.cancel()
        parentExitSource = nil

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)

        let pidPath = ProcessInfo.processInfo.environment[DAEMON_PID_ENV]
            ?? "/tmp/waifux-video-renderer.pid"
        try? FileManager.default.removeItem(atPath: pidPath)

        for state in screenStates.values {
            state.window?.orderOut(nil)
        }
        _exit(0)
    }

    deinit {
        if let playbackStateObserver {
            DistributedNotificationCenter.default.removeObserver(playbackStateObserver)
        }
    }
}

private final class VideoRendererExceptionHandler: NSObject, @unchecked Sendable {
    static let shared = VideoRendererExceptionHandler()

    @objc override func exceptionHandler(
        _ sender: NSExceptionHandler,
        shouldLogException exception: NSException,
        mask: Int
    ) -> Bool {
        let reason = exception.reason ?? "nil"
        let trace = exception.callStackSymbols.prefix(12).joined(separator: " | ")
        FileHandle.standardError.write(Data(
            "WAIFUX_OBSERVED_EXCEPTION:name=\(exception.name.rawValue) reason=\(reason) trace=\(trace)\n"
                .utf8
        ))
        return true
    }
}

// MARK: - 桌面层窗口

private final class VideoWallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 视频容器视图

/// The renderer-side equivalent of WallpaperVideoContainerView.
///
/// Layer order is deliberate:
///   freezeFrameLayer (last known frame, below the player)
///   playerLayer      (live AVPlayer output)
///   posterLayer      (explicit static cover, above the player)
///
/// The grain view is an AppKit subview, so it remains above the complete
/// Core Animation tree while still following the container bounds.

private final class VideoContainerView: NSView {
    private(set) var playerLayer = AVPlayerLayer()
    /// Keeps the live/freeze/poster layers clipped to the requested viewport
    /// without clipping the outer letterbox background. The old implementation
    /// masked the root layer, which made crop margins transparent and exposed
    /// the system wallpaper underneath.
    private let videoContentLayer = CALayer()
    private var transitionPlayerLayer: AVPlayerLayer?
    private let freezeFrameLayer = CALayer()
    private var posterLayer: CALayer?
    private var grainOverlayView: GrainPatternOverlayView?
    private var readyForDisplayObservation: NSKeyValueObservation?
    private var lastFreezeCaptureTime: CFTimeInterval = 0
    private let freezeCaptureMinInterval: CFTimeInterval = 0.35
    private var currentViewportRect: CGRect?
    private var currentLayerFrame: CGRect?

    var preparedPlayerLayer: AVPlayerLayer? {
        transitionPlayerLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let container = CALayer()
        container.masksToBounds = true
        container.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer = container

        videoContentLayer.frame = bounds
        videoContentLayer.masksToBounds = true
        container.addSublayer(videoContentLayer)

        freezeFrameLayer.contentsGravity = .resizeAspectFill
        freezeFrameLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        freezeFrameLayer.frame = bounds
        freezeFrameLayer.isHidden = false
        videoContentLayer.addSublayer(freezeFrameLayer)

        playerLayer.needsDisplayOnBoundsChange = true
        playerLayer.frame = bounds
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = CGColor(gray: 0, alpha: 0)
        videoContentLayer.addSublayer(playerLayer)

        startReadyForDisplayObservation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        readyForDisplayObservation?.invalidate()
        playerLayer.player = nil
    }

    override func layout() {
        super.layout()
        videoContentLayer.frame = bounds
        let videoFrame = currentLayerFrame ?? bounds
        if currentViewportRect == nil {
            playerLayer.frame = bounds
        } else {
            playerLayer.frame = videoFrame
        }
        freezeFrameLayer.frame = videoFrame
        posterLayer?.frame = videoFrame
        transitionPlayerLayer?.frame = videoFrame
        grainOverlayView?.frame = currentViewportRect ?? bounds
        if let currentViewportRect {
            videoContentLayer.mask?.frame = currentViewportRect
        }
    }

    func attachPlayer(_ player: AVQueuePlayer?) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
        if player == nil || !playerLayer.isReadyForDisplay {
            freezeFrameLayer.isHidden = false
        }
        refreshFreezeFrameVisibility()
    }

    @discardableResult
    func preparePlayerForCrossfade(_ player: AVQueuePlayer) -> AVPlayerLayer {
        discardPreparedPlayerTransition()
        let incoming = AVPlayerLayer(player: player)
        incoming.videoGravity = playerLayer.videoGravity
        incoming.needsDisplayOnBoundsChange = true
        incoming.frame = playerLayer.frame
        incoming.opacity = 0.001
        videoContentLayer.addSublayer(incoming)
        transitionPlayerLayer = incoming
        return incoming
    }

    func discardPreparedPlayerTransition() {
        transitionPlayerLayer?.player = nil
        transitionPlayerLayer?.removeFromSuperlayer()
        transitionPlayerLayer = nil
    }

    func crossfadePreparedPlayer(
        _ newPlayer: AVQueuePlayer,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        guard let incoming = transitionPlayerLayer,
              incoming.player === newPlayer else {
            vlog("crossfade: 无过渡层→硬挂载 ⚠️ freezeActive=\(freezeFrameLayer.contents != nil)")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            attachPlayer(newPlayer)
            CATransaction.commit()
            completion()
            return
        }

        // 已有有效冻结帧（播完即换的最后一帧）时保留不覆盖，
        // 避免被 seek 复位后的第 0 帧或瞬时黑帧顶掉过渡底图。
        if freezeFrameLayer.contents == nil {
            captureFreezeFrameIfNeeded(force: true)
        }
        let fadeDuration = max(0.12, duration)
        vlog("crossfade: 开始 fade=\(fadeDuration) freezeActive=\(freezeFrameLayer.contents != nil)")
        var didComplete = false

        let finish: () -> Void = { [weak self, weak incoming] in
            guard let self, let incoming, !didComplete else { return }
            didComplete = true
            vlog("crossfade: 完成 freezeActive=\(self.freezeFrameLayer.contents != nil)")
            let outgoing = self.playerLayer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            incoming.opacity = 1
            self.playerLayer = incoming
            if self.transitionPlayerLayer === incoming {
                self.transitionPlayerLayer = nil
            }
            outgoing.player = nil
            outgoing.removeFromSuperlayer()
            self.startReadyForDisplayObservation()
            self.refreshFreezeFrameVisibility()
            CATransaction.commit()
            CATransaction.flush()
            completion()
        }

        if duration <= 0.01 {
            finish()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = incoming.presentation()?.opacity ?? incoming.opacity
        fade.toValue = 1
        fade.duration = fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        incoming.add(fade, forKey: "wallpaperCrossfade")
        incoming.opacity = 1
        CATransaction.commit()
        CATransaction.flush()

        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration) {
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration + 0.35) {
            finish()
        }
    }

    func detachPlayer() {
        captureFreezeFrameIfNeeded(force: true)
        discardPreparedPlayerTransition()
        attachPlayer(nil)
    }

    /// Capture the current drawable before pausing. The freeze layer is kept
    /// visible until the live layer has a valid drawable again.
    func freezeForPause() {
        captureFreezeFrameIfNeeded(force: true)
        freezeFrameLayer.isHidden = freezeFrameLayer.contents == nil
        if freezeFrameLayer.contents != nil {
            playerLayer.opacity = 0
        }
    }

    /// 当前是否持有有效的冻结帧
    var isFreezeFrameActive: Bool {
        freezeFrameLayer.contents != nil
    }

    /// 仅保留「当前可见」的冻结帧（播完即换刚冻住的最后一帧）。
    /// 上一轮交接留下的隐藏冻帧必须丢掉再重捕，否则 A→B 会闪出更早的 C。
    func freezeForPausePreservingFrame() {
        let keepVisibleFreeze = freezeFrameLayer.contents != nil
            && freezeFrameLayer.isHidden == false
        if !keepVisibleFreeze {
            clearFreezeFrame()
            captureFreezeFrameIfNeeded(force: true)
        }
        freezeFrameLayer.isHidden = freezeFrameLayer.contents == nil
        if freezeFrameLayer.contents != nil {
            playerLayer.opacity = 0
        }
    }

    /// Resume the live layer without exposing the window background while it
    /// waits for the first drawable after a pause.
    func resumeFromFreeze() {
        playerLayer.opacity = 1
        if playerLayer.isReadyForDisplay {
            vlog("resume: layerReady→延迟藏冻结帧")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playerLayer.isReadyForDisplay else { return }
                self.clearFreezeFrame()
            }
        } else {
            vlog("resume: layer未就绪→保持冻结帧可见")
            freezeFrameLayer.isHidden = false
        }
    }

    private func clearFreezeFrame() {
        freezeFrameLayer.contents = nil
        freezeFrameLayer.isHidden = true
    }

    // MARK: Freeze frame

    private func startReadyForDisplayObservation() {
        readyForDisplayObservation?.invalidate()
        readyForDisplayObservation = playerLayer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let readyFromChange = change.newValue
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isReady = readyFromChange ?? self.playerLayer.isReadyForDisplay
                self.handleReadyForDisplayChanged(isReady)
            }
        }
    }

    @MainActor
    private func handleReadyForDisplayChanged(_ isReady: Bool) {
        if isReady {
            captureFreezeFrameIfNeeded(force: false)
            // AVPlayerLayer can report ready one transaction before its drawable
            // is committed. Keep the captured frame for one main-actor turn.
            Task { @MainActor [weak self] in
                guard let self, self.playerLayer.isReadyForDisplay else { return }
                if self.playerLayer.opacity > 0 {
                    self.freezeFrameLayer.isHidden = true
                }
            }
        } else {
            freezeFrameLayer.isHidden = false
        }
    }

    @MainActor
    private func refreshFreezeFrameVisibility() {
        handleReadyForDisplayChanged(playerLayer.isReadyForDisplay)
    }

    private func captureFreezeFrameIfNeeded(force: Bool) {
        guard playerLayer.isReadyForDisplay else {
            vlog("freeze: SKIP layerNotReady force=\(force)")
            return
        }
        let now = CACurrentMediaTime()
        if !force, now - lastFreezeCaptureTime < freezeCaptureMinInterval {
            return
        }
        lastFreezeCaptureTime = now

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let sourceLayer = playerLayer.presentation() ?? playerLayer

        // AVPlayerLayer sometimes exposes its decoded surface as contents.
        // Reuse it first because this path is cheap and preserves the layer's
        // exact aspect-fill presentation.
        if let contents = sourceLayer.contents {
            // A paused AVPlayerLayer can briefly publish an all-black
            // IOSurface/CGImage while its timebase is settling. Only accept a
            // static CGImage after a black-frame check; live IOSurface contents
            // can go black after seek/pause and would then become the handoff
            // backdrop.
            if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                let image = contents as! CGImage
                if !isMostlyBlack(image) {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    freezeFrameLayer.contents = image
                    freezeFrameLayer.contentsScale = sourceLayer.contentsScale > 0 ? sourceLayer.contentsScale : scale
                    freezeFrameLayer.contentsGravity = sourceLayer.contentsGravity
                    freezeFrameLayer.frame = currentLayerFrame ?? bounds
                    CATransaction.commit()
                    vlog("freeze: contentsDirect OK")
                    return
                }
                vlog("freeze: contentsDirect BLACK-rejected → render fallback")
            } else {
                vlog("freeze: contentsDirect rejected → render fallback")
            }
        } else {
            vlog("freeze: contents=nil → render fallback")
        }

        // Fallback for systems where AVPlayerLayer.contents is not exposed.
        let sourceBounds = playerLayer.bounds
        guard sourceBounds.width > 1, sourceBounds.height > 1 else { return }
        let pixelSize = CGSize(width: sourceBounds.width * scale, height: sourceBounds.height * scale)
        guard pixelSize.width > 1, pixelSize.height > 1 else { return }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width.rounded()),
            pixelsHigh: Int(pixelSize.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return }
        rep.size = sourceBounds.size

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            let cgContext = context.cgContext
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: sourceBounds.height)
            cgContext.scaleBy(x: 1, y: -1)
            sourceLayer.render(in: cgContext)
            cgContext.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = rep.cgImage, !isMostlyBlack(image) else {
            vlog("freeze: renderPath BLACK-rejected ⚠️ 无冻结帧可用")
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        freezeFrameLayer.contents = image
        freezeFrameLayer.contentsScale = scale
        freezeFrameLayer.contentsGravity = .resizeAspectFill
        freezeFrameLayer.frame = currentLayerFrame ?? bounds
        CATransaction.commit()
        vlog("freeze: renderPath OK")
    }

    private func isMostlyBlack(_ image: CGImage) -> Bool {
        let width = min(image.width, 32)
        let height = min(image.height, 32)
        guard width > 0, height > 0 else { return true }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let sampleCount = width * height
        var sum = 0
        var index = 0
        while index < sampleCount {
            let offset = index * 4
            sum += Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
            index += 1
        }
        return Double(sum) / Double(sampleCount * 3) < 6
    }

    // MARK: Poster

    /// Loads a local poster synchronously so the IPC response means the cover
    /// is already installed, which is important when replacing a just-ended
    /// player whose AVPlayerLayer may clear before its next frame.
    @discardableResult
    func showPoster(path: String) -> Bool {
        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        showPoster(cgImage: cgImage)
        return true
    }

    private func showPoster(cgImage: CGImage) {
        hidePoster()

        let poster = CALayer()
        poster.contentsGravity = .resizeAspectFill
        poster.contents = cgImage
        poster.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        poster.frame = currentLayerFrame ?? bounds
        videoContentLayer.addSublayer(poster)
        posterLayer = poster

        // Keep the last valid static image under the live player as a second
        // fallback. Always replace a leftover freeze from an older clip so
        // A→B cannot flash wallpaper C.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        freezeFrameLayer.contents = cgImage
        freezeFrameLayer.contentsGravity = .resizeAspectFill
        freezeFrameLayer.frame = currentLayerFrame ?? bounds
        freezeFrameLayer.isHidden = true
        CATransaction.commit()
    }

    func hidePoster() {
        posterLayer?.removeFromSuperlayer()
        posterLayer = nil
        refreshFreezeFrameVisibility()
    }

    var isShowingPoster: Bool {
        posterLayer != nil
    }

    // MARK: Grain overlay

    func showGrainOverlay(intensity: Double) {
        hideGrainOverlay()
        guard intensity > 0.01 else { return }

        let overlay = GrainPatternOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.intensity = intensity
        addSubview(overlay)
        grainOverlayView = overlay
    }

    func hideGrainOverlay() {
        grainOverlayView?.removeFromSuperview()
        grainOverlayView = nil
    }

    func removeVisualOverlays() {
        hidePoster()
        hideGrainOverlay()
        freezeFrameLayer.contents = nil
    }

    // MARK: Crop

    /// Applies normalized crop and viewport rectangles to both the live video
    /// and its fallback layers. The container mask clips the result so
    /// letterbox pixels remain the configured background color.
    func applyCrop(
        crop: CGRect?,
        viewport: CGRect?,
        letterboxColorHex: String?,
        incomingLayerOnly: Bool = false
    ) {
        guard let crop, let viewport,
              bounds.width > 0, bounds.height > 0,
              crop.width > 0, crop.height > 0,
              viewport.width > 0, viewport.height > 0 else {
            if incomingLayerOnly {
                transitionPlayerLayer?.frame = bounds
                return
            }
            currentViewportRect = nil
            currentLayerFrame = nil
            videoContentLayer.mask = nil
            layer?.backgroundColor = parseColor(letterboxColorHex) ?? CGColor(gray: 0, alpha: 1)
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.frame = bounds
            freezeFrameLayer.frame = bounds
            posterLayer?.frame = bounds
            transitionPlayerLayer?.frame = bounds
            grainOverlayView?.autoresizingMask = [.width, .height]
            grainOverlayView?.frame = bounds
            return
        }

        let clampedViewport = CGRect(
            x: max(0, min(1, viewport.origin.x)),
            y: max(0, min(1, viewport.origin.y)),
            width: max(0.0001, min(1, viewport.width)),
            height: max(0.0001, min(1, viewport.height))
        )
        let clampedCrop = CGRect(
            x: max(0, min(1, crop.origin.x)),
            y: max(0, min(1, crop.origin.y)),
            width: max(0.0001, min(1 - crop.origin.x, crop.width)),
            height: max(0.0001, min(1 - crop.origin.y, crop.height))
        )

        let viewportRect = CGRect(
            x: clampedViewport.minX * bounds.width,
            y: (1 - clampedViewport.maxY) * bounds.height,
            width: clampedViewport.width * bounds.width,
            height: clampedViewport.height * bounds.height
        )
        let videoWidth = viewportRect.width / clampedCrop.width
        let videoHeight = viewportRect.height / clampedCrop.height
        let videoFrame = CGRect(
            x: viewportRect.minX - clampedCrop.minX * videoWidth,
            y: viewportRect.minY - (1 - clampedCrop.maxY) * videoHeight,
            width: videoWidth,
            height: videoHeight
        )

        if incomingLayerOnly {
            transitionPlayerLayer?.frame = videoFrame
            return
        }
        currentViewportRect = viewportRect
        currentLayerFrame = videoFrame
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = videoFrame
        freezeFrameLayer.frame = videoFrame
        posterLayer?.frame = videoFrame
        transitionPlayerLayer?.frame = videoFrame
        grainOverlayView?.autoresizingMask = []
        grainOverlayView?.frame = viewportRect
        layer?.backgroundColor = parseColor(letterboxColorHex) ?? CGColor(gray: 0, alpha: 1)

        let fullViewport = abs(viewportRect.minX) < 0.5
            && abs(viewportRect.minY) < 0.5
            && abs(viewportRect.width - bounds.width) < 0.5
            && abs(viewportRect.height - bounds.height) < 0.5
        if fullViewport {
            videoContentLayer.mask = nil
        } else {
            let mask = videoContentLayer.mask ?? CALayer()
            mask.backgroundColor = CGColor(gray: 1, alpha: 1)
            mask.frame = viewportRect
            videoContentLayer.mask = mask
        }
    }

    private func parseColor(_ hex: String?) -> CGColor? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6 || value.count == 8,
              let raw = UInt64(value, radix: 16) else { return nil }

        let red = CGFloat((raw >> (value.count == 8 ? 24 : 16)) & 0xff) / 255
        let green = CGFloat((raw >> (value.count == 8 ? 16 : 8)) & 0xff) / 255
        let blue = CGFloat((raw >> (value.count == 8 ? 8 : 0)) & 0xff) / 255
        let alpha = value.count == 8 ? CGFloat(raw & 0xff) / 255 : 1
        return CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [red, green, blue, alpha]
        )
    }
}

// MARK: - 视频壁纸颗粒蒙层视图

private final class GrainPatternOverlayView: NSView {
    var intensity: Double = 0.5 {
        didSet { updateOpacity() }
    }

    private var grainImage: CGImage?
    private let tileSize = CGSize(width: 2048, height: 2048)

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        if window != nil {
            setupGrain()
        }
    }

    private func setupGrain() {
        guard let layer else { return }
        if grainImage == nil {
            grainImage = generateFilmGrainTexture(size: tileSize)
        }
        layer.contents = grainImage
        layer.contentsGravity = .resizeAspectFill
        updateOpacity()
    }

    private func updateOpacity() {
        layer?.opacity = Float(max(0, min(1, intensity)) * 0.10)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        layer?.frame = bounds
    }

    private func generateFilmGrainTexture(size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let noiseFilter = CIFilter(name: "CIRandomGenerator") else { return nil }

        let margin: CGFloat = 4
        let noiseSize = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let baseNoise = noiseFilter.outputImage?.cropped(
            to: CGRect(origin: .zero, size: noiseSize)
        ) ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0))

        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(baseNoise, forKey: kCIInputImageKey)
        blurFilter.setValue(0.6, forKey: kCIInputRadiusKey)
        let blurred = blurFilter.outputImage ?? baseNoise

        guard let matrixFilter = CIFilter(name: "CIColorMatrix") else { return nil }
        matrixFilter.setValue(blurred, forKey: kCIInputImageKey)
        matrixFilter.setValue(CIVector(x: 0.10, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0.10, z: 0, w: 0), forKey: "inputGVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0.10, w: 0), forKey: "inputBVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        let grain = matrixFilter.outputImage ?? blurred

        let final = grain.cropped(to: CGRect(
            origin: CGPoint(x: margin, y: margin),
            size: size
        ))
        return context.createCGImage(final, from: final.extent)
    }
}

// MARK: - 入口

@main
struct WallpaperVideoRenderer {
    static func main() {
        let args = CommandLine.arguments

        if args.contains(VERSION_ARG) {
            print("wallpaper-video-renderer 1.0.0")
            return
        }

        // 解析 socket 路径
        var socketPath = "/tmp/waifux-video-renderer.sock"
        if let socketIndex = args.firstIndex(of: SOCKET_PATH_ARG), socketIndex + 1 < args.count {
            socketPath = args[socketIndex + 1]
        }
        var parentPID: pid_t?
        if let parentIndex = args.firstIndex(of: PARENT_PID_ARG),
           parentIndex + 1 < args.count,
           let parsedPID = pid_t(args[parentIndex + 1]) {
            parentPID = parsedPID
        }

        // 先初始化 NSApplication；直接访问 NSApp 会在命令行进程中触发
        // AppKit 全局对象的强制解包崩溃，导致子进程刚启动就 SIGTRAP。
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // 运行 daemon
        let daemon = VideoRendererDaemon.shared
        daemon.run(socketPath: socketPath, parentPID: parentPID)
    }
}
