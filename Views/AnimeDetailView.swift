import SwiftUI
import AVKit

// MARK: - AnimeDetailView - Netflix 风格详情页

struct AnimeDetailView: View {
    let anime: AnimeSearchResult
    @ObservedObject var viewModel: AnimeViewModel
    @Binding var isPresented: Bool

    @State private var detail: AnimeDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedEpisode: AnimeDetail.AnimeEpisodeItem?
    @State private var showPlayer = false
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景层
                backgroundLayer

                // 内容层
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Hero 区域
                        heroSection(width: geometry.size.width, height: geometry.size.height)

                        // 内容区域
                        contentSection

                        Spacer(minLength: 60)
                    }
                    .offsetReader()
                }
                .coordinateSpace(name: "scroll")
                .onPreferenceChange(ViewOffsetKey.self) { offset in
                    scrollOffset = offset
                }

                // 顶部导航栏
                topNavigationBar
            }
        }
        .task {
            await loadDetail()
        }
        .sheet(isPresented: $showPlayer) {
            if let episode = selectedEpisode {
                AnimePlayerView(episode: episode, animeTitle: anime.title)
            }
        }
    }

    // MARK: - 背景层

    private var backgroundLayer: some View {
        ZStack {
            // 全屏背景图
            if let coverURL = anime.coverURL {
                OptimizedAsyncImage(
                    url: URL(string: coverURL),
                    priority: .low
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.black.opacity(0.9)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 40)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.2),
                            Color.black.opacity(0.5),
                            Color.black.opacity(0.85),
                            Color.black.opacity(0.98)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            } else {
                Color.black.opacity(0.9)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Hero Section

    private func heroSection(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            // 背景大图
            if let coverURL = anime.coverURL {
                OptimizedAsyncImage(
                    url: URL(string: coverURL),
                    priority: .high
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                }
                .frame(width: width, height: height * 0.65)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.1),
                            Color.black.opacity(0.3),
                            Color.black.opacity(0.7),
                            Color.black.opacity(0.95)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            // 内容叠加层
            VStack(alignment: .leading, spacing: 20) {
                Spacer()

                // 源标签
                HStack(spacing: 8) {
                    Text(anime.sourceName)
                        .font(.system(size: 12, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.red)
                        )

                    if let rating = detail?.rating, !rating.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow)
                            Text(rating)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.15))
                        )
                    }

                    if let status = detail?.status, !status.isEmpty {
                        Text(status)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(0.15))
                            )
                    }
                }

                // 标题
                Text(anime.title)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: Color.black.opacity(0.5), radius: 4, x: 0, y: 2)

                // 操作按钮
                HStack(spacing: 16) {
                    // 播放按钮
                    Button {
                        if let firstEpisode = detail?.episodes.first {
                            selectedEpisode = firstEpisode
                            showPlayer = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 18, weight: .semibold))
                            Text(detail?.episodes.isEmpty ?? true ? "暂无剧集" : "立即播放")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(detail?.episodes.isEmpty ?? true)
                    .opacity(detail?.episodes.isEmpty ?? true ? 0.5 : 1)

                    // 收藏按钮
                    Button {
                        // TODO: 收藏功能
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                            Text("收藏")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.2))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    // 分享按钮
                    Button {
                        // TODO: 分享功能
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.15))
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                // 描述
                if let desc = detail?.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 600, alignment: .leading)
                } else if isLoading {
                    Text("正在加载详情...")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
            .frame(width: width, alignment: .leading)
        }
        .frame(height: height * 0.75)
    }

    // MARK: - 内容区域

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 32) {
            // 剧集列表
            if let detail = detail, !detail.episodes.isEmpty {
                episodesSection
            }

            // 相关推荐
            relatedSection
        }
        .padding(.top, 20)
    }

    // MARK: - 剧集列表

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("剧集")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                // 剧集数量
                Text("\(detail?.episodes.count ?? 0) 集")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 40)

            // 剧集网格
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                ForEach(detail?.episodes ?? []) { episode in
                    EpisodeRow(
                        episode: episode,
                        isPlaying: selectedEpisode?.id == episode.id
                    ) {
                        selectedEpisode = episode
                        showPlayer = true
                    }
                }
            }
            .padding(.horizontal, 40)
        }
    }

    // MARK: - 相关推荐

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("相关推荐")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 40)

            // 可以在这里添加相关动漫
            HStack(spacing: 16) {
                ForEach(0..<4) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 200, height: 112)
                            .overlay(
                                Image(systemName: "tv")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.white.opacity(0.3))
                            )

                        Text("推荐动漫 \(index + 1)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 40)
            .opacity(0.5)
        }
    }

    // MARK: - 顶部导航栏

    private var topNavigationBar: some View {
        VStack {
            HStack {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        isPresented = false
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(scrollOffset > 100 ? 0.5 : 0.3))
                                .background(.ultraThinMaterial)
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                // 标题（滚动时显示）
                if scrollOffset < -300 {
                    Text(anime.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .transition(.opacity)
                }

                Spacer()

                // 占位保持居中
                Color.clear
                    .frame(width: 40, height: 40)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Spacer()
        }
        .background(
            scrollOffset < -300 ?
            Color.black.opacity(min(0.9, abs(scrollOffset + 300) / 200))
            : Color.clear
        )
        .animation(.easeInOut(duration: 0.2), value: scrollOffset)
    }

    // MARK: - 加载详情

    private func loadDetail() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await viewModel.fetchDetail(for: anime)
            await MainActor.run {
                self.detail = result
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 滚动偏移检测

struct ViewOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    func offsetReader() -> some View {
        self.background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: ViewOffsetKey.self,
                        value: proxy.frame(in: .named("scroll")).minY
                    )
            }
        )
    }
}

// MARK: - 剧集行

struct EpisodeRow: View {
    let episode: AnimeDetail.AnimeEpisodeItem
    let isPlaying: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 缩略图
                ZStack {
                    if let thumb = episode.thumbnailURL {
                        OptimizedAsyncImage(
                            url: URL(string: thumb),
                            priority: .low
                        ) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle()
                                .fill(Color.white.opacity(0.1))
                        }
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                    }

                    // 播放图标
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.6))
                        )
                        .opacity(isHovered || isPlaying ? 1 : 0)
                }
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // 剧集信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.name ?? "第 \(episode.episodeNumber) 集")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text("第 \(episode.episodeNumber) 集")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                // 播放中指示器
                if isPlaying {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("播放中")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.red.opacity(0.15))
                    )
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered || isPlaying ? Color.white.opacity(0.1) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isPlaying ? Color.red.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 播放器视图

struct AnimePlayerView: View {
    let episode: AnimeDetail.AnimeEpisodeItem
    let animeTitle: String
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("正在加载视频...")
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        player.play()
                    }
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("无法播放视频")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("关闭") {
                        dismiss()
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                }
            }

            // 关闭按钮
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.5))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
                Spacer()
            }
        }
        .task {
            await loadVideo()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func loadVideo() async {
        isLoading = true
        defer { isLoading = false }

        // 这里需要解析真实视频地址
        // 目前直接使用 episode URL 作为演示
        if let url = URL(string: episode.url) {
            await MainActor.run {
                self.player = AVPlayer(url: url)
            }
        } else {
            errorMessage = "无效的视频地址"
        }
    }
}
