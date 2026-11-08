import AppKit

/// Window-space points, never screen coordinates or collection-view index paths.
struct CardTransitionAnchor: Equatable {
    let frameInWindow: CGRect
    let cornerRadius: CGFloat
    /// The full cover defines click fractions; only this visible intersection must be on screen.
    let visibleFrameInWindow: CGRect?

    init(frameInWindow: CGRect, cornerRadius: CGFloat, visibleFrameInWindow: CGRect? = nil) {
        self.frameInWindow = frameInWindow
        self.cornerRadius = cornerRadius
        self.visibleFrameInWindow = visibleFrameInWindow
    }

    var isUsable: Bool {
        let r = frameInWindow
        guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite,
              r.width > 8, r.height > 8, cornerRadius.isFinite, cornerRadius >= 0 else { return false }
        guard let visibleFrameInWindow else { return true }
        let visible = r.intersection(visibleFrameInWindow)
        return visible.minX.isFinite && visible.minY.isFinite
            && visible.width.isFinite && visible.height.isFinite && visible.width > 8 && visible.height > 8
    }
}

/// A value capture of the displayed image. The resolver must weakly reference the collection
/// coordinator and resolve by stable item ID again on return; a reused cell is never retained.
@MainActor
final class CardTransitionSource {
    let itemID: String
    let image: NSImage
    let anchor: CardTransitionAnchor
    /// Fractional position on the displayed cover, preserved when its cell moves or resizes.
    let activationUnitPoint: CGPoint
    let capturedAt: TimeInterval
    private(set) weak var window: NSWindow?
    private let resolveAnchor: @MainActor () -> CardTransitionAnchor?

    init(
        itemID: String,
        image: NSImage,
        anchor: CardTransitionAnchor,
        window: NSWindow,
        activationPointInWindow: CGPoint? = nil,
        resolveAnchor: @escaping @MainActor () -> CardTransitionAnchor?
    ) {
        self.itemID = itemID
        self.image = image
        self.anchor = anchor
        if let point = activationPointInWindow, point.x.isFinite, point.y.isFinite,
           anchor.isUsable, anchor.frameInWindow.contains(point) {
            self.activationUnitPoint = CGPoint(
                x: (point.x - anchor.frameInWindow.minX) / anchor.frameInWindow.width,
                y: (point.y - anchor.frameInWindow.minY) / anchor.frameInWindow.height)
        } else {
            let visible = anchor.visibleFrameInWindow ?? anchor.frameInWindow
            self.activationUnitPoint = anchor.isUsable
                ? CGPoint(x: (visible.midX - anchor.frameInWindow.minX) / anchor.frameInWindow.width,
                          y: (visible.midY - anchor.frameInWindow.minY) / anchor.frameInWindow.height)
                : CGPoint(x: 0.5, y: 0.5)
        }
        self.window = window
        self.resolveAnchor = resolveAnchor
        self.capturedAt = ProcessInfo.processInfo.systemUptime
    }

    func isFresh(for itemID: String, in window: NSWindow) -> Bool {
        self.itemID == itemID && self.window === window && anchor.isUsable
            && image.size.width > 0 && image.size.height > 0
            && ProcessInfo.processInfo.systemUptime - capturedAt < 1.5
    }

    func activationPoint(in anchor: CardTransitionAnchor) -> CGPoint {
        let point = CGPoint(x: anchor.frameInWindow.minX + anchor.frameInWindow.width * activationUnitPoint.x,
                            y: anchor.frameInWindow.minY + anchor.frameInWindow.height * activationUnitPoint.y)
        guard let visible = anchor.visibleFrameInWindow else { return point }
        return CGPoint(x: min(visible.maxX, max(visible.minX, point.x)),
                       y: min(visible.maxY, max(visible.minY, point.y)))
    }

    func returnAnchor(in window: NSWindow) -> CardTransitionAnchor? {
        guard self.window === window, let anchor = resolveAnchor(), anchor.isUsable else { return nil }
        return anchor
    }
}
