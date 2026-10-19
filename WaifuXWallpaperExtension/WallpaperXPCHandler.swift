//  XPC handler implementing WallpaperExtensionXPCProtocol

import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import os
import QuartzCore

extension CALayer: @unchecked @retroactive Sendable {}
extension CAContext: @unchecked @retroactive Sendable {}

/// Darwin notifications do not retain their observer context. Keep the C callback
/// bound to this process-lifetime object and retain XPC handlers only while dispatching.
private final class WallpaperPrefsChangeObserver: @unchecked Sendable {
    private final class WeakHandler {
        weak var value: WallpaperXPCHandler?

        init(_ value: WallpaperXPCHandler) {
            self.value = value
        }
    }

    static let shared = WallpaperPrefsChangeObserver()

    private let lock = NSLock()
    private var handlers: [ObjectIdentifier: WeakHandler] = [:]
    private var isRegistered = false

    private init() {}

    func register(_ handler: WallpaperXPCHandler) {
        let shouldRegister: Bool
        lock.lock()
        handlers = handlers.filter { $0.value.value != nil }
        handlers[ObjectIdentifier(handler)] = WeakHandler(handler)
        shouldRegister = !isRegistered
        isRegistered = true
        lock.unlock()

        guard shouldRegister else { return }

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let dispatcher = Unmanaged<WallpaperPrefsChangeObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                dispatcher.dispatchPrefsChanged()
            },
            "com.waifux.app.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately
        )
    }

    func unregister(_ handler: WallpaperXPCHandler) {
        lock.lock()
        handlers.removeValue(forKey: ObjectIdentifier(handler))
        lock.unlock()
    }

    /// 对当前存活的 handler 执行闭包（XPC 连接失效后 weak 引用自然消失）。
    /// 供唤醒恢复等进程级事件触达所有活跃连接的 agentProxy。
    func withLiveHandlers(_ body: (WallpaperXPCHandler) -> Void) {
        lock.lock()
        let activeHandlers = handlers.values.compactMap(\.value)
        lock.unlock()
        activeHandlers.forEach(body)
    }

    private func dispatchPrefsChanged() {
        lock.lock()
        let activeHandlers = handlers.values.compactMap(\.value)
        handlers = handlers.filter { $0.value.value != nil }
        lock.unlock()

        activeHandlers.forEach { $0.handlePrefsChanged() }
    }
}

final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)?
    /// Contexts acquired through this XPC connection. WallpaperAgent can keep
    /// separate connections for desktop/lock-screen instances and displays, so
    /// an invalidated connection must not tear down contexts owned by others.
    private let ownedContextLock = NSLock()
    private var ownedContexts: [UInt32: UInt64] = [:]
    private var connectionInvalidated = false
    private var previousPresentationMode = "default"
    /// 上次收到 presentationMode == "locked" 的时间。用于防止 screenIsUnlocked
    /// DistributedNotification 偶发丢失导致 isScreenLocked 永久卡死。
    private var lastLockedUpdate: Date = .distantPast

    /// 本连接是否服务过至少一个 XPC 方法。SpiralRecovery 用它区分
    /// 「agent 空转的空连接」与「服务过方法的正常断开」。
    private let servedStateLock = NSLock()
    private var _servedAnyMethod = false
    var servedAnyMethod: Bool {
        servedStateLock.lock()
        defer { servedStateLock.unlock() }
        return _servedAnyMethod
    }

    /// XPC 方法入口统一打点：标记本连接健康 + 清零空连接螺旋计数。
    func noteServed() {
        servedStateLock.lock()
        _servedAnyMethod = true
        servedStateLock.unlock()
        SpiralRecovery.noteHealthyConnection()
    }

    private func beginOwnedContext(_ context: ActiveWallpaper) -> UInt64? {
        ownedContextLock.lock()
        defer { ownedContextLock.unlock() }
        guard !connectionInvalidated else { return nil }
        let generation = WallpaperState.shared.beginContextSetup(context)
        ownedContexts[context.contextId] = generation
        return generation
    }

    func forgetOwnedContexts(_ contextIDs: Set<UInt32>) {
        guard !contextIDs.isEmpty else { return }
        ownedContextLock.lock()
        for id in contextIDs { ownedContexts.removeValue(forKey: id) }
        ownedContextLock.unlock()
    }

    func takeOwnedContexts() -> [UInt32: UInt64] {
        ownedContextLock.lock()
        defer { ownedContextLock.unlock() }
        let contexts = ownedContexts
        connectionInvalidated = true
        ownedContexts.removeAll()
        return contexts
    }

    private static func extractWallpaperContextIdentifier(from object: Any?) -> String? {
        guard let object else { return nil }

        func normalizedIdentifier(from raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "nil" else { return nil }

            if let range = trimmed.range(
                of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                options: .regularExpression
            ) {
                return "uuid:\(trimmed[range].lowercased())"
            }

            if !trimmed.contains("0x") {
                return "raw:\(trimmed)"
            }

            return nil
        }

        if let string = object as? String, let normalized = normalizedIdentifier(from: string) {
            return normalized
        }
        if let string = object as? NSString, let normalized = normalizedIdentifier(from: string as String) {
            return normalized
        }
        if let uuid = object as? UUID {
            return "uuid:\(uuid.uuidString.lowercased())"
        }

        let mirror = Mirror(reflecting: object)
        for child in mirror.children {
            if let string = child.value as? String, let normalized = normalizedIdentifier(from: string) {
                return normalized
            }
            if let string = child.value as? NSString, let normalized = normalizedIdentifier(from: string as String) {
                return normalized
            }
            if let uuid = child.value as? UUID {
                return "uuid:\(uuid.uuidString.lowercased())"
            }

            let childDescription = String(describing: child.value)
            if let normalized = normalizedIdentifier(from: childDescription) {
                return normalized
            }
        }

        return normalizedIdentifier(from: String(describing: object))
    }

    private static func displayMetrics(for displayID: UInt32) -> (size: CGSize, scale: CGFloat)? {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  screenNumber.uint32Value == displayID else {
                continue
            }
            return (screen.frame.size, screen.backingScaleFactor)
        }

        let cgDisplayID = CGDirectDisplayID(displayID)
        let bounds = CGDisplayBounds(cgDisplayID)
        guard bounds.width > 0, bounds.height > 0 else {
            let pixelWidth = CGDisplayPixelsWide(cgDisplayID)
            let pixelHeight = CGDisplayPixelsHigh(cgDisplayID)
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }
            return (CGSize(width: pixelWidth, height: pixelHeight), 1.0)
        }
        return (bounds.size, 1.0)
    }

    private static func requestDisplayGeometry(from request: Any?) -> (displayID: UInt32?, size: CGSize?, scale: CGFloat?) {
        var descriptions: [String] = []

        func collectDescriptions(_ value: Any, depth: Int) {
            guard depth < 3, descriptions.count < 24 else { return }
            descriptions.append(String(describing: value))
            for child in Mirror(reflecting: value).children {
                collectDescriptions(child.value, depth: depth + 1)
            }
        }

        if let request {
            collectDescriptions(request, depth: 0)
        }

        return ExtDisplayGeometry.parse(descriptions: descriptions)
    }

    private static func applyDisplayGeometryUpdate(
        wallpaperID: String?,
        displayID: UInt32?,
        size requestedSize: CGSize?,
        scale requestedScale: CGFloat?
    ) {
        let applyBlock: @Sendable () -> Void = {
            // 在主线程取得最新实例，避免排队期间静态图/视频已热切换。
            // wallpaperID 也可对应桌面 + 锁屏两个 context，不能只更新 first。
            let contexts = WallpaperState.shared.activeContextsSnapshot().filter { active in
                ExtDisplayGeometry.matches(
                    wallpaperID: wallpaperID, displayID: displayID,
                    contextWallpaperID: active.wallpaperID, contextDisplayID: active.displayID,
                    contextDisplayIsActive: active.displayID.map { CGDisplayIsActive($0) != 0 } ?? false)
            }
            let contextDisplayIDs = Set(contexts.compactMap { $0.displayID })
            let hasTarget = displayID != nil || (wallpaperID != nil && contextDisplayIDs.count == 1)
            // per-display 的 IOSurface 重分配只做一次（surface 是按 display 共享的）
            var reallocatedDisplays = Set<UInt32>()

            for active in contexts {
                let targetDisplayID = displayID ?? active.displayID
                guard let targetDisplayID else { continue }

                let metrics = Self.displayMetrics(for: targetDisplayID)
                // 无目标的 update 只能逐屏取 metrics，不能把某一屏尺寸广播到其它屏。
                let targetSize = (hasTarget ? requestedSize : nil) ?? metrics?.size ?? active.rootLayer.bounds.size
                let targetScale = (hasTarget ? requestedScale : nil) ?? metrics?.scale ?? active.rootLayer.contentsScale
                guard ExtDisplayGeometry.isValid(size: targetSize), targetScale.isFinite, targetScale > 0 else { continue }

                let oldBounds = active.rootLayer.bounds
                let oldScale = active.rootLayer.contentsScale
                let needsFrame = abs(oldBounds.width - targetSize.width) > 0.5
                    || abs(oldBounds.height - targetSize.height) > 0.5
                let needsScale = abs(oldScale - targetScale) > 0.001

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                active.rootLayer.frame = CGRect(origin: .zero, size: targetSize)
                active.rootLayer.bounds = CGRect(origin: .zero, size: targetSize)
                active.rootLayer.contentsScale = targetScale
                relayoutContent(active, displayID: targetDisplayID)

                // IOSurface 渲染器也需要重新布局，但分辨率重分配 per-display 只做一次。
                if let ioRenderer = WallpaperState.shared.ioSurfaceRenderer(for: targetDisplayID),
                   ioRenderer.displayLayer.superlayer === active.rootLayer, needsFrame || needsScale {
                    ioRenderer.relayout(rootLayer: active.rootLayer)

                    if reallocatedDisplays.insert(targetDisplayID).inserted {
                        let pixelWidth = Int(targetSize.width * targetScale)
                        let pixelHeight = Int(targetSize.height * targetScale)
                        if #available(macOS 15.0, *) {
                            if let newIDs = ioRenderer.reallocateSurfacesIfNeeded(width: pixelWidth, height: pixelHeight) {
                                Task {
                                    _ = await UnixSocketClient.shared.registerSurfaces(
                                        displayID: targetDisplayID,
                                        surfaceID0: newIDs.surfaceID0,
                                        surfaceID1: newIDs.surfaceID1,
                                        videoID: active.videoID ?? ""
                                    )
                                    extLog("[Geometry] re-registered surfaces display=\(targetDisplayID) [\(newIDs.surfaceID0), \(newIDs.surfaceID1)]")
                                }
                            }
                        }
                    }
                }

                CATransaction.commit()

                if active.displayID != targetDisplayID {
                    WallpaperState.shared.updateContextDisplayID(rootLayer: active.rootLayer, displayID: targetDisplayID)
                }

                if needsFrame || needsScale || active.displayID != targetDisplayID {
                    extLog(
                        "[Geometry] updated context=\(active.contextId) display=\(targetDisplayID) "
                            + "\(Int(oldBounds.width))x\(Int(oldBounds.height))@\(oldScale) -> "
                            + "\(Int(targetSize.width))x\(Int(targetSize.height))@\(targetScale)"
                    )
                }
            }
        }

        if Thread.isMainThread {
            applyBlock()
        } else {
            DispatchQueue.main.async(execute: applyBlock)
        }
    }

    /// 裁剪设置通知不保证 WallpaperAgent 会重新 acquire；就地刷新全部现存实例。
    /// 保留每个 context 的尺寸（系统预览可能不同于物理显示器）。
    static func refreshActiveCropLayouts() {
        let applyBlock: @Sendable () -> Void = {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for active in WallpaperState.shared.activeContextsSnapshot() {
                guard let displayID = active.displayID else { continue }
                relayoutContent(active, displayID: displayID)
            }
            CATransaction.commit()
        }
        if Thread.isMainThread { applyBlock() } else { DispatchQueue.main.async(execute: applyBlock) }
    }

    private static func relayoutContent(_ active: ActiveWallpaper, displayID: UInt32) {
        if let renderer = active.renderer {
            renderer.relayoutForCurrentDisplayGeometry(displayID: displayID)
        } else if let image = ExtCropLayers.staticImage(in: active.rootLayer) ?? ExtCropLayers.imageContents(in: active.rootLayer) {
            applyStaticCrop(rootLayer: active.rootLayer, image: image, displayID: displayID)
        }
    }

    // MARK: - Lifecycle

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        noteServed()
        extLog("=== ACQUIRE ===")

        let wallpaperIDString = Self.extractWallpaperContextIdentifier(from: id)

        // acquire/update 共用校验后的尺寸解析，失败时按目标显示器回退。
        let requestGeometry = Self.requestDisplayGeometry(from: request)
        var displayID = requestGeometry.displayID
        var destSize = requestGeometry.size ?? .zero
        var scaleFactor = requestGeometry.scale ?? 1.0
        var choiceConfiguration: String?

        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let innerValue = mirror.children.first?.value {
                let desc = String(describing: innerValue)
                _ = desc.contains("isPreview: true")
                // 尝试解析 String 格式的 configuration: Optional("display-instance-id")
                if let cRange = desc.range(of: "configuration: Optional(\""), let cEnd = desc[cRange.upperBound...].range(of: "\")") {
                    choiceConfiguration = String(desc[cRange.upperBound..<cEnd.lowerBound])
                }
                // 回退：尝试从 Data 格式的 configuration 解析（UTF-8 字节）
                if choiceConfiguration == nil {
                    if let dataRange = desc.range(of: "configuration: Optional("),
                       let bytesRange = desc[dataRange.upperBound...].range(of: "bytes = \""),
                       let endQuote = desc[bytesRange.upperBound...].range(of: "\")") {
                        let hexStr = String(desc[bytesRange.upperBound..<endQuote.lowerBound])
                        if let data = hexStr.data(using: .utf8), !data.isEmpty {
                            choiceConfiguration = String(data: data, encoding: .utf8)
                        }
                    }
                }
                // 从 Mirror 遍历提取 cacheDirectory 和 choice files（更可靠的提取方式）
                for child in mirror.children {
                    let reqMirror = Mirror(reflecting: child.value)
                    for prop in reqMirror.children {
                        if prop.label == "destination" {
                            let destMirror = Mirror(reflecting: prop.value)
                            for destProp in destMirror.children {
                                if destProp.label == "directDisplayID", let did = destProp.value as? UInt32 {
                                    displayID = did
                                } else if destProp.label == "cacheDirectory" {
                                    if let url = prop.value as? URL {
                                        WallpaperState.shared.cacheDirectoryURL = url
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // 从 descriptor 提取配置和文件
            let rawMirror = Mirror(reflecting: reqObj)
            if let rawValue = rawMirror.children.first?.value {
                let rMirror = Mirror(reflecting: rawValue)
                for prop in rMirror.children where prop.label == "descriptor" {
                    let descMirror = Mirror(reflecting: prop.value)
                    for descProp in descMirror.children {
                        if descProp.label == "configuration" {
                            if let data = descProp.value as? Data, !data.isEmpty {
                                choiceConfiguration = String(data: data, encoding: .utf8)
                            }
                        } else if descProp.label == "files" {
                            if let urls = descProp.value as? [URL] {
                                _ = urls
                            }
                        }
                    }
                }
            }
        }

        // Some request variants expose directDisplayID only in their nested
        // description. Do not infer a display from process-wide currentVideoID:
        // it belongs to whichever monitor was selected most recently.
        if displayID == nil {
            displayID = Self.requestDisplayGeometry(from: request).displayID
        }

        // 回退：如果 displayID 仍为 nil，尝试从 choiceConfiguration 提取
        // 实例 ID 格式为 "display-<number>"
        if displayID == nil, let config = choiceConfiguration,
           config.hasPrefix("display-"),
           let idStr = config.split(separator: "-").last,
           let parsed = UInt32(idStr) {
            displayID = parsed
            extLog("[acquire] ⚠️ 从 choiceConfiguration 提取 displayID: \(parsed) (config: \(config))")
        }

        // A system-wide first screen is safe only when there is exactly one.
        if displayID == nil, NSScreen.screens.count == 1 {
            if let mainScreen = NSScreen.screens.first,
               let screenNumber = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                displayID = screenNumber.uint32Value
                extLog("[acquire] ⚠️ 从 NSScreen 获取 displayID: \(displayID!)")
            }
        }
        // Last resort when AppKit cannot enumerate the sole active display.
        if displayID == nil {
            var count: UInt32 = 0
            if CGGetActiveDisplayList(0, nil, &count) == .success, count == 1 {
                var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
                if CGGetActiveDisplayList(count, &displays, &count) == .success {
                    displayID = displays[0]
                    extLog("[acquire] ⚠️ 从 CGGetActiveDisplayList 获取 displayID: \(displayID!)")
                }
            }
        }
        if displayID == nil {
            extLog("[acquire] ❌ 无法确定 displayID，无法创建渲染管线")
            reply(nil, NSError(domain: "WaifuXExtension", code: 4,
                               userInfo: [NSLocalizedDescriptionKey: "Cannot determine display ID"]))
            return
        }

        if let did = displayID, let metrics = Self.displayMetrics(for: did) {
            if requestGeometry.size == nil {
                destSize = metrics.size
                extLog("[acquire] request 无有效目标尺寸，使用 display metrics: display=\(did) size=\(destSize)")
            }
            if requestGeometry.scale == nil { scaleFactor = metrics.scale }
        }
        guard ExtDisplayGeometry.isValid(size: destSize), scaleFactor.isFinite, scaleFactor > 0 else {
            extLog("[acquire] ❌ 无有效显示尺寸 display=\(displayID ?? 0)")
            reply(nil, NSError(domain: "WaifuXExtension", code: 5,
                               userInfo: [NSLocalizedDescriptionKey: "Cannot determine display geometry"]))
            return
        }

        // Seed currentVideoID only on first launch when UserDefaults has no value yet,
        // so the menu-bar UI has something sensible to show before the user picks anything.
        // Each acquire's choiceConfiguration is authoritative for *this* display's context.
        // Do NOT mutate the process-wide currentVideoID here based on a diff — concurrent
        // acquires for different displays would race and a renderer can end up initialized
        // with the wrong monitor's video (multi-monitor bug: after one loop, all monitors
        // play the same video). The global tracks the last user-picked choice (via
        // selectedChoicesDidChange); we only seed it on first launch.
        if WallpaperState.shared.currentVideoID == nil,
           let instanceID = choiceConfiguration, !instanceID.isEmpty {
            extLog("  Seeding currentVideoID (first launch): \(instanceID)")
            WallpaperState.shared.currentVideoID = instanceID
            WallpaperPrefs.shared.updateCurrentVideo()
        }

        // Create remote CAContext
        var contextOptions: [String: Any] = [:]
        if let did = displayID {
            contextOptions["displayId"] = NSNumber(value: did)
        }
        let caContext: CAContext
        if contextOptions.isEmpty {
            guard let ctx = CAContext.remoteContext() as? CAContext else {
                reply(nil, NSError(domain: "WaifuXExtension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CAContext"]))
                return
            }
            caContext = ctx
        } else {
            let result = CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: contextOptions)?.takeUnretainedValue()
            guard let ctx = result as? CAContext else {
                reply(nil, NSError(domain: "WaifuXExtension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CAContext"]))
                return
            }
            caContext = ctx
        }
        guard caContext.contextId != 0 else {
            reply(nil, NSError(domain: "WaifuXExtension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CAContext"]))
            return
        }

        let contextId = caContext.contextId
        guard let replyObj = createRemoteContextXPC(contextId: contextId) else {
            reply(nil, NSError(domain: "WaifuXExtension", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create WallpaperRemoteContextXPC"]))
            return
        }

        nonisolated(unsafe) let unsafeReplyObj = replyObj
        let hasReplied = OSAllocatedUnfairLock(initialState: false)
        let doReply: @Sendable (String) -> Void = { source in
            let shouldReply = hasReplied.withLock { replied in
                if replied { return false }
                replied = true
                return true
            }
            if shouldReply {
                extLog("  Replying to acquire [\(source)] (contextId: \(contextId))")
                reply(unsafeReplyObj, nil)
            }
        }

        let layerFrame = CGRect(origin: .zero, size: destSize)
        let rootLayer = CALayer()
        rootLayer.frame = layerFrame
        rootLayer.contentsScale = scaleFactor
        rootLayer.contentsGravity = .resizeAspectFill
        extLog("[acquire] rootLayer size=\(Int(destSize.width))x\(Int(destSize.height)) scale=\(scaleFactor) display=\(displayID ?? 0)")

        if let cachedImage = loadCachedSnapshotImage() {
            rootLayer.contents = cachedImage
            extLog("  Set cached snapshot as initial layer content")
        } else if let systemImage = SystemFallbackImage.image() {
            // acquire 即时底图第二级：无缓存快照时先挂系统桌面图，renderer 创建后即被覆盖
            rootLayer.contents = systemImage
            extLog("  Set system desktop picture as initial layer content (no cached snapshot)")
        }

        if let did = displayID {
            let instanceID = choiceConfiguration ?? "display-\(did)"
            let placeholder = ActiveWallpaper(
                caContext: caContext, rootLayer: rootLayer, renderer: nil,
                displayID: did, videoID: instanceID, contextId: contextId,
                wallpaperID: wallpaperIDString
            )
            guard let generation = beginOwnedContext(placeholder) else {
                reply(nil, CancellationError())
                return
            }
            extLog("  Setting up display instance \(instanceID) for display \(did)")
            caContext.layer = rootLayer
            CATransaction.flush()
            doReply("context ready")

            Self.startLocalVideoFallbackTask(
                displayID: did,
                instanceID: instanceID,
                context: placeholder,
                generation: generation,
                wallpaperIDString: wallpaperIDString,
                doReply: doReply
            )

            DispatchQueue.global().asyncAfter(deadline: .now() + 15.0) {
                doReply("timeout")
            }
        } else {
            reply(nil, NSError(domain: "WaifuXExtension", code: 4,
                               userInfo: [NSLocalizedDescriptionKey: "Cannot determine display ID"]))
        }
    }

    private static func startLocalVideoFallbackTask(
        displayID: UInt32,
        instanceID: String,
        context: ActiveWallpaper,
        generation: UInt64,
        wallpaperIDString: String?,
        doReply: @escaping @Sendable (String) -> Void
    ) {
        let contextId = context.contextId
        let task = Task { @MainActor in
            defer { WallpaperState.shared.finishSetupTask(contextId: contextId, generation: generation) }
            guard !Task.isCancelled, WallpaperState.shared.isContextSetupCurrent(contextId: contextId, generation: generation) else { return }
            guard let caContext = context.caContext as? CAContext else { return }
            extLog("  [Acquire] 使用扩展本地解码 display=\(displayID)")
            await startLocalVideoFallback(
                displayID: displayID,
                instanceID: instanceID,
                rootLayer: context.rootLayer,
                caContext: caContext,
                contextId: contextId,
                generation: generation,
                wallpaperIDString: wallpaperIDString,
                doReply: doReply
            )
        }
        WallpaperState.shared.retainSetupTask(task, contextId: contextId, generation: generation)
    }

    @MainActor private static func startLocalVideoFallback(
        displayID: UInt32,
        instanceID: String,
        rootLayer: CALayer,
        caContext: CAContext,
        contextId: UInt32,
        generation: UInt64,
        wallpaperIDString: String?,
        doReply: @escaping @Sendable (String) -> Void
    ) async {
        guard !Task.isCancelled, WallpaperState.shared.isContextSetupCurrent(contextId: contextId, generation: generation) else { return }
        // 静态图和视频热切换都可能恰好落在 WallpaperAgent 重建 context 的窗口。
        // 静态图必须优先于待处理视频消费，避免旧视频命令在下一次 acquire 时反向覆盖新图片。
        // 待处理静态图可能来自旧机器/旧用户的容器路径：校验归属，失效则丢弃
        // 并继续走 prefs / findImageURL，而不是直接渲染失败退成系统桌面图。
        if let pending = WallpaperState.shared.takePendingImage(for: displayID),
           let pendingImageURL = containerOwnedImageURL(pending) {
            extLog("  [Acquire] 📦 应用待处理静态图 display=\(displayID) image=\(pendingImageURL.lastPathComponent)")
            renderStaticImage(
                imageURL: pendingImageURL,
                displayID: displayID,
                instanceID: instanceID,
                rootLayer: rootLayer,
                caContext: caContext,
                contextId: contextId,
                generation: generation,
                wallpaperIDString: wallpaperIDString,
                doReply: doReply
            )
            return
        }

        // 优先使用待处理的视频切换（扩展重启期间 switch_video 到达但无上下文时缓存的）
        if let pendingURL = WallpaperState.shared.takePendingVideo(for: displayID) {
            extLog("  [Acquire] 📦 应用待处理视频 display=\(displayID) video=\(pendingURL.lastPathComponent)")
            do {
                let renderer = try await VideoRenderer.create(rootLayer: rootLayer, videoURL: pendingURL, displayID: displayID)
                guard !Task.isCancelled else { renderer.stop(); return }
                let committed = WallpaperState.shared.commitRenderer(contextId: contextId, generation: generation, renderer: renderer, videoID: instanceID)
                guard committed.committed else { renderer.stop(); return }
                committed.previous?.stop()
                renderer.start()
                // 应用当前 policy（可能正处于锁屏 / userPaused / display paused 等暂停状态），
                // 否则新 renderer 会一直满速跑到下一次 update() 才被拉回。
                WaifuXWallpaperExtension.recomputeAndApplyPolicy()
                writeSnapshotCacheIfPossible(videoURL: pendingURL, videoID: instanceID, displayID: displayID, rootLayer: rootLayer)
                WallpaperPrefs.shared.setActive(true)
                extLog("  [Acquire] ✅ 待处理视频渲染已启动 display=\(displayID) video=\(pendingURL.lastPathComponent)")
                doReply("pending video applied")
                return
            } catch {
                guard !Task.isCancelled, WallpaperState.shared.isContextSetupCurrent(contextId: contextId, generation: generation) else { return }
                extLog("  [Acquire] ❌ 待处理视频渲染失败: \(error.localizedDescription)，回退到 prefs")
            }
        }

        // 先读取 App 写入的共享 prefs，确定上次设置的壁纸类型。
        // 多显示器场景下按 displayID 取各自的路径（per-display），
        // 没有时回退到 legacy 全局路径（向后兼容）。
        // findImageURL(sourceID:) 会通过 Socket 查 localDecodeVideoLock 中残留的旧注册，
        // 导致切换壁纸后扩展冷启动仍然渲染旧内容。直接读 prefs 才能反映 App 的最后意图。
        if let videoURL = prefsVideoURL(for: displayID) {
            do {
                let renderer = try await VideoRenderer.create(rootLayer: rootLayer, videoURL: videoURL, displayID: displayID)
                guard !Task.isCancelled else { renderer.stop(); return }
                let committed = WallpaperState.shared.commitRenderer(contextId: contextId, generation: generation, renderer: renderer, videoID: instanceID)
                guard committed.committed else { renderer.stop(); return }
                committed.previous?.stop()
                renderer.start()
                // 应用当前 policy，避免锁屏/暂停状态下新 renderer 自动播放。
                WaifuXWallpaperExtension.recomputeAndApplyPolicy()
                writeSnapshotCacheIfPossible(videoURL: videoURL, videoID: instanceID, displayID: displayID, rootLayer: rootLayer)
                WallpaperPrefs.shared.setActive(true)
                extLog("  [Acquire] ✅ 本地回退渲染已启动 display=\(displayID) video=\(videoURL.lastPathComponent)")
                doReply("local video fallback")
            } catch {
                guard !Task.isCancelled, WallpaperState.shared.isContextSetupCurrent(contextId: contextId, generation: generation) else { return }
                extLog("  [Acquire] ❌ 本地回退视频渲染失败: \(error.localizedDescription)")
                // 视频播放失败，尝试回退到 prefs 中指定的静态图
                if let imageURL = prefsImageURL(for: displayID) {
                    renderStaticImage(
                        imageURL: imageURL,
                        displayID: displayID,
                        instanceID: instanceID,
                        rootLayer: rootLayer,
                        caContext: caContext,
                        contextId: contextId,
                        generation: generation,
                        wallpaperIDString: wallpaperIDString,
                        doReply: doReply
                    )
                } else {
                    WallpaperPrefs.shared.setActive(true)
                    doReply("video failed, no image fallback")
                }
            }
            return
        }

        // prefs 中当前 displayID 的视频路径未设置 → 检查静态图
        if let imageURL = prefsImageURL(for: displayID) {
            renderStaticImage(
                imageURL: imageURL,
                displayID: displayID,
                instanceID: instanceID,
                rootLayer: rootLayer,
                caContext: caContext,
                contextId: contextId,
                generation: generation,
                wallpaperIDString: wallpaperIDString,
                doReply: doReply
            )
            return
        }

        // prefs 无有效设置 → 最后的回退：查 findImageURL（兼容旧状态）
        if let imageURL = findImageURL(sourceID: "display-\(displayID)") {
            renderStaticImage(
                imageURL: imageURL,
                displayID: displayID,
                instanceID: instanceID,
                rootLayer: rootLayer,
                caContext: caContext,
                contextId: contextId,
                generation: generation,
                wallpaperIDString: wallpaperIDString,
                doReply: doReply
            )
            return
        }

        extLog("  [Acquire] ❌ 本地回退失败：未找到可播放视频或图片")
        WallpaperPrefs.shared.setActive(true)
        doReply("fallback no resource")
    }

    /// 从共享 prefs 读取此显示器的视频；仅旧版无按屏记录时使用全局路径。
    private static func prefsVideoURL(for displayID: UInt32) -> URL? {
        struct MirroringPrefs: Decodable {
            let currentVideoPath: String?
            let currentVideoPaths: [String: String]?
            let currentImagePath: String?
            let currentImagePaths: [String: String]?
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
            return nil
        }
        let prefsURL = container.appendingPathComponent("waifux-wallpaper-prefs.json")
        guard let data = try? Data(contentsOf: prefsURL),
              let prefs = try? JSONDecoder().decode(MirroringPrefs.self, from: data) else {
            return nil
        }
        guard let path = LockScreenSourceSelection.path(
            for: .video,
            displayID: displayID,
            videoPaths: prefs.currentVideoPaths,
            imagePaths: prefs.currentImagePaths,
            legacyVideoPath: prefs.currentVideoPath,
            legacyImagePath: prefs.currentImagePath
        ) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            extLog("[prefsVideoURL] ⚠️ 视频路径不存在: display=\(displayID) path=\(path)")
            return nil
        }
        return url
    }

    /// 持久化/命令里的绝对路径可能来自旧机器或旧用户（例如
    /// /Users/<other>/Library/Group Containers/group.com.waifux.app/...）。
    /// 只有落在当前 App Group 容器内、且实际可读的路径才可用；其余交给
    /// 调用方按 sourceID 在容器里重建，避免整屏回退成系统桌面图。
    static func containerOwnedImageURL(_ url: URL) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.waifux.app"
        ) else { return nil }
        let root = container.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root),
              FileManager.default.isReadableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    /// 从共享 prefs 读取图片 URL。同 prefsVideoURL(for:)，优先 per-display 路径。
    private static func prefsImageURL(for displayID: UInt32) -> URL? {
        struct MirroringPrefs: Decodable {
            let currentVideoPath: String?
            let currentVideoPaths: [String: String]?
            let currentImagePath: String?
            let currentImagePaths: [String: String]?
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
            return nil
        }
        let prefsURL = container.appendingPathComponent("waifux-wallpaper-prefs.json")
        guard let data = try? Data(contentsOf: prefsURL),
              let prefs = try? JSONDecoder().decode(MirroringPrefs.self, from: data) else {
            return nil
        }
        guard let path = LockScreenSourceSelection.path(
            for: .image,
            displayID: displayID,
            videoPaths: prefs.currentVideoPaths,
            imagePaths: prefs.currentImagePaths,
            legacyVideoPath: prefs.currentVideoPath,
            legacyImagePath: prefs.currentImagePath
        ) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        guard let owned = containerOwnedImageURL(url) else {
            extLog("[prefsImageURL] ⚠️ 图片路径不属于当前容器或不可读: display=\(displayID) path=\(path)")
            return nil
        }
        return owned
    }

    static func writeSnapshotCacheIfPossible(videoURL: URL, videoID: String, displayID: UInt32, rootLayer: CALayer) {
        let scale = rootLayer.contentsScale > 0 ? rootLayer.contentsScale : 1
        // These dimensions identify the target display in Apple's cache filename;
        // the decoded image and actual BMP allocation use the independent budget.
        let width = rootLayer.bounds.width * scale
        let height = rootLayer.bounds.height * scale
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= 32768, height <= 32768 else { return }
        requestBMPSnapshot(
                videoURL: videoURL,
                videoID: videoID,
                displayID: displayID,
                displayPixelWidth: Int(width),
                displayPixelHeight: Int(height)
            )
    }

    @MainActor private static func renderStaticImage(
        imageURL: URL,
        displayID: UInt32,
        instanceID: String,
        rootLayer: CALayer,
        caContext: CAContext,
        contextId: UInt32,
        generation: UInt64,
        wallpaperIDString: String?,
        doReply: @escaping @Sendable (String) -> Void
    ) {
        guard !Task.isCancelled, WallpaperState.shared.isContextSetupCurrent(contextId: contextId, generation: generation) else { return }
        guard let image = loadBudgetedSnapshotImage(imageURL) else {
            extLog("  [Acquire] ❌ 静态图加载失败: \(imageURL.path)")
            WallpaperPrefs.shared.setActive(true)
            doReply("static image failed")
            return
        }

        let committed = WallpaperState.shared.commitRenderer(contextId: contextId, generation: generation, renderer: nil, videoID: instanceID)
        guard committed.committed else { return }
        committed.previous?.stop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        rootLayer.contents = image
        applyStaticCrop(rootLayer: rootLayer, image: image, displayID: displayID)
        CATransaction.commit()

        WallpaperPrefs.shared.setActive(true)
        extLog("  [Acquire] ✅ 静态图渲染已启动 display=\(displayID) image=\(imageURL.lastPathComponent)")
        doReply("static image")
    }

    /// 静态图与视频共用等比 layer 几何。contentsCenter 是九宫格拉伸区，不能当目标 viewport。
    private static func applyStaticCrop(rootLayer: CALayer, image: CGImage, displayID: UInt32) {
        let settings = ExtCropPrefs.settings(forDisplayID: displayID)
        if ExtCropLayers.setStaticImage(image, in: rootLayer, settings: settings) {
            extLog("[StaticRenderer] layout displayID=\(displayID) image=\(image.width)x\(image.height) display=\(rootLayer.bounds.size) scale=\(rootLayer.contentsScale) preset=\(settings.aspectPreset.rawValue) zoom=\(settings.zoom)")
        }
    }

    static func switchActiveContextToStaticImage(displayID: UInt32, sourceID: String, imageURL: URL) {
        let allContexts = WallpaperState.shared.allActiveContexts(for: displayID)
        guard !allContexts.isEmpty else {
            WallpaperState.shared.setPendingImage(imageURL, for: displayID)
            extLog("[Commands] ⏳ 无活跃 context，已缓存待处理静态图 display=\(displayID) source=\(sourceID)")
            return
        }

        guard let image = loadBudgetedSnapshotImage(imageURL) else {
            extLog("[Commands] ❌ 静态图热切换失败 display=\(displayID) source=\(sourceID)")
            return
        }

        let replacements = allContexts.compactMap {
            WallpaperState.shared.beginRendererReplacement(contextId: $0.contextId, expectedRootLayer: $0.rootLayer)
        }

        // CALayer / CATransaction 不是线程安全的；handleSocketCommand 把这个调用挂在
        // wallpaperCommandQueue（utility 后台串行队列）上，必须切到主线程做 layer 修改。
        // image 和 allContexts 都是 Sendable，可直接捕获到 @Sendable 闭包里。
        let applyBlock: @Sendable () -> Void = {
            for replacement in replacements {
                let active = replacement.context
                defer { WallpaperState.shared.finishSetupTask(contextId: active.contextId, generation: replacement.generation) }
                let committed = WallpaperState.shared.commitRenderer(
                    contextId: active.contextId, generation: replacement.generation,
                    renderer: nil, videoID: sourceID
                )
                guard committed.committed else { continue }
                committed.previous?.stop()
                let rootLayer = active.rootLayer
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
                rootLayer.contents = image
                applyStaticCrop(rootLayer: rootLayer, image: image, displayID: displayID)
                CATransaction.commit()

            }
        }

        if Thread.isMainThread {
            applyBlock()
        } else {
            DispatchQueue.main.async(execute: applyBlock)
        }

        // 这些是线程安全的，可以在当前线程执行
        WallpaperState.shared.removeIOSurfaceRenderer(for: displayID)
        FrameChannel.shared.unregisterCallback(displayID: displayID)
        WallpaperPrefs.shared.updateCurrentVideo()
        extLog("[Commands] ✅ 已热切换显示器 \(displayID) 到静态图: \(sourceID) (\(allContexts.count) 个 context)")
    }

    func update(withId id: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        noteServed()
        let wallpaperIDString = Self.extractWallpaperContextIdentifier(from: id)
        let geometry = Self.requestDisplayGeometry(from: request)
        Self.applyDisplayGeometryUpdate(
            wallpaperID: wallpaperIDString,
            displayID: geometry.displayID,
            size: geometry.size,
            scale: geometry.scale
        )

        var presentationMode = "?"
        var activityState = "?"
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let innerValue = mirror.children.first?.value {
                let desc = String(describing: innerValue)
                if let modeRange = desc.range(of: "presentationMode: ") {
                    let afterMode = desc[modeRange.upperBound...]
                    if let endRange = afterMode.range(of: ",") ?? afterMode.range(of: ")") {
                        presentationMode = String(afterMode[..<endRange.lowerBound])
                    }
                }
                if let actRange = desc.range(of: "activityState: ") {
                    let afterAct = desc[actRange.upperBound...]
                    if let endRange = afterAct.range(of: ",") ?? afterAct.range(of: ")") {
                        activityState = String(afterAct[..<endRange.lowerBound])
                    }
                }
            }
        }

        if presentationMode == "locked" {
            WallpaperState.shared.isScreenLocked = true
            lastLockedUpdate = Date()
        } else if presentationMode == "active",
                  WallpaperState.shared.isScreenLocked,
                  Date().timeIntervalSince(lastLockedUpdate) > 3.0 {
            // 自愈：screenIsUnlocked DistributedNotification 偶发会丢失，导致 isScreenLocked
            // 卡死为 true，桌面壁纸永远走 "locked" policy 不再播放。
            // 看到 presentationMode 持续 active 超过 3s 就强制清除，恢复桌面播放。
            WallpaperState.shared.isScreenLocked = false
            extLog("[Update] 自愈：presentationMode 持续 active，强制清 isScreenLocked")
        }
        // 注意：不在每个 active update 都设置 isScreenLocked = false。
        // screenIsLocked/screenIsUnlocked 的 DistributedNotification 才是锁屏状态的正确信源；
        // WallpaperAgent 在锁屏过渡期间会发 update("active")，此时不应该立刻覆盖 isScreenLocked。

        let prefs = WallpaperPrefs.shared
        let hostUnavailable = prefs.isAppHostTerminated
            && !WallpaperState.shared.isScreenLocked
            && !WallpaperState.shared.isDisplayAsleep
        let effectivePresentationMode = PlaybackPolicy.effectivePresentationMode(
            agentMode: presentationMode,
            isScreenLocked: WallpaperState.shared.isScreenLocked,
            hostUnavailable: hostUnavailable
        )
        let effectiveActivityState = hostUnavailable ? "active" : activityState
        // Preserve the agent's raw mode so the unlock notification can remove
        // the lock override without waiting for another XPC update.
        WallpaperState.shared.presentationMode = presentationMode
        WallpaperState.shared.activityState = activityState

        let power = PowerMonitor.shared.currentState
        let basePolicy = PlaybackPolicy.compute(
            presentationMode: effectivePresentationMode,
            activityState: effectiveActivityState,
            userPaused: prefs.userPaused,
            alwaysPauseDesktop: prefs.effectiveAlwaysPauseDesktop,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            powerState: power,
            pauseOnBattery: prefs.pauseOnBattery
        )

        let modeChanged = effectivePresentationMode != previousPresentationMode
        let animated = prefs.effectiveAlwaysPauseDesktop
            && effectiveActivityState == "active"
            && modeChanged

        // Per-display policy：检查每个显示器是否有独立的暂停设置
        WallpaperState.shared.forEachActiveContext { displayID, renderer in
            let isDisplayPaused = displayID.flatMap { prefs.isDisplayPaused($0) } ?? false
            let effectivePolicy: PlaybackPolicy = isDisplayPaused ? .paused : basePolicy
            renderer.applyPolicy(effectivePolicy, animated: animated)
        }

        previousPresentationMode = effectivePresentationMode
        extLog(
            "=== UPDATE === mode: \(presentationMode) -> \(effectivePresentationMode), "
                + "activity: \(activityState) -> \(effectiveActivityState)"
        )
        reply(nil)
    }

    func invalidate(withId id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        noteServed()
        let identifier = Self.extractWallpaperContextIdentifier(from: id)
        var cleanedCount = 0
        if let identifier {
            // 桌面 + 锁屏共享同一 wallpaperID（系统 WallpaperAgent 一次 invalidate 两个 instance），
            // 必须循环 stop 所有匹配的 renderer，否则前面的 context renderer 永久泄漏。
            let removed = WallpaperState.shared.removeContext(wallpaperID: identifier)
            for ctx in removed {
                ctx.renderer?.stop()
            }
            forgetOwnedContexts(Set(removed.map(\.contextId)))
            cleanedCount = removed.count
        }
        let remaining = WallpaperState.shared.activeContextCount
        if remaining == 0 {
            WallpaperPrefs.shared.setActive(false)
        }
        extLog("=== INVALIDATE === (identifier: \(identifier ?? "nil"), cleaned: \(cleanedCount), remaining: \(remaining))")
        reply(nil)
    }

    func snapshot(withId id: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        noteServed()
        extLog("=== SNAPSHOT ===")
        let identifier = Self.extractWallpaperContextIdentifier(from: id)
        let context = identifier.flatMap { WallpaperState.shared.activeContext(wallpaperID: $0) }
        if identifier != nil, context == nil {
            reply(nil, nil)
            return
        }
        var currentTime: CMTime?
        if let renderer = context?.renderer { currentTime = CMTimebaseGetTime(renderer.timebase) }
        requestSnapshotViaRuntime(displayID: context?.displayID, currentTime: currentTime) { snapshotXPC in
            if let snapshotXPC {
                reply(snapshotXPC, nil)
                extLog("  Snapshot replied (IOSurface)")
            } else {
                reply(nil, nil)
                extLog("  Snapshot replied nil — 所有策略均未命中")
            }
        }
    }

    // MARK: - Prefs Change Monitoring

    /// 唤醒/恢复后让 WallpaperAgent 丢弃缓存的壁纸快照，促使其重新拉取。
    /// 参考 Mirage：唤醒后系统侧快照缓存会滞留旧帧，主动失效可避免
    /// 系统设置页/调度预览停留在唤醒前内容。
    static func invalidateSnapshotsAfterWake() {
        WallpaperPrefsChangeObserver.shared.withLiveHandlers { handler in
            guard let proxy = handler.agentProxy else { return }
            proxy.invalidateSnapshots { error in
                if let error {
                    extLog("[XPCHandler] 唤醒后 invalidateSnapshots 失败: \(error)")
                }
            }
        }
    }

    /// 开始监听 App 部署新视频的 Darwin 通知，并通知系统刷新壁纸设置。
    /// 在 agentProxy 设置后调用。
    func startObservingPrefs() {
        WallpaperPrefsChangeObserver.shared.register(self)
        extLogThrottled(key: "xpc.registerPrefsObserver", interval: 600,
                        "[XPCHandler] 已注册 prefs 变化监听")
    }

    func stopObservingPrefs() {
        WallpaperPrefsChangeObserver.shared.unregister(self)
    }

    deinit {
        stopObservingPrefs()
    }

    /// prefs 变化时：通知系统刷新壁纸设置，促使系统选中最新部署的视频
    fileprivate func handlePrefsChanged() {
        // 这条通知链在 Set wallpaper / 状态同步时会连续触发（实测 13 万行日志来自这里）。
        // 入口不再单独打点，只在真正通知成功/失败时记录，避免同一事件写两三行。

        // 先清除缓存，确保证 SettingsProvider 扫描到最新文件
        WallpaperState.shared.clearCaches()

        // 检查实例文件是否被清理 — 如果 App 执行了「清理锁屏实例」，
        // 实例 JSON 已删除，扩展应停止渲染旧内容并释放 contexts。
        let instancesGone = !Self.displayInstancesFileExists()
        if instancesGone {
            let removed = WallpaperState.shared.removeAllContexts()
            if !removed.isEmpty {
                extLog("[XPCHandler] 🧹 实例文件已删除，清理 \(removed.count) 个活跃上下文")
            }
            WallpaperPrefs.shared.setActive(false)
        }

        // 与其它 drain 入口共用同一串行后台队列，避免并发竞争且不阻塞主线程。
        wallpaperCommandQueue.async {
            WaifuXWallpaperExtension.drainPendingSocketCommands(reason: "xpcPrefsChanged")
        }

        guard let proxy = agentProxy else {
            extLog("[XPCHandler] ⚠️ agentProxy 不可用，跳过刷新")
            return
        }

        nonisolated(unsafe) let unsafeProxy = proxy

        Task {
            // 构建最新的 SettingsViewModels（包含刚部署的视频）
            guard let viewModels = await buildSettingsViewModelsXPC() else {
                extLog("[XPCHandler] ⚠️ buildSettingsViewModelsXPC 返回 nil")
                return
            }

            // 通知系统刷新壁纸设置。系统收到后会重新调用 provideSettingsViewModels，
            // 从而看到最新部署的视频。
            do {
                try await unsafeProxy.updateSettingsViewModels(viewModels)
                extLogThrottled(key: "xpc.prefsRefresh", interval: 10,
                                "[XPCHandler] ✅ 已通知系统刷新壁纸设置")
            } catch {
                extLog("[XPCHandler] ❌ updateSettingsViewModels 失败: \(error)")
            }
        }
    }

    /// 检查显示器实例 JSON 文件是否存在于共享容器中。
    private static func displayInstancesFileExists() -> Bool {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
            return false
        }
        let url = container.appendingPathComponent("waifux-display-instances.json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Stubs

    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        noteServed()
        Task {
            let result = await buildSettingsViewModelsXPC()
            reply(result ?? makeEmptyGroupsResponse(), nil)
        }
    }

    func addChoiceRequest(withChoiceRequest request: Any?, onBehalfOfProcess _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extLog("=== ADD CHOICE REQUEST ===")
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extLog("=== REMOVE CHOICE REQUEST ===")

        // 显示器实例不支持从扩展侧移除；这里只做日志并返回成功。
        var instanceID: String?
        if let reqObj = request as? NSObject {
            let desc = String(describing: reqObj)
            if let range = desc.range(of: "identifier: \"") {
                let after = desc[range.upperBound...]
                if let endQuote = after.firstIndex(of: "\"") {
                    instanceID = String(after[..<endQuote])
                }
            }
        }

        extLog("  [Remove] 忽略实例删除请求: \(instanceID ?? "unknown")")
        reply(nil)
    }

    func selectedChoicesDidChange(for id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extLog("=== SELECTED CHOICES DID CHANGE ===")

        // 从 WallpaperChoiceID 中提取 choice identifier
        var choiceIdentifier: String?
        if let idObj = id as? NSObject {
            let mirror = Mirror(reflecting: idObj)
            for child in mirror.children {
                let desc = String(describing: child.value)
                if let range = desc.range(of: "identifier: \"") {
                    let after = desc[range.upperBound...]
                    if let endQuote = after.firstIndex(of: "\"") {
                        choiceIdentifier = String(after[..<endQuote])
                    }
                }
            }
        }

        guard let instanceID = choiceIdentifier else {
            extLog("selectedChoicesDidChange: 未知 choice \(String(describing: choiceIdentifier))")
            reply(nil)
            return
        }

        extLog("=== INSTANCE CHANGED === id: \(instanceID)")

        WallpaperState.shared.currentVideoID = instanceID
        WallpaperPrefs.shared.updateCurrentVideo()
        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID menuItemID: Any?, groupItemID _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let identifier = (menuItemID as? String) ?? String(describing: menuItemID ?? "nil")
        extLog("=== CONTEXT MENU ACTION === identifier: \(identifier)")
        reply(nil)
    }

    func isChoiceDownloaded(with _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        extLog("isChoiceDownloaded")
        reply(true, nil)
    }

    func download(withChoiceID _: Any?, reply: ((any Error)?) -> Void) -> Any? {
        extLog("download")
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func cancelDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func resumeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func removeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func migrateSelectedChoice(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extLog("migrateSelectedChoice")
        reply(nil, nil)
    }

    func migrate(from _: Any?, to _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extLog("migrate")
        reply(nil)
    }

    func skipShuffledContent(withId _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extLog("skipShuffledContent")
        reply(nil)
    }

    func canSkipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        extLog("canSkipShuffledContent")
        reply(false, nil)
    }

    func handleDebugRequest(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extLog("handleDebugRequest")
        reply(nil, nil)
    }

    func handleNotification(withNamed _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }
    private func createRemoteContextXPC(contextId: UInt32) -> AnyObject? {
        guard let realClass = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
              let raw = class_createInstance(realClass, 0) else {
            extLog("  ERROR: Could not create WallpaperRemoteContextXPC (class not found)")
            return nil
        }

        let obj = raw as AnyObject

        // 优先尝试 KVC 写入 contextId（安全，不会越界写内存）
        let nsContextId = NSNumber(value: contextId)
        if obj.responds(to: NSSelectorFromString("setBox:")) ||
           obj.responds(to: NSSelectorFromString("setContextId:")) {
            obj.setValue(nsContextId, forKey: "box")
            extLog("  Created WallpaperRemoteContextXPC via KVC (contextId: \(contextId))")
            return obj
        }

        // KVC 失败时尝试 ivar 直接写入，但必须有完整的安全检查
        guard let ivar = class_getInstanceVariable(realClass, "box") else {
            // 没有 "box" ivar → 无法安全设置 contextId
            // 直接返回对象，WallpaperAgent 可能会显示默认状态，但不会崩溃
            extLog("  ⚠️ WallpaperRemoteContextXPC 无 'box' ivar，返回未设置 contextId 的对象")
            return obj
        }

        let ivarOffset = ivar_getOffset(ivar)
        let instanceSize = class_getInstanceSize(realClass)
        let writeEnd = ivarOffset + MemoryLayout<UInt32>.size

        guard writeEnd <= instanceSize else {
            extLog("  ❌ WallpaperRemoteContextXPC ivar 偏移越界 (offset=\(ivarOffset), size=\(instanceSize))")
            return obj
        }

        let ptr = Unmanaged.passUnretained(obj).toOpaque()
        ptr.advanced(by: ivarOffset).storeBytes(of: contextId, as: UInt32.self)
        extLog("  Created WallpaperRemoteContextXPC via ivar (contextId: \(contextId), offset: \(ivarOffset))")
        return obj
    }
}
