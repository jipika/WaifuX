import SwiftUI
import Kingfisher

// MARK: - SwiftUI 媒体卡片

struct MediaCardView: View, @preconcurrency Equatable {
    let media: MediaItem
    let isFavorite: Bool
    let cardWidth: CGFloat
    /// 强制使用统一高度（用于 LazyVGrid 网格化布局）。设为 nil 时回退到按媒体自身比例计算。
    let forcedHeight: CGFloat?
    let onTap: (() -> Void)?

    init(
        media: MediaItem,
        isFavorite: Bool,
        cardWidth: CGFloat,
        forcedHeight: CGFloat? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.media = media
        self.isFavorite = isFavorite
        self.cardWidth = cardWidth
        self.forcedHeight = forcedHeight
        self.onTap = onTap
    }

    @State private var animatedProbeResult: AnimatedProbeResult?
    @State private var isHovered = false
    @Environment(\.coverGIFPlaybackHostActive) private var coverGIFPlaybackHostActive

    private let bottomBarHeight: CGFloat = 44
    private let cornerRadius: CGFloat = 16
    private let maxAnimatedGIFBytes = AnimatedImageProbeCache.defaultMaxAnimatedGIFBytes

    static func == (lhs: MediaCardView, rhs: MediaCardView) -> Bool {
        lhs.media.id == rhs.media.id &&
        lhs.isFavorite == rhs.isFavorite &&
        lhs.cardWidth == rhs.cardWidth &&
        lhs.forcedHeight == rhs.forcedHeight
    }

    private var effectiveAspectRatio: CGFloat {
        let raw = media.exactResolution ?? media.resolutionLabel
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "X", with: "x")
        let parts = raw.split(separator: "x")
        if parts.count == 2,
           let w = Double(parts[0]), w > 0,
           let h = Double(parts[1]), h > 0 {
            let aspect = CGFloat(w / h)
            return min(max(aspect, 0.35), 3.6)
        }
        return 1.6
    }

    private var imageHeight: CGFloat {
        if let forced = forcedHeight {
            return max(0, forced - bottomBarHeight)
        }
        let maxImageHeight: CGFloat = cardWidth * 1.8
        return min(cardWidth / effectiveAspectRatio, maxImageHeight)
    }

    private var cardHeight: CGFloat {
        forcedHeight ?? (imageHeight + bottomBarHeight)
    }

    private var staticDisplayURL: URL {
        media.coverImageURL
    }

    private var animatedDisplayURL: URL? {
        animatedProbeResult?.animatedURL
    }

    private var shouldAnimateGIF: Bool {
        isHovered && coverGIFPlaybackHostActive
    }

    /// 同步从 probe 缓存解析当前 candidate 列表 → 已缓存为 GIF 的 URL（若有）
    /// 没有命中或缓存里只有 false 时返回 nil。
    private var cachedAnimatedURL: URL? {
        for url in animatedProbeCandidates {
            if AnimatedImageProbeCache.shared.cachedIsAnimatedGIF(url, maxByteCount: maxAnimatedGIFBytes) == true {
                return url
            }
        }
        return nil
    }

    /// 全部 candidate 都已被探测过且全为 false → 不需要再发起异步 probe。
    private var allCandidatesProbedAsNonAnimated: Bool {
        let candidates = animatedProbeCandidates
        guard !candidates.isEmpty else { return true }
        for url in candidates {
            if AnimatedImageProbeCache.shared.cachedIsAnimatedGIF(url, maxByteCount: maxAnimatedGIFBytes) == nil {
                return false
            }
        }
        return true
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                coverImage
                    .frame(width: cardWidth, height: imageHeight)
                    .task(id: media.id) {
                        // 优化点 1：probe 缓存命中时直接同步设值，不发起异步任务也不抖动。
                        if let hitURL = cachedAnimatedURL {
                            if animatedProbeResult?.animatedURL != hitURL {
                                animatedProbeResult = AnimatedProbeResult(animatedURL: hitURL)
                            }
                            return
                        }
                        if allCandidatesProbedAsNonAnimated {
                            if animatedProbeResult?.animatedURL != nil {
                                animatedProbeResult = AnimatedProbeResult(animatedURL: nil)
                            }
                            return
                        }
                        // 优化点 2：未命中才走异步。**不再先把 animatedProbeResult 设为 nil**
                        // ——避免每次卡片 mount 都触发一次空 body 重算。
                        let result = await probeAnimatedImage()
                        guard !Task.isCancelled else { return }
                        if animatedProbeResult?.animatedURL != result.animatedURL {
                            animatedProbeResult = result
                        }
                    }

                bottomBar
                    .frame(height: bottomBarHeight)
            }
            .background(Color(hex: "1C2431"))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .mediaCardHoverShadow(isHovered: isHovered)

            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    Color.white.opacity(isHovered ? 0.18 : 0.06),
                    lineWidth: isHovered ? 1.25 : 1
                )

            badgesView
                .padding(10)
        }
        .frame(width: cardWidth, height: cardHeight)
        .contentShape(Rectangle())
        .mediaCardHoverScale(isHovered: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
        .zIndex(isHovered ? 1 : 0)
        .onTapGesture { onTap?() }
        // 内存压力下的 probe 重置已上提到 ViewModel/Bridge 层（参见 MediaCardMemoryBridge），
        // 此处不再在每张卡片注册 NotificationCenter 订阅 —— 滚动期间 mount/unmount
        // 反复创建/销毁数百个 Combine sink 是重要的性能开销点。
    }

    @ViewBuilder
    private var coverImage: some View {
        // ZStack 双层 GIF 播放方案（替代旧的自家 NativeGIFView 路径，已删除）：
        // - 底层 KFImage 静态封面**永不销毁**：消除从静态切到动画那一瞬的黑底闪烁。
        // - 顶层仅 `isHovered && detectedGIF` 时叠加 KFAnimatedImage；`id` 含 hover
        //   状态以触发 NSView 重建，确保 Kingfisher 的 `autoPlayAnimatedImage = true`
        //   真实生效（这是项目里 KFMediaCoverImage 验证过的模式）。
        // - 滚动经过 GIF 卡片：条件不成立 → KFAnimatedImage 不创建 → 零下载/解码。
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let targetSize = CGSize(
            width: min(Self.quantize(cardWidth * scale, step: 32), 1600),
            height: min(Self.quantize(imageHeight * scale, step: 32), 1600)
        )

        ZStack {
            // 底层：静态封面，始终存在，量化降采样以稳定 Kingfisher cache key。
            KFImage(staticDisplayURL)
                .setProcessor(DownsamplingImageProcessor(size: targetSize))
                .cacheMemoryOnly(false)
                .memoryCacheExpiration(.seconds(300))
                .fade(duration: 0.25)
                .placeholder { _ in Color.black.opacity(0.4) }
                .resizable()
                .scaledToFill()
                .frame(width: cardWidth, height: imageHeight)
                .clipped()

            // 顶层：仅在 hover + 已确认 GIF 时叠加 Kingfisher 的 AnimatedImageView 播放。
            // - 滚动经过 GIF 卡片不会触发任何下载/解码（条件不成立，view 不创建）。
            // - hover 触发后 `id` 包含 hover 状态，KFAnimatedImage 重建为新 NSView 并应用
            //   `autoPlayAnimatedImage = true`；首帧出来前底层 KFImage 仍可见，无黑底。
            if let animatedURL = animatedDisplayURL, isHovered {
                KFAnimatedImage.url(animatedURL)
                    .memoryCacheExpiration(.expired)
                    .diskCacheExpiration(.days(3))
                    .cancelOnDisappear(true)
                    .configure { view in
                        configureAnimatedGIFViewForAspectFill(view, autoPlay: shouldAnimateGIF)
                    }
                    .placeholder { _ in Color.clear }
                    .onFailure { _ in /* 静默失败：底层 KFImage 兜底 */ }
                    .id("\(animatedURL.absoluteString)|hover:\(isHovered)")
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardWidth, height: imageHeight)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isHovered)
    }

    private static func quantize(_ value: CGFloat, step: CGFloat) -> CGFloat {
        guard step > 0 else { return value }
        return ceil(value / step) * step
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(media.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isFavorite ? Color(hex: "FF5A7D") : .white.opacity(0.36))
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(Color(hex: "1A1D24"))
    }

    @ViewBuilder
    private var badgesView: some View {
        HStack(alignment: .top) {
            let firstTag = media.primaryTagText
            if !firstTag.isEmpty {
                badgeText(firstTag)
            }

            Spacer()

            let resLabel = media.resolutionLabel.replacingOccurrences(of: "x", with: "×")
            if !resLabel.isEmpty && resLabel != firstTag {
                badgeText(resLabel)
            }
        }
        .frame(width: max(0, cardWidth - 20), alignment: .topLeading)
    }

    private func badgeText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.82))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.3))
            )
    }

    private struct AnimatedProbeResult: Equatable {
        let animatedURL: URL?
    }

    private func probeAnimatedImage() async -> AnimatedProbeResult {
        for url in animatedProbeCandidates {
            guard !Task.isCancelled else { return AnimatedProbeResult(animatedURL: nil) }
            if await AnimatedImageProbeCache.shared.isAnimatedGIF(url, maxByteCount: maxAnimatedGIFBytes) {
                return AnimatedProbeResult(animatedURL: url)
            }
        }
        return AnimatedProbeResult(animatedURL: nil)
    }

    private var animatedProbeCandidates: [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        let candidates = [
            media.posterURLValue,
            Optional(media.thumbnailURLValue),
            Optional(media.coverImageURL)
        ]
        for optionalURL in candidates {
            guard let url = optionalURL else { continue }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

}

// MARK: - 性能优化：仅 hover 时挂阴影；scale + animation 永久挂载以保证平滑过渡
//
// ⚠️ scaleEffect / animation **不能**做条件挂载：
// 用 `@ViewBuilder if isHovered { scaleEffect(1.02) }` 会让 SwiftUI 看到"结构变化"，
// 它只能做默认 opacity transition、不会在 1.0 ↔ 1.02 之间插值，hover 动画就生硬跳变。
// 永久挂载 `.scaleEffect(isHovered ? 1.02 : 1.0)` 在非 hover 时是 identity transform，
// SwiftUI 会优化掉实际矩阵运算，开销可忽略；`.animation` 永久挂载只是登记 dependency。
//
// `.shadow` 是真正的 GPU 离屏 compositing 大头，仍按 hover-only 条件挂载。
private extension View {
    @ViewBuilder
    func mediaCardHoverShadow(isHovered: Bool) -> some View {
        if isHovered {
            self.shadow(color: Color.black.opacity(0.20), radius: 10, x: 0, y: 6)
        } else {
            self
        }
    }

    func mediaCardHoverScale(isHovered: Bool) -> some View {
        self
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(AppFluidMotion.hoverEase, value: isHovered)
    }
}
