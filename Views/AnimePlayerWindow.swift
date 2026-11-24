import SwiftUI
import AVFoundation
import QuartzCore
import Kingfisher

// MARK: - 通知名称
extension Notification.Name {
    static let togglePlayerFullScreen = Notification.Name("togglePlayerFullScreen")
    static let playerDidEnterFullScreen = Notification.Name("playerDidEnterFullScreen")
    static let playerDidExitFullScreen = Notification.Name("playerDidExitFullScreen")
    static let playerShowControlBar = Notification.Name("playerShowControlBar")
    static let playerHideControlBar = Notification.Name("playerHideControlBar")
}

// MARK: - AnimePlayerWindow - 现代视频播放器风格
struct AnimePlayerWindow: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    let player: NativeVideoPlayer
    @State private var selectedTab: Tab = .sources
    @State private var isHovering = false
    @State private var isRightPanelCollapsed = false
    @State private var isPlayerFullscreen = false

    enum Tab: String, CaseIterable {
        case local = "本地"
        case sources = "选集"
        case danmaku = "弹幕"
        case enhancement = "设置"

        var title: String {
            switch self {
            case .local: return t("player.local")
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
                    // 左侧播放器区域 (动态宽度)
                    PlayerSection(
                        viewModel: viewModel,
                        isRightPanelCollapsed: $isRightPanelCollapsed,
                        isPlayerFullscreen: $isPlayerFullscreen,
                        player: player
                    )
                        .frame(
                            width: isPlayerFullscreen || isRightPanelCollapsed ? geometry.size.width : geometry.size.width * 0.7,
                            height: geometry.size.height
                        )
                        .zIndex(1)

                    // 右侧面板 (动态宽度)
                    if !isPlayerFullscreen {
                        RightPanel(viewModel: viewModel, selectedTab: $selectedTab)
                            .frame(
                                width: isRightPanelCollapsed ? 0 : geometry.size.width * 0.3,
                                height: geometry.size.height
                            )
                            .opacity(isRightPanelCollapsed ? 0 : 1)
                            .clipped()
                    }
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
        .onReceive(NotificationCenter.default.publisher(for: .playerDidEnterFullScreen)) { notification in
            guard notification.object as? String == viewModel.anime.id else { return }
            isPlayerFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerDidExitFullScreen)) { notification in
            guard notification.object as? String == viewModel.anime.id else { return }
            isPlayerFullscreen = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isRightPanelCollapsed = false
            }
        }
        // 弹幕源手动匹配 Sheet
        .sheet(isPresented: $viewModel.showDanmakuSourcePicker) {
            AnimeDanmakuSourceView(animeTitle: viewModel.anime.title) { selected in
                viewModel.selectDanmakuEpisode(selected)
            }
        }
        // 别名检索 Sheet（查源失败/无结果时使用其他标题重搜）
        .sheet(isPresented: $viewModel.showAliasSearchSheet) {
            AliasSearchSheet(viewModel: viewModel)
        }
        .sheet(item: $viewModel.captchaVerificationSession) { session in
            LiquidGlassCaptchaSheet(
                session: session,
                onCancel: { viewModel.cancelCaptchaVerification() },
                onVerified: { Task { await viewModel.completeCaptchaVerificationAndContinue(session: session) } }
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
    @Binding var isRightPanelCollapsed: Bool
    @Binding var isPlayerFullscreen: Bool
    @ObservedObject var player: NativeVideoPlayer
    @State private var isControlBarVisible = true
    @State private var hideControlBarWorkItem: DispatchWorkItem?

    /// 是否需要自动隐藏控制栏：全屏 或 侧边栏收起时，播放器占满窗口，控件会挡视频
    private var shouldAutoHideControlBar: Bool {
        isPlayerFullscreen || isRightPanelCollapsed
    }

    var body: some View {
        ZStack {
            // 播放器内容
            Group {
                if viewModel.isLoadingVideo {
                    LoadingScreen()
                } else if let url = viewModel.currentPlayURL {
                    NativeVideoPlayerView(player: player)
                        .onAppear {
                            player.load(url: url, startTime: viewModel.currentStartTime, httpHeaders: viewModel.currentHTTPHeaders, playbackID: viewModel.playbackID)
                        }
                        .onChange(of: viewModel.playbackID) { _, _ in
                            if let newURL = viewModel.currentPlayURL {
                                player.load(url: newURL, startTime: viewModel.currentStartTime, httpHeaders: viewModel.currentHTTPHeaders, playbackID: viewModel.playbackID)
                                // 新视频开始播放时自动展开侧边栏
                                if isRightPanelCollapsed {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        isRightPanelCollapsed = false
                                    }
                                }
                            }
                        }
                        .onReceive(player.$state) { state in
                            guard player.playbackID == viewModel.playbackID else { return }
                            viewModel.handlePlayerState(state)
                            if case .failed = state {
                                let failedPlaybackID = viewModel.playbackID
                                Task {
                                    guard viewModel.playbackID == failedPlaybackID else { return }
                                    await viewModel.retryPlayback(automatically: true)
                                }
                            }
                        }
                        .onReceive(player.currentTimePublisher) { newTime in
                            guard player.playbackID == viewModel.playbackID, !player.isSeeking else { return }
                            viewModel.handlePlayerProgress(currentTime: newTime, totalTime: player.totalDuration)
                        }
                        .onChange(of: viewModel.seekRequest?.id) { _, _ in
                            guard player.playbackID == viewModel.playbackID,
                                  let request = viewModel.seekRequest else { return }
                            player.seek(to: request.time, resumeAfterSeek: request.resume)
                            viewModel.consumeSeekRequest(request.id)
                        }
                        .overlay {
                            if viewModel.danmakuSettings.isEnabled {
                                AnimeDanmakuPlaybackOverlay(viewModel: viewModel, player: player)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            // 播放控制栏直接覆盖在播放器上，确保在 AppKit 视图之上渲染
                            PlayerControlOverlay(
                                animeId: viewModel.anime.id,
                                player: player,
                                isPlayerFullscreen: isPlayerFullscreen,
                                isControlBarVisible: isControlBarVisible,
                                viewModel: viewModel
                            )
                        }
                        .overlay(alignment: .trailing) {
                            // 右侧面板折叠/展开按钮（仅占据右侧边缘，不拦截播放器鼠标事件）
                            if !isPlayerFullscreen {
                                PanelToggleButton(isCollapsed: $isRightPanelCollapsed)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    StandbyScreen(viewModel: viewModel)
                }
            }

            // 缓冲中覆盖层
            if viewModel.isBuffering {
                BufferingOverlay()
            }

            // 错误提示覆盖层
            if let error = viewModel.videoError {
                ErrorOverlay(error: error, diagnostic: player.currentDiagnostic?.safeSummary,
                             onSwitchRoad: viewModel.canSwitchPlaybackRoad ? {
                                 Task { await viewModel.switchToNextPlaybackRoad() }
                             } : nil) {
                    Task { await viewModel.retryPlayback() }
                }
            }

            // 自定义标题栏（播放器左上角，不遮挡主要内容）
            if !isPlayerFullscreen {
                VStack(spacing: 0) {
                    HStack {
                        PlayerCustomTitleBar(animeId: viewModel.anime.id, title: viewModel.anime.title)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    Spacer()
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if viewModel.currentPlayURL == nil || viewModel.isLoadingVideo {
                AnimePlaybackAccessories(
                    syncPlay: viewModel.syncPlay,
                    episodeNumber: viewModel.currentEpisode?.episodeNumber,
                    hasVideo: false,
                    player: player,
                    standaloneSurface: true
                )
                .padding(.leading, 18)
                .padding(.bottom, 16)
                .opacity(isControlBarVisible ? 1 : 0)
                .allowsHitTesting(isControlBarVisible)
                .animation(.easeOut(duration: 0.25), value: isControlBarVisible)
            }
        }
        // 鼠标在播放器上移动时显示控制栏，根据当前状态决定是否自动隐藏
        .onHover { hovering in
            if hovering {
                showControlBar()
            } else if shouldAutoHideControlBar {
                hideControlBar()
            }
        }
        // 由 NSWindowController 级别的事件监听驱动显示控制栏
        .onReceive(NotificationCenter.default.publisher(for: .playerShowControlBar)) { notification in
            guard notification.object as? String == viewModel.anime.id else { return }
            showControlBar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerHideControlBar)) { notification in
            guard notification.object as? String == viewModel.anime.id else { return }
            hideControlBar()
        }
        .onChange(of: viewModel.currentPlayURL) { _, url in
            if url == nil { player.stop() }
        }
        // 状态变化时同步控制栏显隐模式
        .onChange(of: isPlayerFullscreen) { _, _ in syncControlBarMode() }
        .onChange(of: isRightPanelCollapsed) { _, _ in syncControlBarMode() }
    }

    private func showControlBar() {
        isControlBarVisible = true
        // 取消之前的隐藏任务
        hideControlBarWorkItem?.cancel()
        // 只有在需要自动隐藏的模式下才启动计时器
        guard shouldAutoHideControlBar else { return }
        hideControlBarWorkItem = DispatchWorkItem { [self] in
            isControlBarVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: hideControlBarWorkItem!)
    }

    private func hideControlBar() {
        isControlBarVisible = false
        hideControlBarWorkItem?.cancel()
    }

    private func syncControlBarMode() {
        if shouldAutoHideControlBar {
            // 切换到自动隐藏模式：立即隐藏，等鼠标移动再显示
            hideControlBar()
        } else {
            // 切换到始终显示模式
            hideControlBarWorkItem?.cancel()
            isControlBarVisible = true
        }
    }
}

// MARK: - 播放控制栏覆盖层（Apple TV / macOS 26 悬浮液态玻璃控制舱）
private struct PlayerControlOverlay: View {
    let animeId: String
    @ObservedObject var player: NativeVideoPlayer
    let isPlayerFullscreen: Bool
    let isControlBarVisible: Bool
    var viewModel: AnimeDetailViewModel? = nil
    @State private var currentState: PlaybackState = .idle
    @State private var currentTime: TimeInterval = 0
    @State private var sliderValue: Double = 0
    @State private var wasPlayingBeforeDrag = false
    @State private var isDraggingSlider = false
    @State private var hoveredControl: Control?

    private enum Control {
        case backward, playPause, forward, rate, mute, fullscreen
    }

    private static let playbackRates: [Double] = [0.5, 1.0, 1.25, 1.5, 2.0]

    init(animeId: String, player: NativeVideoPlayer, isPlayerFullscreen: Bool, isControlBarVisible: Bool,
         viewModel: AnimeDetailViewModel? = nil) {
        self.animeId = animeId
        self.player = player
        self.isPlayerFullscreen = isPlayerFullscreen
        self.isControlBarVisible = isControlBarVisible
        self.viewModel = viewModel
    }

    private var effectiveVolumeBinding: Binding<Double> {
        Binding(
            get: { player.isMuted ? 0 : player.playbackVolume },
            set: { newValue in
                let clamped = min(max(newValue, 0), 1)
                if player.isMuted && clamped > 0 {
                    player.isMuted = false
                }
                player.playbackVolume = clamped
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 8) {
                // 顶部：精密时间进度条
                HStack(spacing: 10) {
                    Text(formatPlayerTime(isDraggingSlider ? sliderValue : currentTime))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.80))
                        .frame(minWidth: 36, alignment: .trailing)

                    ApplePlayerSlider(
                        value: $sliderValue,
                        range: 0...max(player.totalDuration, 1),
                        trackHeight: 4,
                        expandedTrackHeight: 6,
                        thumbSize: 12
                    ) { editing in
                        isDraggingSlider = editing
                        if editing {
                            wasPlayingBeforeDrag = player.state.isPlaying
                            player.pause()
                        } else {
                            let shouldResume = wasPlayingBeforeDrag
                            player.seek(to: sliderValue, resumeAfterSeek: shouldResume)
                        }
                    }
                    .onChange(of: currentTime) { _, newValue in
                        if !isDraggingSlider && !player.isSeeking {
                            sliderValue = newValue
                        }
                    }

                    Text(formatPlayerTime(player.totalDuration))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.56))
                        .frame(minWidth: 36, alignment: .leading)
                }

                // 底部：左 / 中 / 右三区同轴对齐（播放传输组绝对居中）
                ZStack {
                    // 左侧：播放菜单与截图
                    HStack {
                        if let viewModel {
                            AnimePlaybackAccessories(
                                syncPlay: viewModel.syncPlay,
                                episodeNumber: viewModel.currentEpisode?.episodeNumber,
                                hasVideo: viewModel.videoError == nil,
                                player: player
                            )
                        }
                        Spacer(minLength: 0)
                    }

                    // 中间：后退 / 播放暂停 / 前进（绝对居中）
                    HStack(spacing: 8) {
                        Button {
                            player.skip(by: -15)
                        } label: {
                            Image(systemName: "gobackward.15")
                                .font(.system(size: 15.5, weight: .medium))
                                .foregroundStyle(.white.opacity(hoveredControl == .backward ? 1.0 : 0.88))
                                .frame(width: 30, height: 30)
                                .contentShape(Circle())
                        }
                        .buttonStyle(PlayerChromeControlStyle(hovered: hoveredControl == .backward))
                        .focusable(false)
                        .onHover { hovering in
                            hoveredControl = hovering ? .backward : (hoveredControl == .backward ? nil : hoveredControl)
                        }

                        Button {
                            togglePlayPause()
                        } label: {
                            Image(systemName: playPauseIconName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .offset(x: playPauseIconName == "play.fill" ? 1 : 0)
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 36, height: 36)
                                .contentShape(Circle())
                        }
                        .buttonStyle(PlayPausePrimaryButtonStyle(hovered: hoveredControl == .playPause))
                        .focusable(false)
                        .onHover { hovering in
                            hoveredControl = hovering ? .playPause : (hoveredControl == .playPause ? nil : hoveredControl)
                        }

                        Button {
                            player.skip(by: 15)
                        } label: {
                            Image(systemName: "goforward.15")
                                .font(.system(size: 15.5, weight: .medium))
                                .foregroundStyle(.white.opacity(hoveredControl == .forward ? 1.0 : 0.88))
                                .frame(width: 30, height: 30)
                                .contentShape(Circle())
                        }
                        .buttonStyle(PlayerChromeControlStyle(hovered: hoveredControl == .forward))
                        .focusable(false)
                        .onHover { hovering in
                            hoveredControl = hovering ? .forward : (hoveredControl == .forward ? nil : hoveredControl)
                        }
                    }

                    // 右侧：弹幕 / 倍速 | 音量 / 全屏
                    HStack {
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            if let viewModel {
                                DanmakuControlGroup(viewModel: viewModel)
                            }

                            // 倍速菜单（.button 样式保留纯 SwiftUI 胶囊，不注入 AppKit 丑箭头）
                            Menu {
                                ForEach(Self.playbackRates, id: \.self) { rate in
                                    Button {
                                        player.playbackRate = rate
                                    } label: {
                                        let label = formatPlaybackRate(rate)
                                        if abs(player.playbackRate - rate) < 0.01 {
                                            Label(label, systemImage: "checkmark")
                                        } else {
                                            Text(label)
                                        }
                                    }
                                }
                            } label: {
                                Text(formatPlaybackRate(player.playbackRate))
                                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white.opacity(hoveredControl == .rate ? 1.0 : 0.90))
                                    .padding(.horizontal, 7)
                                    .frame(minWidth: 34, minHeight: 24, maxHeight: 24)
                                    .contentShape(Capsule(style: .continuous))
                            }
                            .menuStyle(.button)
                            .buttonStyle(PlayerChromeControlStyle(hovered: hoveredControl == .rate, isActive: true, shape: .capsule))
                            .menuIndicator(.hidden)
                            .focusable(false)
                            .onHover { hovering in
                                hoveredControl = hovering ? .rate : (hoveredControl == .rate ? nil : hoveredControl)
                            }

                            Rectangle()
                                .fill(Color.white.opacity(0.14))
                                .frame(width: 1, height: 14)
                                .padding(.horizontal, 2)
                                .accessibilityHidden(true)

                            // 音量控制（精密细轨，替代 macOS 大圆头原生 Slider）
                            HStack(spacing: 4) {
                                Button {
                                    player.isMuted.toggle()
                                } label: {
                                    Image(systemName: volumeIconName)
                                        .font(.system(size: 13.5, weight: .medium))
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(.white.opacity(hoveredControl == .mute ? 1.0 : 0.88))
                                        .frame(width: 26, height: 28)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(PlayerChromeControlStyle(hovered: hoveredControl == .mute))
                                .focusable(false)
                                .onHover { hovering in
                                    hoveredControl = hovering ? .mute : (hoveredControl == .mute ? nil : hoveredControl)
                                }

                                ApplePlayerSlider(
                                    value: effectiveVolumeBinding,
                                    range: 0...1,
                                    trackHeight: 4,
                                    expandedTrackHeight: 5,
                                    thumbSize: 10
                                )
                                .frame(width: 54)
                            }

                            // 全屏切换
                            Button {
                                NotificationCenter.default.post(name: .togglePlayerFullScreen, object: animeId)
                            } label: {
                                Image(systemName: isPlayerFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(hoveredControl == .fullscreen ? 1.0 : 0.88))
                                    .frame(width: 28, height: 28)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(PlayerChromeControlStyle(hovered: hoveredControl == .fullscreen))
                            .focusable(false)
                            .onHover { hovering in
                                hoveredControl = hovering ? .fullscreen : (hoveredControl == .fullscreen ? nil : hoveredControl)
                            }
                        }
                    }
                }
                .frame(height: 36)
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 9)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.22))
            )
            .liquidGlassSurface(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: 920)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.42), .black.opacity(0.12), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .allowsHitTesting(false)
            )
        }
        // 传统播放器逻辑：鼠标移动时显示，3秒后自动隐藏
        .opacity(isControlBarVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: isControlBarVisible)
        .allowsHitTesting(isControlBarVisible)
        .onAppear {
            currentState = player.state
            currentTime = player.currentTime
            sliderValue = player.currentTime
        }
        .onReceive(player.currentTimePublisher) { newTime in
            currentTime = newTime
        }
        .onReceive(player.$state) { newState in
            currentState = newState
        }
    }

    private func togglePlayPause() {
        if currentState.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    private var playPauseIconName: String {
        if case .failed = currentState {
            return "play.slash.fill"
        }
        return currentState.isPlaying ? "pause.fill" : "play.fill"
    }

    private var volumeIconName: String {
        if player.isMuted || player.playbackVolume <= 0.001 {
            return "speaker.slash.fill"
        } else if player.playbackVolume < 0.33 {
            return "speaker.wave.1.fill"
        } else if player.playbackVolume < 0.67 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private func formatPlaybackRate(_ rate: Double) -> String {
        if abs(rate.rounded() - rate) < 0.001 {
            return "\(Int(rate.rounded()))×"
        }
        let roundedTenth = (rate * 10).rounded() / 10
        if abs(roundedTenth - rate) < 0.001 {
            return String(format: "%.1f×", rate)
        }
        return String(format: "%.2f×", rate)
    }
}

// MARK: - 弹幕控制组（独立观察 viewModel，保证开关状态实时响应）
private struct DanmakuControlGroup: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @State private var showDanmakuSettings = false
    @State private var hoveredControl: Control?

    private enum Control { case toggle, settings }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                viewModel.toggleDanmaku()
            } label: {
                Image(systemName: viewModel.danmakuSettings.isEnabled ? "captions.bubble.fill" : "captions.bubble")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        viewModel.danmakuSettings.isEnabled
                            ? .white
                            : .white.opacity(hoveredControl == .toggle ? 0.96 : 0.72)
                    )
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(PlayerChromeControlStyle(
                hovered: hoveredControl == .toggle,
                isActive: viewModel.danmakuSettings.isEnabled
            ))
            .focusable(false)
            .onHover { hovering in
                hoveredControl = hovering ? .toggle : (hoveredControl == .toggle ? nil : hoveredControl)
            }
            .help(t("anime.player.danmakuToggle"))

            Button {
                showDanmakuSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(hoveredControl == .settings || showDanmakuSettings ? 1.0 : 0.84))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(PlayerChromeControlStyle(
                hovered: hoveredControl == .settings,
                isActive: showDanmakuSettings
            ))
            .focusable(false)
            .onHover { hovering in
                hoveredControl = hovering ? .settings : (hoveredControl == .settings ? nil : hoveredControl)
            }
            .help(t("anime.player.danmakuSettingsButton"))
            .popover(isPresented: $showDanmakuSettings, arrowEdge: .top) {
                AnimeDanmakuSettingsPanel(viewModel: viewModel)
                    .frame(width: 340, height: 520)
            }
        }
    }
}

// MARK: - 播放/暂停主按钮样式
private struct PlayPausePrimaryButtonStyle: ButtonStyle {
    var hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fillOpacity: Double = configuration.isPressed ? 0.30 : (hovered ? 0.24 : 0.16)
        configuration.label
            .background(
                Circle()
                    .fill(Color.white.opacity(fillOpacity))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(hovered ? 0.26 : 0.16), lineWidth: 0.75)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

// MARK: - Apple 风格精密播放器滑块（时间进度 / 音量共用）
private struct ApplePlayerSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var trackHeight: CGFloat = 4
    var expandedTrackHeight: CGFloat = 6
    var thumbSize: CGFloat = 11
    var onEditingChanged: ((Bool) -> Void)? = nil

    @State private var isHovered = false
    @State private var isDragging = false

    private var isInteracting: Bool { isHovered || isDragging }

    private var progress: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let normalized = (value - range.lowerBound) / span
        return CGFloat(min(max(normalized, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let currentHeight = isInteracting ? expandedTrackHeight : trackHeight
            let filledWidth = max(0, min(width, width * progress))
            let clampedThumbX = min(max(filledWidth, thumbSize / 2), max(thumbSize / 2, width - thumbSize / 2))

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.22))
                    .frame(height: currentHeight)

                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isInteracting ? 1.0 : 0.90))
                    .frame(width: max(currentHeight, filledWidth), height: currentHeight)
                    .opacity(filledWidth > 0.5 ? 1 : 0)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                    .position(x: clampedThumbX, y: geometry.size.height / 2)
                    .scaleEffect(isInteracting ? 1.0 : 0.45)
                    .opacity(isInteracting ? 1.0 : 0.0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        updateValue(at: gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        updateValue(at: gesture.location.x, width: width)
                        if isDragging {
                            isDragging = false
                            onEditingChanged?(false)
                        }
                    }
            )
        }
        .frame(height: 18)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                isHovered = hovering
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isDragging)
    }

    private func updateValue(at x: CGFloat, width: CGFloat) {
        let ratio = Double(min(max(x / max(width, 1), 0), 1))
        value = range.lowerBound + (range.upperBound - range.lowerBound) * ratio
    }
}

// MARK: - 时间格式化辅助函数
private func formatPlayerTime(_ seconds: TimeInterval) -> String {
    let secsInt = Int(seconds)
    let hours = secsInt / 3600
    let minutes = (secsInt % 3600) / 60
    let secs = secsInt % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    } else {
        return String(format: "%02d:%02d", minutes, secs)
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
                .tint(.white)

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
                                Color.white.opacity(0.2),
                                Color.white.opacity(0.15)
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
                            colors: [.white, .white.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .shadow(color: Color.white.opacity(0.3), radius: 20, y: 8)

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

// MARK: - 缓冲中覆盖层
private struct BufferingOverlay: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)

            Text(t("player.buffering"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
    }
}

// MARK: - 错误覆盖层
private struct ErrorOverlay: View {
    let error: String
    var diagnostic: String? = nil
    var onSwitchRoad: (() -> Void)? = nil
    let onRetry: () -> Void

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

            HStack {
                Button(t("retry"), action: onRetry)
                    .buttonStyle(.borderedProminent)
                if let onSwitchRoad {
                    Button(t("anime.player.switchRoad"), action: onSwitchRoad)
                        .buttonStyle(.bordered)
                }
            }
            if let diagnostic {
                DisclosureGroup(t("anime.player.diagnostics")) {
                    Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: 440)
            }
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

// MARK: - 面板折叠/展开按钮
private struct PanelToggleButton: View {
    @Binding var isCollapsed: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isCollapsed.toggle()
            }
        } label: {
            ZStack {
                // 背景
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(isHovered ? 0.5 : 0.35))
                    .frame(width: 28, height: 56)

                // 箭头图标
                Image(systemName: isCollapsed ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.7))
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .padding(.trailing, isCollapsed ? 12 : 4)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
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
            // 尚未冻结：实时排序，与冻结口径一致（可播放 > 有剧集 > 待选择 > 验证 > 失败…）
            // 同优先级内按跨会话信誉分排序。
            return sources.sorted { a, b in
                let pa = viewModel.sourceAvailabilityPriority(a), pb = viewModel.sourceAvailabilityPriority(b)
                if pa != pb { return pa < pb }
                return AnimeSourceReputationStore.shared.ranksBefore(a.id, b.id)
            }
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

            if selectedTab != .sources {
                GlassDivider()
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            // 内容区域
            Group {
                switch selectedTab {
                case .local:
                    LocalEpisodesView(viewModel: viewModel)
                case .sources:
                    SourcesContentView(viewModel: viewModel, sources: activeSources)
                case .danmaku:
                    DanmakuSettingsView(viewModel: viewModel)
                case .enhancement:
                    AnimePlaybackSettingsView(viewModel: viewModel)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 播放器自定义标题栏
private struct PlayerCustomTitleBar: View {
    let animeId: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            // 左侧：自定义红绿灯按钮
            CustomWindowControls(
                onClose: { NSApp.keyWindow?.performClose(nil) },
                onMinimize: { NSApp.keyWindow?.performMiniaturize(nil) },
                onMaximize: { NotificationCenter.default.post(name: .togglePlayerFullScreen, object: animeId) }
            )

            // 窗口标题
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Spacer()
        }
        .frame(height: 28)
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

// MARK: - 本地缓存剧集列表（右栏「本地」tab）

private struct LocalEpisodesView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @ObservedObject private var downloadStore = AnimeDownloadStore.shared
    @ObservedObject private var downloadEngine = AnimeDownloadEngine.shared

    private var records: [AnimeDownloadRecord] {
        downloadStore.records(forAnime: viewModel.anime.id)
    }

    private var activeTasks: [AnimeDownloadEngine.TaskState] {
        downloadEngine.tasks.values
            .filter { $0.animeId == viewModel.anime.id && !$0.isCompleted && $0.errorMessage == nil }
            .sorted { $0.episodeNumber < $1.episodeNumber }
    }

    var body: some View {
        ScrollView(showsIndicators: true) {
            LazyVStack(spacing: 0) {
                Color.clear.frame(height: 12)

                if records.isEmpty && activeTasks.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                        Text(t("anime.download.empty"))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(t("anime.download.empty.hint"))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.35))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 80)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(records) { record in
                        LocalEpisodeRow(
                            record: record,
                            viewModel: viewModel,
                            isPlaying: viewModel.currentEpisode?.id == record.episodeId
                        )
                    }

                    ForEach(activeTasks) { task in
                        DownloadingTaskRow(task: task)
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .contentMargins(0, for: .scrollContent)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 本地剧集行

private struct LocalEpisodeRow: View {
    let record: AnimeDownloadRecord
    @ObservedObject var viewModel: AnimeDetailViewModel
    let isPlaying: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            viewModel.playLocalEpisode(record)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isPlaying ? "play.circle.fill" : "play.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isPlaying ? Color(hex: "00AEEC") : .white.opacity(0.6))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: t("episode.number"), record.episodeNumber))
                        .font(.system(size: 14, weight: isPlaying ? .semibold : .regular))
                        .foregroundStyle(isPlaying ? Color(hex: "00AEEC") : .white.opacity(0.85))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(record.sourceName)
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: record.fileSizeBytes, countStyle: .file))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                }

                Spacer()

                // 删除缓存
                if isHovered {
                    Button {
                        AnimeDownloadStore.shared.removeRecord(id: record.id, deleteFile: true)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(t("anime.download.deleteCache"))
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

// MARK: - 下载中任务行

private struct DownloadingTaskRow: View {
    let task: AnimeDownloadEngine.TaskState
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: max(0.02, task.progress))
                .progressViewStyle(.circular)
                .scaleEffect(0.55)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.episodeName ?? String(format: t("episode.number"), task.episodeNumber))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(Color(hex: "00AEEC"))
                            .frame(width: max(2, geometry.size.width * task.progress))
                    }
                }
                .frame(height: 3)

                Text("\(Int(task.progress * 100))%")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer()

            if isHovered {
                Button {
                    AnimeDownloadEngine.shared.cancelByRecordID(task.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(t("cancel"))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 选集侧栏
private struct SourcesContentView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    let sources: [SourceSearchResult]
    @State private var selectedSourceID: String?

    private var selectedSource: SourceSearchResult? {
        let preferredID = selectedSourceID ?? viewModel.currentSourceID
        return sources.first(where: { $0.id == preferredID }) ?? sources.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoadingRules && sources.isEmpty {
                LoadingStateView(message: t("animePlayer.loadingSources"))
            } else if sources.isEmpty {
                EmptyStateView(
                    icon: "exclamationmark.triangle.fill",
                    title: t("player.noRulesAvailable"),
                    message: t("player.installRulesFirst")
                )
            } else if let source = selectedSource,
                      let index = viewModel.sourceResults.firstIndex(where: { $0.id == source.id }) {
                SourceSearchProgressHeader(viewModel: viewModel, sources: sources)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                EpisodeSourceToolbar(viewModel: viewModel, sources: sources, source: source) { id in
                    selectedSourceID = id
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 6)

                SourceDetailView(viewModel: viewModel, source: source, sourceIndex: index)
                    .frame(maxWidth: .infinity)
            } else {
                LoadingStateView(message: t("animePlayer.parsingSources"))
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: viewModel.currentSourceID) { _, id in
            if let id, sources.contains(where: { $0.id == id }) { selectedSourceID = id }
        }
        .onAppear { autoSelectFirstAvailableIfNeeded() }
        .onChange(of: viewModel.isInitialLoadComplete) { _, _ in autoSelectFirstAvailableIfNeeded() }
    }

    /// 检索完成后默认选中第一个有剧集的源（排序已把可用源排前），避免停在失败源上。
    private func autoSelectFirstAvailableIfNeeded() {
        guard selectedSourceID == nil, viewModel.currentSourceID == nil,
              viewModel.isInitialLoadComplete else { return }
        if let best = sources.first(where: { $0.roads.contains { !$0.episodes.isEmpty } }) {
            selectedSourceID = best.id
        }
    }
}

// MARK: - 源检索进度（自动检测可用源的全局摘要）
private struct SourceSearchProgressHeader: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    let sources: [SourceSearchResult]

    private var finishedCount: Int {
        sources.filter { source in
            switch source.status {
            case .idle, .loading: return false
            case .success, .needsSelection, .noResult, .error, .captcha: return true
            }
        }.count
    }

    private var availableCount: Int {
        sources.filter { $0.roads.contains { !$0.episodes.isEmpty } }.count
    }

    var body: some View {
        HStack(spacing: 6) {
            if finishedCount < sources.count {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.85)
                Text(String(format: t("anime.player.sourceStatus.searchingProgress"), finishedCount, sources.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
            } else {
                Image(systemName: availableCount > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(availableCount > 0 ? LiquidGlassColors.onlineGreen : LiquidGlassColors.warningOrange)
                Text(String(format: t("anime.player.sourceStatus.availableCount"), availableCount))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
            }
            Spacer(minLength: 8)
            if finishedCount < sources.count {
                Text(String(format: t("anime.player.sourceStatus.availableCount"), availableCount))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
            }
        }
        .frame(height: 16)
    }
}

private struct EpisodeSourceToolbar: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    let sources: [SourceSearchResult]
    let source: SourceSearchResult
    let onSelectSource: (String) -> Void
    @State private var hoveredSelector: Selector?

    private enum Selector { case source, road }

    var body: some View {
        HStack(spacing: 8) {
            // 左侧：紧凑源与线路选择器胶囊（同心内胶囊 hover，不拉长制造无意义空白）
            HStack(spacing: 2) {
                sourceMenu

                if source.roads.count > 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1, height: 12)
                        .accessibilityHidden(true)

                    roadMenu
                }
            }
            .padding(3)
            .frame(height: 30)
            .liquidGlassSurface(.regular, in: Capsule(style: .continuous))

            Spacer(minLength: 4)

            // 右侧：独立圆形操作按钮，与左侧胶囊同高且共享 GlassEffectContainer
            AnimeEpisodeActionsMenu(
                sourceID: source.id,
                episodes: source.detail?.episodes ?? [],
                onBackToSearch: backToSearchAction,
                viewModel: viewModel
            )
        }
        .foregroundStyle(.white.opacity(0.92))
        .glassContainer(spacing: 8)
    }

    private var sourceMenu: some View {
        Menu {
            ForEach(sources) { item in
                let title = sourceTitle(for: item)
                let state = status(for: item)
                Button { onSelectSource(item.id) } label: {
                    // 菜单项内用 SF Symbol 着色点：AppKit 菜单不渲染自定义 Shape。
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(state.color)
                        if item.id == source.id { Label(title, systemImage: "checkmark") }
                        else { Text(title) }
                    }
                }
            }
        } label: {
            selectorLabel(source.rule.name, dotColor: status(for: source).color, isPrimary: true)
        }
        .menuStyle(.button)
        .buttonStyle(SelectorMenuStyle(hovered: hoveredSelector == .source))
        .menuIndicator(.hidden)
        .focusable(false)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                if hovering { hoveredSelector = .source }
                else if hoveredSelector == .source { hoveredSelector = nil }
            }
        }
        .accessibilityLabel(t("anime.player.source"))
        .accessibilityValue(sourceTitle(for: source))
        .help(sourceTitle(for: source))
    }

    private var roadMenu: some View {
        let title = source.detail?.title ?? t("anime.player.road")
        return Menu {
            ForEach(Array(source.roads.enumerated()), id: \.element.id) { index, road in
                Button { viewModel.selectRoad(index, sourceID: source.id) } label: {
                    if index == source.selectedRoadIndex { Label(road.title, systemImage: "checkmark") }
                    else { Text(road.title) }
                }
            }
        } label: {
            selectorLabel(title, dotColor: nil, isPrimary: false)
        }
        .menuStyle(.button)
        .buttonStyle(SelectorMenuStyle(hovered: hoveredSelector == .road))
        .menuIndicator(.hidden)
        .focusable(false)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                if hovering { hoveredSelector = .road }
                else if hoveredSelector == .road { hoveredSelector = nil }
            }
        }
        .accessibilityLabel(t("anime.player.road"))
        .accessibilityValue(title)
        .help(title)
    }

    private func selectorLabel(_ title: String, dotColor: Color?, isPrimary: Bool) -> some View {
        HStack(spacing: 5) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 12, weight: isPrimary ? .semibold : .medium))
                .foregroundStyle(.white.opacity(isPrimary ? 0.94 : 0.84))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.48))
                .fixedSize()
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .contentShape(Capsule(style: .continuous))
    }

    private var backToSearchAction: (() -> Void)? {
        guard case .success = source.status, source.searchItems != nil else { return nil }
        return { viewModel.resetSourceSelection(for: source.rule) }
    }

    private func sourceTitle(for item: SourceSearchResult) -> String {
        let state = status(for: item)
        let detail = state.episode.map { String(format: t("anime.player.sourceStatus.episodeNumber"), $0) + " · " + t(state.key) } ?? t(state.key)
        return item.rule.name + " — " + detail
    }

    private func status(for item: SourceSearchResult) -> (key: String, color: Color, episode: Int?) {
        // Report the actual current attempt only for its own online episode and source.
        if item.id == viewModel.currentSourceID, viewModel.currentPlayURL?.isFileURL != true,
           let current = viewModel.currentEpisode,
           item.roads.contains(where: { road in road.episodes.contains { $0.id == current.id && $0.url == current.url } }) {
            let number = current.episodeNumber
            if viewModel.isLoadingVideo {
                return ("anime.player.sourceStatus.loadingVideo", LiquidGlassColors.textQuaternary, number)
            }
            if let session = viewModel.captchaVerificationSession, session.rule.id == item.id,
               session.replayEpisode?.id == current.id {
                return ("anime.player.sourceStatus.verification", LiquidGlassColors.warningOrange, number)
            }
            if viewModel.videoError != nil {
                return ("anime.player.sourceStatus.playbackFailed", Color(hex: "FF6B6B"), number)
            }
            if viewModel.currentPlayURL != nil {
                switch viewModel.currentPlayerState {
                case .loading:
                    return ("anime.player.sourceStatus.loadingVideo", LiquidGlassColors.textQuaternary, number)
                case .playing:
                    return ("anime.player.sourceStatus.playing", LiquidGlassColors.onlineGreen, number)
                case .buffering:
                    return ("anime.player.sourceStatus.buffering", LiquidGlassColors.warningOrange, number)
                case .paused:
                    return ("anime.player.sourceStatus.paused", LiquidGlassColors.textQuaternary, number)
                case .finished:
                    return ("anime.player.sourceStatus.finished", LiquidGlassColors.textQuaternary, number)
                case .idle, .readyToPlay, .failed:
                    break
                }
            }
        }

        switch item.status {
        case .success:
            if item.roads.contains(where: { !$0.episodes.isEmpty }) {
                // 本会话真实起播成功过 → 绿色「可播放」；否则灰点「有剧集，未验播」。
                if viewModel.hasVerifiedPlayback(for: item.id) {
                    return ("anime.player.sourceStatus.verified", LiquidGlassColors.onlineGreen, nil)
                }
                return ("anime.player.sourceStatus.episodesUnverified", Color.white.opacity(0.45), nil)
            }
            return ("player.noEpisodes", Color(hex: "FF6B6B"), nil)
        case .needsSelection: return ("anime.player.sourceStatus.chooseTitle", LiquidGlassColors.warningOrange, nil)
        case .captcha: return ("anime.player.sourceStatus.verification", LiquidGlassColors.warningOrange, nil)
        case .error: return ("anime.player.sourceStatus.searchFailed", Color(hex: "FF6B6B"), nil)
        case .noResult: return ("anime.player.sourceStatus.noMatch", Color(hex: "FF6B6B"), nil)
        case .idle: return ("anime.player.sourceStatus.notSearched", LiquidGlassColors.textQuaternary, nil)
        case .loading: return ("animePlayer.searching", LiquidGlassColors.textQuaternary, nil)
        }
    }
}

// MARK: - 源/线路下拉的 hover/按压反馈
// Menu 用 .button 样式时 label 走纯 SwiftUI：borderlessButton 的 AppKit 渲染
// 会把 label 里的 Image 抽到文字前、并丢弃自定义背景。
private struct SelectorMenuStyle: ButtonStyle {
    var hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let opacity = configuration.isPressed ? 0.17 : (hovered ? 0.11 : 0)
        configuration.label
            .background(Color.white.opacity(opacity), in: Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
            StatusView(message: t("animePlayer.preparingSearch"), color: LiquidGlassColors.textQuaternary)

        case .loading:
            StatusView(message: t("animePlayer.searching"), color: LiquidGlassColors.warningOrange, isLoading: true)

        case .success:
            if let episodes = source.detail?.episodes, !episodes.isEmpty {
                EpisodeListView(
                    episodes: episodes,
                    sourceId: source.rule.id,
                    viewModel: viewModel,
                    onSelect: { episode in
                        Task { await viewModel.playEpisode(episode, from: sourceIndex) }
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
            SourceSearchFailureView(message: message, rule: source.rule, viewModel: viewModel)

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

// MARK: - 查源失败视图（Kazumi 同款：重试 / 别名 / 打开网站）
private struct SourceSearchFailureView: View {
    let message: String
    let rule: AnimeRule
    @ObservedObject var viewModel: AnimeDetailViewModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color(hex: "FF6B6B").opacity(0.9))
                .padding(.top, 48)

            Text(t("anime.player.sourceStatus.searchFailed"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textPrimary)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 260)

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.retrySearch(for: rule) }
                } label: {
                    Text(t("anime.player.sourceStatus.retrySearch"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .liquidGlassSurface(.prominent, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.showAliasSearch(for: rule)
                } label: {
                    Text(t("anime.player.sourceStatus.searchAlias"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .liquidGlassSurface(.regular, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button {
                if let url = URL(string: rule.baseURL) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "safari")
                        .font(.system(size: 11))
                    Text(t("anime.player.sourceStatus.openWebsite"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(LiquidGlassColors.accentCyan)
            }
            .buttonStyle(.plain)

            Spacer()
        }
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
    let sourceId: String
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
                        sourceId: sourceId,
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
    let sourceId: String
    @ObservedObject var viewModel: AnimeDetailViewModel
    let onSelect: () -> Void
    @State private var isHovered = false
    @ObservedObject private var downloadEngine = AnimeDownloadEngine.shared
    @ObservedObject private var downloadStore = AnimeDownloadStore.shared

    /// 是否正在播放当前剧集
    private var isPlaying: Bool {
        viewModel.currentEpisode?.id == episode.id && viewModel.currentSourceID == sourceId
    }

    /// 已缓存（记录存在且文件可用）
    private var isCached: Bool {
        downloadStore.isDownloaded(episodeId: episode.id, sourceId: sourceId)
    }

    /// 下载任务状态（排队/下载中/完成/失败）
    private var downloadState: AnimeDownloadEngine.TaskState? {
        downloadEngine.task(for: episode.id, sourceId: sourceId)
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
        HStack(spacing: 6) {
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
            downloadControl
                .frame(width: 32, height: 32)
        }
        .onHover { isHovered = $0 }
    }

    @ViewBuilder private var downloadControl: some View {
        let recordID = AnimeDownloadRecord.recordID(ruleId: sourceId, episodeId: episode.id)
        let resolving = viewModel.resolvingDownloads.contains(recordID)
        let error = viewModel.downloadErrors[recordID] ?? downloadState?.errorMessage
        if isCached || downloadState?.isCompleted == true {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(hex: "34D399"))
                .help(t("anime.download.cached"))
        } else if resolving {
            Image(systemName: "hourglass.circle")
                .font(.system(size: 17))
                .foregroundStyle(Color(hex: "00AEEC"))
        } else if let state = downloadState, error == nil {
            Button {
                downloadEngine.cancel(episodeId: episode.id, sourceId: sourceId)
            } label: {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.02, state.progress))
                        .stroke(Color(hex: "00AEEC"), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 7))
                }.frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("\(Int(state.progress * 100))% · \(t("cancel"))")
        } else {
            Button {
                guard let index = viewModel.sourceResults.firstIndex(where: { $0.id == sourceId }) else { return }
                Task { await viewModel.downloadEpisode(episode, from: index) }
            } label: {
                Image(systemName: error == nil ? "arrow.down.circle" : "arrow.clockwise.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(error == nil ? .white.opacity(isHovered ? 0.9 : 0.5) : Color(hex: "FF6B6B"))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(error.map { "\($0) · \(t("retry"))" } ?? t("anime.download.download"))
            .accessibilityLabel(t(error == nil ? "anime.download.download" : "retry"))
        }
    }
}

// MARK: - 弹幕设置视图（Kazumi 分区结构，原生 grouped Form）
private struct DanmakuSettingsView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel

    var body: some View {
        AnimeDanmakuSettingsPanel(viewModel: viewModel)
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
            .focusable(false)
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
struct LiquidGlassCaptchaSheet: View {
    let session: CaptchaVerificationSession
    let onCancel: () -> Void
    let onVerified: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isCancelHovered = false
    @State private var isVerifyHovered = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 深色液态玻璃背景
                DarkLiquidGlassBackground(cornerRadius: 16, isHovered: false)
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
                customUserAgent: AnimeVideoExtractor.effectiveUserAgent(rule: session.rule)
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
