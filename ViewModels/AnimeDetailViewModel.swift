import Foundation
import SwiftUI
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
    var searchItems: [SourceSearchItem]? // 搜索结果列表（用于返回重新选择）
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
    @Published var currentPlayURL: URL?
    @Published var currentStartTime: TimeInterval = 0
    @Published var isPlaying: Bool = false
    @Published var currentEpisode: AnimeDetail.AnimeEpisodeItem?
    @Published var videoSources: [VideoSource] = []
    @Published var isLoadingVideo: Bool = false
    @Published var isBuffering: Bool = false
    @Published var videoError: String?
    @Published var showPlayerWindow: Bool = false

    // MARK: - 播放进度跟踪
    @Published var currentProgress: Double = 0
    @Published var currentTime: Double = 0
    @Published var totalDuration: Double = 0

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
    @Published var bangumiEpisodes: [BangumiEpisodeItem] = []
    @Published var isLoadingBangumi: Bool = false
    
    // MARK: - 规则加载状态
    @Published var isLoadingRules: Bool = false

    // MARK: - 初始排序冻结机制
    /// 首次全部源完成搜索（含集数解析）后，排序即固定，不再因用户操作而变化
    @Published var isInitialLoadComplete: Bool = false
    /// 初始排序完成时锁定的源 ID 顺序（后续不再改变）
    @Published var frozenSourceOrder: [String] = []
    
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
        isLoadingRules = true
        defer { isLoadingRules = false }
        
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
                async let detailTask = BangumiService.shared.getDetail(id: bangumiId)
                async let episodesTask = BangumiService.shared.getEpisodes(subjectId: bangumiId)
                
                let detail = try await detailTask
                let episodes = try await episodesTask
                
                self.bangumiDetail = detail
                self.bangumiEpisodes = episodes.episodes
            } catch {
                print("[AnimeDetailViewModel] Failed to load Bangumi detail: \(error)")
            }
        }
    }
    
    /// 获取指定集数的 Bangumi 章节标题
    func getEpisodeTitle(for episodeNumber: Int) -> String? {
        // 在 Bangumi 章节中查找匹配的集数
        if let episode = bangumiEpisodes.first(where: { $0.ep == episodeNumber }) {
            return episode.displayName
        }
        return nil
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
            var updatedResult = sourceResults[index]
            updatedResult.status = .loading
            updatedResult.selectedItem = nil
            updatedResult.detail = nil
            sourceResults[index] = updatedResult
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
                var updatedResult = sourceResults[index]
                if items.isEmpty {
                    updatedResult.status = .noResult
                    sourceResults[index] = updatedResult
                } else if items.count == 1 {
                    // 只有一个结果，自动选择但不自动查询剧集
                    updatedResult.selectedItem = items[0]
                    sourceResults[index] = updatedResult
                    // 可选：自动查询剧集
                    Task {
                        await self.queryEpisodes(for: items[0], in: rule)
                    }
                } else {
                    // 多个结果，需要用户选择
                    updatedResult.status = .needsSelection(items)
                    updatedResult.searchItems = items
                    sourceResults[index] = updatedResult
                }
            }

        } catch let error as AnimeParserError {
            await MainActor.run {
                switch error {
                case .captchaRequired:
                    // 仅标记为需要验证码，不弹窗（在播放器中切换源时才弹窗）
                    var updatedResult = sourceResults[index]
                    updatedResult.status = .captcha
                    sourceResults[index] = updatedResult
                case .noResult:
                    var updatedResult = sourceResults[index]
                    updatedResult.status = .noResult
                    sourceResults[index] = updatedResult
                case .networkError(let underlying):
                    var updatedResult = sourceResults[index]
                    updatedResult.status = .error(underlying.localizedDescription)
                    sourceResults[index] = updatedResult
                default:
                    var updatedResult = sourceResults[index]
                    updatedResult.status = .error(error.localizedDescription)
                    sourceResults[index] = updatedResult
                }
            }
        } catch {
            let errorString = error.localizedDescription.lowercased()
            await MainActor.run {
                var updatedResult = sourceResults[index]
                // 优化：避免误判，只匹配明确的验证码关键词
                if errorString.contains("captcha") ||
                   errorString.contains("需要验证") ||
                   errorString.contains("verification required") {
                    // 仅标记为需要验证码，不弹窗
                    updatedResult.status = .captcha
                } else {
                    updatedResult.status = .error(error.localizedDescription)
                }
                sourceResults[index] = updatedResult
            }
        }

        // 检查是否所有源都完成初始搜索（仅对不自动查询剧集的终端状态）
        // queryEpisodes 成功后会自行调用 checkAndFreezeInitialOrder
        checkAndFreezeInitialOrder()
    }

    /// 第二步：用选中的结果获取剧集列表
    /// 参考 Kazumi Plugin.querychapterRoads: 用第三方源详情页 URL 解析剧集
    func queryEpisodes(for item: SourceSearchItem, in rule: AnimeRule, clearCookies: Bool = false) async {
        let detailURL = item.fullURL(baseURL: rule.baseURL)

        print("[AnimeDetailViewModel] ========== 解析剧集 ==========")
        print("[AnimeDetailViewModel] 选中项: '\(item.name)'")
        print("[AnimeDetailViewModel] 详情页 URL: \(detailURL)")
        if clearCookies {
            print("[AnimeDetailViewModel] 将清除旧 Cookie 后重试")
        }

        guard let index = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }

        // 更新状态为加载中，同时保存 selectedItem（即使出错也需要保存，用于验证码验证后重试）
        await MainActor.run {
            var updatedResult = sourceResults[index]
            updatedResult.status = .loading
            updatedResult.selectedItem = item
            sourceResults[index] = updatedResult
        }

        do {
            // 使用 querychapterRoads 解析第三方源详情页
            // 如果需要清除 Cookie（验证码验证后），传入 clearOldCookies: true
            let details: [AnimeDetail]
            if clearCookies {
                // 临时清除 Cookie 后重试
                let cookieURL = URL(string: detailURL)!
                HTTPCookieStorage.shared.cookies?.forEach { cookie in
                    if cookie.domain.contains(cookieURL.host ?? "") {
                        HTTPCookieStorage.shared.deleteCookie(cookie)
                    }
                }
                details = try await AnimeParser.shared.querychapterRoads(
                    detailURL: detailURL,
                    rule: rule
                )
            } else {
                details = try await AnimeParser.shared.querychapterRoads(
                    detailURL: detailURL,
                    rule: rule
                )
            }

            if details.isEmpty {
                print("[AnimeDetailViewModel] ⚠️ 未找到播放列表")
                await MainActor.run {
                    var updatedResult = sourceResults[index]
                    updatedResult.status = .noResult
                    sourceResults[index] = updatedResult
                }
                // noResult 也是终端状态，检查是否需要冻结排序
                checkAndFreezeInitialOrder()
                return
            }

            let firstDetail = details.first!
            print("[AnimeDetailViewModel] ✓ 找到 \(details.count) 个播放列表")
            print("[AnimeDetailViewModel] ✓ 第一个播放列表 '\(firstDetail.title)' 有 \(firstDetail.episodes.count) 集")

            // 更新 sourceResults 中的数据
            await MainActor.run {
                var updatedResult = sourceResults[index]
                updatedResult.selectedItem = item
                updatedResult.detail = firstDetail
                updatedResult.status = .success
                sourceResults[index] = updatedResult
            }

            // 检查是否所有源都完成初始搜索，如果是则冻结排序
            checkAndFreezeInitialOrder()

        } catch let error as AnimeParserError {
            await MainActor.run {
                var updatedResult = sourceResults[index]
                switch error {
                case .captchaRequired:
                    // 仅标记为需要验证码，不弹窗（在播放器中切换源时才弹窗）
                    updatedResult.status = .captcha
                case .noResult:
                    updatedResult.status = .noResult
                case .networkError(let underlying):
                    updatedResult.status = .error(underlying.localizedDescription)
                default:
                    updatedResult.status = .error(error.localizedDescription)
                }
                sourceResults[index] = updatedResult
            }
            // captcha/error 也是终端状态，检查是否需要冻结排序
            checkAndFreezeInitialOrder()
        } catch {
            await MainActor.run {
                var updatedResult = sourceResults[index]
                updatedResult.status = .error(error.localizedDescription)
                sourceResults[index] = updatedResult
            }
            // captcha/error 也是终端状态，检查是否需要冻结排序
            checkAndFreezeInitialOrder()
        }
    }

    /// 用户选择搜索结果后调用 (Kazumi 风格)
    func selectSearchItem(_ item: SourceSearchItem, for rule: AnimeRule) async {
        await queryEpisodes(for: item, in: rule)
    }

    /// 重置源选择，返回到搜索结果列表
    func resetSourceSelection(for rule: AnimeRule) {
        guard let index = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }
        var updatedResult = sourceResults[index]
        // 如果有保存的搜索结果，恢复到 needsSelection 状态
        if let items = updatedResult.searchItems, !items.isEmpty {
            updatedResult.status = .needsSelection(items)
        } else {
            // 没有保存的搜索结果，恢复到 idle 状态并重新搜索
            updatedResult.status = .idle
            updatedResult.selectedItem = nil
            updatedResult.detail = nil
        }
        sourceResults[index] = updatedResult
    }

    // MARK: - 初始排序冻结机制

    /// 渐进式展示阈值：当完成比例达到此值时即冻结排序（0.8 = 80%）
    private let initialLoadThreshold: Double = 0.8

    /// 最少等待完成的源数量（避免源太少时过早触发）
    private let minimumSourcesToWait: Int = 3

    /// 检查是否足够多的非 deprecated 源已完成初始搜索
    /// 条件：已完成数 >= 总数 * threshold 且已完成数 >= minimumSourcesToWait
    /// 或者：所有活跃源都已完成（100% 场景）
    func checkAndFreezeInitialOrder() {
        guard !isInitialLoadComplete else { return }

        let activeSources = sourceResults.filter { !$0.rule.deprecated }
        guard !activeSources.isEmpty else { return }

        // 统计已完成的源（terminal 状态）
        let completedCount = activeSources.filter { status in
            switch status.status {
            case .idle, .loading:
                return false  // 还在进行中
            case .success, .needsSelection, .noResult, .error, .captcha:
                return true   // 已有最终状态
            }
        }.count

        let totalCount = activeSources.count
        let ratio = Double(completedCount) / Double(totalCount)

        // 判断是否可以冻结：
        // 1. 全部完成（兜底），或
        // 2. 达到阈值比例 且 达到最少等待数量
        let shouldFreeze = (completedCount == totalCount) ||
            (ratio >= initialLoadThreshold && completedCount >= minimumSourcesToWait)

        if shouldFreeze {
            // 仅对已完成的源排序冻结（未完成的排在后面保持原位）
            let sorted = activeSources.sorted { a, b in
                priorityForFreezing(a.status) < priorityForFreezing(b.status)
            }
            self.frozenSourceOrder = sorted.map { $0.id }
            self.isInitialLoadComplete = true
            print("[AnimeDetailViewModel] ✅ 初始排序已完成并冻结，\(completedCount)/\(totalCount) 个源完成 (比例: \(String(format: "%.0f", ratio * 100))%)")
        }
    }

    /// 排序优先级（仅用于初始冻结排序）
    private func priorityForFreezing(_ status: SourceQueryStatus) -> Int {
        switch status {
        case .success: return 0
        case .needsSelection: return 1
        case .captcha: return 2
        case .error: return 3
        case .noResult: return 4
        case .loading: return 5
        case .idle: return 6
        }
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

        print("[AnimeDetailViewModel] 验证码验证完成，同步 Cookie...")
        
        // 等待一小段时间确保 Cookie 已写入
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        
        // 同步 WebView Cookie 到共享存储
        await WebViewCookieSync.syncWKWebsiteDataStoreToSharedHTTPCookieStorage()
        
        // 关闭验证码弹窗
        captchaVerificationSession = nil
        
        // 再等待一小段时间确保同步完成
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3秒

        if let ep = replayEp, let idx = replayIdx {
            // 播放阶段的验证码验证完成，重新尝试播放
            print("[AnimeDetailViewModel] 重新尝试播放...")
            await playEpisode(ep, from: idx)
        } else if let item = selectedItem {
            // 剧集列表阶段的验证码验证完成，重新获取剧集列表
            // 传入 clearCookies: true 确保使用新验证的 Cookie
            print("[AnimeDetailViewModel] 重新获取剧集列表...")
            await queryEpisodes(for: item, in: rule, clearCookies: true)
        } else {
            // 搜索阶段的验证码验证完成，重新搜索
            print("[AnimeDetailViewModel] 重新搜索源...")
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
        
        // 先停止之前的播放（避免 stopPlayback 把 currentEpisode 设为 nil）
        stopPlayback()
        
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
    /// 清理播放器但不重置 currentEpisode（用于切换剧集时）
    private func cleanupPlayerOnly() {
        PlaybackProgressCache.shared.stopTracking()
        currentPlayURL = nil
        currentStartTime = 0
        isPlaying = false
        isBuffering = false
        // 恢复系统息屏/休眠
        SleepPreventer.shared.stopPreventingSleep()
        // 清理所有播放器相关的 Combine 订阅，防止切换剧集时堆积
        cancellables.removeAll()
        // 注意：不重置 currentEpisode，保留当前播放的剧集信息
        
        // 取消弹幕加载
        danmakuTask?.cancel()
        danmakuTask = nil
        danmakuList = []
    }

    /// 使用原生播放器设置播放器
    private func setupPlayer(with url: URL, episode: AnimeDetail.AnimeEpisodeItem, sourceIndex: Int) {
        let rule = sourceResults[sourceIndex].rule
        
        // 使用 cleanupPlayerOnly 而不是 stopPlayback，避免 currentEpisode 被清空
        cleanupPlayerOnly()
        
        // 恢复播放进度
        var startTime: TimeInterval = 0
        if let savedProgress = PlaybackProgressCache.shared.getProgress(
            sourceId: rule.id,
            episodeId: episode.id
        ), savedProgress.currentTime > 10,
           savedProgress.currentTime < (savedProgress.duration > 0 ? savedProgress.duration * 0.9 : Double.infinity) {
            startTime = savedProgress.currentTime
            print("[AnimeDetailViewModel] 将从 \(savedProgress.formattedProgress) 恢复播放")
        }
        
        self.currentStartTime = startTime
        self.currentPlayURL = url
        self.isPlaying = true
        self.isBuffering = true
        
        print("[AnimeDetailViewModel] 开始播放: \(url.absoluteString)")

        // 开始跟踪播放进度
        PlaybackProgressCache.shared.startTracking(
            animeId: anime.id,
            animeTitle: anime.title,
            episode: episode,
            sourceId: rule.id,
            sourceName: rule.name,
            coverURL: anime.coverURL
        )

        // 加载弹幕
        loadDanmaku(for: episode)
    }

    // MARK: - 播放器状态回调（由 View 调用）

    func handlePlayerState(_ state: PlaybackState) {
        switch state {
        case .readyToPlay:
            print("[AnimeDetailViewModel] ✅ 播放器状态: readyToPlay")
            isBuffering = false
            videoError = nil // 播放成功时清除之前的错误提示
            SleepPreventer.shared.startPreventingSleep()
        case .buffering:
            print("[AnimeDetailViewModel] ⏳ 播放器状态: buffering")
            isBuffering = true
        case .paused:
            print("[AnimeDetailViewModel] ⏸️ 播放器状态: paused")
            isPlaying = false
            SleepPreventer.shared.stopPreventingSleep()
        case .failed(let msg):
            print("[AnimeDetailViewModel] ❌ 播放器状态: error - \(msg)")
            videoError = "视频播放失败，请尝试切换其他视频源"
            isBuffering = false
            isPlaying = false
            SleepPreventer.shared.stopPreventingSleep()
        case .idle, .loading:
            break
        case .playing:
            isPlaying = true
            isBuffering = false
            videoError = nil // 播放成功时清除之前的错误提示
            SleepPreventer.shared.startPreventingSleep()
        case .finished:
            isPlaying = false
            SleepPreventer.shared.stopPreventingSleep()
        }
    }

    func handlePlayerProgress(currentTime: TimeInterval, totalTime: TimeInterval) {
        self.currentTime = currentTime
        self.totalDuration = totalTime
        let progress = totalTime > 0 ? currentTime / totalTime : 0
        
        // 同时更新 AnimeProgressStore（每5%或完成时保存一次）
        if let currentEpisode = currentEpisode {
            let shouldSave = Int(progress * 20) > Int(self.currentProgress * 20) || progress >= 0.95
            if shouldSave {
                AnimeProgressStore.shared.updateProgress(
                    animeId: anime.id,
                    animeTitle: anime.title,
                    coverURL: anime.coverURL,
                    episodeId: currentEpisode.id,
                    episodeNumber: "\(currentEpisode.episodeNumber)",
                    currentTime: currentTime,
                    totalDuration: totalTime
                )
            }
        }
        
        self.currentProgress = progress
        
        // 更新进度缓存
        PlaybackProgressCache.shared.updateProgress(currentTime: currentTime, duration: totalTime)
    }

    func handlePlayerFinish(error: Error?) {
        isPlaying = false
        isBuffering = false
        SleepPreventer.shared.stopPreventingSleep()
        if let error = error {
            videoError = "播放失败: \(error.localizedDescription)"
            print("[AnimeDetailViewModel] ❌ 播放完成(出错): \(error.localizedDescription)")
        } else {
            print("[AnimeDetailViewModel] ✅ 播放正常完成")
        }
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
        
        PlaybackProgressCache.shared.stopTracking()
        currentPlayURL = nil
        currentStartTime = 0
        isPlaying = false
        isBuffering = false
        // 恢复系统息屏/休眠
        SleepPreventer.shared.stopPreventingSleep()
        // 清理所有播放器相关的 Combine 订阅
        cancellables.removeAll()
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

