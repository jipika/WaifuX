import SwiftUI
import AVKit

// MARK: - AnimeDetailView - 左右分栏布局

struct AnimeDetailView: View {
    let anime: AnimeSearchResult
    @Binding var isPresented: Bool

    @StateObject private var viewModel: AnimeDetailViewModel

    init(anime: AnimeSearchResult, isPresented: Binding<Bool>) {
        self.anime = anime
        self._isPresented = isPresented
        self._viewModel = StateObject(wrappedValue: AnimeDetailViewModel(anime: anime))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 顶部导航栏
                    navigationBar

                    // 主内容区
                    HStack(spacing: 0) {
                        // 左侧：播放器
                        playerSection(width: geometry.size.width * 0.6)

                        // 右侧：动漫信息
                        infoSection(width: geometry.size.width * 0.4)
                    }
                    .frame(height: geometry.size.height * 0.6)

                    // 底部：源选择和集数
                    sourceAndEpisodesSection(height: geometry.size.height * 0.4)
                }
            }
        }
        .task {
            await viewModel.loadData()
        }
        .onDisappear {
            viewModel.stopPlayback()
        }
    }

    // MARK: - 导航栏

    private var navigationBar: some View {
        HStack {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isPresented = false
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("返回")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(anime.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            // 占位保持居中
            Color.clear
                .frame(width: 80, height: 36)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.8))
    }

    // MARK: - 播放器区域

    private func playerSection(width: CGFloat) -> some View {
        ZStack {
            Color(hex: "0D0D0D")

            if let player = viewModel.player {
                ZStack {
                    VideoPlayer(player: player)
                        .onAppear {
                            player.play()
                        }

                    // 弹幕层（叠加在视频上）
                    DanmakuView(
                        danmakuList: viewModel.danmakuList,
                        isEnabled: $viewModel.danmakuSettings.isEnabled,
                        settings: viewModel.danmakuSettings,
                        currentTime: $viewModel.currentTime
                    )

                    // 控制按钮 (右上角)
                    VStack {
                        HStack {
                            Spacer()
                            HStack(spacing: 8) {
                                // 弹幕开关
                                DanmakuToggleButton(isEnabled: $viewModel.danmakuSettings.isEnabled) {
                                    viewModel.toggleDanmaku()
                                }

                                // 弹幕设置按钮
                                DanmakuSettingsButton {
                                    viewModel.showDanmakuSettings = true
                                }

                                // 超分开关
                                enhancementToggle
                            }
                            .padding(.top, 8)
                            .padding(.trailing, 8)
                        }
                        Spacer()
                    }
                }
                .sheet(isPresented: $viewModel.showDanmakuSettings) {
                    DanmakuSettingsSheet(settings: $viewModel.danmakuSettings) { newSettings in
                        viewModel.updateDanmakuSettings(newSettings)
                    }
                }
            } else if viewModel.isLoadingVideo {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.white)
                    Text("正在解析视频...")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else if let error = viewModel.videoError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("无法播放视频")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.3))

                    Text(viewModel.currentEpisodes.isEmpty
                         ? "选择下方剧集开始播放"
                         : "点击剧集开始播放")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: width)
    }

    // MARK: - 超分开关

    private var enhancementToggle: some View {
        @State var isEnabled = AnimeVideoEnhancer.shared.isEnabled

        return Button {
            AnimeVideoEnhancer.shared.isEnabled.toggle()
            isEnabled = AnimeVideoEnhancer.shared.isEnabled
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isEnabled ? "wand.and.stars.inverse" : "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))

                Text(isEnabled ? "超分: 开" : "超分: 关")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isEnabled ? .white : .white.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isEnabled ? Color.purple.opacity(0.6) : Color.black.opacity(0.4))
            )
            .overlay(
                Capsule()
                    .stroke(isEnabled ? Color.purple.opacity(0.8) : Color.white.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("超分辨率增强 (Metal Shader)")
    }

    // MARK: - 信息区域

    private func infoSection(width: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // 封面和基本信息
                HStack(alignment: .top, spacing: 12) {
                    // 小图封面
                    OptimizedAsyncImage(
                        url: URL(string: anime.coverURL ?? ""),
                        priority: .high
                    ) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .overlay(
                                Image(systemName: "tv")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.white.opacity(0.3))
                            )
                    }
                    .frame(width: 100, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // 基本信息
                    VStack(alignment: .leading, spacing: 8) {
                        Text(anime.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        if let detail = viewModel.bangumiDetail {
                            HStack(spacing: 8) {
                                if let score = detail.rating?.score {
                                    HStack(spacing: 4) {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.yellow)
                                        Text(String(format: "%.1f", score))
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .foregroundStyle(.white)
                                }

                                if let date = detail.airDate {
                                    Text(date)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                            }

                            if let episodes = detail.totalEpisodes, episodes > 0 {
                                Text("\(episodes) 集")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                }

                // 简介
                if let summary = viewModel.bangumiDetail?.summary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("简介")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))

                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(6)
                    }
                } else if viewModel.isLoadingBangumi {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("简介")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))

                        Text("正在加载...")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                // 继续播放（如果上次有播放记录）
                ContinuePlayButton(viewModel: viewModel)

                // 当前播放信息
                if let episode = viewModel.currentEpisode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前播放")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))

                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)

                            Text(episode.name ?? "第 \(episode.episodeNumber) 集")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                Spacer(minLength: 20)
            }
            .padding()
        }
        .frame(width: width)
        .background(Color.black)
    }

    // MARK: - 源和集数区域

    private func sourceAndEpisodesSection(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            // 源 Tab 栏
            sourceTabBar

            Divider()
                .background(Color.white.opacity(0.1))

            // 集数列表
            episodesGrid
        }
        .frame(height: height)
        .background(Color(hex: "1A1A1A"))
    }

    // MARK: - 源 Tab 栏
    /// 显示所有源（包括搜索中、无结果、失败的），与 Kazumi 逻辑对齐
    private var sourceTabBar: some View {
        Group {
            if viewModel.sourceResults.isEmpty {
                // 没有安装任何规则
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 20))
                            .foregroundStyle(.orange.opacity(0.7))
                        Text("未安装任何视频源规则")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("请前往设置 > 规则市场安装规则")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(viewModel.sourceResults.enumerated()), id: \.element.id) { index, source in
                            SourceTabButton(
                                source: source,
                                isSelected: viewModel.selectedSourceIndex == index
                            ) {
                                viewModel.selectedSourceIndex = index
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - 集数网格

    private var episodesGrid: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if viewModel.currentSourceResult == nil {
                EmptyStateView(message: "暂无源数据")
            } else if viewModel.currentEpisodes.isEmpty {
                if let source = viewModel.currentSourceResult {
                    switch source.status {
                    case .idle:
                        EmptyStateView(message: "等待搜索")
                    case .loading:
                        LoadingStateView()
                    case .error(let error):
                        SourceErrorStateView(error: error) {
                            Task {
                                if let source = viewModel.currentSourceResult {
                                    await viewModel.retrySearch(for: source.rule)
                                }
                            }
                        }
                    case .noResult:
                        // 与 Kazumi 一致：显示无结果，提供别名检索
                        if let source = viewModel.currentSourceResult {
                            NoResultStateView {
                                Task {
                                    await viewModel.retrySearch(for: source.rule)
                                }
                            } aliasSearch: {
                                showAliasSearch(for: source.rule)
                            }
                        }
                    case .captcha:
                        // 与 Kazumi 一致：显示验证码验证
                        CaptchaStateView {
                            Task {
                                if let source = viewModel.currentSourceResult {
                                    await viewModel.retrySearch(for: source.rule)
                                }
                            }
                        }
                    case .needsSelection(let items):
                        // 需要用户选择搜索结果
                        searchResultsList(for: source, items: items)
                    case .success:
                        if source.detail == nil {
                            EmptyStateView(message: "正在加载剧集...")
                        }
                        // 否则 source.detail != nil，currentEpisodes 会返回剧集列表
                        // 在下面的 else 块中显示
                    }
                }
            } else {
                // 显示集数
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(viewModel.currentEpisodes) { episode in
                        let ruleId = viewModel.currentSourceResult?.rule.id ?? ""
                        let progress = PlaybackProgressCache.shared.getProgress(
                            sourceId: ruleId,
                            episodeId: episode.id
                        )

                        EpisodeButton(
                            episode: episode,
                            isPlaying: viewModel.currentEpisode?.id == episode.id,
                            progress: progress?.progress ?? 0,
                            isCompleted: progress?.isCompleted ?? false
                        ) {
                            Task {
                                await viewModel.playEpisode(episode, from: viewModel.selectedSourceIndex)
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - 搜索结果列表

    private func searchResultsList(for source: SourceSearchResult, items: [SourceSearchItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("'\(viewModel.anime.title)' 的搜索结果")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("(\(source.rule.name))")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Text("请选择正确的动漫以加载剧集")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        SourceSearchItemButton(
                            item: item,
                            isHighlighted: isTitleMatching(item.name, viewModel.anime.title)
                        ) {
                            Task {
                                await viewModel.selectSearchItem(item, for: source.rule)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }

    /// 检查标题是否匹配（参考 Kazumi 的匹配逻辑）
    private func isTitleMatching(_ resultTitle: String, _ originalTitle: String) -> Bool {
        let normalizedResult = resultTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOriginal = originalTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 完全匹配（最高优先级）
        if normalizedResult == normalizedOriginal {
            return true
        }

        // 原始标题包含结果标题（精确匹配）
        if normalizedOriginal.hasPrefix(normalizedResult) || normalizedOriginal.hasSuffix(normalizedResult) {
            return true
        }

        // 移除空格和标点后比较
        let cleanResult = normalizedResult.filter { $0.isLetter || $0.isNumber }
        let cleanOriginal = normalizedOriginal.filter { $0.isLetter || $0.isNumber }

        // 清理后的字符串完全匹配
        if cleanResult == cleanOriginal {
            return true
        }

        // 清理后包含关系
        if cleanOriginal.hasPrefix(cleanResult) || cleanOriginal.hasSuffix(cleanResult) {
            return true
        }

        // 提取关键词匹配（如"超时空辉夜姬"中的"辉夜姬"）
        let keywords = extractKeywords(from: normalizedOriginal)
        return keywords.contains { keyword in
            normalizedResult.contains(keyword) || cleanResult.contains(keyword)
        }
    }

    /// 提取关键词（中文词汇分割）
    private func extractKeywords(from title: String) -> [String] {
        // 移除常见后缀和前缀
        let suffixes = ["第一季", "第二季", "第三季", "第四季", "第五季", "第1季", "第2季", "第3季", "第4季", "第5季", "season 1", "season 2", "season 3", "season 4", "season 5"]
        var cleanTitle = title.lowercased()
        for suffix in suffixes where cleanTitle.hasSuffix(suffix) {
            cleanTitle = String(cleanTitle.dropLast(suffix.count))
        }

        // 按2-3个字分割关键词（中文常用词长度）
        var keywords: [String] = []
        var currentKeyword = ""
        for char in cleanTitle {
            if char.isLetter || char.isNumber {
                currentKeyword.append(char)
                // 当关键词长度达到2-4个字时，保存
                if currentKeyword.count >= 2 && currentKeyword.count <= 4 {
                    keywords.append(currentKeyword)
                    currentKeyword = ""
                }
            } else {
                // 遇到非字母数字字符，保存当前关键词
                if !currentKeyword.isEmpty {
                    keywords.append(currentKeyword)
                }
                currentKeyword = ""
            }
        }
        if !currentKeyword.isEmpty {
            keywords.append(currentKeyword)
        }

        return keywords.filter { !$0.isEmpty }
    }

    /// 显示别名检索对话框 (Kazumi 风格)
    private func showAliasSearch(for rule: AnimeRule) {
        // 获取 Bangumi 别名列表
        let aliases = viewModel.bangumiAliases

        // 显示别名选择对话框
        let alert = NSAlert()
        alert.messageText = "别名检索"
        alert.informativeText = "选择别名重新搜索，或手动输入:"
        alert.alertStyle = .informational

        // 添加别名按钮
        for alias in aliases.prefix(5) {
            alert.addButton(withTitle: alias)
        }

        alert.addButton(withTitle: "手动输入...")
        alert.addButton(withTitle: "取消")

        // 显示对话框
        if let window = NSApplication.shared.keyWindow {
            alert.beginSheetModal(for: window) { [aliasCount = aliases.count] response in
                // NSAlertFirstButtonReturn = 1000, 每增加一个按钮 rawValue 增加 1
                let buttonIndex = Int(response.rawValue) - 1000

                if buttonIndex < aliasCount {
                    // 选择了某个别名
                    let selectedAlias = aliases[buttonIndex]
                    Task {
                        await viewModel.retrySearchWithAlias(selectedAlias, for: rule)
                    }
                } else if buttonIndex == aliasCount {
                    // 手动输入
                    self.showCustomSearchInput(for: rule)
                }
                // 取消(最后一个按钮)则不执行任何操作
            }
        }
    }

    /// 显示手动输入搜索对话框
    private func showCustomSearchInput(for rule: AnimeRule) {
        let alert = NSAlert()
        alert.messageText = "手动检索"
        alert.informativeText = "输入搜索关键词:"
        alert.alertStyle = .informational

        alert.addButton(withTitle: "搜索")
        alert.addButton(withTitle: "取消")

        let inputTextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        inputTextField.stringValue = viewModel.anime.title
        alert.accessoryView = inputTextField

        if let window = NSApplication.shared.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    let keyword = inputTextField.stringValue.trimmingCharacters(in: .whitespaces)
                    if !keyword.isEmpty {
                        Task {
                            await viewModel.retrySearchWithAlias(keyword, for: rule)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 源 Tab 按钮

private struct SourceTabButton: View {
    let source: SourceSearchResult
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(source.rule.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))

                // 状态指示器
                SourceStatusIndicator(status: source.status)
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.white.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.white.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 源状态指示器

private struct SourceStatusIndicator: View {
    let status: SourceQueryStatus

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 6, height: 6)
    }

    private var statusColor: Color {
        switch status {
        case .idle:
            return .gray
        case .loading:
            return .yellow
        case .success:
            return .green
        case .noResult:
            return .orange
        case .captcha:
            return .blue
        case .error:
            return .red
        case .needsSelection:
            return .purple
        }
    }
}

// MARK: - 集数按钮

private struct EpisodeButton: View {
    let episode: AnimeDetail.AnimeEpisodeItem
    let isPlaying: Bool
    let progress: Double
    let isCompleted: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // 背景
                RoundedRectangle(cornerRadius: 8)
                    .fill(isPlaying ? Color.red : Color.white.opacity(isHovered ? 0.12 : 0.05))

                // 播放进度条（底部）
                if progress > 0 && !isPlaying {
                    VStack {
                        Spacer()
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isCompleted ? Color.green : Color.red)
                                .frame(width: geo.size.width * CGFloat(progress), height: 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 3)
                    }
                }

                // 内容
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        if isCompleted {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }

                        Text("\(episode.episodeNumber)")
                            .font(.system(size: 14, weight: .semibold))
                    }

                    if let name = episode.name {
                        Text(name)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(isPlaying ? .white : .white.opacity(0.8))
            }
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isPlaying ? Color.red.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 搜索结果按钮

private struct SearchResultButton: View {
    let result: AnimeSearchResult
    let isHighlighted: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                OptimizedAsyncImage(
                    url: URL(string: result.coverURL ?? ""),
                    priority: .low
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                }
                .frame(width: 60, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.system(size: 14, weight: isHighlighted ? .bold : .semibold))
                        .foregroundStyle(isHighlighted ? .green : .white)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text("来源: \(result.sourceName)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))

                        if isHighlighted {
                            Text("可能匹配")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(12)
            .background(Color.white.opacity(isHovered ? 0.08 : 0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 源搜索结果按钮 (用于选择第三方源搜索结果)

private struct SourceSearchItemButton: View {
    let item: SourceSearchItem
    let isHighlighted: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 由于没有封面图，使用占位符
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.3))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 14, weight: isHighlighted ? .bold : .semibold))
                        .foregroundStyle(isHighlighted ? .green : .white)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text("路径: \(item.src.prefix(30))...")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))

                        if isHighlighted {
                            Text("可能匹配")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(12)
            .background(Color.white.opacity(isHovered ? 0.08 : 0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 状态视图

private struct EmptyStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv.slash")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.3))

            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}

private struct LoadingStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)

            Text("正在搜索...")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}

private struct SourceErrorStateView: View {
    let error: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.red.opacity(0.5))

            Text("搜索失败")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))

            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)

            Button("重试", action: retry)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1))
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - 无结果状态（与 Kazumi 对齐）

private struct NoResultStateView: View {
    let retry: () -> Void
    let aliasSearch: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 32))
                .foregroundStyle(.orange.opacity(0.5))

            Text("该源无结果")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))

            Text("使用别名或切换到其他视频来源")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("别名检索", action: aliasSearch)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())

                Button("重试", action: retry)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.3))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - 继续播放按钮

private struct ContinuePlayButton: View {
    @ObservedObject var viewModel: AnimeDetailViewModel

    var body: some View {
        if let lastProgress = PlaybackProgressCache.shared.getLastPlayedEpisode(animeId: viewModel.anime.id) {
            Button {
                Task {
                    // 找到对应的源和剧集并播放
                    if let sourceIndex = viewModel.sourceResults.firstIndex(where: { $0.rule.id == lastProgress.sourceId }) {
                        // 确保源已加载详情
                        if viewModel.sourceResults[sourceIndex].detail == nil,
                           let selectedItem = viewModel.sourceResults[sourceIndex].selectedItem {
                            await viewModel.selectSearchItem(selectedItem, for: viewModel.sourceResults[sourceIndex].rule)
                        }

                        // 找到剧集并播放
                        if let episode = viewModel.sourceResults[sourceIndex].detail?.episodes.first(where: { $0.id == lastProgress.episodeId }) {
                            await viewModel.playEpisode(episode, from: sourceIndex)
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("继续播放")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)

                        Text("第 \(lastProgress.episodeNumber) 集 · \(lastProgress.formattedProgress)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    // 进度条
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.2))
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.red)
                                .frame(width: geo.size.width * CGFloat(lastProgress.progress), height: 4)
                        }
                    }
                    .frame(width: 60, height: 4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.red.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
    }
}

// MARK: - 验证码状态（与 Kazumi 对齐）

private struct CaptchaStateView: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 32))
                .foregroundStyle(.blue.opacity(0.5))

            Text("需要验证码验证")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))

            Text("该源需要验证码才能继续")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))

            Button("进行验证", action: retry)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.3))
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - 弹幕控制按钮

private struct DanmakuSettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gear")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 弹幕设置面板

private struct DanmakuSettingsSheet: View {
    @Binding var settings: DanmakuSettings
    let onSave: (DanmakuSettings) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("基本设置") {
                    Toggle("启用弹幕", isOn: $settings.isEnabled)

                    VStack(alignment: .leading) {
                        Text("弹幕速度: \(String(format: "%.1f", settings.speed))x")
                        Slider(value: $settings.speed, in: 0.5...2.0, step: 0.1)
                    }

                    VStack(alignment: .leading) {
                        Text("弹幕透明度: \(Int(settings.opacity * 100))%")
                        Slider(value: $settings.opacity, in: 0.1...1.0, step: 0.1)
                    }

                    VStack(alignment: .leading) {
                        Text("字体大小: \(Int(settings.fontSize))px")
                        Slider(value: $settings.fontSize, in: 12...24, step: 1)
                    }
                }

                Section("显示选项") {
                    Toggle("滚动弹幕", isOn: $settings.enableScroll)
                    Toggle("顶部弹幕", isOn: $settings.enableTop)
                    Toggle("底部弹幕", isOn: $settings.enableBottom)
                    Toggle("弹幕去重", isOn: $settings.enableDeduplication)
                }
            }
            .navigationTitle("弹幕设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSave(settings)
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
    }
}
