import Foundation
import SwiftUI
import Combine
import OSLog

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
        guard let base = URL(string: baseURL) else { return src }
        return URL(string: src, relativeTo: base)?.absoluteURL.absoluteString ?? src
    }
}

// MARK: - 源搜索结果

struct SourceSearchResult: Identifiable {
    let id: String  // 使用规则 ID 作为唯一标识
    let rule: AnimeRule
    var status: SourceQueryStatus = .idle
    var selectedItem: SourceSearchItem?  // 用户选择的结果
    var roads: [AnimeDetail] = []
    var selectedRoadIndex = 0
    var detail: AnimeDetail? {
        get { roads.indices.contains(selectedRoadIndex) ? roads[selectedRoadIndex] : nil }
        set { roads = newValue.map { [$0] } ?? []; selectedRoadIndex = 0 }
    }
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
    var isDownload = false
}

// MARK: - 动漫详情页 ViewModel

@MainActor
class AnimeDetailViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.waifux.app", category: "AnimeSourceDiscovery")

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
    @Published private(set) var currentHTTPHeaders: [String: String] = [:]
    @Published private(set) var playbackID = UUID()
    @Published private var observedPlayerState: (id: UUID, state: PlaybackState)?

    /// Do not carry a state across retries, route changes, or episode changes.
    var currentPlayerState: PlaybackState {
        guard let observedPlayerState, observedPlayerState.id == playbackID else { return .idle }
        return observedPlayerState.state
    }

    @Published private(set) var currentSourceID: String?
    @Published private(set) var resolvingDownloads = Set<String>()
    @Published private(set) var downloadErrors: [String: String] = [:]
    private let playbackExtractor = AnimeVideoExtractor()
    private var directHLSRelay: DirectHLSRelay?
    private var downloadExtractors: [String: AnimeVideoExtractor] = [:]
    private var playbackRequestID = UUID()
    private var sourceRequestIDs: [String: UUID] = [:]
    private var candidateIndex = 0
    private var automaticRecoveryCount = 0
    /// 跨源自动恢复：本集已尝试过的源（含当前源），防止循环。
    private var attemptedSourceIDs = Set<String>()
    /// 跨源恢复预算：最多再试 3 个其它源。
    private var crossSourceRecoveryCount = 0
    private static let maxCrossSourceRecovery = 3
    private var recoveryStartTime: TimeInterval?
    private var hasPlaybackPosition = false
    private var readyForSync = false
    /// 每个源最近一次真实起播成功的剧集（内存态；用于「可播放」标记与排序）。
    private var verifiedPlaybackEpisodes: [String: Set<String>] = [:]
    private var pendingRemoteSeek: PlaybackSeekRequest?
    private var currentRoadID: String?
    private let progressSessionID = UUID()
    private var playbackTransitionTask: Task<Void, Never>?
    private var finishedPlaybackID: UUID?
    private var didSkipOpening = false
    private var didSkipEnding = false
    private var attemptedRoadIDs = Set<String>()
    @Published private(set) var seekRequest: PlaybackSeekRequest?
    @Published var showDanmakuSourcePicker = false
    @Published var danmakuError: String?
    /// 当前集的弹幕来源是否为用户手动指定（面板展示「手动指定/自动匹配」）。
    @Published private(set) var danmakuManualSourceActive = false
    let syncPlay = AnimeSyncPlayService()

    struct PlaybackSeekRequest: Identifiable {
        let id = UUID()
        let time: Double
        let resume: Bool
    }
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
        var openingSeconds: Double = 85
        var endingSeconds: Double = 85

        enum CodingKeys: String, CodingKey {
            case superResolution, aiDenoise, colorEnhancement, autoPlayNext, skipOpeningEnding
            case openingSeconds, endingSeconds
        }

        init(superResolution: Bool, aiDenoise: Bool, colorEnhancement: Bool, autoPlayNext: Bool,
             skipOpeningEnding: Bool, openingSeconds: Double = 85, endingSeconds: Double = 85) {
            self.superResolution = superResolution; self.aiDenoise = aiDenoise
            self.colorEnhancement = colorEnhancement; self.autoPlayNext = autoPlayNext
            self.skipOpeningEnding = skipOpeningEnding
            self.openingSeconds = openingSeconds; self.endingSeconds = endingSeconds
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            superResolution = false; aiDenoise = false; colorEnhancement = false
            autoPlayNext = try values.decodeIfPresent(Bool.self, forKey: .autoPlayNext) ?? true
            skipOpeningEnding = try values.decodeIfPresent(Bool.self, forKey: .skipOpeningEnding) ?? false
            openingSeconds = min(300, max(0, try values.decodeIfPresent(Double.self, forKey: .openingSeconds) ?? 85))
            endingSeconds = min(300, max(0, try values.decodeIfPresent(Double.self, forKey: .endingSeconds) ?? 85))
        }

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
        syncPlay.onRemotePlayback = { [weak self] playing, position in
            guard let self, self.currentPlayURL != nil, position.isFinite, position >= 0 else { return }
            let request = PlaybackSeekRequest(time: position, resume: playing)
            if self.readyForSync { self.seekRequest = request }
            else { self.pendingRemoteSeek = request }
        }
        syncPlay.onRemoteEpisode = { [weak self] number in
            guard let self, self.currentEpisode?.episodeNumber != number else { return }
            self.playbackTransitionTask?.cancel()
            self.playbackTransitionTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.playbackTransitionTask = nil
                await self.playEpisode(number: number)
            }
        }
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

    /// 播放器窗口入口：规则装载与全源检索在同一任务里串行完成。
    /// 旧路径「开窗即并发 searchAllSources」会在规则未就绪时静默跳过，
    /// 且规则随后到达也不会补发检索，右栏因此永远停在分析中。
    func loadRulesAndSearchAllSources() async {
        // 先占位规则事务，详情 sheet 并发的 loadData 会合流到同一事务而不是重复重建。
        // 已有源（窗口重聚焦等重复入口）不重装规则，避免重置检索状态。
        if sourceResults.isEmpty {
            await loadRules()
        }
        await searchAllSources()
        // Bangumi 详情仅用于展示与弹幕映射，不阻塞源检索。
        if bangumiDetail == nil, !isLoadingBangumi {
            await loadBangumiDetail()
        }
    }

    // MARK: - 加载规则
    /// 加载规则：先尝试本地，如果失败则从远程加载
    private func loadRules() async {
        // 详情 sheet 与播放器窗口可能同时请求装载；共享同一事务，避免重复重建 sourceResults。
        if let rulesLoadTask {
            await rulesLoadTask.value
            return
        }
        let task = Task { await self.performRulesLoad() }
        rulesLoadTask = task
        await task.value
        rulesLoadTask = nil
    }

    private var rulesLoadTask: Task<Void, Never>?

    private func performRulesLoad() async {
        isLoadingRules = true
        Self.logger.notice("rules_load_begin existing_sources=\(self.sourceResults.count, privacy: .public)")
        defer {
            isLoadingRules = false
            Self.logger.notice("rules_load_end visible_sources=\(self.sourceResults.count, privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)")
        }

        // 与启动检查合并，首次详情搜索使用已完成事务的新规则；离线失败仍保留旧快照。
        await AnimeRuleStore.shared.syncOnLaunchInBackground()
        let rules = await AnimeRuleStore.shared.loadAllRules()

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

        guard sourceResults.firstIndex(where: { $0.id == rule.id }) != nil else { return }
        let requestID = UUID()
        sourceRequestIDs[rule.id] = requestID

        // 更新状态为加载中
        await MainActor.run {
            guard !Task.isCancelled, sourceRequestIDs[rule.id] == requestID,
                  let currentIndex = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }
            var updatedResult = sourceResults[currentIndex]
            updatedResult.status = .loading
            updatedResult.selectedItem = nil
            updatedResult.detail = nil
            sourceResults[currentIndex] = updatedResult
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
                guard !Task.isCancelled, sourceRequestIDs[rule.id] == requestID,
                  let currentIndex = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }
                var updatedResult = sourceResults[currentIndex]
                if items.isEmpty {
                    updatedResult.status = .noResult
                    sourceResults[currentIndex] = updatedResult
                } else if items.count == 1 {
                    // 只有一个结果，自动选择但不自动查询剧集
                    updatedResult.selectedItem = items[0]
                    sourceResults[currentIndex] = updatedResult
                    // 可选：自动查询剧集
                    Task {
                        await self.queryEpisodes(for: items[0], in: rule, expectedRequestID: requestID)
                    }
                } else {
                    // 多个结果，需要用户选择
                    updatedResult.status = .needsSelection(items)
                    updatedResult.searchItems = items
                    sourceResults[currentIndex] = updatedResult
                }
            }

        } catch let error as AnimeParserError {
            await MainActor.run {
                guard !Task.isCancelled, sourceRequestIDs[rule.id] == requestID,
                  let currentIndex = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }
                switch error {
                case .captchaRequired:
                    // 仅标记为需要验证码，不弹窗（在播放器中切换源时才弹窗）
                    var updatedResult = sourceResults[currentIndex]
                    updatedResult.status = .captcha
                    sourceResults[currentIndex] = updatedResult
                case .noResult:
                    var updatedResult = sourceResults[currentIndex]
                    updatedResult.status = .noResult
                    sourceResults[currentIndex] = updatedResult
                case .networkError(let underlying):
                    var updatedResult = sourceResults[currentIndex]
                    updatedResult.status = .error(underlying.localizedDescription)
                    sourceResults[currentIndex] = updatedResult
                default:
                    var updatedResult = sourceResults[currentIndex]
                    updatedResult.status = .error(error.localizedDescription)
                    sourceResults[currentIndex] = updatedResult
                }
            }
        } catch {
            let errorString = error.localizedDescription.lowercased()
            await MainActor.run {
                guard !Task.isCancelled, sourceRequestIDs[rule.id] == requestID,
                  let currentIndex = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }
                var updatedResult = sourceResults[currentIndex]
                // 优化：避免误判，只匹配明确的验证码关键词
                if errorString.contains("captcha") ||
                   errorString.contains("需要验证") ||
                   errorString.contains("verification required") {
                    // 仅标记为需要验证码，不弹窗
                    updatedResult.status = .captcha
                } else {
                    updatedResult.status = .error(error.localizedDescription)
                }
                sourceResults[currentIndex] = updatedResult
            }
        }

        // queryEpisodes 成功后会自行冻结；过期搜索不能影响当前状态。
        guard !Task.isCancelled, sourceRequestIDs[rule.id] == requestID else { return }
        checkAndFreezeInitialOrder()
    }

    /// 第二步：用选中的结果获取剧集列表
    /// 参考 Kazumi Plugin.querychapterRoads: 用第三方源详情页 URL 解析剧集
    func queryEpisodes(for item: SourceSearchItem, in rule: AnimeRule, expectedRequestID: UUID? = nil) async {
        if let expectedRequestID, sourceRequestIDs[rule.id] != expectedRequestID { return }
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        sourceRequestIDs[rule.id] = requestID
        let detailURL = rule.chapterMode == .api ? item.src : item.fullURL(baseURL: rule.baseURL)

        print("[AnimeDetailViewModel] ========== 解析剧集 ==========")
        print("[AnimeDetailViewModel] 选中项: '\(item.name)'")
        print("[AnimeDetailViewModel] 详情来源 host=\(URL(string: detailURL)?.host ?? "api")")

        // 更新状态为加载中，同时保存 selectedItem（即使出错也需要保存，用于验证码验证后重试）
        await MainActor.run {
            guard !Task.isCancelled, sourceRequestIDs[rule.id] == requestID,
                  let currentIndex = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }
            var updatedResult = sourceResults[currentIndex]
            updatedResult.status = .loading
            updatedResult.selectedItem = item
            sourceResults[currentIndex] = updatedResult
        }

        do {
            // 重新请求使用已同步的验证Cookie，API的source可为裸ID。
            let details = try await AnimeParser.shared.querychapterRoads(detailURL: detailURL, rule: rule)

            if details.isEmpty {
                print("[AnimeDetailViewModel] ⚠️ 未找到播放列表")
                await MainActor.run {
                    guard !Task.isCancelled, sourceRequestIDs[rule.id] == requestID,
                  let currentIndex = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }
                    var updatedResult = sourceResults[currentIndex]
                    updatedResult.status = .noResult
                    sourceResults[currentIndex] = updatedResult
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
                guard !Task.isCancelled, sourceRequestIDs[rule.id] == requestID,
                  let currentIndex = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }
                var updatedResult = sourceResults[currentIndex]
                updatedResult.selectedItem = item
                let previousRoadID = updatedResult.detail?.id
                updatedResult.roads = details
                updatedResult.selectedRoadIndex = details.firstIndex(where: { $0.id == previousRoadID }) ?? 0
                updatedResult.status = .success
                sourceResults[currentIndex] = updatedResult
            }

            // 检查是否所有源都完成初始搜索，如果是则冻结排序
            checkAndFreezeInitialOrder()

        } catch let error as AnimeParserError {
            await MainActor.run {
                guard !Task.isCancelled, sourceRequestIDs[rule.id] == requestID,
                  let currentIndex = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }
                var updatedResult = sourceResults[currentIndex]
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
                sourceResults[currentIndex] = updatedResult
            }
            // captcha/error 也是终端状态，检查是否需要冻结排序
            checkAndFreezeInitialOrder()
        } catch {
            await MainActor.run {
                guard !Task.isCancelled, sourceRequestIDs[rule.id] == requestID,
                  let currentIndex = sourceResults.firstIndex(where: { $0.id == rule.id }) else { return }
                var updatedResult = sourceResults[currentIndex]
                updatedResult.status = .error(error.localizedDescription)
                sourceResults[currentIndex] = updatedResult
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
        sourceRequestIDs[rule.id] = UUID()
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
            // 仅对已完成的源排序冻结（未完成的排在后面保持原位）；
            // 同优先级内按跨会话信誉分排序，上次的好源排前面。
            let sorted = activeSources.sorted { a, b in
                let pa = sourceAvailabilityPriority(a), pb = sourceAvailabilityPriority(b)
                if pa != pb { return pa < pb }
                return AnimeSourceReputationStore.shared.ranksBefore(a.id, b.id)
            }
            self.frozenSourceOrder = sorted.map { $0.id }
            self.isInitialLoadComplete = true
            print("[AnimeDetailViewModel] ✅ 初始排序已完成并冻结，\(completedCount)/\(totalCount) 个源完成 (比例: \(String(format: "%.0f", ratio * 100))%)")
        }
    }

    /// 该源是否真实起播成功过：本会话内存标记 或 跨会话信誉记录（60 天内）。
    func hasVerifiedPlayback(for sourceID: String) -> Bool {
        !(verifiedPlaybackEpisodes[sourceID] ?? []).isEmpty
            || AnimeSourceReputationStore.shared.hasVerifiedPlayback(sourceID: sourceID)
    }

    /// 源可用性排序：可播放 > 有剧集 > 需选择 > 需验证 > 检索中 > 失败 > 无结果 > 未检索。
    /// 冻结排序与右栏实时排序共用，保证两处口径一致。
    func sourceAvailabilityPriority(_ source: SourceSearchResult) -> Int {
        if hasVerifiedPlayback(for: source.id) { return 0 }
        switch source.status {
        case .success: return source.roads.contains { !$0.episodes.isEmpty } ? 1 : 6
        case .needsSelection: return 2
        case .captcha: return 3
        case .loading: return 4
        case .error: return 5
        case .noResult: return 6
        case .idle: return 7
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
        if sourceResults.isEmpty {
            // 规则尚未就绪：等待装载完成后补发检索，而不是静默放弃。
            Self.logger.notice("source_search_deferred_until_rules rules_loading=\(self.isLoadingRules, privacy: .public)")
            await loadRules()
        }
        guard !sourceResults.isEmpty else {
            Self.logger.error("source_search_skipped_no_rules rules_loading=\(self.isLoadingRules, privacy: .public)")
            return
        }

        Self.logger.notice("source_search_begin count=\(self.sourceResults.count, privacy: .public)")
        print("[AnimeDetailViewModel] ========== 开始查询所有源 ==========")

        // 并发查询所有源
        await withTaskGroup(of: Void.self) { group in
            for sourceResult in sourceResults {
                group.addTask {
                    await self.searchInSource(sourceResult.rule)
                }
            }
        }

        Self.logger.notice("source_search_end sources=\(self.sourceResults.count, privacy: .public) initial_load_complete=\(self.isInitialLoadComplete, privacy: .public)")
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

        print("[AnimeDetailViewModel] 打开验证码验证页面 host=\(url.host ?? "unknown")")
        captchaVerificationSession = CaptchaVerificationSession(
            rule: rule,
            startURL: url,
            replayEpisode: nil,
            replaySourceIndex: nil
        )
    }

    func presentCaptchaVerificationForPlayback(rule: AnimeRule, episode: AnimeDetail.AnimeEpisodeItem, sourceIndex: Int, forDownload: Bool = false) {
        guard let url = URL(string: episode.url) else { return }
        captchaVerificationSession = CaptchaVerificationSession(
            rule: rule,
            startURL: url,
            replayEpisode: episode,
            replaySourceIndex: sourceIndex,
            isDownload: forDownload
        )
    }

    func cancelCaptchaVerification() {
        captchaVerificationSession = nil
    }

    func completeCaptchaVerificationAndContinue(session: CaptchaVerificationSession) async {
        guard captchaVerificationSession?.id == session.id else { return }
        let replayEp = session.replayEpisode
        let rule = session.rule
        let selectedItem = session.selectedSearchItem

        print("[AnimeDetailViewModel] 验证码验证完成，同步 Cookie...")
        
        await WebViewCookieSync.syncWKWebsiteDataStoreToSharedHTTPCookieStorage()
        guard !Task.isCancelled, captchaVerificationSession?.id == session.id else { return }
        captchaVerificationSession = nil

        if let ep = replayEp,
           let idx = sourceResults.firstIndex(where: { $0.id == rule.id }) {
            // 播放阶段的验证码验证完成，重新尝试播放
            print("[AnimeDetailViewModel] 重新尝试播放...")
            if session.isDownload {
                AnimeDownloadEngine.shared.resume(episodeId: ep.id, sourceId: rule.id)
            } else {
                await playEpisode(ep, from: idx)
            }
        } else if let item = selectedItem {
            // 剧集列表阶段的验证码验证完成，重新获取剧集列表
            print("[AnimeDetailViewModel] 重新获取剧集列表...")
            await queryEpisodes(for: item, in: rule)
        } else {
            // 搜索阶段的验证码验证完成，重新搜索
            print("[AnimeDetailViewModel] 重新搜索源...")
            await searchInSource(rule)
        }
    }

    // MARK: - 播放剧集

    func selectRoad(_ roadIndex: Int, sourceID: String) {
        guard let sourceIndex = sourceResults.firstIndex(where: { $0.id == sourceID }),
              sourceResults[sourceIndex].roads.indices.contains(roadIndex) else { return }
        sourceResults[sourceIndex].selectedRoadIndex = roadIndex
        selectedSourceIndex = sourceIndex
    }

    var canSwitchPlaybackRoad: Bool {
        guard let id = currentSourceID, let source = sourceResults.first(where: { $0.id == id }),
              let episode = currentEpisode else { return false }
        return source.roads.contains { road in
            !attemptedRoadIDs.contains(road.id) && road.episodes.contains { $0.episodeNumber == episode.episodeNumber }
        }
    }

    func switchToNextPlaybackRoad() async {
        guard let id = currentSourceID, let index = sourceResults.firstIndex(where: { $0.id == id }),
              let episode = currentEpisode else { return }
        let source = sourceResults[index]
        for (roadIndex, road) in source.roads.enumerated() where !attemptedRoadIDs.contains(road.id) {
            guard let match = road.episodes.first(where: { $0.episodeNumber == episode.episodeNumber }) else { continue }
            attemptedRoadIDs.insert(road.id)
            recoveryStartTime = hasPlaybackPosition ? currentTime : currentStartTime
            sourceResults[index].selectedRoadIndex = roadIndex
            automaticRecoveryCount = 0
            await playEpisode(match, from: index, isRecovery: true)
            return
        }
    }

    func playEpisode(number: Int) async {
        guard let id = currentSourceID, let index = sourceResults.firstIndex(where: { $0.id == id }),
              let episode = (sourceResults[index].roads.first(where: { $0.id == currentRoadID }) ?? sourceResults[index].detail)?.episodes.first(where: { $0.episodeNumber == number }) else { return }
        await playEpisode(episode, from: index)
    }

    func playNextEpisode() async {
        guard let current = currentEpisode else { return }
        if currentPlayURL?.isFileURL == true {
            let records = AnimeDownloadStore.shared.records.values.filter {
                $0.animeId == anime.id && $0.sourceId == currentSourceID && $0.fileExists && $0.episodeNumber > current.episodeNumber
            }.sorted { $0.episodeNumber < $1.episodeNumber }
            if let next = records.first { playLocalEpisode(next) }
            return
        }
        guard let id = currentSourceID, let index = sourceResults.firstIndex(where: { $0.id == id }) else { return }
        let episodes = sourceResults[index].roads.first(where: { $0.id == currentRoadID })?.episodes ?? sourceResults[index].detail?.episodes ?? []
        if let next = episodes.filter({ $0.episodeNumber > current.episodeNumber }).min(by: { $0.episodeNumber < $1.episodeNumber }) {
            await playEpisode(next, from: index)
        }
    }

    private var hasNextEpisode: Bool {
        guard let current = currentEpisode else { return false }
        if currentPlayURL?.isFileURL == true {
            return AnimeDownloadStore.shared.records.values.contains {
                $0.animeId == anime.id && $0.sourceId == currentSourceID && $0.fileExists && $0.episodeNumber > current.episodeNumber
            }
        }
        guard let source = sourceResults.first(where: { $0.id == currentSourceID }) else { return false }
        return (source.roads.first(where: { $0.id == currentRoadID }) ?? source.detail)?.episodes.contains {
            $0.episodeNumber > current.episodeNumber
        } ?? false
    }

    @discardableResult
    private func scheduleNextEpisode() -> Bool {
        guard hasNextEpisode else { return false }
        guard finishedPlaybackID != playbackID else { return true }
        finishedPlaybackID = playbackID
        let expectedID = playbackID
        playbackTransitionTask?.cancel()
        playbackTransitionTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.playbackID == expectedID else { return }
            self.playbackTransitionTask = nil
            await self.playNextEpisode()
        }
        return true
    }

    func playEpisode(_ episode: AnimeDetail.AnimeEpisodeItem, from sourceIndex: Int, isRecovery: Bool = false) async {
        guard sourceResults.indices.contains(sourceIndex) else { return }
        let rule = sourceResults[sourceIndex].rule
        let resumeTime = isRecovery ? (recoveryStartTime ?? currentTime) : nil
        stopPlayback()
        if !isRecovery {
            automaticRecoveryCount = 0
            crossSourceRecoveryCount = 0
            attemptedRoadIDs.removeAll()
            attemptedSourceIDs.removeAll()
        }
        attemptedSourceIDs.insert(rule.id)
        currentRoadID = sourceResults[sourceIndex].roads.first(where: { $0.episodes.contains(where: { $0.id == episode.id }) })?.id
        if let currentRoadID { attemptedRoadIDs.insert(currentRoadID) }
        recoveryStartTime = resumeTime
        let requestID = playbackRequestID
        currentEpisode = episode
        currentSourceID = rule.id
        selectedSourceIndex = sourceIndex
        isLoadingVideo = true
        videoError = nil
        defer { if playbackRequestID == requestID { isLoadingVideo = false } }

        let result = await playbackExtractor.extractVideoSources(from: episode.url, rule: rule, allowDirectMXdmHLS: true)
        guard playbackRequestID == requestID, !Task.isCancelled else { return }
        switch result {
        case .success(let sources):
            videoSources = sources
            candidateIndex = 0
            await startCandidate(at: 0, episode: episode, rule: rule, requestID: requestID)
        case .error(let error):
            AnimeSourceReputationStore.shared.recordFailure(sourceID: rule.id)
            videoError = error
            await recoverPlaybackFailure(episode: episode, requestID: requestID)
        case .captcha:
            presentCaptchaVerificationForPlayback(rule: rule, episode: episode, sourceIndex: sourceIndex)
        case .timeout:
            AnimeSourceReputationStore.shared.recordFailure(sourceID: rule.id)
            videoError = t("视频解析超时，请重试或切换其他视频源")
            await recoverPlaybackFailure(episode: episode, requestID: requestID)
        }
    }

    /// 预探测后起播指定候选：确认媒体可取才交给 AVPlayer；确认失败则换下一候选。
    /// 证据不足（网络超时等）不判死，直接试播由播放器兜底。
    private func startCandidate(at index: Int, episode: AnimeDetail.AnimeEpisodeItem,
                                rule: AnimeRule, requestID: UUID) async {
        guard playbackRequestID == requestID, !Task.isCancelled,
              videoSources.indices.contains(index) else { return }
        candidateIndex = index
        let source = videoSources[index]
        guard let url = URL(string: source.preflightResolvedURL ?? source.url) else {
            await advanceCandidateOrRecover(episode: episode, rule: rule, requestID: requestID)
            return
        }
        currentHTTPHeaders = source.httpHeaders ?? AnimeVideoExtractor.requestHeaders(for: url, rule: rule, pageURL: episode.url)

        let verdict = await AnimePlaybackPreflight.check(source)
        guard playbackRequestID == requestID, !Task.isCancelled else { return }
        if !verdict.playable {
            addRecoveryLog("预探测拒绝候选 host=\(url.host ?? "?") reason=\(verdict.failure ?? "unknown")")
            await advanceCandidateOrRecover(episode: episode, rule: rule, requestID: requestID)
            return
        }
        var playSource = source
        if let resolved = verdict.resolvedURL { playSource.preflightResolvedURL = resolved.absoluteString }
        if verdict.needsDirectRelay { playSource.usesDirectHLSRelay = true }
        videoSources[index] = playSource
        let playURL = verdict.resolvedURL ?? url
        await setupPlayer(with: playURL, episode: episode, rule: rule, useDirectHLS: playSource.usesDirectHLSRelay == true)
    }

    /// 当前候选预探测失败：还有候选就换下一个，否则进恢复链。
    private func advanceCandidateOrRecover(episode: AnimeDetail.AnimeEpisodeItem,
                                           rule: AnimeRule, requestID: UUID) async {
        guard playbackRequestID == requestID, !Task.isCancelled else { return }
        if candidateIndex + 1 < videoSources.count {
            await startCandidate(at: candidateIndex + 1, episode: episode, rule: rule, requestID: requestID)
            return
        }
        AnimeSourceReputationStore.shared.recordFailure(sourceID: rule.id)
        videoError = t("未找到可播放的视频")
        await recoverPlaybackFailure(episode: episode, requestID: requestID)
    }

    private func addRecoveryLog(_ message: String) {
        Self.logger.notice("\(message, privacy: .public)")
    }

    /// 统一失败恢复链（播放器失败 / 解析失败 / 预探测全灭都进这里）：
    /// 同源换线路 → 跨源换源（按信誉分排序，最多 3 个）→ 停。
    private func recoverPlaybackFailure(episode: AnimeDetail.AnimeEpisodeItem, requestID: UUID) async {
        guard playbackRequestID == requestID, !Task.isCancelled else { return }
        // 1) 同源还有未试线路：换线路。
        if canSwitchPlaybackRoad {
            await switchToNextPlaybackRoad()
            return
        }
        // 2) 跨源：按信誉分挑未试过的源里最优的。
        guard crossSourceRecoveryCount < Self.maxCrossSourceRecovery else { return }
        let candidates = sourceResults.enumerated().filter { _, source in
            !attemptedSourceIDs.contains(source.id) && !source.rule.deprecated &&
            source.status == .success && source.roads.contains { road in
                road.episodes.contains { $0.episodeNumber == episode.episodeNumber }
            }
        }
        guard let best = candidates.min(by: { lhs, rhs in
            AnimeSourceReputationStore.shared.ranksBefore(lhs.element.id, rhs.element.id)
        }) else { return }
        guard let match = best.element.roads.lazy.compactMap({ road in
            road.episodes.first { $0.episodeNumber == episode.episodeNumber }
        }).first else { return }
        crossSourceRecoveryCount += 1
        attemptedSourceIDs.insert(best.element.id)
        automaticRecoveryCount = 0
        attemptedRoadIDs.removeAll()
        recoveryStartTime = hasPlaybackPosition ? currentTime : (recoveryStartTime ?? currentStartTime)
        addRecoveryLog("跨源恢复 → \(best.element.rule.name) 第\(episode.episodeNumber)集")
        await playEpisode(match, from: best.offset, isRecovery: true)
    }

    /// 先换候选（经预探测），再最多刷新一次解析，最后进跨源恢复链；预算在新选集或手动重试时重置。
    func retryPlayback(automatically: Bool = false) async {
        if currentPlayURL?.isFileURL == true {
            guard !automatically else { return }
            currentStartTime = hasPlaybackPosition ? currentTime : currentStartTime
            videoError = nil
            isBuffering = true
            playbackID = UUID()
            return
        }
        guard let episode = currentEpisode, let sourceID = currentSourceID,
              let index = sourceResults.firstIndex(where: { $0.id == sourceID }) else { return }
        recoveryStartTime = hasPlaybackPosition ? currentTime : (recoveryStartTime ?? currentStartTime)
        let requestID = playbackRequestID
        if automatically {
            AnimeSourceReputationStore.shared.recordFailure(sourceID: sourceID)
            if candidateIndex + 1 < videoSources.count {
                await startCandidate(at: candidateIndex + 1, episode: episode, rule: sourceResults[index].rule, requestID: requestID)
                return
            }
            guard automaticRecoveryCount < 1 else {
                await recoverPlaybackFailure(episode: episode, requestID: requestID)
                return
            }
            automaticRecoveryCount += 1
        } else {
            automaticRecoveryCount = 0
            crossSourceRecoveryCount = 0
        }
        await playEpisode(episode, from: index, isRecovery: true)
    }

    // MARK: - 本地缓存（下载）

    /// 该集是否有可用本地缓存
    func hasLocalCache(for episodeId: String, sourceId: String) -> Bool {
        AnimeDownloadStore.shared.isDownloaded(episodeId: episodeId, sourceId: sourceId)
    }

    /// 播放本地缓存的剧集（「本地」tab 与选集列表缓存标记共用）
    func playLocalEpisode(_ record: AnimeDownloadRecord) {
        guard FileManager.default.fileExists(atPath: record.localFilePath) else {
            // 缓存文件被外部清理：移除失效记录并提示
            AnimeDownloadStore.shared.removeRecord(id: record.id, deleteFile: false)
            videoError = t("本地缓存文件已失效，请重新下载")
            return
        }

        stopPlayback()

        // 构造与在线播放等价的 episode 项，让进度跟踪/弹幕/下一集逻辑正常工作
        let episode = AnimeDetail.AnimeEpisodeItem(
            id: record.episodeId,
            name: record.episodeName,
            episodeNumber: record.episodeNumber,
            url: record.originalURL ?? "",
            thumbnailURL: nil
        )
        currentEpisode = episode
        currentSourceID = record.sourceId
        currentHTTPHeaders = [:]
        playbackID = UUID()
        isLoadingVideo = false
        videoError = nil
        videoSources = [VideoSource(quality: "Local", url: record.localFilePath, type: "mp4", label: record.sourceName)]

        // 恢复播放进度（进度键与在线播放一致：sourceId_episodeId）
        var startTime: TimeInterval = 0
        if let saved = PlaybackProgressCache.shared.getProgress(
            sourceId: record.sourceId,
            episodeId: record.episodeId
        ), saved.currentTime > 10,
           saved.currentTime < (saved.duration > 0 ? saved.duration * 0.9 : .infinity) {
            startTime = saved.currentTime
        }

        currentStartTime = startTime
        currentPlayURL = record.localFileURL
        isPlaying = true
        isBuffering = false

        PlaybackProgressCache.shared.startTracking(
            animeId: anime.id,
            animeTitle: anime.title,
            episode: episode,
            sourceId: record.sourceId,
            sourceName: record.sourceName,
            coverURL: anime.coverURL,
            sessionID: progressSessionID
        )

        loadDanmaku(for: episode)
    }

    func downloadEpisodes(_ episodes: [AnimeDetail.AnimeEpisodeItem], from sourceIndex: Int) {
        guard sourceResults.indices.contains(sourceIndex) else { return }
        let source = sourceResults[sourceIndex]
        let downloadAnime = downloadContext(for: source)
        for episode in episodes {
            AnimeDownloadEngine.shared.enqueueEpisode(anime: downloadAnime, source: source.rule, episode: episode)
        }
    }

    /// 下载任务在解析前即落盘；解析、暂停和恢复统一由下载引擎持有。
    func downloadEpisode(_ episode: AnimeDetail.AnimeEpisodeItem, from sourceIndex: Int) async {
        guard sourceResults.indices.contains(sourceIndex) else { return }
        let source = sourceResults[sourceIndex]
        AnimeDownloadEngine.shared.enqueueEpisode(anime: downloadContext(for: source), source: source.rule, episode: episode)
    }

    private func downloadContext(for source: SourceSearchResult) -> AnimeSearchResult {
        let detailURL = source.selectedItem.map {
            source.rule.chapterMode == .api ? $0.src : $0.fullURL(baseURL: source.rule.baseURL)
        } ?? ""
        return AnimeSearchResult(id: anime.id, title: anime.title, coverURL: anime.coverURL,
                                 detailURL: detailURL, sourceId: source.id, sourceName: source.rule.name,
                                 latestEpisode: anime.latestEpisode, rating: anime.rating)
    }

    /// 设置播放器并恢复进度
    /// 清理播放器但不重置 currentEpisode（用于切换剧集时）
    private func cleanupPlayerOnly() {
        directHLSRelay?.stop()
        directHLSRelay = nil
        PlaybackProgressCache.shared.stopTracking(sessionID: progressSessionID)
        readyForSync = false
        currentTime = 0
        totalDuration = 0
        currentProgress = 0
        currentPlayURL = nil
        currentStartTime = 0
        isPlaying = false
        isBuffering = false
        // 恢复系统息屏/休眠
        SleepPreventer.shared.stopPreventingSleep(sessionID: progressSessionID)
        // 清理所有播放器相关的 Combine 订阅，防止切换剧集时堆积
        cancellables.removeAll()
        // 注意：不重置 currentEpisode，保留当前播放的剧集信息
        
        // 取消弹幕加载
        danmakuTask?.cancel()
        danmakuTask = nil
        danmakuList = []
        danmakuManualSourceActive = false
    }

    /// 使用原生播放器设置播放器
    private func setupPlayer(with url: URL, episode: AnimeDetail.AnimeEpisodeItem, rule: AnimeRule, useDirectHLS: Bool) async {
        cleanupPlayerOnly()
        let playURL: URL
        if useDirectHLS {
            let requestID = playbackRequestID
            do {
                guard let host = url.host else { throw URLError(.badURL) }
                let relay = try DirectHLSRelay(mediaHost: host, headers: currentHTTPHeaders)
                directHLSRelay = relay
                playURL = try await relay.start(at: url)
                guard playbackRequestID == requestID, directHLSRelay === relay, !Task.isCancelled else {
                    relay.stop()
                    return
                }
                // Only the relay needs the origin headers; never send them to the loopback URL.
                currentHTTPHeaders = [:]
            } catch {
                guard playbackRequestID == requestID else { return }
                directHLSRelay?.stop()
                directHLSRelay = nil
                videoError = t("页面加载失败，请重试或切换线路")
                return
            }
        } else { playURL = url }
        
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
        
        hasPlaybackPosition = false
        self.currentStartTime = recoveryStartTime ?? startTime
        recoveryStartTime = nil
        self.currentPlayURL = playURL
        playbackID = UUID()
        self.isPlaying = false
        self.isBuffering = true
        self.videoError = nil
        finishedPlaybackID = nil
        didSkipOpening = false
        didSkipEnding = false
        seekRequest = nil

        print("[AnimeDetailViewModel] 开始播放 host=\(url.host ?? "local")")

        // 开始跟踪播放进度
        PlaybackProgressCache.shared.startTracking(
            animeId: anime.id,
            animeTitle: anime.title,
            episode: episode,
            sourceId: rule.id,
            sourceName: rule.name,
            coverURL: anime.coverURL,
            sessionID: progressSessionID
        )

        // 加载弹幕
        loadDanmaku(for: episode)
    }

    // MARK: - 播放器状态回调（由 View 调用）

    func handlePlayerState(_ state: PlaybackState) {
        observedPlayerState = (playbackID, state)
        switch state {
        case .readyToPlay:
            readyForSync = true
            if let pendingRemoteSeek {
                seekRequest = pendingRemoteSeek
                self.pendingRemoteSeek = nil
            }
            print("[AnimeDetailViewModel] ✅ 播放器状态: readyToPlay")
            isBuffering = false
            videoError = nil // 播放成功时清除之前的错误提示
            SleepPreventer.shared.startPreventingSleep(sessionID: progressSessionID)
        case .buffering:
            print("[AnimeDetailViewModel] ⏳ 播放器状态: buffering")
            isBuffering = true
        case .paused:
            print("[AnimeDetailViewModel] ⏸️ 播放器状态: paused")
            isPlaying = false
            isBuffering = false
            SleepPreventer.shared.stopPreventingSleep(sessionID: progressSessionID)
        case .failed(let msg):
            readyForSync = false
            print("[AnimeDetailViewModel] ❌ 播放器状态: error - \(msg)")
            videoError = msg
            isPlaying = false
            isBuffering = false
            SleepPreventer.shared.stopPreventingSleep(sessionID: progressSessionID)
        case .idle, .loading:
            break
        case .playing:
            readyForSync = true
            isPlaying = true
            isBuffering = false
            videoError = nil // 播放成功时清除之前的错误提示
            if let sourceID = currentSourceID, let episode = currentEpisode, currentPlayURL?.isFileURL != true {
                verifiedPlaybackEpisodes[sourceID, default: []].insert(episode.id)
                AnimeSourceReputationStore.shared.recordSuccess(sourceID: sourceID)
            }
            SleepPreventer.shared.startPreventingSleep(sessionID: progressSessionID)
        case .finished:
            isPlaying = false
            isBuffering = false
            SleepPreventer.shared.stopPreventingSleep(sessionID: progressSessionID)
            if totalDuration > 0 { handlePlayerProgress(currentTime: totalDuration, totalTime: totalDuration) }
            if enhancementSettings.autoPlayNext { scheduleNextEpisode() }
        }
        publishSyncPlayState(force: true)
    }

    private func publishSyncPlayState(force: Bool = false) {
        guard readyForSync, let episode = currentEpisode else { return }
        syncPlay.bangumiID = bangumiDetail?.id
        syncPlay.updateLocalPlayback(isPlaying: isPlaying, position: currentTime,
                                    episodeNumber: episode.episodeNumber, title: anime.title, force: force)
    }

    func consumeSeekRequest(_ id: UUID) {
        if seekRequest?.id == id { seekRequest = nil }
    }

    func handlePlayerProgress(currentTime: TimeInterval, totalTime: TimeInterval) {
        guard currentEpisode != nil, currentTime.isFinite, totalTime.isFinite,
              currentTime >= 0, totalTime >= 0 else { return }
        // 续播seek尚未落地时的初始零点不覆盖已有续播位置。
        if !hasPlaybackPosition, currentStartTime > 0, currentTime == 0 { return }
        if currentTime > 0 || (currentStartTime == 0 && totalTime > 0) { hasPlaybackPosition = true }
        self.currentTime = currentTime
        self.totalDuration = totalTime
        let progress = totalTime > 0 ? min(1, currentTime / totalTime) : 0
        
        // 同时更新 AnimeProgressStore（每5%或完成时保存一次）
        if let currentEpisode = currentEpisode {
            let shouldSave = Int(progress * 20) != Int(self.currentProgress * 20)
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
        PlaybackProgressCache.shared.updateProgress(currentTime: currentTime, duration: totalTime, sessionID: progressSessionID)
        publishSyncPlayState()
        guard enhancementSettings.skipOpeningEnding, totalTime > 0,
              isPlaying || isBuffering else { return }
        let opening = enhancementSettings.openingSeconds
        let ending = enhancementSettings.endingSeconds
        // 短片不应用固定时长，避免把整段内容跳光。
        guard totalTime > opening + ending + 60 else { return }
        if !didSkipOpening {
            didSkipOpening = true
            if currentTime < opening, opening > 0 {
                seekRequest = PlaybackSeekRequest(time: opening, resume: isPlaying || isBuffering)
            }
        }
        if !didSkipEnding, ending > 0, currentTime >= totalTime - ending, currentTime < totalTime - 0.5 {
            didSkipEnding = true
            if !enhancementSettings.autoPlayNext || !scheduleNextEpisode() {
                seekRequest = PlaybackSeekRequest(time: totalTime, resume: false)
            }
        }
    }

    func handlePlayerFinish(error: Error?) {
        isPlaying = false
        isBuffering = false
        SleepPreventer.shared.stopPreventingSleep(sessionID: progressSessionID)
        if let error = error {
            videoError = String(format: t("播放失败: %@"), String(describing: error.localizedDescription))
            print("[AnimeDetailViewModel] ❌ 播放完成(出错): \(error.localizedDescription)")
        } else {
            print("[AnimeDetailViewModel] ✅ 播放正常完成")
        }
    }

    private var cancellables = Set<AnyCancellable>()

    /// 停止播放并保存进度
    func stopPlayback() {
        playbackTransitionTask?.cancel()
        playbackTransitionTask = nil
        playbackID = UUID()
        playbackRequestID = UUID()
        playbackExtractor.cancel()
        directHLSRelay?.stop()
        directHLSRelay = nil
        isLoadingVideo = false
        currentSourceID = nil
        currentRoadID = nil
        readyForSync = false
        pendingRemoteSeek = nil
        seekRequest = nil
        finishedPlaybackID = nil
        didSkipOpening = false
        didSkipEnding = false
        // 保存最终进度到 AnimeProgressStore
        if let currentEpisode = currentEpisode, hasPlaybackPosition {
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
        
        PlaybackProgressCache.shared.stopTracking(sessionID: progressSessionID)
        readyForSync = false
        currentTime = 0
        totalDuration = 0
        currentProgress = 0
        currentPlayURL = nil
        currentStartTime = 0
        isPlaying = false
        isBuffering = false
        // 恢复系统息屏/休眠
        SleepPreventer.shared.stopPreventingSleep(sessionID: progressSessionID)
        // 清理所有播放器相关的 Combine 订阅
        cancellables.removeAll()
        currentEpisode = nil
        currentTime = 0
        totalDuration = 0
        currentProgress = 0
        hasPlaybackPosition = false

        // 取消弹幕加载
        danmakuTask?.cancel()
        danmakuTask = nil
        danmakuList = []
        danmakuManualSourceActive = false
    }

    /// 前台窗口释放时使用：保留收藏/偏好等持久状态，清掉播放页的大对象和临时数据。
    func releaseForegroundMemory() {
        Self.logger.notice("source_state_release sources=\(self.sourceResults.count, privacy: .public) requests=\(self.sourceRequestIDs.count, privacy: .public)")
        playbackTransitionTask?.cancel()
        playbackTransitionTask = nil
        syncPlay.disconnect()
        stopPlayback()
        downloadExtractors.values.forEach { $0.cancel() }
        downloadExtractors.removeAll()
        resolvingDownloads.removeAll()

        sourceRequestIDs.removeAll()
        availableRules.removeAll(keepingCapacity: false)
        sourceResults.removeAll(keepingCapacity: false)
        videoSources.removeAll(keepingCapacity: false)
        bangumiDetail = nil
        bangumiEpisodes.removeAll(keepingCapacity: false)
        danmakuList.removeAll(keepingCapacity: false)
        captchaVerificationSession = nil
        aliasSearchRule = nil
        aliasSearchText = ""
        showAliasSearchSheet = false

        selectedSourceIndex = 0
        isLoadingVideo = false
        isBuffering = false
        isLoadingDanmaku = false
        isLoadingBangumi = false
        isLoadingRules = false
        videoError = nil
        showPlayerWindow = false
        currentProgress = 0
        currentTime = 0
        totalDuration = 0
        isInitialLoadComplete = false
        frozenSourceOrder.removeAll(keepingCapacity: false)
        verifiedPlaybackEpisodes.removeAll(keepingCapacity: false)
        rulesLoadTask?.cancel()
        rulesLoadTask = nil
    }

    // MARK: - 弹幕功能

    /// 加载弹幕（参考 Kazumi 的弹幕获取逻辑）
    func loadDanmaku(for episode: AnimeDetail.AnimeEpisodeItem) {
        // 取消之前的任务
        danmakuTask?.cancel()
        danmakuList = []
        danmakuError = nil

        guard danmakuSettings.isEnabled else { return }

        // 未配置弹弹play开放平台凭证时给出可行动的提示，而不是伪装成网络失败。
        guard DanmakuCredentials.isConfigured else {
            danmakuError = t("anime.player.danmakuAuthMissing")
            return
        }

        danmakuTask = Task {
            let manualID = await AnimeDanmakuCache.shared.manualEpisodeID(animeId: anime.id, episodeNumber: episode.episodeNumber)
            guard !Task.isCancelled, currentEpisode?.id == episode.id else { return }
            danmakuManualSourceActive = manualID != nil
            await fetchDanmakuInternal(episode: episode)
        }
    }

    /// 重试当前集弹幕（弹幕面板「重新加载」按钮调用）。
    func retryDanmakuLoad() {
        guard let episode = currentEpisode else { return }
        loadDanmaku(for: episode)
    }

    private func fetchDanmakuInternal(episode: AnimeDetail.AnimeEpisodeItem) async {
        let expectedPlaybackID = playbackID
        isLoadingDanmaku = true
        danmakuError = nil
        defer { if playbackID == expectedPlaybackID { isLoadingDanmaku = false } }
        do {
            var comments: [Danmaku] = []
            if let cached = await AnimeDanmakuCache.shared.cached(animeId: anime.id, episodeNumber: episode.episodeNumber) {
                comments = cached
            } else if let manualID = await AnimeDanmakuCache.shared.manualEpisodeID(animeId: anime.id, episodeNumber: episode.episodeNumber) {
                comments = try await DanmakuService.shared.getDanmaku(episodeId: manualID)
            } else {
                // Bangumi 详情可能仍在加载：短暂等待映射依据就绪，避免落到标题搜索匹配错番。
                if bangumiDetail == nil, isLoadingBangumi, Int(anime.id) != nil {
                    for _ in 0..<20 {
                        try Task.checkCancellation()
                        if bangumiDetail != nil || !isLoadingBangumi { break }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                if let bangumiID = bangumiDetail?.id ?? Int(anime.id.replacingOccurrences(of: "bangumi_", with: "")) {
                    comments = (try? await DanmakuService.shared.fetchDanmakuByBangumiId(
                        bangumiId: bangumiID, episodeNumber: episode.episodeNumber)) ?? []
                }
                try Task.checkCancellation()
                if comments.isEmpty {
                    comments = try await DanmakuService.shared.fetchDanmakuSmart(
                        animeTitle: cleanedDanmakuSearchTitle, episodeNumber: episode.episodeNumber)
                }
            }
            guard !Task.isCancelled, playbackID == expectedPlaybackID, currentEpisode?.id == episode.id else { return }
            danmakuList = comments
            if danmakuSettings.cacheEnabled, !comments.isEmpty {
                await AnimeDanmakuCache.shared.store(comments, animeId: anime.id, episodeNumber: episode.episodeNumber)
            }
            if comments.isEmpty { danmakuError = t("anime.player.danmakuNoMatch") }
        } catch {
            guard !Task.isCancelled, playbackID == expectedPlaybackID else { return }
            danmakuError = (error as? DanmakuError) == .authenticationRequired
                ? t("anime.player.danmakuAuthMissing")
                : t("anime.player.danmakuLoadFailed")
        }
    }

    /// 弹弹play标题搜索用的净化标题（去标点/季数后缀，提高命中率）。
    private var cleanedDanmakuSearchTitle: String {
        cleanSearchQuery(anime.title)
    }

    func selectDanmakuEpisode(_ selected: DanmakuEpisode) {
        guard let episode = currentEpisode else { return }
        showDanmakuSourcePicker = false
        guard DanmakuCredentials.isConfigured else {
            danmakuError = t("anime.player.danmakuAuthMissing")
            return
        }
        danmakuTask?.cancel()
        danmakuTask = Task { [weak self] in
            guard let self else { return }
            let expectedID = self.playbackID
            guard !Task.isCancelled, self.currentEpisode?.id == episode.id else { return }
            self.danmakuList = []
            self.danmakuError = nil
            self.isLoadingDanmaku = true
            defer { if self.playbackID == expectedID { self.isLoadingDanmaku = false } }
            do {
                await AnimeDanmakuCache.shared.setManualEpisodeID(selected.episodeId, animeId: self.anime.id, episodeNumber: episode.episodeNumber)
                guard !Task.isCancelled, self.playbackID == expectedID else { return }
                self.danmakuManualSourceActive = true
                let comments = try await DanmakuService.shared.getDanmaku(episodeId: selected.episodeId)
                guard !Task.isCancelled, self.playbackID == expectedID else { return }
                await AnimeDanmakuCache.shared.store(comments, animeId: self.anime.id, episodeNumber: episode.episodeNumber)
                guard !Task.isCancelled, self.playbackID == expectedID else { return }
                self.danmakuList = comments
                self.danmakuError = comments.isEmpty ? t("anime.player.danmakuNoMatch") : nil
            } catch {
                guard !Task.isCancelled, self.playbackID == expectedID else { return }
                self.danmakuError = (error as? DanmakuError) == .authenticationRequired
                    ? t("anime.player.danmakuAuthMissing")
                    : t("anime.player.danmakuLoadFailed")
            }
        }
    }

    /// 切换弹幕开关
    func toggleDanmaku() {
        var settings = danmakuSettings
        settings.isEnabled.toggle()
        updateDanmakuSettings(settings)
    }

    /// 更新弹幕设置
    func updateDanmakuSettings(_ settings: DanmakuSettings) {
        let wasEnabled = danmakuSettings.isEnabled
        danmakuSettings = settings
        if settings.isEnabled && !wasEnabled, let episode = currentEpisode {
            loadDanmaku(for: episode)
        } else if !settings.isEnabled {
            danmakuTask?.cancel()
            isLoadingDanmaku = false
            danmakuList = []
            danmakuError = nil
        }

        // 保存到 UserDefaults
        if let encoded = try? JSONEncoder().encode(settings) {
            WaifuXPreferences.shared.set(encoded, forKey: "danmakuSettings")
        }
    }

    /// 加载弹幕设置
    func loadDanmakuSettings() {
        if let data = WaifuXPreferences.shared.data(forKey: "danmakuSettings"),
           let settings = try? JSONDecoder().decode(DanmakuSettings.self, from: data) {
            danmakuSettings = settings
        }
    }
    
    // MARK: - 播放器增强设置
    
    func updateEnhancementSettings(_ settings: PlayerEnhancementSettings) {
        enhancementSettings = settings
        if let encoded = try? JSONEncoder().encode(settings) {
            WaifuXPreferences.shared.set(encoded, forKey: "playerEnhancementSettings")
        }
    }
    
    func loadEnhancementSettings() {
        if let data = WaifuXPreferences.shared.data(forKey: "playerEnhancementSettings"),
           let settings = try? JSONDecoder().decode(PlayerEnhancementSettings.self, from: data) {
            enhancementSettings = settings
        }
    }

    // MARK: - 获取当前选中的源结果

    var currentSourceResult: SourceSearchResult? {
        guard sourceResults.indices.contains(selectedSourceIndex) else { return nil }
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
