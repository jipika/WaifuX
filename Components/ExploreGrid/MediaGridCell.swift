import AppKit
import Kingfisher

/// 媒体网格 Cell — 对齐 SwiftUI `MediaCardView` 的视觉结构
/// - 16:10 图片区域（整卡 16pt 圆角裁切）
/// - 左侧标签 / 右侧分辨率胶囊
/// - 底部实心标题栏 + 收藏心形（SF Symbol）
/// - hover：1.02 缩放 + 边框提亮 + 投影 + GIF 封面动画播放
final class MediaGridCell: ExploreGridItem {

    static let newReuseIdentifier = NSUserInterfaceItemIdentifier("MediaGridCell")

    private enum Layout {
        static let outerCornerRadius: CGFloat = 16
        static let bottomBarHeight: CGFloat = 44
        static let overlayPadding: CGFloat = 10
        static let badgeSpacing: CGFloat = 6
        static let bottomHorizontalPadding: CGFloat = 14
        static let heartSymbolSize: CGFloat = 13
    }

    static let imageAspectRatio: CGFloat = 1.6
    private static let maxDecodeEdge: CGFloat = 1600
    private static let minDecodeEdge: CGFloat = 640
    private static let maxAnimatedGIFBytes: Int64 = 32 * 1024 * 1024
    private static let maxAnimatedGIFPixelCount = 32_000_000
    private static let maxAnimatedGIFFrameCount = Int.max
    private var currentMedia: MediaItem?

    private let bottomBar: NSView = {
        let view = NSView()
        view.wantsLayer = true
        // 与 MediaCardView 底栏同色（实心，非半透明）
        view.layer?.backgroundColor = NSColor(hexString: "1A1D24").cgColor
        return view
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    /// 收放心形：SF Symbol，对齐 SwiftUI 卡片 Image(systemName: "heart"/"heart.fill")
    private let heartImageView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = NSColor.white.withAlphaComponent(0.36)
        return view
    }()

    private let leadingTagBadge = MediaMetaBadgeView()
    private let trailingBadge = MediaMetaBadgeView()

    // MARK: - hover GIF 播放状态

    /// 已探测出的 GIF 源（item 级缓存，二次 hover 免探测）
    private var resolvedGIFURL: URL?
    private var resolvedGIFItemID: String?
    /// 已取回的 GIF 原始数据（item 级缓存，二次 hover 免下载）
    private var resolvedGIFData: Data?
    /// hover 触发的异步探测 / 取数任务
    private var hoverGIFFetchTask: Task<Void, Never>?
    private var shouldRestoreHoverAfterConfigure = false

    override var hoverScaleFactor: CGFloat { 1.02 }
    override var shouldAnimateBorderOnHover: Bool { true }
    override var shouldShowShadowOnHover: Bool { true }
    override var usesGIFOverlay: Bool { true }

    override func setupContentLayout() {
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(Layout.outerCornerRadius)
        setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.06))

        contentView.translatesAutoresizingMaskIntoConstraints = true
        bottomBar.translatesAutoresizingMaskIntoConstraints = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        heartImageView.translatesAutoresizingMaskIntoConstraints = true
        leadingTagBadge.translatesAutoresizingMaskIntoConstraints = true
        trailingBadge.translatesAutoresizingMaskIntoConstraints = true

        contentView.addSubview(bottomBar)
        bottomBar.addSubview(titleLabel)
        bottomBar.addSubview(heartImageView)

        contentView.addSubview(leadingTagBadge)
        contentView.addSubview(trailingBadge)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentMedia = nil
        titleLabel.stringValue = ""
        updateHeartSymbol(isFavorite: false)
        leadingTagBadge.isHidden = true
        trailingBadge.isHidden = true
        teardownHoverGIFPlayback()
        resolvedGIFURL = nil
        resolvedGIFItemID = nil
        resolvedGIFData = nil
        lastImageTargetSize = .zero
    }

    override func configure(with item: Any, isFavorite: Bool) {
        guard let media = item as? MediaItem else { return }
        // 复用 cell 换了数据：先停掉旧 hover GIF 播放与探测缓存
        if currentMedia?.id != media.id {
            shouldRestoreHoverAfterConfigure = isHovered
            teardownHoverGIFPlayback()
            resolvedGIFURL = nil
            resolvedGIFItemID = nil
            resolvedGIFData = nil
        } else {
            shouldRestoreHoverAfterConfigure = false
        }
        currentMedia = media

        titleLabel.stringValue = media.title
        updateHeartSymbol(isFavorite: isFavorite)

        let firstTag = media.tags.lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        leadingTagBadge.configure(text: firstTag)
        leadingTagBadge.isHidden = firstTag == nil

        let resolutionText = media.resolutionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let showResolution = !resolutionText.isEmpty && resolutionText != firstTag
        trailingBadge.configure(text: showResolution ? resolutionText : nil)
        trailingBadge.isHidden = !showResolution

        let targetSize = preferredImageTargetSize(for: media)
        lastImageTargetSize = targetSize
        // preferGIFMiddleFrame：poster 本身是 GIF 时静态封面取中间帧，
        // 避免「前几帧全黑」的动图在非 hover 态常驻一张黑图。
        loadImage(urls: preferredImageURLs(for: media), targetSize: targetSize, preferGIFMiddleFrame: true)

        if containerView.bounds.width > 0, containerView.bounds.height > 0 {
            layoutContentFrames()
        } else {
            view.needsLayout = true
            containerView.needsLayout = true
            contentView.needsLayout = true
        }

        if shouldRestoreHoverAfterConfigure, allowsHoverInteraction {
            shouldRestoreHoverAfterConfigure = false
            hoverStateDidChange(true)
        }
    }

    override func layoutContentFrames() {
        let bounds = containerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        contentView.frame = bounds

        let imageHeight = max(0, bounds.height - Layout.bottomBarHeight)
        // 平面设计：图片区不做独立圆角，整卡由 containerView 的 16pt 圆角统一裁切
        coverImageView.frame = CGRect(x: 0, y: Layout.bottomBarHeight, width: bounds.width, height: imageHeight)
        coverImageView.layer?.cornerRadius = 0
        coverImageView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        coverImageView.layer?.backgroundColor = NSColor(hexString: "1C2431").cgColor

        bottomBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.bottomBarHeight)

        let heartSize = CGSize(width: Layout.heartSymbolSize, height: Layout.heartSymbolSize)
        heartImageView.frame = CGRect(
            x: bounds.width - Layout.bottomHorizontalPadding - heartSize.width,
            y: floor((Layout.bottomBarHeight - heartSize.height) / 2),
            width: heartSize.width,
            height: heartSize.height
        ).integral

        titleLabel.frame = CGRect(
            x: Layout.bottomHorizontalPadding,
            y: floor((Layout.bottomBarHeight - 16) / 2),
            width: max(0, heartImageView.frame.minX - Layout.bottomHorizontalPadding - 12),
            height: 16
        ).integral

        layoutTopBadges(in: bounds)

        // bounds 从占位尺寸变为真实尺寸时按新目标重载，避免一直用 minDecodeEdge 的糊图
        if let media = currentMedia {
            let targetSize = preferredImageTargetSize(for: media)
            let sizeGrew =
                targetSize.width > lastImageTargetSize.width + 24
                || targetSize.height > lastImageTargetSize.height + 24
            if sizeGrew {
                lastImageTargetSize = targetSize
                loadImage(urls: preferredImageURLs(for: media), targetSize: targetSize, preferGIFMiddleFrame: true)
            }
        }
    }

    private func updateHeartSymbol(isFavorite: Bool) {
        let symbolName = isFavorite ? "heart.fill" : "heart"
        let configuration = NSImage.SymbolConfiguration(
            pointSize: Layout.heartSymbolSize,
            weight: .bold
        )
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        heartImageView.image = base?.withSymbolConfiguration(configuration)
        heartImageView.contentTintColor = isFavorite
            ? NSColor(hexString: "FF5A7D")
            : NSColor.white.withAlphaComponent(0.36)
    }

    // MARK: - Hover GIF

    override func hoverStateDidChange(_ hovering: Bool) {
        if hovering {
            startHoverGIFPlaybackIfNeeded()
        } else {
            // 停止播放并释放 GIF 原始数据（大 GIF 可达数十 MB，连续 hover 多卡时会累积）；
            // 已探测的 URL 保留，再次 hover 命中 Kingfisher 磁盘缓存，无需重新探测
            teardownHoverGIFPlayback()
        }
    }

    private func startHoverGIFPlaybackIfNeeded() {
        guard let media = currentMedia else { return }
        let itemID = media.id

        if isPlayingGIFOverlay, resolvedGIFItemID == itemID { return }

        // 同一 cell 再次 hover 时直接复用原始数据，不再重复网络请求。
        if let cachedData = resolvedGIFData, resolvedGIFItemID == itemID {
            hoverGIFFetchTask?.cancel()
            hoverGIFFetchTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                _ = await self.playGIFOverlayAsync(data: cachedData)
            }
            return
        }

        let allCandidates = preferredImageURLs(for: media)
        let hintedCandidates = allCandidates.filter(Self.urlLooksLikeGIF)
        let candidates = hintedCandidates
            + allCandidates.filter { !hintedCandidates.contains($0) }
        guard !candidates.isEmpty else { return }
        let needsProbe = hintedCandidates.isEmpty && media.isAnimatedImage != true

        hoverGIFFetchTask?.cancel()
        hoverGIFFetchTask = Task { [weak self] in
            guard let self else { return }

            if needsProbe {
                for url in candidates {
                    guard !Task.isCancelled else { return }
                    guard await AnimatedImageProbeCache.shared.isAnimatedGIF(
                        url,
                        maxByteCount: Self.maxAnimatedGIFBytes,
                        maxPixelCount: Self.maxAnimatedGIFPixelCount,
                        maxFrameCount: Self.maxAnimatedGIFFrameCount
                    ) else {
                        continue
                    }
                    guard let data = await self.retrieveAnimatedGIFData(from: url) else {
                        // Range 探测只能确认“GIF 头”，完整下载后仍可能是单帧；
                        // 继续尝试下一个候选，避免误判让整张卡片失去动效。
                        continue
                    }
                    await self.installHoverGIFData(data: data, url: url, itemID: itemID)
                    return
                }
                return
            }

            for url in candidates {
                guard !Task.isCancelled,
                      let data = await self.retrieveAnimatedGIFData(from: url) else {
                    continue
                }
                await self.installHoverGIFData(data: data, url: url, itemID: itemID)
                return
            }
        }
    }

    @MainActor
    private func installHoverGIFData(data: Data, url: URL, itemID: String) async {
        guard !Task.isCancelled,
              isHovered,
              currentMedia?.id == itemID else {
            return
        }
        resolvedGIFURL = url
        resolvedGIFItemID = itemID
        resolvedGIFData = data
        _ = await playGIFOverlayAsync(data: data)
    }

    private static func urlLooksLikeGIF(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return value.hasSuffix(".gif")
            || value.contains(".gif?")
            || value.contains(".gif&")
            || value.contains("format=gif")
            || value.contains("output-format=gif")
    }

    private func teardownHoverGIFPlayback() {
        hoverGIFFetchTask?.cancel()
        hoverGIFFetchTask = nil
        stopGIFOverlayPlayback()
        resolvedGIFData = nil
    }

    // MARK: - 图片目标尺寸

    /// 上次 loadImage 的目标点尺寸；bounds 变大后需要按新尺寸重解码
    private var lastImageTargetSize: CGSize = .zero

    private func preferredImageURLs(for media: MediaItem) -> [URL] {
        // 与 MediaCardView 的探测候选一致：poster > thumbnail > cover
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

    private func preferredImageTargetSize(for media: MediaItem) -> CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let displayWidth = max(coverImageView.bounds.width, 320) * scale
        let displayHeight = max(coverImageView.bounds.height, 200) * scale
        let displayAspect = max(coverImageView.bounds.width, 320) / max(coverImageView.bounds.height, 200)
        let sourceAspect = parsedAspectRatio(for: media) ?? displayAspect

        var requiredEdge = max(displayWidth, displayHeight)

        if sourceAspect < displayAspect {
            requiredEdge = max(requiredEdge, displayWidth / max(sourceAspect, 0.2))
        } else if sourceAspect > displayAspect {
            requiredEdge = max(requiredEdge, displayHeight * sourceAspect)
        }

        let clampedEdge = min(max(requiredEdge.rounded(.up), Self.minDecodeEdge), Self.maxDecodeEdge)
        return CGSize(width: clampedEdge, height: clampedEdge)
    }

    private func parsedAspectRatio(for media: MediaItem) -> CGFloat? {
        let raw = (media.exactResolution ?? media.resolutionLabel)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "X", with: "x")
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0 else {
            return nil
        }

        return CGFloat(width / height)
    }

    private func layoutTopBadges(in bounds: CGRect) {
        let topY = bounds.height - Layout.overlayPadding
        var nextX = Layout.overlayPadding

        if !leadingTagBadge.isHidden {
            let size = sanitizedBadgeSize(for: leadingTagBadge)
            leadingTagBadge.frame = CGRect(
                x: nextX,
                y: topY - size.height,
                width: size.width,
                height: size.height
            ).integral
            nextX = leadingTagBadge.frame.maxX + Layout.badgeSpacing
        } else {
            leadingTagBadge.frame = .zero
        }

        if !trailingBadge.isHidden {
            let size = sanitizedBadgeSize(for: trailingBadge)
            trailingBadge.frame = CGRect(
                x: bounds.width - Layout.overlayPadding - size.width,
                y: topY - size.height,
                width: size.width,
                height: size.height
            ).integral
        } else {
            trailingBadge.frame = .zero
        }
    }

    private func sanitizedBadgeSize(for badge: MediaMetaBadgeView) -> CGSize {
        let size = badge.preferredSize
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return .zero
        }

        return CGSize(
            width: min(size.width, max(0, containerView.bounds.width - Layout.overlayPadding * 2)),
            height: min(size.height, 28)
        )
    }
}

private final class MediaMetaBadgeView: NSView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 4
    }

    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.82)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    var preferredSize: CGSize {
        guard !label.stringValue.isEmpty else { return .zero }
        let textSize = label.fittingSize
        guard textSize.width.isFinite,
              textSize.height.isFinite,
              textSize.width >= 0,
              textSize.height >= 0 else {
            return .zero
        }
        return CGSize(
            width: ceil(textSize.width + Layout.horizontalPadding * 2),
            height: ceil(textSize.height + Layout.verticalPadding * 2)
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        layer?.cornerRadius = 10
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String?) {
        label.stringValue = text ?? ""
        isHidden = label.stringValue.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.isFiniteGeometry, bounds.width > 0, bounds.height > 0 else {
            label.frame = .zero
            return
        }

        let insetBounds = bounds.insetBy(dx: Layout.horizontalPadding, dy: Layout.verticalPadding)
        guard insetBounds.isFiniteGeometry else {
            label.frame = .zero
            return
        }

        label.frame = CGRect(
            x: insetBounds.minX,
            y: insetBounds.minY,
            width: max(0, insetBounds.width),
            height: max(0, insetBounds.height)
        ).integral
    }
}

private extension CGRect {
    var isFiniteGeometry: Bool {
        origin.x.isFinite &&
        origin.y.isFinite &&
        size.width.isFinite &&
        size.height.isFinite &&
        abs(origin.x) < 1_000_000 &&
        abs(origin.y) < 1_000_000 &&
        size.width >= 0 &&
        size.height >= 0 &&
        size.width < 1_000_000 &&
        size.height < 1_000_000
    }
}

private extension NSColor {
    convenience init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

extension MediaItem {
    /// 用于 ExploreGridLayout 的有效宽高比（包含底部信息栏）
    static func effectiveAspectRatio(columnWidth: CGFloat) -> CGFloat {
        guard columnWidth > 0 else { return 1.6 }
        let imageHeight = columnWidth / 1.6
        return columnWidth / (imageHeight + 44)
    }
}
