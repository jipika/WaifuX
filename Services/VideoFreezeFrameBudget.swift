import Foundation
import CoreGraphics

/// A freeze frame samples only visible pixels. Crop zoom and source resolution
/// must never increase the size of a CPU bitmap allocation.
enum VideoFreezeFrameBudget {
    static let maximumBytes = 16 * 1_024 * 1_024
    static let maximumDimension = 4_096
    static let bytesPerPixel = 4

    struct Allocation: Equatable, Sendable {
        let pixelWidth: Int
        let pixelHeight: Int
        var bytesPerRow: Int { pixelWidth * VideoFreezeFrameBudget.bytesPerPixel }
        var byteCount: Int { bytesPerRow * pixelHeight }
    }

    static func allocation(viewportSize: CGSize, backingScale: CGFloat) -> Allocation? {
        guard viewportSize.width.isFinite, viewportSize.height.isFinite,
              backingScale.isFinite, backingScale > 0,
              viewportSize.width > 1, viewportSize.height > 1 else { return nil }
        let desiredWidth = viewportSize.width * backingScale
        let desiredHeight = viewportSize.height * backingScale
        guard desiredWidth.isFinite, desiredHeight.isFinite,
              desiredWidth > 0, desiredHeight > 0 else { return nil }

        // Bound each dimension before multiplying, including malformed geometry.
        let dimensionScale = min(
            1,
            CGFloat(maximumDimension) / desiredWidth,
            CGFloat(maximumDimension) / desiredHeight
        )
        let boundedWidth = desiredWidth * dimensionScale
        let boundedHeight = desiredHeight * dimensionScale
        let area = boundedWidth * boundedHeight
        guard area.isFinite, area > 0 else { return nil }
        let maximumPixels = CGFloat(maximumBytes / bytesPerPixel)
        let areaScale = min(1, sqrt(maximumPixels / area))
        let width = max(1, Int((boundedWidth * areaScale).rounded(.down)))
        let height = max(1, Int((boundedHeight * areaScale).rounded(.down)))
        let allocation = Allocation(pixelWidth: width, pixelHeight: height)
        guard width <= maximumDimension, height <= maximumDimension,
              allocation.byteCount <= maximumBytes else { return nil }
        return allocation
    }
}
