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
    // 原布局：hero 全宽。播放控制条以浮动玻璃胶囊挂在 hero 右上角
    // 画笔/详情按钮下方（与它们同列），不占布局高度。
    private let heroWidth: CGFloat = 342
    private let heroHeight: CGFloat = 240
    private let heroCorner: CGFloat = 16
    /// 播放条宽度：略宽于 32pt 的画笔按钮，图标与展开滑块都不挤。
    /// 右边缘与按钮行同为 10pt 内边距，视觉上同一条竖列。
    private let playbackBarWidth: CGFloat = 38

    private let thumbnailSize: CGFloat = 56
    private let thumbnailSpacing: CGFloat = 8
    private let thumbnailCorner: CGFloat = 11
    private let footerButtonHeight: CGFloat = 36
    private let footerIconSize: CGFloat = 17
    private let playbackButtonSize: CGFloat = 27
    private let playbackSlotSpacing: CGFloat = 2
    private let playbackBarVerticalPadding: CGFloat = 5

    // Hero 右上角按钮行：10pt 内边距 + 按钮 + 10pt 内边距。
    // 直径取播放条宽度（playbackBarWidth = 38），上方圆钮与下方玻璃胶囊同宽，
    // 右边缘对齐成一条竖列；按钮底边因此落在 10 + 38 = 48pt。
    private let heroActionButtonSize: CGFloat = 38
    private let heroActionInset: CGFloat = 10
    /// 两个按钮之间的水平间距。
    private let heroActionGap: CGFloat = 8
    /// 播放条与上方按钮行的竖向间距：与四周内边距同值，整块共用一套边距。
    private let heroPlaybackGap: CGFloat = 10

    // MARK: - 播放控制条状态
    @State private var isVolumeExpanded = false
    @State private var isRateExpanded = false
    @State private var volumeValue: Double = 1.0
    @State private var rateValue: Double = 1.0

    private var hasAnyExpandedOverlay: Bool { isVolumeExpanded || isRateExpanded }

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
        .onAppear {
            refreshPlaybackControls()
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
                            .id(selected.id + (selected.thumbnailURL?.absoluteString ?? "") + "#\(viewModel.coverRevision)")
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

                HStack(spacing: heroActionGap) {
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
                .padding(heroActionInset)

                // 播放控制条：浮动玻璃胶囊，与上面两个按钮同列、挂在它们下方。
                // 竖排在 hero 内部右上角，不占布局高度、不改面板尺寸。
                // 按钮行外框四周各 10pt 内边距，按钮视觉底边在 10 + 38 = 48pt；
                // 播放条顶边取 48 + 10 = 58pt。
                // 按钮直径与胶囊同宽（38），两者右边缘都贴 10pt 即同一条竖列；
                // 若将来两者宽度再拉开，再按「图标中心」补半个差值。
                playbackColumn
                    .padding(.top, heroActionInset + heroActionButtonSize + heroPlaybackGap)
                    .padding(.trailing, heroActionInset - (playbackBarWidth - heroActionButtonSize) / 2)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
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
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: heroActionButtonSize, height: heroActionButtonSize)
                .modifier(HeroGlassCircleSurface())
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
            contentSignature: railContentSignature,
            railMinimumHeight: thumbnailSize + 4
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
        hasher.combine(viewModel.coverRevision)
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
                        .id((item.thumbnailURL?.absoluteString ?? "") + "#\(viewModel.coverRevision)")
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

    // MARK: - 播放控制（液态玻璃，与状态栏右键菜单同一套每屏能力）

    /// 控制条可用槽位高度（不含外层竖向 padding）：每格 27pt + 2pt 间距。
    private var playbackControlsHeight: CGFloat {
        var slots = 3
        if viewModel.showsVolumeControl { slots += 1 }
        if viewModel.playbackRate != nil { slots += 1 }
        return CGFloat(slots) * playbackButtonSize + CGFloat(max(0, slots - 1)) * playbackSlotSpacing
    }

    /// 竖排玻璃控制条：上一张 · 暂停/播放 · 下一张 · 音量 · 播放速度。
    ///
    /// macOS Tahoe / 27 的做法（`GlassEffectContainer` + `glassEffectID`）：
    /// · 胶囊尺寸锁死，布局一次定死——滑块**不进 VStack**，不撑高；
    /// · 滑块是 **overlay 覆盖层**，对齐到底部、从按钮顶端向上长出，
    ///   盖住上面的图标，按钮自己还在原位；
    /// · 也就是文档里的「second button will be like growing out of the first」。
    @ViewBuilder
    private var playbackColumn: some View {
        let live = viewModel.hasLivePlayback
        let kind = expandedKind
        // 槽位序号：prev 0 · play 1 · next 2 · volume 3 · rate 4（无音量时 rate 为 3）。
        let volumeSlot = 3
        let rateSlot = viewModel.showsVolumeControl ? 4 : 3
        let anchorSlot: Int? = {
            guard let kind else { return nil }
            switch kind {
            case .volume: return viewModel.showsVolumeControl ? volumeSlot : nil
            case .rate: return viewModel.playbackRate != nil ? rateSlot : nil
            }
        }()
        // 被盖住的图标隐身（只留布局占位，尺寸不动；半透玻璃下不透字）。
        let dimmed: (Int) -> Bool = { slot in
            guard let anchorSlot else { return false }
            return slot < anchorSlot
        }

        let column = ZStack {
            VStack(spacing: playbackSlotSpacing) {
                playbackBarButton("backward.end.fill", enabled: live && viewModel.canGoPrevious) {
                    viewModel.previousWallpaperForTargetScreen()
                    refreshPlaybackControls()
                }
                .opacity(dimmed(0) ? 0 : 1)
                .allowsHitTesting(anchorSlot == nil)
                playbackBarButton(
                    viewModel.isPlaybackPaused ? "play.fill" : "pause.fill",
                    enabled: live
                ) {
                    viewModel.togglePlaybackForTargetScreen()
                    refreshPlaybackControls()
                }
                .opacity(dimmed(1) ? 0 : 1)
                .allowsHitTesting(anchorSlot == nil)
                playbackBarButton("forward.end.fill", enabled: live && viewModel.canSwitchWallpaper) {
                    viewModel.nextWallpaperForTargetScreen()
                    refreshPlaybackControls()
                }
                .opacity(dimmed(2) ? 0 : 1)
                .allowsHitTesting(anchorSlot == nil)

                if viewModel.showsVolumeControl {
                    playbackAnchorIcon(.volume, isExpanded: kind == .volume)
                        .opacity(dimmed(volumeSlot) ? 0 : 1)
                        .allowsHitTesting(!dimmed(volumeSlot))
                }
                if viewModel.playbackRate != nil {
                    playbackAnchorIcon(.rate, isExpanded: kind == .rate)
                        .opacity(dimmed(rateSlot) ? 0 : 1)
                        .allowsHitTesting(!dimmed(rateSlot))
                }
            }
            .frame(width: playbackBarWidth - 6, height: playbackControlsHeight)
            .animation(expanderSpring, value: kind)
        }
        .frame(width: playbackBarWidth - 6)
        .padding(.vertical, playbackBarVerticalPadding)
        .frame(width: playbackBarWidth)
        .modifier(PlaybackGlassSurface(
            shape: Capsule(style: .continuous),
            id: PlaybackGlassID.bar
        ))
        .opacity(live || viewModel.canSwitchWallpaper ? 1.0 : 0.55)
        // 滑块盖在胶囊上：不占布局（overlay），从按钮顶端向上长出。
        .overlay(alignment: .bottom) {
            if let kind {
                sliderPanel(kind)
                    .padding(.bottom, overlayBottomPadding(kind))
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.6, anchor: panelAnchor(kind)).combined(with: .opacity),
                            removal: .scale(scale: 0.8, anchor: panelAnchor(kind)).combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(expanderSpring, value: kind)

        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { column }
        } else {
            column
        }
    }



    /// 被盖住区域的高度：anchor 之上的 a 个槽（a*27）加 a 个间距（a*2）。
    private func upperAreaHeight(_ rowKind: ExpanderKind) -> CGFloat {
        CGFloat(anchorSlotIndex(rowKind)) * (playbackButtonSize + playbackSlotSpacing)
    }

    /// anchor 在整条里的槽位号：prev0/play1/next2/volume3/rate4（无音量时 rate 为 3）。
    private func anchorSlotIndex(_ rowKind: ExpanderKind) -> Int {
        switch rowKind {
        case .volume: return 3
        case .rate: return viewModel.showsVolumeControl ? 4 : 3
        }
    }

    /// 滑块面板：和外框同宽，底边托在按钮顶端上，顶到胶囊顶部。
    /// 高度按被盖住的槽位精确计算，滑块自适应填满。
    @ViewBuilder
    private func sliderPanel(_ rowKind: ExpanderKind) -> some View {
        // 不给面板 glassEffectID：容器只管采样不做 morph。
        let content = sliderWellContent(rowKind)
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .frame(width: playbackBarWidth, height: upperAreaHeight(rowKind))
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    Glass.regular.tint(Color.primary.opacity(0.05)),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                }
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Rectangle()
                        .fill(Color.clear)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        .clipShape(Capsule(style: .continuous))
                }
        }
    }

    /// 面板底边到胶囊底边的距离：正好把面板托在被点的按钮顶端上。
    private func overlayBottomPadding(_ rowKind: ExpanderKind) -> CGFloat {
        // 最后一格按钮顶端到胶囊底：padding + 按钮高 + 间距。
        let lastTop = playbackBarVerticalPadding + playbackButtonSize + playbackSlotSpacing
        switch rowKind {
        case .rate:
            return lastTop
        case .volume:
            // volume 上面还有 rate 时，它是倒数第二格，再垫一格。
            return viewModel.playbackRate != nil
                ? lastTop + playbackButtonSize + playbackSlotSpacing
                : lastTop
        }
    }

    /// 转场缩放的锚点：面板底边中心也就是被点按钮的顶端中心。
    private func panelAnchor(_ rowKind: ExpanderKind) -> UnitPoint {
        let panelH = upperAreaHeight(rowKind)
        let totalH = panelH + overlayBottomPadding(rowKind)
        guard totalH > 0 else { return .bottom }
        return UnitPoint(x: 0.5, y: panelH / totalH)
    }

    private func sliderWellContent(_ kind: ExpanderKind) -> some View {
        VStack(spacing: 3) {
            if kind == .rate {
                Text(Self.rateLabel(rateValue))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .frame(height: 11)
            }

            Group {
                if kind == .rate {
                    GlassVerticalSlider(
                        value: Binding(
                            get: { rateValue },
                            set: { newValue in
                                rateValue = newValue
                                viewModel.setPlaybackRate(newValue)
                            }
                        ),
                        range: VideoWallpaperManager.minPlaybackRate...VideoWallpaperManager.maxPlaybackRate,
                        tickValue: 1.0
                    )
                } else {
                    GlassVerticalSlider(
                        value: Binding(
                            get: { volumeValue },
                            set: { newValue in
                                volumeValue = newValue
                                viewModel.setPlaybackVolume(newValue)
                            }
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 滑块（圆头+轨道）在加宽后的胶囊里居中：宽度改了但轨道仍按自身
            // 宽度画，不居中会贴在左边。
            .frame(maxWidth: .infinity)
        }
    }

    /// 一颗可展开的图标：点开/收起，展开中高亮。
    private func playbackAnchorIcon(_ rowKind: ExpanderKind, isExpanded: Bool) -> some View {
        Button {
            withAnimation(expanderSpring) {
                switch rowKind {
                case .volume:
                    isVolumeExpanded.toggle()
                    if isVolumeExpanded { isRateExpanded = false }
                case .rate:
                    isRateExpanded.toggle()
                    if isRateExpanded { isVolumeExpanded = false }
                }
            }
            refreshPlaybackControls()
        } label: {
            Image(systemName: rowIcon(rowKind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isExpanded ? Color.primary : Color.primary.opacity(0.72))
                .frame(width: playbackButtonSize, height: playbackButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(PlaybackPressButtonStyle(diameter: playbackButtonSize - 1))
        .help(rowKind == .volume ? t("statusbar.volume") : t("statusbar.playbackSpeed"))
    }

    private func rowIcon(_ kind: ExpanderKind) -> String {
        switch kind {
        case .volume:
            return volumeValue <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .rate:
            return "speedometer"
        }
    }

    /// 当前展开的是哪一块；nil = 收起。
    private enum ExpanderKind: Hashable {
        case volume
        case rate

        var glassKey: ExpanderKindKey {
            switch self {
            case .volume: return .volume
            case .rate: return .rate
            }
        }
    }
    private var expandedKind: ExpanderKind? {
        if isVolumeExpanded, viewModel.showsVolumeControl { return .volume }
        if isRateExpanded, viewModel.playbackRate != nil { return .rate }
        return nil
    }

    /// 展开/收起专用弹簧：稍快并带一点回弹，起点钉按钮顶。
    /// 玻璃本身的形变由系统 matchedGeometry 接管，这里只管布局事务。
    private var expanderSpring: Animation {
        reduceMotion
            ? .easeOut(duration: 0.25)
            : .spring(response: 0.4, dampingFraction: 0.8, blendDuration: 0)
    }

    /// 滑块底衬：细描边胶囊，与外层玻璃胶囊拉开层次（参考展开态的轨道框）。
    /// 让出上下 2pt，滑块轨道两端才不会顶出描边。
    private var sliderTrackCapsule: some View {
        Capsule(style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.6)
            }
    }

    private func playbackBarButton(
        _ systemName: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary.opacity(0.72) : Color.primary.opacity(0.22))
                .frame(width: playbackButtonSize, height: playbackButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(PlaybackPressButtonStyle(diameter: playbackButtonSize - 1))
        .disabled(!enabled)
    }

    private func toggleExpansion(_ target: inout Bool, other: inout Bool) {
        guard !viewModel.isApplying else { return }
        withAnimation(selectionSpring) {
            target.toggle()
            other = false
        }
    }

    private func collapseExpansion() {
        withAnimation(selectionSpring) {
            isVolumeExpanded = false
            isRateExpanded = false
        }
    }

    /// 从服务读回当前每屏状态（暂停态切换 / 音量被别处改过时保持 UI 一致）。
    /// 先让 ViewModel 立即重算并发布快照，再回读——只改本地 @State 不发布时，
    /// 暂停图标会停在按下前的样子。
    private func refreshPlaybackControls() {
        viewModel.refreshPlaybackSnapshot()
        volumeValue = viewModel.playbackVolume
        if let rate = viewModel.playbackRate {
            rateValue = rate
        }
    }

    private static func rateLabel(_ rate: Double) -> String {
        if abs(rate - rate.rounded()) < 0.05 {
            return String(format: "%.0fx", rate.rounded())
        }
        return String(format: "%.2gx", rate)
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

// MARK: - 播放控制玻璃表面与滑块

/// macOS 26+ 原生 glassEffect（含 GlassEffectContainer 形变配对）；14/15 回退 ultraThinMaterial。
/// macOS 27 上就是原生液态玻璃胶囊，与系统播放器控件同一套材质语言。
struct PlaybackGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let id: PlaybackGlassID

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    Glass.regular.tint(Color.primary.opacity(0.05)),
                    in: shape
                )
                .overlay {
                    shape
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                }
                .glassEffectID(id, in: MenuBarPlaybackGlassCoordinator.shared.namespace)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    Rectangle()
                        .fill(Color.clear)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        .clipShape(shape)
                }
        }
    }
}

/// hero 右上角浮动圆钮的玻璃底：与播放控制胶囊同一套材质——
/// macOS 26+ 原生液态玻璃，14/15 回退 ultraThinMaterial。
/// 不再额外叠「材质模糊 + 黑色蒙版」，否则在亮封面上会糊成一块灰。
/// 不参与 glassEffectID morph：那套命名空间只服务播放面板的放大形变。
struct HeroGlassCircleSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    Glass.regular.tint(Color.primary.opacity(0.05)),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                }
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }
        }
    }
}

/// glassEffectID 需要 @Namespace，但 ViewModifier 无法自己持有；
/// 用单例持有一个 namespace 供整条控制条与面板共用（同一容器才能形变）。
@MainActor
final class MenuBarPlaybackGlassCoordinator {
    static let shared = MenuBarPlaybackGlassCoordinator()
    @Namespace private var storedNamespace
    var namespace: Namespace.ID { storedNamespace }
    private init() {}
}

/// glassEffectID 命名空间里的稳定标识。
/// 展开态是同一条胶囊原地换内容，所以只需一个 id——这也让玻璃形变
/// 在收起/展开之间保持连续，不会出现两个胶囊各自缩放的错位。
enum PlaybackGlassID: Hashable {
    /// 竖条本体。滑块也会 union 进这个 id，让两者是同一块玻璃。
    case bar
    /// 覆盖式滑块自己的形变身份：出现/消失时走 matchedGeometry，
    /// 视觉上就是从图标里长出来（与 `bar` 分开，才能各自独立形变）。
    case well(ExpanderKindKey)
}

/// `PlaybackGlassID` 需要跨类型引用展开档位，这里给一个独立的 Hashable 标识，
/// 避免把 View 内部的私有枚举暴露出去。
enum ExpanderKindKey: Hashable {
    case volume
    case rate
}

/// 竖向滑块（音量/速度共用），版式对齐系统播放器的竖向音量条：
/// 一条细轨 + 顶部一个白色圆头，圆头下面连一小段同宽短柄，
/// 整体被一圈细描边胶囊包住（用户给的目标截图就是这个构造）。
/// 0 在底、最大值在顶，拖动即时生效。
private struct GlassVerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    /// 额外刻度点（速度滑块用它标 1x）。
    var tickValue: Double?
    @State private var isDragging = false

    /// 尺寸按参考截图实测比例标定：参考条宽 93px、圆头 30px、轨道 8px，
    /// 即 圆头 ≈ 条宽 × 0.32、轨道 ≈ 条宽 × 0.086。
    /// 我们竖条内容宽 32pt → 圆头 10pt、轨道 3pt。
    /// 11pt 实测渲染后直径仍占条宽 0.69（离屏量过），偏大，收到 10pt。
    private let knobSize: CGFloat = 10
    private let trackThickness: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let usable = max(0, height - knobSize)
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let fraction = (clamped - range.lowerBound) / span
            // 上大下小：0 在底、最大值在顶。
            let knobY = usable * (1 - fraction)
            let knobCenter = knobY + knobSize / 2

            ZStack {
                // 轨道分两段画：
                // · 底槽（整条，浅色）——之前完全没画，所以看着像「只有一根杆」；
                // · 已填充段（从底到圆头中心，深色）——表示当前值。
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: trackThickness, height: height)

                Capsule()
                    .fill(Color.primary.opacity(0.82))
                    .frame(width: trackThickness, height: max(0, height - knobCenter))
                    .offset(y: height / 2 - max(0, height - knobCenter) / 2)

                // 刻度点（1x）画在描边胶囊内侧。
                if let tickValue {
                    let tf = (min(max(tickValue, range.lowerBound), range.upperBound) - range.lowerBound) / span
                    Circle()
                        .fill(Color.primary.opacity(0.30))
                        .frame(width: 3, height: 3)
                        .offset(y: usable * (1 - tf) + knobSize / 2 - height / 2 - 8)
                }

                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .scaleEffect(isDragging ? 1.08 : 1.0)
                    .offset(y: knobCenter - height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let raw = min(max((drag.location.y - knobSize / 2) / max(usable, 1), 0), 1)
                        let next = range.lowerBound + (1 - raw) * span
                        // 靠近 1x 吸附，方便取回原速
                        value = abs(next - 1.0) < 0.04 ? 1.0 : next
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isDragging)
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

/// 播放控制条按钮的按压样式：按下时图标周围浮出一个圆形高亮底，
/// 释放后弹回并淡出（与参考录像里点喇叭键时那圈浅色圆一致）。
/// 玻璃胶囊里的图标是纯线条，没有这个底就完全看不出点到了。
private struct PlaybackPressButtonStyle: ButtonStyle {
    /// 高亮圆的直径。默认略大于图标以留出呼吸感。
    var diameter: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 按下时图标本身也提亮（录像里喇叭键会从灰变深），
            // 配合下面那圈底，反馈才明确。
            .brightness(configuration.isPressed ? 0.22 : 0)
            .background {
                Circle()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0))
                    .frame(width: diameter, height: diameter)
                    // 按下时从略小长到全尺寸，像被手指压出来的一圈。
                    .scaleEffect(configuration.isPressed ? 1.0 : 0.72)
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(
                .spring(response: 0.20, dampingFraction: 0.72, blendDuration: 0),
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
    /// 轨道最小行高：与 SwiftUI 侧 `.frame(height: thumbnailSize + 4)` 对齐，
    /// 内容未加载时 documentView 不得塌成 0 高。
    let railMinimumHeight: CGFloat

    init(
        selectedIndex: Int?,
        itemStride: CGFloat,
        contentSignature: Int,
        railMinimumHeight: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.selectedIndex = selectedIndex
        self.itemStride = itemStride
        self.contentSignature = contentSignature
        self.railMinimumHeight = railMinimumHeight
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
                // 轨道高度兜底：首帧内容未加载（缩略图 URL 未解析/图未解码）时
                // fittingSize 可能塌成 0 高，documentView 高度跟着为 0，
                // 视觉上整条 rail 坍缩、footer 跳位。内容真实高度与
                // thumbnailSize+4 取大者，加载完成后再由正常 fittingSize 接管。
                let minHeight = railMinimumHeight
                let size = NSSize(
                    width: max(fittingSize.width, scrollView.contentSize.width),
                    height: max(fittingSize.height, scrollView.contentSize.height, minHeight)
                )
                if hostingView.frame.size != size {
                    hostingView.setFrameSize(size)
                }
                if scrollView.contentSize.height < minHeight {
                    // NSScrollView 不会自己长高；容器高度由 SwiftUI 侧固定，
                    // 这里只把 clip view 的可见行高顶住，避免塌缩闪烁。
                    scrollView.contentView.frame.size.height = max(scrollView.contentView.frame.height, minHeight)
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

    /// 把某个 chip 滚进可视区（左对齐语义）：只有它在可视区外时才滚动，
    /// 且滚到刚好完整露出它的最小偏移——轨道默认从最左开始展示，
    /// 内容不足以滚动时保持原位，不做视觉居中。
    func revealItem(at index: Int, stride: CGFloat) {
        guard let documentView, stride > 0 else { return }
        let viewportWidth = contentView.bounds.width
        let maxOffset = max(0, documentView.frame.width - viewportWidth)
        guard maxOffset > 0 else { return }
        let itemStart = CGFloat(index) * stride
        let itemEnd = itemStart + stride
        let currentOffset = contentView.bounds.origin.x
        // 完整可见（含一格余量）就不动，避免用户手动滚动后被抢回。
        guard itemStart < currentOffset
                || itemEnd > currentOffset + viewportWidth else {
            return
        }
        // 目标：让该 chip 尽量靠视口左侧完整露出。
        let targetOffset = min(max(itemStart, 0), maxOffset)
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
