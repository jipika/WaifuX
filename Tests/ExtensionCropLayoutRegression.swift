import CoreGraphics
import Foundation

@main
struct ExtensionCropLayoutRegression {
    static func main() {
        let sourceSize = CGSize(width: 1920, height: 1080)
        let laptopScreenSize = CGSize(width: 1600, height: 1000)
        let layout = ExtCropEngine.compute(
            wallpaperSize: sourceSize,
            screenSize: laptopScreenSize,
            settings: .default
        )

        precondition(approximatelyEqual(layout.viewportRect.x, 0))
        precondition(approximatelyEqual(layout.viewportRect.y, 0))
        precondition(approximatelyEqual(layout.viewportRect.w, 1))
        precondition(approximatelyEqual(layout.viewportRect.h, 1))
        precondition(approximatelyEqual(layout.wallpaperCropRect.x, 0.05))
        precondition(approximatelyEqual(layout.wallpaperCropRect.y, 0))
        precondition(approximatelyEqual(layout.wallpaperCropRect.w, 0.9))
        precondition(approximatelyEqual(layout.wallpaperCropRect.h, 1))

        let croppedAspect = (
            sourceSize.width * layout.wallpaperCropRect.w
        ) / (
            sourceSize.height * layout.wallpaperCropRect.h
        )
        precondition(approximatelyEqual(croppedAspect, laptopScreenSize.width / laptopScreenSize.height))

        print(
            "Extension crop regression passed: "
                + "crop=\(layout.wallpaperCropRect.x),"
                + "\(layout.wallpaperCropRect.y),"
                + "\(layout.wallpaperCropRect.w),"
                + "\(layout.wallpaperCropRect.h)"
        )
    }

    private static func approximatelyEqual(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        tolerance: CGFloat = 0.000_001
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
