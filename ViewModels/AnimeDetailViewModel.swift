import Foundation
import SwiftUI
import AVKit
import Combine

// MARK: - 源搜索状态 (简化版，与 Kazumi 对齐)

enum SourceQueryStatus: Equatable {
    case idle         // 未搜索
    case loading      // 搜索中
    case needsSelection([SourceSearchItem]) // 需要用户选择
    case success      // 已获取剧集列表
    case noResult     // 无结果
    case error(String) // 错误
    case captcha      // 需要验证码
}

// MARK: - 从第三方源搜索到的结果项

struct SourceSearchItem: Identifiable, Equatable {
    let id = UUID()
    let name: String       // 第三方源上的标题
    let src: String        // 详情页路径 (如 "/video/12345.html")

    // 计算完整 URL
    func fullURL(baseURL: String) -> String {
        if src.hasPrefix("http") {
            return src
        }
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if src.hasPrefix("/") {
            return base + src
        }
        return base + "/" + src
    }
}

// MARK: - 源搜索结果

struct SourceSearchResult: Identifiable {
    let id: String  // 使用规则 ID 作为唯一标识
    let rule: AnimeRule
    var status: SourceQueryStatus = .idle
    var selectedItem: SourceSearchItem?  // 用户选择的结果
    var detail: AnimeDetail?             // 解析后的剧集列表
}

// MARK: - 动漫详情页 ViewModel

@MainActor
class AnimeDetailViewModel: ObservableObject {
    // MARK: - 输入数据
    let anime: AnimeSearchResult

    // MARK: - 可用规则
    @Published var availableRules: [AnimeRule] = []

    // MARK: - 多源搜索结果
    @Published var sourceResults: [SourceSearchResult] = []

    // MARK: - 当前选中的源
    @Published var selectedSourceIndex: Int = 0

    // MARK: - 播放器状态
    @Published var player: AVPlayer?
    @Published var isPlaying: Bool = false
    @Published var currentEpisode: AnimeDetail.AnimeEpisodeItem?
    @Published var videoSources: [VideoSource] = []
    @Published var isLoadingVideo: Bool = false
    @Published var videoError: String?

    // MARK: - 播放进度跟踪
    @Published var currentProgress: Double = 0
    @Published var currentTime: Double = 0
    @Published var totalDuration: Double = 0
    private var progressTracker: PlaybackProgressTracker?
    private var progressObserver: AnyCancellable?

    // MARK: - 弹幕功能（参考 Kazumi）
    @Published var danmakuList: [Danmaku] = []
    @Published var danmakuSettings: DanmakuSettings = .default
    @Published var isLoadingDanmaku: Bool = false
    @Published var showDanmakuSettings: Bool = false
    private var danmakuTask: Task<Void, Never>?

    // MARK: - Bangumi 详情（用于展示信息）
    @Published var bangumiDetail: BangumiDetail?
    @Published var isLoadingBangumi: Bool = false

    init(anime: AnimeSearchResult) {
        self.anime = anime
        loadDanmakuSettings()
    }

    // MARK: - 加载数据

    func loadData() async {
        // 加载规则
        await loadRules()

        // 加载 Bangumi 详情（用于展示）
        await loadBangumiDetail()

        // 查询所有源的播放列表
        await queryAllSourcesForBangumiDetail()
    }

    // MARK: - 加载规则
    /// 加载规则：先尝试本地，如果失败则从远程加载
    private func loadRules() async {
        // 首先尝试从本地加载已安装的规则
        var rules = await AnimeRuleStore.shared.loadAllRules()
        print("[AnimeDetailViewModel] 本地规则数量: \(rules.count)")

        // 如果本地没有规则，先尝试自动安装默认规则
        if rules.isEmpty {
            print("[AnimeDetailViewModel] 本地无规则，尝试自动安装默认规则...")
            await AnimeRuleStore.shared.ensureDefaultRulesCopied()

            // 再次尝试加载
            rules = await AnimeRuleStore.shared.loadAllRules()
            print("[AnimeDetailViewModel] 自动安装后规则数量: \(rules.count)")
        }

        // 如果仍然没有规则，尝试从远程直接加载
        if rules.isEmpty {
            print("[AnimeDetailViewModel] 尝试从远程加载所有规则...")
            do {
                let remoteRules = try await AnimeRuleStore.shared.loadRulesFromRemote()
                print("[AnimeDetailViewModel] 从远程加载了 \(remoteRules.count) 个规则")

                // 保存到本地
                for rule in remoteRules {
                    do {
                        try await AnimeRuleStore.shared.saveRule(rule)
                    } catch {
                        print("[AnimeDetailViewModel] 保存规则失败: \(rule.name) - \(error)")
                    }
                }

                // 重新加载
                rules = await AnimeRuleStore.shared.loadAllRules()
            } catch {
                print("[AnimeDetailViewModel] 从远程加载规则失败: \(error)")
            }
        }

        // 过滤废弃规则
        let activeRules = rules.filter { !$0.deprecated }
        self.availableRules = activeRules

        print("[AnimeDetailViewModel] 可用规则: \(activeRules.count) 个")
        for rule in activeRules {
            print("[AnimeDetailViewModel]   ✓ \(rule.name) (\(rule.id))")
        }

        // 初始化源搜索结果
        await MainActor.run {
            self.sourceResults = activeRules.map { rule in
                SourceSearchResult(id: rule.id, rule: rule, status: .idle)
            }

            // 确保选中第一个源
            if !self.sourceResults.isEmpty {
                self.selectedSourceIndex = 0
            }
        }

        // 如果没有安装任何规则，提示用户
        if activeRules.isEmpty {
            print("[AnimeDetailViewModel] ⚠️ 未安装任何规则，需要从规则市场安装")
        }
    }

    // MARK: - 加载 Bangumi 详情

    private func loadBangumiDetail() async {
        isLoadingBangumi = true
        defer { isLoadingBangumi = false }

        // 尝试从 anime.id 解析 Bangumi ID
        if let bangumiId = Int(anime.id) {
            do {
                let detail = try await BangumiService.shared.getDetail(id: bangumiId)
                self.bangumiDetail = detail
            } catch {
                print("[AnimeDetailViewModel] Failed to load Bangumi detail: \(error)")
            }
        }
    }

    // MARK: - Kazumi 正确链路：搜索 -> 选择 -> 解析剧集

    // MARK: - Kazumi 风格：搜索源

    /// 参考 Kazumi Plugin.queryBangumi: 用标题搜索，返回搜索结果列表
    func searchInSource(_ rule: AnimeRule, query: String? = nil) async {
        let searchQuery = query ?? anime.title
        print("[AnimeDetailViewModel] ========== 搜索源 '\(rule.name)' ==========")
        print("[AnimeDetailViewModel] 关键词: \(searchQuery)")

        guard let index = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }

        // 更新状态为加载中
        await MainActor.run {
            sourceResults[index].status = .loading
            sourceResults[index].selectedItem = nil
            sourceResults[index].detail = nil
        }

        do {
            // 使用 AnimeParser 搜索
            let searchResults = try await AnimeParser.shared.searchWithRule(
                query: searchQuery,
                rule: rule
            )

            print("[AnimeDetailViewModel] 源 '\(rule.name)' 搜索到 \(searchResults.count) 个结果")

            // 转换为 SourceSearchItem
            let items = searchResults.map { result -> SourceSearchItem in
                SourceSearchItem(
                    name: result.title,
                    src: result.detailURL
                )
            }

            await MainActor.run {
                if items.isEmpty {
                    sourceResults[index].status = .noResult
                } else if items.count == 1 {
                    // 只有一个结果，自动选择但不自动查询剧集
                    sourceResults[index].selectedItem = items[0]
                    // 可选：自动查询剧集
                    Task {
                        await self.queryEpisodes(for: items[0], in: rule)
                    }
                } else {
                    // 多个结果，需要用户选择
                    sourceResults[index].status = .needsSelection(items)
                }
            }

        } catch let error as AnimeParserError {
            await MainActor.run {
                switch error {
                case .captchaRequired:
                    sourceResults[index].status = .captcha
                case .noResult:
                    sourceResults[index].status = .noResult
                case .networkError(let underlying):
                    sourceResults[index].status = .error(underlying.localizedDescription)
                default:
                    sourceResults[index].status = .error(error.localizedDescription)
                }
            }
        } catch {
            let errorString = error.localizedDescription.lowercased()
            await MainActor.run {
                if errorString.contains("captcha") ||
                   errorString.contains("验证码") ||
                   errorString.contains("验证") {
                    sourceResults[index].status = .captcha
                } else {
                    sourceResults[index].status = .error(error.localizedDescription)
                }
            }
        }
    }

    /// 第二步：用选中的结果获取剧集列表
    /// 参考 Kazumi Plugin.querychapterRoads: 用第三方源详情页 URL 解析剧集
    func queryEpisodes(for item: SourceSearchItem, in rule: AnimeRule) async {
        let detailURL = item.fullURL(baseURL: rule.baseURL)

        print("[AnimeDetailViewModel] ========== 解析剧集 ==========")
        print("[AnimeDetailViewModel] 选中项: '\(item.name)'")
        print("[AnimeDetailViewModel] 详情页 URL: \(detailURL)")

        guard let index = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }

        // 更新状态为加载中
        await MainActor.run {
            sourceResults[index].status = .loading
        }

        do {
            // 使用 querychapterRoads 解析第三方源详情页
            let details = try await AnimeParser.shared.querychapterRoads(
                detailURL: detailURL,
                rule: rule
            )

            if details.isEmpty {
                print("[AnimeDetailViewModel] ⚠️ 未找到播放列表")
                await MainActor.run {
                    sourceResults[index].status = .noResult
                }
                return
            }

            let firstDetail = details.first!
            print("[AnimeDetailViewModel] ✓ 找到 \(details.count) 个播放列表")
            print("[AnimeDetailViewModel] ✓ 第一个播放列表 '\(firstDetail.title)' 有 \(firstDetail.episodes.count) 集")

            // 更新 sourceResults 中的数据
            await MainActor.run {
                self.sourceResults[index].selectedItem = item
                self.sourceResults[index].detail = firstDetail
                self.sourceResults[index].status = .success
            }

        } catch let error as AnimeParserError {
            await MainActor.run {
                switch error {
                case .captchaRequired:
                    sourceResults[index].status = .captcha
                case .noResult:
                    sourceResults[index].status = .noResult
                case .networkError(let underlying):
                    sourceResults[index].status = .error(underlying.localizedDescription)
                default:
                    sourceResults[index].status = .error(error.localizedDescription)
                }
            }
        } catch {
            await MainActor.run {
                sourceResults[index].status = .error(error.localizedDescription)
            }
        }
    }

    /// 用户选择搜索结果后调用 (Kazumi 风格)
    func selectSearchItem(_ item: SourceSearchItem, for rule: AnimeRule) async {
        await queryEpisodes(for: item, in: rule)
    }

    // MARK: - 查询所有源 (Kazumi 风格)

    /// 参考 Kazumi QueryManager.queryAllSource: 并发搜索所有源
    func queryAllSourcesForBangumiDetail() async {
        guard !sourceResults.isEmpty else { return }

        print("[AnimeDetailViewModel] ========== 开始查询所有源 ==========")

        // 并发查询所有源
        await withTaskGroup(of: Void.self) { group in
            for sourceResult in sourceResults {
                group.addTask {
                    await self.searchInSource(sourceResult.rule)
                }
            }
        }

        print("[AnimeDetailViewModel] ========== 所有源查询完成 ==========")
    }

    /// 使用别名重新搜索指定源 (Kazumi 别名检索)
    func retrySearchWithAlias(_ alias: String, for rule: AnimeRule) async {
        await searchInSource(rule, query: alias)
    }

    /// 手动重试搜索指定源
    func retrySearch(for rule: AnimeRule) async {
        await searchInSource(rule)
    }

    // MARK: - 播放剧集

    func playEpisode(_ episode: AnimeDetail.AnimeEpisodeItem, from sourceIndex: Int) async {
        guard sourceIndex < sourceResults.count else { return }

        let rule = sourceResults[sourceIndex].rule
        currentEpisode = episode
        isLoadingVideo = true
        videoError = nil

        defer { isLoadingVideo = false }

        // 使用视频提取器（参考 Kazumi 的 WebView 拦截方式）
        let result = await AnimeVideoExtractor.shared.extractVideoSources(
            from: episode.url,
            rule: rule
        )

        switch result {
        case .success(let sources):
            self.videoSources = sources

            // 尝试播放第一个可用的视频源
            if let firstSource = sources.first,
               let url = URL(string: firstSource.url) {
                self.setupPlayer(with: url, episode: episode, sourceIndex: sourceIndex)
            } else {
                videoError = "未找到可播放的视频"
            }

        case .error(let error):
            videoError = error

        case .captcha:
            videoError = "需要验证码验证"

        case .timeout:
            videoError = "视频解析超时"
        }
    }

    /// 设置播放器并恢复进度
    private func setupPlayer(with url: URL, episode: AnimeDetail.AnimeEpisodeItem, sourceIndex: Int) {
        let rule = sourceResults[sourceIndex].rule

        // 创建播放器
        let playerItem = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: playerItem)
        self.isPlaying = true

        // 开始跟踪播放进度
        PlaybackProgressCache.shared.startTracking(
            animeId: anime.id,
            animeTitle: anime.title,
            episode: episode,
            sourceId: rule.id,
            sourceName: rule.name,
            coverURL: anime.coverURL
        )

        // 附加进度跟踪器
        progressTracker = PlaybackProgressTracker()
        progressTracker?.attach(to: self.player!)

        // 监听进度更新
        progressObserver = progressTracker?.$currentTime
            .sink { [weak self] time in
                self?.currentTime = time
            }

        progressTracker?.$duration
            .sink { [weak self] duration in
                self?.totalDuration = duration
            }
            .store(in: &cancellables)

        progressTracker?.$progress
            .sink { [weak self] progress in
                self?.currentProgress = progress
            }
            .store(in: &cancellables)

        // 恢复上次播放进度
        if let savedProgress = PlaybackProgressCache.shared.getProgress(
            sourceId: rule.id,
            episodeId: episode.id
        ), savedProgress.currentTime > 10 { // 至少10秒才恢复
            let seekTime = CMTime(seconds: savedProgress.currentTime, preferredTimescale: 600)
            self.player?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            print("[AnimeDetailViewModel] 恢复播放进度: \(savedProgress.formattedProgress)")
        }

        // 开始播放
        self.player?.play()
        print("[AnimeDetailViewModel] 开始播放: \(url.absoluteString)")

        // 加载弹幕
        loadDanmaku(for: episode)
    }

    private var cancellables = Set<AnyCancellable>()

    /// 停止播放并保存进度
    func stopPlayback() {
        progressObserver?.cancel()
        progressTracker?.detach()
        progressTracker = nil
        PlaybackProgressCache.shared.stopTracking()
        player?.pause()
        player = nil
        isPlaying = false
        currentEpisode = nil

        // 取消弹幕加载
        danmakuTask?.cancel()
        danmakuTask = nil
        danmakuList = []
    }

    // MARK: - 弹幕功能

    /// 加载弹幕（参考 Kazumi 的弹幕获取逻辑）
    func loadDanmaku(for episode: AnimeDetail.AnimeEpisodeItem) {
        // 取消之前的任务
        danmakuTask?.cancel()
        danmakuList = []

        guard danmakuSettings.isEnabled else { return }

        danmakuTask = Task {
            await fetchDanmakuInternal(episode: episode)
        }
    }

    private func fetchDanmakuInternal(episode: AnimeDetail.AnimeEpisodeItem) async {
        isLoadingDanmaku = true
        defer { isLoadingDanmaku = false }

        do {
            // 1. 首先尝试通过 Bangumi ID 获取
            if let bangumiId = Int(anime.id) {
                let danmaku = try await DanmakuService.shared.fetchDanmakuByBangumiId(
                    bangumiId: bangumiId,
                    episodeNumber: episode.episodeNumber
                )

                if !danmaku.isEmpty {
                    await MainActor.run {
                        if danmakuSettings.enableDeduplication {
                            self.danmakuList = danmaku.deduplicated(timeWindow: 5.0)
                        } else {
                            self.danmakuList = danmaku
                        }
                    }
                    print("[AnimeDetailViewModel] 加载弹幕成功: \(self.danmakuList.count) 条")
                    return
                }
            }

            // 2. 通过标题搜索获取
            let danmaku = try await DanmakuService.shared.fetchDanmakuSmart(
                animeTitle: anime.title,
                episodeNumber: episode.episodeNumber
            )

            await MainActor.run {
                if danmakuSettings.enableDeduplication {
                    self.danmakuList = danmaku.deduplicated(timeWindow: 5.0)
                } else {
                    self.danmakuList = danmaku
                }
            }
            print("[AnimeDetailViewModel] 加载弹幕成功: \(self.danmakuList.count) 条")

        } catch {
            print("[AnimeDetailViewModel] 加载弹幕失败: \(error)")
            // 弹幕加载失败不影响播放
        }
    }

    /// 切换弹幕开关
    func toggleDanmaku() {
        danmakuSettings.isEnabled.toggle()

        if danmakuSettings.isEnabled, let episode = currentEpisode {
            // 开启时加载弹幕
            loadDanmaku(for: episode)
        } else {
            // 关闭时清空弹幕
            danmakuList = []
        }
    }

    /// 更新弹幕设置
    func updateDanmakuSettings(_ settings: DanmakuSettings) {
        danmakuSettings = settings

        // 保存到 UserDefaults
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: "danmakuSettings")
        }
    }

    /// 加载弹幕设置
    func loadDanmakuSettings() {
        if let data = UserDefaults.standard.data(forKey: "danmakuSettings"),
           let settings = try? JSONDecoder().decode(DanmakuSettings.self, from: data) {
            danmakuSettings = settings
        }
    }

    // MARK: - 获取当前选中的源结果

    var currentSourceResult: SourceSearchResult? {
        guard selectedSourceIndex < sourceResults.count else { return nil }
        return sourceResults[selectedSourceIndex]
    }

    // MARK: - 获取当前源的剧集列表

    var currentEpisodes: [AnimeDetail.AnimeEpisodeItem] {
        currentSourceResult?.detail?.episodes ?? []
    }

    // MARK: - 获取 Bangumi 别名列表（用于别名检索）

    var bangumiAliases: [String] {
        // 从 Bangumi 详情中获取别名
        var aliases: [String] = []

        // 主标题
        if !anime.title.isEmpty {
            aliases.append(anime.title)
        }

        // Bangumi 详情中的其他标题
        if let detail = bangumiDetail {
            // 中文名
            // 英文名等其他名称
        }

        // 去重
        return Array(Set(aliases)).filter { !$0.isEmpty }
    }

    // MARK: - 搜索关键词清理

    /// 清理搜索关键词，移除标点符号和特殊字符以提高匹配率
    private func cleanSearchQuery(_ title: String) -> String {
        // 需要移除的标点符号和特殊字符
        let charactersToRemove: [Character] = [
            "!", "！", "?", "？", ".", "。", ",", "，",
            ";", "；", ":", "：", "·", "•", "●", "○",
            "【", "】", "[", "]", "《", "》", "<", ">",
            "（", "）", "(", ")", "「", "」", "『", "』",
            "~", "～", "@", "#", "$", "%", "^", "&", "*",
            "+", "=", "|", "\\", "/", "\"", "'"
        ]

        var cleaned = title

        // 移除标点符号
        for char in charactersToRemove {
            cleaned.removeAll { $0 == char }
        }

        // 移除常见后缀（如 "第X季", "Season X" 等）
        let suffixesToRemove = [
            "第一季", "第二季", "第三季", "第四季", "第五季",
            "第1季", "第2季", "第3季", "第4季", "第5季",
            "Season 1", "Season 2", "Season 3", "Season 4", "Season 5",
            "SEASON 1", "SEASON 2", "SEASON 3", "SEASON 4", "SEASON 5",
            "Part 1", "Part 2", "Part 3"
        ]

        for suffix in suffixesToRemove {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
                break // 只移除第一个匹配的后缀
            }
        }

        // 修剪首尾空格
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        // 如果清理后为空，返回原始标题（避免完全空查询）
        return cleaned.isEmpty ? title : cleaned
    }
}

