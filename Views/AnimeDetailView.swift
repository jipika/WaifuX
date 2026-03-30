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
                        heroSection(width: geometry.size.width)

                        // 剧集列表
                        if let detail = detail, !detail.episodes.isEmpty {
                            episodesSection
                        }

                        // 相关推荐占位
                        relatedSection

                        Spacer(minLength: 40)
                    }
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
                .blur(radius: 60)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.3),
                            Color.black.opacity(0.7),
                            Color.black.opacity(0.95)
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

    private func heroSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
                .frame(height: 100)

            HStack(alignment: .bottom, spacing: 24) {
                // 海报
                posterImage

                // 信息
                infoPanel
            }
            .padding(.horizontal, 28)
        }
        .frame(width: width)
        .padding(.bottom, 40)
    }

    // MARK: - 海报

    private var posterImage: some View {
        OptimizedAsyncImage(
            url: anime.coverURL.flatMap { URL(string: $0) },
            priority: .medium
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .overlay(
                    Image(systemName: "tv")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.3))
                )
        }
        .frame(width: 180, height: 270)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
        .liquidGlassSurface(.prominent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 信息面板

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            Text(anime.title)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            // 元信息
            HStack(spacing: 12) {
                if let rating = detail?.rating {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.yellow)
                        Text(rating)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                }

                if let status = detail?.status {
                    Text(status)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.1))
                        )
                }

                Text(anime.sourceName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

            // 描述
            if let desc = detail?.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            } else if isLoading {
                Text("正在加载详情...")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // 操作按钮
            actionButtons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 操作按钮

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // 播放按钮
            Button {
                if let firstEpisode = detail?.episodes.first {
                    selectedEpisode = firstEpisode
                    showPlayer = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("立即播放")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
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
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
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

            // 分享按钮
            Button {
                // TODO: 分享功能
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
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
        .padding(.top, 8)
    }

    // MARK: - 剧集列表

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("剧集")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(detail?.episodes ?? []) { episode in
                        EpisodeCard(
                            episode: episode,
                            isPlaying: selectedEpisode?.id == episode.id
                        ) {
                            selectedEpisode = episode
                            showPlayer = true
                        }
                    }
                }
                .padding(.horizontal, 28)
            }
        }
        .padding(.vertical, 24)
    }

    // MARK: - 相关推荐

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("相关推荐")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)

            // 可以在这里添加相关动漫
            // 目前显示提示
            Text("更多精彩内容即将推出")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 28)
        }
        .padding(.vertical, 24)
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
                                .fill(Color.black.opacity(0.3))
                                .background(.ultraThinMaterial)
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                // 标题（滚动时显示）
                if scrollOffset < -200 {
                    Text(anime.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .transition(.opacity)
                }

                Spacer()

                // 占位保持居中
                Color.clear
                    .frame(width: 40, height: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Spacer()
        }
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

// MARK: - 剧集卡片

struct EpisodeCard: View {
    let episode: AnimeDetail.AnimeEpisodeItem
    let isPlaying: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                // 缩略图或占位
                ZStack {
                    if let thumb = episode.thumbnailURL {
                        OptimizedAsyncImage(
                            url: URL(string: thumb),
                            priority: .medium
                        ) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle()
                                .fill(Color.white.opacity(0.1))
                                .overlay(
                                    Image(systemName: "play.circle")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.white.opacity(0.5))
                                )
                        }
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .overlay(
                                Image(systemName: "play.circle")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.white.opacity(0.5))
                            )
                    }

                    // 播放中指示器
                    if isPlaying {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 40, height: 40)
                            .overlay(
                                Image(systemName: "pause.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.black)
                            )
                    }
                }
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // 剧集信息
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.name ?? "第 \(episode.episodeNumber) 集")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text("第 \(episode.episodeNumber) 集")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(width: 160, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
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
