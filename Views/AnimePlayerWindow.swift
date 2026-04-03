import SwiftUI
import AVKit

// MARK: - 通知名称
extension Notification.Name {
    static let togglePlayerFullScreen = Notification.Name("togglePlayerFullScreen")
}

// MARK: - AnimePlayerWindow - 独立播放器窗口
struct AnimePlayerWindow: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @State private var selectedTab: Tab = .sources
    
    enum Tab {
        case sources
        case danmaku
        case enhancement
    }
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // 左侧播放器（70%）
                PlayerSection(viewModel: viewModel)
                    .frame(width: geometry.size.width * 0.7)
                
                // 右侧面板（30%）- 使用统一背景
                RightPanel(viewModel: viewModel, selectedTab: $selectedTab)
                    .frame(width: geometry.size.width * 0.3)
                    .background(
                        PlayerSidebarBackground()
                            .ignoresSafeArea()
                    )
            }
        }
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

// MARK: - 播放器侧边栏背景
private struct PlayerSidebarBackground: View {
    var body: some View {
        ZStack {
            // 基础背景色 - 比播放器区域稍亮的深色
            Color(hex: "121216")
                .ignoresSafeArea()
            
            // 微妙的顶部渐变
            LinearGradient(
                colors: [
                    Color(hex: "1A1A20").opacity(0.5),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            // 左侧分隔线
            HStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.3),
                                Color.white.opacity(0.05),
                                Color.black.opacity(0.3)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1)
                Spacer()
            }
        }
    }
}

// MARK: - 播放器区域
private struct PlayerSection: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @State private var isFullScreen = false
    
    var body: some View {
        ZStack {
            Color.black
            
            if viewModel.isLoadingVideo {
                VStack(spacing: 28) {
                    Spacer()
                    
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.white.opacity(0.7))
                    
                    VStack(spacing: 10) {
                        Text(t("player.loadingVideo"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    
                    Spacer()
                }
            } else if let player = viewModel.player {
                PlayerContainerView(player: player)
            } else {
                VStack(spacing: 28) {
                    Spacer()
                    
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 72, weight: .ultraLight))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(hex: "FF3366").opacity(0.8),
                                    Color(hex: "8B5CF6").opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    VStack(spacing: 10) {
                        Text(viewModel.anime.title)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        
                        Text(t("player.selectSourceOnRight"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 40)
                    
                    Spacer()
                }
            }
            
            // 错误提示
            if let error = viewModel.videoError {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color(hex: "FF9F43"))
                    
                    Text(t("player.playFailed"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 40)
                }
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(hex: "1C1C24").opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                .padding(40)
            }
            
            // 全屏按钮 - 放在播放器控件层之上
            VStack {
                HStack {
                    Spacer()
                    PlayerControlButton(
                        icon: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                    ) {
                        toggleFullScreen()
                    }
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
            .allowsHitTesting(true)
        }
    }
    
    private func toggleFullScreen() {
        // 使用 AVPlayerView 的真正视频全屏
        NotificationCenter.default.post(name: .togglePlayerFullScreen, object: nil)
    }
}

// MARK: - 播放器控制按钮
private struct PlayerControlButton: View {
    let icon: String
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(Color.black.opacity(0.4))
        )
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .opacity(isHovered ? 1.0 : 0.7)
        .onHover { hovering in
            isHovered = hovering
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
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

// MARK: - 支持全屏的 AVPlayerView
private class FullScreenAVPlayerView: AVPlayerView {
    private var fullScreenObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // 移除之前的观察者
        if let observer = fullScreenObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // 添加全屏切换通知观察者
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
        // 安全地移除观察者
        MainActor.assumeIsolated {
            if let observer = fullScreenObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

// MARK: - 右侧面板
private struct RightPanel: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @Binding var selectedTab: AnimePlayerWindow.Tab
    
    var activeSources: [SourceSearchResult] {
        viewModel.sourceResults.filter { !$0.rule.deprecated }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            PanelHeader(selectedTab: $selectedTab)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            // 内容区域
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
}

// MARK: - 面板头部
private struct PanelHeader: View {
    @Binding var selectedTab: AnimePlayerWindow.Tab
    
    var body: some View {
        VStack(spacing: 12) {
            // Tab 切换按钮
            HStack(spacing: 4) {
                TabButton(
                    icon: "play.tv",
                    title: t("player.play"),
                    isSelected: selectedTab == .sources
                ) {
                    selectedTab = .sources
                }
                
                TabButton(
                    icon: "text.bubble",
                    title: t("danmaku.settings"),
                    isSelected: selectedTab == .danmaku
                ) {
                    selectedTab = .danmaku
                }
                
                TabButton(
                    icon: "sparkles",
                    title: t("player.enhancement"),
                    isSelected: selectedTab == .enhancement
                ) {
                    selectedTab = .enhancement
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }
}

// MARK: - Tab 按钮
private struct TabButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 源内容视图
private struct SourcesContentView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    let sources: [SourceSearchResult]
    @State private var selectedSourceIndex: Int = 0
    
    var body: some View {
        VStack(spacing: 0) {
            if sources.isEmpty {
                EmptyStateView(
                    icon: "exclamationmark.triangle.fill",
                    title: t("player.noRulesAvailable"),
                    message: t("player.installRulesFirst")
                )
            } else {
                // 源标签选择
                SourceTabSelector(
                    sources: sources,
                    selectedIndex: $selectedSourceIndex
                )
                .padding(.top, 8)
                .padding(.horizontal, 12)
                
                Divider()
                    .background(Color.white.opacity(0.06))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                
                // 源内容
                if selectedSourceIndex < sources.count {
                    let source = sources[selectedSourceIndex]
                    SourceDetailView(
                        viewModel: viewModel,
                        source: source,
                        sourceIndex: viewModel.sourceResults.firstIndex(where: { $0.id == source.id }) ?? 0
                    )
                }
            }
        }
    }
}

// MARK: - 源标签选择器
private struct SourceTabSelector: View {
    let sources: [SourceSearchResult]
    @Binding var selectedIndex: Int
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
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
            }
            .onChange(of: selectedIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

// MARK: - 源标签按钮
private struct SourceTabButton: View {
    let source: SourceSearchResult
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                StatusDot(status: source.status)
                
                Text(source.rule.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.65))
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.white.opacity(0.15) : Color.clear,
                    lineWidth: 1
                )
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 状态点
private struct StatusDot: View {
    let status: SourceQueryStatus
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .overlay(
                Group {
                    if case .loading = status {
                        ProgressView()
                            .scaleEffect(0.35)
                            .tint(.white)
                    }
                }
            )
    }
    
    private var color: Color {
        switch status {
        case .success: return Color(hex: "34D399")
        case .loading: return .clear
        case .error: return Color(hex: "FF6B6B")
        case .captcha: return Color(hex: "FF9F43")
        case .idle, .noResult, .needsSelection: return Color(hex: "6B7280")
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
            LoadingView(message: "准备搜索...")
            
        case .loading:
            LoadingView(message: "正在搜索...")
            
        case .success:
            if let episodes = source.detail?.episodes, !episodes.isEmpty {
                EpisodeListView(
                    episodes: episodes,
                    currentEpisode: viewModel.currentEpisode,
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
            EmptyStateView(
                icon: "magnifyingglass.circle.fill",
                title: t("player.noResults"),
                message: t("player.noSearchResults")
            )
            
        case .error(let message):
            EmptyStateView(
                icon: "exclamationmark.triangle.fill",
                title: t("player.searchFailed"),
                message: message
            )
            
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

// MARK: - 剧集列表视图（重新设计）
private struct EpisodeListView: View {
    let episodes: [AnimeDetail.AnimeEpisodeItem]
    let currentEpisode: AnimeDetail.AnimeEpisodeItem?
    let onSelect: (AnimeDetail.AnimeEpisodeItem) -> Void
    
    // 每行显示6个按钮
    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(episodes) { episode in
                    EpisodeButton(
                        episode: episode,
                        isPlaying: currentEpisode?.id == episode.id
                    ) {
                        onSelect(episode)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - 剧集按钮（优化性能版本）
private struct EpisodeButton: View {
    let episode: AnimeDetail.AnimeEpisodeItem
    let isPlaying: Bool
    let action: () -> Void
    @State private var isHovered = false

    var displayText: String {
        if let name = episode.name, !name.isEmpty {
            // 如果名字很短（如 "SP1", "OVA1"），直接显示
            if name.count <= 4 {
                return name
            }
            // 尝试从名字中提取纯数字
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if let intValue = Int(trimmed), intValue == episode.episodeNumber {
                return trimmed
            }
        }
        return "\(episode.episodeNumber)"
    }

    var body: some View {
        Button(action: action) {
            Text(displayText)
                .font(.system(size: 12, weight: isPlaying ? .bold : .medium, design: .rounded))
                .foregroundStyle(isPlaying ? .white : .white.opacity(0.8))
                .frame(minHeight: 32)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isPlaying ? Color.white.opacity(0.25) : Color.white.opacity(0.06),
                    lineWidth: isPlaying ? 1.5 : 0.5
                )
        )
        .scaleEffect(isPlaying ? 1.02 : (isHovered ? 1.02 : 1.0))
        .animation(.easeOut(duration: 0.08), value: isPlaying || isHovered)
        .help(episode.name ?? "第 \(episode.episodeNumber) 集")
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private var backgroundColor: Color {
        if isPlaying {
            return Color(hex: "FF3366").opacity(0.85)
        } else if isHovered {
            return Color.white.opacity(0.08)
        } else {
            return Color.white.opacity(0.03)
        }
    }
}

// MARK: - 弹幕设置视图
private struct DanmakuSettingsView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 主开关
                SettingsToggleRow(
                    title: t("danmaku.enableDanmaku"),
                    isOn: binding(for: \.isEnabled)
                )
                
                Divider()
                    .background(Color.white.opacity(0.06))
                
                // 滑块设置
                VStack(spacing: 12) {
                    SettingsSliderRow(
                        title: t("player.opacity"),
                        value: binding(for: \.opacity),
                        range: 0.1...1.0,
                        format: { String(format: "%.0f%%", $0 * 100) }
                    )
                    
                    SettingsSliderRow(
                        title: t("danmaku.fontSize"),
                        value: binding(for: \.fontSize),
                        range: 12...24,
                        format: { String(format: "%.0f", $0) }
                    )
                    
                    SettingsSliderRow(
                        title: t("player.scrollSpeed"),
                        value: binding(for: \.speed),
                        range: 0.5...2.0,
                        format: { String(format: "%.1fx", $0) }
                    )
                }
                
                Divider()
                    .background(Color.white.opacity(0.06))
                
                // 去重
                SettingsToggleRow(
                    title: t("player.enableDeduplication"),
                    subtitle: t("player.hideDuplicate"),
                    isOn: binding(for: \.enableDeduplication)
                )
                
                Divider()
                    .background(Color.white.opacity(0.06))
                
                // 弹幕类型
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("danmaku.type"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    
                    SettingsToggleRow(title: t("danmaku.top"), isOn: binding(for: \.enableTop))
                    SettingsToggleRow(title: t("danmaku.bottom"), isOn: binding(for: \.enableBottom))
                    SettingsToggleRow(title: t("danmaku.scroll"), isOn: binding(for: \.enableScroll))
                }
            }
            .padding(12)
        }
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

// MARK: - 增强设置视图
private struct EnhancementSettingsView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: t("player.imageEnhancement"), icon: "wand.and.stars")
                
                VStack(spacing: 8) {
                    SettingsToggleRow(
                        title: t("player.superResolution"),
                        subtitle: t("player.aiUpscale"),
                        isOn: binding(for: \.superResolution)
                    )
                    
                    SettingsToggleRow(
                        title: t("player.aiDenoise"),
                        subtitle: t("player.reduceNoise"),
                        isOn: binding(for: \.aiDenoise)
                    )
                    
                    SettingsToggleRow(
                        title: t("player.colorEnhance"),
                        subtitle: t("player.boostSaturation"),
                        isOn: binding(for: \.colorEnhancement)
                    )
                }
                
                Divider()
                    .background(Color.white.opacity(0.06))
                
                SectionHeader(title: t("player.playbackSettings"), icon: "gear")
                
                VStack(spacing: 8) {
                    SettingsToggleRow(
                        title: t("player.autoPlay"),
                        subtitle: t("player.autoPlayNext"),
                        isOn: binding(for: \.autoPlayNext)
                    )
                    
                    SettingsToggleRow(
                        title: t("player.skipOpEd"),
                        subtitle: t("player.smartSkip"),
                        isOn: binding(for: \.skipOpeningEnding)
                    )
                }
            }
            .padding(12)
        }
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

// MARK: - Section 标题
private struct SectionHeader: View {
    let title: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - 设置切换行（液态玻璃版本）
private struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isOn ? Color(hex: "FF3366") : .white.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            
            Spacer()
            
            // 液态玻璃开关
            LiquidGlassSwitchInternal(isOn: $isOn)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlassSurface(
            isHovered ? .prominent : .subtle,
            tint: isOn ? Color(hex: "FF3366").opacity(0.1) : nil,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 液态玻璃开关 (内部组件)
private struct LiquidGlassSwitchInternal: View {
    @Binding var isOn: Bool
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        }) {
            ZStack {
                // 背景轨道
                Capsule()
                    .fill(isOn ? Color(hex: "FF3366").opacity(0.35) : Color.white.opacity(0.12))
                    .frame(width: 44, height: 24)
                
                // 玻璃滑块
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
                    .offset(x: isOn ? 10 : -10)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                    )
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.92 : 1.0)
    }
}

// MARK: - 设置滑块行
private struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(format(value))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            
            Slider(value: $value, in: range)
                .tint(Color(hex: "FF3366"))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }
}

// MARK: - 空状态视图
private struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.2))
            
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 20)
            
            Spacer()
        }
    }
}

// MARK: - 加载中视图
private struct LoadingView: View {
    let message: String
    
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            
            ProgressView()
                .scaleEffect(0.9)
                .tint(.white.opacity(0.6))
            
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
            
            Spacer()
        }
    }
}

// MARK: - 需要选择视图
private struct NeedsSelectionView: View {
    let items: [SourceSearchItem]
    let onSelect: (SourceSearchItem) -> Void
    
    var body: some View {
        VStack(spacing: 10) {
            Text(t("player.selectMatch"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 10)
            
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        SelectionRow(item: item, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, 12)
            }
            
            Spacer()
        }
    }
}

private struct SelectionRow: View {
    let item: SourceSearchItem
    let onSelect: (SourceSearchItem) -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 10) {
                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 验证码 Required 视图
private struct CaptchaRequiredView: View {
    let onTrigger: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color(hex: "FF9F43").opacity(0.8))
            
            Text(t("player.captchaRequired"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            
            Text(t("captcha.sourceRequiresContinue"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            
            Button {
                onTrigger()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "lock.open")
                    Text(t("captcha.enterCode"))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 32)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hex: "3B8BFF").opacity(0.8))
            )
            .padding(.top, 6)
            
            Spacer()
        }
    }
}

// MARK: - 液态玻璃验证码弹窗
private struct LiquidGlassCaptchaSheet: View {
    let session: CaptchaVerificationSession
    let onCancel: () -> Void
    let onVerified: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            // 背景
            Color(hex: "0D0D0D")
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 标题栏
                HStack {
                    Text("\(t("player.verification")) - \(session.rule.name)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    
                    Spacer()
                    
                    Button {
                        dismiss()
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
                
                // 提示文字
                Text(t("player.completeVerification"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                
                // WebView
                CaptchaVerificationWebView(
                    url: session.startURL,
                    customUserAgent: session.rule.userAgent
                )
                .frame(minWidth: 860, minHeight: 580)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                )
                .padding(.horizontal, 16)
                
                // 底部按钮
                HStack(spacing: 10) {
                    Button {
                        dismiss()
                        onCancel()
                    } label: {
                        Text(t("cancel"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    
                    Spacer()
                    
                    Button {
                        dismiss()
                        onVerified()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(t("player.verificationComplete"))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(Color(hex: "3B8BFF").opacity(0.85))
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .frame(minWidth: 900, minHeight: 700)
    }
}
