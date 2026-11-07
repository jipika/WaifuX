import AppKit
import QuartzCore
import SwiftUI

/// Only explicit page navigation advances this value; search/reload/tab changes do not animate.
struct LibraryFolderNavigation: Equatable {
    enum Direction: Equatable {
        case forward
        case backward

        var sign: CGFloat { self == .forward ? 1 : -1 }
    }

    private(set) var revision: UInt = 0
    private(set) var direction: Direction = .forward
    private(set) var isAnimated = false

    mutating func move(_ direction: Direction) {
        self.direction = direction
        isAnimated = true
        revision &+= 1
    }

    mutating func suppressAnimation() {
        // A reset can be coalesced with an earlier push before the bridge sees either update.
        // Keep the final intent explicit instead of treating every unseen revision as a move.
        isAnimated = false
    }
}

/// One live hosting view, plus one short-lived viewport image. In particular, a folder change
/// must not give the NSCollectionView a new SwiftUI identity and reload all its cover images.
struct LibraryFolderTransition<Content: View>: NSViewRepresentable {
    let pageID: String
    let navigation: LibraryFolderNavigation
    let isVisible: Bool
    /// Describes this page, not its destination. Live video/web details opt out; lists may be captured.
    var allowsSnapshot: Bool = true
    @ViewBuilder var content: Content
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> LibraryFolderTransitionView {
        LibraryFolderTransitionView(
            rootView: hostedContent,
            pageID: pageID,
            navigation: navigation,
            allowsSnapshot: allowsSnapshot
        )
    }

    func updateNSView(_ nsView: LibraryFolderTransitionView, context: Context) {
        nsView.update(
            rootView: hostedContent,
            pageID: pageID,
            navigation: navigation,
            isVisible: isVisible,
            reduceMotion: environment.accessibilityReduceMotion,
            allowsSnapshot: allowsSnapshot
        )
    }

    static func dismantleNSView(_ nsView: LibraryFolderTransitionView, coordinator: ()) {
        nsView.finishTransition()
    }

    private var hostedContent: AnyView {
        // A separate NSHostingView does not inherit the enclosing SwiftUI environment.
        AnyView(content.environment(\.self, environment))
    }
}

/// The same lightweight transition hosts the main list/detail NavigationStack.
/// Keep the library names intact so folder navigation needs no identity or API migration.
typealias PageNavigationMotion = LibraryFolderNavigation
typealias PageNavigationTransition<Content: View> = LibraryFolderTransition<Content>

@MainActor
final class LibraryFolderTransitionView: NSView {
    private let hostingView: NSHostingView<AnyView>
    private let liveContainer = NSView()
    private var outgoingLayer: CALayer?
    private var pageID: String
    private var navigation: LibraryFolderNavigation
    private var generation: UInt = 0
    private var viewportSize: CGSize = .zero
    private var wasReducingMotion = false
    private var isTransitioning = false
    private var allowsSnapshot: Bool

    init(rootView: AnyView, pageID: String, navigation: LibraryFolderNavigation, allowsSnapshot: Bool = true) {
        self.hostingView = NSHostingView(rootView: rootView)
        self.pageID = pageID
        self.navigation = navigation
        self.allowsSnapshot = allowsSnapshot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        liveContainer.wantsLayer = true
        hostingView.sizingOptions = []
        addSubview(liveContainer)
        liveContainer.addSubview(hostingView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        if viewportSize != bounds.size {
            // A resized snapshot has the wrong geometry. Drop it rather than stretching a frame.
            finishTransition()
            viewportSize = bounds.size
        }
        liveContainer.frame = bounds
        hostingView.frame = liveContainer.bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finishTransition() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isTransitioning, bounds.contains(convert(point, from: superview)),
           let event = NSApp.currentEvent {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown,
                 .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                // A bitmap and a translated presentation layer are not native hit targets.
                // Settle immediately and consume this activation instead of opening an unseen item.
                // Keyboard/trackpad back remains available throughout the transition.
                finishTransition()
                return self
            default:
                break
            }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    func update(
        rootView: AnyView,
        pageID: String,
        navigation: LibraryFolderNavigation,
        isVisible: Bool,
        reduceMotion: Bool,
        allowsSnapshot: Bool = true
    ) {
        let pageChanged = self.pageID != pageID
        let isNavigation = pageChanged && self.navigation.revision != navigation.revision && navigation.isAnimated
        let shouldAnimate = isNavigation && isVisible && window?.isVisible == true
            && bounds.width > 1 && bounds.height > 1
        // Capture eligibility belongs to the outgoing page. The incoming page may have a player.
        let image = shouldAnimate && self.allowsSnapshot ? viewportSnapshot() : nil
        if pageChanged || !isVisible || reduceMotion != wasReducingMotion {
            finishTransition()
        }
        self.pageID = pageID
        self.navigation = navigation
        self.allowsSnapshot = allowsSnapshot
        wasReducingMotion = reduceMotion

        if shouldAnimate { isTransitioning = true }
        if let image {
            installOutgoingImage(image)
        } else if shouldAnimate {
            // Never flatten a privacy blur, video, or web detail into an unsafe/incomplete image.
            // Incoming-only motion also lets the original detail tear down its player immediately.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveContainer.layer?.opacity = 0
            CATransaction.commit()
        }
        hostingView.rootView = rootView

        guard shouldAnimate else { return }
        let currentGeneration = generation
        let direction = navigation.direction
        // Updating the hosted root schedules the collection view's reload on the main queue.
        // Keep the old frame visible until that reload/layout has had its turn, with no timed delay.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.hostingView.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.hostingView.layoutSubtreeIfNeeded()
                self.hostingView.displayIfNeeded()
                self.animate(direction: direction, reduceMotion: reduceMotion, generation: currentGeneration)
            }
        }
    }

    func finishTransition() {
        generation &+= 1
        isTransitioning = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveContainer.layer?.removeAllAnimations()
        liveContainer.layer?.transform = CATransform3DIdentity
        liveContainer.layer?.opacity = 1
        outgoingLayer?.removeFromSuperlayer()
        outgoingLayer = nil
        CATransaction.commit()
    }

    private func installOutgoingImage(_ image: CGImage) {
        guard let layer else { return }
        let snapshot = CALayer()
        snapshot.frame = bounds
        snapshot.contents = image
        snapshot.contentsGravity = .resize
        snapshot.contentsScale = CGFloat(image.width) / max(1, bounds.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.addSublayer(snapshot)
        outgoingLayer = snapshot
        // The bitmap is not a view: it cannot steal clicks or appear in the accessibility tree.
        liveContainer.layer?.opacity = 0
        CATransaction.commit()
    }

    private func animate(
        direction: LibraryFolderNavigation.Direction,
        reduceMotion: Bool,
        generation: UInt
    ) {
        guard let incoming = liveContainer.layer else {
            finishTransition()
            return
        }
        let outgoing = outgoingLayer
        let duration: CFTimeInterval = reduceMotion ? 0.12 : 0.32
        let incomingDistance = reduceMotion ? 0 : direction.sign * min(72, bounds.width * 0.12)
        let outgoingDistance = reduceMotion ? 0 : -direction.sign * min(28, bounds.width * 0.045)
        let easing = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.24, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.finishTransition()
            }
        }
        incoming.opacity = 1
        addAnimation(to: incoming, keyPath: "transform.translation.x", from: incomingDistance, to: 0,
                     duration: duration, easing: easing)
        addAnimation(to: incoming, keyPath: "opacity", from: 0, to: 1,
                     duration: duration, easing: easing)
        if let outgoing {
            outgoing.opacity = 0
            outgoing.transform = CATransform3DMakeTranslation(outgoingDistance, 0, 0)
            addAnimation(to: outgoing, keyPath: "transform.translation.x", from: 0, to: outgoingDistance,
                         duration: duration, easing: easing)
            addAnimation(to: outgoing, keyPath: "opacity", from: 1, to: 0,
                         duration: duration, easing: easing)
        }
        CATransaction.commit()
    }

    private func addAnimation(
        to layer: CALayer,
        keyPath: String,
        from: CGFloat,
        to: CGFloat,
        duration: CFTimeInterval,
        easing: CAMediaTimingFunction
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = easing
        layer.add(animation, forKey: "library.folder.\(keyPath)")
    }

    private func viewportSnapshot() -> CGImage? {
        guard window?.isVisible == true, bounds.width > 1, bounds.height > 1,
              let layer, !containsFilters(in: layer) else { return nil }
        // Bound transient storage even on a large Retina window. Never capture the scroll document.
        let maxPixels: CGFloat = 2_000_000
        let scale = min(window?.backingScaleFactor ?? 1, sqrt(maxPixels / (bounds.width * bounds.height)))
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Capture the presentation tree, including an interrupted transition, rather than jumping
        // back to its logical destination when the user immediately reverses direction.
        (layer.presentation() ?? layer).render(in: context)
        return context.makeImage()
    }

    private func containsFilters(in layer: CALayer) -> Bool {
        guard !layer.isHidden, layer.opacity > 0 else { return false }
        // CALayer.render(in:) ignores filters. In particular it must not expose the unblurred
        // contents of LibraryFolderGridCell's locked previewCanvasView, even for one frame.
        if layer.filters?.isEmpty == false || layer.backgroundFilters?.isEmpty == false { return true }
        return layer.sublayers?.contains(where: { containsFilters(in: $0) }) == true
    }
}
