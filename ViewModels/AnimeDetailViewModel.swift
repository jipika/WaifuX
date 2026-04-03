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

// MARK: - 应用内验证码（WebView 会话）

struct CaptchaVerificationSession: Identifiable {
    let id = UUID()
    let rule: AnimeRule
    let startURL: URL
    /// 若设置，同步 Cookie 后重新尝试解析该集（播放阶段验证码）
    var replayEpisode: AnimeDetail.AnimeEpisodeItem?
    var replaySourceIndex: Int?
    /// 若设置，验证完成后重新获取该剧集的剧集列表
    var selectedSearchItem: SourceSearchItem?
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
    @Published var showPlayerWindow: Bool = false

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
    
    // MARK: - 播放器增强设置
    @Published var enhancementSettings: PlayerEnhancementSettings = .default
    
    struct PlayerEnhancementSettings: Codable {
        var superResolution: Bool
        var aiDenoise: Bool
        var colorEnhancement: Bool
        var autoPlayNext: Bool
        var skipOpeningEnding: Bool
        
        static let `default` = PlayerEnhancementSettings(
            superResolution: false,
            aiDenoise: false,
            colorEnhancement: false,
            autoPlayNext: true,
            skipOpeningEnding: false
        )
    }

    // MARK: - Bangumi 详情（用于展示信息）
    @Published var bangumiDetail: BangumiDetail?
    @Published var isLoadingBangumi: Bool = false
    
    // MARK: - 收藏状态
    @Published var isFavorite: Bool = false

    // MARK: - 验证码验证（统一使用 WebView 方案）
    @Published var captchaVerificationSession: CaptchaVerificationSession?
    
    // MARK: - 别名搜索弹窗
    @Published var showAliasSearchSheet: Bool = false
    @Published var aliasSearchRule: AnimeRule?
    @Published var aliasSearchText: String = ""

    init(anime: AnimeSearchResult) {
        self.anime = anime
        loadDanmakuSettings()
        loadEnhancementSettings()
        self.aliasSearchText = anime.title
        loadFavoriteStatus()
    }

    // MARK: - 加载数据

    /// 加载基本信息（规则和 Bangumi 详情），不触发搜索
    func loadData() async {
        // 加载规则
        await loadRules()

        // 加载 Bangumi 详情（用于展示）
        await loadBangumiDetail()
        
        // 注：不再自动查询源，改为用户手动触发
        // 避免一进入页面就触发验证码
    }
    
    /// 完整加载（包括搜索源）- 用于播放器窗口
    func loadFullData() async {
        await loadData()
        // 查询所有源的播放列表（仅在需要时调用）
        // await searchAllSources()
    }

    // MARK: - 加载规则
    /// 加载规则：先尝试本地，如果失败则从远程加载
    private func loadRules() async {
        // 首先尝试从本地加载已安装的规则
        var rules = await AnimeRuleStore.shared.loadAllRules()
        print("[AnimeDetailViewModel] 本地规则数量: \(rules.count)")

        // 本地无缓存时全量从 Kazumi 同步覆盖（与 App 启动后台任务一致）
        if rules.isEmpty {
            print("[AnimeDetailViewModel] 本地无规则，从 Kazumi 全量同步…")
            await AnimeRuleStore.shared.ensureDefaultRulesCopied()
            rules = await AnimeRuleStore.shared.loadAllRules()
            print("[AnimeDetailViewModel] 同步后规则数量: \(rules.count)")
        }

        // loadAllRules / 远程加载已排除 deprecated
        self.availableRules = rules

        print("[AnimeDetailViewModel] 可用规则: \(rules.count) 个")
        for rule in rules {
            print("[AnimeDetailViewModel]   ✓ \(rule.name) (\(rule.id))")
        }

        // 初始化源搜索结果
        await MainActor.run {
            self.sourceResults = rules.map { rule in
                SourceSearchResult(id: rule.id, rule: rule, status: .idle)
            }

            // 确保选中第一个源
            if !self.sourceResults.isEmpty {
                self.selectedSourceIndex = 0
            }
        }

        // 如果没有安装任何规则，提示用户
        if rules.isEmpty {
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
                    // 仅标记为需要验证码，不弹窗（在播放器中切换源时才弹窗）
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
                    // 仅标记为需要验证码，不弹窗
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

        // 更新状态为加载中，同时保存 selectedItem（即使出错也需要保存，用于验证码验证后重试）
        await MainActor.run {
            sourceResults[index].status = .loading
            sourceResults[index].selectedItem = item
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
                    // 仅标记为需要验证码，不弹窗（在播放器中切换源时才弹窗）
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
    
    /// 触发 WebView 验证码验证（直接使用 WebView 完成验证）
    /// 用于搜索阶段的验证码验证
    func triggerCaptchaVerification(for rule: AnimeRule) {
        guard let sourceIndex = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }
        
        // 构建验证 URL（使用搜索页作为入口）
        let searchQuery = anime.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? anime.title
        var verifyURL = rule.searchURL
            .replacingOccurrences(of: "{keyword}", with: searchQuery)
            .replacingOccurrences(of: "{page}", with: "1")
            .replacingOccurrences(of: "@keyword", with: searchQuery)
        
        // 如果搜索 URL 无效，回退到 baseURL
        if verifyURL.isEmpty || !verifyURL.hasPrefix("http") {
            verifyURL = rule.baseURL
        }
        
        guard let url = URL(string: verifyURL) else { return }
        
        // 获取当前已选择的 item（如果有），用于验证完成后重新获取剧集
        let currentSelectedItem = sourceResults[sourceIndex].selectedItem
        
        // 创建 WebView 验证会话
        captchaVerificationSession = CaptchaVerificationSession(
            rule: rule,
            startURL: url,
            replayEpisode: nil,
            replaySourceIndex: nil,
            selectedSearchItem: currentSelectedItem  // 保存已选择的项
        )
    }

    // MARK: - 查询所有源 (Kazumi 风格)

    /// 参考 Kazumi QueryManager.queryAllSource: 并发搜索所有源
    // MARK: - 搜索所有源
    
    /// 搜索所有可用源（用户手动触发）
    func searchAllSources() async {
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
    
    /// 显示别名搜索弹窗
    func showAliasSearch(for rule: AnimeRule) {
        aliasSearchRule = rule
        aliasSearchText = anime.title
        showAliasSearchSheet = true
    }
    
    /// 切换收藏状态（集成 AnimeFavoriteStore）
    func toggleFavorite() {
        let newStatus = AnimeFavoriteStore.shared.toggleFavorite(
            anime: anime,
            bangumiId: bangumiDetail?.id
        )
        isFavorite = newStatus
        
        // 如果收藏了，默认设置为"想看"状态
        if newStatus {
            AnimeFavoriteStore.shared.updateWatchStatus(animeId: anime.id, status: .planToWatch)
        }
    }
    
    /// 更新观看状态
    func updateWatchStatus(_ status: FavoriteAnime.WatchStatus) {
        guard isFavorite else { return }
        AnimeFavoriteStore.shared.updateWatchStatus(animeId: anime.id, status: status)
    }
    
    /// 加载收藏状态
    func loadFavoriteStatus() {
        isFavorite = AnimeFavoriteStore.shared.isFavorite(animeId: anime.id)
    }
    
    /// 获取当前动漫的观看进度
    func getEpisodeProgress(_ episodeId: String) -> EpisodeProgress? {
        return AnimeProgressStore.shared.getProgress(animeId: anime.id, episodeId: episodeId)
    }
    
    /// 获取上次播放的剧集
    var lastPlayedEpisode: AnimeDetail.AnimeEpisodeItem? {
        guard let summary = AnimeProgressStore.shared.getSummary(animeId: anime.id),
              let lastEpisodeId = summary.lastEpisodeId else { return nil }
        return currentEpisodes.first { $0.id == lastEpisodeId }
    }

    // MARK: - 验证码（应用内 WebView，对齐 Kazumi 用 WebView 提高兼容性）

    func presentCaptchaVerificationForSearch(rule: AnimeRule) {
        // 使用搜索 URL 进行验证码验证（而非首页），因为通常是在搜索时触发验证码
        let searchQuery = anime.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? anime.title
        var verifyURL = rule.searchURL
            .replacingOccurrences(of: "{keyword}", with: searchQuery)
            .replacingOccurrences(of: "{page}", with: "1")
            .replacingOccurrences(of: "@keyword", with: searchQuery)

        // 如果搜索 URL 无效，回退到 baseURL
        if verifyURL.isEmpty || !verifyURL.hasPrefix("http") {
            verifyURL = rule.baseURL
        }

        guard let url = URL(string: verifyURL), url.scheme == "http" || url.scheme == "https" else { return }

        print("[AnimeDetailViewModel] 打开验证码验证页面: \(url)")
        captchaVerificationSession = CaptchaVerificationSession(
            rule: rule,
            startURL: url,
            replayEpisode: nil,
            replaySourceIndex: nil
        )
    }

    func presentCaptchaVerificationForPlayback(rule: AnimeRule, episode: AnimeDetail.AnimeEpisodeItem, sourceIndex: Int) {
        guard let url = URL(string: episode.url) else { return }
        captchaVerificationSession = CaptchaVerificationSession(
            rule: rule,
            startURL: url,
            replayEpisode: episode,
            replaySourceIndex: sourceIndex
        )
    }

    func cancelCaptchaVerification() {
        captchaVerificationSession = nil
    }

    func completeCaptchaVerificationAndContinue() async {
        guard let session = captchaVerificationSession else { return }
        let replayEp = session.replayEpisode
        let replayIdx = session.replaySourceIndex
        let rule = session.rule
        let selectedItem = session.selectedSearchItem

        await WebViewCookieSync.syncWKWebsiteDataStoreToSharedHTTPCookieStorage()
        captchaVerificationSession = nil

        if let ep = replayEp, let idx = replayIdx {
            // 播放阶段的验证码验证完成，重新尝试播放
            await playEpisode(ep, from: idx)
        } else if let item = selectedItem {
            // 剧集列表阶段的验证码验证完成，重新获取剧集列表
            print("[AnimeDetailViewModel] 验证码验证完成，重新获取剧集列表...")
            await queryEpisodes(for: item, in: rule)
        } else {
            // 搜索阶段的验证码验证完成，重新搜索
            await searchInSource(rule)
        }
    }

    // MARK: - 播放剧集

    func playEpisode(_ episode: AnimeDetail.AnimeEpisodeItem, from sourceIndex: Int) async {
        guard sourceIndex < sourceResults.count else { return }
        
        // 防止重复调用
        guard !isLoadingVideo else {
            print("[AnimeDetailViewModel] 视频正在加载中，忽略重复点击")
            return
        }

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
            // 触发验证码验证弹窗，验证完成后会自动重试播放
            presentCaptchaVerificationForPlayback(rule: rule, episode: episode, sourceIndex: sourceIndex)

        case .timeout:
            videoError = "视频解析超时，请重试或切换其他视频源"
        }
    }

    /// 设置播放器并恢复进度
    private func setupPlayer(with url: URL, episode: AnimeDetail.AnimeEpisodeItem, sourceIndex: Int) {
        let rule = sourceResults[sourceIndex].rule
        
        // 创建播放器项目，设置必要的 headers（如 Referer、User-Agent）
        let playerItem: AVPlayerItem
        
        // 检查是否需要设置 headers
        var headers: [String: String] = [:]
        if let userAgent = rule.userAgent, !userAgent.isEmpty {
            headers["User-Agent"] = userAgent
        }
        // 设置 Referer（某些视频源需要）
        if let referer = rule.headers?["Referer"], !referer.isEmpty {
            headers["Referer"] = referer
        } else {
            headers["Referer"] = rule.baseURL
        }
        
        if !headers.isEmpty {
            // 使用 AVURLAsset 设置 headers
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            playerItem = AVPlayerItem(asset: asset)
        } else {
            playerItem = AVPlayerItem(url: url)
        }
        
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
                
                // 同时更新 AnimeProgressStore（每5%或每30秒保存一次）
                if let self = self, let currentEpisode = self.currentEpisode {
                    let shouldSave = Int(progress * 20) > Int(self.currentProgress * 20) || progress >= 0.95
                    if shouldSave {
                        AnimeProgressStore.shared.updateProgress(
                            animeId: self.anime.id,
                            animeTitle: self.anime.title,
                            coverURL: self.anime.coverURL,
                            episodeId: currentEpisode.id,
                            episodeNumber: "\(currentEpisode.episodeNumber)",
                            currentTime: self.currentTime,
                            totalDuration: self.totalDuration
                        )
                    }
                }
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
        // 保存最终进度到 AnimeProgressStore
        if let currentEpisode = currentEpisode {
            AnimeProgressStore.shared.updateProgress(
                animeId: anime.id,
                animeTitle: anime.title,
                coverURL: anime.coverURL,
                episodeId: currentEpisode.id,
                episodeNumber: "\(currentEpisode.episodeNumber)",
                currentTime: currentTime,
                totalDuration: totalDuration
            )
        }
        
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
    
    // MARK: - 播放器增强设置
    
    func updateEnhancementSettings(_ settings: PlayerEnhancementSettings) {
        enhancementSettings = settings
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: "playerEnhancementSettings")
        }
    }
    
    func loadEnhancementSettings() {
        if let data = UserDefaults.standard.data(forKey: "playerEnhancementSettings"),
           let settings = try? JSONDecoder().decode(PlayerEnhancementSettings.self, from: data) {
            enhancementSettings = settings
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
    
    /// 是否有可播放的剧集
    var hasAvailableEpisodes: Bool {
        sourceResults.contains { $0.detail?.episodes.isEmpty == false }
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
        if bangumiDetail != nil {
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

