import AppKit
import ImageIO
import QuartzCore

/// Scene 交接专用的临时过渡静态图。
///
/// 只负责「新场景的精确静态图先盖住旧壁纸 → 新场景在其后完成真实首帧 → 淡出」这一段。
/// 不读写系统壁纸同步、持久静态 overlay 的偏好与记录、动态锁屏选择，也不碰其它显示器。
/// 窗口层级 desktop+1：高于视频/Scene 壁纸窗口（desktop），低于桌面图标与挂件。
@MainActor
final class SceneTransitionPosterPresenter {
    static let shared = SceneTransitionPosterPresenter()

    /// 本类拥有的过渡窗口归属：只有当前 owner 才能淡出或移除。
    struct Owner: Equatable, Hashable, Sendable {
        let requestID: String
        let screenID: String
        let generation: UInt64
    }

    enum PresentationError: Error, LocalizedError, Equatable {
        case imageDecodeFailed(String)
        case displayGone(String)
        case refreshBarrierTimedOut(String)
        case superseded(String)

        var errorDescription: String? {
            switch self {
            case .imageDecodeFailed(let id): return "过渡静态图解码失败（\(id)）"
            case .displayGone(let id): return "过渡静态图目标显示器已失效（\(id)）"
            case .refreshBarrierTimedOut(let id): return "过渡静态图展示屏障超时（\(id)）"
            case .superseded(let id): return "过渡静态图已被新请求接管（\(id)）"
            }
        }
    }

    private final class PosterWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private struct Entry {
        let window: NSWindow
        var owner: Owner
        let imageURL: URL
        let geometry: String
        var fadeToken: UUID?
    }

    private var entries: [String: Entry] = [:]

    private init() {}

    // MARK: 查询

    func hasPoster(on screenID: String) -> Bool { entries[screenID] != nil }

    func owner(of screenID: String) -> Owner? { entries[screenID]?.owner }

    func imageURL(on screenID: String) -> URL? { entries[screenID]?.imageURL }

    // MARK: 展示

    /// 展示（或接管）一屏的过渡图，并通过展示屏障才返回。
    ///
    /// 屏障 = 图片已完整解码 + 布局完成 + 窗口按正确相对顺序排好 + 图层事务提交 +
    /// 目标显示器经过两个刷新回调 + 再次核对请求与显示器身份。
    /// 这是工程上可得的证据，不等同 WindowServer 的绝对可见性确认。
    /// 同屏已有旧请求的过渡图时直接原地换图换 owner，不先清空，避免露出旧内容。
    func present(
        imageURL: URL,
        on screen: NSScreen,
        owner: Owner,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        let screenID = screen.wallpaperScreenIdentifier
        let geometry = Self.geometrySignature(screen)
        let image = await Self.decodeImage(at: imageURL)
        guard let image else { throw PresentationError.imageDecodeFailed(screenID) }
        guard !Task.isCancelled, isCurrent() else { throw PresentationError.superseded(screenID) }
        guard let liveScreen = Self.liveScreen(id: screenID),
              Self.geometrySignature(liveScreen) == geometry else {
            throw PresentationError.displayGone(screenID)
        }

        // 同屏同几何：原地换图换 owner（取消进行中的淡出），不先清空。
        // 几何已变：新窗口排好后再关旧窗口，中间不露底。
        var staleWindow: NSWindow?
        let window: NSWindow
        if let existing = entries[screenID], existing.geometry == geometry {
            window = existing.window
        } else {
            staleWindow = entries[screenID]?.window
            window = makeWindow(for: liveScreen)
        }
        entries[screenID] = Entry(
            window: window, owner: owner, imageURL: imageURL,
            geometry: geometry, fadeToken: nil
        )

        Self.setImage(image, in: window, frame: liveScreen.frame)
        Self.setAlphaImmediately(window, 1)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        CATransaction.flush()
        if let staleWindow {
            staleWindow.orderOut(nil)
            staleWindow.close()
        }

        let passed = await DisplayRefreshBarrier.wait(
            screen: liveScreen, ticks: 2, timeout: 1.5
        )
        guard entries[screenID]?.owner == owner else { throw PresentationError.superseded(screenID) }
        guard !Task.isCancelled, isCurrent() else { throw PresentationError.superseded(screenID) }
        guard passed else { throw PresentationError.refreshBarrierTimedOut(screenID) }
        guard let recheck = Self.liveScreen(id: screenID),
              Self.geometrySignature(recheck) == geometry else {
            throw PresentationError.displayGone(screenID)
        }
        // 其它路径（视频守护等）可能在等待期间把窗口顶到前面，最后再排一次。
        window.orderFrontRegardless()
    }

    // MARK: 淡出 / 取消 / 释放

    /// 在同一次主线程提交里淡出一组过渡图（全局同步的组提交也走这里）。
    /// 返回 true = 全部按本请求所有权完成淡出并移除；false = 中途被取消或接管。
    /// 减少动态效果开启时不做动画，直接移除。
    @discardableResult
    func fadeOut(owners: [Owner], isCurrent: @escaping @MainActor () -> Bool) async -> Bool {
        let token = UUID()
        var windows: [(String, NSWindow)] = []
        for owner in owners {
            guard var entry = entries[owner.screenID], entry.owner == owner else { continue }
            entry.fadeToken = token
            entries[owner.screenID] = entry
            windows.append((owner.screenID, entry.window))
        }
        guard !windows.isEmpty else { return false }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            guard isCurrent() else { cancelFade(token: token); return false }
            for (screenID, window) in windows where entries[screenID]?.fadeToken == token {
                entries.removeValue(forKey: screenID)
                window.orderOut(nil)
                window.close()
            }
            return true
        }

        let completed: Bool = await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                context.allowsImplicitAnimation = true
                for (_, window) in windows {
                    window.animator().alphaValue = 0
                }
            }, completionHandler: {
                continuation.resume(returning: true)
            })
        }
        _ = completed
        // 完成回调再核对一次：过期动画只能清理自己（fadeToken 仍是本次）的窗口。
        let stillCurrent = isCurrent()
        var allRemoved = true
        for (screenID, window) in windows {
            guard entries[screenID]?.fadeToken == token else { allRemoved = false; continue }
            if stillCurrent {
                entries.removeValue(forKey: screenID)
                window.orderOut(nil)
                window.close()
            } else {
                // 淡出期间失效：仍归本请求所有时恢复覆盖，交给调用方回收运行时。
                var entry = entries[screenID]!
                entry.fadeToken = nil
                entries[screenID] = entry
                Self.setAlphaImmediately(window, 1)
                allRemoved = false
            }
        }
        return allRemoved && stillCurrent
    }

    /// 新请求接管或调用方失败时取消淡出，把过渡图恢复为完全覆盖。
    func cancelFade(on screenIDs: [String]) {
        for screenID in screenIDs {
            guard var entry = entries[screenID], entry.fadeToken != nil else { continue }
            entry.fadeToken = nil
            entries[screenID] = entry
            Self.setAlphaImmediately(entry.window, 1)
        }
    }

    private func cancelFade(token: UUID) {
        let ids = entries.filter { $0.value.fadeToken == token }.map(\.key)
        cancelFade(on: ids)
    }

    /// 只移除 owner 完全一致的过渡图；旧请求不能清掉新请求的覆盖层。
    func remove(owner: Owner) {
        guard let entry = entries[owner.screenID], entry.owner == owner else { return }
        entries.removeValue(forKey: owner.screenID)
        entry.window.orderOut(nil)
        entry.window.close()
    }

    /// 某屏被设成其它类型壁纸（视频/静态/Web）或被停止时，无条件收掉该屏过渡图。
    func releaseScreens(_ screenIDs: [String], reason: String) {
        for screenID in screenIDs {
            guard let entry = entries.removeValue(forKey: screenID) else { continue }
            entry.window.orderOut(nil)
            entry.window.close()
            AppLogger.error(.wallpaper, "Scene 过渡图被释放", metadata: [
                "screenID": screenID, "reason": reason, "requestID": entry.owner.requestID
            ])
        }
    }

    func releaseAll(reason: String) {
        releaseScreens(Array(entries.keys), reason: reason)
    }

    /// 把过渡图重新排到前面（失败回退后防止被其它壁纸窗口的守护逻辑顶下去）。
    func reassertFront(on screenIDs: [String]) {
        for screenID in screenIDs {
            entries[screenID]?.window.orderFrontRegardless()
        }
    }

    // MARK: 内部工具

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = PosterWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // 淡出需要 alpha 动画，因此非不透明；图片本身铺满整屏，视觉上不透底。
        window.isOpaque = false
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.animationBehavior = .none
        window.setFrame(screen.frame, display: false)
        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.contentsGravity = .resizeAspectFill
        content.layer?.masksToBounds = true
        window.contentView = content
        return window
    }

    private static func setImage(_ image: CGImage, in window: NSWindow, frame: CGRect) {
        window.setFrame(frame, display: false)
        guard let content = window.contentView else { return }
        content.frame = NSRect(origin: .zero, size: frame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.layer?.contents = image
        content.layer?.contentsGravity = .resizeAspectFill
        CATransaction.commit()
        content.layoutSubtreeIfNeeded()
    }

    private static func setAlphaImmediately(_ window: NSWindow, _ alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = alpha
        }
        window.alphaValue = alpha
    }

    static func geometrySignature(_ screen: NSScreen) -> String {
        let f = screen.frame
        return "\(screen.wallpaperScreenIdentifier)|\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))@\(Int(screen.backingScaleFactor * 100))"
    }

    static func liveScreen(id: String) -> NSScreen? {
        NSScreen.screens.first { $0.wallpaperScreenIdentifier == id }
    }

    /// 在后台线程完整解码（kCGImageSourceShouldCacheImmediately），主线程只挂 contents。
    private static func decodeImage(at url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

/// 目标显示器刷新屏障：等该屏 CADisplayLink 回调 N 次，超时返回 false。
@MainActor
enum DisplayRefreshBarrier {
    private final class Ticker: NSObject {
        var remaining: Int
        var continuation: CheckedContinuation<Bool, Never>?
        var link: CADisplayLink?

        init(remaining: Int) { self.remaining = remaining }

        @objc func tick(_ link: CADisplayLink) {
            remaining -= 1
            if remaining <= 0 { finish(true) }
        }

        func finish(_ value: Bool) {
            link?.invalidate()
            link = nil
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    static func wait(screen: NSScreen, ticks: Int, timeout: TimeInterval) async -> Bool {
        let ticker = Ticker(remaining: max(1, ticks))
        return await withCheckedContinuation { continuation in
            ticker.continuation = continuation
            let link = screen.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
            ticker.link = link
            link.add(to: .main, forMode: .common)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated { ticker.finish(false) }
            }
        }
    }
}
