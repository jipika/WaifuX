import AppKit
import SwiftUI

struct WallpaperCardMorphOverlay: View {
    @ObservedObject var coordinator: WallpaperCardMorphCoordinator

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                CardMorphViewportProbe(owner: coordinator)
                    .allowsHitTesting(false)
                if let surface = coordinator.surface {
                    CardMorphInputShield(owner: coordinator)
                    WallpaperCardMorphSurface(surface: surface, progress: coordinator.progress,
                                              contourProgress: coordinator.contourProgress,
                                              imageOpacity: coordinator.imageOpacity)
                        .id(surface.id)
                        .opacity(coordinator.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(coordinator.isTransitioning)
        .accessibilityHidden(true)
    }
}

/// Observe inside the cached native destination, so playback resumes even if NavigationStack
/// retains its destination builder instead of asking the root to construct it again.
struct CardMorphMediaGate<Content: View>: View {
    let itemID: String
    @ObservedObject var coordinator: WallpaperCardMorphCoordinator
    @ViewBuilder var content: (Bool, Bool, Bool) -> Content

    var body: some View {
        content(coordinator.itemID == itemID && coordinator.isTransitioning,
                coordinator.itemID == itemID && coordinator.phase == .closing,
                coordinator.itemID == itemID && coordinator.isPreparingImage)
    }
}

/// The destination mounts immediately but is revealed through the same lightweight aperture.
/// Its expensive layout and media preparation do not wait for the glass animation to finish.
struct CardMorphDestinationReveal: ViewModifier {
    @ObservedObject var coordinator: WallpaperCardMorphCoordinator

    func body(content: Content) -> some View {
        content.mask {
            if let surface = coordinator.surface,
               surface.usesCenterReveal, coordinator.phase != .closing {
                CardMorphRevealAperture(viewport: surface.destinationRect, origin: surface.revealOrigin,
                                       layer: .image, progress: coordinator.progress,
                                       contourProgress: coordinator.contourProgress)
            } else {
                Rectangle()
            }
        }
    }
}

/// Keep the photograph and material outside the per-frame animation graph. Only their small
/// aperture canvases and rim consume presentation values; the native list is never re-laid out.
struct WallpaperCardMorphSurface: View {
    let surface: WallpaperCardMorphCoordinator.Surface
    var progress: CGFloat
    var contourProgress: CGFloat
    var imageOpacity: Double = 1

    @ViewBuilder
    var body: some View {
        if surface.usesCenterReveal {
            centerReveal
        } else {
            CardMorphLegacySurface(surface: surface, progress: progress, contourProgress: contourProgress)
        }
    }

    private var centerReveal: some View {
        let size = surface.destinationRect.size
        return ZStack {
            CardMorphRevealImage(image: surface.image, revision: surface.imageRevision, layout: surface.imageLayout)
                .frame(width: size.width, height: size.height)
                .clipped()
                .mask { aperture(.image) }
                .opacity(imageOpacity)
            // The fixed-size native glass still samples the photograph in FRONT. Its moving
            // alpha aperture carries both the lens outline and the later clear opening.
            CardMorphFixedGlass()
                .frame(width: size.width, height: size.height)
                .mask { aperture(.glass) }
            aperture(.rim)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .position(x: surface.destinationRect.midX, y: surface.destinationRect.midY)
    }

    private func aperture(_ layer: CardMorphRevealLayer) -> some View {
        CardMorphRevealAperture(viewport: surface.destinationRect, origin: surface.revealOrigin,
                               layer: layer, progress: progress, contourProgress: contourProgress)
    }

    static func interpolate(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * progress,
               y: from.minY + (to.minY - from.minY) * progress,
               width: from.width + (to.width - from.width) * progress,
               height: from.height + (to.height - from.height) * progress)
    }
}

private struct CardMorphFixedGlass: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var body: some View {
        if reduceTransparency {
            Rectangle().fill(.background)
        } else if #available(macOS 26.0, *) {
            Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}

private enum CardMorphRevealLayer { case image, glass, rim }

private struct CardMorphRevealAperture: View, Animatable {
    let viewport: CGRect
    let origin: CGPoint?
    let layer: CardMorphRevealLayer
    nonisolated var progress: CGFloat
    nonisolated var contourProgress: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, contourProgress) }
        set { progress = newValue.first; contourProgress = newValue.second }
    }

    var body: some View {
        let geometry = CardMorphRevealGeometry(viewport: viewport, progress: progress,
                                              contourProgress: contourProgress, origin: origin)
        let reduceTransparency = reduceTransparency
        return Canvas { context, size in
            let rect = CGRect(x: geometry.lensCenter.x - geometry.lensSize.width * 0.5,
                              y: geometry.lensCenter.y - geometry.lensSize.height * 0.5,
                              width: geometry.lensSize.width, height: geometry.lensSize.height)
            let shape = RoundedRectangle(cornerRadius: geometry.radius, style: .continuous)
            let center = CGPoint(x: size.width * geometry.revealCenter.x, y: size.height * geometry.revealCenter.y)
            switch layer {
            case .image:
                context.opacity = geometry.imageOpacity
                context.clip(to: shape.inset(by: geometry.rim).path(in: rect))
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                    Gradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.70),
                                     .init(color: .clear, location: 1)]),
                    center: center, startRadius: 0, endRadius: geometry.imageRadius))
            case .glass:
                context.opacity = geometry.materialOpacity * geometry.glassCoverOpacity
                context.clip(to: shape.path(in: rect))
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                    Gradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.70),
                                     .init(color: .white, location: 1)]),
                    center: center, startRadius: 0, endRadius: geometry.glassClearRadius))
            case .rim:
                context.opacity = reduceTransparency ? 0 : geometry.edgeOpacity
                context.stroke(shape.inset(by: 0.6).path(in: rect), with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.7), .white.opacity(0.05), .white.opacity(0.3)]),
                    startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)), lineWidth: 1)
            }
        }
    }
}

private struct CardMorphLegacySurface: View, Animatable {
    let surface: WallpaperCardMorphCoordinator.Surface
    nonisolated var progress: CGFloat
    nonisolated var contourProgress: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, contourProgress) }
        set { progress = newValue.first; contourProgress = newValue.second }
    }
    var body: some View {
        let geometry = CardMorphFluidGeometry(surface: surface, progress: progress, contourProgress: contourProgress)
        let width = geometry.rect.width
        let height = geometry.rect.height
        let shape = CardMorphFluidShape(topCorner: geometry.topCorner, bottomCorner: geometry.bottomCorner,
                                        bend: geometry.bend, horizontalBias: geometry.horizontalBias,
                                        verticalBias: geometry.verticalBias)
        let rim = geometry.rim
        return ZStack {
            glassSurface(shape: shape)
            Image(nsImage: surface.image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
                // The photograph and live glass share the same deforming silhouette, so the
                // perimeter cannot detach into a rectangular border during the spring recoil.
                .clipShape(shape.inset(by: rim))
            shape.inset(by: 0.6)
                .stroke(LinearGradient(colors: [.white.opacity(0.46), .white.opacity(0.06), .white.opacity(0.24)],
                                       startPoint: geometry.highlightStart, endPoint: geometry.highlightEnd),
                        lineWidth: 0.8)
                .opacity(reduceTransparency ? 0 : geometry.lift)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.22 * geometry.lift), radius: 24 * geometry.lift, y: 9 * geometry.lift)
        .position(x: geometry.rect.midX, y: geometry.rect.midY)
    }

    @ViewBuilder
    private func glassSurface<S: Shape>(shape: S) -> some View {
        if reduceTransparency {
            shape.fill(.background)
        } else if #available(macOS 26.0, *) {
            GlassEffectContainer {
                shape.fill(.clear)
                    .glassEffect(.regular, in: shape)
            }
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

/// The aperture and photograph are deliberately separate: the photo is never scaled with the
/// lens, and a soft radial front makes its content emerge from the center behind the glass.
struct CardMorphRevealGeometry {
    let lensSize: CGSize
    let lensCenter: CGPoint
    let revealCenter: UnitPoint
    let radius: CGFloat
    let rim: CGFloat
    let imageRadius: CGFloat
    let imageOpacity: Double
    let materialOpacity: Double
    let glassClearRadius: CGFloat
    let glassCoverOpacity: Double
    let edgeOpacity: Double

    init(viewport: CGRect, progress: CGFloat, contourProgress: CGFloat, origin: CGPoint? = nil) {
        let p = min(1, max(0, progress))
        let c = min(1, max(0, contourProgress))
        let lag = min(0.18, max(-0.18, progress - contourProgress))
        func smooth(_ value: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
            let x = min(1, max(0, (value - from) / (to - from)))
            return x * x * (3 - 2 * x)
        }
        let opening = smooth(p, from: 0.03, to: 1)
        let settling = smooth(c, from: 0.68, to: 1)
        let diameter = min(76, max(44, min(viewport.width, viewport.height) * 0.11))
        let candidate = origin ?? CGPoint(x: viewport.midX, y: viewport.midY)
        let point = CGPoint(x: min(viewport.width, max(0, candidate.x - viewport.minX)),
                            y: min(viewport.height, max(0, candidate.y - viewport.minY)))
        // Keep the first droplet at the activation point. Its growing bounds gradually absorb
        // the viewport while the radial reveal remains anchored to the clicked cover.
        lensCenter = CGPoint(x: point.x + (viewport.width * 0.5 - point.x) * opening,
                             y: point.y + (viewport.height * 0.5 - point.y) * opening)
        revealCenter = UnitPoint(x: point.x / max(viewport.width, 1), y: point.y / max(viewport.height, 1))
        lensSize = CGSize(width: max(1, diameter + (viewport.width - diameter) * opening + lag * viewport.width * 0.06),
                          height: max(1, diameter + (viewport.height - diameter) * opening - lag * viewport.height * 0.04))
        let halfShort = min(lensSize.width, lensSize.height) * 0.5
        radius = halfShort * (1 - settling)
        rim = (1 - settling) * (5 + sin(p * .pi) * 9)
        let farthestCorner = hypot(max(point.x, viewport.width - point.x),
                                   max(point.y, viewport.height - point.y))
        let fullRadius = farthestCorner / 0.70 * 1.01
        let reveal = smooth(p, from: 0.34, to: 1)
        imageRadius = max(1, fullRadius * reveal)
        imageOpacity = Double(smooth(p, from: 0.29, to: 0.69))
        materialOpacity = Double(smooth(p, from: 0, to: 0.10))
        // Content can exist underneath while its clear opening is still tiny. Using the slower
        // contour response gives the foreground glass time to be seen, in both directions.
        let clarity = min(p, c)
        glassClearRadius = max(0.1, fullRadius * smooth(clarity, from: 0.64, to: 1))
        glassCoverOpacity = Double(1 - smooth(clarity, from: 0.965, to: 1))
        edgeOpacity = Double(smooth(p, from: 0, to: 0.09) * (1 - smooth(c, from: 0.83, to: 1)))
    }
}

private struct CardMorphRevealImage: View {
    let image: NSImage
    let revision: UInt
    let layout: CardMorphImageLayout
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                if layout == .portrait {
                    ZStack {
                        Color.black
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: width, height: height)
                            .scaleEffect(x: 2.25, y: 1.14)
                            .blur(radius: 84).saturation(1.12).brightness(-0.08)
                            .mask {
                                LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.22),
                                                       .init(color: .clear, location: 0.38), .init(color: .clear, location: 0.62),
                                                       .init(color: .white, location: 0.78), .init(color: .white, location: 1)],
                                               startPoint: .leading, endPoint: .trailing)
                            }
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .frame(width: width, height: height)
                            .shadow(color: .black.opacity(0.32), radius: 42, y: 18)
                    }.frame(width: width, height: height).clipped()
                } else {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                        .frame(width: width, height: height).clipped()
                }
            }
            .id(revision)
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.12), value: revision)
    }
}

/// Endpoint geometry is exact. Between endpoints the faster axis leads, the other catches up,
/// and the softer perimeter carries a small signed recoil. No timer, shader snapshot or blur pass.
struct CardMorphFluidGeometry {
    let rect: CGRect
    let lift: CGFloat
    let rim: CGFloat
    let topCorner: CGFloat
    let bottomCorner: CGFloat
    let bend: CGFloat
    let horizontalBias: CGFloat
    let verticalBias: CGFloat
    let highlightStart: UnitPoint
    let highlightEnd: UnitPoint

    init(surface: WallpaperCardMorphCoordinator.Surface, progress: CGFloat, contourProgress: CGFloat) {
        let p = min(1, max(0, progress))
        let c = min(1, max(0, contourProgress))
        let lag = min(0.22, max(-0.22, progress - contourProgress))
        let flight = sin(p * .pi)
        let energy = min(1, flight + abs(lag) * 3)
        let size = max(1, min(surface.destinationRect.width, surface.destinationRect.height))
        let dx = surface.destinationRect.midX - surface.sourceRect.midX
        let dy = surface.destinationRect.midY - surface.sourceRect.midY
        let horizontal = min(1, max(-1, dx / max(surface.destinationRect.width * 0.4, 1)))
        let vertical = min(1, max(-1, dy / max(surface.destinationRect.height * 0.4, 1)))
        // Separate axis response creates a brief squash/stretch without stretching the photo pixels.
        let widthProgress = p + lag * 0.16
        let heightProgress = p - lag * 0.12
        let width = max(1, surface.sourceRect.width + (surface.destinationRect.width - surface.sourceRect.width) * widthProgress)
        let height = max(1, surface.sourceRect.height + (surface.destinationRect.height - surface.sourceRect.height) * heightProgress)
        let centerProgress = p - lag * 0.06
        rect = CGRect(x: surface.sourceRect.midX + dx * centerProgress - width / 2,
                      y: surface.sourceRect.midY + dy * centerProgress - height / 2,
                      width: width, height: height)
        lift = energy
        rim = (min(7, size * 0.012) * flight + min(5, size * 0.009) * abs(lag) * 3)
        let rounding = min(42, size * 0.073) * energy
        topCorner = max(0, surface.sourceCornerRadius * (1 - c) + rounding)
        bottomCorner = rounding
        bend = min(13, size * 0.025) * min(1, max(-1, lag * 5))
        horizontalBias = horizontal
        verticalBias = vertical
        highlightStart = UnitPoint(x: 0.12 + 0.25 * p, y: 0)
        highlightEnd = UnitPoint(x: 0.9 - 0.2 * p, y: 1)
    }
}

/// Smooth edge curves bow with the material's velocity lag. Insets retain the same flow field
/// for the photograph mask and native glass, including the square-bottom source-card endpoint.
struct CardMorphFluidShape: InsettableShape {
    var topCorner: CGFloat
    var bottomCorner: CGFloat
    var bend: CGFloat
    var horizontalBias: CGFloat
    var verticalBias: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> Self {
        var result = self
        result.insetAmount += amount
        return result
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard box.width > 0, box.height > 0 else { return Path() }
        let maxRadius = min(box.width, box.height) * 0.45
        let top = min(maxRadius, max(0, topCorner - insetAmount))
        let bottom = min(maxRadius, max(0, bottomCorner - insetAmount))
        let b = min(min(box.width, box.height) * 0.06, abs(bend)) * (bend < 0 ? -1 : 1)
        let left = box.minX, right = box.maxX, upper = box.minY, lower = box.maxY
        let k: CGFloat = 0.55228475
        let topBow = b * (0.55 - verticalBias * 0.25)
        let bottomBow = b * (0.55 + verticalBias * 0.25)
        let leftBow = b * (0.55 - horizontalBias * 0.25)
        let rightBow = b * (0.55 + horizontalBias * 0.25)
        var path = Path()
        path.move(to: CGPoint(x: left + top, y: upper))
        path.addCurve(to: CGPoint(x: right - top, y: upper),
                      control1: CGPoint(x: left + top + (box.width - top * 2) / 3, y: upper - topBow),
                      control2: CGPoint(x: right - top - (box.width - top * 2) / 3, y: upper - topBow))
        path.addCurve(to: CGPoint(x: right, y: upper + top),
                      control1: CGPoint(x: right - top + k * top, y: upper),
                      control2: CGPoint(x: right, y: upper + top - k * top))
        path.addCurve(to: CGPoint(x: right, y: lower - bottom),
                      control1: CGPoint(x: right + rightBow, y: upper + top + (box.height - top - bottom) / 3),
                      control2: CGPoint(x: right + rightBow, y: lower - bottom - (box.height - top - bottom) / 3))
        path.addCurve(to: CGPoint(x: right - bottom, y: lower),
                      control1: CGPoint(x: right, y: lower - bottom + k * bottom),
                      control2: CGPoint(x: right - bottom + k * bottom, y: lower))
        path.addCurve(to: CGPoint(x: left + bottom, y: lower),
                      control1: CGPoint(x: right - bottom - (box.width - bottom * 2) / 3, y: lower + bottomBow),
                      control2: CGPoint(x: left + bottom + (box.width - bottom * 2) / 3, y: lower + bottomBow))
        path.addCurve(to: CGPoint(x: left, y: lower - bottom),
                      control1: CGPoint(x: left + bottom - k * bottom, y: lower),
                      control2: CGPoint(x: left, y: lower - bottom + k * bottom))
        path.addCurve(to: CGPoint(x: left, y: upper + top),
                      control1: CGPoint(x: left - leftBow, y: lower - bottom - (box.height - top - bottom) / 3),
                      control2: CGPoint(x: left - leftBow, y: upper + top + (box.height - top - bottom) / 3))
        path.addCurve(to: CGPoint(x: left + top, y: upper),
                      control1: CGPoint(x: left, y: upper + top - k * top),
                      control2: CGPoint(x: left + top - k * top, y: upper))
        path.closeSubpath()
        return path
    }
}

private struct CardMorphViewportProbe: NSViewRepresentable {
    let owner: WallpaperCardMorphCoordinator
    func makeNSView(context: Context) -> CardMorphViewportView {
        let view = CardMorphViewportView()
        view.owner = owner
        return view
    }
    func updateNSView(_ nsView: CardMorphViewportView, context: Context) {
        nsView.owner = owner
        nsView.scheduleReport()
    }
    static func dismantleNSView(_ nsView: CardMorphViewportView, coordinator: ()) {
        let owner = nsView.owner
        nsView.owner = nil
        DispatchQueue.main.async { [weak owner] in owner?.detachViewport(nsView) }
    }
}

private final class CardMorphViewportView: NSView {
    weak var owner: WallpaperCardMorphCoordinator?
    private var reportPending = false
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); scheduleReport() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleReport() }
    func scheduleReport() {
        guard !reportPending else { return }
        reportPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reportPending = false
            if self.window != nil { self.owner?.attachViewport(self) }
            else { self.owner?.detachViewport(self) }
        }
    }
}

private struct CardMorphInputShield: NSViewRepresentable {
    let owner: WallpaperCardMorphCoordinator
    func makeNSView(context: Context) -> CardMorphInputView {
        let view = CardMorphInputView()
        view.owner = owner
        return view
    }
    func updateNSView(_ nsView: CardMorphInputView, context: Context) { nsView.owner = owner }
}

private final class CardMorphInputView: NSView {
    weak var owner: WallpaperCardMorphCoordinator?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.settleForPointerActivation() }
    override func rightMouseDown(with event: NSEvent) { owner?.settleForPointerActivation() }
    override func otherMouseDown(with event: NSEvent) { owner?.settleForPointerActivation() }
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
