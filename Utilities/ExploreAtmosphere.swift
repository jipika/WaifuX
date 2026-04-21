import SwiftUI
import AppKit
import Kingfisher
import Combine

// MARK: - 列表滚动时暂停 GIF（减轻 Lazy 列表滚动主线程压力；勿用于驱动全屏背景）

@MainActor
final class ExploreListGIFPlaybackState: ObservableObject {
    static let shared = ExploreListGIFPlaybackState()

    /// true 时 `KFMediaCoverImage` 只显示首帧，不跑 `KFAnimatedImage` 动画
    @Published private(set) var shouldPauseListGIFs = false
    /// 用 `DispatchWorkItem` 合并高频滚动回调，避免每帧 `Task` 创建/取消
    private var resumeGIFsWorkItem: DispatchWorkItem?

    /// 由 `ScrollLoadMoreModifier` 在滚动偏移变化时调用；滚动中仅第一次切到暂停态会触发刷新，恢复前用 debounce 合并
    func noteListScrolling() {
        if !shouldPauseListGIFs {
            shouldPauseListGIFs = true
        }
        resumeGIFsWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.shouldPauseListGIFs {
                self.shouldPauseListGIFs = false
            }
        }
        resumeGIFsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }
}

// MARK: - 探索页氛围色（背景光斑 + 液态玻璃主题色）

struct ExploreAtmosphereTint {
    var primary: Color
    var secondary: Color
    var tertiary: Color
    var baseTop: Color
    var baseBottom: Color

    static let wallpaperFallback = ExploreAtmosphereTint(
        primary: Color(hex: "5A7CFF"),
        secondary: Color(hex: "8A5CFF"),
        tertiary: Color(hex: "20C1FF"),
        baseTop: Color(hex: "1D2128"),
        baseBottom: Color(hex: "0E1116")
    )

    static let mediaFallback = ExploreAtmosphereTint(
        primary: Color(hex: "20C1FF"),
        secondary: Color(hex: "6D42FF"),
        tertiary: Color(hex: "2EE6A6"),
        baseTop: Color(hex: "1D2128"),
        baseBottom: Color(hex: "0E1116")
    )

    static func fromWallpaperMetadata(_ wallpaper: Wallpaper) -> ExploreAtmosphereTint {
        let palette = HeroDrivenPalette(wallpaper: wallpaper)
        return ExploreAtmosphereTint(
            primary: palette.primary,
            secondary: palette.secondary,
            tertiary: palette.tertiary,
            baseTop: Color(hex: "1D2128"),
            baseBottom: Color(hex: "0E1116")
        )
    }

    static func fromSampledTriplet(_ a: Color, _ b: Color, _ c: Color) -> ExploreAtmosphereTint {
        ExploreAtmosphereTint(
            primary: a,
            secondary: b,
            tertiary: c,
            baseTop: Color(hex: "1D2128"),
            baseBottom: Color(hex: "0E1116")
        )
    }
}

// MARK: - Environment（子视图同步主题色）

private struct ExplorePageAtmosphereTintKey: EnvironmentKey {
    static let defaultValue = ExploreAtmosphereTint.wallpaperFallback
}

extension EnvironmentValues {
    var explorePageAtmosphereTint: ExploreAtmosphereTint {
        get { self[ExplorePageAtmosphereTintKey.self] }
        set { self[ExplorePageAtmosphereTintKey.self] = newValue }
    }
}

// MARK: - Tab 后台时停列表 GIF（keep-alive 下 opacity=0 仍可能解码动画）

private struct CoverGIFPlaybackHostActiveKey: EnvironmentKey {
    /// 主窗口里当前 Tab 是否为该子树所属页（false 时 `KFMediaCoverImage` 强制不播 GIF）
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    /// 由 `ContentView` 按 `selectedTab` 注入；弹窗/详情未设置时默认为 `true`。
    var coverGIFPlaybackHostActive: Bool {
        get { self[CoverGIFPlaybackHostActiveKey.self] }
        set { self[CoverGIFPlaybackHostActiveKey.self] = newValue }
    }
}

// MARK: - 缩略图三色采样（左/中/右条带平均）

enum ExploreImageColorSampler {
    /// 从图片采样三色
    /// - Parameter image: 要采样的图片
    static func triplet(from image: NSImage) -> (Color, Color, Color)? {
        let pixelWidth: CGFloat = 48
        let pixelHeight: CGFloat = 48
        let size = NSSize(width: pixelWidth, height: pixelHeight)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelWidth),
            pixelsHigh: Int(pixelHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()

        let drawRect = NSRect(origin: .zero, size: size)
        let sourceRect: NSRect = .zero

        image.draw(
            in: drawRect,
            from: sourceRect,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let bpp = max(rep.bitsPerPixel / 8, 4)

        func average(in rect: (x: Int, y: Int, width: Int, height: Int)) -> (Double, Double, Double) {
            var r: Double = 0
            var g: Double = 0
            var b: Double = 0
            var n: Double = 0
            let x1 = max(0, rect.x)
            let y1 = max(0, rect.y)
            let x2 = min(w, rect.x + rect.width)
            let y2 = min(h, rect.y + rect.height)
            for y in y1..<y2 {
                for x in x1..<x2 {
                    let o = (y * w + x) * bpp
                    guard o + 2 < rep.bytesPerRow * h else { continue }
                    r += Double(data[o])
                    g += Double(data[o &+ 1])
                    b += Double(data[o &+ 2])
                    n += 1
                }
            }
            guard n > 0 else { return (0.15, 0.15, 0.18) }
            return (r / n / 255, g / n / 255, b / n / 255)
        }

        let colW = max(1, w / 3)
        let a1 = boost(average(in: (0, 0, colW, h)))
        let a2 = boost(average(in: (colW, 0, colW, h)))
        let a3 = boost(average(in: (colW * 2, 0, w - colW * 2, h)))

        return (color(from: a1), color(from: a2), color(from: a3))
    }

    private static func boost(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let mx = max(rgb.0, rgb.1, rgb.2)
        let mn = min(rgb.0, rgb.1, rgb.2)
        if mx - mn < 0.07 {
            return (
                min(1, rgb.0 * 0.55 + mx * 0.45),
                min(1, rgb.1 * 0.55 + mx * 0.45),
                min(1, rgb.2 * 0.55 + mx * 0.45)
            )
        }
        return (
            min(1, rgb.0 * 0.85 + mx * 0.15),
            min(1, rgb.1 * 0.85 + mx * 0.15),
            min(1, rgb.2 * 0.85 + mx * 0.15)
        )
    }

    private static func color(from rgb: (Double, Double, Double)) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

// MARK: - 氛围底图用缩略 NSImage（降低全屏 blur 的像素与内存）

extension NSImage {
    /// 限制最大边长（点），供 `ExploreDynamicAtmosphereBackground` 做大面积模糊用，避免对原图全尺寸 blur。
    func constrainedForAtmosphereBackdrop(maxEdge: CGFloat = 256) -> NSImage {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return self }
        let longest = max(w, h)
        guard longest > maxEdge else { return self }
        let scale = maxEdge / longest
        let nw = max(1, floor(w * scale))
        let nh = max(1, floor(h * scale))
        let newSize = NSSize(width: nw, height: nh)
        let img = NSImage(size: newSize)
        img.lockFocus()
        defer { img.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .low
        draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: NSSize(width: w, height: h)),
            operation: .copy,
            fraction: 1
        )
        return img
    }
}

// MARK: - 控制器（首张卡片缩略图 + 采样）

@MainActor
final class ExploreAtmosphereController: ObservableObject {
    @Published private(set) var tint: ExploreAtmosphereTint
    @Published private(set) var referenceImage: NSImage?

    private var loadTask: Task<Void, Never>?
    private let wallpaperMode: Bool
    /// 避免列表刷新但首张未变时重复拉缩略图、重复采样
    private var activeFirstItemKey: String?
    private var cancellables = Set<AnyCancellable>()

    init(wallpaperMode: Bool) {
        self.wallpaperMode = wallpaperMode
        self.tint = wallpaperMode ? .wallpaperFallback : .mediaFallback
        
        // 监听应用隐藏窗口通知，清理大内存占用（异步执行避免卡顿）
        NotificationCenter.default.publisher(for: .appDidHideWindow)
            .sink { [weak self] _ in
                // 使用低优先级队列异步执行
                Task(priority: .background) { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000) // 0.05秒延迟
                    self?.clearMemory()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        loadTask?.cancel()
        // cancellables 会自动释放，无需手动清理
    }
    
    /// 清理大内存占用，但保留颜色主题
    func clearMemory() {
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil
        // 不重置 activeFirstItemKey，这样重新打开窗口时不会重复加载同一张图
    }

    func resetToFallback() {
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil
        activeFirstItemKey = nil
        tint = wallpaperMode ? .wallpaperFallback : .mediaFallback
    }

    func updateFirstWallpaper(_ wallpaper: Wallpaper?) {
        guard let wallpaper else {
            resetToFallback()
            return
        }

        let key = "w:\(wallpaper.id)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key

        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        tint = ExploreAtmosphereTint.fromWallpaperMetadata(wallpaper)

        guard let url = wallpaper.thumbURL ?? wallpaper.smallThumbURL else { return }

        loadTask = Task {
            let result = try? await KingfisherManager.shared.retrieveImage(with: .network(url))
            guard !Task.isCancelled, let image = result?.image else { return }

            let processed = await Task.detached(priority: .userInitiated) {
                let small = image.constrainedForAtmosphereBackdrop()
                let sampledColors = ExploreImageColorSampler.triplet(from: small)
                return (small, sampledColors)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.referenceImage = processed.0
                if let (c1, c2, c3) = processed.1 {
                    self.tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }

    func updateFirstMedia(_ item: MediaItem?) {
        guard let item else {
            resetToFallback()
            return
        }

        let key = "m:\(item.id)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key

        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        tint = .mediaFallback
        let url = item.coverImageURL

        loadTask = Task {
            let result = try? await KingfisherManager.shared.retrieveImage(with: .network(url))
            guard !Task.isCancelled, let image = result?.image else { return }

            let processed = await Task.detached(priority: .userInitiated) {
                let small = image.constrainedForAtmosphereBackdrop()
                let sampledColors = ExploreImageColorSampler.triplet(from: small)
                return (small, sampledColors)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.referenceImage = processed.0
                if let (c1, c2, c3) = processed.1 {
                    self.tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }

    func updateFirstAnime(coverURL: String) {
        guard !coverURL.isEmpty else {
            resetToFallback()
            return
        }

        let key = "a:\(coverURL)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        tint = .mediaFallback

        guard let url = URL(string: coverURL) else { return }

        loadTask = Task {
            let result = try? await KingfisherManager.shared.retrieveImage(with: .network(url))
            guard !Task.isCancelled, let image = result?.image else { return }

            let processed = await Task.detached(priority: .userInitiated) {
                let small = image.constrainedForAtmosphereBackdrop()
                let sampledColors = ExploreImageColorSampler.triplet(from: small)
                return (small, sampledColors)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.referenceImage = processed.0
                if let (c1, c2, c3) = processed.1 {
                    self.tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }
}

// MARK: - 胶片噪点平铺（Arc 类质感，生成一次复用）

// MARK: - 全局胶片噪点纹理

enum GrainTextureTile {
    /// 胶片颗粒：避开「贴在中灰」——softLight 对 128 附近几乎无变化，改用更宽的明暗变化才看得见。
    static let image: NSImage = {
        let w = 256
        let h = 256
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: w,
                pixelsHigh: h,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let data = rep.bitmapData
        else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for y in 0..<h {
            for x in 0..<w {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                let u = UInt32(truncatingIfNeeded: state >> 33)
                // 约 55–200 的亮度跨度，叠 softLight/overlay 时才有可感颗粒
                let v = UInt8(clamping: 55 + Int(u % 146))
                let o = (y * w + x) * 4
                data[o] = v
                data[o + 1] = v
                data[o + 2] = v
                data[o + 3] = 255
            }
        }
        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(rep)
        return img
    }()
}

// MARK: - 全局颗粒材质覆盖层（支持开关和轻量模式）

struct GrainTextureOverlay: View {
    @State private var enabled = true
    @State private var quality = "high"
    var lightweight: Bool = false
    /// `UserDefaults.didChange` 触发极频繁，合并读取避免主线程反复刷新整层叠加
    @State private var settingsReadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if enabled && quality != "off" {
                let isLightweight = lightweight || quality == "low"

                Image(nsImage: GrainTextureTile.image)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(isLightweight ? 0.15 : 0.35)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .onAppear(perform: readSettings)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            scheduleReadSettings()
        }
    }

    private func scheduleReadSettings() {
        settingsReadTask?.cancel()
        settingsReadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            readSettings()
        }
    }

    private func readSettings() {
        enabled = UserDefaults.standard.object(forKey: "grain_texture_enabled") as? Bool ?? true
        quality = UserDefaults.standard.string(forKey: "grain_texture_quality") ?? "high"
    }
}

// MARK: - 动态背景：散色模糊底图 + 原有氛围渐变 + 轻磨砂 + 噪点

struct ExploreDynamicAtmosphereBackground: View {
    let tint: ExploreAtmosphereTint
    let referenceImage: NSImage?
    /// 快速滚动时减轻效果，避免卡顿
    var lightweightBackdrop: Bool = false

    // 预计算颜色值（避免 body 中重复创建 Color 结构体）
    private var primaryColor: Color { tint.primary }
    private var secondaryColor: Color { tint.secondary }
    private var tertiaryColor: Color { tint.tertiary }
    private var baseTopColor: Color { tint.baseTop }

    var body: some View {
        ZStack {
            // 基础氛围背景
            LiquidGlassAtmosphereBackground(
                primary: primaryColor,
                secondary: secondaryColor,
                tertiary: tertiaryColor,
                baseTop: baseTopColor,
                baseBottom: tint.baseBottom
            )

            // 参考图片模糊背景（轻量模式时完全禁用）
            if !lightweightBackdrop, let referenceImage {
                // 参考图已在控制器中压到最长边约 256pt，此处用适中 blur 即可铺满视觉，避免对大图做超大半径模糊
                Image(nsImage: referenceImage)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 160, minHeight: 160)
                    .blur(radius: 32)
                    .opacity(0.2)
                    .saturation(1.05)
                    .allowsHitTesting(false)
            }

            // 简化：合并径向渐变效果
            RadialGradient(
                colors: [
                    primaryColor.opacity(lightweightBackdrop ? 0.06 : 0.08),
                    secondaryColor.opacity(lightweightBackdrop ? 0.03 : 0.04),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: lightweightBackdrop ? 200 : 300
            )
            .allowsHitTesting(false)

            // 移除材质层，使用纯色替代
            Rectangle()
                .fill(baseTopColor.opacity(0.05))
                .allowsHitTesting(false)

            // 底部渐变遮罩
            LinearGradient(
                colors: [
                    Color.clear,
                    tint.baseBottom.opacity(0.3)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

// MARK: - Kingfisher 列表降采样

extension KFImage {
    /// 列表/卡片传入 `cardSize * 2` 等，避免 GIF/大图按全分辨率在主线程解码。
    fileprivate func wh_optionalDownsample(_ size: CGSize?) -> KFImage {
        guard let size else { return self }
        return setProcessor(DownsamplingImageProcessor(size: size))
    }
}

extension KFAnimatedImage {
    fileprivate func wh_optionalDownsample(_ size: CGSize?) -> KFAnimatedImage {
        guard let size else { return self }
        return setProcessor(DownsamplingImageProcessor(size: size))
    }
}

// MARK: - 媒体封面（静态 / GIF统一加载 + 失败占位）

/// 列表/首页封面：底层始终有色块/渐变，避免加载失败时出现空白或系统错误图。
/// 统一使用 `KFAnimatedImage`：Kingfisher 内部会解析真实文件格式，
/// GIF 自动走动画管线，静态图则回退到普通 ImageView 行为，无需外部根据 URL 预判断。
struct KFMediaCoverImage: View {
    @ObservedObject private var listGIFPlayback = ExploreListGIFPlaybackState.shared
    @Environment(\.coverGIFPlaybackHostActive) private var coverGIFPlaybackHostActive

    let url: URL
    var animated: Bool
    /// 非 nil 时对 **KFImage / KFAnimatedImage** 解码做降采样（列表/卡片必传，显著减轻 Workshop GIF 全尺寸主线程解码）。
    var downsampleSize: CGSize? = nil
    var fadeDuration: Double = 0.25
    /// 任意一次加载结束（成功或失败）时调用，用于详情页淡入等。
    var loadFinished: (() -> Void)? = nil
    /// 列表/卡片必须传入，约束 `KFAnimatedImage`（AppKit）按 GIF 原始尺寸撑开父布局的问题。
    var layoutSize: CGSize? = nil
    /// 是否允许播放 GIF 动画；详情页等大图建议 true。
    var playAnimatedImage: Bool = false
    /// 当前卡片/视图是否在视口内；非「仅悬停播放」模式下，离屏时停动画。
    var isVisible: Bool = true
    /// `true` 时仅在 `isHovered == true` 时解码播放 GIF（列表/网格推荐，显著减轻滚动时主线程压力）。
    var animateOnHoverOnly: Bool = false
    /// 配合 `animateOnHoverOnly`；由卡片 `onHover` / `throttledHover` 传入。
    var isHovered: Bool = false

    @State private var detectedGIF = false
    @State private var loadFailed = false

    private var shouldAnimate: Bool {
        guard playAnimatedImage, coverGIFPlaybackHostActive else { return false }
        if animateOnHoverOnly {
            return isHovered
        }
        return isVisible && !listGIFPlayback.shouldPauseListGIFs
    }

    /// `KFAnimatedImage` 的 `configure` 在 SwiftUI 更新时不一定会同步到已有 NSView；仅悬停播放时让 `id` 随悬停变化以强制重建并应用 `autoPlayAnimatedImage`。
    private var kfAnimatedLayerIdentity: String {
        if animateOnHoverOnly {
            "\(url.absoluteString)|hover:\(isHovered)"
        } else {
            url.absoluteString
        }
    }

    private var underlay: some View {
        LinearGradient(
            colors: [
                Color(hex: "1C2431"),
                Color(hex: "233B5A"),
                Color(hex: "14181F")
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        let core = ZStack {
            underlay
            // 1. 底层始终用 KFImage 加载，保证静态图和 GIF 首帧都能显示
            KFImage(url)
                .wh_optionalDownsample(downsampleSize)
                .cacheMemoryOnly(false)
                .cancelOnDisappear(true)
                .fade(duration: fadeDuration)
                .placeholder { _ in underlay }
                .onSuccess { result in
                    // GIF 判定：优先解码结果；降采样后静态图会丢失 `gifRepresentation`，回退到模型/URL 的 `animated` 提示
                    if !detectedGIF {
                        if result.image.kf.gifRepresentation() != nil {
                            detectedGIF = true
                        } else if animated {
                            detectedGIF = true
                        }
                    }
                    loadFinished?()
                }
                .onFailure { _ in loadFinished?() }
                .resizable()
                .aspectRatio(contentMode: .fill)

            // 2. 若真实格式为 GIF 且允许动画，叠加 KFAnimatedImage 播放动效
            if detectedGIF && !loadFailed {
                KFAnimatedImage.url(url)
                    .wh_optionalDownsample(downsampleSize)
                    .cacheMemoryOnly(false)
                    .cancelOnDisappear(true)
                    .configure { view in
                        #if os(macOS)
                        view.imageScaling = NSImageScaling.scaleAxesIndependently
                        #elseif canImport(UIKit)
                        view.contentMode = .scaleAspectFill
                        view.clipsToBounds = true
                        #endif
                        view.autoPlayAnimatedImage = shouldAnimate
                        // 列表内降低预加载帧数，减轻解码与内存峰值
                        view.framePreloadCount = shouldAnimate ? 4 : 1
                    }
                    .placeholder { _ in underlay }
                    .onSuccess { _ in loadFinished?() }
                    .onFailure { _ in
                        loadFailed = true
                        loadFinished?()
                    }
                    // 非「仅悬停」模式：仅用 URL 稳定身份，滚动暂停 GIF 时靠 `@ObservedObject` + configure 更新。
                    // 「仅悬停」模式：`id` 必须随 `isHovered` 变化，否则 AppKit 侧不会响应 `autoPlayAnimatedImage` 切换。
                    .id(kfAnimatedLayerIdentity)
            }
        }

        Group {
            if let s = layoutSize {
                core.frame(width: s.width, height: s.height).clipped()
            } else {
                core
            }
        }
    }
}

/// 兼容旧调用点：等价于 `KFMediaCoverImage(url:animated:true)` 。
struct KingfisherGIFImage: View {
    let url: URL

    var body: some View {
        KFMediaCoverImage(
            url: url,
            animated: true,
            downsampleSize: nil,
            fadeDuration: 0.2,
            loadFinished: nil,
            layoutSize: nil,
            playAnimatedImage: true,
            isVisible: true,
            animateOnHoverOnly: false,
            isHovered: false
        )
    }
}
