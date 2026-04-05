import SwiftUI
import AVKit

// MARK: - 通知名称
extension Notification.Name {
    static let togglePlayerFullScreen = Notification.Name("togglePlayerFullScreen")
}

// MARK: - AnimePlayerWindow - 拟物化播放器窗口
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
                // 左侧播放器区域 - 监视器风格
                PlayerSection(viewModel: viewModel)
                    .frame(width: geometry.size.width * 0.65)
                    .background(SkeuomorphicColors.metalDark)

                // 右侧面板 - 控制面板风格
                RightPanel(viewModel: viewModel, selectedTab: $selectedTab)
                    .frame(width: geometry.size.width * 0.35)
                    .background(
                        ControlPanelBackground()
                            .ignoresSafeArea()
                    )
            }
            // 设备外壳效果
            .background(
                RoundedRectangle(cornerRadius: 0)
                    .stroke(Color.black.opacity(0.5), lineWidth: 2)
            )
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

// MARK: - 控制面板背景
private struct ControlPanelBackground: View {
    var body: some View {
        ZStack {
            // 基础金属背景
            SkeuomorphicColors.metalMid
                .ignoresSafeArea()

            // 金属质感渐变
            LinearGradient(
                colors: [
                    SkeuomorphicColors.metalLight.opacity(0.3),
                    Color.clear,
                    SkeuomorphicColors.metalDark.opacity(0.5)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 左侧金属接缝高光
            HStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.2),
                                Color.white.opacity(0.05),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 2)
                    .ignoresSafeArea()

                Spacer()
            }

            // 顶部高光
            VStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.1),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 1)
                    .ignoresSafeArea()

                Spacer()
            }
        }
    }
}

// MARK: - 播放器区域（监视器风格）
private struct PlayerSection: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @State private var isFullScreen = false

    var body: some View {
        ZStack {
            // 监视器边框
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    LinearGradient(
                        colors: [
                            SkeuomorphicColors.metalLight,
                            SkeuomorphicColors.metalMid,
                            SkeuomorphicColors.metalDark
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(8)

            // 屏幕区域
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black)
                .padding(12)
                .overlay(
                    // 屏幕内容
                    Group {
                        if viewModel.isLoadingVideo {
                            LoadingScreen()
                        } else if let player = viewModel.player {
                            PlayerContainerView(player: player)
                                .padding(12)
                        } else {
                            StandbyScreen(viewModel: viewModel)
                        }
                    }
                )

            // 错误提示覆盖层
            if let error = viewModel.videoError {
                ErrorOverlay(error: error)
                    .padding(40)
            }

            // 全屏按钮
            VStack {
                HStack {
                    Spacer()
                    MechanicalIconButton(
                        icon: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        action: toggleFullScreen
                    )
                    .padding(.top, 20)
                    .padding(.trailing, 20)
                }
                Spacer()
            }
        }
    }

    private func toggleFullScreen() {
        NotificationCenter.default.post(name: .togglePlayerFullScreen, object: nil)
    }
}

// MARK: - 加载屏幕
private struct LoadingScreen: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // 旋转的 LED 指示灯效果
            HStack(spacing: 8) {
                ForEach(0..<3) { i in
                    LEDIndicator(
                        color: SkeuomorphicColors.activeAmber,
                        isOn: true,
                        size: 8
                    )
                    .opacity(0.3 + Double(i) * 0.35)
                }
            }

            Text(t("player.loadingVideo"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SkeuomorphicColors.textSecondary)

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

            // 电源指示灯
            ZStack {
                Circle()
                    .fill(SkeuomorphicColors.metalDark)
                    .frame(width: 80, height: 80)
                    .shadow(color: Color.black.opacity(0.5), radius: 4, x: 0, y: 2)

                Image(systemName: "power")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(SkeuomorphicColors.ledAmber.opacity(0.6))
            }

            VStack(spacing: 8) {
                Text(viewModel.anime.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SkeuomorphicColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(t("player.selectSourceOnRight"))
                    .font(.system(size: 12))
                    .foregroundStyle(SkeuomorphicColors.textMuted)
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
            // 错误指示灯
            LEDIndicator(color: SkeuomorphicColors.ledRed, isOn: true, size: 16)

            Text(t("player.playFailed"))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(SkeuomorphicColors.textPrimary)

            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(SkeuomorphicColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 20)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SkeuomorphicColors.metalMid.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(SkeuomorphicColors.ledRed.opacity(0.3), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.5), radius: 10, x: 0, y: 5)
    }
}

// MARK: - 机械图标按钮
private struct MechanicalIconButton: View {
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SkeuomorphicColors.textPrimary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(MechanicalButtonStyle())
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

// MARK: - 右侧面板（控制面板）
private struct RightPanel: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @Binding var selectedTab: AnimePlayerWindow.Tab

    var activeSources: [SourceSearchResult] {
        viewModel.sourceResults.filter { !$0.rule.deprecated }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 模式选择器（机械按键组）
            ModeSelector(selectedTab: $selectedTab)
                .padding(.horizontal, 12)
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

// MARK: - 模式选择器（机械按键组）
private struct ModeSelector: View {
    @Binding var selectedTab: AnimePlayerWindow.Tab

    var body: some View {
        HStack(spacing: 8) {
            ModeButton(
                title: t("player.play"),
                isSelected: selectedTab == .sources
            ) {
                selectedTab = .sources
            }

            ModeButton(
                title: t("danmaku.settings"),
                isSelected: selectedTab == .danmaku
            ) {
                selectedTab = .danmaku
            }

            ModeButton(
                title: t("player.enhancement"),
                isSelected: selectedTab == .enhancement
            ) {
                selectedTab = .enhancement
            }
        }
    }
}

// MARK: - 模式按钮
private struct ModeButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
        }
        .buttonStyle(MechanicalButtonStyle(isActive: isSelected, cornerRadius: 6))
        .frame(maxWidth: .infinity)
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
                // 源选择器
                SourceTabSelector(
                    sources: sources,
                    selectedIndex: $selectedSourceIndex
                )
                .padding(.top, 12)
                .padding(.horizontal, 12)

                // 分隔线
                Rectangle()
                    .fill(Color.black.opacity(0.3))
                    .frame(height: 1)
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
                HStack(spacing: 8) {
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // LED 状态指示灯
                SourceStatusLED(status: source.status)

                Text(source.rule.name)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
            }
            .foregroundStyle(isSelected ? SkeuomorphicColors.activeAmber : SkeuomorphicColors.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
        .buttonStyle(MechanicalButtonStyle(isActive: isSelected, cornerRadius: 6))
    }
}

// MARK: - 源状态 LED
private struct SourceStatusLED: View {
    let status: SourceQueryStatus

    var body: some View {
        LEDIndicator(
            color: ledColor,
            isOn: isOn,
            size: 6
        )
    }

    private var ledColor: Color {
        switch status {
        case .success: return SkeuomorphicColors.ledGreen
        case .loading: return SkeuomorphicColors.ledAmber
        case .error: return SkeuomorphicColors.ledRed
        case .captcha: return SkeuomorphicColors.ledAmber
        case .idle, .noResult, .needsSelection: return SkeuomorphicColors.ledOff
        }
    }

    private var isOn: Bool {
        switch status {
        case .success, .error, .captcha: return true
        case .loading: return true // 会闪烁
        case .idle, .noResult, .needsSelection: return false
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
            StatusView(message: "准备搜索...", ledColor: SkeuomorphicColors.ledOff)

        case .loading:
            StatusView(message: "正在搜索...", ledColor: SkeuomorphicColors.ledAmber, isBlinking: true)

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
            StatusView(message: message, ledColor: SkeuomorphicColors.ledRed)

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
    let ledColor: Color
    var isBlinking: Bool = false
    @State private var isVisible = true

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            LEDIndicator(color: ledColor, isOn: isVisible, size: 12)
                .onAppear {
                    if isBlinking {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            isVisible = false
                        }
                    }
                }

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(SkeuomorphicColors.textSecondary)

            Spacer()
        }
    }
}

// MARK: - 剧集列表视图
private struct EpisodeListView: View {
    let episodes: [AnimeDetail.AnimeEpisodeItem]
    let currentEpisode: AnimeDetail.AnimeEpisodeItem?
    let onSelect: (AnimeDetail.AnimeEpisodeItem) -> Void

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

// MARK: - 剧集按钮（机械按键风格）
private struct EpisodeButton: View {
    let episode: AnimeDetail.AnimeEpisodeItem
    let isPlaying: Bool
    let action: () -> Void
    @State private var isHovered = false

    var displayText: String {
        if let name = episode.name, !name.isEmpty {
            if name.count <= 4 {
                return name
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if let intValue = Int(trimmed), intValue == episode.episodeNumber {
                return trimmed
            }
        }
        return "\(episode.episodeNumber)"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isPlaying {
                    LEDIndicator(color: SkeuomorphicColors.activeAmber, isOn: true, size: 4)
                }

                Text(displayText)
                    .font(.system(size: 12, weight: isPlaying ? .bold : .medium))
            }
            .foregroundStyle(isPlaying ? SkeuomorphicColors.activeAmber : SkeuomorphicColors.textPrimary)
            .frame(minHeight: 32)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MechanicalButtonStyle(isActive: isPlaying, cornerRadius: 4))
        .help(episode.name ?? "第 \(episode.episodeNumber) 集")
    }
}

// MARK: - 弹幕设置视图（控制面板风格）
private struct DanmakuSettingsView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 主开关
                ControlPanelSection(title: t("danmaku.settings")) {
                    HStack {
                        Text(t("danmaku.enableDanmaku"))
                            .font(.system(size: 13))
                            .foregroundStyle(SkeuomorphicColors.textPrimary)

                        Spacer()

                        ToggleSwitch(isOn: binding(for: \.isEnabled))
                    }
                }

                // 外观设置
                ControlPanelSection(title: t("player.appearance")) {
                    VStack(spacing: 16) {
                        SliderRow(
                            title: t("player.opacity"),
                            value: binding(for: \.opacity),
                            range: 0.1...1.0,
                            format: { "\(Int($0 * 100))%" }
                        )

                        SliderRow(
                            title: t("danmaku.fontSize"),
                            value: binding(for: \.fontSize),
                            range: 12...24,
                            format: { "\(Int($0))pt" }
                        )

                        SliderRow(
                            title: t("player.scrollSpeed"),
                            value: binding(for: \.speed),
                            range: 0.5...2.0,
                            format: { String(format: "%.1fx", $0) }
                        )
                    }
                }

                // 去重
                ControlPanelSection {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("player.enableDeduplication"))
                                .font(.system(size: 13))
                                .foregroundStyle(SkeuomorphicColors.textPrimary)

                            Text(t("player.hideDuplicate"))
                                .font(.system(size: 10))
                                .foregroundStyle(SkeuomorphicColors.textMuted)
                        }

                        Spacer()

                        ToggleSwitch(isOn: binding(for: \.enableDeduplication))
                    }
                }

                // 弹幕类型
                ControlPanelSection(title: t("danmaku.type")) {
                    VStack(spacing: 12) {
                        ToggleRow(title: t("danmaku.top"), isOn: binding(for: \.enableTop))
                        ToggleRow(title: t("danmaku.bottom"), isOn: binding(for: \.enableBottom))
                        ToggleRow(title: t("danmaku.scroll"), isOn: binding(for: \.enableScroll))
                    }
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
            VStack(spacing: 16) {
                ControlPanelSection(title: t("player.imageEnhancement")) {
                    VStack(spacing: 12) {
                        ToggleRow(title: t("player.superResolution"), isOn: binding(for: \.superResolution))
                        ToggleRow(title: t("player.aiDenoise"), isOn: binding(for: \.aiDenoise))
                        ToggleRow(title: t("player.colorEnhance"), isOn: binding(for: \.colorEnhancement))
                    }
                }

                ControlPanelSection(title: t("player.playbackSettings")) {
                    VStack(spacing: 12) {
                        ToggleRow(title: t("player.autoPlay"), isOn: binding(for: \.autoPlayNext))
                        ToggleRow(title: t("player.skipOpEd"), isOn: binding(for: \.skipOpeningEnding))
                    }
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
                    .foregroundStyle(SkeuomorphicColors.textSecondary)

                Spacer()

                Text(format(value))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(SkeuomorphicColors.activeAmber)
                    .monospacedDigit()
            }

            MetalSlider(value: $value, range: range)
        }
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
                .foregroundStyle(SkeuomorphicColors.textPrimary)

            Spacer()

            ToggleSwitch(isOn: $isOn)
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
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(SkeuomorphicColors.textMuted)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SkeuomorphicColors.textSecondary)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(SkeuomorphicColors.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 20)

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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SkeuomorphicColors.textSecondary)
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

    var body: some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 10) {
                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(SkeuomorphicColors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SkeuomorphicColors.textMuted)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
        .buttonStyle(MechanicalButtonStyle(cornerRadius: 4))
    }
}

// MARK: - 验证码 Required 视图
private struct CaptchaRequiredView: View {
    let onTrigger: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            LEDIndicator(color: SkeuomorphicColors.ledAmber, isOn: true, size: 20)

            Text(t("player.captchaRequired"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SkeuomorphicColors.textPrimary)

            Text(t("captcha.sourceRequiresContinue"))
                .font(.system(size: 11))
                .foregroundStyle(SkeuomorphicColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Button {
                onTrigger()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.open")
                    Text(t("captcha.enterCode"))
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(MechanicalButtonStyle(isActive: true, cornerRadius: 16))
            .padding(.top, 6)

            Spacer()
        }
    }
}

// MARK: - 验证码弹窗
private struct LiquidGlassCaptchaSheet: View {
    let session: CaptchaVerificationSession
    let onCancel: () -> Void
    let onVerified: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // 背景
            SkeuomorphicColors.metalDark
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // 标题栏
                HStack {
                    HStack(spacing: 8) {
                        LEDIndicator(color: SkeuomorphicColors.ledAmber, isOn: true, size: 8)

                        Text("\(t("player.verification")) - \(session.rule.name)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SkeuomorphicColors.textPrimary)
                    }

                    Spacer()

                    Button {
                        dismiss()
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SkeuomorphicColors.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(MechanicalButtonStyle(cornerRadius: 14))
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // 提示文字
                Text(t("player.completeVerification"))
                    .font(.system(size: 11))
                    .foregroundStyle(SkeuomorphicColors.textMuted)
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                        .innerShadow(color: Color.black.opacity(0.5), radius: 2, x: 0, y: 1)
                )
                .padding(.horizontal, 16)

                // 底部按钮
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                        onCancel()
                    } label: {
                        Text(t("cancel"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(MechanicalButtonStyle(cornerRadius: 16))
                    .frame(width: 80)

                    Spacer()

                    Button {
                        dismiss()
                        onVerified()
                    } label: {
                        HStack(spacing: 6) {
                            LEDIndicator(color: SkeuomorphicColors.ledGreen, isOn: true, size: 6)
                            Text(t("player.verificationComplete"))
                        }
                        .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(MechanicalButtonStyle(isActive: true, cornerRadius: 16))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .frame(minWidth: 900, minHeight: 700)
    }
}
