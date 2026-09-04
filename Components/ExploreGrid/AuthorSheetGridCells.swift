import AppKit

// MARK: - 作者壁纸卡片（原生复刻原 AuthorWallpaperCard 的视觉）
//
// 对应的 SwiftUI 结构（保持字号 / 颜色 / 间距一致）：
//   VStack(spacing: 0) {
//     KFImage 封面 158×100 aspectFill
//     Text(11 semibold, white 0.9).padding(h 8, top 7)        // 可选标题
//     HStack(spacing: 6) { 分类胶囊; Spacer; 分辨率 }
//       .padding(h 8, top 4/7, bottom 7)
//   }
//   .background(1A1D24 0.6, 圆角 14)
//   .overlay(边框 0.5 white 0.06 / hover white 0.2 / 当前项 accent 2)
//   .scaleEffect(hover 1.01)
final class AuthorWallpaperGridCell: ExploreGridItem {

    static let authorSheetReuseIdentifier = NSUserInterfaceItemIdentifier("AuthorWallpaperGridCell")

    override class var gridReuseIdentifier: NSUserInterfaceItemIdentifier {
        authorSheetReuseIdentifier
    }

    private enum Layout {
        static let cardWidth = AuthorSheetCardMetrics.cardWidth
        static let imageHeight = AuthorSheetCardMetrics.cardImageHeight
        static let titleTopPadding: CGFloat = 7
        static let bottomRowTopPaddingWithTitle: CGFloat = 4
        static let bottomRowTopPaddingWithoutTitle: CGFloat = 7
        static let bottomPadding: CGFloat = 7
        static let textHorizontalPadding = AuthorSheetCardMetrics.textHorizontalPadding
        static let normalBorderWidth: CGFloat = 0.5
        static let activeBorderWidth: CGFloat = 2
    }

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = AuthorSheetCardMetrics.titleFont
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        return label
    }()

    private let categoryLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = AuthorSheetCardMetrics.categoryFont
        label.textColor = NSColor.white.withAlphaComponent(0.6)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        return label
    }()

    /// 分类胶囊背景（white 0.08 Capsule）
    private let categoryCapsule: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return view
    }()

    private let resolutionLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = AuthorSheetCardMetrics.resolutionFont
        label.textColor = NSColor.white.withAlphaComponent(0.35)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        return label
    }()

    private var isActive = false
    private var hasTitle = false
    private var hasCategory = false
    private var hasResolution = false
    /// configure 时测量缓存，layout 直接读取，避免滚动中重复 fittingSize
    private var cachedCategoryTextWidth: CGFloat = 0
    private var cachedResolutionTextWidth: CGFloat = 0

    // 原 SwiftUI 卡 hover：scaleEffect 1.01 + 边框提亮到 white 0.2（宽度仍 0.5）。
    // 当前项（activeItemID 对应卡片）恒为强调色 2pt，hover 不改变它——与原三元表达式一致。
    override var hoverScaleFactor: CGFloat { 1.01 }

    override func effectiveHoverBorderWidth(for hovering: Bool) -> CGFloat {
        isActive ? Layout.activeBorderWidth : Layout.normalBorderWidth
    }

    override func effectiveHoverBorderColor(for hovering: Bool) -> NSColor {
        if isActive {
            return NSColor.controlAccentColor
        }
        return hovering
            ? NSColor.white.withAlphaComponent(0.2)
            : NSColor.white.withAlphaComponent(0.06)
    }

    override func setupContentLayout() {
        containerView.layer?.backgroundColor = NSColor(hexString: "1A1D24").withAlphaComponent(0.6).cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(AuthorSheetCardMetrics.cardCornerRadius)
        setNormalBorder(width: Layout.normalBorderWidth, color: NSColor.white.withAlphaComponent(0.06))
        // 原 KFImage 占位：Rectangle().fill(.white.opacity(0.05))
        coverImageView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor

        contentView.addSubview(titleLabel)
        contentView.addSubview(categoryCapsule)
        categoryCapsule.addSubview(categoryLabel)
        contentView.addSubview(resolutionLabel)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isActive = false
        hasTitle = false
        hasCategory = false
        hasResolution = false
        titleLabel.stringValue = ""
        categoryLabel.stringValue = ""
        resolutionLabel.stringValue = ""
        cachedCategoryTextWidth = 0
        cachedResolutionTextWidth = 0
        setNormalBorder(width: Layout.normalBorderWidth, color: NSColor.white.withAlphaComponent(0.06))
    }

    func configure(with wallpaper: Wallpaper, isActive active: Bool) {
        let title = (wallpaper.title?.isEmpty == false) ? wallpaper.title : nil
        hasTitle = title != nil
        let categoryText = wallpaper.category.isEmpty ? "" : wallpaper.categoryDisplayName
        hasCategory = !categoryText.isEmpty
        let resolutionText = wallpaper.resolution.trimmingCharacters(in: .whitespacesAndNewlines)
        hasResolution = !resolutionText.isEmpty
        isActive = active

        titleLabel.stringValue = title ?? ""
        categoryLabel.stringValue = categoryText
        resolutionLabel.stringValue = resolutionText

        setNormalBorder(
            width: active ? Layout.activeBorderWidth : Layout.normalBorderWidth,
            color: active
                ? NSColor.controlAccentColor
                : NSColor.white.withAlphaComponent(0.06)
        )

        cachedCategoryTextWidth = hasCategory ? ceil(categoryLabel.fittingSize.width) : 0
        cachedResolutionTextWidth = hasResolution ? ceil(resolutionLabel.fittingSize.width) : 0

        // 封面候选与原 coverImageURL（thumb ?? small ?? full）一致；
        // loadImage 自带降采样与复用取消，单个候选失败会顺延下一个。
        setCoverContentsGravity(.resizeAspectFill)
        loadImage(
            urls: [wallpaper.thumbURL, wallpaper.smallThumbURL, wallpaper.fullImageURL].compactMap { $0 },
            targetSize: CGSize(width: Layout.cardWidth, height: Layout.imageHeight)
        )

        // 手动 frame 布局的 cell 在复用时不会因文本变化自动重排，
        // configure 后立即按缓存测量重排一次。
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
        let width = bounds.width

        // 顶部封面（item view 坐标非翻转：y=0 在底部）；
        // 整卡由 containerView 的 14pt 圆角统一裁切，封面自身不设圆角
        coverImageView.frame = CGRect(
            x: 0,
            y: bounds.height - Layout.imageHeight,
            width: width,
            height: Layout.imageHeight
        )
        coverImageView.layer?.cornerRadius = 0

        // 可选标题行
        let titleHeight = AuthorSheetCardMetrics.titleLineHeight
        if hasTitle {
            titleLabel.frame = CGRect(
                x: Layout.textHorizontalPadding,
                y: bounds.height - Layout.imageHeight - Layout.titleTopPadding - titleHeight,
                width: max(0, width - Layout.textHorizontalPadding * 2),
                height: titleHeight
            ).integral
        } else {
            titleLabel.frame = .zero
        }

        // 底部信息行：分类胶囊靠左、分辨率靠右，行内垂直居中（对齐 HStack）
        let rowHeight = AuthorSheetCardMetrics.wallpaperBottomRowHeight(
            hasCategory: hasCategory,
            hasResolution: hasResolution
        )
        let rowTopPadding = hasTitle
            ? Layout.bottomRowTopPaddingWithTitle
            : Layout.bottomRowTopPaddingWithoutTitle
        let contentTop = bounds.height - Layout.imageHeight
            - (hasTitle ? Layout.titleTopPadding + titleHeight : 0)
        let rowTopY = contentTop - rowTopPadding
        let rowBottomY = Layout.bottomPadding
        let rowCenterY = (rowTopY + rowBottomY) / 2

        let availableWidth = max(0, width - Layout.textHorizontalPadding * 2)
        let capsuleHeight = AuthorSheetCardMetrics.categoryCapsuleHeight
        let resolutionHeight = AuthorSheetCardMetrics.resolutionLineHeight
        let spacing = (hasCategory && hasResolution) ? AuthorSheetCardMetrics.bottomRowSpacing : 0

        var capsuleWidth: CGFloat = 0
        var resolutionWidth: CGFloat = 0
        if hasCategory {
            capsuleWidth = min(
                cachedCategoryTextWidth + AuthorSheetCardMetrics.categoryCapsuleHorizontalPadding * 2,
                availableWidth
            )
        }
        if hasResolution {
            let reserved = capsuleWidth > 0 ? capsuleWidth + spacing : 0
            resolutionWidth = min(cachedResolutionTextWidth, max(0, availableWidth - reserved))
        }

        if hasCategory, capsuleWidth > 0 {
            categoryCapsule.frame = CGRect(
                x: Layout.textHorizontalPadding,
                y: rowCenterY - capsuleHeight / 2,
                width: capsuleWidth,
                height: capsuleHeight
            ).integral
            categoryCapsule.layer?.cornerRadius = capsuleHeight / 2
            categoryLabel.frame = categoryCapsule.bounds.insetBy(
                dx: AuthorSheetCardMetrics.categoryCapsuleHorizontalPadding,
                dy: 2
            )
        } else {
            categoryCapsule.frame = .zero
        }

        if hasResolution, resolutionWidth > 0 {
            resolutionLabel.frame = CGRect(
                x: width - Layout.textHorizontalPadding - resolutionWidth,
                y: rowCenterY - resolutionHeight / 2,
                width: resolutionWidth,
                height: resolutionHeight
            ).integral
        } else {
            resolutionLabel.frame = .zero
        }
    }
}

// MARK: - 作者媒体卡片（原生复刻原 AuthorMediaCard 的视觉）
//
// 对应的 SwiftUI 结构：
//   VStack(spacing: 0) {
//     KFImage 封面 158×100 aspectFill
//     Text(11 semibold, white 0.85).padding(h 8, v 7)
//   }
//   卡片底 1A1D24 0.6 / 圆角 14 / 边框与 hover 行为同壁纸卡
final class AuthorMediaGridCell: ExploreGridItem {

    static let authorSheetReuseIdentifier = NSUserInterfaceItemIdentifier("AuthorMediaGridCell")

    override class var gridReuseIdentifier: NSUserInterfaceItemIdentifier {
        authorSheetReuseIdentifier
    }

    private enum Layout {
        static let cardWidth = AuthorSheetCardMetrics.cardWidth
        static let imageHeight = AuthorSheetCardMetrics.cardImageHeight
        static let titleVerticalPadding: CGFloat = 7
        static let textHorizontalPadding = AuthorSheetCardMetrics.textHorizontalPadding
        static let normalBorderWidth: CGFloat = 0.5
        static let activeBorderWidth: CGFloat = 2
    }

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = AuthorSheetCardMetrics.titleFont
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        return label
    }()

    private var isActive = false

    override var hoverScaleFactor: CGFloat { 1.01 }

    override func effectiveHoverBorderWidth(for hovering: Bool) -> CGFloat {
        isActive ? Layout.activeBorderWidth : Layout.normalBorderWidth
    }

    override func effectiveHoverBorderColor(for hovering: Bool) -> NSColor {
        if isActive {
            return NSColor.controlAccentColor
        }
        return hovering
            ? NSColor.white.withAlphaComponent(0.2)
            : NSColor.white.withAlphaComponent(0.06)
    }

    override func setupContentLayout() {
        containerView.layer?.backgroundColor = NSColor(hexString: "1A1D24").withAlphaComponent(0.6).cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(AuthorSheetCardMetrics.cardCornerRadius)
        setNormalBorder(width: Layout.normalBorderWidth, color: NSColor.white.withAlphaComponent(0.06))
        coverImageView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor

        contentView.addSubview(titleLabel)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isActive = false
        titleLabel.stringValue = ""
        setNormalBorder(width: Layout.normalBorderWidth, color: NSColor.white.withAlphaComponent(0.06))
    }

    func configure(with media: MediaItem, isActive active: Bool) {
        isActive = active
        titleLabel.stringValue = media.title

        setNormalBorder(
            width: active ? Layout.activeBorderWidth : Layout.normalBorderWidth,
            color: active
                ? NSColor.controlAccentColor
                : NSColor.white.withAlphaComponent(0.06)
        )

        // 原 coverImageURL = posterURL ?? thumbnailURL；候选顺延仅作失败兜底
        setCoverContentsGravity(.resizeAspectFill)
        loadImage(
            urls: [media.posterURL, media.thumbnailURL].compactMap { $0 },
            targetSize: CGSize(width: Layout.cardWidth, height: Layout.imageHeight)
        )

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
        let width = bounds.width

        coverImageView.frame = CGRect(
            x: 0,
            y: bounds.height - Layout.imageHeight,
            width: width,
            height: Layout.imageHeight
        )
        coverImageView.layer?.cornerRadius = 0

        let titleHeight = AuthorSheetCardMetrics.titleLineHeight
        titleLabel.frame = CGRect(
            x: Layout.textHorizontalPadding,
            y: bounds.height - Layout.imageHeight - Layout.titleVerticalPadding - titleHeight,
            width: max(0, width - Layout.textHorizontalPadding * 2),
            height: titleHeight
        ).integral
    }
}

// MARK: - 私有工具

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
