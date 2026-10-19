//  WaifuX Wallpaper Extension
//  基于 WallpaperExtensionKit 私有框架实现锁屏动态壁纸
//  仅在 macOS 26.0+ 生效

import AppKit
import ExtensionFoundation
import Foundation
import os

struct WallpaperExtensionConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        extLog("XPC from PID=\(connection.processIdentifier)")

        let exported = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)

        // 构建 XPC 类型白名单（从运行时加载的 WallpaperExtensionKit 类）
        let typeNames = [
            "WallpaperIDXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC",
            "WallpaperChoiceIDsXPC",
            "WallpaperExtensionChoiceRequestXPC",
            "WallpaperChoiceRequestAdditionResultXPC",
            "WallpaperDebugRequestXPC",
            "WallpaperDebugResponseXPC",
            "WallpaperMigrationVersionXPC",
            "WallpaperSettingsViewModelsXPC",
            "AuditTokenXPC",
        ]

        let allTypes = NSMutableSet()
        var missing: [String] = []
        for name in typeNames {
            if let cls = objc_getClass(name) {
                allTypes.add(cls)
            } else {
                missing.append(name)
            }
        }
        if !missing.isEmpty {
            extLog("  MISSING types: \(missing.joined(separator: ", "))")
        }
        allTypes.add(NSString.self)
        allTypes.add(NSNumber.self)
        allTypes.add(NSData.self)
        allTypes.add(NSArray.self)
        allTypes.add(NSDictionary.self)
        allTypes.add(NSURL.self)
        allTypes.add(NSError.self)

        let classes = allTypes as! Set<AnyHashable>

        let selectors: [(Selector, Int, Bool)] = [
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.invalidate(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.selectedChoicesDidChange(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.isChoiceDownloaded(with:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.download(withChoiceID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.pauseDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.cancelDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.resumeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.removeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.skipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.canSkipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.handleNotification(withNamed:reply:)), 0, false),
        ]

        for (sel, idx, isReply) in selectors {
            exported.setClasses(classes, for: sel, argumentIndex: idx, ofReply: isReply)
        }

        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(with: WallpaperExtensionProxyXPCProtocol.self)

        let handler = WallpaperXPCHandler()
        connection.exportedObject = handler

        connection.interruptionHandler = {
            extLog("XPC interrupted from PID=\(connection.processIdentifier)")
        }
        connection.invalidationHandler = { [weak handler] in
            // SpiralRecovery：区分「agent 空转的空连接」（被接受但没调用任何方法就
            // 断开）与「服务过方法的正常断开」。连续空连接达到阈值时发 Darwin 通知
            // 请求 Helper 的安全健康检查，不重启 WallpaperAgent。
            if let handler, !handler.servedAnyMethod {
                SpiralRecovery.noteEmptyConnection(pid: connection.processIdentifier)
            } else {
                SpiralRecovery.noteHealthyConnection()
            }
            handler?.stopObservingPrefs()
            handler?.agentProxy = nil
            let ownedContexts = handler?.takeOwnedContexts() ?? [:]
            let ownedContextIDs = Set(ownedContexts.keys)
            let removed = WallpaperState.shared.removeContexts(ids: ownedContextIDs, ownedBy: ownedContexts)
            let remaining = WallpaperState.shared.activeContextCount
            guard !removed.isEmpty else {
                // Benign teardown: no live contexts (settings-only connection, or
                // we were already inactive). Nothing rendering, nothing to recover.
                extLog("XPC invalidated from PID=\(connection.processIdentifier) ownedContexts=\(ownedContextIDs.count) remaining=\(remaining)")
                return
            }
            // Abnormal path: the host connection died while we still held live
            // rendering contexts. Deep standby/hibernation tears the XPC connection
            // down after hours asleep (it can also drop spontaneously during normal
            // use). removeContexts(ids:) has freed the now-dead CAContexts, but the
            // wallpaper is still the user's selection and WindowServer does NOT
            // re-acquire on its own — it keeps compositing the dead surface, leaving
            // the desktop grey/black until the wallpaper is reselected.
            //
            // Normal teardown (switching wallpaper, a display being removed) arrives
            // as invalidate(withId:), which clears each context first. If this was
            // only one of several live connections, keep the process alive: the
            // remaining connections still own valid CAContexts and exiting here
            // would blank unrelated displays. Exit only after the last live context
            // has been reclaimed so WallpaperAgent can re-acquire the whole set.
            WallpaperPrefs.shared.setActive(remaining > 0)
            if remaining > 0 {
                extLog("XPC invalidated for one connection — freed \(removed.count) owned context(s), kept \(remaining) other context(s)")
                return
            }
            extLog("XPC invalidated mid-render — freed \(removed.count) owned context(s); exiting to force re-acquire")
            exit(0)
        }

        connection.resume()

        handler.agentProxy = connection.remoteObjectProxy as? WallpaperExtensionProxyXPCProtocol

        // 注册 pref 变化监听：当 App 部署新视频时通知系统刷新壁纸设置
        handler.startObservingPrefs()

        extLog("XPC accepted with full protocol")
        return true
    }
}

/// 所有 socket 命令消费（drainPendingSocketCommands）统一走此串行后台队列。
/// 原因：drain 内部使用同步 socket I/O（connect 超时 2s + read 超时 1s），
/// 在主线程执行会阻塞 run loop，导致系统 WallpaperAgent 的 XPC 回调（acquire/update）
/// 延迟甚至超时，进而判定扩展无响应并将其重启 → 表现为"用一会儿偶尔黑屏"。
/// 串行队列还避免 commandsChanged / prefsChanged 两个 Darwin 通知路径并发 drain 时的竞争。
///
/// ⚠️ 必须作为模块级常量而非 `static let`：Darwin 通知回调是 C 函数指针，
/// 不能捕获 dynamic Self；引用模块顶层 `let` 不属于捕获，可编译通过。
let wallpaperCommandQueue = DispatchQueue(label: "com.waifux.wallpaperextension.command", qos: .utility)

@main
final class WaifuXWallpaperExtension: NSObject, AppExtension {
    typealias Configuration = WallpaperExtensionConfiguration
    private static let wakeRecoveryGeneration = OSAllocatedUnfairLock(initialState: 0)
    private static let hostAppBundleIdentifier = "com.waifux.app"

    var configuration: WallpaperExtensionConfiguration {
        WallpaperExtensionConfiguration()
    }

    override required init() {
        super.init()

        guard #available(macOS 26.0, *) else {
            extLog("INIT — macOS < 26, WallpaperExtensionKit disabled")
            return
        }

        let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if let handle = dlopen(frameworkPath, RTLD_LAZY) {
            _ = handle
            extLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)) — WallpaperExtensionKit loaded")
            swizzleSnapshotEncodeIfNeeded()
            Self.recordLaunchBundleFingerprint()
            VideoLibrary.shared.scan()
            WallpaperPrefs.shared.observeChanges()
            observeLibraryChanges()
            observeAppTermination()
            observeDisplaySleepWake()
            observeScreenLockState()
            PowerMonitor.shared.startMonitoring()
            observePowerStateChanges()
            observeSocketCommands()
            observeSocketCommandNotifications()
            observeExtensionReload()
            Self.reconcileHostApplicationPresence()
        } else {
            let err = String(cString: dlerror())
            extLog("INIT — dlopen failed: \(err)")
        }
    }

    private func observeAppTermination() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                WaifuXWallpaperExtension.transitionToSelfHostedPlayback(
                    reason: "appWillTerminate"
                )
            },
            "com.waifux.app.wallpaper.appWillTerminate" as CFString,
            nil,
            .deliverImmediately
        )
    }

    private static func transitionToSelfHostedPlayback(reason: String) {
        FrameChannel.shared.stop()
        WallpaperPrefs.shared.markAppHostTerminated()

        // WallpaperAgent can leave the covered desktop instance in `idle`.
        // Once the App-owned overlay is gone, that stale mode must not keep the
        // extension frozen. Future WallpaperAgent updates remain authoritative.
        let state = WallpaperState.shared
        if !state.isScreenLocked, !state.isDisplayAsleep {
            state.presentationMode = "active"
            state.activityState = "active"
        }

        recomputeAndApplyPolicy()
        extLog(
            "[Extension] Host unavailable (\(reason)); kept "
                + "\(state.activeContextCount) context(s) and enabled self-hosted desktop playback"
        )
    }

    private static func reconcileHostApplicationPresence() {
        let isRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: hostAppBundleIdentifier
        ).isEmpty
        let prefs = WallpaperPrefs.shared
        guard prefs.setAppHostRunning(isRunning) else { return }

        if isRunning {
            recomputeAndApplyPolicy()
            extLog("[Extension] Host App detected; restored App-managed playback policy")
        } else {
            transitionToSelfHostedPlayback(reason: "hostProcessMissing")
        }
    }

    /// 监听 App 重启时的扩展重载通知。
    /// App 更新（bundle 变化）后旧扩展进程退出，macOS WallpaperAgent 从新 bundle 重新加载。
    ///
    /// ⚠️ macOS 27 陷阱：扩展 exit 后 WallpaperAgent 可能长时间不重新拉载（实测 ≥30 分钟），
    /// 期间锁屏实例假死。而 Host 曾在每次启动时无条件广播本通知（现已在 Host 侧改为
    /// 仅 bundle 变化时发送），因此这里再做一道自检：磁盘 bundle 与本进程启动时一致
    /// 说明没有新二进制要换，直接忽略通知，绝不自杀。
    private func observeExtensionReload() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                guard WaifuXWallpaperExtension.shouldExitForBundleSwap() else {
                    extLog("[Extension] Reload ignored — bundle unchanged since launch (no new binary to swap)")
                    return
                }
                extLog("[Extension] Reload requested by app — exiting to allow new version to load")
                FrameChannel.shared.stop()
                let removed = WallpaperState.shared.removeAllContexts()
                WallpaperPrefs.shared.setActive(false)
                extLog("[Extension] Released \(removed.count) active context(s), exiting")
                exit(0)
            },
            "com.waifux.app.wallpaper.extensionReload" as CFString,
            nil,
            .deliverImmediately
        )
        extLog("[Extension] Reload notification observer registered")
    }

    // MARK: - Bundle Fingerprint（reload 自检）

    private static let launchBundleFingerprint = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// 计算扩展自身 bundle 的指纹（版本 + 构建 + 可执行文件大小/mtime）。
    /// 与 Host 侧 WallpaperExtensionSocketServer.embeddedExtensionBundleFingerprint() 同构。
    private static func currentBundleFingerprint() -> String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        var execPart = "noexec"
        if let execURL = Bundle.main.executableURL,
           let values = try? execURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            let mtime = Int64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970)
            execPart = "\(values.fileSize ?? 0)-\(mtime)"
        }
        return "v\(version)-b\(build)-\(execPart)"
    }

    private static func recordLaunchBundleFingerprint() {
        let fingerprint = currentBundleFingerprint()
        launchBundleFingerprint.withLock { $0 = fingerprint }
        extLog("[Extension] Bundle fingerprint at launch: \(fingerprint)")
    }

    /// 收到 reload 通知时判断是否真的有新二进制要换：
    /// 磁盘 bundle 与本进程启动时一致 → 无需换（忽略通知，保持存活）。
    /// 指纹未记录（异常路径）→ 保持旧行为（退出），宁可多杀不可不换。
    private static func shouldExitForBundleSwap() -> Bool {
        let atLaunch = launchBundleFingerprint.withLock { $0 }
        guard let atLaunch else { return true }
        let onDisk = currentBundleFingerprint()
        if atLaunch != onDisk {
            extLog("[Extension] Bundle changed since launch: \(atLaunch) → \(onDisk); honoring reload")
            return true
        }
        return false
    }

    // MARK: - SnapshotXPC Swizzle

    private func swizzleSnapshotEncodeIfNeeded() {
        guard let snapshotClass = NSClassFromString("WallpaperSnapshotXPC") else { return }
        let sel = NSSelectorFromString("encodeWithCoder:")
        guard let origMethod = class_getInstanceMethod(snapshotClass, sel) else { return }
        let origIMP = method_getImplementation(origMethod)
        typealias EncodeFunc = @convention(c) (AnyObject, Selector, NSCoder) -> Void
        let origFunc = unsafeBitCast(origIMP, to: EncodeFunc.self)
        guard let nsxpcCoderClass = NSClassFromString("NSXPCCoder") else { return }

        let block: @convention(block) (AnyObject, NSCoder) -> Void = { obj, coder in
            let origClass: AnyClass = object_getClass(coder)!
            object_setClass(coder, nsxpcCoderClass)
            origFunc(obj, sel, coder)
            object_setClass(coder, origClass)
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(origMethod, newIMP)
        extLog("  [Swizzle] Patched WallpaperSnapshotXPC encodeWithCoder:")
    }

    // MARK: - Display Sleep/Wake

    private func observeDisplaySleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { _ in
            Self.handleDisplaySleep(source: "screensDidSleep")
        }
        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { _ in
            Self.handleDisplaySleep(source: "willSleep")
        }
        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { _ in
            Self.handleDisplayWake(source: "screensDidWake")
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            Self.handleDisplayWake(source: "didWake")
        }
    }

    private static func nextWakeRecoveryGeneration() -> Int {
        wakeRecoveryGeneration.withLock { generation in
            generation &+= 1
            return generation
        }
    }

    private static func isCurrentWakeRecoveryGeneration(_ generation: Int) -> Bool {
        wakeRecoveryGeneration.withLock { $0 == generation }
    }

    private static func handleDisplaySleep(source: String) {
        _ = nextWakeRecoveryGeneration()
        WallpaperState.shared.isDisplayAsleep = true
        WallpaperState.shared.forEachRenderer { $0.applyPolicy(.paused) }
        extLog("[Extension] Display sleep (\(source)) — paused all renderers")
    }

    /// 合盖后的完整系统唤醒不保证发送 `screensDidWakeNotification`。
    /// 两类唤醒通知都走这里；第一次立即恢复，随后再补两次，覆盖显示器、背光和
    /// VideoToolbox 在不同阶段恢复的时序。
    private static func handleDisplayWake(source: String) {
        let generation = nextWakeRecoveryGeneration()
        WallpaperState.shared.isDisplayAsleep = false

        recoverRenderersAfterDisplayWake(source: source, generation: generation)
        for delay in [0.75, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard isCurrentWakeRecoveryGeneration(generation) else { return }
                recoverRenderersAfterDisplayWake(
                    source: "\(source)+\(String(format: "%.2f", delay))s",
                    generation: generation
                )
            }
        }
    }

    private static func recoverRenderersAfterDisplayWake(source: String, generation: Int) {
        guard isCurrentWakeRecoveryGeneration(generation) else { return }
        PowerMonitor.shared.refreshNow()
        WallpaperState.shared.forEachRenderer { $0.recoverFromDisplayWake() }
        remountRemoteLayersAfterWake(source: source)
        WallpaperXPCHandler.invalidateSnapshotsAfterWake()
        Self.recomputeAndApplyPolicy()
        extLog("[Extension] Display wake (\(source)) — refreshed power state and recovered renderers")
    }

    /// 唤醒后远端 CAContext 的 layer 挂载可能被 WindowServer 回收（解码管线正常但画面黑屏）。
    /// 参考 Mirage：把 rootLayer 重新赋给 caContext.layer 并 flush，让远程合成树重新指向本进程图层。
    /// 必须在主线程调用（NSWorkspace 通知队列即为 .main，补做路径也经 main.asyncAfter）。
    private static func remountRemoteLayersAfterWake(source: String) {
        let contexts = WallpaperState.shared.activeContextsSnapshot()
        guard !contexts.isEmpty else { return }
        var remounted = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for context in contexts {
            guard let caContext = context.caContext as? CAContext else { continue }
            caContext.layer = context.rootLayer
            remounted += 1
        }
        CATransaction.commit()
        CATransaction.flush()
        if remounted > 0 {
            extLog("[Extension] Wake (\(source)) — remounted \(remounted) remote CAContext layer(s)")
        }
    }

    // MARK: - Screen Lock

    private func observeScreenLockState() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isScreenLocked = true
            extLog("[Extension] Screen locked")
        }
        dnc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isScreenLocked = false
            Self.recomputeAndApplyPolicy()
            extLog("[Extension] Screen unlocked — recomputed policy")
        }
    }

    // MARK: - Power State Changes

    /// 监听电源状态变化（热状态、电池、亮度）并重新计算播放策略
    private func observePowerStateChanges() {
        Task {
            for await _ in PowerMonitor.shared.stateChanges() {
                WaifuXWallpaperExtension.recomputeAndApplyPolicy()
            }
        }
    }

    // MARK: - Socket Command Polling

    /// 定期轮询 App 的挂起命令（如 switch_video），实现 App 主动推送切换壁纸。
    /// 用户只需在系统设置初始化选择一次，之后 App 通过 socket 控制。
    ///
    /// ⚠️ 必须 dispatch 到后台队列执行，因为 drainPendingSocketCommands 内部使用同步 socket I/O，
    /// 在主线程执行会阻塞 run loop，影响 XPC 回调响应和 CACommit 等关键事件的处理。
    private func observeSocketCommands() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            WaifuXWallpaperExtension.reconcileHostApplicationPresence()
            wallpaperCommandQueue.async {
                Self.drainPendingSocketCommands(reason: "timer")
            }
        }
        extLog("[Extension] Socket command polling started (background dispatch)")
    }

    private func observeSocketCommandNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                // ⚠️ 必须走后台串行队列：drainPendingSocketCommands 内部是同步 socket I/O，
                // 在主线程执行会阻塞 run loop（见 commandQueue 注释），曾被系统判定无响应而重启扩展。
                wallpaperCommandQueue.async {
                    WaifuXWallpaperExtension.drainPendingSocketCommands(reason: "commandsChanged")
                }
            },
            "com.waifux.app.wallpaper.commandsChanged" as CFString,
            nil,
            .deliverImmediately
        )
        extLog("[Extension] Socket command notification observer started")
    }

    static func drainPendingSocketCommands(reason: String) {
        var handledCount = 0
        for _ in 0..<16 {
            guard pollAndHandleSocketCommand() else { break }
            handledCount += 1
        }
        if handledCount > 0 {
            extLog("[Commands] Drained \(handledCount) pending command(s), reason=\(reason)")
        }
    }

    @discardableResult
    private static func pollAndHandleSocketCommand() -> Bool {
        guard let socketPath = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app")?
            .appendingPathComponent("socket/extension.ipc").path
        else { return false }

        let req = IPCRequest(id: UUID().uuidString, method: "poll_commands", params: nil)
        guard let data = try? JSONEncoder().encode(req) else { return false }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var noSigPipe: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            Darwin.strncpy(&addr.sun_path.0, src, MemoryLayout.size(ofValue: addr.sun_path))
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafeMutablePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, len) } }) == 0 else { return false }

        var reqLen = UInt32(data.count).bigEndian
        guard write(sock, &reqLen, 4) == 4 else { return false }
        guard data.withUnsafeBytes({ write(sock, $0.baseAddress!, data.count) }) == data.count else { return false }

        var respLen: UInt32 = 0
        guard read(sock, &respLen, 4) == 4 else { return false }
        let payloadLen = Int(UInt32(bigEndian: respLen))
        guard payloadLen > 0, payloadLen < 10_000 else { return false }

        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: payloadLen, alignment: 1)
        defer { buf.deallocate() }
        var total = 0
        while total < payloadLen {
            let n = read(sock, buf.baseAddress! + total, payloadLen - total)
            guard n > 0 else { return false }
            total += n
        }

        let respData = Data(bytes: buf.baseAddress!, count: payloadLen)
        guard let resp = try? JSONDecoder().decode(IPCResponse.self, from: respData),
              let cmdJSON = resp.videoPath,
              let cmdData = cmdJSON.data(using: .utf8),
              let cmd = try? JSONDecoder().decode(IPCCommand.self, from: cmdData) else {
            return false
        }

        handleSocketCommand(cmd)
        return true
    }

    private static func handleSocketCommand(_ cmd: IPCCommand) {
        if cmd.action == "switch_video", let videoID = cmd.videoID, let displayID = cmd.displayID {
            extLog("[Commands] Socket switch_video: display=\(displayID) video=\(videoID)")
            if let path = UnixSocketClient.shared.fetchVideoPathSync(for: videoID) {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) {
                    // 多显示器：按 displayID 写各自一格缓存，避免覆盖其它屏的缓存。
                    WallpaperState.shared.setCachedVideoURL(url, for: displayID)
                    WallpaperState.shared.removeIOSurfaceRenderer(for: displayID)
                    FrameChannel.shared.unregisterCallback(displayID: displayID)

                    // macOS 桌面实例和锁屏实例共享 displayID 但各自有独立 context，
                    // 必须遍历所有匹配的 context 进行热切换，否则其中一个会停留在旧视频内容。
                    let allContexts = WallpaperState.shared.allActiveContexts(for: displayID)

                    if allContexts.isEmpty {
                        // 无活跃上下文（扩展刚重启），缓存视频等待 acquire 后自动应用
                        WallpaperState.shared.setPendingVideo(url, for: displayID)
                        extLog("[Commands] ⏳ 无活跃上下文 display=\(displayID)，已缓存待处理视频: \(videoID)")
                        return
                    }

                    // Advance every context's generation before choosing a path.
                    // A preceding image command may still be queued on main; it
                    // must not overwrite this newer video command when it runs.
                    let replacements = allContexts.compactMap {
                        WallpaperState.shared.beginRendererReplacement(contextId: $0.contextId, expectedRootLayer: $0.rootLayer)
                    }
                    // Path A: 有 renderer 的 context → 热切换视频
                    let contextsWithRenderer = replacements.filter { $0.context.renderer != nil }
                    if !contextsWithRenderer.isEmpty {
                        for replacement in contextsWithRenderer {
                            let active = replacement.context
                            defer { WallpaperState.shared.finishSetupTask(contextId: active.contextId, generation: replacement.generation) }
                            guard let renderer = active.renderer else { continue }
                            guard WallpaperState.shared.commitRenderer(contextId: active.contextId,
                                generation: replacement.generation, renderer: renderer, videoID: videoID).committed else { continue }
                            renderer.replaceVideo(with: url)
                            WallpaperXPCHandler.writeSnapshotCacheIfPossible(videoURL: url, videoID: videoID, displayID: displayID, rootLayer: active.rootLayer)
                        }
                        // 所有 context 更新完后统一写一次状态文件 + Darwin 通知，避免循环内重复 IO
                        WallpaperPrefs.shared.updateCurrentVideo()
                        extLog("[Commands] ✅ 已热切换显示器 \(displayID) 到视频: \(videoID) (\(contextsWithRenderer.count) 个 context)")
                    }

                    // Path B: 无 renderer 的 context（之前是静态图模式）→ 创建新的视频 renderer
                    let contextsWithoutRenderer = replacements.filter { $0.context.renderer == nil }
                    if !contextsWithoutRenderer.isEmpty {
                        // per-displayID 全局清理只在循环外做一次：IOSurface 渲染器和 FrameChannel
                        // 回调都是按 displayID 共享的，桌面+锁屏两个 context 各自 dispatch 一次
                        // 会重复清理同一份资源（race + 多余 stop）。
                        WallpaperState.shared.removeIOSurfaceRenderer(for: displayID)
                        FrameChannel.shared.unregisterCallback(displayID: displayID)
                    }
                    for replacement in contextsWithoutRenderer {
                        let active = replacement.context
                        // handleSocketCommand 在 wallpaperCommandQueue（后台串行队列）上调用，
                        // rootLayer 修改需要派发到主线程（@MainActor Task 已处理）。
                        let rootLayer = replacement.context.rootLayer
                        // ⚠️ 必须 @MainActor：AVSampleBufferDisplayLayer 的创建和添加到 rootLayer
                        // 需要在主线程执行，否则视频不会动画（displayLayer 无帧输出）。
                        let task = Task { @MainActor in
                            defer { WallpaperState.shared.finishSetupTask(contextId: active.contextId, generation: replacement.generation) }
                            guard !Task.isCancelled, WallpaperState.shared.isContextSetupCurrent(contextId: active.contextId, generation: replacement.generation) else { return }
                            do {
                                let renderer = try await VideoRenderer.create(rootLayer: rootLayer, videoURL: url, displayID: displayID)
                                guard !Task.isCancelled else { renderer.stop(); return }
                                let committed = WallpaperState.shared.commitRenderer(
                                    contextId: active.contextId,
                                    generation: replacement.generation,
                                    renderer: renderer,
                                    videoID: videoID
                                )
                                guard committed.committed else { renderer.stop(); return }
                                committed.previous?.stop()
                                rootLayer.contents = nil
                                renderer.start()
                                // 应用当前 policy（锁屏 / userPaused / display paused / 热限频等）。
                                // 否则新建 renderer 会在暂停状态下也满速跑，直到下次 update() 才被拉回。
                                Self.recomputeAndApplyPolicy()
                                WallpaperPrefs.shared.updateCurrentVideo()
                                WallpaperXPCHandler.writeSnapshotCacheIfPossible(videoURL: url, videoID: videoID, displayID: displayID, rootLayer: rootLayer)
                                extLog("[Commands] ✅ 已从静态图切回视频: display=\(displayID) video=\(videoID)")
                            } catch {
                                guard !Task.isCancelled, WallpaperState.shared.isContextSetupCurrent(contextId: active.contextId, generation: replacement.generation) else { return }
                                extLog("[Commands] ❌ 从静态图切回视频失败: \(error.localizedDescription)")
                                WallpaperPrefs.shared.reportError("switch_video 失败: \(error.localizedDescription)")
                                // 恢复：尝试加载缓存快照作为兜底内容，避免永久黑屏
                                if rootLayer.sublayers?.isEmpty ?? true {
                                    if let cachedImage = loadCachedSnapshotImage() {
                                        CATransaction.begin()
                                        CATransaction.setDisableActions(true)
                                        rootLayer.contents = cachedImage
                                        rootLayer.contentsGravity = .resizeAspectFill
                                        CATransaction.commit()
                                        extLog("[Commands] ✅ 已恢复缓存快照作为 fallback display=\(displayID)")
                                    } else if let systemImage = SystemFallbackImage.image() {
                                        CATransaction.begin()
                                        CATransaction.setDisableActions(true)
                                        rootLayer.contents = systemImage
                                        rootLayer.contentsGravity = .resizeAspectFill
                                        CATransaction.commit()
                                        extLog("[Commands] ✅ 无缓存快照，已挂系统桌面图兜底 display=\(displayID)")
                                    } else {
                                        extLog("[Commands] ⚠️ 无缓存快照可用，rootLayer 将保持空载 display=\(displayID)")
                                    }
                                }
                            }
                        }
                        WallpaperState.shared.retainSetupTask(task, contextId: active.contextId, generation: replacement.generation)
                    }
                }
            }
        } else if cmd.action == "switch_image", let sourceID = cmd.videoID, let displayID = cmd.displayID {
            extLog("[Commands] Socket switch_image: display=\(displayID) source=\(sourceID)")
            if let path = UnixSocketClient.shared.fetchVideoPathSync(for: sourceID) {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) {
                    // 多显示器：按 displayID 写各自一格缓存，避免覆盖其它屏的缓存。
                    WallpaperState.shared.setCachedImageURL(url, for: displayID)
                    WallpaperXPCHandler.switchActiveContextToStaticImage(displayID: displayID, sourceID: sourceID, imageURL: url)
                }
            }
        }
    }

    // MARK: - Library Changes

    private func observeLibraryChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                // 注意：App 侧的 prefsChanged 通知是混用的（库变化 + prefs 变化共用同一通知）。
                // 历史实现这里直接 `VideoLibrary.shared.scan()` —— 用户每次按"暂停"都会通过 socket
                // 拉取整个视频库，性能严重浪费。
                //
                // 现在 acquire 的 fallback 路径全部走 prefs JSON（prefsVideoURL / prefsImageURL），
                // 不再依赖 in-memory 视频库；VideoLibrary 仅为 findVideoURL/findImageURL 等少量
                // fallback 路径服务，启动时扫一次即可。如有真实库变化导致缓存失效，
                // clearCaches() + 共享容器目录扫描会即时反映。
                WallpaperState.shared.clearCaches()
                WallpaperXPCHandler.refreshActiveCropLayouts()
                // 电池暂停开关与电源切换共用这条通知；即使 prefs 内容未变（forceNotify），
                // 也要刷新电源状态并重算策略，否则要等 30s 兜底轮询才生效。
                WallpaperPrefs.shared.refreshPlaybackPolicy()
                // 与 commandsChanged 路径共用同一串行后台队列，避免并发 drain 竞争，
                // 且不阻塞主线程。
                wallpaperCommandQueue.async {
                    WaifuXWallpaperExtension.drainPendingSocketCommands(reason: "prefsChanged")
                }
            },
            "com.waifux.app.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// 重新计算播放策略并应用到所有渲染器。
    /// 处理锁屏时的竞争条件：当屏幕已锁定但 WallpaperAgent 尚未更新 presentationMode 时，
    /// 使用 "locked" 防止陈旧的桌面模式策略阻止锁屏播放。
    ///
    /// Per-display awareness：检查每个显示器是否有独立的暂停设置，
    /// 避免全局 policy 覆盖用户对某一显示器的单独暂停。
    static func recomputeAndApplyPolicy() {
        let state = WallpaperState.shared
        let prefs = WallpaperPrefs.shared
        let power = PowerMonitor.shared.currentState

        let effectiveMode: String
        let effectiveActivity: String
        if prefs.isAppHostTerminated && !state.isScreenLocked && !state.isDisplayAsleep {
            effectiveMode = "active"
            effectiveActivity = "active"
        } else {
            effectiveMode = PlaybackPolicy.effectivePresentationMode(
                agentMode: state.presentationMode,
                isScreenLocked: state.isScreenLocked,
                hostUnavailable: false
            )
            effectiveActivity = state.activityState
        }

        let basePolicy = PlaybackPolicy.compute(
            presentationMode: effectiveMode,
            activityState: effectiveActivity,
            userPaused: prefs.userPaused,
            alwaysPauseDesktop: prefs.effectiveAlwaysPauseDesktop,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            powerState: power,
            pauseOnBattery: prefs.pauseOnBattery
        )

        // Per-display policy：检查每个显示器是否有独立的暂停设置
        let displayIDs = state.uniqueDisplayIDs()
        if displayIDs.isEmpty {
            // 无 per-display 信息（向后兼容），全局应用
            state.forEachRenderer { renderer in
                renderer.applyPolicy(basePolicy)
            }
        } else {
            for displayID in displayIDs {
                let isDisplayPaused = prefs.isDisplayPaused(displayID)
                let effectivePolicy: PlaybackPolicy = isDisplayPaused ? .paused : basePolicy
                state.forRenderers(displayID: displayID) { renderer in
                    renderer.applyPolicy(effectivePolicy)
                }
            }
        }
    }
}

// MARK: - Logging

private var extLogFileURL: URL {
    if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") {
        return container.appendingPathComponent("waifux-extension.log")
    }
    return URL(fileURLWithPath: "/tmp/waifux-extension.log")
}

/// 扩展日志文件存储：O_APPEND 原子追加 + 大小上限 + 同 inode 保尾截断。
///
/// 为什么不用 `FileHandle` + rename 轮转：扩展可能同时有多个实例写同一文件，
/// rename 会让其它实例持有的 fd 指向已 unlink 的孤儿 inode，日志整段丢失。
/// 这里始终 open→write→close，截断用 `flock` 互斥 + `ftruncate` 原地保尾，
/// 最坏情况只是尾部少量行交错，不会静默丢掉整个进程的日志。
private enum ExtensionLogStore {
    /// 超过该大小触发截断（1MB）
    static let maxBytes: Int64 = 1_000_000
    /// 截断时保留尾部字节数（256KB）
    static let keepBytes: Int64 = 256 * 1024
    /// 每 N 次追加才 fstat 一次，避免高频日志在热路径上反复 syscall
    static let checkEvery: UInt64 = 64

    static let writeCounter = OSAllocatedUnfairLock(initialState: UInt64(0))

    static func append(_ message: String) {
        let path = extLogFileURL.path
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }

        let count = writeCounter.withLock { value -> UInt64 in
            value &+= 1
            return value
        }
        if count % checkEvery == 0 {
            trimIfNeeded(fd: fd, path: path)
        }
        data.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, data.count)
        }
    }

    private static func trimIfNeeded(fd: Int32, path: String) {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > maxBytes else { return }

        // 跨进程互斥：只锁截断窗口，追加仍由 O_APPEND 保证原子性。
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }

        guard fstat(fd, &info) == 0, info.st_size > maxBytes else { return }
        let readStart = Int64(info.st_size) - keepBytes

        let readFD = open(path, O_RDONLY)
        guard readFD >= 0 else { return }
        defer { close(readFD) }
        guard lseek(readFD, readStart, SEEK_SET) >= 0 else { return }

        var tail = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while tail.count < Int(keepBytes) {
            let n = read(readFD, &buffer, buffer.count)
            guard n > 0 else { break }
            tail.append(contentsOf: buffer[0..<n])
        }

        // 从最近的换行之后开始保留：避免截出半个 UTF-8 汉字或半行。
        guard var start = tail.firstIndex(of: 0x0A) else { return }
        start = tail.index(after: start)
        var attempts = 0
        while start < tail.endIndex,
              String(data: Data(tail[start...]), encoding: .utf8) == nil,
              attempts < 4 {
            guard let next = tail[start...].firstIndex(of: 0x0A) else { return }
            start = tail.index(after: next)
            attempts += 1
        }
        guard start < tail.endIndex else { return }

        let header = "\n--- LOG TRUNCATED \(ISO8601DateFormatter().string(from: Date())) ---\n"
        var output = Data(header.utf8)
        output.append(contentsOf: tail[start...])

        guard ftruncate(fd, 0) == 0 else { return }
        output.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, output.count)
        }
    }
}

/// 节流表：固定 key（枚举式）在时间窗内只输出一次。
/// 超过容量时先清理 5 分钟前的过期项，仍超出则只保留最近 64 个 key，
/// 避免动态 key 把表撑爆；节流只影响日志频率，不影响功能状态。
private let extLogThrottleLock = OSAllocatedUnfairLock(initialState: [String: Date]())

func extLogThrottled(key: String, interval: TimeInterval, _ message: @autoclosure () -> String) {
    let now = Date()
    let shouldLog = extLogThrottleLock.withLock { table -> Bool in
        if let last = table[key], now.timeIntervalSince(last) < interval {
            return false
        }
        if table.count >= 256 {
            let cutoff = now.addingTimeInterval(-300)
            table = table.filter { $0.value > cutoff }
            if table.count >= 256 {
                let newest = table.sorted { $0.value < $1.value }.suffix(64)
                table = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
            }
        }
        table[key] = now
        return true
    }
    guard shouldLog else { return }
    extLog(message())
}

private struct ExtLogAggregate {
    var windowStart: Date
    var count: Int
    var lastMessage: String
}

private let extLogAggregateLock = OSAllocatedUnfairLock(initialState: [String: ExtLogAggregate]())

/// 窗口聚合：高频状态日志按窗口计数，到期后输出「×N + 最近一条」。
/// 用于 layout updated / updateCurrentVideo 这类可能振荡的信号：既能观察频率，
/// 又不会每条都写文件。
func extLogAggregated(key: String, interval: TimeInterval = 60, _ message: @autoclosure () -> String) {
    let now = Date()
    let text = message()
    let flush: String? = extLogAggregateLock.withLock { table -> String? in
        if var entry = table[key] {
            entry.count += 1
            entry.lastMessage = text
            if now.timeIntervalSince(entry.windowStart) >= interval {
                let elapsed = Int(now.timeIntervalSince(entry.windowStart))
                table[key] = ExtLogAggregate(windowStart: now, count: 0, lastMessage: text)
                return "\(key) ×\(entry.count) in \(elapsed)s | last: \(text)"
            }
            table[key] = entry
            return nil
        }
        table[key] = ExtLogAggregate(windowStart: now, count: 0, lastMessage: text)
        return text
    }
    if let flush { extLog(flush) }
}

func extLog(_ message: String) {
    if #available(macOS 11.0, *) {
        os_log("[WaifuXExt] %{public}@", log: .default, type: .info, message)
    } else {
        print("[WaifuXExt] \(message)")
    }
    ExtensionLogStore.append(message)
}
