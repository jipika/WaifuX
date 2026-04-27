import SwiftUI
import AppKit
import Kingfisher

// MARK: - 动漫详情页 - 与 MediaDetailSheet 风格一致
// 液态玻璃材质，沉浸式全屏设计，支持横屏背景

struct AnimeDetailSheet: View {
    // 使用 AnimeSearchResult 作为数据源
    let anime: AnimeSearchResult
    @Binding var isPresented: Bool

    // 支持可选类型的 Binding（用于 ContentView 的 selectedAnime）
    init(anime: AnimeSearchResult, isPresented: Binding<Bool>) {
        self.anime = anime
        self._isPresented = isPresented
        self._viewModel = StateObject(wrappedValue: AnimeDetailViewModel(anime: anime))
    }

    init(anime: AnimeSearchResult, selectedAnime: Binding<AnimeSearchResult?>) {
        self.anime = anime
        self._isPresented = Binding(
            get: { selectedAnime.wrappedValue != nil },
            set: { if !$0 { selectedAnime.wrappedValue = nil } }
        )
        self._viewModel = StateObject(wrappedValue: AnimeDetailViewModel(anime: anime))
    }

    @StateObject private var viewModel: AnimeDetailViewModel
    @State private var isVisible = false
    @State private var isImageLoaded = false
    @State private var scrollOffset: CGFloat = 0
    @State private var showInfoBubble = false
    @State private var isHeroContentHidden = false

    // MARK: - 键盘快捷键
    @State private var keyboardMonitor: Any?
    
    // 背景图状态管理
    @State private var backdropURL: String?
    @State private var isLoadingBackdrop = false
    
    // 挤压动画配置
    private let squeezeThreshold: CGFloat = 80
    private let maxSqueezeOffset: CGFloat = 120
    
    // 封面图 URL（备用）
    private var coverImageURL: URL? {
        anime.coverURL.flatMap { URL(string: $0) }
    }
    
    var body: some View {
        GeometryReader { geometry in
            let _ = max(28, min(72, geometry.size.width * 0.05))
            let topBarTopInset = max(geometry.safeAreaInsets.top, 18)
            let bottomSafeInset = max(geometry.safeAreaInsets.bottom, 28)
            
            let viewW = geometry.size.width
            let viewH = geometry.size.height
            
            ZStack(alignment: .topLeading) {
                // 深色背景
                Color(hex: "0A0A0C")
                    .ignoresSafeArea()
                    .coordinateSpace(name: "scroll")
                
                // 背景图区域（包含双图叠加过渡）
                if isVisible {
                    layeredBackgroundView(width: viewW, height: viewH)
                }
                
                // 加载动画（仅在两张图都未加载完成时显示）
                if !isImageLoaded {
                    LoadingOverlayView()
                        .frame(width: viewW, height: viewH)
                        .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                }
                
                // 叠在固定底图上的轻暗角
                ZStack {
                    VStack {
                        LinearGradient(
                            colors: [Color.black.opacity(0.52), Color.black.opacity(0.18), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 180)
                        Spacer()
                    }
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [Color.clear, Color.black.opacity(0.35), Color.black.opacity(0.72)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: min(viewH * 0.45, 520))
                    }
                }
                .allowsHitTesting(false)
                
                // ScrollView 包含内容区域
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // 顶部空白占位（让背景图显示）
                        Color.clear
                            .frame(height: detailScrollTopInset(viewportHeight: viewH, heroHidden: isHeroContentHidden))
                        
                        // 内容区域
                        VStack(alignment: .leading, spacing: 24) {
                            // 底部留白（信息卡片已移除，简介在按钮下方）
                            Color.clear
                                .frame(height: bottomSafeInset + 32)
                        }
                        .padding(.top, 20)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: ScrollOffsetPreferenceKey.self, value: proxy.frame(in: .named("scroll")).minY)
                        }
                    )
                }
                .scrollClipDisabled()
                .safeAreaPadding(.bottom, bottomSafeInset)
                .background(Color.clear)
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    scrollOffset = value
                }
                .overlay(alignment: .top) {
                    fixedHeroChrome(
                        viewportWidth: viewW,
                        topBarTopInset: topBarTopInset
                    )
                }
                
                if showInfoBubble {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                showInfoBubble = false
                            }
                        }
                }
                
                floatingBackButton
                    .padding(.top, topBarTopInset + 18)
                    .padding(.leading, 28)
                    .zIndex(100)
                
                floatingInfoOverlay(
                    viewportWidth: viewW,
                    topBarTopInset: topBarTopInset
                )
                .zIndex(100)
            }
        }
        .ignoresSafeArea()
        .navigationBarBackButtonHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.15).delay(0.05)) {
                isVisible = true
            }
            loadBackdrop()
            setupKeyboardMonitor()

            // 加载规则数据
            Task {
                await viewModel.loadData()
            }
        }
        .onDisappear {
            isVisible = false
            removeKeyboardMonitor()
        }
    }
    
    // MARK: - 键盘快捷键

    private func setupKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard NSApp.isActive, let window = event.window, window.isKeyWindow else { return event }
            guard self.isVisible else { return event }
            switch event.keyCode {
            case 49: // 空格键：显示/隐藏信息区域
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85, blendDuration: 0)) {
                    self.isHeroContentHidden.toggle()
                }
                return nil
            case 53: // ESC：返回
                self.isPresented = false
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }

    // MARK: - 加载横屏背景
    private func loadBackdrop() {
        isLoadingBackdrop = true
        Task {
            let url = await TMDBService.shared.fetchBackdropURL(
                for: anime.displayTitle,
                originalName: anime.originalName ?? anime.title
            )
            
            await MainActor.run {
                self.backdropURL = url
                self.isLoadingBackdrop = false
                
                // 图片加载状态会在 AsyncImage 的 onAppear 中设置
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.isImageLoaded = true
                }
            }
        }
    }
    
    // MARK: - 背景视图
    /// 横图（TMDB backdrop）铺满整屏，竖图（Bangumi cover）完整缩放并做左右模糊延伸
    private func layeredBackgroundView(width: CGFloat, height viewH: CGFloat) -> some View {
        // 判断是否有横屏背景图
        let hasBackdrop = backdropURL != nil
        
        return ZStack {
            if hasBackdrop {
                // 横图模式：铺满整屏
                landscapeBackground(width: width, height: viewH)
            } else {
                // 竖图模式：完整显示+两侧模糊延伸
                portraitBackground(width: width, height: viewH)
            }
            
            // 渐变遮罩
            LinearGradient(
                colors: [
                    Color.black.opacity(0.22),
                    Color.black.opacity(0.10),
                    Color.black.opacity(0.34)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.12),
                            Color.black.opacity(0.34)
                        ],
                        center: .center,
                        startRadius: 120,
                        endRadius: max(width, viewH)
                    )
                )
        }
        .frame(width: width, height: viewH)
        .clipped()
        .ignoresSafeArea()
    }
    
    /// 横图背景：铺满整屏
    private func landscapeBackground(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color(hex: "0A0A0C").frame(width: width, height: height)
            KFImage(backdropURL.flatMap { URL(string: $0) })
                .cacheMemoryOnly(false)
                .fade(duration: 0.3)
                .onSuccess { _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isImageLoaded = true
                    }
                }
                .onFailure { _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isImageLoaded = true
                    }
                }
                .placeholder { _ in Color.clear }
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
        }
    }
    
    /// 竖图背景：完整缩放+两侧模糊延伸（参考 WallpaperDetailSheet）
    private func portraitBackground(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black

            // 左右延伸层：基于居中图做横向拉伸和模糊
            if let coverURL = coverImageURL {
                KFImage(coverURL)
                    .cacheMemoryOnly(false)
                    .fade(duration: 0.3)
                    .placeholder { _ in Color.clear }
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: height)
                    .scaleEffect(x: 2.25, y: 1.14, anchor: .center)
                    .blur(radius: 84)
                    .saturation(1.12)
                    .brightness(-0.08)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0.0),
                                .init(color: .white, location: 0.22),
                                .init(color: .clear, location: 0.38),
                                .init(color: .clear, location: 0.62),
                                .init(color: .white, location: 0.78),
                                .init(color: .white, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }

            // 主图：完整缩放展示
            if let coverURL = coverImageURL {
                KFImage(coverURL)
                    .cacheMemoryOnly(false)
                    .fade(duration: 0.3)
                    .onSuccess { _ in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isImageLoaded = true
                        }
                    }
                    .onFailure { _ in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isImageLoaded = true
                        }
                    }
                    .placeholder { _ in Color.clear }
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: height)
                    .shadow(color: .black.opacity(0.32), radius: 42, y: 18)
            }

            // 左右暗角遮罩
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.42), location: 0.0),
                    .init(color: Color.clear, location: 0.20),
                    .init(color: Color.clear, location: 0.80),
                    .init(color: Color.black.opacity(0.42), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height, alignment: .center)
    }
    
    // MARK: - Hero Chrome
    private func fixedHeroChrome(viewportWidth: CGFloat, topBarTopInset: CGFloat) -> some View {
        // 计算挤压进度：0 表示未滚动，1 表示达到最大挤压
        let squeezeProgress = min(max(-scrollOffset / squeezeThreshold, 0), 1)
        let scaleY = 1 - (squeezeProgress * 0.15) // 最大挤压到 85%
        let offsetY = -squeezeProgress * maxSqueezeOffset * 0.3
        let opacity = 1 - (squeezeProgress * 0.3)
        
        return VStack(spacing: 0) {
            Spacer()
                .frame(height: max(topBarTopInset + 44, 68))
            
            VStack(spacing: 18) {
                if !isHeroContentHidden {
                    detailCategoryBadge

                    Text(anime.displayTitle)
                        .font(.system(size: 52, weight: .bold, design: .serif))
                        .tracking(-1.3)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: 980)
                        .detailGlassTitleChrome()

                    HStack(spacing: 0) {
                        metadataCapsules
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    buttonRowWithDividers

                    // 简介已移至信息气泡弹窗中显示
                }
            }
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .frame(width: viewportWidth)
        .scaleEffect(x: 1, y: scaleY, anchor: .center)
        .offset(y: offsetY)
        .opacity(opacity)
        .animation(.easeOut(duration: 0.15), value: scrollOffset)
    }
    
    private func detailScrollTopInset(viewportHeight: CGFloat, heroHidden: Bool) -> CGFloat {
        if heroHidden {
            return max(min(viewportHeight * 0.42, 380), 300)
        }
        return max(min(viewportHeight * 0.58, 520), 420)
    }
    
    // MARK: - 返回按钮
    private var floatingBackButton: some View {
        Button {
            isPresented = false
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .detailGlassCircleChrome()
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 信息浮层
    private func floatingInfoOverlay(viewportWidth: CGFloat, topBarTopInset: CGFloat) -> some View {
        let bubbleWidth = min(360, max(260, viewportWidth - 84))
        
        return VStack(alignment: .trailing, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        showInfoBubble.toggle()
                    }
                } label: {
                    Image(systemName: showInfoBubble ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                        .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)
                
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        isHeroContentHidden.toggle()
                    }
                } label: {
                    Image(systemName: isHeroContentHidden ? "eye.slash" : "eye")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                        .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)
            }
            
            if showInfoBubble {
                detailInfoBubble(width: bubbleWidth)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .padding(.top, topBarTopInset + 18)
        .padding(.trailing, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .zIndex(2)
    }
    
    // MARK: - 中央信息区
    private var detailCategoryBadge: some View {
        Text("Anime · \(anime.typeDisplayName)")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .tracking(2)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .detailGlassCapsuleChrome(level: .prominent)
    }
    
    // MARK: - 元数据胶囊
    private var metadataItems: [(label: String, value: String)] {
        var items: [(String, String)] = []

        if let rating = anime.rating, let score = Double(rating) {
            items.append((t("anime.rating"), String(format: "%.1f", score)))
        }

        if let rank = anime.rank {
            items.append((t("anime.rank"), "#\(rank)"))
        }

        if let airDate = anime.airDate {
            items.append((t("anime.airDate"), String(airDate.prefix(4))))
        }

        items.append((t("anime.type"), anime.typeDisplayName))

        return items
    }
    
    private var metadataCapsules: some View {
        ForEach(Array(metadataItems.enumerated()), id: \.offset) { index, item in
            detailMetaCapsule(
                label: item.label,
                value: item.value,
                isLast: index == metadataItems.count - 1
            )
        }
    }
    
    private func detailMetaCapsule(label: String, value: String, isLast: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .detailGlassCapsuleChrome(level: .prominent)
        .padding(.trailing, isLast ? 0 : 8)
    }
    
    // MARK: - 按钮行
    private var buttonRowWithDividers: some View {
        HStack(spacing: 16) {
            HStack(spacing: 16) {
                dividerLine
                    .frame(width: 70)
                
                Button {
                    viewModel.toggleFavorite()
                } label: {
                    Image(systemName: viewModel.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(viewModel.isFavorite ? Color(hex: "FF5A7D") : .white)
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                        .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)
            }
            
            Button {
                AnimeWindowManager.shared.openPlayerWindow(for: anime, using: viewModel)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: viewModel.lastPlayedEpisode != nil ? "play.circle.fill" : "play.fill")
                        .font(.system(size: 13, weight: .medium))
                    Text(viewModel.lastPlayedEpisode != nil ? t("anime.continueWatch") : t("anime.watch"))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .frame(height: 46)
                .contentShape(Capsule())
                .detailPrimaryGlassButtonChrome()
            }
            .buttonStyle(.plain)
            
            HStack(spacing: 16) {
                Button {
                    // TODO: 分享
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                        .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)
                
                dividerLine
                    .frame(width: 70)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .glassContainer(spacing: 16)
    }
    
    private var dividerLine: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.0),
                        Color.white.opacity(0.25),
                        Color.white.opacity(0.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
    
    // MARK: - 简介区域
    private func summarySection(summary: String) -> some View {
        Text(summary)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(.white.opacity(0.9))
            .lineSpacing(8)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
    }

    // MARK: - 信息区域
    private func infoSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(t("anime.info"))
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 10) {
                if let airDate = anime.airDate {
                    infoRow(label: t("anime.airDate"), value: airDate)
                }

                if let weekday = anime.airWeekdayDisplay {
                    infoRow(label: t("anime.airWeekday"), value: weekday)
                }

                infoRow(label: t("anime.type"), value: anime.typeDisplayName)

                if let rating = anime.rating, let score = Double(rating) {
                    infoRow(label: t("anime.rating"), value: String(format: "%.1f / 10", score))
                }

                if let rank = anime.rank {
                    infoRow(label: t("anime.rank"), value: "#\(rank)")
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
    
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .tracking(1)
    }
    
    // MARK: - 信息气泡
    private func detailInfoBubble(width: CGFloat) -> some View {
        DetailGlassPopoverCard(width: width, maxHeight: 460, variant: .dark) {
            VStack(alignment: .leading, spacing: 8) {
                Text(anime.displayTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(2)
                
                Text("Anime · TV Series")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .tracking(0.6)
            }
            
            if let tags = anime.tags, !tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(tags.prefix(8)) { tag in
                        Text(tag.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .detailGlassCapsuleChrome(level: .prominent)
                    }
                }
                .glassContainer(spacing: 10)
            }
            
            dividerLine.opacity(0.7)
            
            // 简要信息 - 优先使用 Bangumi 详情中的简介
            let summary = viewModel.bangumiDetail?.summary ?? anime.summary
            if let summary = summary, !summary.isEmpty {
                // 自适应高度：内容少时不滚动，内容多时才滚动
                AdaptiveScrollView(content: summary)
            }
        }
    }
}

// MARK: - 加载动画
private struct LoadingOverlayView: View {
    @State private var isAnimating = false
    @State private var rotationAngle: Double = 0
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0C")
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                // 加载指示器
                ZStack {
                    // 外圈
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.1),
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 48, height: 48)
                    
                    // 旋转的弧线
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.8),
                                    Color.white.opacity(0.4),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 48, height: 48)
                        .rotationEffect(.degrees(rotationAngle))
                }
                .onAppear {
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        rotationAngle = 360
                    }
                }
                
                // 加载文本
                Text(t("loading"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 自适应高度滚动视图
/// 内容少时不滚动，内容多时才滚动
private struct AdaptiveScrollView: View {
    let content: String
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(content)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.8))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }
}
