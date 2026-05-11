import AppKit

final class WallpaperGridCell: ExploreGridItem {

    private enum Layout {
        static let bottomBarHeight: CGFloat = 46
        static let topPadding: CGFloat = 12
        static let sidePadding: CGFloat = 12
        static let tagSpacing: CGFloat = 8
        static let bottomHPadding: CGFloat = 14
        static let trailingSpacing: CGFloat = 8
        static let titleSpacing: CGFloat = 12
        static let minTitleWidth: CGFloat = 42
        static let minColorChipWidth: CGFloat = 72
        static let minSecondaryBadgeWidth: CGFloat = 42
        static let outerCornerRadius: CGFloat = 22
        static let imageCornerRadius: CGFloat = 22
    }

    private let bottomBar: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }()

    private let categoryBadge = WallpaperTagBadgeView()
    private let purityBadge = WallpaperTagBadgeView()
    private let resolutionBadge = WallpaperTagBadgeView()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let colorChip = WallpaperColorChipView()
    private let favoritesView = WallpaperStatView(symbolName: "heart.fill")
    private let viewsView = WallpaperStatView(symbolName: "eye.fill")
    private var wallpaperImageURLs: [URL] = []
    private var currentWallpaper: Wallpaper?

    /// layoutContentFrames 中 fittingSize 缓存；文本内容不变时结果不变，
    /// 在 configure() 中计算一次，避免每次 layout 重算。
    private var cachedCategoryBadgeSize: CGSize = .zero
    private var cachedPurityBadgeSize: CGSize = .zero
    private var cachedResolutionBadgeSize: CGSize = .zero
    private var cachedColorChipSize: CGSize = .zero
    private var cachedViewsViewSize: CGSize = .zero
    private var cachedFavoritesViewSize: CGSize = .zero

    override var hoverScaleFactor: CGFloat { 1.01 }
    override var hoverOverlayMaxOpacity: Float { 0 }
    override var shouldAnimateBorderOnHover: Bool { true }

    override func setupContentLayout() {
        coverImageView.isHidden = false
        containerView.layer?.backgroundColor = NSColor(hexString: "1A1D24").withAlphaComponent(0.6).cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(Layout.outerCornerRadius)
        setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.08))

        contentView.translatesAutoresizingMaskIntoConstraints = true

        categoryBadge.translatesAutoresizingMaskIntoConstraints = true
        purityBadge.translatesAutoresizingMaskIntoConstraints = true
        resolutionBadge.translatesAutoresizingMaskIntoConstraints = true
        contentView.addSubview(resolutionBadge)
        contentView.addSubview(categoryBadge)
        contentView.addSubview(purityBadge)

        bottomBar.translatesAutoresizingMaskIntoConstraints = true
        contentView.addSubview(bottomBar)

        colorChip.translatesAutoresizingMaskIntoConstraints = true
        favoritesView.translatesAutoresizingMaskIntoConstraints = true
        viewsView.translatesAutoresizingMaskIntoConstraints = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        bottomBar.addSubview(titleLabel)
        bottomBar.addSubview(colorChip)
        bottomBar.addSubview(favoritesView)
        bottomBar.addSubview(viewsView)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.08))
        titleLabel.stringValue = ""
        wallpaperImageURLs = []
        currentWallpaper = nil
        categoryBadge.isHidden = true
        purityBadge.isHidden = true
        resolutionBadge.isHidden = true
        colorChip.isHidden = true
        favoritesView.reset()
        viewsView.reset()
        // 清空 fittingSize 缓存，防止复用时残留旧尺寸
        cachedCategoryBadgeSize = .zero
        cachedPurityBadgeSize = .zero
        cachedResolutionBadgeSize = .zero
        cachedColorChipSize = .zero
        cachedViewsViewSize = .zero
        cachedFavoritesViewSize = .zero
    }

    override func configure(with item: Any, isFavorite: Bool) {
        guard let wallpaper = item as? Wallpaper else { return }
        let isSameWallpaper = wallpaper.id == currentWallpaper?.id
        currentWallpaper = wallpaper

        if isSameWallpaper, coverImageView.image != nil {
            // 同一张壁纸且图片已加载，仅更新 UI 状态，跳过图片重载
            favoritesView.configure(value: compactNumber(wallpaper.favorites), tint: isFavorite ? NSColor(hexString: "FF5A7D") : secondaryStatColor)
            return
        }

        applyTheme()
        applyBorder(for: wallpaper)

        titleLabel.stringValue = wallpaper.uploader?.username ?? wallpaper.categoryDisplayName
        categoryBadge.configure(text: wallpaper.categoryDisplayName)
        purityBadge.configure(text: wallpaper.purityDisplayName)
        resolutionBadge.configure(text: wallpaper.effectiveResolutionLabel.replacingOccurrences(of: "x", with: "×"))

        if let hex = wallpaper.primaryColorHex, !hex.isEmpty {
            colorChip.isHidden = false
            colorChip.configure(hex: hex)
        } else {
            colorChip.isHidden = true
        }

        favoritesView.configure(
            value: compactNumber(wallpaper.favorites),
            tint: isFavorite ? NSColor(hexString: "FF5A7D") : secondaryStatColor
        )
        viewsView.configure(
            value: compactNumber(wallpaper.views),
            tint: secondaryStatColor
        )

        let targetSize = preferredImageTargetSize()
        wallpaperImageURLs = preferredImageURLs(for: wallpaper, targetSize: targetSize)
        loadImage(urls: wallpaperImageURLs, targetSize: targetSize)

        // 在文本确定后立即计算并缓存各子视图的 fittingSize；
        // 后续 layoutContentFrames/layout 中直接读取缓存，避免重复测量。
        cacheFittingSizes()

        // 手动 frame 布局的 cell 在复用时不会因文本变化自动重新排版；
        // 如果不在 configure 后立即重算，旧 cell 残留的 badge/chip 宽度会直接带到新数据上，
        // 表现为随机出现 "...".
        if containerView.bounds.width > 0, containerView.bounds.height > 0 {
            layoutContentFrames()
        } else {
            view.needsLayout = true
            containerView.needsLayout = true
            contentView.needsLayout = true
        }
    }

    private func cacheFittingSizes() {
        cachedCategoryBadgeSize = categoryBadge.hasContent ? fittingSize(for: categoryBadge) : .zero
        cachedPurityBadgeSize = purityBadge.hasContent ? fittingSize(for: purityBadge) : .zero
        cachedResolutionBadgeSize = resolutionBadge.hasContent ? fittingSize(for: resolutionBadge) : .zero
        cachedColorChipSize = colorChip.hasContent ? fittingSize(for: colorChip) : .zero
        cachedViewsViewSize = viewsView.isHidden ? .zero : fittingSize(for: viewsView)
        cachedFavoritesViewSize = favoritesView.isHidden ? .zero : fittingSize(for: favoritesView)
    }

    override func layoutContentFrames() {
        let bounds = containerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        contentView.frame = bounds

        let imageHeight = max(0, bounds.height - Layout.bottomBarHeight)
        coverImageView.frame = CGRect(
            x: 0,
            y: Layout.bottomBarHeight,
            width: bounds.width,
            height: imageHeight
        )
        coverImageView.layer?.cornerRadius = Layout.imageCornerRadius
        if #available(macOS 10.13, *) {
            coverImageView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }

        bottomBar.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: Layout.bottomBarHeight
        )

        layoutTopBadges(in: bounds)
        layoutBottomBar(in: bottomBar.bounds)
        if let currentWallpaper {
            let targetSize = preferredImageTargetSize()
            let urls = preferredImageURLs(for: currentWallpaper, targetSize: targetSize)
            if urls != wallpaperImageURLs {
                wallpaperImageURLs = urls
                loadImage(urls: wallpaperImageURLs, targetSize: targetSize)
            }
        }
    }

    /// 根据 Cell 实际显示尺寸与图片比例动态计算降采样目标。
    /// 竖图高度远大于宽度，固定 512 会导致高度方向像素不足而模糊。
    private func preferredImageTargetSize() -> CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let baseWidth = coverImageView.bounds.width > 0
            ? coverImageView.bounds.width
            : 300

        let aspectRatio = CGFloat(currentWallpaper?.effectiveAspectRatioValue ?? 1.0)
        let clampedRatio = min(max(aspectRatio, 0.35), 3.6)
        let imageHeight = baseWidth / clampedRatio

        let targetWidth = baseWidth * scale
        let targetHeight = imageHeight * scale

        // 限制最大边不超过 1280，避免极端比例（如 0.35）导致单图内存爆炸
        let maxEdge: CGFloat = 1280
        let currentMaxEdge = max(targetWidth, targetHeight)
        guard currentMaxEdge > maxEdge else {
            return CGSize(width: targetWidth, height: targetHeight)
        }
        let reduction = maxEdge / currentMaxEdge
        return CGSize(width: targetWidth * reduction, height: targetHeight * reduction)
    }

    private func preferredImageURLs(for wallpaper: Wallpaper, targetSize: CGSize) -> [URL] {
        let aspectRatio = CGFloat(wallpaper.effectiveAspectRatioValue)
        let targetMaxEdge = max(targetSize.width, targetSize.height)
        let isLargeCard = targetMaxEdge >= 900
        let isExtremeAspect = aspectRatio < 0.7 || aspectRatio > 2.1

        let candidates: [URL?]
        if isLargeCard || isExtremeAspect {
            candidates = [
                wallpaper.originalThumbURL,
                wallpaper.fullImageURL,
                wallpaper.thumbURL,
                wallpaper.smallThumbURL
            ]
        } else {
            candidates = [
                wallpaper.thumbURL,
                wallpaper.originalThumbURL,
                wallpaper.fullImageURL,
                wallpaper.smallThumbURL
            ]
        }

        var seen: Set<String> = []
        return candidates.compactMap { url in
            guard let url else { return nil }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return nil }
            return url
        }
    }

    private func layoutTopBadges(in bounds: CGRect) {
        let totalTopWidth = max(0, bounds.width - Layout.sidePadding * 2)
        let topY = bounds.height - Layout.topPadding
        let hasCategory = categoryBadge.hasContent
        let hasPurity = purityBadge.hasContent
        let hasResolution = resolutionBadge.hasContent
        let categorySize = hasCategory ? cachedCategoryBadgeSize : .zero
        let puritySize = hasPurity ? cachedPurityBadgeSize : .zero
        let resolutionSize = hasResolution ? cachedResolutionBadgeSize : .zero
        let badgeHeight = max(categorySize.height, puritySize.height, resolutionSize.height)

        let categoryWidth = hasCategory ? ceil(categorySize.width) : 0
        let purityWidth = hasPurity ? ceil(puritySize.width) : 0
        var resolutionWidth = hasResolution ? ceil(resolutionSize.width) : 0
        let resolutionSpacing: CGFloat = hasResolution ? Layout.tagSpacing : 0

        var showCategory = hasCategory
        var showPurity = hasPurity

        func leftWidth(category: Bool, purity: Bool) -> CGFloat {
            var width: CGFloat = 0
            if category { width += categoryWidth }
            if purity {
                if width > 0 { width += Layout.tagSpacing }
                width += purityWidth
            }
            return width
        }

        let resolutionReservedWidth = resolutionWidth + resolutionSpacing
        let leftAvailableWidth = max(0, totalTopWidth - resolutionReservedWidth)

        if showCategory && showPurity && leftWidth(category: true, purity: true) > leftAvailableWidth {
            showCategory = false
        }

        if showPurity && leftWidth(category: showCategory, purity: true) > leftAvailableWidth {
            if showCategory {
                showCategory = false
            } else {
                showPurity = false
            }
        }

        let activeLeftWidth = leftWidth(category: showCategory, purity: showPurity)
        if resolutionWidth > 0 {
            let maxResolutionWidth = max(0, totalTopWidth - activeLeftWidth - (activeLeftWidth > 0 ? Layout.tagSpacing : 0))
            resolutionWidth = min(resolutionWidth, maxResolutionWidth)
        }

        var nextX = Layout.sidePadding
        if showCategory {
            categoryBadge.frame = CGRect(
                x: nextX,
                y: topY - badgeHeight,
                width: categoryWidth,
                height: categorySize.height
            ).integral
            nextX += categoryWidth + (showPurity ? Layout.tagSpacing : 0)
        } else {
            categoryBadge.frame = .zero
        }

        if showPurity {
            purityBadge.frame = CGRect(
                x: nextX,
                y: topY - badgeHeight,
                width: purityWidth,
                height: puritySize.height
            ).integral
        } else {
            purityBadge.frame = .zero
        }

        if hasResolution, resolutionWidth > 0 {
            resolutionBadge.frame = CGRect(
                x: bounds.width - Layout.sidePadding - resolutionWidth,
                y: topY - badgeHeight,
                width: resolutionWidth,
                height: resolutionSize.height
            ).integral
        } else {
            resolutionBadge.frame = .zero
        }
    }

    private func layoutBottomBar(in bounds: CGRect) {
        var trailingX = bounds.width - Layout.bottomHPadding
        let statHeight = max(
            cachedViewsViewSize.height,
            cachedFavoritesViewSize.height,
            titleLabel.intrinsicContentSize.height
        )
        let centerY = floor((bounds.height - statHeight) * 0.5)

        if !viewsView.isHidden, cachedViewsViewSize != .zero {
            trailingX -= cachedViewsViewSize.width
            viewsView.frame = CGRect(
                x: trailingX,
                y: centerY,
                width: cachedViewsViewSize.width,
                height: cachedViewsViewSize.height
            )
            trailingX -= Layout.trailingSpacing
        }

        if !favoritesView.isHidden, cachedFavoritesViewSize != .zero {
            trailingX -= cachedFavoritesViewSize.width
            favoritesView.frame = CGRect(
                x: trailingX,
                y: centerY,
                width: cachedFavoritesViewSize.width,
                height: cachedFavoritesViewSize.height
            )
            trailingX -= Layout.trailingSpacing
        }

        if colorChip.hasContent, cachedColorChipSize != .zero {
            let maxColorWidth = max(
                0,
                trailingX - Layout.titleSpacing - Layout.bottomHPadding - Layout.minTitleWidth
            )
            if maxColorWidth >= cachedColorChipSize.width {
                trailingX -= cachedColorChipSize.width
                colorChip.frame = CGRect(
                    x: trailingX,
                    y: floor((bounds.height - cachedColorChipSize.height) * 0.5),
                    width: cachedColorChipSize.width,
                    height: cachedColorChipSize.height
                ).integral
                trailingX -= Layout.trailingSpacing
            } else {
                colorChip.frame = .zero
            }
        } else {
            colorChip.frame = .zero
        }

        let titleMaxWidth = max(0, trailingX - Layout.titleSpacing - Layout.bottomHPadding)
        let titleFrame = CGRect(
            x: Layout.bottomHPadding,
            y: floor((bounds.height - titleLabel.intrinsicContentSize.height) * 0.5),
            width: titleMaxWidth,
            height: titleLabel.intrinsicContentSize.height
        )
        titleLabel.frame = titleFrame.integral
    }

    private func applyTheme() {
        titleLabel.textColor = primaryTextColor
        categoryBadge.applyTheme(isLightMode: isLightMode)
        purityBadge.applyTheme(isLightMode: isLightMode)
        resolutionBadge.applyTheme(isLightMode: isLightMode)
        colorChip.applyTheme(isLightMode: isLightMode)
    }

    private func applyBorder(for wallpaper: Wallpaper) {
        switch wallpaper.purity.lowercased() {
        case "nsfw":
            setNormalBorder(width: 1.5, color: NSColor(hexString: "FF3B30"))
        case "sketchy":
            setNormalBorder(width: 1.5, color: NSColor(hexString: "FFB347"))
        default:
            setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.08))
        }
    }

    private func fittingSize(for view: NSView) -> CGSize {
        let intrinsic = view.intrinsicContentSize
        let width = intrinsic.width != NSView.noIntrinsicMetric ? intrinsic.width : view.fittingSize.width
        let height = intrinsic.height != NSView.noIntrinsicMetric ? intrinsic.height : view.fittingSize.height

        return CGSize(width: ceil(max(0, width)), height: ceil(max(0, height)))
    }

    private var isLightMode: Bool {
        ArcBackgroundSettings.shared.isLightMode
    }

    private var primaryTextColor: NSColor {
        isLightMode
            ? NSColor(hexString: "1A1A1A").withAlphaComponent(0.9)
            : NSColor.white.withAlphaComponent(0.9)
    }

    private var secondaryStatColor: NSColor {
        isLightMode
            ? NSColor(hexString: "666666").withAlphaComponent(0.78)
            : NSColor.white.withAlphaComponent(0.5)
    }

    private func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private final class WallpaperTagBadgeView: NSView {
    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = true
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(label)

        applyTheme(isLightMode: ArcBackgroundSettings.shared.isLightMode)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String) {
        label.stringValue = text
        isHidden = text.isEmpty
        label.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyTheme(isLightMode: Bool) {
        label.textColor = isLightMode
            ? NSColor(hexString: "666666").withAlphaComponent(0.9)
            : NSColor.white.withAlphaComponent(0.82)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.measuredTextSize()
        return NSSize(width: ceil(labelSize.width) + 16, height: 20)
    }

    override func layout() {
        super.layout()
        let labelSize = label.measuredTextSize()
        label.frame = CGRect(
            x: 8,
            y: floor((bounds.height - labelSize.height) * 0.5),
            width: max(0, bounds.width - 16),
            height: labelSize.height
        ).integral
    }

    var hasContent: Bool {
        !label.stringValue.isEmpty
    }
}

private final class WallpaperColorChipView: NSView {
    private let dotView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }()

    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = true
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(dotView)
        addSubview(label)

        applyTheme(isLightMode: ArcBackgroundSettings.shared.isLightMode)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(hex: String) {
        let normalized = hex.replacingOccurrences(of: "#", with: "").uppercased()
        label.stringValue = "#\(normalized)"
        dotView.layer?.backgroundColor = NSColor(hexString: normalized).cgColor
        dotView.layer?.cornerRadius = 4
        isHidden = normalized.isEmpty
        label.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyTheme(isLightMode: Bool) {
        label.textColor = isLightMode
            ? NSColor(hexString: "666666").withAlphaComponent(0.9)
            : NSColor.white.withAlphaComponent(0.82)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
        dotView.layer?.borderWidth = 0.5
        dotView.layer?.borderColor = (isLightMode
            ? NSColor.black.withAlphaComponent(0.18)
            : NSColor.white.withAlphaComponent(0.22)).cgColor
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.measuredTextSize()
        let width = 8 + 8 + 6 + ceil(labelSize.width) + 12
        return NSSize(width: width, height: 22)
    }

    override func layout() {
        super.layout()
        let labelSize = label.measuredTextSize()
        let dotSize: CGFloat = 8
        let contentHeight = max(dotSize, labelSize.height)
        let contentOriginY = floor((bounds.height - contentHeight) * 0.5)
        dotView.frame = CGRect(
            x: 8,
            y: contentOriginY + floor((contentHeight - dotSize) * 0.5),
            width: dotSize,
            height: dotSize
        ).integral
        label.frame = CGRect(
            x: dotView.frame.maxX + 6,
            y: floor((bounds.height - labelSize.height) * 0.5),
            width: max(0, bounds.width - dotView.frame.maxX - 18),
            height: labelSize.height
        ).integral
    }

    var hasContent: Bool {
        !label.stringValue.isEmpty
    }
}

private final class WallpaperStatView: NSView {
    private let imageView = NSImageView()
    private let valueLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        return label
    }()

    private let symbolName: String

    init(symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = true
        imageView.imageScaling = .scaleProportionallyDown
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            imageView.image = image.withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        }

        valueLabel.translatesAutoresizingMaskIntoConstraints = true
        addSubview(imageView)
        addSubview(valueLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(value: String, tint: NSColor) {
        valueLabel.stringValue = value
        valueLabel.textColor = tint
        imageView.contentTintColor = tint
        valueLabel.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func reset() {
        valueLabel.stringValue = ""
        let tint = NSColor.white.withAlphaComponent(0.5)
        valueLabel.textColor = tint
        imageView.contentTintColor = tint
        valueLabel.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = valueLabel.measuredTextSize()
        return NSSize(width: 10 + 4 + ceil(labelSize.width) + 2, height: max(10, ceil(labelSize.height)))
    }

    override func layout() {
        super.layout()
        let labelSize = valueLabel.measuredTextSize()
        imageView.frame = CGRect(
            x: 0,
            y: floor((bounds.height - 10) * 0.5),
            width: 10,
            height: 10
        ).integral
        valueLabel.frame = CGRect(
            x: 14,
            y: floor((bounds.height - labelSize.height) * 0.5),
            width: max(0, bounds.width - 14),
            height: labelSize.height
        ).integral
    }
}

private extension NSTextField {
    func measuredTextSize() -> CGSize {
        let bounds = NSRect(
            x: 0,
            y: 0,
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if let cell {
            let measured = cell.cellSize(forBounds: bounds)
            return CGSize(width: ceil(measured.width), height: ceil(measured.height))
        }
        let measured = attributedStringValue.size()
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
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
