import AppKit
import SwiftUI
import Kingfisher

/// The compact local-library browser shown from a left click on the menu-bar item.
/// Visual target: floating frosted card, fixed-size rounded hero, scrollable thumbnail rail.
struct MenuBarQuickSwitcherView: View {
    /// Shared panel size — also referenced by MenuBarQuickSwitcherController.
    static let panelSize = NSSize(width: 370, height: 385)

    @ObservedObject var viewModel: MenuBarQuickSwitcherViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var readyVideoURL: URL?
    /// hero 视频是否已「武装」：停留够久才真正加载视频预览（见 body 里的 .task）。
    @State private var videoPreviewArmed = false
    private static let videoPreviewArmDelay = Duration.milliseconds(450)

    // Panel: previous height kept; width bumped slightly for breathing room.
    private let panelWidth: CGFloat = 370
    private let panelHeight: CGFloat = 385
    private let panelCorner: CGFloat = 26
    private let contentPadding: CGFloat = 14

    // Hero is intentionally fixed — never flexible max frames that can overflow.
    private let heroWidth: CGFloat = 342
    private let heroHeight: CGFloat = 240
    private let heroCorner: CGFloat = 16

    private let thumbnailSize: CGFloat = 56
    private let thumbnailSpacing: CGFloat = 8
    private let thumbnailCorner: CGFloat = 11
    private let footerButtonHeight: CGFloat = 36
    private let footerIconSize: CGFloat = 17

    private var selectionSpring: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.16)
            : .spring(response: 0.30, dampingFraction: 0.86, blendDuration: 0)
    }

    private var crossfadeAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.12)
            : .spring(response: 0.28, dampingFraction: 0.90, blendDuration: 0)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: panelCorner, style: .continuous)
    }

    private var heroShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: heroCorner, style: .continuous)
    }

    var body: some View {
        ZStack {
            // System frosted glass only — no muddy green wash.
            panelShape
                .fill(.ultraThinMaterial)
                .overlay {
                    panelShape
                        .fill(Color.primary.opacity(0.04))
                }
                .overlay {
                    panelShape
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)

            VStack(spacing: 0) {
                hero
                    .frame(width: heroWidth, height: heroHeight)

                thumbnailRail
                    .padding(.top, 12)

                footer
                    .padding(.top, 12)
            }
            .padding(contentPadding)
        }
        .frame(width: panelWidth, height: panelHeight)
        .clipShape(panelShape)
        .compositingGroup()
        .task(id: viewModel.previewWarmupToken) {
            await viewModel.warmVisiblePreviews()
        }
        .task(id: viewModel.selectedItem?.id) {
            // hero 视频延迟武装：连点缩略图时不要每个都起一个播放器 —— 外置盘原片
            // 解码是弹窗里最贵的一步（CPU + IO + 一路 AVPlayer 内存）。停留超过
            // 这个时间才真正加载视频预览；快速划过时只显示静帧。
            videoPreviewArmed = false
            guard viewModel.selectedItem?.videoPreviewURL != nil else { return }
            try? await Task.sleep(for: Self.videoPreviewArmDelay)
            guard !Task.isCancelled else { return }
            videoPreviewArmed = true
        }
        .onChange(of: viewModel.selectedItem?.videoPreviewURL) { _, _ in
            readyVideoURL = nil
        }
    }

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            if let selected = viewModel.selectedItem {
                // Fixed-size slot. Media is painted as an overlay so scaledToFill
                // cannot expand layout or poke past the rounded clip.
                Color.black.opacity(0.10)
                    .overlay {
                        QuickSwitcherImage(url: selected.thumbnailURL, fallbackSymbol: "photo")
                            .id(selected.id + (selected.thumbnailURL?.absoluteString ?? ""))
                            .transition(.opacity)
                    }
                    .overlay {
                        if videoPreviewArmed, let videoURL = selected.videoPreviewURL {
                            LoopingVideoBackgroundView(
                                url: videoURL,
                                isMuted: true,
                                contentMode: .fill,
                                // Outer SwiftUI clip owns the corner; avoid double-radius mismatch.
                                cornerRadius: 0,
                                onReady: { @MainActor in
                                    withAnimation(crossfadeAnimation) {
                                        readyVideoURL = videoURL
                                    }
                                }
                            )
                            .id(videoURL)
                            .opacity(readyVideoURL == videoURL ? 1 : 0)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: heroWidth, height: heroHeight)
                    .clipped()
                    .clipShape(heroShape)
                    .contentShape(heroShape)
                    .overlay(alignment: .bottomLeading) {
                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.black.opacity(0.54), in: Capsule())
                                .padding(10)
                                .transition(
                                    .opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading))
                                )
                        }
                    }
                    .overlay {
                        if viewModel.isApplying {
                            ZStack {
                                Color.black.opacity(0.22)
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(.white)
                            }
                            .clipShape(heroShape)
                            .transition(.opacity)
                        }
                    }

                HStack(spacing: 8) {
                    if viewModel.canDesignCurrentWallpaper {
                        heroActionButton(
                            systemName: "paintbrush.pointed",
                            help: t("design.designWallpaper")
                        ) {
                            viewModel.openDesignWallpaper()
                        }
                    }

                    // external 项（库里没有记录）没有详情页可开，按钮直接隐藏。
                    if viewModel.canOpenSelectedDetail {
                        heroActionButton(
                            systemName: "arrow.up.right.square",
                            help: t("statusbar.openCurrentWallpaper")
                        ) {
                            viewModel.openDetail()
                        }
                    }
                }
                .padding(10)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 32, weight: .light))
                    Text(t("menubar.quick.empty"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(width: heroWidth, height: heroHeight)
                .background(Color.primary.opacity(0.06))
                .clipShape(heroShape)
            }
        }
        .frame(width: heroWidth, height: heroHeight)
        .clipShape(heroShape)
        .animation(crossfadeAnimation, value: viewModel.selectedItem?.id)
        .animation(crossfadeAnimation, value: viewModel.isApplying)
        .animation(crossfadeAnimation, value: viewModel.errorMessage)
    }

    private func heroActionButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .background(Color.black.opacity(0.22), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
                }
        }
        .buttonStyle(QuickSwitcherPressButtonStyle())
        .help(help)
        .accessibilityLabel(Text(help))
        .disabled(viewModel.isApplying)
    }

    private var thumbnailRail: some View {
        NativeHorizontalThumbnailRail(
            selectedIndex: viewModel.batchItems.firstIndex {
                $0.id == viewModel.selectedItem?.id
            },
            itemStride: thumbnailSize + thumbnailSpacing,
            contentSignature: railContentSignature
        ) {
            HStack(spacing: thumbnailSpacing) {
                ForEach(viewModel.batchItems) { item in
                    let isSelected = item.id == viewModel.selectedItem?.id
                    thumbnailChip(item: item, isSelected: isSelected)
                }
            }
            .padding(.horizontal, 1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: thumbnailSize + 4)
    }

    /// 轨道内容签名：chip 列表、缩略图、标题、选中项与禁用态。
    /// 弹窗里每次选中/预热回调都会触发 body 求值；无条件 `rootView = content` +
    /// `layoutSubtreeIfNeeded()` 会让「点缩略图切换」一顿一顿的。
    private var railContentSignature: Int {
        var hasher = Hasher()
        for item in viewModel.batchItems {
            hasher.combine(item.id)
            hasher.combine(item.thumbnailURL?.absoluteString)
            hasher.combine(item.title)
        }
        hasher.combine(viewModel.selectedItem?.id)
        hasher.combine(viewModel.isApplying)
        return hasher.finalize()
    }

    private func thumbnailChip(item: MenuBarQuickWallpaperItem, isSelected: Bool) -> some View {
        Button {
            // 不要用 withAnimation 包住 select：那会把整棵弹窗树（hero + 轨道 + footer）
            // 都卷进同一次 spring 事务里逐帧重排。选中态动画由 chip 自己的
            // `.animation(value: isSelected)` 与 hero 的 crossfade 各自负责。
            viewModel.select(item)
        } label: {
            Color.black.opacity(0.08)
                .overlay {
                    QuickSwitcherImage(url: item.thumbnailURL, fallbackSymbol: "photo")
                }
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: thumbnailCorner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: thumbnailCorner, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.white : Color.primary.opacity(0.08),
                            lineWidth: isSelected ? 2.5 : 0.6
                        )
                }
                .shadow(
                    color: isSelected ? .black.opacity(0.16) : .clear,
                    radius: isSelected ? 5 : 0,
                    y: isSelected ? 2 : 0
                )
                .scaleEffect(isSelected ? 1.0 : 0.97)
                .opacity(isSelected ? 1.0 : 0.92)
                .animation(selectionSpring, value: isSelected)
        }
        .buttonStyle(QuickSwitcherPressButtonStyle())
        .help(item.title)
        .disabled(viewModel.isApplying)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(item.title)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                iconButton(systemName: "gearshape", help: t("settings")) {
                    viewModel.openSettings()
                }
                iconButton(systemName: "arrow.clockwise", help: t("menubar.quick.refreshBatch")) {
                    withAnimation(selectionSpring) {
                        viewModel.refreshBatch()
                    }
                }
                iconButton(systemName: "power", help: t("statusbar.quit")) {
                    viewModel.quitApplication()
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Menu {
                    // NSMenu 丢弃 HStack 标签里的 Image，勾选必须用 Toggle 渲染。
                    Toggle(
                        t("menubar.quick.myLibrary"),
                        isOn: Binding(
                            get: { viewModel.isUsingEntireLibrary },
                            set: { newValue in
                                guard newValue else { return }
                                withAnimation(selectionSpring) {
                                    viewModel.selectEntireLibrary()
                                }
                            }
                        )
                    )

                    if !viewModel.availableFolders.isEmpty {
                        Divider()
                        ForEach(viewModel.availableFolders) { folder in
                            Toggle(
                                viewModel.folderOptionLabel(for: folder),
                                isOn: Binding(
                                    get: { viewModel.isFolderSelected(folder.id) },
                                    set: { _ in
                                        withAnimation(selectionSpring) {
                                            viewModel.toggleFolderSelection(folder.id)
                                        }
                                    }
                                )
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .semibold))
                        Text(viewModel.selectedFolderLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.86))
                        .frame(width: 150, height: footerButtonHeight)
                        .background(Color.white, in: Capsule())
                        .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
                }
                .menuStyle(.borderlessButton)
                .help(viewModel.selectedFolderLabel)
                .disabled(viewModel.isApplying)

                Button {
                    viewModel.applySelectedItem()
                } label: {
                    Text(t("setWallpaper"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(minWidth: 68, minHeight: footerButtonHeight)
                        .padding(.horizontal, 10)
                        .background(Color.black.opacity(0.92), in: Capsule())
                }
                .buttonStyle(QuickSwitcherPressButtonStyle())
                .disabled(viewModel.selectedItem == nil || viewModel.isApplying)
            }
        }
        .frame(height: footerButtonHeight)
    }

    private func iconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: footerIconSize, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.58))
                .frame(width: 30, height: footerButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuickSwitcherPressButtonStyle())
        .help(help)
        .disabled(viewModel.isApplying)
    }

}

// MARK: - Press feedback

private struct QuickSwitcherPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(
                .spring(response: 0.22, dampingFraction: 0.78, blendDuration: 0),
                value: configuration.isPressed
            )
    }
}

// MARK: - Thumbnail rail wheel support

/// Native scroll view for the candidate rail. Vertical mouse-wheel deltas are
/// mapped to its horizontal content offset, while thumbnail buttons remain in
/// the hosted SwiftUI view and receive normal clicks.
@MainActor
private struct NativeHorizontalThumbnailRail<Content: View>: NSViewRepresentable {
    let content: Content
    /// 当前选中项在候选数组里的下标；变化时把它滚进可视区。
    let selectedIndex: Int?
    /// 单个 chip 的横向步进（宽 + 间距），用于按下标算滚动目标。
    let itemStride: CGFloat
    /// 轨道显示依赖的签名：相同就不重赋 rootView、不重排（切换选中不再整条重排）。
    let contentSignature: Int

    init(
        selectedIndex: Int?,
        itemStride: CGFloat,
        contentSignature: Int,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.selectedIndex = selectedIndex
        self.itemStride = itemStride
        self.contentSignature = contentSignature
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rootView: content)
    }

    func makeNSView(context: Context) -> VerticalWheelHorizontalScrollView {
        let scrollView = VerticalWheelHorizontalScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = context.coordinator.hostingView
        return scrollView
    }

    func updateNSView(_ scrollView: VerticalWheelHorizontalScrollView, context: Context) {
        let hostingView = context.coordinator.hostingView
        let updateStart = Date()
        let signatureChanged = context.coordinator.lastContentSignature != contentSignature
        if signatureChanged {
            context.coordinator.lastContentSignature = contentSignature
            hostingView.rootView = content
        }

        // 打开弹窗时默认选中的是「当前壁纸」，它可能落在轨道可视区之外
        // （例如在所属文件夹内被随机排到中段），这里只在选中项变化时补一次滚动。
        var shouldRevealSelectedItem = false
        if let selectedIndex, context.coordinator.lastRevealedIndex != selectedIndex {
            context.coordinator.lastRevealedIndex = selectedIndex
            shouldRevealSelectedItem = true
        }
        guard signatureChanged || shouldRevealSelectedItem else { return }
        let revealIndex = shouldRevealSelectedItem ? selectedIndex : nil
        let stride = itemStride
        let updateNumber = context.coordinator.updateCount

        DispatchQueue.main.async {
            guard scrollView.documentView === hostingView else { return }
            if signatureChanged {
                hostingView.layoutSubtreeIfNeeded()
                let fittingSize = hostingView.fittingSize
                let size = NSSize(
                    width: max(fittingSize.width, scrollView.contentSize.width),
                    height: max(fittingSize.height, scrollView.contentSize.height)
                )
                if hostingView.frame.size != size {
                    hostingView.setFrameSize(size)
                }
            }
            if let revealIndex {
                scrollView.revealItem(at: revealIndex, stride: stride)
            }
            // 切换选中/换批时量一次「body 求值 → 轨道布局完成」的主线程耗时。
            AppLogger.debug(.general, "菜单栏轨道更新耗时", metadata: [
                "layoutMS": String(Int(Date().timeIntervalSince(updateStart) * 1000)),
                "changed": signatureChanged ? "1" : "0",
                "count": String(updateNumber),
            ])
        }
        context.coordinator.updateCount += 1
    }

    @MainActor
    final class Coordinator {
        let hostingView: NSHostingView<Content>
        /// 上一次已经滚动到过的选中下标，避免每次 body 更新都强制滚动。
        var lastRevealedIndex: Int?
        var lastContentSignature: Int?
        var updateCount = 0

        init(rootView: Content) {
            hostingView = NSHostingView(rootView: rootView)
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

private final class VerticalWheelHorizontalScrollView: NSScrollView {
    private var dragStartLocation: NSPoint?
    private var dragStartOffset: CGFloat = 0
    private var isDraggingRail = false
    private var dragMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installDragMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeDragMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        MainActor.assumeIsolated {
            removeDragMonitor()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let documentView else {
            super.scrollWheel(with: event)
            return
        }

        let viewportWidth = contentView.bounds.width
        let maxOffset = max(0, documentView.frame.width - viewportWidth)
        guard maxOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }

        let rawDelta: CGFloat
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            // AppKit deltas already respect the system's natural-scrolling setting.
            // Moving the clip-view origin must use the opposite sign, matching NSScrollView.
            rawDelta = -event.scrollingDeltaX
        } else {
            rawDelta = -event.scrollingDeltaY
        }
        guard abs(rawDelta) > 0.001 else { return }

        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 24
        var origin = contentView.bounds.origin
        origin.x = min(max(origin.x + rawDelta * multiplier, 0), maxOffset)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func installDragMonitorIfNeeded() {
        guard dragMonitor == nil, window != nil else { return }
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleDragEvent(event)
        }
    }

    private func removeDragMonitor() {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
    }

    private func handleDragEvent(_ event: NSEvent) -> NSEvent? {
        let location = convert(event.locationInWindow, from: nil)

        switch event.type {
        case .leftMouseDown:
            guard bounds.contains(location) else { return event }
            dragStartLocation = location
            dragStartOffset = contentView.bounds.origin.x
            isDraggingRail = false
            return event

        case .leftMouseDragged:
            guard let dragStartLocation else { return event }
            let delta = location.x - dragStartLocation.x
            if !isDraggingRail, abs(delta) >= 3 {
                isDraggingRail = true
            }
            guard isDraggingRail else { return event }

            scrollHorizontally(to: dragStartOffset - delta)
            return nil

        case .leftMouseUp:
            guard self.dragStartLocation != nil else { return event }
            let shouldConsume = isDraggingRail
            dragStartLocation = nil
            isDraggingRail = false
            return shouldConsume ? nil : event

        default:
            return event
        }
    }

    private func scrollHorizontally(to requestedOffset: CGFloat) {
        guard let documentView else { return }
        let maxOffset = max(0, documentView.frame.width - contentView.bounds.width)
        var origin = contentView.bounds.origin
        origin.x = min(max(requestedOffset, 0), maxOffset)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    /// 把某个 chip 滚进可视区（尽量居中）。已经在可视区内时不动，
    /// 避免用户手动滚动后被抢回。
    func revealItem(at index: Int, stride: CGFloat) {
        guard let documentView, stride > 0 else { return }
        let viewportWidth = contentView.bounds.width
        let maxOffset = max(0, documentView.frame.width - viewportWidth)
        let itemCenter = CGFloat(index) * stride + stride / 2
        let currentOffset = contentView.bounds.origin.x
        // 露出半格以上就算可见。
        guard itemCenter < currentOffset + stride / 2
                || itemCenter > currentOffset + viewportWidth - stride / 2 else {
            return
        }
        let targetOffset = min(max(itemCenter - viewportWidth / 2, 0), maxOffset)
        contentView.scroll(to: NSPoint(x: targetOffset, y: contentView.bounds.origin.y))
        reflectScrolledClipView(contentView)
    }
}

// MARK: - Image

private struct QuickSwitcherImage: View {
    let url: URL?
    let fallbackSymbol: String

    var body: some View {
        Group {
            if let url {
                KFImage(url)
                    .fade(duration: 0.16)
                    // chip 56px / hero 342pt@2x=684 —— 768 上限足够，避免把外置盘
                    // 几 MB~几十 MB 的原图全尺寸解码（2026-10-13 弹窗出图慢的
                    // 静图侧主因）。macOS 无 UIScreen；菜单栏面板 Retina 最高 2x，
                    // downsampling 按像素吃 768 已覆盖。
                    .downsampling(size: CGSize(width: 768, height: 768))
                    .cacheOriginalImage()
                    .cancelOnDisappear(true)
                    .resizable()
                    .placeholder {
                        placeholder
                    }
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        // Fill the parent-proposed size (overlay/frame), then clip overflow.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            Color.black.opacity(0.18)
            Image(systemName: fallbackSymbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(0.72))
        }
    }
}
