import XCTest
import ImageIO
@testable import WaifuX

final class CropLayoutEngineTests: XCTestCase {

    func testPortraitBlurFillCreatesAndReusesMappedArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortraitBlurFillTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceURL = root.appendingPathComponent("source.png")
        try writeSolidImage(width: 300, height: 600, to: sourceURL)

        let derivedRoot = root.appendingPathComponent("DerivedWallpapers", isDirectory: true)
        let targetSize = CGSize(width: 1600, height: 900)
        let first = try await PortraitBlurFillWallpaperService.shared.preparedWallpaperURL(
            for: sourceURL,
            targetPixelSize: targetSize,
            derivedWallpapersDirectory: derivedRoot
        )
        let second = try await PortraitBlurFillWallpaperService.shared.preparedWallpaperURL(
            for: sourceURL,
            targetPixelSize: targetSize,
            derivedWallpapersDirectory: derivedRoot
        )

        XCTAssertNotEqual(first.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(first.standardizedFileURL, second.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try imageSize(at: first), targetSize)

        let mappingURL = derivedRoot
            .appendingPathComponent("PortraitBlurFill", isDirectory: true)
            .appendingPathComponent("mapping.json")
        let mapping = try String(contentsOf: mappingURL, encoding: .utf8)
        XCTAssertTrue(mapping.contains(sourceURL.standardizedFileURL.path))
    }

    func testPortraitBlurFillLeavesLandscapeSourceUntouched() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortraitBlurFillLandscapeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceURL = root.appendingPathComponent("source.png")
        try writeSolidImage(width: 600, height: 300, to: sourceURL)

        let result = try await PortraitBlurFillWallpaperService.shared.preparedWallpaperURL(
            for: sourceURL,
            targetPixelSize: CGSize(width: 1600, height: 900),
            derivedWallpapersDirectory: root.appendingPathComponent("DerivedWallpapers", isDirectory: true)
        )

        XCTAssertEqual(result.standardizedFileURL, sourceURL.standardizedFileURL)
    }

    private func writeSolidImage(width: Int, height: Int, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "CropLayoutEngineTests", code: 1)
        }
        context.setFillColor(CGColor(red: 0.15, green: 0.32, blue: 0.78, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  "public.png" as CFString,
                  1,
                  nil
              ) else {
            throw NSError(domain: "CropLayoutEngineTests", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "CropLayoutEngineTests", code: 3)
        }
    }

    private func imageSize(at url: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw NSError(domain: "CropLayoutEngineTests", code: 4)
        }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    private func assertRect(_ actual: UnitRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertEqual(actual.x, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.y, y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.w, w, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.h, h, accuracy: 1e-9, file: file, line: line)
    }

    func testAutoFillReturnsFullScreenAndCenteredCoverCrop() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .autoFill
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 3440, height: 1440),
            settings: s)
        assertRect(layout.viewportRect, 0, 0, 1, 1)
        XCTAssertEqual(layout.wallpaperCropRect.x, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.wallpaperCropRect.w, 1, accuracy: 1e-9)
        XCTAssertEqual(layout.wallpaperCropRect.h, 0.7441860465, accuracy: 1e-9)
        XCTAssertEqual(layout.wallpaperCropRect.y, 0.1279069767, accuracy: 1e-9)
    }

    /// 默认铺满（不改 pan）在 16:10 屏上居中裁 16:9，左右各切 5%。
    func testDefaultAutoFillIsCentered() {
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 3840, height: 2160),
            screenSize: CGSize(width: 1440, height: 900),
            settings: .defaultSettings)
        assertRect(layout.viewportRect, 0, 0, 1, 1)
        XCTAssertEqual(layout.wallpaperCropRect.x, 0.05, accuracy: 1e-6)
        XCTAssertEqual(layout.wallpaperCropRect.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(layout.wallpaperCropRect.w, 0.9, accuracy: 1e-6)
        XCTAssertEqual(layout.wallpaperCropRect.h, 1.0, accuracy: 1e-6)
    }

    func testAutoFillUsesRealWallpaperOverflowOnDifferentScreenAspect() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .autoFill
        s.pan = CGPoint(x: 0.5, y: 0.5)
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1440, height: 900),
            settings: s
        )

        // 16:9 内容铺满 16:10 屏幕高度后，左右各有 5% 可平移余量。
        assertRect(layout.viewportRect, 0, 0, 1, 1)
        XCTAssertEqual(layout.wallpaperCropRect.x, 0.05, accuracy: 1e-9)
        XCTAssertEqual(layout.wallpaperCropRect.y, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.wallpaperCropRect.w, 0.9, accuracy: 1e-9)
        XCTAssertEqual(layout.wallpaperCropRect.h, 1, accuracy: 1e-9)
    }

    func testAutoFillPanReachesBothHorizontalEdges() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .autoFill

        s.pan = CGPoint(x: 0, y: 0.5)
        let left = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1440, height: 900),
            settings: s
        )
        XCTAssertEqual(left.wallpaperCropRect.x, 0, accuracy: 1e-9)

        s.pan = CGPoint(x: 1, y: 0.5)
        let right = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1440, height: 900),
            settings: s
        )
        XCTAssertEqual(right.wallpaperCropRect.x, 0.1, accuracy: 1e-9)
    }

    func testCustomWithoutAspectFallsBackToScreenAspect() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .custom
        s.customAspect = nil
        s.pan = CGPoint(x: 0.5, y: 0.5)
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1440, height: 900),
            settings: s
        )

        assertRect(layout.viewportRect, 0, 0, 1, 1)
        XCTAssertEqual(layout.wallpaperCropRect.w, 0.9, accuracy: 1e-9)
        XCTAssertEqual(layout.wallpaperCropRect.h, 1, accuracy: 1e-9)
    }

    func testDisabledReturnsFullScreenAndFullCrop() {
        var s = DisplayCropSettings.defaultSettings
        s.isEnabled = false
        s.aspectPreset = .ratio16x9
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 3440, height: 1440),
            settings: s)
        assertRect(layout.viewportRect, 0, 0, 1, 1)
        assertRect(layout.wallpaperCropRect, 0, 0, 1, 1)
    }

    /// 21:9 壁纸在 21:9 屏选 21:9 预设 → 可视框=全屏，壁纸铺满无黑边。
    func testSameAspectAsScreenViewportIsFullScreen() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio21x9
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 2560, height: 1080),
            screenSize: CGSize(width: 3360, height: 1440),  // 屏精确 21:9 (3360/1440 = 21/9)
            settings: s)
        assertRect(layout.viewportRect, 0, 0, 1, 1)
        assertRect(layout.wallpaperCropRect, 0, 0, 1, 1)
    }

    /// 16:9 预设在 16:9 屏 → 可视框=全屏；壁纸 16:9 铺满框，裁切框=full。
    func testSixteenNineOnSixteenNineScreen() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio16x9
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: s)
        assertRect(layout.viewportRect, 0, 0, 1, 1)
        assertRect(layout.wallpaperCropRect, 0, 0, 1, 1)
    }

    /// 16:9 预设在 21:9 屏（屏更宽）→ 框高=1，框宽=screenAspect/targetAspect，左右黑边。
    func testSixteenNineOnUltrawideLetterboxLeftRight() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio16x9
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 3440, height: 1440),
            settings: s)
        let expectedW = (16.0/9.0) / (3440.0/1440.0)
        XCTAssertEqual(layout.viewportRect.y, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.viewportRect.h, 1, accuracy: 1e-9)
        XCTAssertEqual(layout.viewportRect.w, expectedW, accuracy: 1e-6)
        XCTAssertEqual(layout.viewportRect.x, (1 - expectedW) / 2, accuracy: 1e-6)
        assertRect(layout.wallpaperCropRect, 0, 0, 1, 1)
    }

    /// 21:9 预设在 16:9 屏（屏更窄）→ 框宽=1，框高=screenAspect/targetAspect，上下黑边。
    func testUltrawideOnSixteenNineLetterboxTopBottom() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio21x9
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 2560, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: s)
        let expectedH = (1920.0/1080.0) / (21.0/9.0)
        XCTAssertEqual(layout.viewportRect.x, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.viewportRect.w, 1, accuracy: 1e-9)
        XCTAssertEqual(layout.viewportRect.h, expectedH, accuracy: 1e-6)
        XCTAssertEqual(layout.viewportRect.y, (1 - expectedH) / 2, accuracy: 1e-6)
    }

    /// zoom=2 → 窗口尺寸减半（32:9 预设，垂直方向）。
    func testZoomHalvesCropSize() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio32x9
        s.zoom = 2.0
        s.pan = CGPoint(x: 0.5, y: 0.5)
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: s)
        // cover: 32:9 可视框 1920×540, 16:9 壁纸 1920×1080, zoom=2 → coverScale×2=2.0
        // 显示壁纸=3840×2160, winW=1920/3840=0.5, winH=540/2160=0.25
        XCTAssertEqual(layout.wallpaperCropRect.w, 0.5, accuracy: 1e-9)
        XCTAssertEqual(layout.wallpaperCropRect.h, 0.25, accuracy: 1e-9)
    }

    /// 回归：超宽壁纸（6600×3000, 2.2:1）选 32:9 预设 → 宽度撑满、上下裁切，
    /// crop 窗口必须在 [0,1] 内（cover 语义，不能 w>1 溢出）。
    /// 旧实现用宽高比分支推断 cover 方向，壁纸比可视框宽时误走 contain 分支算出 w=2.0，
    /// 导致 wgpu blit 采样超界、右侧素材被 ClampToEdge 拉伸。
    func testUltrawideWallpaperCoversNotContains() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio32x9
        s.zoom = 1.0
        s.pan = CGPoint(x: 0.5, y: 0.5)
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 6600, height: 3000),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: s)
        // cover: 壁纸宽度铺满可视框宽度 → crop.w = 1.0
        XCTAssertEqual(layout.wallpaperCropRect.w, 1.0, accuracy: 1e-6)
        // 高度方向裁切 → crop.h < 1.0
        // vp 像素 = 1920×540, coverScale = max(1920/6600, 540/3000) = 1920/6600
        // 显示壁纸高 = 3000 × 1920/6600 = 872.7, crop.h = 540/872.7 ≈ 0.61875
        XCTAssertEqual(layout.wallpaperCropRect.h, 0.61875, accuracy: 1e-4)
        // 居中：origin = (1 - h)/2
        XCTAssertEqual(layout.wallpaperCropRect.y, (1.0 - 0.61875) / 2.0, accuracy: 1e-4)
        // crop 窗口不得超出 [0,1]
        XCTAssertLessThanOrEqual(layout.wallpaperCropRect.w, 1.0)
        XCTAssertLessThanOrEqual(layout.wallpaperCropRect.h, 1.0)
    }

    /// 32:9 预设 + 16:9 壁纸：pan.y=0 看上方 → crop.y=0；pan.y=1 看下方 → crop.y=1-h。
    func testPanVerticalWithinWallpaper() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio32x9
        s.zoom = 1.0
        // cover: 32:9 可视框 1920×540, 16:9 壁纸 1920×1080
        // coverScale = max(1920/1920, 540/1080) = 1.0, 显示壁纸=1920×1080, winW=1, winH=540/1080=0.5
        s.pan = CGPoint(x: 0.5, y: 0)
        let l0 = CropLayoutEngine.compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s)
        XCTAssertEqual(l0.wallpaperCropRect.y, 0, accuracy: 1e-9)
        s.pan = CGPoint(x: 0.5, y: 1)
        let l1 = CropLayoutEngine.compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s)
        XCTAssertEqual(l1.wallpaperCropRect.y, 0.5, accuracy: 1e-9)
    }

    /// pan 超出 [0,1] 被 clamp 到边缘，窗口始终在壁纸内。
    func testPanClampsToEdges() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio1x1
        s.zoom = 1.0
        s.pan = CGPoint(x: -5, y: 5)
        // cover: 1:1 可视框 1080×1080, 16:9 壁纸 1920×1080
        // coverScale = max(1080/1920, 1080/1080) = 1.0, 显示壁纸=1920×1080, winW=1080/1920=0.5625, winH=1
        let layout = CropLayoutEngine.compute(wallpaperSize: CGSize(width:1920,height:1080), screenSize: CGSize(width:1920,height:1080), settings: s)
        XCTAssertEqual(layout.wallpaperCropRect.x, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.wallpaperCropRect.y, 0, accuracy: 1e-9)
    }

    /// zoom 下限 1.0、上限 4.0（窗口尺寸随 zoom 缩小）。
    func testZoomClampsToRange() {
        var sLow = DisplayCropSettings.defaultSettings
        sLow.aspectPreset = .ratio16x9
        sLow.zoom = 0.2
        let lLow = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: sLow)
        // 16:9 on 16:9 → vp=full, vpAspect=16/9, wpAspect=16/9 → winW=winH=1
        XCTAssertEqual(lLow.wallpaperCropRect.w, 1, accuracy: 1e-9)

        var sHigh = DisplayCropSettings.defaultSettings
        sHigh.aspectPreset = .ratio32x9
        sHigh.zoom = 10
        let lHigh = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 1920, height: 1080),
            settings: sHigh)
        // 32:9 vpAspect=2, wpAspect=16/9 < 2 → winW=1/4, winH=winW/2=0.125
        XCTAssertEqual(lHigh.wallpaperCropRect.w, 0.25, accuracy: 1e-9)
        XCTAssertEqual(lHigh.wallpaperCropRect.h, 0.125, accuracy: 1e-9)
    }

    func testLetterboxColorParsed() {
        var s = DisplayCropSettings.defaultSettings
        s.aspectPreset = .ratio16x9
        s.letterboxColorHex = "FF0000"
        let layout = CropLayoutEngine.compute(
            wallpaperSize: CGSize(width: 1920, height: 1080),
            screenSize: CGSize(width: 3440, height: 1440),
            settings: s)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        layout.letterboxColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1, accuracy: 1e-3)
        XCTAssertEqual(g, 0, accuracy: 1e-3)
        XCTAssertEqual(b, 0, accuracy: 1e-3)
    }
}
