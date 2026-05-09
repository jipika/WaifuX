import AppKit

/// 媒体网格 Cell — 还原重构前 SimpleMediaCard 的视觉结构
/// - 16:10 图片区域
/// - 左侧标签 / 右侧分辨率胶囊
/// - 底部半透明标题栏 + 收藏心形
final class MediaGridCell: ExploreGridItem {

    static let newReuseIdentifier = NSUserInterfaceItemIdentifier("MediaGridCell")

    private enum Layout {
        static let outerCornerRadius: CGFloat = 16
        static let imageCornerRadius: CGFloat = 14
        static let bottomBarHeight: CGFloat = 44
        static let overlayPadding: CGFloat = 10
        static let badgeSpacing: CGFloat = 6
        static let bottomHorizontalPadding: CGFloat = 14
    }

    static let imageAspectRatio: CGFloat = 1.6
    private static let maxDecodeEdge: CGFloat = 1600
    private static let minDecodeEdge: CGFloat = 640

    private var currentMedia: MediaItem?

    private let bottomBar: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
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

    private let heartLabel: NSTextField = {
        let label = NSTextField(labelWithString: "♡")
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.36)
        return label
    }()

    private let leadingTagBadge = MediaMetaBadgeView()
    private let trailingBadge = MediaMetaBadgeView()

    override var hoverScaleFactor: CGFloat { 1.02 }
    override var shouldAnimateBorderOnHover: Bool { false }

    override func setupContentLayout() {
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(Layout.outerCornerRadius)
        setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.06))

        contentView.translatesAutoresizingMaskIntoConstraints = true
        bottomBar.translatesAutoresizingMaskIntoConstraints = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        heartLabel.translatesAutoresizingMaskIntoConstraints = true
        leadingTagBadge.translatesAutoresizingMaskIntoConstraints = true
        trailingBadge.translatesAutoresizingMaskIntoConstraints = true

        contentView.addSubview(bottomBar)
        bottomBar.addSubview(titleLabel)
        bottomBar.addSubview(heartLabel)

        contentView.addSubview(leadingTagBadge)
        contentView.addSubview(trailingBadge)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentMedia = nil
        titleLabel.stringValue = ""
        heartLabel.stringValue = "♡"
        heartLabel.textColor = NSColor.white.withAlphaComponent(0.36)
        leadingTagBadge.isHidden = true
        trailingBadge.isHidden = true
    }

    override func configure(with item: Any, isFavorite: Bool) {
        guard let media = item as? MediaItem else { return }
        currentMedia = media

        titleLabel.stringValue = media.title
        heartLabel.stringValue = isFavorite ? "♥" : "♡"
        heartLabel.textColor = isFavorite
            ? NSColor(hexString: "FF5A7D")
            : NSColor.white.withAlphaComponent(0.36)

        let firstTag = media.tags.lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        leadingTagBadge.configure(text: firstTag)
        leadingTagBadge.isHidden = firstTag == nil

        let resolutionText = media.resolutionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        trailingBadge.configure(text: resolutionText.isEmpty ? nil : resolutionText)
        trailingBadge.isHidden = resolutionText.isEmpty

        loadImage(urls: preferredImageURLs(for: media), targetSize: preferredImageTargetSize(for: media))

        if containerView.bounds.width > 0, containerView.bounds.height > 0 {
            layoutContentFrames()
        } else {
            view.needsLayout = true
            containerView.needsLayout = true
            contentView.needsLayout = true
        }
    }

    override func layoutContentFrames() {
        let bounds = containerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        contentView.frame = bounds

        let imageHeight = max(0, bounds.height - Layout.bottomBarHeight)
        coverImageView.frame = CGRect(x: 0, y: Layout.bottomBarHeight, width: bounds.width, height: imageHeight)
        coverImageView.layer?.cornerRadius = Layout.imageCornerRadius
        if #available(macOS 10.13, *) {
            coverImageView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        coverImageView.layer?.backgroundColor = NSColor(hexString: "1C2431").cgColor

        bottomBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.bottomBarHeight)

        let heartSize = heartLabel.fittingSize
        heartLabel.frame = CGRect(
            x: bounds.width - Layout.bottomHorizontalPadding - heartSize.width,
            y: floor((Layout.bottomBarHeight - heartSize.height) / 2),
            width: heartSize.width,
            height: heartSize.height
        ).integral

        titleLabel.frame = CGRect(
            x: Layout.bottomHorizontalPadding,
            y: floor((Layout.bottomBarHeight - 16) / 2),
            width: max(0, heartLabel.frame.minX - Layout.bottomHorizontalPadding - 12),
            height: 16
        ).integral

        layoutTopBadges(in: bounds)
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

    private func preferredImageURLs(for media: MediaItem) -> [URL] {
        var urls: [URL] = []
        if let posterURL = media.posterURLValue {
            urls.append(posterURL)
        }
        urls.append(media.thumbnailURLValue)
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
}

private final class MediaMetaBadgeView: NSView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 4
    }

    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
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
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        layer?.cornerRadius = 11
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
