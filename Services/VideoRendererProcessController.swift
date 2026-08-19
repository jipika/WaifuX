// VideoRendererProcessController.swift
//
// 视频壁纸子进程控制器（主进程侧）。
// 负责：
//   1. 启动/终止 wallpaper-video-renderer 子进程
//   2. 通过 Unix Socket IPC 向子进程发送命令
//   3. 接收子进程上报的事件（首帧就绪、播放结束等）
//
// P1 阶段：与 VideoWallpaperManager 的主进程内渲染路径并存，
// 通过 VideoWallpaperManager.useExternalVideoRenderer 开关切换。
// 验证 Screen Time 不再计入主进程后，再逐步把功能迁移到子进程。

import Foundation
import AppKit
import CoreAudio

/// Renderer 侧音频输出策略。
///
/// `builtInNonBluetooth` 与 VideoWallpaperManager 现有的
/// `audioOutputDeviceUniqueID` 语义一致：静音时固定到内置/非蓝牙输出，
/// 非静音时恢复系统默认输出。
enum VideoRendererAudioOutputStrategy: String, Codable {
    case systemDefault
    case builtInNonBluetooth
}

struct VideoRendererAudioPolicy: Codable, Equatable {
    let muted: Bool
    let volume: Double
    let outputStrategy: VideoRendererAudioOutputStrategy
    let outputDeviceUniqueID: String?

    var effectiveVolume: Double {
        muted ? 0 : volume
    }
}

/// 主进程侧的音频路由策略解析器。
///
/// 仅由视频 renderer 控制器使用，不会影响 Web/Scene 音频。
@MainActor
final class VideoRendererAudioRouting {
    static let shared = VideoRendererAudioRouting()

    private var cachedBuiltInOutputDeviceUID: String?

    func policy(muted: Bool, volume: Double) -> VideoRendererAudioPolicy {
        let clampedVolume = max(0, min(1, volume))
        if muted {
            return VideoRendererAudioPolicy(
                muted: true,
                volume: clampedVolume,
                outputStrategy: .builtInNonBluetooth,
                outputDeviceUniqueID: findBuiltInOutputDeviceUID()
            )
        }

        return VideoRendererAudioPolicy(
            muted: false,
            volume: clampedVolume,
            outputStrategy: .systemDefault,
            outputDeviceUniqueID: nil
        )
    }

    /// 音频设备变化后可由上层主动调用，重新发现内置输出设备。
    func invalidateCachedOutputDevice() {
        cachedBuiltInOutputDeviceUID = nil
    }

    /// 与 VideoWallpaperManager.findBuiltInOutputDeviceUID() 保持相同的选择顺序：
    /// 优先 Built-in/Speaker，其次第一个有输出能力且不是蓝牙类的设备。
    private func findBuiltInOutputDeviceUID() -> String? {
        if let cachedBuiltInOutputDeviceUID {
            return cachedBuiltInOutputDeviceUID
        }

        var propertySize: UInt32 = 0
        var devicesProperty = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesProperty,
            0,
            nil,
            &propertySize
        ) == noErr, propertySize > 0 else {
            return nil
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesProperty,
            0,
            nil,
            &propertySize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        var fallbackUID: String?
        for deviceID in deviceIDs {
            guard deviceID != kAudioObjectUnknown else { continue }

            var outputStreamProperty = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var outputStreamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                deviceID,
                &outputStreamProperty,
                0,
                nil,
                &outputStreamSize
            ) == noErr, outputStreamSize > 0 else {
                continue
            }

            var uidProperty = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(
                deviceID,
                &uidProperty,
                0,
                nil,
                &uidSize,
                &uidRef
            ) == noErr, let retainedUID = uidRef?.takeRetainedValue() as String? else {
                continue
            }

            var transportProperty = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transportType: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            let hasTransport = AudioObjectGetPropertyData(
                deviceID,
                &transportProperty,
                0,
                nil,
                &transportSize,
                &transportType
            ) == noErr
            if hasTransport,
               transportType == kAudioDeviceTransportTypeBluetooth
                || transportType == kAudioDeviceTransportTypeBluetoothLE {
                continue
            }

            if (hasTransport && transportType == kAudioDeviceTransportTypeBuiltIn)
                || retainedUID.localizedCaseInsensitiveContains("built")
                || retainedUID.localizedCaseInsensitiveContains("speaker") {
                cachedBuiltInOutputDeviceUID = retainedUID
                return retainedUID
            }

            if !retainedUID.localizedCaseInsensitiveContains("bluetooth")
                && !retainedUID.localizedCaseInsensitiveContains("airpods")
                && !retainedUID.localizedCaseInsensitiveContains("beats") {
                fallbackUID = fallbackUID ?? retainedUID
            }
        }

        cachedBuiltInOutputDeviceUID = fallbackUID
        return cachedBuiltInOutputDeviceUID
    }
}

/// 子进程上报的事件
enum VideoRendererEvent {
    case ready
    case windowCreated(screen: Int, screenID: String?, requestID: String?)
    case firstFrameReady(screen: Int, screenID: String?, requestID: String?)
    case playbackEnded(screen: Int, screenID: String?, requestID: String?)
    case error(screen: Int?, screenID: String?, requestID: String?, message: String)
    case stopped(screen: Int, screenID: String?, requestID: String?)
    case terminated(status: Int32, expected: Bool)
}

/// 视频壁纸子进程控制器。单例。
@MainActor
final class VideoRendererProcessController {
    static let shared = VideoRendererProcessController()

    // MARK: - 状态

    private var process: Process?
    private var processPID: pid_t = 0
    private var socketPath: String = ""
    private var pidPath: String = ""
    private var generation: UInt64 = 0  // 防止旧进程的退出事件污染新进程状态
    private var expectedTerminationGeneration: UInt64?
    /// `stopDaemon()` cannot block the main actor. Keep stopping PIDs until
    /// their desktop-level windows have actually exited so a following launch
    /// cannot briefly overlap the old renderer.
    private var stoppingPIDs = Set<pid_t>()
    private var eventBuffer = Data()
    private var lastAudioMuted = true
    private var lastAudioVolume = 1.0
    /// All IPC writes share one queue so fire-and-forget maintenance commands
    /// cannot overtake a subsequent `set` or `stop` request.
    private let ipcCommandQueue = DispatchQueue(
        label: "com.waifux.video-renderer.ipc-client",
        qos: .userInitiated
    )
    /// Crop 更新可能在拖动和显示器布局变更时密集产生。只保留每屏最新值，
    /// 防止大量无响应 IPC 排队到 renderer 的主线程，阻塞后续 set/stop。
    private var pendingCropCommands: [Int: Command] = [:]
    private var cropFlushScheduled = false

    /// 事件回调（主线程）
    var eventHandler: ((VideoRendererEvent) -> Void)?

    /// 子进程是否存活
    var isRunning: Bool {
        guard processPID > 0 else { return false }
        return kill(processPID, 0) == 0
    }

    // MARK: - 启动 / 停止子进程

    /// 启动 wallpaper-video-renderer 子进程。
    /// - Returns: true 表示启动成功且子进程已就绪
    @discardableResult
    func startDaemon() async -> Bool {
        if isRunning {
            // 存活 ≠ 健康：socket 可连只代表内核 accept 队列在工作，daemon
            // 主线程卡死时连接照样成功但任何命令都无响应。必须 ping 通过才
            // 算可用，否则「活而不答」的 daemon 会永远挡住新启动（即用户
            // 反馈的「只能手动杀进程」楔死点）。
            if await waitForSocket(timeout: 2.0),
               await sendCommand(.ping, screen: nil, timeout: 1.5) == "OK" {
                AppLogger.info(.wallpaper, "video-renderer 子进程已在运行，跳过启动")
                return true
            }
            AppLogger.error(.wallpaper, "video-renderer 进程仍存活但不响应 IPC，强制重启渲染器")
            stopDaemon()
        }

        await waitForStoppingRenderers()
        await terminateOrphanedRenderers()

        guard let executableURL = resolvedExecutableURL() else {
            AppLogger.error(.wallpaper, "未找到 wallpaper-video-renderer 二进制")
            return false
        }

        generation &+= 1
        let currentGen = generation
        expectedTerminationGeneration = nil

        // 每次启动用独立 socket 路径，避免与旧进程残留冲突
        socketPath = "/tmp/waifux-video-renderer-\(currentGen).sock"
        pidPath = "/tmp/waifux-video-renderer-\(currentGen).pid"

        // 清理旧文件
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidPath)

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = [
            "--socket", socketPath,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        proc.environment = ProcessInfo.processInfo.environment
        proc.environment?["WAIFUX_VIDEO_RENDERER_PID_PATH"] = pidPath
        proc.environment?["LSUIElement"] = "1"  // 无 Dock 图标
        if let lockStateURL = LockScreenWallpaperService.shared.playbackStateURL {
            proc.environment?["WAIFUX_VIDEO_RENDERER_LOCK_STATE_PATH"] = lockStateURL.path
        }

        // Events go to stdout so diagnostic vlog on stderr cannot glue/split
        // firstFrameReady lines during rapid switches.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let copy = data
            Task { @MainActor in
                self?.handleEventStreamData(copy)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let copy = data
            Task { @MainActor in
                self?.handleDiagnosticStreamData(copy)
            }
        }

        proc.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                guard let self else { return }
                self.stoppingPIDs.remove(terminatedProcess.processIdentifier)
                // 只有当前 generation 的进程退出才处理，防止旧进程退出污染新进程
                guard self.generation == currentGen else { return }
                let expected = self.expectedTerminationGeneration == currentGen
                if expected {
                    self.expectedTerminationGeneration = nil
                }
                AppLogger.info(.wallpaper, "video-renderer 子进程退出 code=\(terminatedProcess.terminationStatus)")
                self.process = nil
                self.processPID = 0
                // 清理 socket 文件
                try? FileManager.default.removeItem(atPath: self.socketPath)
                try? FileManager.default.removeItem(atPath: self.pidPath)
                self.eventHandler?(
                    .terminated(
                        status: terminatedProcess.terminationStatus,
                        expected: expected
                    )
                )
            }
        }

        do {
            try proc.run()
            process = proc
            processPID = proc.processIdentifier
            AppLogger.info(.wallpaper, "video-renderer 子进程已启动 pid=\(processPID) socket=\(socketPath)")
            guard await waitForSocket(timeout: 2.0) else {
                AppLogger.error(.wallpaper, "video-renderer 子进程启动后未监听 socket")
                terminateFailedLaunch(proc)
                return false
            }
            guard await sendCommand(.ping, screen: nil, timeout: 1.0) == "OK" else {
                AppLogger.error(.wallpaper, "video-renderer socket 已出现但 ping 未通过")
                terminateFailedLaunch(proc)
                return false
            }
            return true
        } catch {
            AppLogger.error(.wallpaper, "video-renderer 子进程启动失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 停止子进程
    func stopDaemon() {
        guard isRunning else { return }
        AppLogger.info(.wallpaper, "停止 video-renderer 子进程 pid=\(processPID)")
        expectedTerminationGeneration = generation
        pendingCropCommands.removeAll()
        cropFlushScheduled = false

        // 不能在 MainActor 上等待 helper 的回包或退出。helper 会自行处理 shutdown；
        // SIGTERM 作为立即兜底，watchdog 仍会在它卡死时收尾。
        sendCommandFireAndForget(.shutdown)
        let pid = processPID
        stoppingPIDs.insert(pid)
        kill(pid, SIGTERM)

        // watchdog: 2s 后 SIGKILL
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 2.0)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }

        process = nil
        processPID = 0
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// daemon 是否仍在响应 IPC（短超时 ping 探测，用于区分「活而不答」）。
    /// 进程存活但主线程/IPC 卡死时 connect 依旧成功，只有 ping 能鉴别。
    func isDaemonResponsive(timeout: TimeInterval = 1.5) async -> Bool {
        guard isRunning else { return false }
        return await sendCommand(.ping, screen: nil, timeout: timeout) == "OK"
    }

    /// 强制换代重启：处理进程存活但 IPC 无响应的卡死态
    @discardableResult
    func restartDaemon() async -> Bool {
        if isRunning {
            stopDaemon()
        }
        return await startDaemon()
    }

    // MARK: - IPC 客户端

    /// IPC 命令（与子进程的 IPCCommand 枚举对应）
    enum Command {
        case set(
            screen: Int,
            screenID: String,
            requestID: String,
            path: String,
            posterPath: String?,
            frame: CGRect,
            muted: Bool,
            volume: Double,
            looping: Bool,
            shared: Bool,
            forceNewPipeline: Bool,
            hdrMetadataEnabled: Bool,
            deferredPresentation: Bool,
            transitionDuration: Double,
            globalPaused: Bool,
            screenPaused: Bool,
            globalDisplaySyncEnabled: Bool
        )
        case pause(screen: Int?)
        case resume(screen: Int?)
        case stop(screen: Int?)
        case seek(screen: Int, time: Double)
        case setVolume(screen: Int?, volume: Double)
        case setMuted(Bool)
        case setCrop(screen: Int, crop: CGRect?, viewport: CGRect?, letterboxColor: String?, revision: UInt64?)
        case updatePoster(screen: Int, path: String?)
        case showPoster(screen: Int, path: String)
        case hidePoster(screen: Int)
        case setGrainOverlay(screen: Int?, intensity: Double)
        case bringToFront(screen: Int)
        case revealPreparedWindow(screen: Int)
        case commitTransition(requestID: String)
        case cancelTransition(requestID: String)
        case forceCommit(screen: Int?)
        case pruneInactiveScreens(screenIDs: [String])
        case prewarm(screen: Int, path: String, volume: Double, hdrMetadataEnabled: Bool)
        case ping
        case refreshPlaybackState
        case shutdown
    }

    /// 发送命令并等待响应。socket I/O 始终在 worker queue 上执行，因此在
    /// `@MainActor` 调用时会让出 AppKit 事件循环，不会把 HID 事件卡在 recv()。
    @discardableResult
    func sendCommand(_ cmd: Command, screen: Int?, timeout: TimeInterval = 5.0) async -> String? {
        guard isRunning else {
            AppLogger.error(.wallpaper, "video-renderer 子进程未运行，无法发送命令")
            return nil
        }

        let msg = encodeCommand(cmd)
        guard let body = try? JSONEncoder().encode(msg) else { return nil }
        let startedAt = Date()
        let currentSocketPath = socketPath

        let response: String? = await withCheckedContinuation { continuation in
            ipcCommandQueue.async {
                continuation.resume(
                    returning: Self.sendOverSocket(
                        socketPath: currentSocketPath,
                        body: body,
                        timeout: timeout
                    )
                )
            }
        }
        if response == nil {
            AppLogger.error(.wallpaper, "video-renderer IPC 超时或连接失败", metadata: [
                "command": msg.command,
                "screen": screen.map(String.init) ?? "all",
                "timeout": String(format: "%.2f", timeout),
                "elapsed": String(format: "%.3f", Date().timeIntervalSince(startedAt))
            ])
        }
        return response
    }

    /// 发送命令但不等待响应（fire-and-forget，用于高频命令）
    func sendCommandFireAndForget(_ cmd: Command) {
        guard isRunning else { return }
        if case .setCrop(let screen, _, _, _, _) = cmd {
            pendingCropCommands[screen] = cmd
            guard !cropFlushScheduled else { return }
            cropFlushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33)) { [weak self] in
                self?.flushPendingCropCommands()
            }
            return
        }

        sendCommandFireAndForgetImmediately(cmd)
    }

    private func flushPendingCropCommands() {
        cropFlushScheduled = false
        let commands = pendingCropCommands
            .sorted { $0.key < $1.key }
            .map(\.value)
        pendingCropCommands.removeAll()

        for command in commands {
            sendCommandFireAndForgetImmediately(command)
        }
    }

    private func sendCommandFireAndForgetImmediately(_ cmd: Command) {
        guard isRunning else { return }
        let msg = encodeCommand(cmd, expectsResponse: false)
        guard let body = try? JSONEncoder().encode(msg) else { return }
        let currentSocketPath = socketPath

        ipcCommandQueue.async {
            Self.sendOverSocketFireAndForget(
                socketPath: currentSocketPath,
                body: body
            )
        }
    }

    // MARK: - 私有

    /// `Process.run()` 只代表 fork/exec 成功，不代表 daemon 已完成 bind/listen。
    /// 等待 socket 出现，避免首条 set 命令撞在子进程初始化窗口上。
    private func waitForSocket(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await socketIsReachable() {
                return true
            }
            guard isRunning else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await socketIsReachable() && isRunning
    }

    private func socketIsReachable() async -> Bool {
        let currentSocketPath = socketPath
        return await Task.detached(priority: .userInitiated) {
            Self.socketIsReachable(socketPath: currentSocketPath)
        }.value
    }

    private nonisolated static func socketIsReachable(socketPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let sunPathSize = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let count = min(pathBytes.count - 1, sunPathSize - 1)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            for i in 0..<count {
                dest[i] = UInt8(bitPattern: pathBytes[i])
            }
        }

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private func terminateFailedLaunch(_ proc: Process) {
        expectedTerminationGeneration = generation
        if proc.isRunning {
            stoppingPIDs.insert(proc.processIdentifier)
            kill(proc.processIdentifier, SIGTERM)
        }
        process = nil
        processPID = 0
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// Wait only when a replacement is about to launch. Normal stop paths
    /// remain non-blocking on the main actor, while restart paths guarantee
    /// the old renderer's desktop windows are gone before the next process is
    /// allowed to create its own windows.
    private func waitForStoppingRenderers() async {
        stoppingPIDs = stoppingPIDs.filter(Self.isProcessAlive)
        guard !stoppingPIDs.isEmpty else { return }

        let gracefulDeadline = Date().addingTimeInterval(0.6)
        while Date() < gracefulDeadline, !stoppingPIDs.isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
            stoppingPIDs = stoppingPIDs.filter(Self.isProcessAlive)
        }

        guard !stoppingPIDs.isEmpty else { return }
        let stuckPIDs = stoppingPIDs
        AppLogger.error(.wallpaper, "video-renderer 停止超时，强制清理后再启动", metadata: [
            "pids": stuckPIDs.map(String.init).sorted().joined(separator: ",")
        ])
        for pid in stuckPIDs {
            kill(pid, SIGKILL)
        }

        let forceDeadline = Date().addingTimeInterval(0.2)
        while Date() < forceDeadline, !stoppingPIDs.isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
            stoppingPIDs = stoppingPIDs.filter(Self.isProcessAlive)
        }
    }

    /// A renderer normally dies with its App parent. If Xcode terminates the
    /// host abruptly, a stale helper can remain at desktop level and keep
    /// showing a frozen old frame above the new renderer. Only processes
    /// reparented to launchd are eligible, so a live WaifuX session is untouched.
    private func terminateOrphanedRenderers() async {
        let stalePIDs = Self.orphanedRendererPIDs()
        guard !stalePIDs.isEmpty else { return }

        AppLogger.error(.wallpaper, "清理孤儿 video-renderer 进程", metadata: [
            "pids": stalePIDs.map(String.init).joined(separator: ",")
        ])
        for pid in stalePIDs {
            kill(pid, SIGTERM)
        }

        let gracefulDeadline = Date().addingTimeInterval(0.4)
        while Date() < gracefulDeadline,
              stalePIDs.contains(where: Self.isProcessAlive) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        for pid in stalePIDs where Self.isProcessAlive(pid) {
            kill(pid, SIGKILL)
        }
    }

    private static func orphanedRendererPIDs() -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else {
                return []
            }
            return text
                .split(separator: "\n")
                .compactMap { line -> pid_t? in
                    let fields = line.split(
                        maxSplits: 2,
                        whereSeparator: { $0 == " " || $0 == "\t" }
                    )
                    guard fields.count == 3,
                          let pid = pid_t(fields[0]),
                          let parentPID = pid_t(fields[1]),
                          parentPID == 1,
                          pid > 1 else {
                        return nil
                    }
                    let command = String(fields[2])
                    guard command.contains("wallpaper-video-renderer"),
                          command.contains("--socket"),
                          command.contains("/tmp/waifux-video-renderer-") else {
                        return nil
                    }
                    return pid
                }
        } catch {
            return []
        }
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func resolvedExecutableURL() -> URL? {
        // 查找优先级与 WallpaperEngineXBridge.resolvedCLIExecutableURL 一致
        let candidates: [URL] = [
            Bundle.main.url(forResource: "wallpaper-video-renderer", withExtension: nil),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/wallpaper-video-renderer"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Resources/wallpaper-video-renderer"),
            Bundle.main.resourceURL?.appendingPathComponent("wallpaper-video-renderer"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wallpaper-video-renderer"),
            // 开发 fallback
            URL(fileURLWithPath: "/Volumes/mac/CodeLibrary/Claude/WallHaven/wallpaper-video-renderer"),
            URL(fileURLWithPath: "/Volumes/mac/CodeLibrary/Claude/WallHaven/Resources/wallpaper-video-renderer"),
        ].compactMap { $0 }

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: 命令编码

    private struct IPCMessageDTO: Codable {
        var command: String
        var expectsResponse: Bool?
        var screen: Int?
        var screenID: String?
        var requestID: String?
        var path: String?
        var screenFrameX: Double?
        var screenFrameY: Double?
        var screenFrameW: Double?
        var screenFrameH: Double?
        var muted: Bool?
        var volume: Double?
        var audioEffectiveVolume: Double?
        var audioOutputDeviceStrategy: String?
        var audioOutputDeviceUniqueID: String?
        var enableLooping: Bool?
        var usesSharedDecoder: Bool?
        var forceNewPipeline: Bool?
        var hdrMetadataEnabled: Bool?
        var deferredPresentation: Bool?
        var transitionDuration: Double?
        var globalPaused: Bool?
        var screenPaused: Bool?
        var globalDisplaySyncEnabled: Bool?
        var time: Double?
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
        var posterPath: String?
        var grainIntensity: Double?
        var activeScreenIDs: [String]?
        var message: String?
    }

    private func encodeCommand(
        _ cmd: Command,
        expectsResponse: Bool = true
    ) -> IPCMessageDTO {
        var msg = IPCMessageDTO(
            command: "",
            expectsResponse: expectsResponse,
            screen: nil,
            screenID: nil,
            requestID: nil,
            path: nil,
            screenFrameX: nil,
            screenFrameY: nil,
            screenFrameW: nil,
            screenFrameH: nil,
            muted: nil,
            volume: nil,
            audioEffectiveVolume: nil,
            audioOutputDeviceStrategy: nil,
            audioOutputDeviceUniqueID: nil,
            enableLooping: nil,
            usesSharedDecoder: nil,
            forceNewPipeline: nil,
            hdrMetadataEnabled: nil,
            deferredPresentation: nil,
            transitionDuration: nil,
            globalPaused: nil,
            screenPaused: nil,
            globalDisplaySyncEnabled: nil,
            time: nil,
            cropX: nil,
            cropY: nil,
            cropW: nil,
            cropH: nil,
            viewportX: nil,
            viewportY: nil,
            viewportW: nil,
            viewportH: nil,
            letterboxColorHex: nil,
            cropRevision: nil,
            posterPath: nil,
            grainIntensity: nil,
            activeScreenIDs: nil,
            message: nil
        )

        switch cmd {
        case .set(
            let screen,
            let screenID,
            let requestID,
            let path,
            let posterPath,
            let frame,
            let muted,
            let volume,
            let looping,
            let shared,
            let forceNewPipeline,
            let hdrMetadataEnabled,
            let deferredPresentation,
            let transitionDuration,
            let globalPaused,
            let screenPaused,
            let globalDisplaySyncEnabled
        ):
            msg.command = "set"
            msg.screen = screen
            msg.screenID = screenID
            msg.requestID = requestID
            msg.path = path
            msg.posterPath = posterPath
            msg.screenFrameX = frame.origin.x
            msg.screenFrameY = frame.origin.y
            msg.screenFrameW = frame.size.width
            msg.screenFrameH = frame.size.height
            msg.muted = muted
            msg.volume = volume
            msg.enableLooping = looping
            msg.usesSharedDecoder = shared
            msg.forceNewPipeline = forceNewPipeline
            msg.hdrMetadataEnabled = hdrMetadataEnabled
            msg.deferredPresentation = deferredPresentation
            msg.transitionDuration = transitionDuration
            msg.globalPaused = globalPaused
            msg.screenPaused = screenPaused
            msg.globalDisplaySyncEnabled = globalDisplaySyncEnabled
            lastAudioMuted = muted
            lastAudioVolume = max(0, min(1, volume))
            updateAudioPolicyFields(
                in: &msg,
                muted: muted,
                volume: lastAudioVolume
            )

        case .pause(let screen):
            msg.command = "pause"
            msg.screen = screen
            msg.screenID = screen.flatMap(stableScreenID(for:))

        case .resume(let screen):
            msg.command = "resume"
            msg.screen = screen
            msg.screenID = screen.flatMap(stableScreenID(for:))

        case .stop(let screen):
            msg.command = "stop"
            msg.screen = screen
            msg.screenID = screen.flatMap(stableScreenID(for:))

        case .seek(let screen, let time):
            msg.command = "seek"
            msg.screen = screen
            msg.screenID = stableScreenID(for: screen)
            msg.time = time

        case .setVolume(let screen, let vol):
            msg.command = "setVolume"
            msg.screen = screen
            msg.screenID = screen.flatMap(stableScreenID(for:))
            lastAudioVolume = max(0, min(1, vol))
            msg.volume = lastAudioVolume
            // Carry the complete snapshot so the renderer can preserve the
            // anti-Bluetooth route while the volume slider changes.
            msg.muted = lastAudioMuted
            updateAudioPolicyFields(
                in: &msg,
                muted: lastAudioMuted,
                volume: lastAudioVolume
            )

        case .setMuted(let muted):
            msg.command = "setMuted"
            lastAudioMuted = muted
            msg.muted = muted
            msg.volume = lastAudioVolume
            updateAudioPolicyFields(
                in: &msg,
                muted: muted,
                volume: lastAudioVolume
            )

        case .setCrop(let screen, let crop, let viewport, let letterboxColor, let revision):
            msg.command = "setCrop"
            msg.screen = screen
            msg.screenID = stableScreenID(for: screen)
            if let crop {
                msg.cropX = crop.origin.x
                msg.cropY = crop.origin.y
                msg.cropW = crop.size.width
                msg.cropH = crop.size.height
            }
            if let viewport {
                msg.viewportX = viewport.origin.x
                msg.viewportY = viewport.origin.y
                msg.viewportW = viewport.size.width
                msg.viewportH = viewport.size.height
            }
            msg.letterboxColorHex = letterboxColor
            msg.cropRevision = revision

        case .updatePoster(let screen, let path):
            msg.command = "updatePoster"
            msg.screen = screen
            msg.screenID = stableScreenID(for: screen)
            msg.posterPath = path

        case .showPoster(let screen, let path):
            msg.command = "showPoster"
            msg.screen = screen
            msg.screenID = stableScreenID(for: screen)
            msg.posterPath = path

        case .hidePoster(let screen):
            msg.command = "hidePoster"
            msg.screen = screen
            msg.screenID = stableScreenID(for: screen)

        case .setGrainOverlay(let screen, let intensity):
            msg.command = "setGrainOverlay"
            msg.screen = screen
            msg.screenID = screen.flatMap(stableScreenID(for:))
            msg.grainIntensity = max(0, min(1, intensity))

        case .bringToFront(let screen):
            msg.command = "bringToFront"
            msg.screen = screen
            msg.screenID = stableScreenID(for: screen)

        case .revealPreparedWindow(let screen):
            msg.command = "revealPreparedWindow"
            msg.screen = screen
            msg.screenID = stableScreenID(for: screen)

        case .commitTransition(let requestID):
            msg.command = "commitTransition"
            msg.requestID = requestID

        case .cancelTransition(let requestID):
            msg.command = "cancelTransition"
            msg.requestID = requestID

        case .forceCommit(let screen):
            msg.command = "forceCommit"
            msg.screen = screen
            msg.screenID = screen.flatMap(stableScreenID(for:))

        case .pruneInactiveScreens(let screenIDs):
            msg.command = "pruneInactiveScreens"
            msg.activeScreenIDs = screenIDs

        case .prewarm(let screen, let path, let volume, let hdrMetadataEnabled):
            msg.command = "prewarm"
            msg.screen = screen
            msg.path = path
            msg.volume = volume
            msg.hdrMetadataEnabled = hdrMetadataEnabled

        case .ping:
            msg.command = "ping"

        case .refreshPlaybackState:
            msg.command = "refreshPlaybackState"

        case .shutdown:
            msg.command = "shutdown"
        }

        return msg
    }

    private func stableScreenID(for screen: Int?) -> String? {
        guard let screen else { return nil }
        let orderedScreens = NSScreen.screensOrderedForDisplay
        guard orderedScreens.indices.contains(screen) else { return nil }
        return orderedScreens[screen].wallpaperScreenIdentifier
    }

    private func updateAudioPolicyFields(
        in msg: inout IPCMessageDTO,
        muted: Bool,
        volume: Double
    ) {
        let policy = VideoRendererAudioRouting.shared.policy(muted: muted, volume: volume)
        msg.audioOutputDeviceStrategy = policy.outputStrategy.rawValue
        msg.audioOutputDeviceUniqueID = policy.outputDeviceUniqueID
        msg.audioEffectiveVolume = policy.effectiveVolume
    }

    // MARK: Socket 操作

    private nonisolated static func sendOverSocket(socketPath: String, body: Data, timeout: TimeInterval) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        // 给发送和接收都设限，避免 helper 的 accept 队列、主线程或 socket
        // 缓冲区异常时 worker 长时间挂在内核调用里。
        var tv = timeval(tv_sec: Int(timeout), tv_usec: __darwin_suseconds_t((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let sunPathSize = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let count = min(pathBytes.count - 1, sunPathSize - 1)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            for i in 0..<count {
                dest[i] = UInt8(bitPattern: pathBytes[i])
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        // 发送长度前缀 + body
        var length = UInt32(body.count)
        let headerData = Data(bytes: &length, count: 4)
        let payload = headerData + body

        guard writeAll(fd: fd, data: payload) else { return nil }

        // 接收响应
        var responseBuf = [UInt8](repeating: 0, count: 256)
        let received = responseBuf.withUnsafeMutableBufferPointer { buf in
            recv(fd, buf.baseAddress, buf.count, 0)
        }
        guard received > 0 else { return nil }

        return String(bytes: responseBuf.prefix(received), encoding: .utf8)
    }

    private nonisolated static func sendOverSocketFireAndForget(socketPath: String, body: Data) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var noSigPipe: Int32 = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let sunPathSize = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let count = min(pathBytes.count - 1, sunPathSize - 1)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            for i in 0..<count {
                dest[i] = UInt8(bitPattern: pathBytes[i])
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            close(fd)
            return
        }

        var length = UInt32(body.count)
        let headerData = Data(bytes: &length, count: 4)
        let payload = headerData + body

        guard writeAll(fd: fd, data: payload) else {
            close(fd)
            return
        }

        // shutdown 写端，让服务端 recv 返回
        shutdown(fd, SHUT_WR)
        close(fd)
    }

    private nonisolated static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return data.isEmpty }
            var written = 0
            while written < buffer.count {
                let count = send(
                    fd,
                    baseAddress.advanced(by: written),
                    buffer.count - written,
                    0
                )
                if count < 0 && errno == EINTR {
                    continue
                }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
    }

    // MARK: stdout 事件解析

    private func handleEventStreamData(_ data: Data) {
        eventBuffer.append(data)
        guard let str = String(data: eventBuffer, encoding: .utf8) else { return }
        let lines = str.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return }
        if !str.hasSuffix("\n") {
            eventBuffer = Data(lines.last!.utf8)
        } else {
            eventBuffer.removeAll(keepingCapacity: true)
        }

        for line in lines.dropLast(str.hasSuffix("\n") ? 0 : 1) {
            if line.isEmpty { continue }
            guard line.hasPrefix("WAIFUX_EVENT:") else { continue }
            let jsonStr = String(line.dropFirst("WAIFUX_EVENT:".count))
            guard let jsonData = jsonStr.data(using: .utf8),
                  let evt = try? JSONDecoder().decode(EventDTO.self, from: jsonData) else {
                continue
            }

            let event: VideoRendererEvent
            switch evt.event {
            case "ready":
                event = .ready
            case "windowCreated":
                event = .windowCreated(
                    screen: evt.screen ?? -1,
                    screenID: evt.screenID,
                    requestID: evt.requestID
                )
            case "firstFrameReady":
                event = .firstFrameReady(
                    screen: evt.screen ?? -1,
                    screenID: evt.screenID,
                    requestID: evt.requestID
                )
            case "playbackEnded":
                event = .playbackEnded(
                    screen: evt.screen ?? -1,
                    screenID: evt.screenID,
                    requestID: evt.requestID
                )
            case "error":
                event = .error(
                    screen: evt.screen,
                    screenID: evt.screenID,
                    requestID: evt.requestID,
                    message: evt.message ?? ""
                )
            case "stopped":
                event = .stopped(
                    screen: evt.screen ?? -1,
                    screenID: evt.screenID,
                    requestID: evt.requestID
                )
            default:
                continue
            }

            Task { @MainActor in
                self.eventHandler?(event)
            }
        }
    }

    private func handleDiagnosticStreamData(_ data: Data) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        for rawLine in str.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("WAIFUX_FATAL_EXCEPTION:") {
                AppLogger.error(.wallpaper, "wallpaper-video-renderer 未捕获异常", metadata: [
                    "diagnostic": line
                ])
            } else if line.hasPrefix("WAIFUX_OBSERVED_EXCEPTION:") {
                AppLogger.error(.wallpaper, "wallpaper-video-renderer 捕获到 Objective-C 异常", metadata: [
                    "diagnostic": line
                ])
            } else if line.hasPrefix("WAIFUX_DIAG:") {
                AppLogger.debug(.wallpaper, "video-renderer 诊断", metadata: [
                    "d": String(line.dropFirst("WAIFUX_DIAG:".count))
                ])
            }
        }
    }

    private struct EventDTO: Codable {
        let event: String
        let screen: Int?
        let screenID: String?
        let requestID: String?
        let message: String?
    }
}
