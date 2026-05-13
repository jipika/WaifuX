import AppKit

/// 动漫卡片 Cell — 还原重构前 AnimePortraitCard 的视觉结构
/// - 10:14 竖版封面
/// - 右上角评分胶囊
/// - 底部半透明信息栏（标题 + 最新集数）
final class AnimeGridCell: ExploreGridItem {

    static let newReuseIdentifier = NSUserInterfaceItemIdentifier("AnimeGridCell")

    private enum Layout {
        static let outerCornerRadius: CGFloat = 14
        static let imageCornerRadius: CGFloat = 14
        static let bottomBarHeight: CGFloat = 44
        static let titleSidePadding: CGFloat = 12
        static let titleTopPadding: CGFloat = 10
        static let episodeBottomPadding: CGFloat = 8
        static let ratingTopPadding: CGFloat = 10
        static let ratingTrailingPadding: CGFloat = 8
        static let ratingHorizontalPadding: CGFloat = 6
        static let ratingVerticalPadding: CGFloat = 4
    }

    private let bottomBar: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
        return view
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.95)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    private let episodeIconLabel: NSTextField = {
        let label = NSTextField(labelWithString: "▶")
        label.font = .systemFont(ofSize: 9, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.5)
        label.isHidden = true
        return label
    }()

    private let episodeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.6)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isHidden = true
        return label
    }()

    private let ratingBadgeView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        view.layer?.cornerRadius = 11
        view.isHidden = true
        return view
    }()

    private let ratingStarLabel: NSTextField = {
        let label = NSTextField(labelWithString: "★")
        label.font = .systemFont(ofSize: 8, weight: .regular)
        label.textColor = .systemYellow
        return label
    }()

    private let ratingLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byClipping
        return label
    }()

    private var currentAnime: AnimeSearchResult?

    override var hoverScaleFactor: CGFloat { 1.02 }

    override func setupContentLayout() {
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(Layout.outerCornerRadius)
        setNormalBorder(width: 0.5, color: NSColor.white.withAlphaComponent(0.06))

        contentView.translatesAutoresizingMaskIntoConstraints = true
        bottomBar.translatesAutoresizingMaskIntoConstraints = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        episodeIconLabel.translatesAutoresizingMaskIntoConstraints = true
        episodeLabel.translatesAutoresizingMaskIntoConstraints = true
        ratingBadgeView.translatesAutoresizingMaskIntoConstraints = true
        ratingStarLabel.translatesAutoresizingMaskIntoConstraints = true
        ratingLabel.translatesAutoresizingMaskIntoConstraints = true

        contentView.addSubview(bottomBar)
        bottomBar.addSubview(titleLabel)
        bottomBar.addSubview(episodeIconLabel)
        bottomBar.addSubview(episodeLabel)

        contentView.addSubview(ratingBadgeView)
        ratingBadgeView.addSubview(ratingStarLabel)
        ratingBadgeView.addSubview(ratingLabel)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentAnime = nil
        titleLabel.stringValue = ""
        episodeLabel.stringValue = ""
        ratingLabel.stringValue = ""
        episodeIconLabel.isHidden = true
        episodeLabel.isHidden = true
        ratingBadgeView.isHidden = true
    }

    override func configure(with item: Any, isFavorite: Bool) {
        guard let anime = item as? AnimeSearchResult else { return }
        currentAnime = anime

        titleLabel.stringValue = anime.title

        if let episode = anime.latestEpisode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !episode.isEmpty {
            episodeLabel.stringValue = episode
            episodeIconLabel.isHidden = false
            episodeLabel.isHidden = false
        } else {
            episodeLabel.stringValue = ""
            episodeIconLabel.isHidden = true
            episodeLabel.isHidden = true
        }

        if let rating = anime.rating?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rating.isEmpty {
            ratingLabel.stringValue = rating
            ratingBadgeView.isHidden = false
        } else {
            ratingLabel.stringValue = ""
            ratingBadgeView.isHidden = true
        }

        if let coverURL = anime.coverURL.flatMap(URL.init(string:)) {
            loadImage(url: coverURL, targetSize: preferredImageTargetSize())
        } else {
            loadImage(url: nil, targetSize: preferredImageTargetSize())
        }

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
        coverImageView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor

        bottomBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.bottomBarHeight)
        titleLabel.frame = CGRect(
            x: Layout.titleSidePadding,
            y: 18,
            width: bounds.width - Layout.titleSidePadding * 2,
            height: 16
        ).integral

        if episodeLabel.isHidden {
            episodeIconLabel.frame = .zero
            episodeLabel.frame = .zero
        } else {
            let iconSize = NSSize(width: 10, height: 10)
            let episodeSize = episodeLabel.fittingSize
            episodeIconLabel.frame = CGRect(
                x: Layout.titleSidePadding,
                y: Layout.episodeBottomPadding,
                width: iconSize.width,
                height: iconSize.height
            ).integral
            episodeLabel.frame = CGRect(
                x: episodeIconLabel.frame.maxX + 4,
                y: Layout.episodeBottomPadding - 1,
                width: min(episodeSize.width, bounds.width - Layout.titleSidePadding * 2 - iconSize.width - 4),
                height: max(12, episodeSize.height)
            ).integral
        }

        if ratingBadgeView.isHidden {
            ratingBadgeView.frame = .zero
        } else {
            let starSize = ratingStarLabel.fittingSize
            let textSize = ratingLabel.fittingSize
            let badgeWidth = Layout.ratingHorizontalPadding * 2 + starSize.width + 2 + textSize.width
            let badgeHeight = Layout.ratingVerticalPadding * 2 + max(starSize.height, textSize.height)
            ratingBadgeView.frame = CGRect(
                x: bounds.width - Layout.ratingTrailingPadding - badgeWidth,
                y: bounds.height - Layout.ratingTopPadding - badgeHeight,
                width: badgeWidth,
                height: badgeHeight
            ).integral
            ratingStarLabel.frame = CGRect(
                x: Layout.ratingHorizontalPadding,
                y: Layout.ratingVerticalPadding + 1,
                width: starSize.width,
                height: starSize.height
            ).integral
            ratingLabel.frame = CGRect(
                x: ratingStarLabel.frame.maxX + 2,
                y: Layout.ratingVerticalPadding,
                width: textSize.width,
                height: textSize.height
            ).integral
        }
    }

    override func hoverStateDidChange(_ hovering: Bool) {
        // 动漫探索页不再叠加额外 hover 阴影，保持和其他探索卡片一致的干净视觉。
    }

    private func preferredImageTargetSize() -> CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let width = max(coverImageView.bounds.width, 180) * scale
        let height = max(coverImageView.bounds.height, 252) * scale
        let maxEdge = min(max(width, height), 1200)
        return CGSize(width: width, height: min(height, maxEdge))
    }
}
