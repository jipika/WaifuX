import AppKit
import SwiftUI

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
    weak var standaloneTransitionRegistry: AnimeCardTransitionRegistry?
    private var standaloneSelection: ((CGPoint?) -> Void)?
    private var standaloneClickRecognizer: NSClickGestureRecognizer?

    override var cardTransitionItemID: String? { currentAnime?.id }
    override var hoverScaleFactor: CGFloat { 1.02 }

    /// The SwiftUI explore grid keeps its lazy columns while using the same native cover and
    /// presentation-layer geometry as collection cells. Collection-view users leave this nil.
    func setStandaloneSelection(_ action: ((CGPoint?) -> Void)?) {
        standaloneSelection = action
        if let recognizer = standaloneClickRecognizer {
            recognizer.isEnabled = action != nil
        } else if action != nil {
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(selectStandaloneCard(_:)))
            recognizer.buttonMask = 0x1
            view.addGestureRecognizer(recognizer)
            standaloneClickRecognizer = recognizer
        }
        view.needsLayout = true
    }

    @objc private func selectStandaloneCard(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended, let window = view.window else { return }
        let point = view.convert(recognizer.location(in: view), to: nil)
        guard window === view.window, view.visibleRect.contains(recognizer.location(in: view)) else { return }
        standaloneSelection?(point)
    }

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
        standaloneTransitionRegistry?.unregister(self)
        standaloneTransitionRegistry = nil
        super.prepareForReuse()
        currentAnime = nil
        setStandaloneSelection(nil)
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

        // Only a successfully displayed image may seed a transition. An absent URL also
        // invalidates an in-flight/reused cover through the shared identity-aware loader.
        loadImage(
            urls: anime.coverURL.flatMap(URL.init(string:)).map { [$0] } ?? [],
            targetSize: preferredImageTargetSize(),
            imageIdentity: anime.id
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

        let imageHeight = max(0, bounds.height - Layout.bottomBarHeight)
        coverImageView.frame = CGRect(x: 0, y: Layout.bottomBarHeight, width: bounds.width, height: imageHeight)
        coverImageView.layer?.cornerRadius = Layout.imageCornerRadius
        if #available(macOS 10.13, *) {
            coverImageView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        coverImageView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor

        bottomBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.bottomBarHeight)
        let standalone = standaloneSelection != nil
        let episodeWidth = episodeLabel.isHidden ? 0 : min(episodeLabel.fittingSize.width + 17, max(0, bounds.width * 0.42))
        titleLabel.frame = CGRect(
            x: Layout.titleSidePadding,
            y: standalone ? 14 : 18,
            width: max(0, bounds.width - Layout.titleSidePadding * 2 - (standalone ? episodeWidth + 8 : 0)),
            height: 16
        ).integral

        if episodeLabel.isHidden {
            episodeIconLabel.frame = .zero
            episodeLabel.frame = .zero
        } else {
            let iconSize = NSSize(width: 10, height: 10)
            let episodeSize = episodeLabel.fittingSize
            episodeIconLabel.frame = CGRect(
                x: standalone ? bounds.width - Layout.titleSidePadding - episodeWidth : Layout.titleSidePadding,
                y: standalone ? 17 : Layout.episodeBottomPadding,
                width: iconSize.width,
                height: iconSize.height
            ).integral
            episodeLabel.frame = CGRect(
                x: episodeIconLabel.frame.maxX + 4,
                y: standalone ? 16 : Layout.episodeBottomPadding - 1,
                width: max(0, min(episodeSize.width, standalone ? episodeWidth - 17 : bounds.width - Layout.titleSidePadding * 2 - iconSize.width - 4)),
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
        // ExploreGridItem accepts points and applies the hosting window's scale itself.
        // Preserve the existing 1200px decode budget without multiplying scale twice.
        let scale = view.window?.backingScaleFactor ?? 2
        let size = CGSize(width: max(coverImageView.bounds.width, 180), height: max(coverImageView.bounds.height, 252))
        let factor = min(1, 1200 / max(1, max(size.width, size.height) * scale))
        return CGSize(width: size.width * factor, height: size.height * factor)
    }
}

/// Page-owned, weak registration: a return resolves the current mounted cell by stable ID,
/// including after SwiftUI recreates a lazy row. No scrolling geometry is published to SwiftUI.
@MainActor
final class AnimeCardTransitionRegistry: ObservableObject {
    private struct WeakCell {
        weak var value: AnimeGridCell?
    }
    private var cellsByItemID: [String: [WeakCell]] = [:]
    var isVisible = true

    func register(_ cell: AnimeGridCell) {
        guard let itemID = cell.cardTransitionItemID, !itemID.isEmpty else { return }
        var entries = cellsByItemID[itemID] ?? []
        entries.removeAll { $0.value == nil || $0.value?.cardTransitionItemID != itemID }
        if !entries.contains(where: { $0.value === cell }) {
            entries.append(WeakCell(value: cell))
        }
        cellsByItemID[itemID] = entries
    }

    func unregister(_ cell: AnimeGridCell) {
        guard let itemID = cell.cardTransitionItemID else { return }
        let remaining = cellsByItemID[itemID]?.filter { $0.value != nil && $0.value !== cell } ?? []
        cellsByItemID[itemID] = remaining.isEmpty ? nil : remaining
    }

    func source(for itemID: String, from selectedCell: AnimeGridCell, activationPoint: CGPoint?) -> CardTransitionSource? {
        guard isVisible, !itemID.isEmpty,
              let snapshot = selectedCell.cardTransitionSnapshot(for: itemID),
              uniqueCell(for: itemID, in: snapshot.window) === selectedCell else { return nil }
        let window = snapshot.window
        return CardTransitionSource(
            itemID: itemID, image: snapshot.image, anchor: snapshot.anchor, window: window,
            activationPointInWindow: activationPoint
        ) { [weak self, weak window] in
            guard let self, let window, self.isVisible,
                  let cell = self.uniqueCell(for: itemID, in: window) else { return nil }
            return cell.cardTransitionSnapshot(for: itemID)?.anchor
        }
    }

    private func uniqueCell(for itemID: String, in window: NSWindow) -> AnimeGridCell? {
        var match: AnimeGridCell?
        for entry in cellsByItemID[itemID] ?? [] {
            guard let cell = entry.value, cell.cardTransitionItemID == itemID,
                  cell.cardTransitionSnapshot(for: itemID)?.window === window else { continue }
            guard match == nil else { return nil }
            match = cell
        }
        return match
    }
}

/// Native, reusable card hosted inside the existing lazy SwiftUI columns. Capturing a source
/// is synchronous with this card's click, before the selectedAnime binding changes.
struct AnimeExploreGridCard: NSViewControllerRepresentable {
    let anime: AnimeSearchResult
    let cardWidth: CGFloat
    let isVisible: Bool
    let transitionRegistry: AnimeCardTransitionRegistry
    let onSelect: (AnimeSearchResult, CardTransitionSource?) -> Void

    func makeNSViewController(context: Context) -> AnimeGridCell {
        let cell = AnimeGridCell()
        _ = cell.view
        update(cell)
        return cell
    }

    func updateNSViewController(_ cell: AnimeGridCell, context: Context) {
        update(cell)
    }

    static func dismantleNSViewController(_ cell: AnimeGridCell, coordinator: ()) {
        cell.prepareForReuse()
    }

    private func update(_ cell: AnimeGridCell) {
        cell.view.setFrameSize(CGSize(width: cardWidth, height: cardWidth * 1.4 + 44))
        cell.view.layoutSubtreeIfNeeded()
        if cell.cardTransitionItemID != anime.id {
            cell.standaloneTransitionRegistry?.unregister(cell)
        }
        cell.configure(with: anime, isFavorite: false)
        cell.standaloneTransitionRegistry = transitionRegistry
        transitionRegistry.register(cell)
        cell.setHoverInteractionEnabled(isVisible)
        let selection = onSelect
        let item = anime
        let acceptsSelection = isVisible
        cell.setStandaloneSelection { [weak cell, weak transitionRegistry] point in
            guard acceptsSelection, let cell else { return }
            let source = transitionRegistry?.source(for: item.id, from: cell, activationPoint: point)
            selection(item, source)
        }
    }
}
