//  线程安全的扩展共享状态
//
//  所有访问通过 OSAllocatedUnfairLock 保护，避免并发 XPC 回调竞争。
//
//  参考 Phosphene (MIT) 的实现，增加了库变化监听、display contexts、
//  cachedThumbnailURL 等特性。

import Foundation
import os
import QuartzCore

struct ActiveWallpaper: @unchecked Sendable {
    let caContext: AnyObject
    let rootLayer: CALayer
    let renderer: VideoRenderer?
    let displayID: UInt32?
    let videoID: String?
    let contextId: UInt32
    /// 系统 WallpaperAgent 通过 XPC 传给 acquire 的 id（已 normalize 成 "uuid:..." 或 "raw:..."）。
    /// 同一 wallpaperID 可对应多个 contextId（桌面 + 锁屏两 instance 共享 wallpaperID）。
    /// 注意：videoID 存的是 instanceID（"display-<n>"），与 wallpaperID 是两个命名空间，
    /// 历史代码混用导致 invalidate/几何更新等路径全部 mismatch — 见 commit b74db8a 后的修复。
    let wallpaperID: String?
}

final class WallpaperState: Sendable {
    static let shared = WallpaperState()

    private static let selectedVideoKey = "waifux_selected_video_id"

    private struct State: @unchecked Sendable {
        var activeContexts: [UInt32: ActiveWallpaper] = [:]
        /// 已移除：历史上 wallpaperID → contextId 是单值映射，
        /// 桌面和锁屏两个 instance 共享同一 wallpaperID 时后者会覆盖前者，
        /// 导致被覆盖的 instance 的 renderer 被 stop（layers 全部拆除）→ 黑屏。
        /// 现在按 contextId 独立存储，wallpaperID 查找改走 activeContexts.values 扫描。
        var cachedThumbnailURL: URL?
        var cacheDirectoryURL: URL?
        // 兼容旧的全局单值缓存（findVideoURL/findImageURL 等非 display 特定路径仍会使用）。
        var cachedVideoURL: URL?
        var cachedImageURL: URL?
        // 多显示器：每个显示器独立的“热切换”缓存。
        // switch_video / switch_image 到达时按 displayID 写入各自一格，避免屏 A 的切换覆盖屏 B。
        var cachedVideoURLs: [UInt32: URL] = [:]
        var cachedImageURLs: [UInt32: URL] = [:]
        var currentVideoID: String? = UserDefaults.standard.string(forKey: WallpaperState.selectedVideoKey)
        var presentationMode: String = "active"
        var activityState: String = "active"
        var isDisplayAsleep: Bool = false
        var isScreenLocked: Bool = false
        /// IOSurface 帧渲染器（每显示器），用于帧通道回调
        var ioSurfaceRenderers: [UInt32: IOSurfaceFrameRenderer] = [:]
        /// 待处理的视频切换：当 switch_video 到达但无活跃上下文时缓存，上下文创建后自动应用
        var pendingVideoSwitches: [UInt32: URL] = [:]
        /// 待处理的静态图切换。与视频切换同样需要跨越 context 重建窗口。
        var pendingImageSwitches: [UInt32: URL] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private init() {
        // 注册库变化通知 — 收到通知时清除缓存
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let state = Unmanaged<WallpaperState>.fromOpaque(observer).takeUnretainedValue()
                state.clearCaches()
            },
            "com.waifux.app.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// 清除库级别的缓存 URL，使下次查找重新评估当前库。
    /// 不清理 pendingVideoSwitches/pendingImageSwitches 和 per-display 热切换缓存（cachedVideoURLs/cachedImageURLs），
    /// 这些是 socket 命令级别的状态，不应因 prefs 变化通知而丢失。
    func clearCaches() {
        lock.withLock { state in
            state.cachedVideoURL = nil
            state.cachedImageURL = nil
            state.cachedThumbnailURL = nil
        }
    }

    // MARK: - Context Management

    /// 存储新的渲染上下文。
    /// 同一 wallpaperID 可对应多个 contextId（桌面 + 锁屏两个独立 instance 各自 acquire）。
    /// 历史上此处按 wallpaperID 去重，会把先 acquire 的 instance（通常是桌面）的 renderer stop 掉，
    /// 导致该 instance 的 rootLayer layers 全部拆除 → 黑屏，且永远无法被 alwaysPauseDesktop policy 命中。
    /// 现改为只按 contextId 存储/去重，同一 wallpaperID 多 instance 共存。
    /// `wallpaperID` 形参会被持久化到 ActiveWallpaper.wallpaperID，供 invalidate / 几何更新等
    /// 按真 wallpaperID 路由的路径使用（不要再用 videoID 比 wallpaperID — 两者属不同命名空间）。
    func storeContext(_ context: ActiveWallpaper, id: UInt32, wallpaperID _: String?) -> ActiveWallpaper? {
        lock.withLock { state in
            let existing = state.activeContexts[id]
            state.activeContexts[id] = context
            return existing
        }
    }

    /// 移除所有匹配 wallpaperID 的 context（桌面 + 锁屏均可能被系统一次性 invalidate）。
    /// 返回所有被移除的 context，调用方负责对每个 renderer 调用 stop()。
    /// 历史实现按 videoID 比较 wallpaperID（命名空间不同，永远 mismatch），且循环里 `removed = ...`
    /// 会覆盖只剩最后一个，导致前面的 renderer 永久泄漏 — 现已修正。
    func removeContext(wallpaperID: String) -> [ActiveWallpaper] {
        lock.withLock { state in
            let matching = state.activeContexts.filter { $0.value.wallpaperID == wallpaperID }.map { $0.key }
            var removed: [ActiveWallpaper] = []
            removed.reserveCapacity(matching.count)
            for id in matching {
                if let ctx = state.activeContexts.removeValue(forKey: id) {
                    removed.append(ctx)
                }
            }
            return removed
        }
    }

    func removeAllContexts() -> [ActiveWallpaper] {
        let removed = lock.withLock { state -> ([ActiveWallpaper], [IOSurfaceFrameRenderer]) in
            let all = Array(state.activeContexts.values)
            let ioRenderers = Array(state.ioSurfaceRenderers.values)
            state.activeContexts.removeAll()
            state.ioSurfaceRenderers.removeAll()
            return (all, ioRenderers)
        }
        for ctx in removed.0 { ctx.renderer?.stop() }
        for renderer in removed.1 { renderer.stop() }
        return removed.0
    }

    // MARK: - Iteration

    func forEachRenderer(_ body: (VideoRenderer) -> Void) {
        let renderers = lock.withLock { $0.activeContexts.values.compactMap(\.renderer) }
        for renderer in renderers { body(renderer) }
    }

    /// 对指定 displayID 的渲染器执行闭包
    func forRenderers(displayID: UInt32, _ body: (VideoRenderer) -> Void) {
        let renderers = lock.withLock {
            $0.activeContexts.values
                .filter { $0.displayID == displayID }
                .compactMap(\.renderer)
        }
        for renderer in renderers { body(renderer) }
    }

    /// 遍历每个活跃 context 的 renderer 和 displayID（用于 per-display policy）
    func forEachActiveContext(_ body: (UInt32?, VideoRenderer) -> Void) {
        let contexts = lock.withLock { Array($0.activeContexts.values) }
        for ctx in contexts {
            if let renderer = ctx.renderer {
                body(ctx.displayID, renderer)
            }
        }
    }

    /// 根据 displayID 查找活跃 renderer
    func renderer(for displayID: UInt32) -> VideoRenderer? {
        lock.withLock {
            $0.activeContexts.values.first(where: { $0.displayID == displayID })?.renderer
        }
    }

    func activeContext(for displayID: UInt32) -> ActiveWallpaper? {
        lock.withLock {
            $0.activeContexts.values.first(where: { $0.displayID == displayID })
        }
    }

    /// 命令路由用的上下文查找：必须精确匹配 displayID。
    /// 历史上此处带有”回退到任意 nil displayID 上下文 / count==1 就返回唯一上下文”的逻辑，
    /// 在多显示器场景下会把发给屏幕 A 的 switch_video 命令命中到屏幕 B 的上下文（串屏/黑屏）。
    /// 现改为精确匹配失败即返回 nil，调用方会通过 setPendingVideo 缓存命令，
    /// 在对应屏幕下次 acquire 时自动应用。
    func activeContextForCommand(displayID: UInt32) -> ActiveWallpaper? {
        lock.withLock { state in
            state.activeContexts.values.first(where: { $0.displayID == displayID })
        }
    }

    /// 返回同一 displayID 的**所有**活跃上下文。
    /// macOS 桌面实例和锁屏实例共享同一个 displayID 但各自 acquire 产生独立 context，
    /// switch_video 命令必须更新两者，否则其中一个会停留在旧视频内容。
    func allActiveContexts(for displayID: UInt32) -> [ActiveWallpaper] {
        lock.withLock { state in
            state.activeContexts.values.filter { $0.displayID == displayID }
        }
    }

    func activeContext(wallpaperID: String) -> ActiveWallpaper? {
        lock.withLock { state in
            state.activeContexts.values.first { $0.wallpaperID == wallpaperID }
        }
    }

    func updateContextDisplayID(wallpaperID: String, displayID: UInt32) {
        lock.withLock { state in
            let matching = state.activeContexts.filter { $0.value.wallpaperID == wallpaperID && $0.value.displayID != displayID }
            for (key, old) in matching {
                state.activeContexts[key] = ActiveWallpaper(
                    caContext: old.caContext,
                    rootLayer: old.rootLayer,
                    renderer: old.renderer,
                    displayID: displayID,
                    videoID: old.videoID,
                    contextId: old.contextId,
                    wallpaperID: old.wallpaperID
                )
            }
        }
    }

    func updateContextDisplayID(rootLayer: CALayer, displayID: UInt32) {
        lock.withLock { state in
            guard let pair = state.activeContexts.first(where: { $0.value.rootLayer === rootLayer }),
                  pair.value.displayID != displayID else {
                return
            }
            let old = pair.value
            state.activeContexts[pair.key] = ActiveWallpaper(
                caContext: old.caContext,
                rootLayer: old.rootLayer,
                renderer: old.renderer,
                displayID: displayID,
                videoID: old.videoID,
                contextId: pair.key,
                wallpaperID: old.wallpaperID
            )
        }
    }

    func activeContextsSnapshot() -> [ActiveWallpaper] {
        lock.withLock { Array($0.activeContexts.values) }
    }

    func replaceContextRenderer(displayID: UInt32, renderer: VideoRenderer?, videoID: String?) -> VideoRenderer? {
        lock.withLock { state in
            guard let pair = state.activeContexts.first(where: { $0.value.displayID == displayID }) else {
                return nil
            }
            let old = pair.value
            state.activeContexts[pair.key] = ActiveWallpaper(
                caContext: old.caContext,
                rootLayer: old.rootLayer,
                renderer: renderer,
                displayID: old.displayID,
                videoID: videoID ?? old.videoID,
                contextId: pair.key,
                wallpaperID: old.wallpaperID
            )
            return old.renderer
        }
    }

    /// 命令路由用的渲染器替换：必须精确匹配 displayID，不再回退到任意上下文，
    /// 避免多显示器下把某一屏的渲染器替换错误地应用到另一屏（与 activeContextForCommand 保持一致）。
    /// 替换指定 contextId 的渲染器，返回旧的渲染器（如果存在）。
    /// 用于 switch_video 命令中需要精确更新特定 context 的场景。
    func replaceContextRendererByContextId(contextId: UInt32, renderer: VideoRenderer?, videoID: String?) -> VideoRenderer? {
        lock.withLock { state in
            guard let old = state.activeContexts[contextId] else {
                return nil
            }
            state.activeContexts[contextId] = ActiveWallpaper(
                caContext: old.caContext,
                rootLayer: old.rootLayer,
                renderer: renderer,
                displayID: old.displayID,
                videoID: videoID ?? old.videoID,
                contextId: contextId,
                wallpaperID: old.wallpaperID
            )
            return old.renderer
        }
    }

    /// 替换指定 contextId 的上下文，返回旧的上下文（如果存在）。
    func replaceContextById(contextId: UInt32, context: ActiveWallpaper) -> ActiveWallpaper? {
        lock.withLock { state in
            let old = state.activeContexts.removeValue(forKey: contextId)
            state.activeContexts[contextId] = context
            return old
        }
    }

    // MARK: - Pending Video Switches

    /// 缓存待处理的视频切换请求（当 switch_video 到达但无活跃上下文时调用）
    func setPendingVideo(_ url: URL, for displayID: UInt32) {
        lock.withLock { state in
            state.pendingVideoSwitches[displayID] = url
            state.pendingImageSwitches.removeValue(forKey: displayID)
        }
    }

    /// 取出并清除待处理的视频切换（上下文创建后调用）
    func takePendingVideo(for displayID: UInt32) -> URL? {
        lock.withLock { $0.pendingVideoSwitches.removeValue(forKey: displayID) }
    }

    /// 取出任意一个待处理的视频切换（当 displayID 不确定时使用）
    func takeAnyPendingVideo() -> (displayID: UInt32, url: URL)? {
        lock.withLock { state in
            guard let first = state.pendingVideoSwitches.first else { return nil }
            return state.pendingVideoSwitches.removeValue(forKey: first.key).map { (first.key, $0) }
        }
    }

    // MARK: - Pending Image Switches

    /// 缓存待处理的静态图切换请求（当 switch_image 到达但无活跃上下文时调用）。
    func setPendingImage(_ url: URL, for displayID: UInt32) {
        lock.withLock { state in
            state.pendingImageSwitches[displayID] = url
            state.pendingVideoSwitches.removeValue(forKey: displayID)
        }
    }

    /// 取出并清除待处理的静态图切换（上下文创建后调用）。
    func takePendingImage(for displayID: UInt32) -> URL? {
        lock.withLock { $0.pendingImageSwitches.removeValue(forKey: displayID) }
    }

    // MARK: - IOSurfaceFrameRenderer Registry

    /// 存储 IOSurfaceFrameRenderer 供帧通道回调使用
    func storeIOSurfaceRenderer(_ renderer: IOSurfaceFrameRenderer, for displayID: UInt32) {
        let previous = lock.withLock { state -> IOSurfaceFrameRenderer? in
            let old = state.ioSurfaceRenderers[displayID]
            state.ioSurfaceRenderers[displayID] = renderer
            return old
        }
        previous?.stop()
    }

    /// 移除 IOSurfaceFrameRenderer
    func removeIOSurfaceRenderer(for displayID: UInt32) {
        let previous = lock.withLock { state -> IOSurfaceFrameRenderer? in
            let old = state.ioSurfaceRenderers[displayID]
            state.ioSurfaceRenderers[displayID] = nil
            return old
        }
        previous?.stop()
    }

    /// 获取指定显示器的 IOSurfaceFrameRenderer
    func ioSurfaceRenderer(for displayID: UInt32) -> IOSurfaceFrameRenderer? {
        lock.withLock { $0.ioSurfaceRenderers[displayID] }
    }

    /// 获取任意一个活跃的 IOSurfaceFrameRenderer（用于 snapshot 回退）。
    func anyIOSurfaceRenderer() -> IOSurfaceFrameRenderer? {
        lock.withLock { $0.ioSurfaceRenderers.values.first }
    }

    /// 所有活跃 context 的唯一 displayID 集合
    func uniqueDisplayIDs() -> Set<UInt32> {
        lock.withLock { Set($0.activeContexts.values.compactMap(\.displayID)) }
    }

    /// 每个唯一显示器的活跃 context 信息
    func activeDisplayContexts() -> [(displayID: UInt32, videoID: String?)] {
        lock.withLock { state in
            var seen = Set<UInt32>()
            var result: [(displayID: UInt32, videoID: String?)] = []
            for ctx in state.activeContexts.values {
                guard let did = ctx.displayID, seen.insert(did).inserted else { continue }
                result.append((displayID: did, videoID: ctx.videoID))
            }
            return result
        }
    }

    var activeContextCount: Int {
        lock.withLock { $0.activeContexts.count }
    }

    // MARK: - Properties

    var cachedThumbnailURL: URL? {
        get { lock.withLock { $0.cachedThumbnailURL } }
        set { lock.withLock { $0.cachedThumbnailURL = newValue } }
    }

    var cacheDirectoryURL: URL? {
        get { lock.withLock { $0.cacheDirectoryURL } }
        set { lock.withLock { $0.cacheDirectoryURL = newValue } }
    }

    var cachedVideoURL: URL? {
        get { lock.withLock { $0.cachedVideoURL } }
        set { lock.withLock { $0.cachedVideoURL = newValue } }
    }

    var cachedImageURL: URL? {
        get { lock.withLock { $0.cachedImageURL } }
        set { lock.withLock { $0.cachedImageURL = newValue } }
    }

    // MARK: - Per-display 缓存（多显示器热切换）

    /// 读取某块显示器热切换缓存到的视频 URL。优先返回 per-display 缓存，
    /// 没有则回退到全局单值（兼容单显示器/旧调用方）。
    func cachedVideoURL(for displayID: UInt32) -> URL? {
        lock.withLock { $0.cachedVideoURLs[displayID] ?? $0.cachedVideoURL }
    }

    /// 写入某块显示器的热切换视频缓存，并清除该屏的图片缓存（互斥）。
    func setCachedVideoURL(_ url: URL?, for displayID: UInt32) {
        lock.withLock { state in
            if let url {
                state.cachedVideoURLs[displayID] = url
            } else {
                state.cachedVideoURLs.removeValue(forKey: displayID)
            }
            state.cachedImageURLs.removeValue(forKey: displayID)
            state.pendingVideoSwitches.removeValue(forKey: displayID)
            state.pendingImageSwitches.removeValue(forKey: displayID)
        }
    }

    /// 读取某块显示器热切换缓存到的图片 URL。
    func cachedImageURL(for displayID: UInt32) -> URL? {
        lock.withLock { $0.cachedImageURLs[displayID] ?? $0.cachedImageURL }
    }

    /// 写入某块显示器的热切换图片缓存，并清除该屏的视频缓存（互斥）。
    func setCachedImageURL(_ url: URL?, for displayID: UInt32) {
        lock.withLock { state in
            if let url {
                state.cachedImageURLs[displayID] = url
            } else {
                state.cachedImageURLs.removeValue(forKey: displayID)
            }
            state.cachedVideoURLs.removeValue(forKey: displayID)
            state.pendingImageSwitches.removeValue(forKey: displayID)
            state.pendingVideoSwitches.removeValue(forKey: displayID)
        }
    }

    var currentVideoID: String? {
        get { lock.withLock { $0.currentVideoID } }
        set {
            lock.withLock { $0.currentVideoID = newValue }
            UserDefaults.standard.set(newValue, forKey: WallpaperState.selectedVideoKey)
        }
    }

    var presentationMode: String {
        get { lock.withLock { $0.presentationMode } }
        set { lock.withLock { $0.presentationMode = newValue } }
    }

    var activityState: String {
        get { lock.withLock { $0.activityState } }
        set { lock.withLock { $0.activityState = newValue } }
    }

    var isDisplayAsleep: Bool {
        get { lock.withLock { $0.isDisplayAsleep } }
        set { lock.withLock { $0.isDisplayAsleep = newValue } }
    }

    var isScreenLocked: Bool {
        get { lock.withLock { $0.isScreenLocked } }
        set { lock.withLock { $0.isScreenLocked = newValue } }
    }
}
