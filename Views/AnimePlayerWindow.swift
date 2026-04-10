import SwiftUI
import AVKit
import QuartzCore
import Kingfisher

// MARK: - 通知名称
extension Notification.Name {
    static let togglePlayerFullScreen = Notification.Name("togglePlayerFullScreen")
}

// MARK: - AnimePlayerWindow - 现代视频播放器风格
struct AnimePlayerWindow: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @State private var selectedTab: Tab = .sources
    @State private var isHovering = false

    enum Tab: String, CaseIterable {
        case sources = "选集"
        case danmaku = "弹幕"
        case enhancement = "设置"
        
        var title: String {
            switch self {
            case .sources: return t("player.episodes")
            case .danmaku: return t("danmaku.title")
            case .enhancement: return t("player.settings")
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 统一背景
                AnimeCoverBackground(viewModel: viewModel)
                
                HStack(alignment: .top, spacing: 0) {
                    // 左侧播放器区域 (70%)
                    PlayerSection(viewModel: viewModel)
                        .frame(width: geometry.size.width * 0.7, height: geometry.size.height)
                    
                    // 右侧面板 (30%)
                    RightPanel(viewModel: viewModel, selectedTab: $selectedTab)
                        .frame(width: geometry.size.width * 0.3, height: geometry.size.height)
                }
                .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.2)) {
                    isHovering = hovering
                }
            }
        }
        .ignoresSafeArea()
        // 验证码 WebView Sheet
        .sheet(item: $viewModel.captchaVerificationSession) { session in
            LiquidGlassCaptchaSheet(
                session: session,
                onCancel: { viewModel.cancelCaptchaVerification() },
                onVerified: { Task { await viewModel.completeCaptchaVerificationAndContinue() } }
            )
        }
    }
}

// MARK: - 动漫封面背景
private struct AnimeCoverBackground: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    
    var body: some View {
        ZStack {
            // 深色基础背景
            Color(hex: "0A0A0C")
            
            // 封面图模糊背景
            if let coverURL = viewModel.anime.coverURL,
               let url = URL(string: coverURL) {
                KFImage(url)
                    .fade(duration: 0.3)
                    .placeholder { _ in
                        Color.clear
                    }
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 80)
                    .saturation(0.8)
                    .brightness(-0.3)
                    .opacity(0.6)
            }
            
            // 渐变叠加层
            LinearGradient(
                colors: [
                    Color.black.opacity(0.4),
                    Color.black.opacity(0.2),
                    Color.black.opacity(0.5)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - 播放器区域（现代化设计）
private struct PlayerSection: View {
    @ObservedObject var viewModel: AnimeDetailViewModel

    var body: some View {
        ZStack {
            // 播放器内容
            Group {
                if viewModel.isLoadingVideo {
                    LoadingScreen()
                } else if let player = viewModel.player {
                    PlayerContainerView(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    StandbyScreen(viewModel: viewModel)
                }
            }

            // 错误提示覆盖层
            if let error = viewModel.videoError {
                ErrorOverlay(error: error)
            }
        }
    }
}

// MARK: - 加载屏幕
private struct LoadingScreen: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // 现代化加载动画
            ProgressView()
                .scaleEffect(1.5)
                .tint(LiquidGlassColors.primaryPink)

            Text(t("player.loadingVideo"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))

            Spacer()
        }
    }
}

// MARK: - 待机屏幕
private struct StandbyScreen: View {
    @ObservedObject var viewModel: AnimeDetailViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // 图标
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                LiquidGlassColors.primaryPink.opacity(0.2),
                                LiquidGlassColors.secondaryViolet.opacity(0.15)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: "play.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [LiquidGlassColors.primaryPink, LiquidGlassColors.secondaryViolet],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .shadow(color: LiquidGlassColors.primaryPink.opacity(0.3), radius: 20, y: 8)

            VStack(spacing: 8) {
                Text(viewModel.anime.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(t("player.selectSourceOnRight"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }
}

// MARK: - 错误覆盖层
private struct ErrorOverlay: View {
    let error: String

    var body: some View {
        VStack(spacing: 16) {
            // 错误图标
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color(hex: "FF6B6B"))

            Text(t("player.playFailed"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)

            Text(error)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 20)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(hex: "1A1A24").opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.5), radius: 30, y: 15)
        .padding(40)
    }
}

// MARK: - 现代化图标按钮
private struct ModernIconButton: View {
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.2 : 0.12))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isHovered ? 0.3 : 0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 播放器容器
private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = FullScreenAVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsSharingServiceButton = false
        playerView.allowsPictureInPicturePlayback = true
        playerView.updatesNowPlayingInfoCenter = true
        playerView.showsFullScreenToggleButton = true
        // 使用 resizeAspect 保持视频比例，完整显示
        playerView.videoGravity = .resizeAspect
        // 确保视频居中显示
        playerView.allowsMagnification = false
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        nsView.videoGravity = .resizeAspect
    }
}

// MARK: - 支持全屏的 AVPlayerView
private class FullScreenAVPlayerView: AVPlayerView {
    private var fullScreenObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        // 确保视频层正确配置
        self.wantsLayer = true
        // 透明背景，让毛玻璃背景穿透
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }
    
    override func layout() {
        super.layout()
        // 确保视频层填满整个视图
        if let playerLayer = self.layer?.sublayers?.first as? AVPlayerLayer {
            playerLayer.frame = self.bounds
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let observer = fullScreenObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        fullScreenObserver = NotificationCenter.default.addObserver(
            forName: .togglePlayerFullScreen,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window?.toggleFullScreen(nil)
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let observer = fullScreenObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

// MARK: - 右侧面板（Bilibili 风格）
private struct RightPanel: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @Binding var selectedTab: AnimePlayerWindow.Tab

    var activeSources: [SourceSearchResult] {
        let sources = viewModel.sourceResults.filter { !$0.rule.deprecated }
        
        // 如果初始排序已冻结，按冻结顺序排列；否则实时排序
        if viewModel.isInitialLoadComplete, !viewModel.frozenSourceOrder.isEmpty {
            return sources.sorted { a, b in
                let idxA = viewModel.frozenSourceOrder.firstIndex(of: a.id) ?? Int.max
                let idxB = viewModel.frozenSourceOrder.firstIndex(of: b.id) ?? Int.max
                return idxA < idxB
            }
        } else {
            // 尚未冻结：实时排序（绿色 > 橙色 > 蓝色 > 其他）
            return sources.sorted { a, b in
                let priorityA = sortPriority(for: a.status)
                let priorityB = sortPriority(for: b.status)
                return priorityA < priorityB
            }
        }
    }
    
    // 排序优先级: 数字越小越靠前
    private func sortPriority(for status: SourceQueryStatus) -> Int {
        switch status {
        case .success: return 0      // 绿色 - 最前面
        case .needsSelection: return 1  // 橙色
        case .captcha: return 2     // 蓝色
        case .loading: return 3
        case .error: return 4
        case .noResult: return 5
        case .idle: return 6
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 视频信息区（固定顶部）
            VideoInfoHeader(viewModel: viewModel)
                .padding(.horizontal, 20)
                .padding(.top, 44)
            
            // 标签切换（简介/选集/设置）
            BilibiliStyleTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            
            // 分隔线
            GlassDivider()
                .padding(.horizontal, 20)
                .padding(.top, 12)
            
            // 内容区域
            Group {
                switch selectedTab {
                case .sources:
                    SourcesContentView(viewModel: viewModel, sources: activeSources)
                case .danmaku:
                    DanmakuSettingsView(viewModel: viewModel)
                case .enhancement:
                    EnhancementSettingsView(viewModel: viewModel)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 视频信息头部（B站风格）
private struct VideoInfoHeader: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @State private var isFavoriteHovered = false
    @State private var isSummaryExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行
            HStack(alignment: .top, spacing: 12) {
                Text(viewModel.anime.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                Spacer(minLength: 8)
                
                // 追番/收藏按钮
                Button {
                    viewModel.toggleFavorite()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 14, weight: .semibold))
                        Text(viewModel.isFavorite ? t("anime.favorited") : t("anime.favorite"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(viewModel.isFavorite ? .white : Color(hex: "FB7299"))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(viewModel.isFavorite ? Color(hex: "FB7299") : Color(hex: "FB7299").opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(viewModel.isFavorite ? Color.clear : Color(hex: "FB7299").opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .scaleEffect(isFavoriteHovered ? 1.02 : 1.0)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isFavoriteHovered = hovering
                    }
                }
            }
            
            // 元数据行（播放量、弹幕、评分等）
            HStack(spacing: 16) {
                if let rating = viewModel.anime.rating, let score = Double(rating) {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: "FFB800"))
                        Text(String(format: "%.1f", score))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: "FFB800"))
                    }
                }
                
                if let rank = viewModel.anime.rank {
                    Label("#\(rank)", systemImage: "trophy.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                
                if let airDate = viewModel.anime.airDate {
                    Label(String(airDate.prefix(4)), systemImage: "calendar")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                
                Label(viewModel.anime.typeDisplayName, systemImage: "tv")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
            
            // 简介（可展开/收起）
            ExpandableSummary(
                summary: viewModel.bangumiDetail?.summary ?? viewModel.anime.summary,
                isExpanded: $isSummaryExpanded
            )
        }
    }
}

// MARK: - 可展开简介
private struct ExpandableSummary: View {
    let summary: String?
    @Binding var isExpanded: Bool
    @State private var isHovered = false
    
    var body: some View {
        if let summary = summary, !summary.isEmpty {
            // 展开按钮放在行尾，节省空间
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineSpacing(4)
                        .lineLimit(isExpanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                    
                    if summary.count > 40 {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(hex: "00AEEC"))
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .opacity(isHovered ? 0.9 : 1.0)
            .padding(.top, 4)
        }
    }
}

// MARK: - B站风格标签栏（全局导航栏样式 + 滑动动画）
private struct BilibiliStyleTabBar: View {
    @Binding var selectedTab: AnimePlayerWindow.Tab
    @State private var hoveredTab: AnimePlayerWindow.Tab?
    
    private let controlHeight: CGFloat = 34
    @Namespace private var selectionNamespace
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(AnimePlayerWindow.Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(labelColor(for: tab))
                        .frame(maxWidth: .infinity)
                        .frame(height: controlHeight - 8)
                        .background {
                            if selectedTab == tab {
                                selectedTabBackground
                            } else if hoveredTab == tab {
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            }
                        }
                }
                .buttonStyle(.plain)
                .contentShape(Capsule(style: .continuous))
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.16)) {
                        hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .liquidGlassSurface(.prominent, in: Capsule(style: .continuous))
        .glassContainer(spacing: 10)
    }
    
    private func labelColor(for tab: AnimePlayerWindow.Tab) -> Color {
        if selectedTab == tab {
            return .white.opacity(0.96)
        }
        if hoveredTab == tab {
            return .white.opacity(0.86)
        }
        return .white.opacity(0.72)
    }
    
    private var selectedTabBackground: some View {
        Capsule(style: .continuous)
            .liquidGlassSurface(.max, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .matchedGeometryEffect(id: "playerTabSelection", in: selectionNamespace)
    }
}

// MARK: - 源内容视图（B站风格）
private struct SourcesContentView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    let sources: [SourceSearchResult]
    @State private var selectedSourceIndex: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // 规则加载中显示加载动画，避免用户看到突然变化
            if viewModel.isLoadingRules {
                LoadingStateView(message: "正在加载源...")
            } else if !viewModel.isInitialLoadComplete {
                // 初始排序尚未冻结：所有源还在搜索或解析集数中，显示统一加载状态
                LoadingStateView(message: "正在分析来源...")
            } else if sources.isEmpty {
                EmptyStateView(
                    icon: "exclamationmark.triangle.fill",
                    title: t("player.noRulesAvailable"),
                    message: t("player.installRulesFirst")
                )
            } else {
                // 源选择器（水平滚动标签）
                SourceTabSelector(
                    sources: sources,
                    selectedIndex: $selectedSourceIndex
                )
                .padding(.top, 12)
                .padding(.horizontal, 20)

                // 源内容
                if selectedSourceIndex < sources.count {
                    let source = sources[selectedSourceIndex]
                    SourceDetailView(
                        viewModel: viewModel,
                        source: source,
                        sourceIndex: viewModel.sourceResults.firstIndex(where: { $0.id == source.id }) ?? 0
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 源标签选择器（支持拖拽滚动）
private struct SourceTabSelector: View {
    let sources: [SourceSearchResult]
    @Binding var selectedIndex: Int
    @State private var dragOffset: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        SourceTabButton(
                            source: source,
                            isSelected: selectedIndex == index
                        ) {
                            selectedIndex = index
                        }
                        .id(index)
                    }
                }
                .offset(x: dragOffset)
            }
            .contentMargins(0, for: .scrollContent)
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        withAnimation(.easeOut(duration: 0.2)) {
                            dragOffset = 0
                        }
                    }
            )
            .onChange(of: selectedIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(height: 40)
    }
}

// MARK: - 源标签按钮（B站风格）
private struct SourceTabButton: View {
    let source: SourceSearchResult
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // 状态指示器
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                Text(source.rule.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1)
            )
            // 修复毛边：裁剪到圆角形状
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var statusColor: Color {
        switch source.status {
        case .success: return Color(hex: "34D399") // 绿色
        case .needsSelection: return Color(hex: "F59E0B") // 橙色 - 需要选择
        case .captcha: return Color(hex: "00AEEC") // 蓝色 - 需要验证码
        case .loading: return Color(hex: "FBBF24")
        case .error: return Color(hex: "EF4444")
        case .idle, .noResult: return Color.white.opacity(0.3)
        }
    }
}

// MARK: - 源状态指示器
private struct SourceStatusIndicator: View {
    let status: SourceQueryStatus
    @State private var isBlinking = false

    var body: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 6, height: 6)
            .opacity(isBlinking ? 0.3 : 1.0)
            .onAppear {
                if status == .loading {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        isBlinking = true
                    }
                }
            }
    }

    private var indicatorColor: Color {
        switch status {
        case .success: return LiquidGlassColors.onlineGreen // 绿色
        case .needsSelection: return Color(hex: "F59E0B") // 橙色 - 需要选择
        case .captcha: return Color(hex: "00AEEC") // 蓝色 - 需要验证码
        case .loading: return LiquidGlassColors.warningOrange
        case .error: return Color(hex: "FF6B6B")
        case .idle, .noResult: return LiquidGlassColors.textQuaternary
        }
    }
}

// MARK: - 源详情视图
private struct SourceDetailView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    let source: SourceSearchResult
    let sourceIndex: Int

    var body: some View {
        switch source.status {
        case .idle:
            StatusView(message: "准备搜索...", color: LiquidGlassColors.textQuaternary)

        case .loading:
            StatusView(message: "正在搜索...", color: LiquidGlassColors.warningOrange, isLoading: true)

        case .success:
            if let episodes = source.detail?.episodes, !episodes.isEmpty {
                EpisodeListView(
                    episodes: episodes,
                    viewModel: viewModel,
                    onSelect: { episode in
                        Task {
                            await viewModel.playEpisode(episode, from: sourceIndex)
                        }
                    }
                )
            } else {
                EmptyStateView(
                    icon: "film.fill",
                    title: t("player.noEpisodes"),
                    message: t("player.noPlayableEpisodes")
                )
            }

        case .noResult:
            NoResultWithManualSearchView(
                rule: source.rule,
                viewModel: viewModel
            )

        case .error(let message):
            StatusView(message: message, color: Color(hex: "FF6B6B"))

        case .needsSelection(let items):
            NeedsSelectionView(
                items: items,
                onSelect: { item in
                    Task {
                        await viewModel.selectSearchItem(item, for: source.rule)
                    }
                }
            )

        case .captcha:
            CaptchaRequiredView {
                viewModel.triggerCaptchaVerification(for: source.rule)
            }
        }
    }
}

// MARK: - 状态视图
private struct StatusView: View {
    let message: String
    let color: Color
    var isLoading: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            if isLoading {
                ProgressView()
                    .tint(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
            }

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 24)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 加载状态视图
private struct LoadingStateView: View {
    let message: String
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // 现代化加载动画
            ProgressView()
                .scaleEffect(1.2)
                .tint(LiquidGlassColors.primaryPink)
            
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - 剧集列表视图（B站风格垂直列表）
private struct EpisodeListView: View {
    let episodes: [AnimeDetail.AnimeEpisodeItem]
    let viewModel: AnimeDetailViewModel
    let onSelect: (AnimeDetail.AnimeEpisodeItem) -> Void

    var body: some View {
        ScrollView(showsIndicators: true) {
            LazyVStack(spacing: 0) {
                // 添加上边距，避免与 tabs 贴在一起
                Color.clear
                    .frame(height: 12)
                
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    EpisodeRow(
                        episode: episode,
                        index: index,
                        isLast: index == episodes.count - 1,
                        viewModel: viewModel,
                        onSelect: { onSelect(episode) }
                    )
                }
            }
            .padding(.bottom, 16)
        }
        .contentMargins(0, for: .scrollContent)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 剧集行（B站风格 + Bangumi 标题）
private struct EpisodeRow: View {
    let episode: AnimeDetail.AnimeEpisodeItem
    let index: Int
    let isLast: Bool
    @ObservedObject var viewModel: AnimeDetailViewModel
    let onSelect: () -> Void
    @State private var isHovered = false
    
    /// 是否正在播放当前剧集
    private var isPlaying: Bool {
        viewModel.currentEpisode?.id == episode.id
    }

    /// 获取显示标题（优先 Bangumi，其次源数据）
    private var displayTitle: String {
        // 优先使用 Bangumi 章节标题
        if let bangumiTitle = viewModel.getEpisodeTitle(for: episode.episodeNumber),
           !bangumiTitle.isEmpty {
            return bangumiTitle
        }
        // 其次使用源数据中的标题
        if let name = episode.name, !name.isEmpty,
           name != "\(episode.episodeNumber)" {
            return name
        }
        return ""
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // 序号或播放图标
                ZStack {
                    if isPlaying {
                        // 播放中动画背景
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: "00AEEC").opacity(0.2))
                            .frame(width: 36, height: 28)
                        
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: "00AEEC"))
                    } else {
                        Text("\(episode.episodeNumber)")
                            .font(.system(size: 15, weight: isHovered ? .semibold : .medium))
                            .foregroundStyle(isHovered ? .white : .white.opacity(0.7))
                            .frame(width: 36, alignment: .center)
                    }
                }
                
                // 剧集标题（左边集数，右边标题）
                if !displayTitle.isEmpty {
                    Text(displayTitle)
                        .font(.system(size: 14, weight: isPlaying ? .semibold : .regular))
                        .foregroundStyle(isPlaying ? Color(hex: "00AEEC") : (isHovered ? .white : .white.opacity(0.85)))
                        .lineLimit(1)
                }
                
                Spacer()
                
                // 播放状态
                if isPlaying {
                    HStack(spacing: 6) {
                        // 声波动画指示器
                        HStack(spacing: 2) {
                            ForEach(0..<4) { i in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color(hex: "00AEEC"))
                                    .frame(width: 2, height: CGFloat.random(in: 6...14))
                                    .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true).delay(Double(i) * 0.1), value: isPlaying)
                            }
                        }
                        .frame(height: 14)
                        
                        Text(t("player.playing"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: "00AEEC"))
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 弹幕设置视图（B站风格）
private struct DanmakuSettingsView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel

    var body: some View {
        ScrollView(showsIndicators: true) {
            VStack(spacing: 20) {
                // 主开关（B站风格大按钮）
                BilibiliStyleToggleCard(
                    icon: "text.bubble.fill",
                    iconColor: Color(hex: "00AEEC"),
                    title: t("danmaku.enableDanmaku"),
                    subtitle: t("danmaku.showRealtimeComments"),
                    isOn: binding(for: \.isEnabled)
                )
                
                // 外观设置
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("player.appearance"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 0) {
                        BilibiliSliderRow(
                            title: t("player.opacity"),
                            value: binding(for: \.opacity),
                            range: 0.1...1.0,
                            format: { "\(Int($0 * 100))%" }
                        )
                        
                        BilibiliSliderRow(
                            title: t("danmaku.fontSize"),
                            value: binding(for: \.fontSize),
                            range: 12...24,
                            format: { "\(Int($0))" }
                        )
                        
                        BilibiliSliderRow(
                            title: t("player.scrollSpeed"),
                            value: binding(for: \.speed),
                            range: 0.5...2.0,
                            format: { String(format: "%.1fx", $0) }
                        )
                    }
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(10)
                    .padding(.horizontal, 20)
                }

                // 去重设置
                BilibiliStyleToggleCard(
                    icon: "checkmark.circle.fill",
                    iconColor: Color(hex: "34D399"),
                    title: t("player.enableDeduplication"),
                    subtitle: t("player.hideDuplicate"),
                    isOn: binding(for: \.enableDeduplication)
                )

                // 弹幕类型
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("danmaku.type"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 0) {
                        BilibiliToggleRow(title: t("danmaku.top"), isOn: binding(for: \.enableTop))
                        BilibiliToggleRow(title: t("danmaku.bottom"), isOn: binding(for: \.enableBottom))
                        BilibiliToggleRow(title: t("danmaku.scroll"), isOn: binding(for: \.enableScroll), isLast: true)
                    }
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(10)
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binding(for keyPath: WritableKeyPath<DanmakuSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { viewModel.danmakuSettings[keyPath: keyPath] },
            set: { newValue in
                var settings = viewModel.danmakuSettings
                settings[keyPath: keyPath] = newValue
                viewModel.updateDanmakuSettings(settings)
            }
        )
    }

    private func binding(for keyPath: WritableKeyPath<DanmakuSettings, Double>) -> Binding<Double> {
        Binding(
            get: { viewModel.danmakuSettings[keyPath: keyPath] },
            set: { newValue in
                var settings = viewModel.danmakuSettings
                settings[keyPath: keyPath] = newValue
                viewModel.updateDanmakuSettings(settings)
            }
        )
    }
}

// MARK: - 增强设置视图（B站风格）
private struct EnhancementSettingsView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel

    var body: some View {
        ScrollView(showsIndicators: true) {
            VStack(spacing: 20) {
                // 画质增强
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("player.imageEnhancement"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 0) {
                        BilibiliToggleRow(title: t("player.superResolution"), isOn: binding(for: \.superResolution))
                        BilibiliToggleRow(title: t("player.aiDenoise"), isOn: binding(for: \.aiDenoise))
                        BilibiliToggleRow(title: t("player.colorEnhance"), isOn: binding(for: \.colorEnhancement), isLast: true)
                    }
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(10)
                    .padding(.horizontal, 20)
                }

                // 播放设置
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("player.playbackSettings"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 0) {
                        BilibiliToggleRow(title: t("player.autoPlayNext"), isOn: binding(for: \.autoPlayNext))
                        BilibiliToggleRow(title: t("player.skipOpEd"), isOn: binding(for: \.skipOpeningEnding), isLast: true)
                    }
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(10)
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binding(for keyPath: WritableKeyPath<AnimeDetailViewModel.PlayerEnhancementSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { viewModel.enhancementSettings[keyPath: keyPath] },
            set: { newValue in
                var settings = viewModel.enhancementSettings
                settings[keyPath: keyPath] = newValue
                viewModel.updateEnhancementSettings(settings)
            }
        )
    }
}

// MARK: - B站风格切换卡片
private struct BilibiliStyleToggleCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            // 图标
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconColor.opacity(0.15))
                )
            
            // 文字
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            
            Spacer()
            
            // 开关
            BilibiliToggle(isOn: $isOn)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.white.opacity(0.04))
        )
        .padding(.horizontal, 20)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - B站风格滑块行
private struct BilibiliSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.8))
                
                Spacer()
                
                Text(format(value))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(hex: "00AEEC"))
                    .monospacedDigit()
            }
            
            Slider(value: $value, in: range)
                .tint(Color(hex: "00AEEC"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - B站风格切换行
private struct BilibiliToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var isLast: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
            
            Spacer()
            
            BilibiliToggle(isOn: $isOn)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Rectangle()
                .fill(Color.white.opacity(0.02))
        )
        .overlay(alignment: .bottom) {
            if !isLast {
                GlassDivider()
                    .padding(.leading, 16)
            }
        }
    }
}

// MARK: - B站风格开关
private struct BilibiliToggle: View {
    @Binding var isOn: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        }) {
            ZStack {
                // 背景轨道
                Capsule()
                    .fill(isOn ? Color(hex: "00AEEC") : Color.white.opacity(0.2))
                    .frame(width: 48, height: 26)
                
                // 滑块
                Circle()
                    .fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .offset(x: isOn ? 10 : -10)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 控制面板区块
private struct PlayerControlPanelSection<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
            }
            content
        }
        .padding(16)
        .liquidGlassSurface(
            .subtle,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

// MARK: - 滑块行
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(LiquidGlassColors.textSecondary)

                Spacer()

                Text(format(value))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(LiquidGlassColors.primaryPink)
                    .monospacedDigit()
            }

            ModernSlider(value: $value, range: range)
        }
    }
}

// MARK: - 现代化滑块
private struct ModernSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        Slider(value: $value, in: range)
            .tint(LiquidGlassColors.primaryPink)
    }
}

// MARK: - 切换行
private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(LiquidGlassColors.textPrimary)

            Spacer()

            ModernToggle(isOn: $isOn)
        }
    }
}

// MARK: - 现代化开关
private struct ModernToggle: View {
    @Binding var isOn: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        }) {
            ZStack {
                Capsule()
                    .fill(isOn ? LiquidGlassColors.primaryPink.opacity(0.35) : Color.white.opacity(0.12))
                    .frame(width: 44, height: 24)

                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                    .offset(x: isOn ? 10 : -10)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                    )
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 空状态视图
private struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(LiquidGlassColors.textTertiary)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textSecondary)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 20)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 需要选择视图 (流媒体风格)
private struct NeedsSelectionView: View {
    let items: [SourceSearchItem]
    let onSelect: (SourceSearchItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: "00AEEC"))
                
                Text(t("player.selectMatch"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                
                Spacer()
                
                Text("\(items.count) \(t("player.options"))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(hex: "00AEEC").opacity(0.15))
                    )
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            // 分隔线
            GlassDivider()
                .padding(.horizontal, 20)
            
            // 列表内容
            ScrollView(showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SelectionRow(
                            item: item,
                            index: index,
                            isLast: index == items.count - 1,
                            onSelect: onSelect
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SelectionRow: View {
    let item: SourceSearchItem
    let index: Int
    let isLast: Bool
    let onSelect: (SourceSearchItem) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 14) {
                // 序号
                Text("\(index + 1)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isHovered ? Color(hex: "00AEEC") : LiquidGlassColors.textQuaternary)
                    .frame(width: 28, alignment: .center)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    Text(t("player.clickToSelect"))
                        .font(.system(size: 11))
                        .foregroundStyle(LiquidGlassColors.textTertiary)
                }

                Spacer()

                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        isHovered 
                            ? Color(hex: "00AEEC")
                            : LiquidGlassColors.textQuaternary
                    )
                    .opacity(isHovered ? 1.0 : 0.6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
            .overlay(alignment: .bottom) {
                if !isLast {
                    GlassDivider()
                        .padding(.leading, 58)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 无结果带手动搜索视图
private struct NoResultWithManualSearchView: View {
    let rule: AnimeRule
    @ObservedObject var viewModel: AnimeDetailViewModel
    @State private var isHovered = false
    @State private var customSearchText: String = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // 图标
            ZStack {
                Circle()
                    .fill(LiquidGlassColors.textQuaternary.opacity(0.15))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(LiquidGlassColors.textQuaternary)
            }
            .padding(.top, 60)
            .padding(.bottom, 20)
            
            // 文字
            VStack(spacing: 8) {
                Text(t("player.noResults"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                
                Text(t("player.noSearchResults"))
                    .font(.system(size: 13))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            .padding(.bottom, 20)
            
            // 自定义搜索输入框
            VStack(spacing: 12) {
                // 搜索输入框
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                    
                    TextField(t("player.enterSearchKeyword"), text: $customSearchText)
                        .font(.system(size: 14))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .focused($isTextFieldFocused)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isTextFieldFocused ? Color.white.opacity(0.3) : Color.white.opacity(0.15), lineWidth: 1)
                )
                .frame(width: 260)
                
                // 搜索按钮
                Button {
                    Task {
                        await viewModel.searchInSource(rule, query: customSearchText)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                        Text(t("player.search"))
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 260, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LiquidGlassColors.textSecondary.opacity(isHovered ? 0.3 : 0.2))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.2)) {
                        isHovered = hovering
                    }
                }
                .disabled(customSearchText.isEmpty)
                .opacity(customSearchText.isEmpty ? 0.6 : 1.0)
            }
            .padding(.bottom, 8)
            
            // 重新搜索按钮（使用原标题）
            Button {
                Task {
                    await viewModel.searchInSource(rule)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text(t("player.retrySearch"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(LiquidGlassColors.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
    }
}

// MARK: - 验证码 Required 视图
private struct CaptchaRequiredView: View {
    let onTrigger: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // 图标区域 - 简化样式
            ZStack {
                Circle()
                    .fill(Color(hex: "F59E0B").opacity(0.15))
                    .frame(width: 64, height: 64)

                Image(systemName: "lock.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color(hex: "F59E0B"))
            }
            .padding(.top, 40)
            .padding(.bottom, 20)

            // 文字内容
            VStack(spacing: 8) {
                Text(t("player.captchaRequired"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)

                Text(t("captcha.sourceRequiresContinue"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 260)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)

            // 主要操作按钮 - 简化样式
            Button {
                onTrigger()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14))
                    Text(t("captcha.enterCode"))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(width: 160, height: 38)
                .background(Color(hex: isHovered ? "E85A8F" : "FB7299"))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 验证码弹窗
private struct LiquidGlassCaptchaSheet: View {
    let session: CaptchaVerificationSession
    let onCancel: () -> Void
    let onVerified: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isCancelHovered = false
    @State private var isVerifyHovered = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 深色背景
                Color(hex: "0D0D10")
                    .ignoresSafeArea()

                // 主内容区
                VStack(spacing: 0) {
                    // 标题栏
                    captchaHeader
                    
                    // 信息提示区
                    captchaInfoBanner
                    
                    // WebView 容器
                    webviewContainer(in: geometry)
                    
                    // 底部操作栏
                    captchaFooter
                }
            }
        }
        .frame(minWidth: 900, minHeight: 700)
    }
    
    // MARK: - 标题栏
    private var captchaHeader: some View {
        HStack(spacing: 16) {
            // 左侧图标和标题
            HStack(spacing: 12) {
                // 验证图标 - 简化样式
                ZStack {
                    Circle()
                        .fill(Color(hex: "F59E0B").opacity(0.15))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: "lock.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "F59E0B"))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("player.securityVerification"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    
                    Text(session.rule.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()

            // 关闭按钮
            Button {
                dismiss()
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(isCancelHovered ? 0.1 : 0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isCancelHovered = hovering
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
    
    // MARK: - 信息横幅
    private var captchaInfoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "00AEEC"))
            
            Text(t("player.completeVerificationInstructions"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(hex: "00AEEC").opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
    
    // MARK: - WebView 容器
    private func webviewContainer(in geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // WebView 标题栏
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                    
                    Text(session.startURL.host ?? t("player.verificationPage"))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                
                Spacer()
                
                // 安全指示器
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(hex: "22C55E"))
                        .frame(width: 5, height: 5)
                    
                    Text(t("player.secureConnection"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "22C55E"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(hex: "22C55E").opacity(0.15))
                .cornerRadius(10)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hex: "1A1A20"))
            
            // WebView
            CaptchaVerificationWebView(
                url: session.startURL,
                customUserAgent: session.rule.userAgent
            )
            .frame(minHeight: 480)
        }
        .background(Color(hex: "121216"))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }
    
    // MARK: - 底部操作栏
    private var captchaFooter: some View {
        HStack(spacing: 12) {
            // 左侧：取消按钮
            Button {
                dismiss()
                onCancel()
            } label: {
                Text(t("cancel"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 100, height: 36)
                    .background(Color.white.opacity(isCancelHovered ? 0.1 : 0.05))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isCancelHovered = hovering
            }

            Spacer()

            // 右侧：完成验证按钮 - 简化样式
            Button {
                dismiss()
                onVerified()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text(t("player.verificationComplete"))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(width: 140, height: 36)
                .background(Color(hex: "22C55E"))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isVerifyHovered = hovering
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
