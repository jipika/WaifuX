#if !WAIFUX_HELPER
import AppKit
import Combine
import ServiceManagement

private final class BackgroundClientObserver: NSObject, BackgroundAgentObserver, @unchecked Sendable {
    let generation: UInt64
    init(generation: UInt64) { self.generation = generation }
    func snapshotChanged(_ data: NSData) {
        let bytes = data as Data
        Task { @MainActor in BackgroundAgentClient.shared.receive(bytes, from: generation) }
    }
    func openUI(_ action: String) {
        Task { @MainActor in
            guard BackgroundAgentClient.shared.acceptsConnectionGeneration(generation) else { return }
            if let action = WaifuXUIActions.Action(rawValue: action) { WaifuXUIActions.perform(action) }
        }
    }
}

private final class BackgroundDiagnosticObserver: NSObject, BackgroundAgentObserver {
    func snapshotChanged(_ data: NSData) {}
    func openUI(_ action: String) {}
}

private final class BackgroundReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeout: Task<Void, Never>?
    private var result: Result<Data, Error>?
    func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        lock.unlock()
    }
    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let current = continuation
        continuation = nil
        let timer = timeout
        timeout = nil
        lock.unlock()
        timer?.cancel()
        current?.resume(with: result)
    }
    func setTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        if result != nil { lock.unlock(); task.cancel(); return }
        timeout = task
        lock.unlock()
    }
}

@MainActor
final class BackgroundAgentClient: ObservableObject {
    static let shared = BackgroundAgentClient()
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    @Published private(set) var requiresApproval = false
    private var connection: NSXPCConnection?
    private var connectionGeneration: UInt64 = 0
    private var bootstrapGeneration: UInt64 = 0
    private var reconnectGeneration: UInt64 = 0
    private var handlers: [([String: Any]) -> Void] = []
    private var libraryHandlers: [([String: Any]) -> Void] = []
    private var latestLibrary: [String: Any] = [:]
    private var libraryRevision: UInt64?
    private var libraryFetchTask: Task<Void, Never>?
    private var libraryFetchGeneration: UInt64 = 0
    private var latestSnapshot: [String: Any] = [:]
    private var commandTail: Task<Data, Error>?
    private var bootstrapTask: Task<Void, Error>?
    private var reconnectTask: Task<Void, Never>?
    private var isClosing = false
    private var isBootstrapping = false
    /// launchd 脱节修复的互斥位：同一时刻只允许一轮 unregister/register。
    /// 连点重试会 cancel 旧 bootstrapTask，但 SMAppService 的注销/注册不响应
    /// 取消，两轮交错会互相把刚注册的 job 注销掉。
    private var isRepairingRegistration = false
    private var isQuittingApplication = false
    /// Helper 已确认 `runtime.stop`：此刻它正在不可逆地收尾，失败后不能再
    /// 自动重连（会把正在退出的后台服务重新拉起）。
    private var helperStopRequested = false
    private var observedHelperStop = false
    private var knownHelperPID: Int32?
    var onApplicationQuitRequested: (() -> Void)?
    var onHelperStopped: (() -> Void)?
    private var pendingCropCommands: [String: [String: Any]] = [:]
    private var cropFlushTask: Task<Void, Never>?
    #if DEBUG
    private var isolatedProbeService: String?
    private var pausedHelperProbePID: Int32?
    private var obsoleteObserverProbe: BackgroundClientObserver?
    private var obsoleteInvalidationProbe: (() -> Void)?
    #endif

    private init() {}

    func retryConnection() {
        guard !isQuittingApplication else { return }
        disconnect()
        bootstrapTask?.cancel()
        bootstrapTask = nil
        start()
    }

    func start() {
        guard bootstrapTask == nil, !isQuittingApplication else { return }
        isClosing = false
        requiresApproval = false
        isBootstrapping = true
        bootstrapGeneration &+= 1
        let generation = bootstrapGeneration
        WaifuXPreferences.shared.loadLegacyPreferences()
        bootstrapTask = Task {
            defer { if generation == bootstrapGeneration { isBootstrapping = false } }
            do {
                try await runBootstrap()
            } catch {
                // 三类可自愈的失败：
                // ① BTM 记录与 launchd 域脱节（job 被 bootout 过，或应用重建后
                //    BTM 没把 job 重新下发），连接以 NSCocoaErrorDomain 4099 失败；
                // ② 用户用新包替换旧版本后，launchd 的 KeepAlive 仍持有旧 helper、
                //    原地升级又失败 —— hello 成功但身份/协议不符。
                // ③ job 在 launchd 里存在、mach service 端口能连上（所以不是 4099），
                //    但 bootstrap 阶段 hello/首波 RPC 120s 无响应 —— launchd spawn
                //    循环失败（EX_CONFIG 类约束拒绝）或 Helper 起来后卡死都是这个
                //    形态（2026-10-24 本机实测：job spawn failed 24516 次，
                //    status=1 却只报「后台服务响应超时」，repair 永远不触发）。
                // 三者都只能靠注销重注册恢复。
                let staleHelper = Self.indicatesStaleHelper(error)
                let unresponsive = Self.indicatesUnresponsiveHelper(error)
                guard staleHelper || unresponsive || Self.indicatesMissingLaunchdJob(error) else { throw error }
                // 同一时刻只允许一轮 repair：连点「重试」只 cancel 旧的
                // bootstrapTask，而 SMAppService 的注销/注册不响应取消，
                // 两轮交错会把刚注册好的 job 又注销掉（实测一秒内三次 4099）。
                guard !isRepairingRegistration else {
                    AppLogger.error(.startup, "Helper repair already in flight, skipping",
                                    metadata: ["code": (error as NSError).code])
                    throw CancellationError()
                }
                isRepairingRegistration = true
                defer { isRepairingRegistration = false }
                AppLogger.error(.startup,
                                staleHelper
                                    ? "Helper outdated after replacement, repairing registration"
                                    : unresponsive
                                        ? "Helper unresponsive during bootstrap (120s no reply), repairing registration"
                                        : "Helper service missing from launchd, repairing registration",
                                metadata: ["code": (error as NSError).code,
                                           "detail": error.localizedDescription])
                try Task.checkCancellation()
                let service = SMAppService.agent(plistName: BackgroundAgentWire.plistName)
                do {
                    try await BackgroundAgentRegistration.repairLaunchdRegistration(service) { [weak self] in
                        guard let self else { return false }
                        return await self.probeHelperReachable()
                    }
                    AppLogger.error(.startup, "Helper registration repaired",
                                    metadata: ["status": service.status.rawValue])
                } catch {
                    AppLogger.error(.startup, "Helper registration repair failed",
                                    metadata: ["status": service.status.rawValue,
                                               "error": error.localizedDescription])
                    throw error
                }
                try Task.checkCancellation()
                try await runBootstrap()
            }
        }
        let startedTask = bootstrapTask
        Task {
            do { try await startedTask?.value }
            catch {
                // 连点「重试」会推进 generation。旧代际的失败仍要留痕，否则
                // 日志里只剩 4099、看不到真正抛错的那一轮（2026-10-19 排查踩点）。
                guard generation == bootstrapGeneration else {
                    AppLogger.error(.startup, "Helper startup failed (superseded)",
                                    metadata: ["generation": generation,
                                               "error": error.localizedDescription])
                    return
                }
                lastError = error.localizedDescription
                if case BackgroundAgentRegistrationError.approvalRequired = error { requiresApproval = true }
                isConnected = false
                let failure = error as NSError
                AppLogger.error(.startup, "Helper startup failed", metadata: ["domain": failure.domain, "code": failure.code, "error": failure.localizedDescription])
            }
        }
    }

    /// launchd 里没有注册该 mach service 时，`NSXPCConnection` 报的错：
    /// `NSCocoaErrorDomain` 的 `NSXPCConnectionInvalid`（4099，系统文案即
    /// 「无法与帮助程序通信。」）；launchd 侧对应
    /// `failed lookup: name = com.waifux.app.helper.control`。
    private static func indicatesMissingLaunchdJob(_ error: Error) -> Bool {
        let code = CocoaError.Code.xpcConnectionInvalid.rawValue
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain, failure.code == code { return true }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSCocoaErrorDomain, underlying.code == code { return true }
        return false
    }

    /// bootstrap 阶段的响应超时：`exchange` 的 gate 计时器到期抛出
    /// domain `WaifuXHelper` code 3。job 在 launchd 里存在、mach service 端口
    /// 能连上（所以 `indicatesMissingLaunchdJob` 的 4099 不会触发），但 Helper
    /// 120s 不回话 —— launchd spawn 循环失败（EX_CONFIG 类约束拒绝）或进程
    /// 起来后卡死都是这个形态。只用 domain+code 判断，不匹配文案。
    private static func indicatesUnresponsiveHelper(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == "WaifuXHelper" && failure.code == 3
    }

    /// `hello` 成功、但对方是旧构建（或协议落后）。
    ///
    /// 只在身份**已被读到并明确不一致**时抛出的错误类型，用于把「换包后连上旧
    /// helper」接进同一套注销重注册流程；瞬时的读不到/超时不会走这里，避免误杀
    /// 正在渲染壁纸的健康 helper。
    private static func indicatesStaleHelper(_ error: Error) -> Bool {
        guard let registrationError = error as? BackgroundAgentRegistrationError else { return false }
        if case .helperOutdated = registrationError { return true }
        return false
    }

    private func runBootstrap() async throws {
        try Task.checkCancellation()
        try BackgroundAgentRegistration.validateBundle(WaifuXHostBundle.bundleURL)
        let service = SMAppService.agent(plistName: BackgroundAgentWire.plistName)
        AppLogger.info(.startup, "Helper registration status", metadata: ["status": service.status.rawValue])
        try BackgroundAgentRegistration.ensureEnabled(service)
        requiresApproval = false
        connect()
        try await ensureCurrentHelper()
        try Task.checkCancellation()
        let legacy = UserDefaults.standard.persistentDomain(forName: "com.waifux.app") ?? [:]
        _ = try await perform("preferences.migrate", ["preferences": legacy])
        try Task.checkCancellation()
        try await configureMediaEnvironment()
        _ = WaifuXPreferences.shared.takeBufferedMutations()
        try await replayPendingPreferences()
        _ = try await perform("bootstrap", [:])
        try Task.checkCancellation()
        try await subscribe()
        try Task.checkCancellation()
        isConnected = true
        lastError = nil
        installPreferenceMutationHandler()
    }

    private func configureMediaEnvironment() async throws {
        try Task.checkCancellation()
        let environment = ProcessInfo.processInfo.environment
        _ = try await perform("media.configure", ["developerToken": environment["WAIFUX_APPLE_MUSIC_DEVELOPER_TOKEN"] ?? "", "storefront": environment["WAIFUX_APPLE_MUSIC_STOREFRONT"] ?? ""])
        try Task.checkCancellation()
    }

    private func replayPendingPreferences(timeoutSeconds: Double? = nil) async throws {
        for mutation in try WaifuXPreferences.shared.pendingMutationData() {
            try Task.checkCancellation()
            _ = try await perform("preferences.set", ["mutation": mutation], timeoutSeconds: timeoutSeconds)
            try Task.checkCancellation()
        }
    }

    private func installPreferenceMutationHandler() {
        WaifuXPreferences.shared.setMutationHandler { data in
            if Thread.isMainThread {
                MainActor.assumeIsolated { BackgroundAgentClient.shared.send("preferences.set", ["mutation": data]) }
            } else {
                Task { @MainActor in BackgroundAgentClient.shared.send("preferences.set", ["mutation": data]) }
            }
        }
    }

    #if DEBUG
    /// Read-only production diagnostics from the signed host executable. Does not
    /// register, bootstrap or stop the service, and exposes no saved preferences.
    func inspectRunningService() async throws -> [String: Any] {
        let service = SMAppService.agent(plistName: BackgroundAgentWire.plistName)
        guard service.status == .enabled else { throw BackgroundAgentRegistrationError.unavailable(service.status.rawValue) }
        let diagnosticConnection = NSXPCConnection(machServiceName: BackgroundAgentWire.machServiceName)
        diagnosticConnection.remoteObjectInterface = NSXPCInterface(with: BackgroundAgentXPC.self)
        diagnosticConnection.exportedInterface = NSXPCInterface(with: BackgroundAgentObserver.self)
        diagnosticConnection.exportedObject = BackgroundDiagnosticObserver()
        diagnosticConnection.resume()
        defer { diagnosticConnection.invalidate() }
        let helloData = try await exchange(using: diagnosticConnection) { proxy, gate in proxy.hello { gate.finish(.success($0 as Data)) } }
        let hello = try JSONDecoder().decode(BackgroundAgentHello.self, from: helloData)
        let data = try await exchange(using: diagnosticConnection) { proxy, gate in proxy.subscribe { gate.finish(.success($0 as Data)) } }
        let snapshot = try BackgroundPropertyList.decode(data)
        let video = snapshot["video"] as? [String: Any] ?? [:]
        return ["serviceStatus": service.status.rawValue, "helperPID": hello.processIdentifier,
                "helperBundleID": hello.bundleIdentifier, "ready": hello.runtimeReady,
                "loadedCodeIdentity": hello.buildIdentity ?? "",
                "embeddedCodeIdentity": BackgroundAgentBuildIdentity.executable(WaifuXHostBundle.bundleURL.appendingPathComponent("Contents/Helpers/WaifuXHelper.app/Contents/MacOS/WaifuXHelper")) ?? "",
                "menuBar": snapshot["menuBar"] as? [String: Any] ?? [:],
                "appearance": snapshot["appearance"] as? [String: Any] ?? [:],
                "nativePlayerCount": video["nativePlayerCount"] as? Int ?? 0,
                "nativeWindowCount": video["nativeWindowCount"] as? Int ?? 0]
    }

    /// Exercises the real command queue, subscription and exit drain without
    /// registering a production login item or importing the user's preferences.
    func startIsolatedUIExitProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard BackgroundRuntimeRole.isIsolatedTest,
              let service = environment["WAIFUX_HELPER_TEST_SERVICE"],
              service.hasPrefix("com.waifux.test.helper."),
              environment["WAIFUX_HELPER_TEST_SUITE"] == service + ".preferences",
              environment["WAIFUX_HELPER_TEST_ROOT"] != nil,
              bootstrapTask == nil else { throw CocoaError(.featureUnsupported) }
        isolatedProbeService = service
        isClosing = false
        isBootstrapping = true
        bootstrapGeneration &+= 1
        let generation = bootstrapGeneration
        bootstrapTask = Task {
            defer { if generation == bootstrapGeneration { isBootstrapping = false } }
            connect()
            try await ensureCurrentHelper()
            try await regressionCheckpoint("startup.identified")
            try await replayPendingPreferences()
            _ = try await perform("bootstrap", [:])
            try Task.checkCancellation()
            try await subscribe()
            try Task.checkCancellation()
            isConnected = true
            installPreferenceMutationHandler()
        }
        try await bootstrapTask?.value
    }

    func pauseIsolatedHelperForExitProbe() async throws {
        guard BackgroundRuntimeRole.isIsolatedTest, isConnected,
              isolatedProbeService?.hasPrefix("com.waifux.test.helper.") == true else {
            throw CocoaError(.featureUnsupported)
        }
        let data = try await exchange { proxy, gate in proxy.hello { gate.finish(.success($0 as Data)) } }
        let status = try JSONDecoder().decode(BackgroundAgentHello.self, from: data)
        guard status.bundleIdentifier == BackgroundAgentWire.bundleIdentifier,
              status.processIdentifier > 0, status.processIdentifier != getpid(),
              kill(status.processIdentifier, SIGSTOP) == 0 else { throw CocoaError(.xpcConnectionInvalid) }
        pausedHelperProbePID = status.processIdentifier
    }

    func resumeIsolatedHelperAfterQuitProbe() throws {
        guard BackgroundRuntimeRole.isIsolatedTest,
              isolatedProbeService?.hasPrefix("com.waifux.test.helper.") == true,
              let pid = pausedHelperProbePID, kill(pid, SIGCONT) == 0 else { throw CocoaError(.featureUnsupported) }
        pausedHelperProbePID = nil
    }

    func interruptIsolatedConnectionForProbe() throws {
        guard BackgroundRuntimeRole.isIsolatedTest, isolatedProbeService != nil else { throw CocoaError(.featureUnsupported) }
        obsoleteObserverProbe = connection?.exportedObject as? BackgroundClientObserver
        obsoleteInvalidationProbe = connection?.invalidationHandler
        connection?.invalidate()
    }

    func deliverObsoleteCallbacksForProbe() throws {
        guard BackgroundRuntimeRole.isIsolatedTest, isolatedProbeService != nil,
              let obsoleteObserverProbe else { throw CocoaError(.featureUnsupported) }
        obsoleteObserverProbe.snapshotChanged(try BackgroundPropertyList.encode(["stopped": true]) as NSData)
        obsoleteInvalidationProbe?()
    }

    private func regressionCheckpoint(_ name: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard BackgroundRuntimeRole.isIsolatedTest, isolatedProbeService != nil,
              environment["WAIFUX_UI_CLIENT_PROBE_CHECKPOINT"] == name,
              let root = environment["WAIFUX_HELPER_TEST_ROOT"] else { return }
        let directory = URL(fileURLWithPath: root)
        try Data().write(to: directory.appendingPathComponent(name + ".reached"))
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".release").path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
    }
    #endif

    private func connect() {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        observedHelperStop = false
        resetLibraryFetch()
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        var serviceName = BackgroundAgentWire.machServiceName
        #if DEBUG
        serviceName = isolatedProbeService ?? serviceName
        #endif
        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BackgroundAgentXPC.self)
        connection.exportedInterface = NSXPCInterface(with: BackgroundAgentObserver.self)
        connection.exportedObject = BackgroundClientObserver(generation: generation)
        connection.interruptionHandler = { @Sendable in Task { @MainActor in BackgroundAgentClient.shared.connectionLost(generation: generation) } }
        connection.invalidationHandler = { @Sendable in Task { @MainActor in BackgroundAgentClient.shared.connectionLost(generation: generation) } }
        self.connection = connection
        connection.resume()
    }

    fileprivate func acceptsConnectionGeneration(_ generation: UInt64) -> Bool {
        generation == connectionGeneration
    }

    private func resetLibraryFetch() {
        libraryFetchGeneration &+= 1
        libraryFetchTask?.cancel()
        libraryFetchTask = nil
        libraryRevision = nil
    }

    private func connectionLost(generation: UInt64) {
        guard acceptsConnectionGeneration(generation), !isClosing else { return }
        isConnected = false
        // Startup already owns connection/replacement retries. A second reconnect
        // task can invalidate its connection while the new Helper is booting.
        guard !isBootstrapping else { return }
        guard reconnectTask == nil else { return }
        reconnectGeneration &+= 1
        let attempt = reconnectGeneration
        reconnectTask = Task {
            defer { if attempt == reconnectGeneration { reconnectTask = nil } }
            for delay in [1, 2, 4, 8, 16] {
                do {
                    try await Task.sleep(for: .seconds(delay))
                    try Task.checkCancellation()
                    guard !isClosing, !isQuittingApplication, attempt == reconnectGeneration else { return }
                    connect()
                    try await ensureCurrentHelper()
                    try Task.checkCancellation()
                    #if DEBUG
                    try await regressionCheckpoint("reconnect.identified")
                    #endif
                    try await configureMediaEnvironment()
                    try await replayPendingPreferences()
                    _ = try await perform("bootstrap", [:])
                    try Task.checkCancellation()
                    try await subscribe()
                    try Task.checkCancellation()
                    isConnected = true
                    lastError = nil
                    break
                } catch {
                    if Task.isCancelled { return }
                    lastError = error.localizedDescription
                }
            }
        }
    }

    private func ensureCurrentHelper() async throws {
        try Task.checkCancellation()
        let url = WaifuXHostBundle.bundleURL.appendingPathComponent("Contents/Helpers/WaifuXHelper.app/Contents/MacOS/WaifuXHelper")
        guard let expected = BackgroundAgentBuildIdentity.executable(url) else { throw CocoaError(.executableNotLoadable) }
        var status = try await helloReply()
        try Task.checkCancellation()
        guard status.bundleIdentifier == BackgroundAgentWire.bundleIdentifier else { throw CocoaError(.executableLoad) }
        if status.buildIdentity != expected {
            // This endpoint is independent of the command protocol version.
            // launchd restarts the new on-disk executable after the old one exits.
            _ = try await exchange { proxy, gate in proxy.prepareForUpgrade { gate.finish(.success($0 as Data)) } }
            try Task.checkCancellation()
            for _ in 0..<24 {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                connect()
                if let next = try? await helloReply(), next.buildIdentity == expected { status = next; break }
                try Task.checkCancellation()
            }
        }
        guard status.buildIdentity == expected, status.protocolVersion == BackgroundAgentWire.protocolVersion else {
            // 连接成功、身份却对不上：launchd 里跑的是旧构建。上面的原地升级
            // （prepareForUpgrade + 12s 重连窗口）没能把它换掉，说明旧 helper
            // 不认这个命令，或者 job 仍绑在另一个副本的 bundle 上。
            // 抛专门的错误，让 bootstrap 走注销重注册，而不是让用户无限「重试连接」。
            throw BackgroundAgentRegistrationError.helperOutdated(
                "identity=\(status.buildIdentity ?? "nil") expected=\(expected) "
                + "protocol=\(status.protocolVersion)/\(BackgroundAgentWire.protocolVersion)"
            )
        }
        knownHelperPID = status.processIdentifier
        observedHelperStop = false
    }

    /// 发一次 `hello` 并解码。超时可调：启动校验用默认 120s，
    /// 注册修复后的探活用 2s（4099 会立刻回调，慢的只会是 job 还没就绪）。
    private func helloReply(timeoutSeconds: Double = 120) async throws -> BackgroundAgentHello {
        let data = try await exchange(timeoutSeconds: timeoutSeconds) { proxy, gate in
            proxy.hello { gate.finish(.success($0 as Data)) }
        }
        return try JSONDecoder().decode(BackgroundAgentHello.self, from: data)
    }

    /// repair 后的真实可达性探针。
    ///
    /// `SMAppService.status == .enabled` 只代表 BTM 记录：launchd 里 job 没起来、
    /// 或端口还没就绪时它照样是 enabled，所以必须真发一次 `hello` 才算验证
    /// （2026-10-19 用户机日志：旧实现只在 `.enabled` 上收尾，repair 后立刻又 4099）。
    /// 这里新建连接：repair 期间旧连接已被 invalidate。
    private func probeHelperReachable() async -> Bool {
        connect()
        do {
            let hello = try await helloReply(timeoutSeconds: 2)
            return hello.bundleIdentifier == BackgroundAgentWire.bundleIdentifier
        } catch {
            return false
        }
    }

    func observe(_ handler: @escaping ([String: Any]) -> Void) {
        handlers.append(handler)
        if !latestSnapshot.isEmpty { handler(latestSnapshot) }
    }

    func observeLibrary(_ handler: @escaping ([String: Any]) -> Void) {
        libraryHandlers.append(handler)
        if !latestLibrary.isEmpty { handler(latestLibrary) }
    }

    fileprivate func receive(_ data: Data, from generation: UInt64) {
        guard acceptsConnectionGeneration(generation) else { return }
        receive(data)
    }

    func receive(_ data: Data) {
        guard let snapshot = try? BackgroundPropertyList.decode(data) else { return }
        if snapshot["quitRequested"] as? Bool == true {
            if !isQuittingApplication { onApplicationQuitRequested?() }
            return
        }
        if snapshot["stopped"] as? Bool == true {
            observedHelperStop = true
            disconnect()
            if !isQuittingApplication {
                bootstrapTask = nil
                onHelperStopped?()
            }
            return
        }
        guard !isClosing else { return }
        if let revision = (snapshot["libraryRevision"] as? NSNumber)?.uint64Value, revision != libraryRevision {
            libraryRevision = revision
            if libraryFetchTask == nil {
                libraryFetchGeneration &+= 1
                let fetch = libraryFetchGeneration
                libraryFetchTask = Task {
                    defer { if fetch == libraryFetchGeneration { libraryFetchTask = nil } }
                    do {
                        var fetchedRevision: UInt64?
                        repeat {
                            fetchedRevision = libraryRevision
                            let values = try await request("library.snapshot")
                            try Task.checkCancellation()
                            latestLibrary = values
                            for handler in libraryHandlers { handler(values) }
                        } while fetchedRevision != libraryRevision
                    } catch { if !Task.isCancelled { lastError = error.localizedDescription } }
                }
            }
        }
        latestSnapshot = snapshot
        for handler in handlers { handler(snapshot) }
        NotificationCenter.default.post(name: .backgroundAgentSnapshotChanged, object: snapshot)
    }

    func send(_ operation: String, _ arguments: [String: Any] = [:]) {
        if operation == "crop.update", arguments["interactive"] as? Bool == true, let id = arguments["id"] as? String {
            pendingCropCommands[id] = arguments
            if cropFlushTask == nil {
                cropFlushTask = Task {
                    try? await Task.sleep(for: .milliseconds(33))
                    guard !Task.isCancelled else { return }
                    flushCropCommands()
                }
            }
            return
        }
        flushCropCommands()
        sendImmediately(operation, arguments)
    }

    private func sendImmediately(_ operation: String, _ arguments: [String: Any]) {
        let task = enqueue(operation, arguments)
        Task {
            do { _ = try await task.value }
            catch { lastError = error.localizedDescription }
        }
    }

    private func flushCropCommands() {
        cropFlushTask?.cancel()
        cropFlushTask = nil
        let commands = pendingCropCommands
        pendingCropCommands.removeAll()
        for id in commands.keys.sorted() { sendImmediately("crop.update", commands[id]!) }
    }

    /// - Parameter interfaceOnly: 关窗口/换界面时 Helper 会继续运行，待存设置
    ///   已经持久化在 pending 队列里，连接恢复后自动回放；所以这里只需要一次
    ///   有界的尝试，不能被无响应的 Helper 拖到退出看门狗。完整退出仍要求
    ///   Helper 明确 ack 每一笔写入。
    func drainForUIExit(interfaceOnly: Bool = false) async throws {
        flushCropCommands()
        if interfaceOnly {
            // 单一 2s 窗口同时覆盖 in-flight 命令与 pending 重放。分成两段
            // 2s 串行会和随后的 cloud sync（再 2s）一起撞上 6s 退出看门狗。
            await boundedExitFlush()
            try Task.checkCancellation()
            return
        }
        // Startup owns direct migration/bootstrap RPCs outside commandTail.
        // Finish admitted startup before stopping its shared XPC connection.
        _ = try? await bootstrapTask?.value
        try Task.checkCancellation()
        // Give unrelated in-flight commands (Steam, cloud, …) only a short grace
        // period: a slow command must not stall window-close into the 6s quit
        // watchdog. Preference durability is enforced by the replay below.
        if let tail = commandTail {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await tail.value }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        try Task.checkCancellation()
        // A failed RPC leaves its UI overlay pending even when commandTail has
        // completed. Its failure cannot be treated as a successful write drain.
        // An unrelated failed wallpaper command does not prevent closing once
        // all preferences are durable.
        guard try !WaifuXPreferences.shared.pendingMutationData().isEmpty else { return }
        guard connection != nil else {
            // 完整退出 + 连接不可用：保留 UI 也无法让写入发生（退出期间重连
            // 已被冻结）。pending 队列本身是持久化的，下次连接自动回放，
            // 不能再用这一条把退出卡成「UI retained」横幅死锁。
            warnPendingMutationsForQuit()
            return
        }
        try await replayPendingPreferences()
        try Task.checkCancellation()
        guard try WaifuXPreferences.shared.pendingMutationData().isEmpty else {
            throw NSError(domain: "WaifuXHelper", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "仍有设置等待后台保存，请稍后重试"])
        }
    }

    /// 界面退出只要求「把已持久化的设置尽力发出去」。这里只重放 pending
    /// 队列（与 commandTail 里的偏好写是同一批、幂等），并给 2s 上限：
    /// `await commandTail.value` 不响应取消，无响应的 Helper 会让它挂到
    /// 120s XPC 超时，反而把界面退出拖进 6s 看门狗。
    private func boundedExitFlush() async {
        let pending = (try? WaifuXPreferences.shared.pendingMutationData()) ?? []
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await self.replayPendingPreferences(timeoutSeconds: 2) }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Freeze new work before draining previously accepted writes. Explicit
    /// quit must not reconnect or enqueue a bootstrap after the Helper stops.
    func beginApplicationQuit() {
        guard !isQuittingApplication else { return }
        flushCropCommands()
        isQuittingApplication = true
        helperStopRequested = false
        isClosing = true
        reconnectGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    func stopForApplicationQuit() async throws {
        beginApplicationQuit()
        if observedHelperStop {
            if let pid = knownHelperPID {
                do { try await waitForHelperExit(pid) }
                catch {
                    guard !isIsolatedProbeEnvironment else { throw error }
                    await escalateStopForFullQuit(reason: "helper-exit-wait-timeout")
                }
            }
            return
        }
        if connection == nil {
            if !isIsolatedProbeEnvironment, let pid = knownHelperPID, helperProcessGone(pid) {
                // 记录的 Helper 已经退出：不要再用 BTM 状态否决这次退出。
                warnPendingMutationsForQuit()
                helperStopRequested = true
                observedHelperStop = true
                return
            }
            // BTM 记录可能指向别的 App 副本、或 Helper 正在退出。先走真实连接：
            // 连上了就能按正常链路停服务，连不上再按真实进程状态归因。
            connect()
        }
        do {
            switch try await helloForApplicationQuit() {
            case .stopped:
                helperStopRequested = true
                observedHelperStop = true
            case .helper(let helper):
                knownHelperPID = helper.processIdentifier
                // 退出阶段的偏好重放尽力而为：失败交给 runtime.stop 与升级
                // 路径兜底，不再让一条慢命令把完整退出卡成「UI retained」。
                for mutation in (try? WaifuXPreferences.shared.pendingMutationData()) ?? [] {
                    _ = try? await perform("preferences.set", ["mutation": mutation], timeoutSeconds: 2)
                }
                _ = try? await perform("runtime.stop", [:], timeoutSeconds: 2)
                helperStopRequested = true
                disconnect()
                do { try await waitForHelperExit(helper.processIdentifier) }
                catch {
                    guard !isIsolatedProbeEnvironment else { throw error }
                    await escalateStopForFullQuit(reason: "helper-stop-ack-timeout")
                }
                observedHelperStop = true
            }
        } catch {
            // Hello 不通（超时 / 连接失效 / 登录项不可用）：完整退出的意图明确，
            // 不再把 UI 留在「无法与帮助程序通信」横幅上等一个无响应的服务。
            // 升级为按进程表直接终止 Helper 与 worker——这是真的停止，不是
            // 「断开连接冒充成功」。
            guard !isIsolatedProbeEnvironment else { throw error }
            AppLogger.error(.general, "Helper unreachable during full quit; escalating to process termination", metadata: [
                "error": error.localizedDescription,
            ])
            warnPendingMutationsForQuit()
            await escalateStopForFullQuit(reason: error.localizedDescription)
            helperStopRequested = true
            observedHelperStop = true
        }
    }

    private var isIsolatedProbeEnvironment: Bool {
        #if DEBUG
        isolatedProbeService != nil
        #else
        false
        #endif
    }

    /// 退出时有设置尚未写入后台（Helper 不可用）。pending 队列持久化、
    /// 下次连接自动回放，这里只记日志，不再阻断完整退出。
    private func warnPendingMutationsForQuit() {
        let pending = (try? WaifuXPreferences.shared.pendingMutationData()) ?? []
        guard !pending.isEmpty else { return }
        AppLogger.error(.general, "后台服务不可用，退出时有设置尚未写入后台；已保留待下次连接回放", metadata: [
            "count": pending.count,
        ])
    }

    // MARK: - Full-quit escalation

    /// Helper 无响应时完整退出的最后手段：按进程表终止**本 App 副本**的
    /// Helper 与它名下的 worker。匹配是「可执行文件路径前缀 == 宿主 bundle
    /// 路径」与「basename ∈ 已知名单」的双条件——绝不只按进程名匹配，也
    /// 绝不盲杀已知 pid（pid 复用会把无关进程牵连进来），扫描结果是唯一
    /// 权威。SIGTERM 给渲染器留出清理窗口（释放 owned 桌面窗口/音频），
    /// 超时再 SIGKILL。
    private func escalateStopForFullQuit(reason: String) async {
        let processes = Self.hostOwnedBackgroundProcesses()
        guard !processes.isEmpty else {
            AppLogger.error(.general, "Full-quit escalation: no helper/worker process found (already gone)", metadata: [
                "reason": reason,
            ])
            return
        }
        let pidList = processes.map { String($0.pid) }.joined(separator: ",")
        AppLogger.error(.general, "Full-quit escalation: terminating unresponsive helper and workers", metadata: [
            "reason": reason, "pids": pidList,
        ])
        for process in processes { kill(process.pid, SIGTERM) }
        if await Self.waitProcessesExit(processes, iterations: 30) { return }
        let survivors = processes.filter { !helperProcessGone($0.pid) }
        for process in survivors { kill(process.pid, SIGKILL) }
        _ = await Self.waitProcessesExit(survivors, iterations: 20)
        if !survivors.allSatisfy({ helperProcessGone($0.pid) }) {
            AppLogger.error(.general, "Full-quit escalation: processes survived SIGKILL", metadata: [
                "pids": survivors.filter { !helperProcessGone($0.pid) }.map { String($0.pid) }.joined(separator: ","),
            ])
        }
    }

    private static func waitProcessesExit(_ processes: [(pid: Int32, name: String)], iterations: Int) async -> Bool {
        for _ in 0..<iterations {
            let gone = { (pid: Int32) -> Bool in kill(pid, 0) != 0 && errno == ESRCH }
            if processes.allSatisfy({ gone($0.pid) }) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// 宿主 bundle 名下仍在运行的后台进程（Helper / 场景渲染器 / web daemon）。
    private static func hostOwnedBackgroundProcesses() -> [(pid: Int32, name: String)] {
        let terminationBasenames: Set<String> = ["WaifuXHelper", "wallpaper-wgpu", "wallpaperengine-cli"]
        let hostPrefix = WaifuXHostBundle.bundleURL.resolvingSymlinksInPath().path + "/"
        var pidBuffer = [Int32](repeating: 0, count: 8192)
        let count = proc_listallpids(&pidBuffer, Int32(pidBuffer.count))
        guard count > 0 else { return [] }
        var result: [(pid: Int32, name: String)] = []
        for pid in pidBuffer[..<Int(count)] where pid > 0 && pid != getpid() {
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let url = URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath()
            guard url.path.hasPrefix(hostPrefix),
                  terminationBasenames.contains(url.lastPathComponent) else { continue }
            result.append((pid: pid, name: url.lastPathComponent))
        }
        return result
    }

    private func waitForHelperExit(_ pid: Int32) async throws {
        // A new Mach-service probe can relaunch a successfully stopped job.
        // Observe only the acknowledged process while waiting for its exit.
        //
        // Helper 收到 runtime.stop 后还要收尾渲染器与子进程（动态壁纸渲染中
        // 可达数秒，见 BackgroundAgentRuntime.stopAll）。3.5s 会把「正在正常
        // 退出」误判成失败，并让第二次尝试落到 BTM 状态分支上。
        for _ in 0..<100 {
            if helperProcessGone(pid) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "WaifuXHelper", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "后台服务仍在退出，请重试退出 WaifuX"])
    }

    private func helperProcessGone(_ pid: Int32) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    private enum HelperQuitProbe {
        case alreadyStopped
        case failure(Error)
    }

    /// 退出阶段连不上 Helper 时按**真实进程状态**归因，而不是只看 BTM 记录：
    /// 进程已经不在就是干净退出；进程还在但登录项不可用时才给可操作错误。
    private func classifyHelperQuitFailure(_ fallback: Error) -> HelperQuitProbe {
        #if DEBUG
        let isolated = isolatedProbeService != nil
        #else
        let isolated = false
        #endif
        guard !isolated else { return .failure(fallback) }
        let status = SMAppService.agent(plistName: BackgroundAgentWire.plistName).status
        if let pid = knownHelperPID {
            if helperProcessGone(pid) { return .alreadyStopped }
            if status != .enabled {
                return .failure(NSError(domain: "WaifuXHelper", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "后台服务仍在运行，但登录项不可用，请允许后台服务后重试退出"]))
            }
            return .failure(fallback)
        }
        // 没有已知 Helper PID：BTM 记录也没启用时，原始实现就直接放行退出。
        if status != .enabled { return .alreadyStopped }
        return .failure(fallback)
    }

    private enum HelperQuitHello {
        case helper(BackgroundAgentHello)
        case stopped
    }

    private func helloForApplicationQuit() async throws -> HelperQuitHello {
        do {
            let data = try await exchange(timeoutSeconds: 3) { proxy, gate in
                proxy.hello { gate.finish(.success($0 as Data)) }
            }
            let helper = try JSONDecoder().decode(BackgroundAgentHello.self, from: data)
            guard helper.bundleIdentifier == BackgroundAgentWire.bundleIdentifier,
                  helper.processIdentifier > 0, helper.processIdentifier != getpid() else {
                throw CocoaError(.executableLoad)
            }
            return .helper(helper)
        } catch {
            switch classifyHelperQuitFailure(error) {
            case .alreadyStopped:
                warnPendingMutationsForQuit()
                return .stopped
            case .failure(let mapped):
                throw mapped
            }
        }
    }

    func applicationQuitFailed(_ error: Error) {
        // 失败不等于连接已坏：保留连接，下一次重试可以直接复用，
        // 不必从零重连（否则很容易再次撞上 BTM 状态分支）。
        bootstrapTask?.cancel()
        bootstrapTask = nil
        bootstrapGeneration &+= 1
        isBootstrapping = false
        isQuittingApplication = false
        if !helperStopRequested {
            // 还没让 Helper 停：只是保存/连接问题，恢复 UI 的正常通信。
            isClosing = false
        }
        // helperStopRequested 时保持 isClosing：Helper 正在不可逆地退出，
        // 自动重连只会把正在退出的后台服务重新拉起。
        lastError = "退出未完成，WaifuX 界面已保留：\(error.localizedDescription)"
    }

    func request(_ operation: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        flushCropCommands()
        return try BackgroundPropertyList.decode(await enqueue(operation, arguments).value)
    }

    /// 退出路径专用的有界请求：调用方不关心结果，也不能被无响应的 Helper
    /// 无界拖住（关窗口的 2s fallback / 6s 退出看门狗）。
    func requestBounded(_ operation: String, timeoutSeconds: Double) async {
        // 超时必须下沉到 enqueue 内部的 RPC：等待方被取消不会取消那个 Task，
        // 否则无响应的 Helper 会把这里挂到 120s XPC 超时。跳过 commandTail，
        // 否则会排在退出时那条卡住的偏好写后面。
        let task = enqueue(operation, [:], timeoutSeconds: timeoutSeconds,
                           skipCommandTail: true, skipBootstrap: true)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(timeoutSeconds)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func enqueue(_ operation: String, _ arguments: [String: Any] = [:],
                         timeoutSeconds: Double? = nil,
                         skipCommandTail: Bool = false,
                         skipBootstrap: Bool = false) -> Task<Data, Error> {
        guard !isQuittingApplication || skipCommandTail else { return Task { throw CocoaError(.userCancelled) } }
        if bootstrapTask == nil && !skipBootstrap { start() }
        let admittedBootstrap = skipBootstrap ? nil : bootstrapTask
        let previous = skipCommandTail ? nil : commandTail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await admittedBootstrap?.value
            try Task.checkCancellation()
            return try BackgroundPropertyList.encode(await perform(operation, arguments, timeoutSeconds: timeoutSeconds))
        }
        if !skipCommandTail, !operation.hasSuffix(".wait") { commandTail = task }
        return task
    }

    private func exchange(using explicitConnection: NSXPCConnection? = nil, timeoutSeconds: Double = 120, _ invoke: @escaping (BackgroundAgentXPC, BackgroundReplyGate) -> Void) async throws -> Data {
        try Task.checkCancellation()
        guard let connection = explicitConnection ?? connection else { throw CocoaError(.xpcConnectionInvalid) }
        let gate = BackgroundReplyGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !Task.isCancelled else { gate.finish(.failure(CancellationError())); return }
                // Foundation invokes this on its XPC queue. Explicit Sendable keeps
                // Swift 6 from inheriting this method's MainActor isolation and
                // trapping when a pending request fails during disconnect.
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in gate.finish(.failure(error)) }) as? BackgroundAgentXPC else {
                    gate.finish(.failure(CocoaError(.xpcConnectionInvalid))); return
                }
                invoke(proxy, gate)
                let timer = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    guard !Task.isCancelled else { return }
                    gate.finish(.failure(NSError(domain: "WaifuXHelper", code: 3, userInfo: [NSLocalizedDescriptionKey: "后台服务响应超时"])))
                }
                gate.setTimeout(timer)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private func perform(_ operation: String, _ arguments: [String: Any], timeoutSeconds: Double? = nil) async throws -> [String: Any] {
        let generation = connectionGeneration
        let command = BackgroundAgentCommand(operation: operation, arguments: try BackgroundPropertyList.encode(arguments))
        let payload = try JSONEncoder().encode(command)
        let bytes = try await exchange(timeoutSeconds: timeoutSeconds ?? (operation.hasSuffix(".wait") ? 86_400 : 120)) { proxy, gate in
            proxy.perform(payload as NSData) { gate.finish(.success($0 as Data)) }
        }
        let reply = try JSONDecoder().decode(BackgroundAgentReply.self, from: bytes)
        guard reply.requestID == command.requestID else { throw CocoaError(.coderInvalidValue) }
        if let error = reply.error { throw NSError(domain: "WaifuXHelper", code: 4, userInfo: [NSLocalizedDescriptionKey: error]) }
        let result = try BackgroundPropertyList.decode(reply.result ?? Data())
        if operation == "preferences.set", let key = result["key"] as? String, let sequence = result["sequence"] as? NSNumber {
            WaifuXPreferences.shared.acknowledgeMutation(key: key, sequence: sequence.uint64Value)
        }
        if operation == "download.wait" || operation.hasPrefix("bake.") && operation.hasSuffix(".wait") || operation == "directory.repair.wait" || operation == "library.reindex.wait" || operation == "directory.migrate.wait" {
            if !isClosing {
                let refreshGeneration = connectionGeneration
                let library = try await perform("library.snapshot", [:])
                try Task.checkCancellation()
                if refreshGeneration == connectionGeneration {
                    latestLibrary = library
                    for handler in libraryHandlers { handler(library) }
                }
            }
        }
        if let snapshot = result["snapshot"] as? Data { receive(snapshot, from: generation) }
        return result
    }

    private func subscribe() async throws {
        let generation = connectionGeneration
        let bytes = try await exchange { proxy, gate in
            proxy.subscribe { gate.finish(.success($0 as Data)) }
        }
        try Task.checkCancellation()
        guard acceptsConnectionGeneration(generation) else { throw CocoaError(.xpcConnectionInvalid) }
        receive(bytes, from: generation)
    }

    func disconnect() {
        isClosing = true
        connectionGeneration &+= 1
        cropFlushTask?.cancel()
        cropFlushTask = nil
        pendingCropCommands.removeAll()
        resetLibraryFetch()
        reconnectGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        isConnected = false
    }
}
#endif
