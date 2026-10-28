#if WAIFUX_HELPER
import AppKit
import Combine

@MainActor
private struct AgentArguments {
    let values: [String: Any]
    func string(_ key: String) throws -> String {
        guard let value = values[key] as? String else { throw CocoaError(.coderValueNotFound) }
        return value
    }
    func optionalString(_ key: String) -> String? { values[key] as? String }
    func bool(_ key: String, default fallback: Bool = false) -> Bool { values[key] as? Bool ?? fallback }
    func double(_ key: String, default fallback: Double = 0) -> Double { (values[key] as? NSNumber)?.doubleValue ?? fallback }
    func integer(_ key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? 0 }
    func optionalInteger(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue }
    func url(_ key: String) throws -> URL {
        guard let url = URL(string: try string(key)), url.isFileURL else { throw CocoaError(.fileReadInvalidFileName) }
        return url
    }
    func optionalURL(_ key: String) throws -> URL? { values[key] == nil ? nil : try url(key) }
    func screen(_ key: String) throws -> NSScreen {
        let screens = NSScreen.screens
        if let identity = values[key] as? [String: String], let fingerprint = identity["fingerprint"] {
            if let index = WallpaperScreenIdentity.commandTargetIndex(
                identifier: identity["id"], fingerprint: fingerprint,
                screens: screens.map { ($0.wallpaperScreenIdentifier, $0.wallpaperScreenFingerprint) }
            ) { return screens[index] }
        } else if let id = values[key] as? String,
                  let screen = screens.first(where: { $0.wallpaperScreenIdentifier == id }) { return screen }
        throw NSError(domain: "WaifuXHelper", code: 5, userInfo: [NSLocalizedDescriptionKey: "目标显示器已变化或无法唯一识别，请重新选择"])
    }
    func optionalScreen(_ key: String) throws -> NSScreen? { values[key] == nil ? nil : try screen(key) }
    func screens(_ key: String) throws -> [NSScreen]? {
        guard let entries = values[key] else { return nil }
        guard let identities = entries as? [Any], !identities.isEmpty else { throw CocoaError(.coderInvalidValue) }
        return try identities.map { try AgentArguments(values: ["screen": $0]).screen("screen") }
    }
    func uuid(_ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(key)) else { throw CocoaError(.coderInvalidValue) }
        return value
    }
    func decode<T: Decodable>(_ key: String, as type: T.Type) throws -> T {
        guard let data = values[key] as? Data else { throw CocoaError(.coderValueNotFound) }
        return try JSONDecoder().decode(type, from: data)
    }
}

@MainActor
final class BackgroundAgentRuntime {
    static let shared = BackgroundAgentRuntime()
    private(set) var isReady = false
    private var observers: [ObjectIdentifier: NSXPCConnection] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var publishTask: Task<Void, Never>?
    private var shutdownRequested = false
    private var stopping = false
    private var stopAllStarted = false
    private var applicationQuitRequested = false
    private var quitFallbackTask: Task<Void, Never>?
    private var commandTail: Task<Data, Never>?
    private var inFlightReplies: [String: Task<Data, Never>] = [:]
    private var upgrading = false
    private var cachedReplyBytes = 0
    private var cachedReplies: [String: Data] = [:]
    private var replyOrder: [String] = []
    private var migrationProgress: MigrationProgress?
    private var libraryRevision: UInt64 = 0
    /// Helper 侧库记录是否已从磁盘恢复完（收藏/下载/文件夹三套都齐）。
    ///
    /// 这是 `library.snapshot` 快速读通道的闸门：没恢复完就读会返回空或半量
    /// 快照，UI 侧据此判「已到达」会把假空态换个理由复现（2026-10-26 复核指出）。
    /// 只有置 true 之后的读才被允许提前返回。
    private(set) var libraryRecordsAreRestored = false
    /// Helper 队列里在飞的库写操作数量（含已排队未执行）。
    ///
    /// 快速读通道只在它为 0 时越队：若队里还有一条删除/移动没跑，越队的读
    /// 会返回「还没有这次写」的快照，UI 整体覆盖后表现为已删记录复活、
    /// 刚建文件夹消失。
    private var pendingLibraryMutations = 0
    private var optimizationAliases: [UUID: UUID] = [:]
    private var preferenceSequences: [String: UInt64] = [:]
    private var wallpaperDownloader: WallpaperViewModel?
    private var mediaDownloader: MediaExploreViewModel?
    private var idleDownloadRelease: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var libraryRecoveryTask: Task<Void, Never>?
    private var exitingChildren: [BackgroundChildProcessCleanup.Child] = []
    private var logoutObserver: Any?
    private let sessionKey = "background_helper_active_session_v1"
    private var idleExitTask: Task<Void, Never>?
    #if DEBUG
    private(set) var regressionStaleIdentity = false
    private var regressionChildren: [Process] = []
    #endif
    private init() {
        logoutObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            WaifuXPreferences.shared.removeObject(forKey: "background_helper_active_session_v1")
            WaifuXPreferences.shared.synchronize()
        }
    }

    private var currentSession: String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["managerpid"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let manager = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, !manager.isEmpty else { return "" }
        return "\(bootTime.tv_sec):\(manager)"
    }

    func startAtLoginIfNeeded() async {
        guard !BackgroundRuntimeRole.isIsolatedTest else { return }
        let preferences = WaifuXPreferences.shared
        if preferences.bool(forKey: BackgroundAgentWire.migrationKey), preferences.bool(forKey: "launch_at_login") || (!currentSession.isEmpty && preferences.string(forKey: sessionKey) == currentSession) {
            await startRuntime()
        } else {
            idleExitTask = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, !isReady else { return }
                NSApp.terminate(nil)
            }
        }
    }

    private func startRuntime() async {
        guard !stopping, !upgrading else { return }
        if let startupTask { await startupTask.value; return }
        idleExitTask?.cancel()
        startupTask = Task {
            isReady = true
            ThemeManager.shared.restoreSavedSettings()
            await applyNetworkPreferences()
            guard !Task.isCancelled, !stopping, !upgrading else { return }
            if BackgroundRuntimeRole.isIsolatedTest {
                // 隔离测试不跑下面的恢复序列，快照闸门必须同样打开，
                // 否则回归脚本里的 `library.snapshot` RPC 会被新 guard 拒掉。
                libraryRecordsAreRestored = true
                bindState()
                return
            }
            WaifuXPreferences.shared.set(currentSession, forKey: sessionKey)
            WaifuXPreferences.shared.synchronize()
            LocalizationService.shared.restoreSavedSettings()
            WallpaperLibraryService.shared.restoreSavedData()
            MediaLibraryService.shared.restoreSavedData()
            LibraryFolderStore.shared.restoreSavedData()
            LibraryFolderStore.shared.sanitizeLibraryFolderMemberships()
            // 三套库状态齐了：从这里开始 `library.snapshot` 可以提前应答，
            // 不必等 startRuntime 尾部（渲染器/屏保恢复要几十秒，UI 白等）。
            libraryRecordsAreRestored = true
            libraryRecoveryTask = Task(priority: .utility) {
                await DirectoryMigrationService.shared.recoverIncompleteMigrationIfNeeded()
                guard !Task.isCancelled else { return }
                await DirectoryMigrationService.shared.repairOrphanedPathsIfNeeded()
                guard !Task.isCancelled else { return }
                _ = await LocalWallpaperScanner.shared.rebuildManagedLibraryIndexForUpgradeIfNeeded()
                guard !Task.isCancelled else { return }
                _ = await LocalWallpaperScanner.shared.rebuildManagedLibraryIndexIfNoLiveRecords()
            }
            DownloadTaskService.shared.restoreSavedTasks()
            if PersistentDownloadQueueService.shared.hasPersistedWork { prepareDownloadExecutors() }
            WallpaperSchedulerService.shared.restoreSavedConfig()
            DynamicWallpaperAutoPauseManager.shared.restoreSettings()
            WaifuXUIActions.handler = { [weak self] action in self?.openUI(action) }
            if !BackgroundRuntimeRole.isIsolatedTest {
                StatusBarController.shared.configure(showWindow: { WaifuXUIActions.perform(.main) }, releaseMemory: { WaifuXUIActions.perform(.releaseMemory) }, quit: { Task { await BackgroundAgentRuntime.shared.requestApplicationQuit() } })
                // The old keeper runs the UI binary. Retire it before taking ownership.
                WallpaperExtensionKeeper.syncLaunchAgentWithEnabledFlag(false)
                ExternalDisplayConnectionCoordinator.shared.start()
                // 系统壁纸缓存清理已移交主 App（授权对象必须是隐私面板里可见的 WaifuX，
                // Helper 在 Contents/Helpers/ 下用户无法授权），此处不再调用 noteAppLaunch。
                if #available(macOS 26.0, *) {
                    WallpaperExtensionSocketServer.shared.start()
                    LockScreenWallpaperService.shared.syncInstanceCatalogToSocketServer()
                    WallpaperExtensionSocketServer.shared.notifyExtensionReloadIfBundleChanged()
                    if WaifuXPreferences.shared.object(forKey: "wallpaper_extension_keeper_enabled") as? Bool ?? true { WallpaperExtensionAgentHealer.shared.start() }
                }
                await VideoRendererProcessController.shared.reapOrphanedRenderersFromPreviousVersions()
                guard !Task.isCancelled, !stopping, !upgrading else { return }
                if WallpaperEngineXBridge.shared.hasPersistedRestoreState() {
                    await WallpaperEngineXBridge.shared.restoreIfNeeded()
                } else {
                    await VideoWallpaperManager.shared.restoreIfNeeded()
                    guard !Task.isCancelled, !stopping, !upgrading else { return }
                    if !VideoWallpaperManager.shared.isVideoWallpaperActive { await WallpaperEngineXBridge.shared.restoreIfNeeded() }
                }
                guard !Task.isCancelled, !stopping, !upgrading else { return }
                StaticImageWallpaperOverlayManager.shared.restoreIfNeeded()
                await refreshSettings()
                guard !Task.isCancelled, !stopping, !upgrading else { return }
                ScreenSaverService.shared.refreshInstalledVersionIfNeeded()
                ScreenSaverService.shared.syncFromDesktop(reason: "helper.start")
            }
            if !BackgroundRuntimeRole.isIsolatedTest {
                VideoOptimizationQueueService.shared.applySettings(autoOnDownload: WaifuXPreferences.shared.bool(forKey: "frame_interpolation_auto_on_download"))
                _ = SceneOfflineBakeProgressTracker.shared
            }
            bindState()
            publish()
        }
        await startupTask?.value
    }

    private func bindState() {
        let publishers: [AnyPublisher<Void, Never>] = [
            VideoWallpaperManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            WallpaperEngineXBridge.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            WallpaperSchedulerService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            CurrentWallpaperService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            DownloadTaskService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            CloudSyncService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            VideoOptimizationQueueService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SteamServiceManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            DSHHarnessBridge.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            StaticImageWallpaperOverlayManager.shared.$stateChangeSignal.map { _ in () }.eraseToAnyPublisher()
        ]
        for publisher in [MediaLibraryService.shared.objectWillChange.eraseToAnyPublisher(), WallpaperLibraryService.shared.objectWillChange.eraseToAnyPublisher(), LibraryFolderStore.shared.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                self.libraryRevision &+= 1
                self.schedulePublish()
            }.store(in: &subscriptions)
        }
        for publisher in publishers {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.schedulePublish() }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: .backgroundDownloadWorkersChanged)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.releaseIdleDownloadExecutors() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .sceneOfflineBakeProgressDidUpdate)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.schedulePublish() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: WaifuXPreferences.shared)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.schedulePublish() }.store(in: &subscriptions)
    }

    func subscribe(_ connection: NSXPCConnection) {
        observers[ObjectIdentifier(connection)] = connection
        if !BackgroundRuntimeRole.isIsolatedTest { DSHHarnessBridge.shared.startAvailabilityMonitor() }
    }
    func unsubscribe(_ id: ObjectIdentifier) {
        observers.removeValue(forKey: id)
        if observers.isEmpty {
            DSHHarnessBridge.shared.stopAvailabilityMonitor()
            if applicationQuitRequested && !stopAllStarted {
                Task { await stopAll() }
            }
        }
    }
    func snapshot() -> Data {
        var values: [String: Any] = ["ready": isReady, "pid": ProcessInfo.processInfo.processIdentifier]
        if isReady {
            values["appearance"] = ThemeManager.shared.backgroundSnapshot
            if !BackgroundRuntimeRole.isIsolatedTest { values["menuBar"] = StatusBarController.shared.backgroundSnapshot }
            values["desktop"] = DesktopWallpaperSyncManager.shared.backgroundSnapshot()
            values["staticOverlay"] = StaticImageWallpaperOverlayManager.shared.backgroundSnapshot()
            values["video"] = VideoWallpaperManager.shared.backgroundSnapshot()
            values["engine"] = WallpaperEngineXBridge.shared.backgroundSnapshot()
            values["scheduler"] = ["config": (try? JSONEncoder().encode(WallpaperSchedulerService.shared.config)) ?? Data(), "running": WallpaperSchedulerService.shared.isRunning]
            if let migrationProgress { values["migration"] = try? JSONEncoder().encode(migrationProgress) }
            values["dsh"] = try? JSONEncoder().encode(DSHHarnessBridge.shared.availability)
            values["steam"] = SteamServiceManager.shared.backgroundSnapshot()
            values["libraryRevision"] = NSNumber(value: libraryRevision)
            values["bakes"] = (try? JSONEncoder().encode(SceneOfflineBakeProgressTracker.shared.entries)) ?? Data()
            values["optimization"] = VideoOptimizationQueueService.shared.backgroundSnapshot()
            values["downloads"] = (try? JSONEncoder().encode(DownloadTaskService.shared.tasks)) ?? Data()
            values["cloud"] = CloudSyncService.shared.backgroundSnapshot()
            values["current"] = CurrentWallpaperService.shared.activeURLByScreenID.mapValues(\.absoluteString)
        }
        return (try? BackgroundPropertyList.encode(values)) ?? Data()
    }
    private func schedulePublish() {
        guard !stopping, !upgrading, !observers.isEmpty, publishTask == nil else { return }
        publishTask = Task {
            try? await Task.sleep(for: .milliseconds(30))
            publishTask = nil
            publish()
        }
    }
    private func publish() {
        guard !observers.isEmpty else { return }
        let data = snapshot() as NSData
        for (id, connection) in observers {
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
                Task { @MainActor in BackgroundAgentRuntime.shared.unsubscribe(id) }
            } as? BackgroundAgentObserver
            proxy?.snapshotChanged(data)
        }
    }
    private func openUI(_ action: WaifuXUIActions.Action) {
        // Detail payloads are written by the Helper immediately before this
        // action. Commit them before an existing/new UI consumes the request.
        WaifuXPreferences.shared.synchronize()
        if action == .releaseMemory {
            for connection in observers.values {
                (connection.remoteObjectProxy as? BackgroundAgentObserver)?.openUI(action.rawValue)
            }
            return
        }

        // A URL event opens exactly the requested UI in both cold and warm
        // starts. Plain openApplication sends a reopen event, which also opens
        // the library window. Do not depend on potentially stale XPC observers.
        let request = WaifuXUIActions.Request(action: action)
        NSWorkspace.shared.open(
            [request.url],
            withApplicationAt: WaifuXHostBundle.bundleURL,
            configuration: request.openConfiguration()
        ) { _, error in
            if let error {
                AppLogger.error(.general, "Failed to open requested UI", metadata: [
                    "action": action.rawValue, "error": error.localizedDescription
                ])
            }
        }
    }

    func perform(_ bytes: Data) async -> Data {
        guard bytes.count <= BackgroundAgentWire.maximumCommandBytes,
              let command = try? JSONDecoder().decode(BackgroundAgentCommand.self, from: bytes) else {
            return encodeReply(BackgroundAgentReply(requestID: "", result: nil, error: "Invalid command"))
        }
        if let pending = inFlightReplies[command.requestID] { return await pending.value }
        guard !upgrading else {
            return encodeReply(BackgroundAgentReply(requestID: command.requestID, result: nil, error: "后台服务正在更新，请稍后重试"))
        }
        // 库快照是纯读：允许越过队首那条 `bootstrap`（它会等整个 startRuntime，
        // 实测几十秒）。越过的前提是恢复已完成（见 execute 的闸门）且本进程内
        // 没有待提交的库写操作（UI 侧已按此条件选择是否走快速通道）。
        let isLibraryWrite = command.operation.hasPrefix("library.") && command.operation != "library.snapshot"
        if isLibraryWrite { pendingLibraryMutations += 1 }
        let isLibrarySnapshotRead = command.operation == "library.snapshot"
            && libraryRecordsAreRestored && pendingLibraryMutations == 0
        let previous = isLibrarySnapshotRead ? nil : commandTail
        let task = Task { @MainActor in
            defer { if isLibraryWrite { pendingLibraryMutations -= 1 } }
            _ = await previous?.value
            if let reply = cachedReplies[command.requestID] { return reply }
            let reply: BackgroundAgentReply
            do {
                guard !stopping || command.operation == "runtime.stop" else { throw CocoaError(.userCancelled) }
                guard command.protocolVersion == BackgroundAgentWire.protocolVersion else { throw CocoaError(.coderInvalidValue) }
                let a = AgentArguments(values: try BackgroundPropertyList.decode(command.arguments))
                var result = try await execute(command.operation, a)
                result["snapshot"] = snapshot()
                reply = BackgroundAgentReply(requestID: command.requestID, result: try BackgroundPropertyList.encode(result), error: nil)
            } catch {
                reply = BackgroundAgentReply(requestID: command.requestID, result: nil, error: error.localizedDescription)
            }
            let data = encodeReply(reply)
            if data.count <= 8 * 1024 * 1024 {
                cachedReplies[command.requestID] = data
                cachedReplyBytes += data.count
                replyOrder.append(command.requestID)
                while replyOrder.count > 64 || cachedReplyBytes > 8 * 1024 * 1024 {
                    if let old = cachedReplies.removeValue(forKey: replyOrder.removeFirst()) { cachedReplyBytes -= old.count }
                }
            }
            schedulePublish()
            return data
        }
        if !command.operation.hasSuffix(".wait"), !isLibrarySnapshotRead { commandTail = task }
        inFlightReplies[command.requestID] = task
        let result = await task.value
        inFlightReplies.removeValue(forKey: command.requestID)
        return result
    }
    private func encodeReply(_ reply: BackgroundAgentReply) -> Data { (try? JSONEncoder().encode(reply)) ?? Data() }

    private func execute(_ operation: String, _ a: AgentArguments) async throws -> [String: Any] {
        guard BackgroundRuntimeRole.permitsOperation(operation) else {
            throw NSError(domain: "WaifuXHelper", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "隔离回归默认禁止真实桌面渲染或系统壁纸操作"])
        }
        switch operation {
        case "cloud.syncOnUIExit":
            CloudSyncService.shared.syncOnAppTerminate()
            return [:]
        case "cloud.sync.wait":
            await CloudSyncService.shared.sync()
            return ["cloud": CloudSyncService.shared.backgroundSnapshot()]
        case "cloud.restore.wait":
            await CloudSyncService.shared.restoreFromCloud()
            return ["cloud": CloudSyncService.shared.backgroundSnapshot()]
        case "cloud.clearError":
            CloudSyncService.shared.clearError()
            return [:]
        case "media.configure":
            AppleMusicLyricsService.configureEnvironment(developerToken: a.optionalString("developerToken") ?? "", storefront: a.optionalString("storefront") ?? "")
            return [:]
        case "desktop.capture":
            DesktopWallpaperSyncManager.shared.captureOriginalSystemWallpaperIfNeeded(for: try a.screens("screens") ?? NSScreen.screens)
            return [:]
        case "desktop.register":
            let options = Dictionary(uniqueKeysWithValues: (a.values["options"] as? [String: Any] ?? [:]).map { (NSWorkspace.DesktopImageOptionKey(rawValue: $0.key), $0.value) })
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(try a.url("url"), for: try a.optionalScreen("screen"), options: options)
            return [:]
        case "desktop.clear":
            DesktopWallpaperSyncManager.shared.clearRegistration(for: try a.optionalScreen("screen"))
            return [:]
        case "desktop.clearIdentity":
            DesktopWallpaperSyncManager.shared.clearRegistration(screenID: try a.string("id"), fingerprint: try a.string("fingerprint"))
            return [:]
        case "desktop.activation":
            DesktopWallpaperSyncManager.shared.syncOnAppActivation()
            return [:]
        case "overlay.discard":
            StaticImageWallpaperOverlayManager.shared.discardPersistedImageState(screenID: try a.string("id"), fingerprint: try a.string("fingerprint"))
            return [:]
        case "dsh.refresh.wait":
            return ["result": try JSONEncoder().encode(await DSHHarnessBridge.shared.refreshAvailability(force: a.bool("force")))]
        case "dsh.set.wait":
            let url = try a.url("url")
            let media: DSHHarnessBridge.Media = a.bool("video") ? .video(url) : .image(url)
            return try await DSHHarnessBridge.shared.setBackground(media: media, coverage: DSHHarnessBridge.Coverage(rawValue: try a.string("coverage")) ?? .panels, dim: a.double("dim"), videoLoop: a.bool("videoLoop"), videoMuted: a.bool("videoMuted"), videoRate: a.double("videoRate", default: 1))
        case "dsh.clear.wait":
            try await DSHHarnessBridge.shared.clearBackground()
            return [:]
        case "directory.repair.wait":
            guard !DirectoryMigrationService.shared.isMigrating else {
                throw NSError(domain: "WaifuXHelper", code: 8, userInfo: [NSLocalizedDescriptionKey: "请等待目录迁移完成后再修复数据"])
            }
            return ["result": try JSONEncoder().encode(await DirectoryMigrationService.shared.repairBrokenRecords())]
        case "library.rescan.wait":
            await LocalWallpaperScanner.shared.forceRescan()
            return [:]
        case "library.reindex.wait":
            return ["result": try JSONEncoder().encode(await LocalWallpaperScanner.shared.rebuildManagedLibraryIndex())]
        case "test.delay.wait":
            #if DEBUG
            guard BackgroundRuntimeRole.isIsolatedTest else { throw CocoaError(.featureUnsupported) }
            let key = "regression_delay_count"
            let count = WaifuXPreferences.shared.integer(forKey: key) + 1
            WaifuXPreferences.shared.set(count, forKey: key)
            try await Task.sleep(for: .seconds(1))
            return ["count": count]
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        case "test.preference":
            guard BackgroundRuntimeRole.isIsolatedTest else { throw CocoaError(.featureUnsupported) }
            return ["value": WaifuXPreferences.shared.object(forKey: try a.string("key")) ?? ""]
        case "test.staleIdentity":
            #if DEBUG
            guard BackgroundRuntimeRole.isIsolatedTest else { throw CocoaError(.featureUnsupported) }
            regressionStaleIdentity = true
            return [:]
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        case "test.menuQuit":
            #if DEBUG
            guard BackgroundRuntimeRole.isIsolatedTest else { throw CocoaError(.featureUnsupported) }
            Task { await requestApplicationQuit() }
            return [:]
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        case "test.spawnChild":
            #if DEBUG
            guard BackgroundRuntimeRole.isIsolatedTest else { throw CocoaError(.featureUnsupported) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: a.bool("nested") ? "/bin/sh" : "/bin/sleep")
            process.arguments = a.bool("nested") ? ["-c", "sleep 60 & wait"] : ["60"]
            try process.run()
            regressionChildren.append(process)
            if a.bool("nested") { try await Task.sleep(for: .milliseconds(200)) }
            if a.bool("paused") { kill(process.processIdentifier, SIGSTOP) }
            return ["pid": process.processIdentifier]
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        case "test.spawnDetachedBake":
            #if DEBUG
            guard BackgroundRuntimeRole.isIsolatedTest,
                  let root = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"] else { throw CocoaError(.featureUnsupported) }
            let executable = try a.url("executable")
            guard executable.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/") else { throw CocoaError(.featureUnsupported) }
            let pid = try await BakeService.shared.regressionLaunchWrapperForProcessTermination(
                executableURL: executable, arguments: ["--detached-bake-worker"]
            )
            try await Task.sleep(for: .milliseconds(200))
            if a.bool("cancel") { BakeService.shared.cancel() }
            if a.bool("paused") { kill(pid, SIGSTOP) }
            return ["pid": pid]
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        case "test.network.wait":
            #if DEBUG
            guard BackgroundRuntimeRole.isIsolatedTest,
                  let url = URL(string: try a.string("url")), url.scheme == "http",
                  url.host == "waifux-proxy-regression" || url.host == "127.0.0.1" else { throw CocoaError(.featureUnsupported) }
            return ["data": try await NetworkService.shared.fetchData(from: url)]
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        case "test.migrationRecover.wait":
            #if DEBUG
            guard BackgroundRuntimeRole.isIsolatedTest else { throw CocoaError(.featureUnsupported) }
            await DirectoryMigrationService.shared.recoverIncompleteMigrationIfNeeded()
            return [:]
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        case "test.audioStartStop.wait":
            #if DEBUG
            guard BackgroundRuntimeRole.isIsolatedTest else { throw CocoaError(.featureUnsupported) }
            let capture = SystemAudioCaptureService.shared
            let before = capture.isolatedTapStartAttempts
            capture.start()
            capture.stop()
            try await Task.sleep(for: .milliseconds(200))
            return ["attempts": capture.isolatedTapStartAttempts - before, "running": capture.isRunning]
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        case "test.event":
            #if DEBUG
            guard BackgroundRuntimeRole.isIsolatedTest else { throw CocoaError(.featureUnsupported) }
            let events: [String: Notification.Name] = ["displaySleep": NSWorkspace.screensDidSleepNotification, "displayWake": NSWorkspace.screensDidWakeNotification, "sleep": NSWorkspace.willSleepNotification, "wake": NSWorkspace.didWakeNotification]
            guard let event = events[try a.string("event")] else { throw CocoaError(.coderInvalidValue) }
            NSWorkspace.shared.notificationCenter.post(name: event, object: nil)
            return [:]
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        case "test.snapshot":
            guard BackgroundRuntimeRole.isIsolatedTest else { throw CocoaError(.featureUnsupported) }
            return [:]
        case "preferences.migrate":
            WaifuXPreferences.shared.migrateLegacyDomainIfNeeded(a.values["preferences"] as? [String: Any] ?? [:])
            return [:]
        case "bootstrap":
            WaifuXPreferences.shared.migrateLegacyDomainIfNeeded(a.values["preferences"] as? [String: Any] ?? [:])
            await startRuntime()
            return [:]
        case "preferences.set":
            guard let bytes = a.values["mutation"] as? Data else { throw CocoaError(.coderValueNotFound) }
            let mutation = AgentArguments(values: try BackgroundPropertyList.decode(bytes))
            let key = try mutation.string("key")
            let writer = try mutation.string("writerID")
            let sequence = (mutation.values["sequence"] as? NSNumber)?.uint64Value ?? 0
            let identity = writer + ":" + key
            if sequence > preferenceSequences[identity, default: 0] {
                preferenceSequences[identity] = sequence
                if mutation.bool("removed") { WaifuXPreferences.shared.removeObject(forKey: key) }
                else { WaifuXPreferences.shared.set(mutation.values["value"], forKey: key) }
                WaifuXPreferences.shared.synchronize()
                if isReady { await refreshSettings(key: key) }
            }
            return ["key": key, "sequence": NSNumber(value: sequence)]
        case "runtime.refreshSettings":
            await refreshSettings()
            return [:]
        case "runtime.stop":
            stopping = true
            shutdownRequested = true
            return [:]
        case "video.setExternal":
            VideoWallpaperManager.shared.setExternalVideoRendererEnabled(a.bool("enabled"))
            return [:]
        case "video.publishSync":
            VideoWallpaperManager.shared.publishSystemWallpaperSyncControlToWebDaemon()
            return [:]
        case "video.commit":
            try VideoWallpaperManager.shared.forceCommitDesktopPresentation(on: try a.screens("screens"))
            return [:]
        case "video.sharedDecoder":
            try VideoWallpaperManager.shared.setSharedDecoderPlaybackEnabled(a.bool("enabled"), sourceScreen: try a.optionalScreen("sourceScreen"))
            return [:]
        case "video.refreshShared":
            VideoWallpaperManager.shared.refreshSharedDecoderTargets()
            return [:]
        case "video.muted":
            VideoWallpaperManager.shared.setMuted(a.bool("muted"))
            return [:]
        case "video.volume":
            try VideoWallpaperManager.shared.setVolume(a.double("newVolume"), for: try a.optionalScreen("targetScreen"))
            return [:]
        case "video.grain":
            VideoWallpaperManager.shared.refreshGrainOverlay()
            return [:]
        case "video.screenRate":
            try VideoWallpaperManager.shared.setPlaybackRate(a.double("newRate"), for: try a.screen("screen"))
            return [:]
        case "video.rate":
            VideoWallpaperManager.shared.setPlaybackRate(a.double("newRate"))
            return [:]
        case "video.pause":
            try VideoWallpaperManager.shared.pauseWallpaper(for: try a.optionalScreen("targetScreen"), persistAsUserRequest: a.bool("persistAsUserRequest"))
            return [:]
        case "video.resume":
            try VideoWallpaperManager.shared.resumeWallpaper(for: try a.optionalScreen("targetScreen"), persistAsUserRequest: a.bool("persistAsUserRequest"))
            return [:]
        case "video.crop":
            try VideoWallpaperManager.shared.applyCropToScreen(try a.screen("screen"))
            return [:]
        case "video.letterbox":
            VideoWallpaperManager.shared.refreshAutoRemoveVideoLetterbox()
            return [:]
        case "video.interpolation":
            VideoWallpaperManager.shared.refreshFrameInterpolationSettings()
            return [:]
        case "video.reloadInterpolation":
            try VideoWallpaperManager.shared.reloadPlaybackAfterInPlaceInterpolation(videoURL: try a.url("videoURL"))
            return [:]
        case "video.reloadOptimization":
            try VideoWallpaperManager.shared.reloadPlaybackAfterInPlaceOptimization(videoURL: try a.url("videoURL"))
            return [:]
        case "video.stop":
            try VideoWallpaperManager.shared.stopWallpaper(for: try a.optionalScreen("targetScreen"))
            return [:]
        case "video.paths":
            try VideoWallpaperManager.shared.bulkUpdatePaths(oldPrefix: try a.string("oldPrefix"), newPrefix: try a.string("newPrefix"))
            return [:]
        case "video.apply":
            try await VideoWallpaperManager.shared.applyVideoWallpaper(from: a.url("url"), posterURL: a.optionalURL("poster"), muted: a.bool("muted", default: true), targetScreens: a.screens("screens"), animatedTransition: a.bool("animated"), usesSharedVideoDecoder: a.bool("shared"), forceRebuild: a.bool("rebuild"))
            return [:]
        case "video.applySingle":
            try await VideoWallpaperManager.shared.applyVideoWallpaper(from: a.url("url"), posterURL: a.optionalURL("poster"), muted: a.bool("muted", default: true), targetScreens: a.screens("screens"), animatedTransition: a.bool("animated"), usesSharedVideoDecoder: a.bool("shared"), forceRebuild: a.bool("rebuild"))
            return [:]
        case "video.restorePrevious":
            let success = try await VideoWallpaperManager.shared.restorePreviousVideoWallpaperIfAvailable(for: a.screen("screen"))
            return ["success": success]
        case "video.poster":
            try VideoWallpaperManager.shared.updatePosterURL(try a.url("poster"), for: a.screen("screen"), expectedVideoURL: a.optionalURL("expected"))
            return [:]
        case "video.stopNative":
            try VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: try a.optionalScreen("screen"))
            return [:]
        case "video.discard":
            try VideoWallpaperManager.shared.discardPersistedWallpaperState(screenID: try a.string("id"), fingerprint: a.string("fingerprint"))
            return [:]
        case "video.extensionPause":
            if #available(macOS 26.0, *) { VideoWallpaperManager.shared.toggleExtensionGlobalPause() }
            return [:]
        case "engine.apply":
            try await WallpaperEngineXBridge.shared.setWallpaper(path: a.string("path"), assetsPath: a.optionalString("assets"), targetScreens: a.screens("screens"), userProperties: a.optionalString("properties"), forceRestart: a.bool("restart"), preserveAutoPauseState: a.bool("preservePause"), preserveExistingRendererUntilReady: a.bool("preserveRenderer"), requireAllTargetScreens: a.bool("requireAll"))
            return [:]
        case "engine.properties":
            try await WallpaperEngineXBridge.shared.refreshWallpaperProperties(userProperties: a.optionalString("properties"), reloadScene: a.bool("reload"))
            return [:]
        case "engine.webProperties":
            try await WallpaperEngineXBridge.shared.applyWebWallpaperProperties(a.string("properties"))
            return [:]
        case "engine.pause":
            WallpaperEngineXBridge.shared.pauseWallpaper()
            return [:]
        case "engine.resume":
            WallpaperEngineXBridge.shared.resumeWallpaper()
            return [:]
        case "engine.screenPause":
            try WallpaperEngineXBridge.shared.pauseWallpaper(for: try a.string("id"))
            return [:]
        case "engine.screenResume":
            try WallpaperEngineXBridge.shared.resumeWallpaper(for: try a.string("id"))
            return [:]
        case "engine.screenStop":
            try WallpaperEngineXBridge.shared.stopWallpaper(forScreenID: try a.string("id"))
            return [:]
        case "engine.stop":
            WallpaperEngineXBridge.shared.stopWallpaper()
            return [:]
        case "engine.muted":
            WallpaperEngineXBridge.shared.setMuted(a.bool("muted"))
            return [:]
        case "engine.volume":
            try WallpaperEngineXBridge.shared.setVolume(a.double("volume"), for: try a.optionalScreen("screen"))
            return [:]
        case "engine.designReload":
            WallpaperEngineXBridge.shared.reloadCurrentSceneWallpaperForDesign()
            return [:]
        case "engine.toggle":
            WallpaperEngineXBridge.shared.toggleWallpaper()
            return [:]
        case "engine.disable":
            WallpaperEngineXBridge.shared.disableWallpaperKeepingRestoreState()
            return [:]
        case "engine.paths":
            try WallpaperEngineXBridge.shared.bulkUpdatePaths(oldPrefix: try a.string("old"), newPrefix: a.string("new"))
            return [:]
        case "engine.restorePrevious":
            let success = try await WallpaperEngineXBridge.shared.restorePreviousWallpaperIfAvailable(for: a.screen("screen"))
            return ["success": success]
        case "engine.discard":
            try await WallpaperEngineXBridge.shared.discardPersistedWallpaperState(screenID: try a.string("id"), fingerprint: a.string("fingerprint"))
            return [:]
        case "engine.prepareSwitch":
            try WallpaperEngineXBridge.shared.prepareForNonExternalWallpaperSwitch(on: try a.screens("screens") ?? NSScreen.screens, reason: a.string("reason"))
            return [:]
        case "engine.ensureStopped":
            WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
            return [:]
        case "engine.ensureScreenStopped":
            try WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper(for: try a.optionalScreen("screen"))
            return [:]
        case "engine.ensureTransitionStopped":
            try await WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaperForTransition(for: a.screen("screen"))
            return [:]
        case "wallpaper.apply":
            let success = try await LocalWallpaperApplyService.apply(localURL: a.url("url"), targetScreens: a.screens("screens"), options: a.decode("options", as: LocalWallpaperApplyService.Options.self))
            return ["success": success]
        case "wallpaper.static":
            try await StaticWallpaperApplyService.apply(from: a.url("url"), option: WallpaperOption(rawValue: a.string("option")) ?? .desktop)
            return [:]
        case "wallpaper.staticScreen":
            try await StaticWallpaperApplyService.apply(from: a.url("url"), option: WallpaperOption(rawValue: a.string("option")) ?? .desktop, for: a.optionalScreen("screen"))
            return [:]
        case "scheduler.triggerNextWallpaperNow":
            try WallpaperSchedulerService.shared.triggerNextWallpaperNow(for: try a.string("screenID"))
            return [:]
        case "scheduler.triggerNextGlobalWallpaperNow":
            WallpaperSchedulerService.shared.triggerNextGlobalWallpaperNow()
            return [:]
        case "scheduler.triggerRandomWallpaperNow":
            try WallpaperSchedulerService.shared.triggerRandomWallpaperNow(for: try a.string("screenID"))
            return [:]
        case "scheduler.start":
            WallpaperSchedulerService.shared.start()
            return [:]
        case "scheduler.suppressAutoSwitch":
            try WallpaperSchedulerService.shared.suppressAutoSwitch(forScreen: try a.screen("screen"))
            return [:]
        case "scheduler.suppressAutoSwitchGlobally":
            WallpaperSchedulerService.shared.suppressAutoSwitchGlobally()
            return [:]
        case "scheduler.beginManualApply":
            await WallpaperSchedulerService.shared.beginManualWallpaperApply()
            return [:]
        case "scheduler.completeManualApply":
            WallpaperSchedulerService.shared.completeManualWallpaperApply(
                success: a.bool("success"),
                screenIDs: Set(a.values["screenIDs"] as? [String] ?? [])
            )
            return [:]
        case "scheduler.stop":
            WallpaperSchedulerService.shared.stop()
            return [:]
        case "scheduler.notifyManualWallpaperChange":
            WallpaperSchedulerService.shared.notifyManualWallpaperChange(
                screenID: a.optionalString("screenID"),
                itemID: a.optionalString("itemID")
            )
            return [:]
        case "scheduler.updateConfig":
            try WallpaperSchedulerService.shared.updateConfig(try a.decode("newConfig", as: SchedulerConfig.self))
            return [:]
        case "scheduler.updateGlobalDisplaySyncEnabled":
            WallpaperSchedulerService.shared.updateGlobalDisplaySyncEnabled(a.bool("enabled"))
            return [:]
        case "scheduler.updateGlobalDisplayEnabled":
            WallpaperSchedulerService.shared.updateGlobalDisplayEnabled(a.bool("enabled"))
            return [:]
        case "scheduler.updateGlobalDisplayInterval":
            WallpaperSchedulerService.shared.updateGlobalDisplayInterval(a.integer("minutes"))
            return [:]
        case "scheduler.updateGlobalDisplayOrder":
            try WallpaperSchedulerService.shared.updateGlobalDisplayOrder(ScheduleOrder(rawValue: try a.string("order")) ?? .random)
            return [:]
        case "scheduler.updateGlobalDisplayIncludeWallpapers":
            WallpaperSchedulerService.shared.updateGlobalDisplayIncludeWallpapers(a.bool("include"))
            return [:]
        case "scheduler.updateGlobalDisplayIncludeMedia":
            WallpaperSchedulerService.shared.updateGlobalDisplayIncludeMedia(a.bool("include"))
            return [:]
        case "scheduler.updateGlobalDisplayFolderIDs":
            WallpaperSchedulerService.shared.updateGlobalDisplayFolderIDs(a.values["folderIDs"] as? [String])
            return [:]
        case "scheduler.updateGlobalDisplayWebSceneSwitchSeconds":
            WallpaperSchedulerService.shared.updateGlobalDisplayWebSceneSwitchSeconds(a.optionalInteger("seconds"))
            return [:]
        case "scheduler.updateDisplayEnabled":
            try WallpaperSchedulerService.shared.updateDisplayEnabled(a.bool("enabled"), for: try a.string("screenID"))
            return [:]
        case "scheduler.updateDisplayInterval":
            try WallpaperSchedulerService.shared.updateDisplayInterval(a.integer("minutes"), for: try a.string("screenID"))
            return [:]
        case "scheduler.updateDisplayOrder":
            try WallpaperSchedulerService.shared.updateDisplayOrder(ScheduleOrder(rawValue: try a.string("order")) ?? .random, for: try a.string("screenID"))
            return [:]
        case "scheduler.updateDisplayIncludeWallpapers":
            try WallpaperSchedulerService.shared.updateDisplayIncludeWallpapers(a.bool("include"), for: try a.string("screenID"))
            return [:]
        case "scheduler.updateDisplayIncludeMedia":
            try WallpaperSchedulerService.shared.updateDisplayIncludeMedia(a.bool("include"), for: try a.string("screenID"))
            return [:]
        case "scheduler.updateDisplayFolderIDs":
            try WallpaperSchedulerService.shared.updateDisplayFolderIDs(a.values["folderIDs"] as? [String], for: try a.string("screenID"))
            return [:]
        case "scheduler.updateDisplayWebSceneSwitchSeconds":
            try WallpaperSchedulerService.shared.updateDisplayWebSceneSwitchSeconds(a.optionalInteger("seconds"), for: try a.string("screenID"))
            return [:]
        case "scheduler.synchronizeCurrentGlobalWallpaperToConnectedDisplays":
            WallpaperSchedulerService.shared.synchronizeCurrentGlobalWallpaperToConnectedDisplays()
            return [:]
        case "scheduler.configureExternalDisplayForRandomAllWallpapers":
            try WallpaperSchedulerService.shared.configureExternalDisplayForRandomAllWallpapers(try a.screen("screen"))
            return [:]
        case "scheduler.configureExternalDisplayWithoutAutoSwitch":
            try WallpaperSchedulerService.shared.configureExternalDisplayWithoutAutoSwitch(try a.screen("screen"))
            return [:]
        case "scheduler.discardPersistedDisplayState":
            try WallpaperSchedulerService.shared.discardPersistedDisplayState(screenID: try a.string("screenID"), fingerprint: try a.string("fingerprint"))
            return [:]
        case "policy.reevaluate":
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            return [:]
        case "scheduler.reevaluateBattery":
            WallpaperSchedulerService.shared.reevaluateBatterySuspension()
            return [:]
        case "policy.suppressForegroundPauseForMainWindowHide":
            DynamicWallpaperAutoPauseManager.shared.suppressForegroundPauseForMainWindowHide(duration: a.double("duration", default: 1))
            return [:]
        case "policy.clearForegroundPauseForWallpaperSwitch":
            DynamicWallpaperAutoPauseManager.shared.clearForegroundPauseForWallpaperSwitch()
            return [:]
        case "download.submitWallpaper":
            prepareDownloadExecutors()
            return ["id": try PersistentDownloadQueueService.shared.submitWallpaper(a.decode("wallpaper", as: Wallpaper.self), folderID: a.optionalString("folderID"))]
        case "download.submitMedia":
            prepareDownloadExecutors()
            let option = a.values["option"] == nil ? nil : try a.decode("option", as: MediaDownloadOption.self)
            return ["id": try PersistentDownloadQueueService.shared.submitMedia(a.decode("item", as: MediaItem.self), option: option, saveToLibrary: a.bool("save", default: true), folderID: a.optionalString("folderID"))]
        case "download.stage":
            prepareDownloadExecutors()
            return ["success": await PersistentDownloadQueueService.shared.stage(try a.decode("items", as: [MediaItem].self), folderID: a.optionalString("folderID"))]
        case "download.start":
            prepareDownloadExecutors()
            PersistentDownloadQueueService.shared.start(using: mediaDownloader!)
            return [:]
        case "download.pause":
            PersistentDownloadQueueService.shared.pause(jobID: try a.string("id"))
            return [:]
        case "download.resume":
            prepareDownloadExecutors()
            PersistentDownloadQueueService.shared.resume(jobID: try a.string("id"))
            return [:]
        case "download.cancel":
            PersistentDownloadQueueService.shared.cancel(jobID: try a.string("id"))
            return [:]
        case "download.resumeLogin":
            prepareDownloadExecutors()
            PersistentDownloadQueueService.shared.resumeWaitingForSteamLogin()
            return [:]
        case "download.retry":
            prepareDownloadExecutors()
            PersistentDownloadQueueService.shared.retry(try a.decode("task", as: DownloadTask.self))
            return [:]
        case "download.pauseTask":
            DownloadTaskService.shared.pauseTask(id: try a.string("id"))
            return [:]
        case "download.resumeTask":
            DownloadTaskService.shared.resumeTask(id: try a.string("id"))
            return [:]
        case "download.cancelTask":
            DownloadTaskService.shared.cancelTask(id: try a.string("id"))
            return [:]
        case "download.removeTask":
            DownloadTaskService.shared.removeTask(id: try a.string("id"))
            return [:]
        case "download.cancelAll":
            DownloadTaskService.shared.cancelAllActiveDownloads()
            return [:]
        case "download.wait":
            let url = try await PersistentDownloadQueueService.shared.waitForRemoteCompletion(id: a.string("id"))
            return url.map { ["url": $0.absoluteString] } ?? [:]
        case "overlay.notch":
            NotchOverlayManager.shared.setEnabled(a.bool("enabled"))
            return [:]
        case "overlay.grain":
            StaticWallpaperGrainManager.shared.updateOverlay()
            return [:]
        case "overlay.grainRefresh":
            StaticWallpaperGrainManager.shared.refreshWindows()
            return [:]
        case "overlay.clock":
            LiquidGlassClockSettings.shared.reloadFromPreferences()
            LiquidGlassClockOverlayManager.shared.refreshAll()
            return [:]
        case "overlay.clockRebuild":
            LiquidGlassClockOverlayManager.shared.rebuildAll()
            return [:]
        case "overlay.staticRefresh":
            StaticImageWallpaperOverlayManager.shared.refreshWindows()
            return [:]
        case "overlay.imageLetterbox":
            StaticImageWallpaperOverlayManager.shared.refreshAutoRemoveImageLetterbox()
            return [:]
        case "overlay.clear":
            StaticImageWallpaperOverlayManager.shared.clearState()
            return [:]
        case "overlay.clearScreen":
            try StaticImageWallpaperOverlayManager.shared.clearState(for: a.screen("screen"))
            return [:]
        case "overlay.hide":
            StaticImageWallpaperOverlayManager.shared.hideAll()
            return [:]
        case "overlay.hideScreen":
            try StaticImageWallpaperOverlayManager.shared.hide(for: a.screen("screen"))
            return [:]
        case "desktop.syncMode":
            StaticWallpaperApplyService.systemSyncModeChanged(a.bool("enabled"))
            return [:]
        case "desktop.icons":
            DesktopIconManager.shared.setDesktopIconsHidden(a.bool("hidden"))
            return [:]
        case "desktop.restore":
            try DesktopWallpaperSyncManager.shared.restoreOriginalSystemWallpaper(for: a.screen("screen"))
            return [:]
        case "sleep.userSetting":
            SleepPreventer.shared.setPreventingSleep(a.bool("enabled"), reason: .userSetting)
            return [:]
        case "crop.update":
            let screen = try a.screen("screen")
            let setting = try a.decode("settings", as: DisplayCropSettings.self)
            DisplayCropSettingsStore.shared.update(for: screen, interactive: a.bool("interactive")) { $0 = setting }
            return [:]
        case "lock.cacheVideo":
            if #available(macOS 26.0, *) { try await LockScreenWallpaperService.shared.cacheMirroringSource(videoURL: a.url("video"), videoID: a.string("id"), displayIDs: a.values["displays"] as? [UInt32] ?? [], notify: a.bool("notify", default: true)) }
            return [:]
        case "lock.cacheImage":
            if #available(macOS 26.0, *) { try await LockScreenWallpaperService.shared.cacheStaticImageSource(imageURL: a.url("image"), displayIDs: a.values["displays"] as? [UInt32] ?? []) }
            return [:]
        case "lock.paused":
            if #available(macOS 26.0, *) { LockScreenWallpaperService.shared.setPaused(a.bool("paused")) }
            return [:]
        case "lock.desktopPaused":
            if #available(macOS 26.0, *) { LockScreenWallpaperService.shared.setAlwaysPauseDesktop(a.bool("paused")) }
            return [:]
        case "lock.pauseOnBattery":
            // 电池暂停开关镜像：扩展自己检测电源/低功耗状态，这里只同步用户开关。
            LockScreenWallpaperService.shared.setPauseOnBattery(
                a.bool("enabled"),
                forceNotify: a.bool("forceNotify", default: false)
            )
            return [:]
        case "lock.displayPause":
            if #available(macOS 26.0, *) { LockScreenWallpaperService.shared.setDisplayPaused(a.bool("paused"), forDisplayID: UInt32(a.integer("display"))) }
            return [:]
        case "lock.displayMuted":
            if #available(macOS 26.0, *) { LockScreenWallpaperService.shared.setDisplayMuted(a.bool("muted"), forDisplayID: UInt32(a.integer("display"))) }
            return [:]
        case "lock.syncDisplays":
            if #available(macOS 26.0, *) { LockScreenWallpaperService.shared.syncDisplayInstancesToSocketServer() }
            return [:]
        case "lock.syncCatalog":
            if #available(macOS 26.0, *) { LockScreenWallpaperService.shared.syncInstanceCatalogToSocketServer(notify: a.bool("notify", default: true)) }
            return [:]
        case "lock.clearInstances":
            if #available(macOS 26.0, *) { LockScreenWallpaperService.shared.clearLockScreenInstances() }
            return [:]
        case "lock.clearCache":
            if #available(macOS 26.0, *) { LockScreenWallpaperService.shared.clearMirroringSourceCache(notify: a.bool("notify", default: true)) }
            return [:]
        case "lock.clearRealtime":
            if #available(macOS 26.0, *) { LockScreenWallpaperService.shared.clearRealtimeSourceIfNeeded(notify: a.bool("notify", default: true)) }
            return [:]
        case "saver.install":
            try await ScreenSaverService.shared.install()
            return [:]
        case "saver.uninstall":
            try await ScreenSaverService.shared.uninstall()
            return [:]
        case "saver.sync":
            return ["success": ScreenSaverService.shared.syncFromDesktop(reason: try a.string("reason"), force: a.bool("force"))]
        case "saver.syncNow":
            try await ScreenSaverService.shared.syncNow()
            return [:]
        case "optimization.applySettings0":
            try VideoOptimizationQueueService.shared.applySettings(autoOnDownload: a.bool("autoOnDownload"))
            return [:]
        case "optimization.applySettings1":
            try VideoOptimizationQueueService.shared.applySettings(automaticPolicy: try a.decode("automaticPolicy", as: VideoOptimizationAutomaticPolicy.self))
            return [:]
        case "optimization.enqueueAutomaticOptimizationIfNeeded":
            _ = try VideoOptimizationQueueService.shared.enqueueAutomaticOptimizationIfNeeded(videoURL: try a.url("videoURL"), title: a.optionalString("title"))
            return [:]
        case "optimization.enqueueAfterBakeIfNeeded":
            _ = try VideoOptimizationQueueService.shared.enqueueAfterBakeIfNeeded(videoURL: try a.url("videoURL"), title: a.optionalString("title"))
            return [:]
        case "optimization.registerDownloadedSource":
            try VideoOptimizationQueueService.shared.registerDownloadedSource(videoURL: try a.url("videoURL"), sourceURL: try a.optionalURL("sourceURL"))
            return [:]
        case "optimization.registerBakedSource":
            try VideoOptimizationQueueService.shared.registerBakedSource(videoURL: try a.url("videoURL"), sourcePath: try a.string("sourcePath"), artifact: try a.decode("artifact", as: SceneBakeArtifact.self))
            return [:]
        case "optimization.resetOptimizationState":
            try VideoOptimizationQueueService.shared.resetOptimizationState(videoURL: try a.url("videoURL"))
            return [:]
        case "optimization.requestAfterSourceRestore":
            try VideoOptimizationQueueService.shared.requestAfterSourceRestore(videoURL: try a.url("videoURL"), title: a.optionalString("title"), operations: (a.values["operations"] as? [String] ?? []).compactMap(FrameInterpolationQueueItem.Operation.init(rawValue:)))
            return [:]
        case "optimization.cancelSourceRestoreRequest":
            try VideoOptimizationQueueService.shared.cancelSourceRestoreRequest(videoURL: try a.url("videoURL"))
            return [:]
        case "optimization.enqueueOptimizeVideo":
            _ = try VideoOptimizationQueueService.shared.enqueueOptimizeVideo(videoURL: try a.url("videoURL"), title: a.optionalString("title"), targetFPS: a.optionalInteger("targetFPS"), source: FrameInterpolationQueueItem.Source(rawValue: try a.string("source")) ?? .manual)
            return [:]
        case "optimization.enqueueLoopTransition":
            _ = try VideoOptimizationQueueService.shared.enqueueLoopTransition(videoURL: try a.url("videoURL"), title: a.optionalString("title"), source: FrameInterpolationQueueItem.Source(rawValue: try a.string("source")) ?? .manual)
            return [:]
        case "optimization.enqueueLoopAnalysis":
            _ = try VideoOptimizationQueueService.shared.enqueueLoopAnalysis(videoURL: try a.url("videoURL"), title: a.optionalString("title"), source: FrameInterpolationQueueItem.Source(rawValue: try a.string("source")) ?? .manual)
            return [:]
        case "optimization.enqueueFrameInterpolation":
            _ = try VideoOptimizationQueueService.shared.enqueueFrameInterpolation(videoURL: try a.url("videoURL"), title: a.optionalString("title"), targetFPS: a.optionalInteger("targetFPS"), source: FrameInterpolationQueueItem.Source(rawValue: try a.string("source")) ?? .manual)
            return [:]
        case "optimization.enqueueLoopTransitionThenInterpolation":
            _ = try VideoOptimizationQueueService.shared.enqueueLoopTransitionThenInterpolation(videoURL: try a.url("videoURL"), title: a.optionalString("title"), targetFPS: a.optionalInteger("targetFPS"), source: FrameInterpolationQueueItem.Source(rawValue: try a.string("source")) ?? .manual)
            return [:]
        case "optimization.markInterpolationNotNeeded":
            try VideoOptimizationQueueService.shared.markInterpolationNotNeeded(videoURL: try a.url("videoURL"), title: try a.string("title"), targetFPS: a.integer("targetFPS"), reason: try a.string("reason"))
            return [:]
        case "optimization.enqueueFolder":
            _ = try VideoOptimizationQueueService.shared.enqueueFolder(at: try a.url("folderURL"), operation: FrameInterpolationQueueItem.Operation(rawValue: try a.string("operation")) ?? .frameInterpolation, targetFPS: a.optionalInteger("targetFPS"), source: FrameInterpolationQueueItem.Source(rawValue: try a.string("source")) ?? .manual)
            return [:]
        case "optimization.enqueueLibraryFolder":
            _ = try VideoOptimizationQueueService.shared.enqueueLibraryFolder(try a.decode("folder", as: LibraryFolder.self), targetFPS: a.optionalInteger("targetFPS"), source: FrameInterpolationQueueItem.Source(rawValue: try a.string("source")) ?? .manual)
            return [:]
        case "optimization.enqueueAfterDownloadIfNeeded":
            _ = try VideoOptimizationQueueService.shared.enqueueAfterDownloadIfNeeded(videoURL: try a.url("videoURL"), title: a.optionalString("title"))
            return [:]
        case "optimization.removeCompleted":
            try VideoOptimizationQueueService.shared.removeCompleted(videoURL: try a.url("videoURL"))
            return [:]
        case "optimization.markBlacklisted":
            try VideoOptimizationQueueService.shared.markBlacklisted(videoURL: try a.url("videoURL"), title: try a.string("title"), targetFPS: a.integer("targetFPS"))
            return [:]
        case "optimization.removeBlacklisted":
            try VideoOptimizationQueueService.shared.removeBlacklisted(videoURL: try a.url("videoURL"))
            return [:]
        case "optimization.cancel":
            let id = try a.uuid("id")
            VideoOptimizationQueueService.shared.cancel(id: optimizationAliases[id] ?? id)
            return [:]
        case "optimization.retry":
            _ = try VideoOptimizationQueueService.shared.retry(historyID: try a.uuid("historyID"))
            return [:]
        case "optimization.enqueue":
            let requestedID = try a.uuid("requestedID")
            let actualID = try VideoOptimizationQueueService.shared.enqueue(videoURL: a.url("url"), title: a.optionalString("title"), targetFPS: a.integer("fps"), source: FrameInterpolationQueueItem.Source(rawValue: a.string("source")) ?? .manual, operations: (a.values["operations"] as? [String] ?? []).compactMap(FrameInterpolationQueueItem.Operation.init(rawValue:)))
            if let actualID {
                optimizationAliases[requestedID] = actualID
                let liveIDs = Set(VideoOptimizationQueueService.shared.items.map(\.id))
                optimizationAliases = optimizationAliases.filter { liveIDs.contains($0.value) }
            }
            return [:]
        case "assets.prepare.wait":
            guard let root = await WallpaperEngineEmbeddedAssets.awaitAssetsReady() else { throw CocoaError(.fileReadNoSuchFile) }
            return ["root": try JSONEncoder().encode(root)]
        case "bake.scene.wait":
            let artifact = try await SceneOfflineBakeService.bake(eligibility: a.decode("eligibility", as: SceneBakeEligibilitySnapshot.self), contentRoot: a.url("root"), cacheItemID: a.string("cacheID"), durationSeconds: a.values["duration"] as? Double, fps: a.optionalInteger("fps").map(Int32.init), renderer: SceneBakeRenderer(rawValue: a.string("renderer")) ?? .wallpaperWgpu, persistArtifactToItemID: a.optionalString("itemID"), progressItemID: a.optionalString("progressItemID"), displayTitle: a.optionalString("title"), isCompanion: a.bool("companion"))
            return ["artifact": try JSONEncoder().encode(artifact)]
        case "bake.record.wait":
            let artifact = try await SceneOfflineBakeService.bake(record: a.decode("record", as: MediaDownloadRecord.self), durationSeconds: a.values["duration"] as? Double, fps: a.optionalInteger("fps").map(Int32.init), renderer: SceneBakeRenderer(rawValue: a.string("renderer")) ?? .wallpaperWgpu)
            return ["artifact": try JSONEncoder().encode(artifact)]
        case "bake.video.wait":
            let result = try await BakeService.shared.bakeVideo(scenePath: a.string("path"), assetsPath: a.optionalString("assets"), outputURL: a.url("output"), targetWidth: a.optionalInteger("width"), targetHeight: a.optionalInteger("height"), fps: a.integer("fps"), duration: a.double("duration"))
            return ["result": try JSONEncoder().encode(result)]
        case "bake.cancel":
            BakeService.shared.cancel()
            return [:]
        case "library.media.toggleFavorite0":
            try MediaLibraryService.shared.toggleFavorite(try a.decode("item", as: MediaItem.self))
            return [:]
        case "library.media.markAsLooped0":
            try MediaLibraryService.shared.markAsLooped(localFilePath: try a.string("path"))
            return [:]
        case "library.media.recordDownload0":
            try MediaLibraryService.shared.recordDownload(item: try a.decode("item", as: MediaItem.self), localFileURL: try a.url("localFileURL"), folderID: a.optionalString("folderID"))
            return [:]
        case "library.media.ensureDownloadRecord0":
            try MediaLibraryService.shared.ensureDownloadRecord(item: try a.decode("item", as: MediaItem.self), localFileURL: try a.url("localFileURL"), folderID: a.optionalString("folderID"))
            return [:]
        case "library.media.attachSceneBakeEligibility0":
            try MediaLibraryService.shared.attachSceneBakeEligibility(itemID: try a.string("itemID"), snapshot: try a.decode("snapshot", as: SceneBakeEligibilitySnapshot.self), triggerAutoBake: a.bool("triggerAutoBake"))
            return [:]
        case "library.media.attachSceneBakeArtifact0":
            try MediaLibraryService.shared.attachSceneBakeArtifact(itemID: try a.string("itemID"), artifact: try a.decode("artifact", as: SceneBakeArtifact.self), regeneratePoster: a.bool("regeneratePoster"))
            return [:]
        case "library.media.upsert0":
            try MediaLibraryService.shared.upsert(try a.decode("item", as: MediaItem.self))
            return [:]
        case "library.media.updateDownloadPath0":
            try MediaLibraryService.shared.updateDownloadPath(for: try a.string("itemID"), newURL: try a.url("newURL"))
            return [:]
        case "library.media.bulkUpdateDownloadPaths0":
            try MediaLibraryService.shared.bulkUpdateDownloadPaths(oldPrefix: try a.string("oldPrefix"), newPrefix: try a.string("newPrefix"))
            return [:]
        case "library.media.recordViewed0":
            try MediaLibraryService.shared.recordViewed(try a.decode("item", as: MediaItem.self))
            return [:]
        case "library.media.removeFavoriteRecords0":
            try MediaLibraryService.shared.removeFavoriteRecords(withIDs: try a.decode("ids", as: Set<String>.self))
            return [:]
        case "library.media.removeDownloadRecord0":
            try MediaLibraryService.shared.removeDownloadRecord(withID: try a.string("id"))
            return [:]
        case "library.media.removeDownloadRecords0":
            try MediaLibraryService.shared.removeDownloadRecords(withIDs: try a.decode("ids", as: Set<String>.self))
            return [:]
        case "library.media.clearSceneBakeArtifact0":
            try MediaLibraryService.shared.clearSceneBakeArtifact(itemID: try a.string("itemID"))
            return [:]
        case "library.media.clearSceneBakeArtifactKeepingPoster0":
            try MediaLibraryService.shared.clearSceneBakeArtifactKeepingPoster(itemID: try a.string("itemID"))
            return [:]
        case "library.media.removeRecentItems0":
            try MediaLibraryService.shared.removeRecentItems(withIDs: try a.decode("ids", as: Set<String>.self))
            return [:]
        case "library.media.moveItemsToRoot0":
            try MediaLibraryService.shared.moveItemsToRoot(fromFolder: try a.string("folderID"))
            return [:]
        case "library.media.repairDownloadPath0":
            try MediaLibraryService.shared.repairDownloadPath(itemID: try a.string("itemID"), newPath: try a.string("newPath"))
            return [:]
        case "library.media.deactivateDownloadRecord0":
            try MediaLibraryService.shared.deactivateDownloadRecord(itemID: try a.string("itemID"))
            return [:]
        case "library.media.syncImportFavorites0":
            try MediaLibraryService.shared.syncImportFavorites(try a.decode("records", as: [MediaFavoriteRecord].self))
            return [:]
        case "library.media.syncImportDownloads0":
            try MediaLibraryService.shared.syncImportDownloads(try a.decode("records", as: [MediaDownloadRecord].self))
            return [:]
        case "library.media.syncImportRecents0":
            try MediaLibraryService.shared.syncImportRecents(try a.decode("items", as: [MediaItem].self))
            return [:]
        case "library.media.syncRemoveFavorites0":
            try MediaLibraryService.shared.syncRemoveFavorites(ids: try a.decode("ids", as: Set<String>.self))
            return [:]
        case "library.media.syncRemoveDownloads0":
            try MediaLibraryService.shared.syncRemoveDownloads(ids: try a.decode("ids", as: Set<String>.self))
            return [:]
        case "library.wallpaper.toggleFavorite0":
            try WallpaperLibraryService.shared.toggleFavorite(try a.decode("wallpaper", as: Wallpaper.self))
            return [:]
        case "library.wallpaper.markAsLooped0":
            try WallpaperLibraryService.shared.markAsLooped(localFilePath: try a.string("path"))
            return [:]
        case "library.wallpaper.recordDownload0":
            try WallpaperLibraryService.shared.recordDownload(try a.decode("wallpaper", as: Wallpaper.self), fileURL: try a.url("fileURL"), folderID: a.optionalString("folderID"))
            return [:]
        case "library.wallpaper.upsert0":
            try WallpaperLibraryService.shared.upsert(try a.decode("wallpaper", as: Wallpaper.self))
            return [:]
        case "library.wallpaper.upsertBatch0":
            try WallpaperLibraryService.shared.upsertBatch(try a.decode("wallpapers", as: [Wallpaper].self))
            return [:]
        case "library.wallpaper.updateDownloadPath0":
            try WallpaperLibraryService.shared.updateDownloadPath(for: try a.string("wallpaperID"), newURL: try a.url("newURL"))
            return [:]
        case "library.wallpaper.bulkUpdateDownloadPaths0":
            try WallpaperLibraryService.shared.bulkUpdateDownloadPaths(oldPrefix: try a.string("oldPrefix"), newPrefix: try a.string("newPrefix"))
            return [:]
        case "library.wallpaper.moveItemsToRoot0":
            try WallpaperLibraryService.shared.moveItemsToRoot(fromFolder: try a.string("folderID"))
            return [:]
        case "library.wallpaper.repairDownloadPath0":
            try WallpaperLibraryService.shared.repairDownloadPath(recordID: try a.string("recordID"), newPath: try a.string("newPath"))
            return [:]
        case "library.wallpaper.deactivateDownloadRecord0":
            try WallpaperLibraryService.shared.deactivateDownloadRecord(recordID: try a.string("recordID"))
            return [:]
        case "library.wallpaper.syncImportFavorites0":
            try WallpaperLibraryService.shared.syncImportFavorites(try a.decode("records", as: [WallpaperFavoriteRecord].self))
            return [:]
        case "library.wallpaper.syncImportDownloads0":
            try WallpaperLibraryService.shared.syncImportDownloads(try a.decode("records", as: [WallpaperDownloadRecord].self))
            return [:]
        case "library.wallpaper.syncRemoveFavorites0":
            try WallpaperLibraryService.shared.syncRemoveFavorites(ids: try a.decode("ids", as: Set<String>.self))
            return [:]
        case "library.wallpaper.syncRemoveDownloads0":
            try WallpaperLibraryService.shared.syncRemoveDownloads(ids: try a.decode("ids", as: Set<String>.self))
            return [:]
        case "library.wallpaper.removeWallpaperFavorites0":
            try WallpaperLibraryService.shared.removeWallpaperFavorites(withIDs: try a.decode("ids", as: Set<String>.self))
            return [:]
        case "library.wallpaper.removeWallpaperDownloads0":
            try WallpaperLibraryService.shared.removeWallpaperDownloads(withIDs: try a.decode("ids", as: Set<String>.self))
            return [:]
        case "library.folder.create":
            LibraryFolderStore.shared.acceptCreatedFolder(try a.decode("folder", as: LibraryFolder.self))
            return [:]
        case "library.folder.renameFolder":
            try LibraryFolderStore.shared.renameFolder(id: try a.string("id"), contentType: try a.decode("contentType", as: LibraryFolder.FolderContentType.self), newName: try a.string("newName"))
            return [:]
        case "library.folder.toggleFolderLock":
            try LibraryFolderStore.shared.toggleFolderLock(id: try a.string("id"), contentType: try a.decode("contentType", as: LibraryFolder.FolderContentType.self))
            return [:]
        case "library.folder.setFolderLock":
            try LibraryFolderStore.shared.setFolderLock(id: try a.string("id"), contentType: try a.decode("contentType", as: LibraryFolder.FolderContentType.self), locked: a.bool("locked"))
            return [:]
        case "library.folder.deleteFolder":
            try LibraryFolderStore.shared.deleteFolder(id: try a.string("id"), contentType: try a.decode("contentType", as: LibraryFolder.FolderContentType.self))
            return [:]
        case "library.folder.syncImportWallpaperFolders":
            try LibraryFolderStore.shared.syncImportWallpaperFolders(try a.decode("folders", as: [LibraryFolder].self))
            return [:]
        case "library.folder.syncImportMediaFolders":
            try LibraryFolderStore.shared.syncImportMediaFolders(try a.decode("folders", as: [LibraryFolder].self))
            return [:]
        case "library.snapshot":
            guard libraryRecordsAreRestored else {
                // 恢复未完成就应答会返回空/半量快照，UI 侧据此判「已到达」
                // 反而把假空态换个理由复现。让这次读明确失败，由调用方按拍重试。
                throw CocoaError(.featureUnsupported, userInfo: [
                    NSLocalizedDescriptionKey: "库记录尚未恢复完成"
                ])
            }
            return ["media": MediaLibraryService.shared.backgroundLibrarySnapshot(), "wallpaper": WallpaperLibraryService.shared.backgroundLibrarySnapshot(), "mediaFolders": try JSONEncoder().encode(LibraryFolderStore.shared.mediaFolders), "wallpaperFolders": try JSONEncoder().encode(LibraryFolderStore.shared.wallpaperFolders)]
        case "steam.start":
            try SteamServiceManager.shared.start()
            return [:]
        case "steam.shutdown":
            try SteamServiceManager.shared.shutdown()
            return [:]
        case "steam.loginWithQR":
            try SteamServiceManager.shared.loginWithQR()
            return [:]
        case "steam.cancelLogin":
            try SteamServiceManager.shared.cancelLogin()
            return [:]
        case "steam.logout":
            try SteamServiceManager.shared.logout()
            return [:]
        case "steam.submitGuardCode":
            try SteamServiceManager.shared.submitGuardCode(try a.string("code"))
            return [:]
        case "steam.cancelDownload":
            try SteamServiceManager.shared.cancelDownload(taskID: try a.string("taskID"))
            return [:]
        case "steam.login.wait":
            try await SteamServiceManager.shared.login(username: a.string("username"), password: a.string("password"), guardCode: a.optionalString("code"))
            return [:]
        case "steam.subscriptions.wait":
            let page = try await SteamServiceManager.shared.fetchSubscriptions(startIndex: a.integer("start"))
            return ["page": try JSONEncoder().encode(page)]
        case "steam.download.wait":
            let url = try await SteamServiceManager.shared.downloadItem(workshopID: a.string("id"), outputRoot: a.url("root"))
            return ["url": try JSONEncoder().encode(url)]
        case "directory.migrate.wait":
            let result = await DirectoryMigrationService.shared.migrate(from: try a.url("old"), to: try a.url("new")) { [weak self] progress in
                self?.migrationProgress = progress
                self?.schedulePublish()
            }
            migrationProgress = nil
            return ["result": try JSONEncoder().encode(result)]
        default: throw NSError(domain: "WaifuXHelper", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unknown background command: \(operation)"])
        }
    }

    private func releaseIdleDownloadExecutors() {
        idleDownloadRelease?.cancel()
        idleDownloadRelease = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, !PersistentDownloadQueueService.shared.hasExecutableWork else { return }
            wallpaperDownloader = nil
            mediaDownloader = nil
            idleDownloadRelease = nil
        }
    }

    private func prepareDownloadExecutors() {
        idleDownloadRelease?.cancel()
        if wallpaperDownloader == nil { wallpaperDownloader = WallpaperViewModel() }
        if mediaDownloader == nil { mediaDownloader = MediaExploreViewModel() }
        PersistentDownloadQueueService.shared.configure(wallpaperViewModel: wallpaperDownloader!, mediaViewModel: mediaDownloader!)
    }

    private func applyNetworkPreferences() async {
        let preferences = WaifuXPreferences.shared
        await NetworkService.shared.updateProxyConfiguration(
            enabled: preferences.bool(forKey: "proxy_enabled"),
            host: preferences.string(forKey: "proxy_host") ?? "",
            port: preferences.string(forKey: "proxy_port") ?? ""
        )
    }

    private func refreshSettings(key: String? = nil) async {
        guard !stopping, !upgrading else { return }
        if key == nil || key?.hasPrefix("proxy_") == true {
            await applyNetworkPreferences()
            guard !Task.isCancelled, !stopping, !upgrading else { return }
        }
        if key == nil || key == ThemeManager.preferencesKey || key == ThemeManager.legacyPreferencesKey {
            ThemeManager.shared.restoreSavedSettings()
        }
        if key == nil || key?.hasPrefix("auto_pause") == true || key?.hasPrefix("pause_") == true || key?.contains("battery") == true || key?.contains("coverage") == true || key == "playback_policy_display_sleep" {
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
        }
        guard !BackgroundRuntimeRole.isIsolatedTest else { return }
        if key == nil || key == "liquid_glass_clock_config_v2" {
            LiquidGlassClockSettings.shared.reloadFromPreferences()
            LiquidGlassClockOverlayManager.shared.refreshAll()
        }
        if key == nil || key == "grain_texture_enabled" || key == "arc_grain_intensity" {
            ArcBackgroundSettings.shared.reloadFromPreferences()
            StaticWallpaperGrainManager.shared.updateOverlay()
        }
        if key?.hasPrefix("display_crop_") == true { DisplayCropSettingsStore.shared.reloadFromPreferences() }
        if key == nil || key == "wallpaper_extension_keeper_enabled" {
            if WaifuXPreferences.shared.object(forKey: "wallpaper_extension_keeper_enabled") as? Bool ?? true { WallpaperExtensionAgentHealer.shared.start() }
            else { WallpaperExtensionAgentHealer.shared.stop() }
        }
        if key == "app_language" { LocalizationService.shared.restoreSavedSettings() }
        if key == nil || key == "hide_notch" { NotchOverlayManager.shared.setEnabled(WaifuXPreferences.shared.bool(forKey: "hide_notch")) }
        if key == nil || key == "prevent_system_sleep" { SleepPreventer.shared.setPreventingSleep(WaifuXPreferences.shared.bool(forKey: "prevent_system_sleep"), reason: .userSetting) }
        if key == nil || key == "system_wallpaper_sync_enabled" {
            VideoWallpaperManager.shared.publishSystemWallpaperSyncControlToWebDaemon()
            StaticWallpaperApplyService.systemSyncModeChanged(WaifuXPreferences.shared.object(forKey: "system_wallpaper_sync_enabled") as? Bool ?? true)
        }
    }

    func completeAcknowledgedCommand() {
        guard shutdownRequested else { return }
        shutdownRequested = false
        Task {
            // Flush the stop acknowledgement before teardown/connection loss.
            try? await Task.sleep(for: .milliseconds(100))
            await stopAll()
        }
    }

    func requestApplicationQuit() async {
        guard !applicationQuitRequested, !stopAllStarted else { return }
        applicationQuitRequested = true
        if observers.isEmpty { await stopAll(); return }
        // An open UI gets a chance to submit its final settings. No UI is
        // launched when only the Helper/menu bar is running.
        let request = (try? BackgroundPropertyList.encode(["quitRequested": true])) ?? Data()
        for connection in observers.values {
            (connection.remoteObjectProxy as? BackgroundAgentObserver)?.snapshotChanged(request as NSData)
        }
        quitFallbackTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            // A connected UI owns its write drain and quit failure handling.
            // Do not stop its durable writer while final settings are queued.
            if observers.isEmpty { await stopAll() }
            else { applicationQuitRequested = false }
        }
    }

    func stopAll() async {
        guard !stopAllStarted else { return }
        stopAllStarted = true
        prepareForProcessExit(clearActiveSession: true)
        await BakeService.shared.finishPendingRendererLaunchesForProcessTermination()
        let stopped = (try? BackgroundPropertyList.encode(["stopped": true])) ?? Data()
        for connection in observers.values { (connection.remoteObjectProxy as? BackgroundAgentObserver)?.snapshotChanged(stopped as NSData) }
        try? await Task.sleep(for: .milliseconds(100))
        finishProcessExit()
        NSApp.terminate(nil)
    }

    /// Both explicit quit and code replacement own the same workers. Upgrades
    /// preserve the session marker so the replacement restores the current work.
    private func prepareForProcessExit(clearActiveSession: Bool) {
        stopping = true
        GlobalWallpaperSyncCoordinator.shared.prepareForProcessExit()
        SystemAudioCaptureService.shared.stopAllForProcessTermination()
        WallsflowWebFetcher.shared.prepareForProcessTermination()
        StaticWallpaperApplyService.prepareForProcessTermination()
        LiquidGlassClockOverlayManager.shared.prepareForProcessTermination()
        StaticImageWallpaperOverlayManager.shared.prepareForProcessTermination()
        exitingChildren = BackgroundChildProcessCleanup.snapshot()
        quitFallbackTask?.cancel()
        idleExitTask?.cancel()
        publishTask?.cancel()
        startupTask?.cancel()
        libraryRecoveryTask?.cancel()
        idleDownloadRelease?.cancel()
        for task in inFlightReplies.values { task.cancel() }
        subscriptions.removeAll()
        if clearActiveSession {
            WaifuXPreferences.shared.removeObject(forKey: sessionKey)
            WaifuXPreferences.shared.synchronize()
        }
        WallpaperSchedulerService.shared.prepareForProcessTermination()
        BakeService.shared.prepareForProcessTermination()
        if !BackgroundRuntimeRole.isIsolatedTest {
            WallpaperExtensionAgentHealer.shared.stop()
            SceneOfflineBakeService.cancelRealtimeCompanionBake(reason: "applicationQuit")
            SceneOfflineBakeService.stopPreview()
            SteamServiceManager.shared.shutdown()
        }
        // Preserve the selected wallpaper for the next manual launch. Stop
        // rendering using the existing termination hooks, rather than clearing
        // the user's saved wallpaper through stopWallpaper().
        prepareForTermination()
        BackgroundChildProcessCleanup.terminate(exitingChildren)
    }

    /// Catch workers created by a previously scheduled completion during the
    /// short acknowledgement flush, and recheck captured reparented workers.
    func finishProcessExit() {
        BackgroundChildProcessCleanup.terminate(exitingChildren + BackgroundChildProcessCleanup.snapshot())
    }
    func prepareForTermination() {
        guard isReady else { return }
        VideoWallpaperManager.shared.prepareForAppTermination()
        WallpaperEngineXBridge.shared.prepareForAppTermination()
        if #available(macOS 26.0, *) {
            WallpaperExtensionSocketServer.shared.notifyAppWillTerminate()
            WallpaperExtensionSocketServer.shared.stop()
        }
        isReady = false
    }

    func prepareForUpgrade() async {
        upgrading = true
        _ = await commandTail?.value
        // Existing queue and migration checkpoints remain intact. Do not clear
        // the user's desired wallpaper, pause settings or active-session marker.
        prepareForProcessExit(clearActiveSession: false)
        await BakeService.shared.finishPendingRendererLaunchesForProcessTermination()
    }
}

extension Notification.Name {
    static let backgroundAgentReleaseMemory = Notification.Name("com.waifux.helper.releaseMemory")
}
#endif
