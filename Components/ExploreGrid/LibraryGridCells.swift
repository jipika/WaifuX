import AppKit
import Kingfisher

// MARK: - 我的库网格 cell 公共定义
//
// 2026-09 我的库网格从 SwiftUI ScrollView + LazyVGrid 迁到 ExploreGridContainer
// （NSCollectionView 自滚动 + cell 真复用），视觉与交互 1:1 对齐旧 SwiftUI 卡片：
// - WallpaperEditCard → LibraryWallpaperGridCell
// - MediaVideoCard    → LibraryMediaGridCell（GIF hover 走 ExploreGridItem 覆盖播放：中间帧起播 + aspect-fill）
// - LibraryFolderCard → LibraryFolderGridCell（叠图 + 中央 drop 区 + 加密锁态）
// - AnimeLibraryCard  → LibraryAnimeGridCell（编辑多选 + 进度）
// 旧 SwiftUI 卡片组件保留不删，探索页/其他场景仍可复用。

/// 我的库卡片统一布局度量（与 LibraryCardMetrics 对齐）
enum LibraryGridCellMetrics {
    /// 封面区固定高度（thumb）
    static let thumbHeight: CGFloat = 180
    /// 底部信息栏高度（壁纸/媒体/文件夹通用）
    static let infoBarHeight: CGFloat = 44
    /// 卡片外圆角
    static let cornerRadius: CGFloat = 22
    /// 卡片底色
    static let cardBackground = NSColor(hexString: "1A1D24")
    /// 动漫底部信息栏
    static let animeInfoBarHeight: CGFloat = 52

    /// 壁纸/媒体/文件夹卡的整卡宽高比（含信息栏）
    static func cardAspectRatio(columnWidth: CGFloat) -> CGFloat {
        guard columnWidth > 0 else { return 1.2 }
        return columnWidth / (thumbHeight + infoBarHeight)
    }

    /// 动漫卡整卡宽高比（10:14 封面 + 52pt 信息栏）
    static func animeAspectRatio(columnWidth: CGFloat) -> CGFloat {
        guard columnWidth > 0 else { return 0.7 }
        return columnWidth / (columnWidth * 1.4 + animeInfoBarHeight)
    }
}

// MARK: - 右键菜单负载

/// 我的库 cell 右键菜单条目（SwiftUI 侧构建，cell 转 NSMenu）
enum LibraryGridMenuEntry {
    case divider
    case item(title: String, icon: String?, destructive: Bool, handler: () -> Void)
    case submenu(title: String, icon: String?, entries: [LibraryGridMenuEntry])
}

/// NSMenuItem.target 是 weak 引用，用小对象包住 handler 并由 cell 持有存活。
final class LibraryMenuActionTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func performAction() {
        handler()
    }
}

/// 我的库卡片强调色（与 LiquidGlassColors 同源 hex；AppKit cell 侧使用）
enum LibraryGridAccent {
    static let pink = NSColor(srgbRed: 1.0, green: 51 / 255.0, blue: 102 / 255.0, alpha: 1)      // FF3366
    static let cyan = NSColor(srgbRed: 0, green: 212 / 255.0, blue: 1, alpha: 1)                 // 00D4FF
    static let violet = NSColor(srgbRed: 139 / 255.0, green: 92 / 255.0, blue: 246 / 255.0, alpha: 1) // 8B5CF6
}

/// 我的库拖拽负载解析（与旧 SwiftUI 卡片的 "waifux:item:" / "waifux:items:" 协议一致）
enum LibraryDragPayload {
    static func ids(from strings: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for payload in strings {
            let parsed: [String]
            if payload.hasPrefix("waifux:items:") {
                parsed = String(payload.dropFirst(13))
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { !$0.isEmpty }
            } else if payload.hasPrefix("waifux:item:") {
                parsed = [String(payload.dropFirst(12))]
            } else {
                parsed = []
            }
            for id in parsed where seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    static func ids(fromPasteboard pasteboard: NSPasteboard) -> [String] {
        var strings: [String] = []
        if let objects = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] {
            strings = objects
        } else if let single = pasteboard.string(forType: .string) {
            strings = [single]
        }
        return ids(from: strings)
    }
}

// MARK: - Cell 配置模型

struct LibraryWallpaperCellModel {
    let wallpaper: Wallpaper
    let localFileURL: URL?
    let isEditing: Bool
    let isSelected: Bool
    let isCurrentWallpaper: Bool
    let accent: NSColor
    /// 右键时才求值：构建过程含 optimizableVideoURL 的同步 workshop 探测
    /// （fileExists + 最多 8 层 project.json 读取），不能进 configureCell 滚动热路径。
    let makeMenuEntries: () -> [LibraryGridMenuEntry]
}

struct LibraryMediaCellModel {
    let itemID: String
    let mediaItem: MediaItem
    let localFileURL: URL?
    /// 父视图预计算的列表缩略图（libraryGridThumbnailURL 产物）
    let initialThumbnailURL: URL?
    let shouldProbeAnimatedThumbnail: Bool
    let resolvedVideoFileURL: URL?
    let badgeText: String
    let isEditing: Bool
    let isSelected: Bool
    let isCurrentWallpaper: Bool
    let accent: NSColor
    /// 右键时才求值（同 LibraryWallpaperCellModel，规避 configureCell 热路径磁盘探测）。
    let makeMenuEntries: () -> [LibraryGridMenuEntry]
}

struct LibraryFolderCellModel {
    let folder: LibraryFolder
    let previewURLs: [URL]
    let itemCount: Int
    let isUnlocked: Bool
    let menuEntries: [LibraryGridMenuEntry]
    let onDrop: ([String]) -> Void
    let onRelock: () -> Void
}

struct LibraryAnimeCellModel {
    let anime: AnimeSearchResult
    let isEditing: Bool
    let isSelected: Bool
    let accent: NSColor
}

// MARK: - 共享子视图

/// 胶囊元信息标签（monospaced 10 bold，黑底 0.3，高 20）
final class LibraryCapsuleBadgeView: NSView {
    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.82)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

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

    var preferredSize: CGSize {
        guard !label.stringValue.isEmpty else { return .zero }
        let textSize = label.fittingSize
        guard textSize.width.isFinite, textSize.width > 0 else { return .zero }
        return CGSize(
            width: ceil(textSize.width + 8 * 2),
            height: 20
        )
    }

    func configure(text: String?) {
        label.stringValue = text ?? ""
        isHidden = label.stringValue.isEmpty
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else {
            label.frame = .zero
            return
        }
        let textSize = label.fittingSize
        label.frame = CGRect(
            x: 8,
            y: floor((bounds.height - textSize.height) / 2),
            width: max(0, bounds.width - 16),
            height: max(textSize.height, 1)
        ).integral
    }
}

/// 「当前壁纸使用中」绿色胶囊（checkmark.circle.fill + 文案）
final class LibraryCurrentWallpaperBadgeView: NSView {
    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.95)
        return label
    }()

    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = NSColor.white.withAlphaComponent(0.95)
        return view
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hexString: "34D399").withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 11
        iconView.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        addSubview(iconView)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String) {
        label.stringValue = text
        needsLayout = true
    }

    var preferredSize: CGSize {
        let textSize = label.fittingSize
        // 左右各 8 + 12pt 图标 + 图标与文字 4pt；旧计算少了 6pt，
        // 中文“正在使用”会在胶囊右侧被裁掉。
        return CGSize(width: ceil(8 + 12 + 4 + textSize.width + 8), height: 22)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        iconView.frame = CGRect(x: 8, y: 5, width: 12, height: 12)
        let textSize = label.fittingSize
        label.frame = CGRect(
            x: iconView.frame.maxX + 4,
            y: floor((bounds.height - textSize.height) / 2),
            width: max(0, bounds.width - iconView.frame.maxX - 4 - 8),
            height: max(textSize.height, 1)
        ).integral
    }
}

/// 编辑态左上角复选框
final class LibraryEditCheckboxView: NSView {
    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()

    private let circleBackground: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        return view
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(circleBackground)
        addSubview(iconView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(isSelected: Bool, accent: NSColor) {
        let symbolName = isSelected ? "checkmark.circle.fill" : "circle"
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
        iconView.contentTintColor = isSelected ? accent : NSColor.white.withAlphaComponent(0.8)
        circleBackground.layer?.backgroundColor = (
            isSelected ? NSColor.white : NSColor.black.withAlphaComponent(0.4)
        ).cgColor
    }

    override func layout() {
        super.layout()
        circleBackground.frame = CGRect(x: 1, y: 1, width: 20, height: 20)
        iconView.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
    }
}

// MARK: - 壁纸卡 Cell

/// 还原 WallpaperEditCard 视觉：180pt 封面 + 44pt 信息栏（作者 + heart/eye/file 统计）
final class LibraryWallpaperGridCell: ExploreGridItem {
    static let newReuseIdentifier = NSUserInterfaceItemIdentifier("LibraryWallpaperGridCell")
    override class var gridReuseIdentifier: NSUserInterfaceItemIdentifier { newReuseIdentifier }

    private enum Layout {
        static let infoBarHeight = LibraryGridCellMetrics.infoBarHeight
        static let cornerRadius = LibraryGridCellMetrics.cornerRadius
        static let overlayPadding: CGFloat = 12
        static let horizontalPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 12
    }

    private var currentModel: LibraryWallpaperCellModel?
    private var menuActionTargets: [LibraryMenuActionTarget] = []

    /// 本地静图 SSD 列表缩略图（生成后替换远程封面）
    private var localThumbEnsureTask: Task<Void, Never>?
    private var localThumbIdleToken: UUID?
    /// `.equatable()` 旧卡片不会在数据未变时重新挂载 KFImage；AppKit cell
    /// 需要自己记住当前源，避免详情返回/状态刷新时重复 setImage 造成闪屏。
    private var coverSourceKey: String?
    private var coverLoadGeneration = 0

    private let bottomBar: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.cgColor
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

    private let heartStat = LibraryStatLabelView()
    private let eyeStat = LibraryStatLabelView()
    private let fileStat = LibraryStatLabelView()

    private let categoryBadge = LibraryCapsuleBadgeView()
    private let purityBadge = LibraryCapsuleBadgeView()
    private let resolutionBadge = LibraryCapsuleBadgeView()
    private let checkboxView = LibraryEditCheckboxView()
    private let selectionMask: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        return view
    }()
    private let currentBadge = LibraryCurrentWallpaperBadgeView()

    override var hoverScaleFactor: CGFloat { 1.01 }
    override var shouldAnimateBorderOnHover: Bool { true }
    override var allowsHoverInteraction: Bool { currentModel?.isEditing != true }

    override func setupContentLayout() {
        containerView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(Layout.cornerRadius)
        setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.08))

        contentView.addSubview(bottomBar)
        bottomBar.addSubview(titleLabel)
        bottomBar.addSubview(heartStat)
        bottomBar.addSubview(eyeStat)
        bottomBar.addSubview(fileStat)

        contentView.addSubview(categoryBadge)
        contentView.addSubview(purityBadge)
        contentView.addSubview(resolutionBadge)
        contentView.addSubview(checkboxView)
        contentView.addSubview(selectionMask)
        contentView.addSubview(currentBadge)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentModel = nil
        titleLabel.stringValue = ""
        coverImageView.kf.cancelDownloadTask()
        coverSourceKey = nil
        coverLoadGeneration &+= 1
        localThumbEnsureTask?.cancel()
        localThumbEnsureTask = nil
        if let token = localThumbIdleToken {
            LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
            localThumbIdleToken = nil
        }
        menuActionTargets.removeAll()
        [categoryBadge, purityBadge, resolutionBadge].forEach { $0.configure(text: nil) }
        checkboxView.isHidden = true
        selectionMask.isHidden = true
        currentBadge.isHidden = true
    }

    override func configure(with item: Any, isFavorite: Bool) {
        guard let model = item as? LibraryWallpaperCellModel else { return }
        currentModel = model
        if model.isEditing {
            clearHover(animated: false)
        }

        titleLabel.stringValue = model.wallpaper.uploader?.username ?? model.wallpaper.categoryDisplayName
        categoryBadge.configure(text: model.wallpaper.categoryDisplayName)
        purityBadge.configure(text: model.wallpaper.purityDisplayName)
        resolutionBadge.configure(text: model.wallpaper.resolution)
        heartStat.configure(icon: "heart.fill", value: compactNumber(model.wallpaper.favorites), tint: NSColor(hexString: "FF5A7D"))
        eyeStat.configure(icon: "eye.fill", value: compactNumber(model.wallpaper.views), tint: NSColor.white.withAlphaComponent(0.5))
        fileStat.configure(icon: "doc.fill", value: model.wallpaper.fileSizeLabel, tint: NSColor.white.withAlphaComponent(0.5))

        checkboxView.configure(isSelected: model.isSelected, accent: model.accent)
        checkboxView.isHidden = !model.isEditing
        selectionMask.isHidden = !(model.isEditing && model.isSelected)
        if !model.isEditing, model.isCurrentWallpaper {
            currentBadge.configure(text: t("wallpaper.currentlyActive"))
            currentBadge.isHidden = false
        } else {
            currentBadge.isHidden = true
        }

        loadCoverImages(model: model)

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
        let imageHeight = max(0, bounds.height - Layout.infoBarHeight)
        coverImageView.frame = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        coverImageView.layer?.cornerRadius = 0
        coverImageView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.cgColor

        bottomBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.infoBarHeight)
        titleLabel.frame = CGRect(
            x: Layout.horizontalPadding,
            y: floor((Layout.infoBarHeight - 16) / 2),
            width: max(40, bounds.width - Layout.horizontalPadding * 2 - 150),
            height: 16
        ).integral

        // 右侧统计：heart / eye / file 依次向左排
        var nextMaxX = bounds.width - Layout.horizontalPadding
        for stat in [fileStat, eyeStat, heartStat] {
            if stat.isHidden { continue }
            let size = stat.preferredSize
            stat.frame = CGRect(
                x: nextMaxX - size.width,
                y: floor((Layout.infoBarHeight - size.height) / 2),
                width: size.width,
                height: size.height
            ).integral
            nextMaxX = stat.frame.minX - 5
        }

        layoutTopBadges(in: bounds, imageHeight: imageHeight)
        layoutSelectionOverlay(in: bounds, imageHeight: imageHeight)
        syncGIFOverlayFrame()
    }

    private func layoutTopBadges(in bounds: CGRect, imageHeight: CGFloat) {
        let topEdge = Layout.infoBarHeight + imageHeight
        var nextX = Layout.overlayPadding
        for badge in [categoryBadge, purityBadge] where !badge.isHidden {
            let size = badge.preferredSize
            guard size.width > 0 else { continue }
            badge.frame = CGRect(
                x: nextX,
                y: topEdge - Layout.overlayPadding - size.height,
                width: size.width,
                height: size.height
            ).integral
            nextX = badge.frame.maxX + 8
        }
        if !resolutionBadge.isHidden {
            let size = resolutionBadge.preferredSize
            resolutionBadge.frame = CGRect(
                x: bounds.width - Layout.overlayPadding - size.width,
                y: topEdge - Layout.overlayPadding - size.height,
                width: size.width,
                height: size.height
            ).integral
        }
    }

    private func layoutSelectionOverlay(in bounds: CGRect, imageHeight: CGFloat) {
        checkboxView.frame = CGRect(x: Layout.overlayPadding, y: Layout.infoBarHeight + imageHeight - Layout.overlayPadding - 22, width: 22, height: 22)
        selectionMask.frame = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        if !currentBadge.isHidden {
            let size = currentBadge.preferredSize
            currentBadge.frame = CGRect(
                x: Layout.overlayPadding,
                y: Layout.infoBarHeight + Layout.overlayPadding,
                width: size.width,
                height: size.height
            ).integral
        }
        syncGIFOverlayFrame()
    }

    override func cellMenu(for event: NSEvent) -> NSMenu? {
        guard let model = currentModel else { return nil }
        let entries = model.makeMenuEntries()
        guard !entries.isEmpty else { return nil }
        return Self.buildMenu(from: entries, targets: &menuActionTargets)
    }

    static func buildMenu(
        from entries: [LibraryGridMenuEntry],
        targets: inout [LibraryMenuActionTarget]
    ) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            switch entry {
            case .divider:
                menu.addItem(.separator())
            case let .item(title, icon, destructive, handler):
                let target = LibraryMenuActionTarget(handler)
                targets.append(target)
                let menuItem = NSMenuItem(
                    title: title,
                    action: #selector(LibraryMenuActionTarget.performAction),
                    keyEquivalent: ""
                )
                menuItem.target = target
                if let icon {
                    let symbolConfiguration = NSImage.SymbolConfiguration(
                        pointSize: 13,
                        weight: .regular
                    ).applying(
                        destructive
                            ? NSImage.SymbolConfiguration(hierarchicalColor: NSColor.systemRed)
                            : NSImage.SymbolConfiguration()
                    )
                    menuItem.image = NSImage(
                        systemSymbolName: icon,
                        accessibilityDescription: nil
                    )?.withSymbolConfiguration(symbolConfiguration)
                }
                if destructive {
                    menuItem.attributedTitle = NSAttributedString(
                        string: title,
                        attributes: [.foregroundColor: NSColor.systemRed]
                    )
                }
                menu.addItem(menuItem)
            case let .submenu(title, icon, subEntries):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let icon {
                    menuItem.image = NSImage(
                        systemSymbolName: icon,
                        accessibilityDescription: nil
                    )?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
                }
                menuItem.submenu = buildMenu(from: subEntries, targets: &targets)
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    // MARK: 封面

    /// 封面加载选项：与旧 WallpaperEditCard 的 KFImage 完全同源
    /// （512 固定降采样、disk 缓存、300s 内存缓存）。不走基类 loadImage 管线。
    private static let coverImageOptions: KingfisherOptionsInfo = [
        .processor(DownsamplingImageProcessor(size: CGSize(width: 512, height: 512))),
        .backgroundDecode,
        .keepCurrentImageWhileLoading,
        .memoryCacheExpiration(.seconds(300)),
        .retryStrategy(DelayRetryStrategy(maxRetryCount: 1, retryInterval: .seconds(0.5)))
    ]

    /// 封面候选（与旧 WallpaperEditCard.resolvedThumbURL 同源）：
    /// SSD 列表缩略图 > 站点 thumb。两者都存在时本地优先，失败自动回退另一张。
    private func loadCoverImages(model: LibraryWallpaperCellModel) {
        var candidates: [URL] = []
        if let local = model.localFileURL,
           local.isFileURL,
           LocalImageThumbnailCache.isRasterImageFile(local),
           let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
            candidates.append(cached)
        }
        if let remote = model.wallpaper.thumbURL ?? model.wallpaper.smallThumbURL,
           !candidates.contains(remote) {
            candidates.append(remote)
        }
        loadCoverCandidates(candidates, model: model)
        ensureLocalListThumbnail(model: model)
    }

    private func loadCoverCandidates(_ candidates: [URL], model: LibraryWallpaperCellModel) {
        guard currentModel?.wallpaper.id == model.wallpaper.id else { return }
        let sourceKey = candidates.first?.absoluteString ?? "<empty>"
        guard sourceKey != coverSourceKey else { return }

        coverSourceKey = sourceKey
        coverLoadGeneration &+= 1
        let generation = coverLoadGeneration
        coverImageView.kf.cancelDownloadTask()
        loadCoverCandidate(
            at: 0,
            candidates: candidates,
            model: model,
            generation: generation
        )
    }

    /// 依次尝试候选：失败（文件缺失/下载失败）落到下一个；全部失败才留空。
    private func loadCoverCandidate(
        at index: Int,
        candidates: [URL],
        model: LibraryWallpaperCellModel,
        generation: Int
    ) {
        guard index < candidates.count, currentModel?.wallpaper.id == model.wallpaper.id else {
            if index == 0 {
                // 无任何候选：保留现有图，避免详情返回或后台刷新时出现黑闪。
                coverSourceKey = nil
            }
            return
        }
        coverImageView.kf.setImage(
            with: candidates[index],
            options: Self.coverImageOptions + [.transition(.none)],
            completionHandler: { [weak self] result in
                guard case .failure = result else { return }
                guard let self,
                      self.coverLoadGeneration == generation,
                      self.currentModel?.wallpaper.id == model.wallpaper.id else { return }
                self.loadCoverCandidate(
                    at: index + 1,
                    candidates: candidates,
                    model: model,
                    generation: generation
                )
            }
        )
    }

    /// 外置原图 → 本机 SSD 512 列表缩略图；有远程 thumb 时列表先显示远程，滚停后再补本地缓存。
    private func ensureLocalListThumbnail(model: LibraryWallpaperCellModel) {
        guard let local = model.localFileURL,
              local.isFileURL,
              LocalImageThumbnailCache.isRasterImageFile(local) else { return }
        guard currentModel?.wallpaper.id == model.wallpaper.id else { return }

        if let token = localThumbIdleToken {
            LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
            localThumbIdleToken = nil
        }

        if LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) != nil {
            return
        }

        // 滚动中不生成：滚停后再写 SSD
        guard !LibraryScrollHoverGate.shared.isScrolling else {
            let token = UUID()
            localThumbIdleToken = token
            LibraryScrollHoverGate.shared.runWhenIdle(token: token) { [weak self] in
                guard let self, self.localThumbIdleToken == token else { return }
                self.localThumbIdleToken = nil
                self.startLocalThumbnailTask(local: local, wallpaperID: model.wallpaper.id)
            }
            return
        }
        startLocalThumbnailTask(local: local, wallpaperID: model.wallpaper.id)
    }

    private func startLocalThumbnailTask(local: URL, wallpaperID: String) {
        localThumbEnsureTask?.cancel()
        localThumbEnsureTask = Task { [weak self] in
            guard !LibraryScrollHoverGate.shared.isScrolling else { return }
            guard let thumb = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: local) else {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, let model = self.currentModel,
                  model.wallpaper.id == wallpaperID else { return }
            // SSD 小图就绪：替换（失败保持现有封面不动）
            self.loadCoverCandidates([thumb], model: model)
        }
    }

    private func compactNumber(_ number: Int) -> String {
        if number >= 1_000_000 {
            return String(format: "%.1fM", Double(number) / 1_000_000)
        } else if number >= 1_000 {
            return String(format: "%.1fK", Double(number) / 1_000)
        }
        return String(number)
    }
}

/// 信息栏右侧统计项（SF icon + monospaced 数字）
final class LibraryStatLabelView: NSView {
    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()

    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.7)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(iconView)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var preferredSize: CGSize {
        guard !label.stringValue.isEmpty else { return .zero }
        let textSize = label.fittingSize
        return CGSize(width: ceil(12 + 4 + textSize.width), height: max(14, textSize.height))
    }

    func configure(icon: String, value: String, tint: NSColor) {
        label.stringValue = value
        iconView.image = NSImage(
            systemSymbolName: icon,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        iconView.contentTintColor = tint
        isHidden = value.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0, !isHidden else { return }
        iconView.frame = CGRect(x: 0, y: floor((bounds.height - 11) / 2), width: 12, height: 11)
        let textSize = label.fittingSize
        label.frame = CGRect(
            x: iconView.frame.maxX + 4,
            y: floor((bounds.height - textSize.height) / 2),
            width: max(0, bounds.width - iconView.frame.maxX - 4),
            height: max(textSize.height, 1)
        ).integral
    }
}

// MARK: - 媒体卡 Cell

/// 还原 MediaVideoCard 视觉，GIF hover 播放走 ExploreGridItem 覆盖播放管线
/// （中间帧起播 + 与静态封面同比例 aspect-fill）。
final class LibraryMediaGridCell: ExploreGridItem {
    static let newReuseIdentifier = NSUserInterfaceItemIdentifier("LibraryMediaGridCell")
    override class var gridReuseIdentifier: NSUserInterfaceItemIdentifier { newReuseIdentifier }

    private enum Layout {
        static let infoBarHeight = LibraryGridCellMetrics.infoBarHeight
        static let cornerRadius = LibraryGridCellMetrics.cornerRadius
        static let overlayPadding: CGFloat = 12
        static let horizontalPadding: CGFloat = 14
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]

    private var currentModel: LibraryMediaCellModel?
    private var menuActionTargets: [LibraryMenuActionTarget] = []

    /// 异步解析出的更清晰列表封面（视频抽帧 / SSD 静图小图 / scene bake 帧）
    private var resolvedThumbnailURL: URL?
    private var thumbnailRefreshTask: Task<Void, Never>?
    private var thumbnailIdleToken: UUID?

    // hover GIF
    private var hoverGIFFetchTask: Task<Void, Never>?
    private var resolvedGIFURL: URL?
    private var resolvedGIFItemID: String?
    private var resolvedGIFData: Data?
    /// `.equatable()` 旧卡片不会在数据未变时重挂 KFImage；AppKit cell
    /// 需要自己保持封面源，避免详情返回时静态封面短暂消失。
    private var coverSourceKey: String?
    private var coverLoadGeneration = 0
    private var shouldRestoreHoverAfterConfigure = false

    private let bottomBar: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.cgColor
        return view
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14.5, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    private let subtitleBadge = LibraryCapsuleBadgeView()
    private let trailingBadge = LibraryCapsuleBadgeView()
    private let checkboxView = LibraryEditCheckboxView()
    private let selectionMask: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        return view
    }()
    private let currentBadge = LibraryCurrentWallpaperBadgeView()

    override var hoverScaleFactor: CGFloat { 1.01 }
    override var shouldAnimateBorderOnHover: Bool { true }
    override var usesGIFOverlay: Bool { true }
    override var allowsHoverInteraction: Bool { currentModel?.isEditing != true }

    override func setupContentLayout() {
        containerView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(Layout.cornerRadius)
        setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.08))

        contentView.addSubview(bottomBar)
        bottomBar.addSubview(titleLabel)

        contentView.addSubview(subtitleBadge)
        contentView.addSubview(trailingBadge)
        contentView.addSubview(checkboxView)
        contentView.addSubview(selectionMask)
        contentView.addSubview(currentBadge)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // selector 版观察者：观察者是 self（cell 复用生命周期），无需保存 token
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneBakeThumbnailDidUpdate(_:)),
            name: .sceneOfflineBakeThumbnailDidUpdate,
            object: nil
        )
    }

    @objc private func sceneBakeThumbnailDidUpdate(_ notification: Notification) {
        guard let updatedItemID = notification.object as? String,
              let model = currentModel,
              updatedItemID == model.itemID else { return }
        // 同 path 的 list_*.jpg / scene_bake_*.jpg 可能仍吃旧内存图：清缓存强制重载
        resolvedThumbnailURL = nil
        coverSourceKey = nil
        let cache = KingfisherManager.shared.cache
        let processorIdentifier = GIFAwareMiddleFrameImageProcessor(
            targetSize: CGSize(width: 512, height: 512),
            scaleFactor: 2
        ).identifier
        let cacheKeys = [
            model.initialThumbnailURL?.cacheKey,
            (notification.userInfo?["thumbnailURL"] as? URL)?.cacheKey
        ].compactMap { $0 }
        for key in Set(cacheKeys) {
            cache.removeImage(forKey: key)
            cache.removeImage(forKey: key, processorIdentifier: processorIdentifier)
        }
        if let newURL = notification.userInfo?["thumbnailURL"] as? URL {
            resolvedThumbnailURL = newURL
            loadCoverImages(preferredURL: newURL, model: model)
        } else {
            loadCoverImages(preferredURL: nil, model: model)
            scheduleThumbnailRefresh()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            NotificationCenter.default.removeObserver(self)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentModel = nil
        titleLabel.stringValue = ""
        coverImageView.kf.cancelDownloadTask()
        coverSourceKey = nil
        coverLoadGeneration &+= 1
        resolvedThumbnailURL = nil
        thumbnailRefreshTask?.cancel()
        thumbnailRefreshTask = nil
        if let token = thumbnailIdleToken {
            LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
            thumbnailIdleToken = nil
        }
        teardownHoverGIFPlayback()
        resolvedGIFURL = nil
        resolvedGIFItemID = nil
        resolvedGIFData = nil
        menuActionTargets.removeAll()
        subtitleBadge.configure(text: nil)
        trailingBadge.configure(text: nil)
        checkboxView.isHidden = true
        selectionMask.isHidden = true
        currentBadge.isHidden = true
    }

    override func configure(with item: Any, isFavorite: Bool) {
        guard let model = item as? LibraryMediaCellModel else { return }
        if currentModel?.itemID != model.itemID {
            // 复用时不能把旧卡的 hover 直接带给新项目；滚动中的 hover
            // 由 coordinator 在滚停后根据真实鼠标位置统一恢复。
            shouldRestoreHoverAfterConfigure = !LibraryScrollHoverGate.shared.isScrolling && isHovered
            teardownHoverGIFPlayback()
            resolvedGIFURL = nil
            resolvedGIFItemID = nil
            resolvedGIFData = nil
            resolvedThumbnailURL = nil
        }
        currentModel = model

        titleLabel.stringValue = model.mediaItem.title
        subtitleBadge.configure(text: model.mediaItem.subtitle)
        let showTrailing = !model.badgeText.isEmpty && model.badgeText != model.mediaItem.subtitle
        trailingBadge.configure(text: showTrailing ? model.badgeText : nil)

        checkboxView.configure(isSelected: model.isSelected, accent: model.accent)
        checkboxView.isHidden = !model.isEditing
        selectionMask.isHidden = !(model.isEditing && model.isSelected)
        if !model.isEditing, model.isCurrentWallpaper {
            currentBadge.configure(text: t("wallpaper.currentlyActive"))
            currentBadge.isHidden = false
        } else {
            currentBadge.isHidden = true
        }

        loadCoverImages(preferredURL: resolvedThumbnailURL, model: model)
        scheduleThumbnailRefresh()

        if containerView.bounds.width > 0, containerView.bounds.height > 0 {
            layoutContentFrames()
        } else {
            view.needsLayout = true
            containerView.needsLayout = true
            contentView.needsLayout = true
        }

        if model.isEditing {
            clearHover(animated: false)
            shouldRestoreHoverAfterConfigure = false
        } else if shouldRestoreHoverAfterConfigure {
            shouldRestoreHoverAfterConfigure = false
            _ = updateHoverStateFromCurrentMouseLocation(animated: false)
        }
    }

    override func layoutContentFrames() {
        let bounds = containerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        contentView.frame = bounds
        let imageHeight = max(0, bounds.height - Layout.infoBarHeight)
        coverImageView.frame = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        coverImageView.layer?.cornerRadius = 0
        coverImageView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.cgColor

        bottomBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.infoBarHeight)
        titleLabel.frame = CGRect(
            x: Layout.horizontalPadding,
            y: floor((Layout.infoBarHeight - 17) / 2),
            width: max(40, bounds.width - Layout.horizontalPadding * 2),
            height: 17
        ).integral

        let topEdge = Layout.infoBarHeight + imageHeight
        if !subtitleBadge.isHidden {
            let size = subtitleBadge.preferredSize
            subtitleBadge.frame = CGRect(
                x: Layout.overlayPadding,
                y: topEdge - Layout.overlayPadding - size.height,
                width: size.width,
                height: size.height
            ).integral
        }
        if !trailingBadge.isHidden {
            let size = trailingBadge.preferredSize
            trailingBadge.frame = CGRect(
                x: bounds.width - Layout.overlayPadding - size.width,
                y: topEdge - Layout.overlayPadding - size.height,
                width: size.width,
                height: size.height
            ).integral
        }

        checkboxView.frame = CGRect(x: Layout.overlayPadding, y: topEdge - Layout.overlayPadding - 22, width: 22, height: 22)
        selectionMask.frame = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        if !currentBadge.isHidden {
            let size = currentBadge.preferredSize
            currentBadge.frame = CGRect(
                x: Layout.overlayPadding,
                y: Layout.infoBarHeight + Layout.overlayPadding,
                width: size.width,
                height: size.height
            ).integral
        }
        syncGIFOverlayFrame()
    }

    override func cellMenu(for event: NSEvent) -> NSMenu? {
        guard let model = currentModel else { return nil }
        let entries = model.makeMenuEntries()
        guard !entries.isEmpty else { return nil }
        return LibraryWallpaperGridCell.buildMenu(from: entries, targets: &menuActionTargets)
    }

    // MARK: 封面

    private func loadCoverImages(preferredURL: URL?, model: LibraryMediaCellModel) {
        var rawCandidates: [URL] = []
        for url in [preferredURL, model.initialThumbnailURL, Optional(model.mediaItem.coverImageURL)] {
            guard let url, !rawCandidates.contains(url) else { continue }
            rawCandidates.append(url)
        }
        // 静态抽帧 / 普通 poster 始终优先。GIF 只能在没有静态候选或所有静态候选
        // 加载失败时接手，避免滚动期间看到 GIF 的中间帧替代正式封面。
        let candidates = rawCandidates.filter { !Self.isGIFStaticFallback($0, model: model) }
            + rawCandidates.filter { Self.isGIFStaticFallback($0, model: model) }
        loadCoverCandidates(candidates, model: model)
    }

    private static func isGIFStaticFallback(_ url: URL, model: LibraryMediaCellModel) -> Bool {
        if MediaItem.urlLooksLikeGIF(url) {
            return true
        }
        let staticImageExtensions: Set<String> = [
            "jpg", "jpeg", "png", "webp", "heic", "heif", "avif", "bmp", "tiff", "tif"
        ]
        if staticImageExtensions.contains(url.pathExtension.lowercased()) {
            return false
        }
        // 有些站点 URL 没有 .gif 后缀；抓取时已有动画元数据时，将原始封面
        // 视作 GIF fallback，不能让它压过本地的静态抽帧。
        guard model.mediaItem.isAnimatedImage == true else { return false }
        return url == model.mediaItem.posterURL
            || url == model.mediaItem.thumbnailURL
            || url == model.mediaItem.coverImageURL
    }

    private func loadCoverCandidates(_ candidates: [URL], model: LibraryMediaCellModel) {
        guard currentModel?.itemID == model.itemID else { return }
        let sourceKey = candidates.first?.absoluteString ?? "<empty>"
        guard sourceKey != coverSourceKey else { return }

        coverSourceKey = sourceKey
        coverLoadGeneration &+= 1
        let generation = coverLoadGeneration
        coverImageView.kf.cancelDownloadTask()
        loadCoverCandidate(
            at: 0,
            candidates: candidates,
            model: model,
            generation: generation
        )
    }

    /// 与旧 MediaVideoCard 的 KFImage 同源：512 固定降采样直连加载。
    /// GIF 候选（本地 .gif / preview.gif / 站点动图）用中间帧处理器避免黑色开场帧；
    /// 其余（视频抽帧 jpg / SSD 小图 / 普通远端图）走原版 Downsampling。
    /// 失败自动落到下一个候选；全部失败才留空。
    private func loadCoverCandidate(
        at index: Int,
        candidates: [URL],
        model: LibraryMediaCellModel,
        generation: Int
    ) {
        guard index < candidates.count, currentModel?.itemID == model.itemID else {
            if index == 0 {
                // 保留已有封面，失败时不要在详情返回/后台刷新期间闪成空白。
                coverSourceKey = nil
            }
            return
        }
        let url = candidates[index]
        let target = CGSize(width: 512, height: 512)
        // 处理器会按数据格式分流，普通图片仍走 Downsampling；GIF 不论 URL
        // 是否带 .gif 后缀都取中间帧，保证默认静态封面不是首帧黑图。
        let processor: ImageProcessor = GIFAwareMiddleFrameImageProcessor(
            targetSize: target,
            scaleFactor: 2
        )
        coverImageView.kf.setImage(
            with: url,
            options: [
                .processor(processor),
                .backgroundDecode,
                .keepCurrentImageWhileLoading,
                .memoryCacheExpiration(.seconds(300)),
                .transition(.none),
                .retryStrategy(DelayRetryStrategy(maxRetryCount: 1, retryInterval: .seconds(0.5)))
            ],
            completionHandler: { [weak self] result in
                guard case .failure = result else { return }
                guard let self,
                      self.coverLoadGeneration == generation,
                      self.currentModel?.itemID == model.itemID else { return }
                self.loadCoverCandidate(
                    at: index + 1,
                    candidates: candidates,
                    model: model,
                    generation: generation
                )
            }
        )
    }

    // MARK: hover GIF

    override func hoverStateDidChange(_ hovering: Bool) {
        guard !LibraryScrollHoverGate.shared.isScrolling else {
            if !hovering {
                teardownHoverGIFPlayback()
            }
            return
        }
        if hovering {
            startHoverGIFPlaybackIfNeeded()
        } else {
            teardownHoverGIFPlayback()
        }
    }

    /// 动画源候选：本地 gif > workshop preview.gif > 列表缩略图 gif；
    /// 与旧 MediaVideoCard.animatedGIFSourceURL 同一优先级。
    private var animatedGIFCandidates: [URL] {
        guard let model = currentModel else { return [] }
        var urls: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL?) {
            guard let url else { return }
            guard seen.insert(url.absoluteString).inserted else { return }
            urls.append(url)
        }

        if let local = model.localFileURL, LocalImageThumbnailCache.isGIFFile(local) {
            append(local)
        }
        if let local = model.localFileURL,
           local.isFileURL,
           FileExistenceCache.shared.isDirectory(atPath: local.path),
           let preview = MediaItem.resolveLocalWorkshopPreviewGIF(from: local),
           LocalImageThumbnailCache.isGIFFile(preview) {
            append(preview)
        }
        // 与旧 MediaVideoCard.animatedProbeCandidates 对齐：不能只探测当前列表
        // 封面，否则本地静态抽帧存在时会漏掉 MediaItem.posterURL 里的真实 GIF。
        for candidate in [
            resolvedThumbnailURL,
            model.initialThumbnailURL,
            model.mediaItem.posterURL,
            model.mediaItem.thumbnailURL,
            model.mediaItem.coverImageURL
        ] {
            guard let candidate else { continue }
            let path = candidate.standardizedFileURL.path
            let isGeneratedStatic = candidate.isFileURL
                && (path.contains("/WaifuX/VideoThumbnails/")
                    || path.contains("/WaifuX/LocalImageThumbnails/"))
            if !isGeneratedStatic || LocalImageThumbnailCache.isGIFFile(candidate) {
                append(candidate)
            }
        }
        return urls
    }

    private func startHoverGIFPlaybackIfNeeded() {
        guard !LibraryScrollHoverGate.shared.isScrolling,
              isHovered,
              let model = currentModel else { return }
        let itemID = model.itemID

        if isPlayingGIFOverlay, resolvedGIFItemID == itemID { return }

        let candidates = animatedGIFCandidates
        guard !candidates.isEmpty else { return }
        guard model.shouldProbeAnimatedThumbnail
            || candidates.contains(where: { $0.isFileURL && LocalImageThumbnailCache.isGIFFile($0) })
            || candidates.contains(where: { $0.pathExtension.lowercased() == "gif" }) else {
            return
        }

        if let cachedData = resolvedGIFData, resolvedGIFItemID == itemID {
            hoverGIFFetchTask?.cancel()
            hoverGIFFetchTask = Task { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      !LibraryScrollHoverGate.shared.isScrolling,
                      self.isHovered,
                      self.currentModel?.itemID == itemID else { return }
                _ = await self.playGIFOverlayAsync(data: cachedData)
            }
            return
        }

        hoverGIFFetchTask?.cancel()
        hoverGIFFetchTask = Task { [weak self] in
            for url in candidates {
                guard !Task.isCancelled,
                      let self,
                      let data = await self.retrieveAnimatedGIFData(from: url) else {
                    continue
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.isHovered,
                          !LibraryScrollHoverGate.shared.isScrolling,
                          self.currentModel?.itemID == itemID else { return }
                    self.resolvedGIFURL = url
                    self.resolvedGIFItemID = itemID
                    self.resolvedGIFData = data
                }
                guard !Task.isCancelled else { return }
                guard !LibraryScrollHoverGate.shared.isScrolling,
                      self.isHovered,
                      self.currentModel?.itemID == itemID else { return }
                _ = await self.playGIFOverlayAsync(data: data)
                return
            }
        }
    }

    private func teardownHoverGIFPlayback() {
        hoverGIFFetchTask?.cancel()
        hoverGIFFetchTask = nil
        stopGIFOverlayPlayback()
        // hover 结束即释放 GIF 原始数据（大 GIF 可达数十 MB，连续 hover 多卡会累积）；
        // 已探测的 URL 保留，再次 hover 命中 Kingfisher 磁盘缓存
        resolvedGIFData = nil
    }

    // MARK: 列表缩略图异步解析（抽帧 / SSD 小图 / scene bake，对齐 MediaVideoCard.triggerThumbnailIfNeeded）

    private func scheduleThumbnailRefresh() {
        guard let model = currentModel else { return }
        if let token = thumbnailIdleToken {
            LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
            thumbnailIdleToken = nil
        }
        guard !LibraryScrollHoverGate.shared.isScrolling else {
            let token = UUID()
            thumbnailIdleToken = token
            LibraryScrollHoverGate.shared.runWhenIdle(token: token) { [weak self] in
                guard let self, self.thumbnailIdleToken == token else { return }
                self.thumbnailIdleToken = nil
                self.refreshListThumbnailSource(model: model)
            }
            return
        }
        refreshListThumbnailSource(model: model)
    }

    private func applyResolvedThumbnail(_ url: URL) {
        guard let model = currentModel, resolvedThumbnailURL != url else { return }
        if Self.isGIFStaticFallback(url, model: model),
           hasStaticCoverCandidate(model: model) {
            return
        }
        resolvedThumbnailURL = url
        loadCoverImages(preferredURL: url, model: model)
    }

    private func hasStaticCoverCandidate(model: LibraryMediaCellModel) -> Bool {
        [resolvedThumbnailURL, model.initialThumbnailURL, model.mediaItem.coverImageURL]
            .compactMap { $0 }
            .contains { !Self.isGIFStaticFallback($0, model: model) }
    }

    private func refreshListThumbnailSource(model: LibraryMediaCellModel) {
        thumbnailRefreshTask?.cancel()
        thumbnailRefreshTask = Task { [weak self] in
            await self?.refreshListThumbnailSourceStep(model: model)
        }
    }

    private func refreshListThumbnailSourceStep(model: LibraryMediaCellModel) async {
        guard currentModel?.itemID == model.itemID else { return }
        let videoCache = VideoThumbnailCache.shared
        let item = model.mediaItem

        // Scene 烘焙：优先列表小图；有 poster 先占位再后台补完整画幅帧
        if let bakedPath = MediaLibraryService.shared.downloadRecord(for: item.id)?.sceneBakeArtifact?.videoPath,
           !bakedPath.isEmpty {
            let bakedVideo = URL(fileURLWithPath: bakedPath)
            if let listThumb = videoCache.cachedListThumbnailFileURLIfExists(forLocalVideo: bakedVideo) {
                applyResolvedThumbnail(listThumb)
                return
            }
            if let hd = videoCache.cachedSceneBakePosterFileURLIfExists(itemID: item.id) {
                applyResolvedThumbnail(hd)
            }
            guard !LibraryScrollHoverGate.shared.isScrolling else { return }
            if let listThumb = await videoCache.listThumbnailJPEGFileURL(forLocalVideo: bakedVideo) {
                applyResolvedThumbnail(listThumb)
            } else if let poster = await videoCache.sceneBakePosterJPEGFileURL(
                forLocalVideo: bakedVideo,
                itemID: item.id
            ) {
                applyResolvedThumbnail(poster)
            }
            return
        }

        if let poster = videoCache.cachedSceneBakePosterFileURLIfExists(itemID: item.id) {
            applyResolvedThumbnail(poster)
            return
        }

        guard let local = model.localFileURL, local.isFileURL else { return }
        let ext = local.pathExtension.lowercased()

        // GIF：直接用原文件
        if ext == "gif" {
            applyResolvedThumbnail(local)
            return
        }

        // 静图：只读已有 SSD 缓存；缺失时滚停后生成
        if LocalImageThumbnailCache.isRasterImageFile(local) {
            if let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
                applyResolvedThumbnail(cached)
                return
            }
            guard !LibraryScrollHoverGate.shared.isScrolling else { return }
            if let thumb = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: local) {
                applyResolvedThumbnail(thumb)
            }
            return
        }

        // 直出视频文件 / 父视图已解析的内部视频
        if Self.videoExtensions.contains(ext) {
            await applyVideoListThumbnail(for: local)
            return
        }
        if let resolved = model.resolvedVideoFileURL,
           Self.videoExtensions.contains(resolved.pathExtension.lowercased()) {
            await applyVideoListThumbnail(for: resolved)
            return
        }

        // Workshop 目录：有内部视频则抽帧；否则 preview / GIF
        guard !LibraryScrollHoverGate.shared.isScrolling else { return }
        let exists = await local.fileExistsAsync()
        guard currentModel?.itemID == model.itemID else { return }
        guard exists else { return }

        if let resolved = MediaItem.resolveLocalVideoFile(from: local),
           Self.videoExtensions.contains(resolved.pathExtension.lowercased()) {
            await applyVideoListThumbnail(for: resolved)
            return
        }

        if let localPreview = MediaItem.resolveLocalWorkshopPreviewImage(from: local) {
            if LocalImageThumbnailCache.isGIFFile(localPreview) {
                applyResolvedThumbnail(localPreview)
                return
            }
            if LocalImageThumbnailCache.isRasterImageFile(localPreview) {
                if let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: localPreview) {
                    applyResolvedThumbnail(cached)
                    return
                }
                if let thumb = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: localPreview) {
                    applyResolvedThumbnail(thumb)
                } else {
                    applyResolvedThumbnail(localPreview)
                }
                return
            }
            applyResolvedThumbnail(localPreview)
            return
        }
    }

    /// 列表视频封面：已有缓存直接用；否则后台生成列表帧，失败回退高清 poster。
    private func applyVideoListThumbnail(for videoURL: URL) async {
        let videoCache = VideoThumbnailCache.shared
        if let cached = videoCache.cachedStaticThumbnailFileURLIfExists(forLocalFile: videoURL) {
            applyResolvedThumbnail(cached)
            FileExistenceCache.shared.markExisting(atPath: videoURL.path)
            return
        }
        guard !LibraryScrollHoverGate.shared.isScrolling else { return }
        if let listThumb = await videoCache.listThumbnailJPEGFileURL(forLocalVideo: videoURL) {
            applyResolvedThumbnail(listThumb)
            FileExistenceCache.shared.markExisting(atPath: videoURL.path)
            return
        }
        if let poster = await videoCache.posterJPEGFileURL(forLocalVideo: videoURL) {
            applyResolvedThumbnail(poster)
            FileExistenceCache.shared.markExisting(atPath: videoURL.path)
        }
    }
}

// MARK: - 文件夹卡 Cell

/// 文件夹卡中央 drop 区：浏览态也允许把壁纸/媒体拖入文件夹（协议与旧 SwiftUI dropDestination 一致）
final class LibraryFolderDropView: NSView {
    var onDrop: (([String]) -> Void)?
    var onTargetChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let acceptsDrop = !LibraryDragPayload.ids(fromPasteboard: sender.draggingPasteboard).isEmpty
        onTargetChanged?(acceptsDrop)
        return acceptsDrop ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !LibraryDragPayload.ids(fromPasteboard: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let ids = LibraryDragPayload.ids(fromPasteboard: sender.draggingPasteboard)
        guard !ids.isEmpty else { return false }
        onDrop?(ids)
        onTargetChanged?(false)
        return true
    }
}

/// 还原 LibraryFolderCard：叠图预览 + 加密锁态 + 中央 drop 区 + 计数信息栏
final class LibraryFolderGridCell: ExploreGridItem {
    static let newReuseIdentifier = NSUserInterfaceItemIdentifier("LibraryFolderGridCell")
    override class var gridReuseIdentifier: NSUserInterfaceItemIdentifier { newReuseIdentifier }

    private enum Layout {
        static let infoBarHeight = LibraryGridCellMetrics.infoBarHeight
        static let cornerRadius = LibraryGridCellMetrics.cornerRadius
        static let horizontalPadding: CGFloat = 14
    }

    private var currentModel: LibraryFolderCellModel?
    private var menuActionTargets: [LibraryMenuActionTarget] = []
    private(set) var isDropTarget = false {
        didSet {
            refreshDropVisual()
        }
    }

    /// 叠图槽位（最多 4 张）
    private let stackPreviewViews: [ExploreGridCoverImageView] = (0..<4).map { _ in
        let view = ExploreGridCoverImageView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        view.layer?.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
        view.layer?.shadowRadius = 5
        view.layer?.shadowOffset = CGSize(width: 0, height: -2)
        view.layer?.shadowOpacity = 1
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.minificationFilter = .trilinear
        // 叠图会做轻微旋转；开启图层边缘抗锯齿，避免圆角和斜边出现毛边。
        view.layer?.allowsEdgeAntialiasing = true
        return view
    }

    /// 各叠图槽位当前已加载的 URL key：reload token 变化会高频 reconfigure 可见 cell，
    /// 重复 kf.setImage（即使命中内存缓存也会异步重设图层）是文件夹卡闪动的主因。
    private var previewLoadedKeys: [String?] = [nil, nil, nil, nil]
    private var previewTargetSize: CGSize = .zero

    /// 当前是否处于「锁定且未解锁」的模糊展示态
    private var isPreviewBlurred = false {
        didSet {
            guard isPreviewBlurred != oldValue else { return }
            applyPreviewBlurFilters()
        }
    }

    /// 加锁未解锁时的叠图滤镜：高斯模糊 18 + 降饱和/压暗
    /// （对齐旧 SwiftUI `.blur(radius: 18).saturation(0.82).brightness(-0.04)`）。
    /// 每次创建独立 CIFilter，避免多个复用 cell 共享可变滤镜对象。
    private static func makeLockedPreviewFilters() -> [CIFilter]? {
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(18, forKey: kCIInputRadiusKey)
        guard let color = CIFilter(name: "CIColorControls") else { return [blur] }
        color.setValue(0.82, forKey: kCIInputSaturationKey)
        color.setValue(-0.04, forKey: kCIInputBrightnessKey)
        return [blur, color]
    }

    /// 空文件夹占位图标
    private let placeholderIconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = NSColor.white.withAlphaComponent(0.1)
        return view
    }()
    /// 对齐旧 SwiftUI 图片区的 `.clipped()`：叠图、模糊和缩放都限制在
    /// 封面区内，不能漏到信息栏或卡片边缘。
    private let previewCanvasView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layerUsesCoreImageFilters = true
        return view
    }()

    /// 加密锁态覆盖（对齐旧 LockedFolderOverlay 结构）：
    /// hudWindow 毛玻璃全幅 + 斜向渐变(screen) + 黑色压暗 + 居中超细材质圆形锁徽章
    private let lockEffectView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }()
    private let lockOverlayView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        return view
    }()
    private let lockGradientLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.colors = [
            NSColor.white.withAlphaComponent(0.18).cgColor,
            NSColor.white.withAlphaComponent(0.06).cgColor,
            NSColor.black.withAlphaComponent(0.18).cgColor
        ]
        layer.startPoint = CGPoint(x: 0, y: 1)
        layer.endPoint = CGPoint(x: 1, y: 0)
        return layer
    }()
    private let lockBadgeView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.allowsEdgeAntialiasing = true
        return view
    }()
    private let lockBadgeShadowView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.35
        view.layer?.shadowRadius = 14
        view.layer?.shadowOffset = CGSize(width: 0, height: -4)
        return view
    }()
    private let lockIconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        return view
    }()

    /// 解锁后的「重新锁定」小按钮
    private let relockButton: NSButton = {
        let button = NSButton(image: NSImage(
            systemSymbolName: "lock.fill",
            accessibilityDescription: nil
        ) ?? NSImage(), target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        button.layer?.cornerRadius = 14
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        button.layer?.borderWidth = 1
        // 旧 SwiftUI 按钮为 11pt 图标 + 8pt 内边距，禁止 AppKit 将符号放大填满按钮。
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        button.image = button.image?.withSymbolConfiguration(
            .init(pointSize: 11, weight: .semibold)
        )
        button.toolTip = t("folder.relock")
        return button
    }()

    private let dropView = LibraryFolderDropView()

    private let bottomBar: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }()

    private let nameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    private let countStat = LibraryStatLabelView()

    override var hoverScaleFactor: CGFloat { 1.01 }
    override var shouldAnimateBorderOnHover: Bool { true }

    override func setupContentLayout() {
        containerView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.withAlphaComponent(0.6).cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(Layout.cornerRadius)
        setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.08))

        contentView.addSubview(previewCanvasView)
        for (index, preview) in stackPreviewViews.enumerated() {
            // 数组前面的在顶层（zPosition 递减）
            preview.layer?.zPosition = CGFloat(4 - index)
            previewCanvasView.addSubview(preview)
        }
        previewCanvasView.addSubview(placeholderIconView)
        contentView.addSubview(lockEffectView)
        contentView.addSubview(lockOverlayView)
        lockOverlayView.layer?.addSublayer(lockGradientLayer)
        contentView.addSubview(lockBadgeShadowView)
        lockBadgeShadowView.addSubview(lockBadgeView)
        lockBadgeView.addSubview(lockIconView)
        contentView.addSubview(relockButton)
        contentView.addSubview(dropView)

        contentView.addSubview(bottomBar)
        bottomBar.addSubview(nameLabel)
        bottomBar.addSubview(countStat)

        relockButton.target = self
        relockButton.action = #selector(relockTapped)

        lockIconView.image = NSImage(
            systemSymbolName: "lock.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 28, weight: .bold))
    }

    /// 按当前锁态挂/摘叠图模糊滤镜
    private func applyPreviewBlurFilters() {
        previewCanvasView.layer?.filters = isPreviewBlurred
            ? Self.makeLockedPreviewFilters()
            : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentModel = nil
        menuActionTargets.removeAll()
        nameLabel.stringValue = ""
        isDropTarget = false
        for preview in stackPreviewViews {
            preview.kf.cancelDownloadTask()
            preview.image = nil
            preview.isHidden = true
            preview.layer?.transform = CATransform3DIdentity
        }
        for index in previewLoadedKeys.indices {
            previewLoadedKeys[index] = nil
        }
        previewCanvasView.layer?.filters = nil
        previewTargetSize = .zero
        placeholderIconView.isHidden = true
        lockOverlayView.isHidden = true
        lockEffectView.isHidden = true
        lockBadgeShadowView.isHidden = true
        lockBadgeView.isHidden = true
        relockButton.isHidden = true
        isPreviewBlurred = false
        dropView.onDrop = nil
        dropView.onTargetChanged = nil
    }

    override func configure(with item: Any, isFavorite: Bool) {
        guard let model = item as? LibraryFolderCellModel else { return }
        currentModel = model

        nameLabel.stringValue = model.folder.name
        countStat.configure(
            icon: "photo.on.rectangle.angled",
            value: "\(model.itemCount)",
            tint: NSColor.white.withAlphaComponent(0.5)
        )

        let isLockedAndHidden = model.folder.isLocked && !model.isUnlocked
        lockOverlayView.isHidden = !isLockedAndHidden
        lockEffectView.isHidden = !isLockedAndHidden
        lockBadgeShadowView.isHidden = !isLockedAndHidden
        lockBadgeView.isHidden = !isLockedAndHidden
        relockButton.isHidden = !(model.folder.isLocked && model.isUnlocked)
        isPreviewBlurred = isLockedAndHidden

        dropView.onDrop = { [weak self] ids in
            self?.currentModel?.onDrop(ids)
        }
        dropView.onTargetChanged = { [weak self] isTargeted in
            self?.isDropTarget = isTargeted
        }

        configureStackPreviews(urls: model.previewURLs)

        if containerView.bounds.width > 0, containerView.bounds.height > 0 {
            layoutContentFrames()
        } else {
            view.needsLayout = true
            containerView.needsLayout = true
            contentView.needsLayout = true
        }
    }

    /// 叠图布局：与 FolderStackView 相同的偏移/旋转（SwiftUI y 向下，AppKit y 向上，dy 取反；旋转角取反）
    private static let stackConfigs: [(dx: CGFloat, dy: CGFloat, rotationDegrees: CGFloat, opacity: Float)] = [
        (16, 10, 0, 1.0),
        (-18, -14, -4, 0.90),
        (20, -12, 5, 0.75),
        (-14, 16, -3, 0.58)
    ]

    private func configureStackPreviews(urls: [URL]) {
        let activeURLs = Array(urls.prefix(4))
        let targetSize = previewTargetSize.width > 0
            ? previewTargetSize
            : CGSize(width: 320, height: 240)
        placeholderIconView.image = NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: nil
        )
        placeholderIconView.isHidden = !activeURLs.isEmpty

        for (index, preview) in stackPreviewViews.enumerated() {
            guard index < activeURLs.count else {
                preview.isHidden = true
                preview.image = nil
                previewLoadedKeys[index] = nil
                continue
            }
            preview.isHidden = false
            // 同 URL 已在显示：只同步可见性/透明度，跳过 setImage（防 reconfigure 闪动）
            let key = "\(activeURLs[index].absoluteString)|\(Int(targetSize.width))x\(Int(targetSize.height))"
            guard previewLoadedKeys[index] != key else { continue }
            previewLoadedKeys[index] = key
            preview.kf.setImage(
                with: activeURLs[index],
                options: [
                    .processor(DownsamplingImageProcessor(size: targetSize)),
                    .backgroundDecode,
                    .keepCurrentImageWhileLoading,
                    .transition(.none)
                ]
            )
        }
    }

    override func layoutContentFrames() {
        let bounds = containerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // 布局期间关闭隐式动画：frame/transform/alpha 的隐式 CA 动画是闪动来源
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        contentView.frame = bounds
        let imageHeight = max(0, bounds.height - Layout.infoBarHeight)
        coverImageView.frame = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        coverImageView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.withAlphaComponent(0.3).cgColor
        coverImageView.layer?.cornerRadius = 0

        let stackWidth = bounds.width * 0.75
        let stackHeight = imageHeight * 0.68
        let nextPreviewTargetSize = CGSize(
            width: max(1, stackWidth * 2),
            height: max(1, stackHeight * 2)
        )
        let targetChanged = abs(nextPreviewTargetSize.width - previewTargetSize.width) > 24
            || abs(nextPreviewTargetSize.height - previewTargetSize.height) > 24
        previewTargetSize = nextPreviewTargetSize
        previewCanvasView.frame = CGRect(
            x: 0,
            y: Layout.infoBarHeight,
            width: bounds.width,
            height: imageHeight
        )
        if targetChanged, let urls = currentModel?.previewURLs {
            configureStackPreviews(urls: urls)
        }
        // 叠图中心 = 图片区几何中心（与旧 FolderStackView 的 ZStack 居中一致）
        // 向下留出顶部呼吸空间，避免后排旋转卡片贴到图片区上沿。
        let stackCenterY = imageHeight / 2 - 9
        let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        for (index, preview) in stackPreviewViews.enumerated() {
            let config = Self.stackConfigs[index]
            preview.frame = CGRect(
                x: (bounds.width - stackWidth) / 2 + config.dx,
                y: stackCenterY - stackHeight / 2 - config.dy,
                width: stackWidth,
                height: stackHeight
            )
            preview.alphaValue = CGFloat(config.opacity)
            preview.layer?.contentsScale = backingScale
            // 旋转取反（SwiftUI y 向下）；模糊态放大 1.06 补偿高斯模糊的边缘透明
            let radians = -config.rotationDegrees * .pi / 180
            var transform = CATransform3DMakeRotation(radians, 0, 0, 1)
            if isPreviewBlurred {
                transform = CATransform3DScale(transform, 1.06, 1.06, 1)
            }
            preview.layer?.transform = transform
        }

        let iconSide = min(bounds.width, imageHeight) * 0.35
        placeholderIconView.frame = CGRect(
            x: (bounds.width - iconSide) / 2,
            y: (imageHeight - iconSide) / 2,
            width: iconSide,
            height: iconSide
        )

        // 锁态覆盖：毛玻璃 + 渐变 + 压暗铺满图片区，居中圆形锁徽章（对齐旧 LockedFolderOverlay）
        let imageArea = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        lockEffectView.frame = imageArea
        lockOverlayView.frame = imageArea
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lockGradientLayer.frame = lockOverlayView.bounds
        CATransaction.commit()
        let badgeSide: CGFloat = 28 + 28 * 0.55 * 2
        let lockBadgeFrame = CGRect(
            x: (bounds.width - badgeSide) / 2,
            y: Layout.infoBarHeight + (imageHeight - badgeSide) / 2,
            width: badgeSide,
            height: badgeSide
        )
        lockBadgeShadowView.frame = lockBadgeFrame
        lockBadgeShadowView.layer?.shadowPath = CGPath(
            ellipseIn: lockBadgeShadowView.bounds,
            transform: nil
        )
        lockBadgeView.frame = lockBadgeShadowView.bounds
        lockBadgeView.layer?.cornerRadius = badgeSide / 2
        lockBadgeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        lockBadgeView.layer?.borderWidth = 1
        lockIconView.frame = lockBadgeView.bounds.insetBy(dx: (badgeSide - 28) / 2, dy: (badgeSide - 28) / 2)

        relockButton.frame = CGRect(x: 10, y: Layout.infoBarHeight + 10, width: 28, height: 28)

        dropView.frame = CGRect(
            x: bounds.width * 0.2,
            y: Layout.infoBarHeight + imageHeight * 0.2,
            width: bounds.width * 0.6,
            height: imageHeight * 0.6
        )

        bottomBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.infoBarHeight)
        nameLabel.frame = CGRect(
            x: Layout.horizontalPadding,
            y: floor((Layout.infoBarHeight - 16) / 2),
            width: max(40, bounds.width - Layout.horizontalPadding * 2 - 70),
            height: 16
        ).integral
        let countSize = countStat.preferredSize
        countStat.frame = CGRect(
            x: bounds.width - Layout.horizontalPadding - countSize.width,
            y: floor((Layout.infoBarHeight - countSize.height) / 2),
            width: countSize.width,
            height: countSize.height
        ).integral
        syncGIFOverlayFrame()
    }

    override func cellMenu(for event: NSEvent) -> NSMenu? {
        guard let model = currentModel, !model.menuEntries.isEmpty else { return nil }
        return LibraryWallpaperGridCell.buildMenu(from: model.menuEntries, targets: &menuActionTargets)
    }

    override func effectiveHoverBorderWidth(for hovering: Bool) -> CGFloat {
        isDropTarget ? 2.5 : super.effectiveHoverBorderWidth(for: hovering)
    }

    override func effectiveHoverBorderColor(for hovering: Bool) -> NSColor {
        isDropTarget
            ? NSColor.controlAccentColor.withAlphaComponent(0.8)
            : super.effectiveHoverBorderColor(for: hovering)
    }

    @objc private func relockTapped() {
        currentModel?.onRelock()
    }

    private func refreshDropVisual() {
        if isDropTarget {
            borderLayer.borderWidth = 2.5
            borderLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        } else {
            borderLayer.borderWidth = normalBorderWidth
            let alpha = isHovered ? hoverBorderAlpha(for: normalBorderColor) : normalBorderColor.alphaComponent
            borderLayer.borderColor = normalBorderColor.withAlphaComponent(alpha).cgColor
        }
    }
}

// MARK: - 动漫卡 Cell

/// 还原 AnimeLibraryCard：10:14 封面 + 52pt 信息栏（标题 + 观看进度）+ 编辑多选
final class LibraryAnimeGridCell: ExploreGridItem {
    static let newReuseIdentifier = NSUserInterfaceItemIdentifier("LibraryAnimeGridCell")
    override class var gridReuseIdentifier: NSUserInterfaceItemIdentifier { newReuseIdentifier }

    private enum Layout {
        static let infoBarHeight = LibraryGridCellMetrics.animeInfoBarHeight
        static let cornerRadius = LibraryGridCellMetrics.cornerRadius
        static let horizontalPadding: CGFloat = 12
        static let overlayPadding: CGFloat = 12
    }

    private var currentModel: LibraryAnimeCellModel?

    private let bottomBar: NSView = {
        let view = NSView()
        view.wantsLayer = true
        // 与旧 AnimeLibraryCard 外层背景一致，避免 AppKit 底栏过黑。
        view.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground
            .withAlphaComponent(0.6)
            .cgColor
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

    private let progressIconView: NSImageView = {
        let view = NSImageView()
        view.image = NSImage(
            systemSymbolName: "play.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
        view.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()

    private let progressLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.6)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    /// 进度条（track + fill）
    private let progressTrack: CALayer = {
        let layer = CALayer()
        layer.cornerRadius = 2
        layer.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        return layer
    }()
    private let progressFill: CALayer = {
        let layer = CALayer()
        layer.cornerRadius = 2
        layer.backgroundColor = NSColor(hexString: "3B8BFF").withAlphaComponent(0.8).cgColor
        return layer
    }()

    private let ratingBadgeView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        view.layer?.cornerRadius = 12
        return view
    }()
    private let ratingStarView: NSImageView = {
        let view = NSImageView()
        view.image = NSImage(
            systemSymbolName: "star.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        view.contentTintColor = .systemYellow
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()
    private let ratingLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.95)
        return label
    }()

    private let checkboxView = LibraryEditCheckboxView()
    private let selectionMask: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        return view
    }()

    override var hoverScaleFactor: CGFloat { 1.01 }
    override var shouldAnimateBorderOnHover: Bool { true }
    override var allowsHoverInteraction: Bool { currentModel?.isEditing != true }

    override func setupContentLayout() {
        containerView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.withAlphaComponent(0.6).cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        setCardCornerRadius(Layout.cornerRadius)
        setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.08))

        contentView.addSubview(bottomBar)
        bottomBar.addSubview(titleLabel)
        bottomBar.addSubview(progressIconView)
        bottomBar.addSubview(progressLabel)
        bottomBar.layer?.addSublayer(progressTrack)
        bottomBar.layer?.addSublayer(progressFill)

        contentView.addSubview(ratingBadgeView)
        ratingBadgeView.addSubview(ratingStarView)
        ratingBadgeView.addSubview(ratingLabel)
        contentView.addSubview(checkboxView)
        contentView.addSubview(selectionMask)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentModel = nil
        titleLabel.stringValue = ""
        progressLabel.stringValue = ""
        progressIconView.isHidden = true
        progressLabel.isHidden = true
        // 轨道必须随复用隐藏：常驻的通栏细条会被看成"滚动条"
        progressTrack.isHidden = true
        progressFill.isHidden = true
        progressFillRatio = 0
        ratingBadgeView.isHidden = true
        checkboxView.isHidden = true
        selectionMask.isHidden = true
    }

    override func configure(with item: Any, isFavorite: Bool) {
        guard let model = item as? LibraryAnimeCellModel else { return }
        currentModel = model
        if model.isEditing {
            clearHover(animated: false)
        }

        titleLabel.stringValue = model.anime.title

        // 进度（对齐 AnimeLibraryCard.loadProgress）
        var progressText: String?
        var progressValue: Double?
        if let summary = AnimeProgressStore.shared.animeSummaries[model.anime.id] {
            if summary.watchedEpisodes > 0 {
                progressText = summary.continueWatchingText
            } else {
                progressText = "开始观看"
            }
            if summary.totalEpisodes > 0 {
                progressValue = summary.overallProgress
            } else if let lastEp = summary.lastEpisodeNumber {
                progressText = "看到第 \(lastEp) 集"
            }
        }
        if progressText == nil,
           let episode = model.anime.latestEpisode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !episode.isEmpty {
            progressText = episode
        }
        if let progressText {
            progressLabel.stringValue = progressText
            progressIconView.isHidden = false
            progressLabel.isHidden = false
        } else {
            progressLabel.stringValue = ""
            progressIconView.isHidden = true
            progressLabel.isHidden = true
        }
        progressFill.isHidden = progressValue == nil
        // 轨道与填充一致：仅真正有观看进度时显示（对齐旧 AnimeLibraryCard）
        progressTrack.isHidden = progressValue == nil
        if let progressValue {
            DispatchQueue.main.async { [weak self] in
                self?.updateProgressFill(ratio: min(max(progressValue, 0), 1))
            }
        }

        // 右上角评分（非编辑态）
        if !model.isEditing,
           let rating = model.anime.rating,
           let score = Double(rating), score > 0 {
            ratingLabel.stringValue = String(format: "%.1f", score)
            ratingStarView.isHidden = false
            ratingBadgeView.isHidden = false
        } else if !model.isEditing, let rank = model.anime.rank {
            ratingLabel.stringValue = "#\(rank)"
            ratingStarView.isHidden = true
            ratingBadgeView.isHidden = false
        } else {
            ratingLabel.stringValue = ""
            ratingStarView.isHidden = true
            ratingBadgeView.isHidden = true
        }

        checkboxView.configure(isSelected: model.isSelected, accent: model.accent)
        checkboxView.isHidden = !model.isEditing
        selectionMask.isHidden = !(model.isEditing && model.isSelected)

        if let coverURL = model.anime.coverURL.flatMap(URL.init(string:)) {
            loadImage(url: coverURL, targetSize: preferredImageTargetSize())
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
        let imageHeight = max(0, bounds.height - Layout.infoBarHeight)
        coverImageView.frame = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        coverImageView.layer?.cornerRadius = 0
        coverImageView.layer?.backgroundColor = LibraryGridCellMetrics.cardBackground.cgColor

        bottomBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.infoBarHeight)
        let contentWidth = bounds.width - Layout.horizontalPadding * 2

        // 文本（集数/观看进度）：只要有文本就显示（旧 AnimeLibraryCard 行为）
        let showsText = !progressLabel.isHidden
        if showsText {
            progressIconView.frame = CGRect(
                x: Layout.horizontalPadding,
                y: 11,
                width: 9,
                height: 10
            )
            progressLabel.frame = CGRect(
                x: progressIconView.frame.maxX + 4,
                y: 10,
                width: max(0, contentWidth - progressIconView.frame.maxX - 4),
                height: 14
            ).integral
            // 对齐旧 SwiftUI VStack(spacing: 3).padding(.vertical, 10)：
            // 标题在上、副标题在下，二者固定留 3pt，避免两行 frame 互相压住。
            titleLabel.frame = CGRect(
                x: Layout.horizontalPadding,
                y: progressLabel.frame.maxY + 3,
                width: contentWidth,
                height: 16
            ).integral
        } else {
            progressIconView.frame = .zero
            progressLabel.frame = .zero
            // 没有副标题时，旧卡片的 HStack 会在 52pt 底栏中垂直居中。
            titleLabel.frame = CGRect(
                x: Layout.horizontalPadding,
                y: floor((Layout.infoBarHeight - 16) / 2),
                width: contentWidth,
                height: 16
            ).integral
        }

        // 进度条：仅真正有观看进度（progressValue 非空）时显示
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if progressTrack.isHidden {
            progressTrack.frame = .zero
            progressFill.frame = .zero
        } else {
            progressTrack.frame = CGRect(
                x: Layout.horizontalPadding,
                y: 5,
                width: contentWidth,
                height: 3
            )
            progressFill.frame = CGRect(
                x: Layout.horizontalPadding,
                y: 5,
                width: contentWidth * progressFillRatio,
                height: 3
            )
        }
        CATransaction.commit()

        // 右上角评分胶囊
        if !ratingBadgeView.isHidden {
            let textSize = ratingLabel.fittingSize
            let starWidth: CGFloat = ratingStarView.isHidden ? 0 : 10
            let spacing: CGFloat = ratingStarView.isHidden ? 0 : 4
            let badgeWidth = 10 * 2 + starWidth + spacing + textSize.width
            let badgeHeight: CGFloat = 24
            ratingBadgeView.frame = CGRect(
                x: bounds.width - Layout.overlayPadding - badgeWidth,
                y: Layout.infoBarHeight + imageHeight - Layout.overlayPadding - badgeHeight,
                width: badgeWidth,
                height: badgeHeight
            ).integral
            ratingStarView.frame = CGRect(
                x: 10,
                y: 6,
                width: 10,
                height: 12
            ).integral
            ratingLabel.frame = CGRect(
                x: ratingStarView.isHidden ? 10 : ratingStarView.frame.maxX + 4,
                y: floor((badgeHeight - textSize.height) / 2),
                width: textSize.width,
                height: max(textSize.height, 1)
            ).integral
        } else {
            ratingBadgeView.frame = .zero
        }

        checkboxView.frame = CGRect(
            x: Layout.overlayPadding,
            y: Layout.infoBarHeight + imageHeight - Layout.overlayPadding - 22,
            width: 22,
            height: 22
        )
        selectionMask.frame = CGRect(x: 0, y: Layout.infoBarHeight, width: bounds.width, height: imageHeight)
        syncGIFOverlayFrame()
    }

    private var progressFillRatio: CGFloat = 0

    private func updateProgressFill(ratio: CGFloat) {
        progressFillRatio = ratio
        guard !progressFill.isHidden, progressTrack.frame.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressFill.frame = CGRect(
            x: progressTrack.frame.minX,
            y: progressTrack.frame.minY,
            width: progressTrack.frame.width * ratio,
            height: 3
        )
        CATransaction.commit()
    }

    private func preferredImageTargetSize() -> CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let width = max(coverImageView.bounds.width, 180) * scale
        let height = max(coverImageView.bounds.height, 252) * scale
        let edge = min(max(width, height), 1200)
        return CGSize(width: edge, height: edge)
    }
}

// MARK: - NSColor hex 便捷构造（与 ExploreGrid 其他 cell 私有实现同款，fileprivate 隔离互不冲突）

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
