import AppKit
import SwiftUI

/// A live liquid aperture reveals a fixed-size image over the real list. The native detail stack
/// prepares behind the final portion of the aperture. One selected image may preload through the
/// injected cancellation-aware loader; no list screenshot or duplicate detail hosting tree.
enum CardMorphImageLayout: Equatable { case fill, portrait }

@MainActor
final class WallpaperCardMorphCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, opening, handoff, open, closing }

    struct Surface: Identifiable {
        let id: UUID
        var image: NSImage
        var sourceRect: CGRect
        let destinationRect: CGRect
        let sourceCornerRadius: CGFloat
        var usesCenterReveal: Bool = false
        var imageRevision: UInt = 0
        var revealOrigin: CGPoint? = nil
        var imageLayout: CardMorphImageLayout = .fill
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var surface: Surface?
    @Published private(set) var progress: CGFloat = 0
    /// The softer contour trails the body; SwiftUI retargets both springs from their presentation values.
    @Published private(set) var contourProgress: CGFloat = 0
    @Published private(set) var opacity: Double = 1
    /// Hand the photograph to the seeded destination independently of the foreground glass.
    @Published private(set) var imageOpacity: Double = 1
    @Published private(set) var isPreparingImage = false

    private weak var viewport: NSView?
    private weak var observedWindow: NSWindow?
    private let windowObservations = CardMorphWindowObservations()
    private var viewportSize: CGSize = .zero
    private var source: CardTransitionSource?
    @Published private var previewImage: NSImage?
    private var imageLayout: CardMorphImageLayout = .fill
    private var openingCommit: Task<Void, Never>?
    private var openingFinished = false
    private var detailReady = false
    private var imageHandoffFinished = false
    private var pendingOpen: (@MainActor () -> Void)?
    private var generation: UInt = 0
    private var handoffWatchdog: Task<Void, Never>?
    private var imagePreparation: Task<Void, Never>?
    private var keyboardMonitor: Any?

    var isTransitioning: Bool { surface != nil }
    var isOpening: Bool { phase == .opening }
    var itemID: String? { source?.itemID }

    func attachViewport(_ view: NSView) {
        let changed = viewportSize != .zero && viewportSize != view.bounds.size
        viewport = view
        viewportSize = view.bounds.size
        observeWindow(view.window)
        guard changed else { return }
        switch phase {
        case .opening:
            // Never stretch an old coordinate system after a window resize.
            generation &+= 1
            imagePreparation?.cancel()
            imagePreparation = nil
            isPreparingImage = false
            commitOpen()
            finishHandoffImmediately()
        case .handoff:
            finishHandoffImmediately()
        case .closing:
            cancelAll()
        case .idle, .open:
            break
        }
    }

    func detachViewport(_ view: NSView) {
        guard viewport === view else { return }
        cancelAll()
        viewport = nil
        viewportSize = .zero
        observeWindow(nil)
    }

    func present(_ source: CardTransitionSource,
                 imageLayout: CardMorphImageLayout = .fill,
                 prepareImage: (@MainActor (CGSize, CGFloat) async -> NSImage?)? = nil,
                 open: @escaping @MainActor () -> Void) -> Bool {
        guard let viewport, let window = viewport.window, window.isVisible, !window.isMiniaturized,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              source.isFresh(for: source.itemID, in: window),
              let rect = localRect(source.anchor, in: viewport) else { return false }
        cancelAll()
        self.source = source
        self.imageLayout = imageLayout
        previewImage = source.image
        pendingOpen = open
        phase = .opening
        progress = 0
        contourProgress = 0
        opacity = 1
        imageOpacity = 1
        surface = Surface(
            id: UUID(), image: source.image, sourceRect: rect,
            destinationRect: viewport.bounds, sourceCornerRadius: source.anchor.cornerRadius,
            usesCenterReveal: true,
            revealOrigin: viewport.convert(source.activationPoint(in: source.anchor), from: nil),
            imageLayout: imageLayout
        )
        installKeyboardMonitor()
        let token = generation
        if let prepareImage {
            isPreparingImage = true
            let size = viewport.bounds.size
            let scale = window.backingScaleFactor
            imagePreparation = Task { @MainActor [weak self] in
                let prepared = await prepareImage(size, scale)
                guard !Task.isCancelled, let self, self.generation == token,
                      self.source?.itemID == source.itemID else { return }
                self.imagePreparation = nil
                if let image = prepared, image.size.width > 0, image.size.height > 0 {
                    self.previewImage = image
                    if self.surface?.usesCenterReveal == true {
                        self.surface?.image = image
                        self.surface?.imageRevision &+= 1
                    }
                }
                self.isPreparingImage = false
            }
        }
        afterLayout(token: token) { [weak self] in
            guard let self, self.phase == .opening else { return }
            self.animateProgress(to: 1, token: token) { [weak self] in
                guard let self else { return }
                self.openingFinished = true
                if self.phase == .opening { self.commitOpen() }
                if self.detailReady { self.finishHandoff(token: token) }
            }
            // Mount on the next UI turn. The destination shares the aperture mask, so its
            // layout/player can start immediately without exposing a full-page flash.
            self.openingCommit = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, self.generation == token, self.phase == .opening else { return }
                self.openingCommit = nil
                self.commitOpen()
            }
        }
        return true
    }

    /// A seed avoids a loading spinner/black placeholder after the expanded card hands off.
    func seedImage(for itemID: String) -> NSImage? {
        source?.itemID == itemID ? previewImage : nil
    }

    func detailDidAppear(itemID: String) {
        guard source?.itemID == itemID, phase == .handoff else { return }
        let token = generation
        afterLayout(token: token) { [weak self] in
            guard let self, self.phase == .handoff, !self.detailReady else { return }
            self.detailReady = true
            // The destination already paints the same decoded seed. Let its chrome emerge once,
            // beneath the still-settling glass, instead of uncovering it in the final 80 ms fade.
            withAnimation(.easeOut(duration: 0.16), completionCriteria: .removed) {
                self.imageOpacity = 0
            } completion: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == token, self.phase == .handoff else { return }
                    self.imageHandoffFinished = true
                    if self.openingFinished { self.finishHandoff(token: token) }
                }
            }
        }
    }

    func detailImageReady(itemID: String, image: NSImage, layout: CardMorphImageLayout? = nil) {
        guard source?.itemID == itemID, image.size.width > 0, image.size.height > 0 else { return }
        // The native detail owns its final image. A later cover preload must not replace a
        // decoded backdrop/video poster that the destination has already chosen.
        imagePreparation?.cancel()
        imagePreparation = nil
        isPreparingImage = false
        previewImage = image
        if let layout { imageLayout = layout }
        if surface?.usesCenterReveal == true, phase == .opening || phase == .handoff {
            surface?.image = image
            surface?.imageRevision &+= 1
            if let layout { surface?.imageLayout = layout }
        }
    }

    func detailLayoutChanged(itemID: String, layout: CardMorphImageLayout) {
        guard source?.itemID == itemID else { return }
        imageLayout = layout
    }

    func detailChangedItem(to itemID: String) {
        guard let source, source.itemID != itemID else { return }
        cancelAll()
    }

    /// Used by Esc/trackpad back before a native detail destination exists.
    @discardableResult
    func cancelOpening() -> Bool {
        guard phase == .opening, surface != nil else { return false }
        generation &+= 1
        pendingOpen = nil
        openingCommit?.cancel()
        openingCommit = nil
        imagePreparation?.cancel()
        imagePreparation = nil
        isPreparingImage = false
        phase = .closing
        let token = generation
        animateProgress(to: 0, token: token) { [weak self] in self?.cancelAll() }
        return true
    }

    /// Keep the final-size photograph above the native pop, then cover it with the same glass
    /// and resolve the current cover by stable ID before collapsing to its activation point.
    @discardableResult
    func close(itemID: String, pop: @escaping @MainActor () -> Void) -> Bool {
        guard source?.itemID == itemID, phase == .open || phase == .handoff,
              let source, let image = previewImage,
              let viewport, let window = viewport.window,
              source.window === window, viewport.bounds.width > 8, viewport.bounds.height > 8,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        generation &+= 1
        openingCommit?.cancel()
        openingCommit = nil
        imagePreparation?.cancel()
        imagePreparation = nil
        isPreparingImage = false
        handoffWatchdog?.cancel()
        handoffWatchdog = nil
        pendingOpen = nil
        phase = .closing
        progress = 1
        contourProgress = 1
        opacity = 1
        imageOpacity = 1
        let capturedRect = viewport.convert(source.anchor.frameInWindow, from: nil)
        surface = Surface(
            id: UUID(), image: image, sourceRect: capturedRect,
            destinationRect: viewport.bounds, sourceCornerRadius: source.anchor.cornerRadius,
            usesCenterReveal: true,
            revealOrigin: viewport.convert(source.activationPoint(in: source.anchor), from: nil),
            imageLayout: imageLayout
        )
        installKeyboardMonitor()
        let token = generation
        pop()
        afterLayout(token: token) { [weak self, weak window] in
            guard let self, let window else { return }
            self.resolveReturn(source, in: window, token: token,
                               deadline: ProcessInfo.processInfo.systemUptime + 0.18)
        }
        return true
    }

    /// An activation during morphing settles the UI first, rather than hitting invisible controls.
    func settleForPointerActivation() {
        switch phase {
        case .opening:
            _ = cancelOpening()
        case .handoff:
            finishHandoffImmediately()
        case .closing:
            cancelAll()
        case .idle, .open:
            break
        }
    }

    func cancelAll() {
        generation &+= 1
        imagePreparation?.cancel()
        imagePreparation = nil
        isPreparingImage = false
        handoffWatchdog?.cancel()
        handoffWatchdog = nil
        pendingOpen = nil
        openingCommit?.cancel()
        openingCommit = nil
        openingFinished = false
        detailReady = false
        imageHandoffFinished = false
        imageOpacity = 1
        imageLayout = .fill
        surface = nil
        source = nil
        previewImage = nil
        phase = .idle
        progress = 0
        contourProgress = 0
        opacity = 1
        removeKeyboardMonitor()
    }

    private func commitOpen() {
        guard phase == .opening, let open = pendingOpen else { return }
        guard let window = viewport?.window, window.isVisible, !window.isMiniaturized,
              source?.window === window else { cancelAll(); return }
        pendingOpen = nil // Release captured ContentView/StateObject before invoking navigation.
        openingCommit?.cancel()
        openingCommit = nil
        phase = .handoff
        open()
        let token = generation
        handoffWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.generation == token, self.phase == .handoff else { return }
            self.finishHandoffImmediately()
        }
    }

    private func finishHandoff(token: UInt) {
        guard phase == .handoff, openingFinished, detailReady, imageHandoffFinished else { return }
        handoffWatchdog?.cancel()
        handoffWatchdog = nil
        fadeSurface(token: token) { [weak self] in
            guard let self else { return }
            self.surface = nil
            self.phase = .open
            self.removeKeyboardMonitor()
        }
    }

    private func finishHandoffImmediately() {
        guard phase == .handoff else { return }
        generation &+= 1
        imagePreparation?.cancel()
        imagePreparation = nil
        isPreparingImage = false
        handoffWatchdog?.cancel()
        handoffWatchdog = nil
        surface = nil
        opacity = 0
        phase = .open
        removeKeyboardMonitor()
    }

    /// A native pop may need a couple of layout frames to reveal its cached collection. Resolve
    /// by ID again; if the item is gone, retain the captured point rather than jump to the center.
    private func resolveReturn(_ source: CardTransitionSource, in window: NSWindow,
                               token: UInt, deadline: TimeInterval) {
        guard generation == token, phase == .closing else { return }
        guard let viewport, viewport.window === window, window.isVisible, !window.isMiniaturized else {
            cancelAll()
            return
        }
        window.contentView?.layoutSubtreeIfNeeded()
        if let anchor = source.returnAnchor(in: window), let rect = localRect(anchor, in: viewport) {
            surface?.sourceRect = rect
            surface?.revealOrigin = viewport.convert(source.activationPoint(in: anchor), from: nil)
            animateProgress(to: 0, token: token) { [weak self] in self?.cancelAll() }
        } else if ProcessInfo.processInfo.systemUptime < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self, weak window] in
                guard let self, let window else { return }
                self.resolveReturn(source, in: window, token: token, deadline: deadline)
            }
        } else {
            animateProgress(to: 0, token: token) { [weak self] in self?.cancelAll() }
        }
    }

    private func localRect(_ anchor: CardTransitionAnchor, in viewport: NSView) -> CGRect? {
        guard anchor.isUsable else { return nil }
        let rect = viewport.convert(anchor.frameInWindow, from: nil)
        let visibleRect = viewport.convert(anchor.visibleFrameInWindow ?? anchor.frameInWindow, from: nil)
        let visible = visibleRect.intersection(rect).intersection(viewport.bounds)
        guard !visible.isNull, visible.width > 8, visible.height > 8 else { return nil }
        return rect
    }

    private func afterLayout(token: UInt, action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            guard let window = self.viewport?.window, window.isVisible, !window.isMiniaturized else {
                self.cancelAll()
                return
            }
            window.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                guard let window = self.viewport?.window, window.isVisible, !window.isMiniaturized else {
                    self.cancelAll()
                    return
                }
                action()
            }
        }
    }

    private func animateProgress(to value: CGFloat, token: UInt, completion: @escaping @MainActor () -> Void) {
        // Entry and return share the liquid aperture's response. Cancellation retargets from
        // the current presentation so the foreground cover and photograph remain continuous.
        let animation = surface?.usesCenterReveal == true
            ? Animation(CardMorphRevealSpring()) : Animation(CardMorphLiquidSpring())
        withAnimation(animation, completionCriteria: .removed) {
            progress = value
            contourProgress = value
        } completion: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                completion()
            }
        }
    }

    private func fadeSurface(token: UInt, completion: @escaping @MainActor () -> Void) {
        withAnimation(.easeOut(duration: 0.08), completionCriteria: .removed) {
            opacity = 0
        } completion: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                completion()
            }
        }
    }

    private func observeWindow(_ window: NSWindow?) {
        guard observedWindow !== window else { return }
        windowObservations.removeAll()
        observedWindow = window
        guard let window else { return }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelAll() }
            }
            windowObservations.tokens.append(token)
        }
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let window, !window.isVisible || window.isMiniaturized else { return }
                self?.cancelAll()
            }
        }
        windowObservations.tokens.append(token)
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isTransitioning, NSApp.isActive, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  event.window === self.viewport?.window, NSApp.modalWindow == nil,
                  event.window?.attachedSheet == nil else { return event }
            self.settleForPointerActivation()
            return nil
        }
    }

    private func removeKeyboardMonitor() {
        guard let keyboardMonitor else { return }
        NSEvent.removeMonitor(keyboardMonitor)
        self.keyboardMonitor = nil
    }
}

/// A finite, native-solved response for the liquid aperture. Motion starts gently, allowing the
/// transparent droplet to be perceived before it opens into the full-size photograph.
struct CardMorphRevealSpring: CustomAnimation {
    private let body = Spring(settlingDuration: 0.46, dampingRatio: 0.94, epsilon: 0.001)
    private let contour = Spring(settlingDuration: 0.51, dampingRatio: 0.82, epsilon: 0.001)

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < 0.54 else { return nil }
        return sample(value, time: time, velocity: false)
    }
    func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        sample(value, time: time, velocity: true)
    }
    func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval,
                                         context: inout AnimationContext<V>) -> Bool { false }
    private func sample<V: VectorArithmetic>(_ value: V, time: TimeInterval, velocity: Bool) -> V {
        if let pair = value as? AnimatablePair<CGFloat, CGFloat> {
            let first: CGFloat = velocity ? body.velocity(target: pair.first, time: time) : body.value(target: pair.first, time: time)
            let second: CGFloat = velocity ? contour.velocity(target: pair.second, time: time) : contour.value(target: pair.second, time: time)
            return AnimatablePair(first, second) as! V
        }
        return velocity ? body.velocity(target: value, time: time) : body.value(target: value, time: time)
    }
}

/// SwiftUI otherwise applies the last transaction's spring to the entire AnimatablePair.
/// Component springs use the public native Spring solver. Returning false from shouldMerge
/// retains additive old motion when redirected, carrying presentation position and velocity.
struct CardMorphLiquidSpring: CustomAnimation {
    private let body = Spring(settlingDuration: 0.50, dampingRatio: 0.88, epsilon: 0.001)
    private let contour = Spring(settlingDuration: 0.62, dampingRatio: 0.76, epsilon: 0.001)

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < 0.66 else { return nil }
        return sample(value, time: time, velocity: false)
    }

    func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        sample(value, time: time, velocity: true)
    }

    func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval,
                                         context: inout AnimationContext<V>) -> Bool { false }

    private func sample<V: VectorArithmetic>(_ value: V, time: TimeInterval, velocity: Bool) -> V {
        if let pair = value as? AnimatablePair<CGFloat, CGFloat> {
            let first: CGFloat = velocity ? body.velocity(target: pair.first, time: time) : body.value(target: pair.first, time: time)
            let second: CGFloat = velocity ? contour.velocity(target: pair.second, time: time) : contour.value(target: pair.second, time: time)
            return AnimatablePair(first, second) as! V
        }
        return velocity ? body.velocity(target: value, time: time) : body.value(target: value, time: time)
    }
}

/// NotificationCenter owns its registrations; this small non-actor bag also unregisters them
/// if a hosting tree is destroyed before its asynchronous viewport-detach report can run.
private final class CardMorphWindowObservations {
    var tokens: [NSObjectProtocol] = []
    func removeAll() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }
    deinit { removeAll() }
}
