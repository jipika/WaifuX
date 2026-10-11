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
    private var isQuittingApplication = false
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
                // BTM 记录与 launchd 域脱节时（job 被 bootout 过，或应用重建后
                // BTM 没把 job 重新下发），mach service 查不到、连接直接以
                // NSCocoaErrorDomain 4099 失败。这种状态只能靠重新注册恢复。
                guard Self.indicatesMissingLaunchdJob(error) else { throw error }
                AppLogger.error(.startup, "Helper service missing from launchd, repairing registration",
                                metadata: ["code": (error as NSError).code])
                try Task.checkCancellation()
                let service = SMAppService.agent(plistName: BackgroundAgentWire.plistName)
                try await BackgroundAgentRegistration.repairLaunchdRegistration(service)
                try Task.checkCancellation()
                try await runBootstrap()
            }
        }
        let startedTask = bootstrapTask
        Task {
            do { try await startedTask?.value }
            catch {
                guard generation == bootstrapGeneration else { return }
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

    private func replayPendingPreferences() async throws {
        for mutation in try WaifuXPreferences.shared.pendingMutationData() {
            try Task.checkCancellation()
            _ = try await perform("preferences.set", ["mutation": mutation])
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
        func hello() async throws -> BackgroundAgentHello {
            let data = try await exchange { proxy, gate in proxy.hello { gate.finish(.success($0 as Data)) } }
            return try JSONDecoder().decode(BackgroundAgentHello.self, from: data)
        }
        var status = try await hello()
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
                if let next = try? await hello(), next.buildIdentity == expected { status = next; break }
                try Task.checkCancellation()
            }
        }
        guard status.buildIdentity == expected, status.protocolVersion == BackgroundAgentWire.protocolVersion else {
            throw NSError(domain: "WaifuXHelper", code: 7, userInfo: [NSLocalizedDescriptionKey: "后台服务版本不匹配，请重试连接"])
        }
        knownHelperPID = status.processIdentifier
        observedHelperStop = false
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

    func drainForUIExit() async throws {
        flushCropCommands()
        // Startup owns direct migration/bootstrap RPCs outside commandTail.
        // Finish admitted startup before stopping its shared XPC connection.
        _ = try? await bootstrapTask?.value
        try Task.checkCancellation()
        _ = try? await commandTail?.value
        try Task.checkCancellation()
        // A failed RPC leaves its UI overlay pending even when commandTail has
        // completed. Its failure cannot be treated as a successful write drain.
        // An unrelated failed wallpaper command does not prevent closing once
        // all preferences are durable.
        guard try !WaifuXPreferences.shared.pendingMutationData().isEmpty else { return }
        guard connection != nil else {
            throw NSError(domain: "WaifuXHelper", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "后台连接不可用，最后的设置尚未保存，请恢复连接后重试"])
        }
        try await replayPendingPreferences()
        try Task.checkCancellation()
        guard try WaifuXPreferences.shared.pendingMutationData().isEmpty else {
            throw NSError(domain: "WaifuXHelper", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "仍有设置等待后台保存，请稍后重试"])
        }
    }

    /// Freeze new work before draining previously accepted writes. Explicit
    /// quit must not reconnect or enqueue a bootstrap after the Helper stops.
    func beginApplicationQuit() {
        guard !isQuittingApplication else { return }
        flushCropCommands()
        isQuittingApplication = true
        isClosing = true
        reconnectGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    func stopForApplicationQuit() async throws {
        beginApplicationQuit()
        if observedHelperStop {
            if let pid = knownHelperPID { try await waitForHelperExit(pid) }
            return
        }
        if connection == nil {
            var isolated = false
            #if DEBUG
            isolated = isolatedProbeService != nil
            #endif
            if !isolated {
                let status = SMAppService.agent(plistName: BackgroundAgentWire.plistName).status
                if status != .enabled {
                    if let pid = knownHelperPID, !(kill(pid, 0) != 0 && errno == ESRCH) {
                        throw NSError(domain: "WaifuXHelper", code: 4,
                                      userInfo: [NSLocalizedDescriptionKey: "后台服务仍在运行，但登录项不可用，请允许后台服务后重试退出"])
                    }
                    guard try WaifuXPreferences.shared.pendingMutationData().isEmpty else {
                        throw NSError(domain: "WaifuXHelper", code: 4,
                                      userInfo: [NSLocalizedDescriptionKey: "后台服务不可用，最后的设置尚未保存，请恢复后台服务后重试退出"])
                    }
                    observedHelperStop = true
                    return
                }
            }
            connect()
        }
        let data = try await exchange(timeoutSeconds: 2) { proxy, gate in
            proxy.hello { gate.finish(.success($0 as Data)) }
        }
        let helper = try JSONDecoder().decode(BackgroundAgentHello.self, from: data)
        guard helper.bundleIdentifier == BackgroundAgentWire.bundleIdentifier,
              helper.processIdentifier > 0, helper.processIdentifier != getpid() else {
            throw CocoaError(.executableLoad)
        }
        knownHelperPID = helper.processIdentifier
        for mutation in try WaifuXPreferences.shared.pendingMutationData() {
            _ = try await perform("preferences.set", ["mutation": mutation], timeoutSeconds: 2)
        }
        _ = try await perform("runtime.stop", [:], timeoutSeconds: 2)
        disconnect()
        try await waitForHelperExit(helper.processIdentifier)
        observedHelperStop = true
    }

    private func waitForHelperExit(_ pid: Int32) async throws {
        // A new Mach-service probe can relaunch a successfully stopped job.
        // Observe only the acknowledged process while waiting for its exit.
        for _ in 0..<35 {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "WaifuXHelper", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "后台服务尚未退出，请重试退出 WaifuX"])
    }

    func applicationQuitFailed(_ error: Error) {
        disconnect()
        bootstrapTask?.cancel()
        bootstrapTask = nil
        bootstrapGeneration &+= 1
        isBootstrapping = false
        isQuittingApplication = false
        lastError = "退出未完成，WaifuX 界面已保留：\(error.localizedDescription)"
    }

    func request(_ operation: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        flushCropCommands()
        return try BackgroundPropertyList.decode(await enqueue(operation, arguments).value)
    }

    private func enqueue(_ operation: String, _ arguments: [String: Any]) -> Task<Data, Error> {
        guard !isQuittingApplication else { return Task { throw CocoaError(.userCancelled) } }
        if bootstrapTask == nil { start() }
        let admittedBootstrap = bootstrapTask
        let previous = commandTail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await admittedBootstrap?.value
            try Task.checkCancellation()
            return try BackgroundPropertyList.encode(await perform(operation, arguments))
        }
        if !operation.hasSuffix(".wait") { commandTail = task }
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
