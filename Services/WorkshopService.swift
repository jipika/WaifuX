import Foundation
import AppKit
import SwiftSoup
import WebKit

// MARK: - Workshop 并发下载限制器
/// Steam 后端会对同一账号的同时登录/下载请求进行限流（RateLimitExceeded），
/// 因此需要控制并发数。实测超过 2 个同时进行的 Workshop 下载即可能触发限流。
///
/// ⚠️ 使用轮询而非 Continuation 实现排队，原因：
/// 如果用 `withCheckedContinuation` 在满负荷时挂起调用方，当用户在
/// 排队等待期间取消下载任务时，continuation 会泄露在 waiters 数组中，
/// 导致内存泄漏和运行时 "SWIFT TASK CONTINUATION MISUSE" 警告。
/// 轮询方案通过 Task.sleep 等待，取消时正确抛出 CancellationError，
/// 不存在延续泄露的风险。
private actor WorkshopDownloadLimiter {
    /// 最大同时下载数（与内嵌 SteamKit2 服务的 maxConcurrentDownloads=3 对齐）
    private let maxConcurrent = 3
    /// 当前活跃下载数
    private var activeCount = 0
    /// 当前正在轮询等待的任务数（近似排队深度）
    private var waitCount = 0
    /// 轮询间隔
    private let pollInterval: UInt64 = 500_000_000 // 0.5s

    /// 获取一个下载槽位；若已满则每隔 0.5s 轮询一次
    func acquire() async throws {
        while true {
            try Task.checkCancellation()
            if activeCount < maxConcurrent {
                activeCount += 1
                return
            }
            waitCount += 1
            do {
                try await Task.sleep(nanoseconds: pollInterval)
                waitCount = max(0, waitCount - 1)
            } catch {
                waitCount = max(0, waitCount - 1)
                throw error
            }
        }
    }

    /// 释放一个下载槽位
    func release() {
        activeCount = max(0, activeCount - 1)
    }

    /// 当前排队（轮询等待）的任务数
    func queuedCount() -> Int { waitCount }

    /// 当前活跃下载数
    func currentActiveCount() -> Int { activeCount }
}

// MARK: - Workshop Service
///
/// 处理 Wallpaper Engine Steam 创意工坊的搜索和下载
@MainActor
class WorkshopService: ObservableObject {
    static let shared = WorkshopService()

    // MARK: - Published State

    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchResults: [WorkshopWallpaper] = []
    @Published var hasMorePages = false
    /// Workshop 下载排队数量（超过并发上限时排队等待）
    @Published var workshopQueuedCount: Int = 0

    // MARK: - Configuration

    private let wallpaperEngineAppID = "431960"
    private let steamAPIBase = "https://api.steampowered.com"
    private let authorPageSize = 30
    private var currentPage = 1
    private let pageSize = 20

    /// Workshop 并发下载限制器（全局，限制同时进行的下载任务数）
    private let downloadLimiter = WorkshopDownloadLimiter()

    /// 主窗口长期隐藏后释放 Workshop 浏览结果；后台下载/动态壁纸渲染不依赖这些前台列表。
    func clearForegroundState() {
        isLoading = false
        errorMessage = nil
        searchResults.removeAll()
        hasMorePages = false
        currentPage = 1
    }

    // MARK: - 按作者查询 Workshop 物品

    /// 从 Steam Workshop 作者页面抓取壁纸列表
    /// - Parameters:
    ///   - steamID: Steam 64位数字 ID
    ///   - page: 页码（从 1 开始）
    /// - Returns: 壁纸列表
    func fetchByAuthor(steamID: String, page: Int = 1) async throws -> [WorkshopWallpaper] {
        let profilePath = steamProfilePath(for: steamID)
        var components = URLComponents(string: "https://steamcommunity.com\(profilePath)/myworkshopfiles/")
        components?.queryItems = [
            URLQueryItem(name: "appid", value: wallpaperEngineAppID),
            // 显式 myfiles + mostrecent，避免默认视图/排序导致翻页异常
            URLQueryItem(name: "browsefilter", value: "myfiles"),
            URLQueryItem(name: "sort", value: "mostrecent"),
            URLQueryItem(name: "p", value: String(max(page, 1))),
            // Steam 作者页使用 numperpage，不是 Workshop 搜索页的 num_per_page。
            URLQueryItem(name: "numperpage", value: String(authorPageSize))
        ]
        guard let url = components?.url else {
            throw WorkshopError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let data = try await NetworkService.shared.fetchData(request: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw WorkshopError.apiError("无法解析 HTML 响应")
        }

        // 先尝试从 SSR JSON 提取
        var wallpapers = extractFromJSON(html)
        if !wallpapers.isEmpty {
            AppLogger.info(.media, "fetchByAuthor used JSON/SSR extraction: \(wallpapers.count) items")
            // 补充作者名和头像
            let authorMap = extractAuthorMapFromHTML(html)
            if !authorMap.isEmpty {
                wallpapers = wallpapers.map { item in
                    guard let author = authorMap[item.id] else { return item }
                    return WorkshopWallpaper(
                        id: item.id,
                        title: item.title,
                        description: item.description,
                        previewURL: item.previewURL,
                        author: mergedAuthor(item.author, author),
                        fileSize: item.fileSize,
                        fileURL: item.fileURL,
                        steamAppID: item.steamAppID,
                        subscriptions: item.subscriptions,
                        favorites: item.favorites,
                        views: item.views,
                        rating: item.rating,
                        type: item.type,
                        tags: item.tags,
                        isAnimatedImage: item.isAnimatedImage,
                        createdAt: item.createdAt,
                        updatedAt: item.updatedAt
                    )
                }
            }
            // 作者页也补齐 API 元数据，保持和搜索页一致，避免列表缺尺寸/类型/统计字段。
            do {
                wallpapers = try await enrichWithAPIDetails(wallpapers)
            } catch {
                AppLogger.error(.media, "Author page API enrichment failed", metadata: ["steamID": steamID, "error": "\(error)"])
            }

            let profile = try? await fetchSteamProfile(profileID: steamID)
            wallpapers = wallpapers.map { item in
                let authorName = bestAuthorName(item.author.name, fallback: profile?.name ?? item.author.steamID)
                return WorkshopWallpaper(
                    id: item.id,
                    title: item.title,
                    description: item.description,
                    previewURL: item.previewURL,
                    author: WorkshopAuthor(
                        steamID: profile?.steamID ?? steamID,
                        name: authorName,
                        avatarURL: item.author.avatarURL ?? profile?.avatarURL
                    ),
                    fileSize: item.fileSize,
                    fileURL: item.fileURL,
                    steamAppID: item.steamAppID,
                    subscriptions: item.subscriptions,
                    favorites: item.favorites,
                    views: item.views,
                    rating: item.rating,
                    type: item.type,
                    tags: item.tags,
                    isAnimatedImage: item.isAnimatedImage,
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt
                )
            }
            return wallpapers
        }

        // 降级：从 HTML DOM 解析
        AppLogger.info(.media, "fetchByAuthor falling back to HTML DOM parsing")
        let doc = try SwiftSoup.parse(html)
        let items = try doc.select(".workshopItem, .workshopItemWrapper, [id*='sharedfiles_']")
        var parsed = try items.compactMap { try parseWorkshopItem($0) }
        if parsed.isEmpty {
            parsed = try parseModernWorkshopHTML(doc)
        }
        do {
            parsed = try await enrichWithAPIDetails(parsed)
        } catch {
            AppLogger.error(.media, "Author HTML API enrichment failed", metadata: ["steamID": steamID, "error": "\(error)"])
        }
        let profile = try? await fetchSteamProfile(profileID: steamID)
        return parsed.map { item in
            WorkshopWallpaper(
                id: item.id,
                title: item.title,
                description: item.description,
                previewURL: item.previewURL,
                author: WorkshopAuthor(
                    steamID: profile?.steamID ?? steamID,
                    name: bestAuthorName(item.author.name, fallback: profile?.name ?? steamID),
                    avatarURL: item.author.avatarURL ?? profile?.avatarURL
                ),
                fileSize: item.fileSize,
                fileURL: item.fileURL,
                steamAppID: item.steamAppID,
                subscriptions: item.subscriptions,
                favorites: item.favorites,
                views: item.views,
                rating: item.rating,
                type: item.type,
                tags: item.tags,
                isAnimatedImage: item.isAnimatedImage,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt
            )
        }
    }

    // MARK: - 获取已订阅的 Workshop 物品

    private var steamCommunityUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
    }
    /// Mirage 式订阅同步：走 WaifuX Steam 服务（SteamKit2 协议层）精确分页拉订阅，
    /// 再用公开 Web API 富化详情。不需要 WebView cookie，也不受 steamcommunity
    /// 页面改版影响。仅在 Steam 服务已登录时可用。
    private func fetchAllSubscriptionsViaSteamService() async throws -> [WorkshopWallpaper] {
        let manager = SteamServiceManager.shared
        guard manager.isLoggedIn else {
            throw SteamServiceError.notAuthenticated
        }

        var allItems: [WorkshopWallpaper] = []
        var seenIDs = Set<String>()
        var startIndex = 0

        // 防御性上限：订阅数远超此值只可能是服务端返回异常，避免死循环。
        while startIndex < 20_000 {
            let page = try await manager.fetchSubscriptions(startIndex: startIndex)
            let ids = page.items.map(\.workshopID).filter { seenIDs.insert($0).inserted }
            if !ids.isEmpty {
                let details = try await fetchPublishedFileDetails(ids: ids)
                let detailMap = Dictionary(details.map { ($0.publishedfileid, $0) },
                                           uniquingKeysWith: { first, _ in first })
                for id in ids {
                    guard let detail = detailMap[id] else { continue }
                    let placeholder = WorkshopWallpaper(
                        id: id,
                        title: "",
                        description: nil,
                        previewURL: nil,
                        author: WorkshopAuthor(steamID: detail.creator, name: "Unknown", avatarURL: nil),
                        fileSize: nil,
                        fileURL: nil,
                        steamAppID: String(detail.consumer_app_id ?? 431960),
                        subscriptions: nil,
                        favorites: nil,
                        views: nil,
                        rating: nil,
                        type: .unknown,
                        tags: [],
                        isAnimatedImage: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                    allItems.append(WorkshopWallpaper(base: placeholder, detail: detail))
                }
            }
            if page.items.isEmpty { break }
            startIndex = page.startIndex + page.items.count
            if startIndex >= page.total { break }
        }

        AppLogger.info(.media, "fetchAllSubscriptionsViaSteamService total: \(allItems.count) items")
        return allItems
    }

    /// 获取用户所有已订阅的壁纸（自动翻页）
    /// 只走 Steam 服务协议层同步：下载本身依赖服务登录会话，
    /// 网页爬取即使拿到列表也无法下载，回退没有意义。
    /// - Parameter steamID: Steam 64位数字 ID（服务已登录时不依赖，用会话自身 SteamId）
    /// - Returns: 所有已订阅壁纸
    func fetchAllSubscriptions(steamID: String) async throws -> [WorkshopWallpaper] {
        let items = try await fetchAllSubscriptionsViaSteamService()
        AppLogger.info(.media, "fetchAllSubscriptions total: \(items.count) items (Steam service)")
        return items
    }

    // MARK: - Search

    func search(params: WorkshopSearchParams) async throws -> WorkshopSearchResponse {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
            currentPage = params.page
        }

        defer {
            isLoading = false
        }

        let result = try await searchHTML(params: params)
        return result
    }

    private func sortValue(for sort: WorkshopSearchParams.SortOption) -> String {
        // Steam Workshop 2026年4月改版后的 browsesort 参数值
        switch sort {
        case .ranked: return "trend"
        case .updated: return "lastupdated"
        case .created: return "mostrecent"
        case .topRated: return "toprated"
        }
    }

    private func searchHTML(params: WorkshopSearchParams) async throws -> WorkshopSearchResponse {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "appid", value: wallpaperEngineAppID),
            URLQueryItem(name: "searchtext", value: params.query),
            URLQueryItem(name: "child_publishedfileid", value: "0"),
            URLQueryItem(name: "browsesort", value: sortValue(for: params.sortBy)),
            URLQueryItem(name: "section", value: "readytouseitems"),
            URLQueryItem(name: "created_filetype", value: "0"),
            URLQueryItem(name: "excludedtags[]", value: "Preset"),
            URLQueryItem(name: "excludedtags[]", value: "RequiredItem"),
            URLQueryItem(name: "updated_filters", value: "1")
        ]

        // 新版 browse 页面使用 requiredtags[]=Value（无索引）
        var requiredTags: [String] = []
        if let type = params.type {
            switch type {
            case .video: requiredTags.append("Video")
            case .scene: requiredTags.append("Scene")
            case .web: requiredTags.append("Web")
            default: break
            }
        }
        if !params.tags.isEmpty {
            requiredTags.append(contentsOf: params.tags)
        }
        // 新版 browse 页面中内容级别通过 requiredtags[]=Mature/Questionable/Everyone 实现
        // 内容级别由开关控制：开启时放行 Mature，关闭时强制降级为 Everyone
        let effectiveContentLevel = params.contentLevel ?? "Everyone"
        let showAllContent = WaifuXPreferences.shared.bool(forKey: "show_all_workshop_content")
        if effectiveContentLevel == "Everyone" || effectiveContentLevel == "Questionable" || (effectiveContentLevel == "Mature" && showAllContent) {
            requiredTags.append(effectiveContentLevel)
        } else {
            requiredTags.append("Everyone")
        }
        // 分辨率/比例筛选通过 requiredtags[] 发送（Steam Workshop 分辨率以标签形式存在）
        if let resolution = params.resolution {
            requiredTags.append(resolution)
        }
        for tag in requiredTags {
            queryItems.append(URLQueryItem(name: "requiredtags[]", value: tag))
        }

        queryItems.append(URLQueryItem(name: "p", value: String(params.page)))
        queryItems.append(URLQueryItem(name: "num_per_page", value: String(params.pageSize)))

        // 热门趋势排序支持时间范围（days 参数）
        if params.sortBy == .ranked, let days = params.days {
            queryItems.append(URLQueryItem(name: "days", value: String(days)))
        }

        var components = URLComponents(string: workshopBrowseBase)
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw WorkshopError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let data = try await NetworkService.shared.fetchData(request: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw WorkshopError.apiError("无法解析 HTML 响应")
        }

        // 优先从 SSR JSON 或内嵌 JSON 提取（已含完整元数据）
        var wallpapers = extractFromJSON(html)
        if !wallpapers.isEmpty {
            AppLogger.info(.media, "searchHTML used JSON/SSR extraction: \(wallpapers.count) items")
            // JSON/SSR 提取的作者名通常是 Steam ID 或 Unknown，尝试从 HTML DOM 补充
            let authorMap = extractAuthorMapFromHTML(html)
            if !authorMap.isEmpty {
                wallpapers = wallpapers.map { item in
                    guard let author = authorMap[item.id] else { return item }
                    return WorkshopWallpaper(
                        id: item.id,
                        title: item.title,
                        description: item.description,
                        previewURL: item.previewURL,
                        author: mergedAuthor(item.author, author),
                        fileSize: item.fileSize,
                        fileURL: item.fileURL,
                        steamAppID: item.steamAppID,
                        subscriptions: item.subscriptions,
                        favorites: item.favorites,
                        views: item.views,
                        rating: item.rating,
                        type: item.type,
                        tags: item.tags,
                        isAnimatedImage: item.isAnimatedImage,
                        createdAt: item.createdAt,
                        updatedAt: item.updatedAt
                    )
                }
            }
        } else {
            wallpapers = try parseWorkshopHTML(html, page: params.page)
            AppLogger.info(.media, "searchHTML used HTML parsing: \(wallpapers.count) items")
        }

        // 无论数据来源是 JSON/SSR 还是 HTML，都用 Steam Web API 批量补全
        // （JSON 提取可能缺少 vote_data 等字段，API 补全可以兜底）
        if !wallpapers.isEmpty {
            do {
                wallpapers = try await enrichWithAPIDetails(wallpapers)
                AppLogger.info(.media, "API enrichment applied to \(wallpapers.count) items")
            } catch {
                AppLogger.error(.media, "API enrichment failed", metadata: ["error": "\(error)"])
            }
        }

        // Steam Workshop browse 列表页不返回标签/类型，用请求参数做兜底注入
        let enriched = enrichWorkshopItems(wallpapers, params: params)
        // 过滤掉子壁纸/依赖（fileSize == 0 的 API 明确无内容）
        let filtered = enriched.filter { $0.fileSize != 0 }

        return WorkshopSearchResponse(
            items: filtered,
            total: filtered.count,
            page: params.page,
            hasMore: enriched.count >= params.pageSize
        )
    }

    /// 用请求参数给 Workshop 项注入缺失的标签和类型（列表页 HTML 本身不暴露这些信息）
    private func enrichWorkshopItems(_ items: [WorkshopWallpaper], params: WorkshopSearchParams) -> [WorkshopWallpaper] {
        return items.map { item in
            var tags = item.tags
            var type = item.type

            // 注入用户选中的标签
            if !params.tags.isEmpty {
                let existing = Set(tags.map { $0.lowercased() })
                for tag in params.tags where !existing.contains(tag.lowercased()) {
                    tags.append(tag)
                }
            }

            // 注入类型标签并修正 type
            if let paramsType = params.type {
                let typeTag = paramsType.rawValue.capitalized
                if !tags.contains(typeTag) {
                    tags.append(typeTag)
                }
                type = paramsType
            }

            // 如果解析出来是 unknown，但有标签，尝试重新检测
            if type == .unknown, !tags.isEmpty {
                type = WorkshopWallpaper.detectType(fromTags: tags)
            }
            // Wallpaper Engine Workshop 列表页不返回类型，默认绝大多数是视频/动态壁纸
            if type == .unknown {
                type = .video
            }

            return WorkshopWallpaper(
                id: item.id,
                title: item.title,
                description: item.description,
                previewURL: item.previewURL,
                author: item.author,
                fileSize: item.fileSize,
                fileURL: item.fileURL,
                steamAppID: item.steamAppID,
                subscriptions: item.subscriptions,
                favorites: item.favorites,
                views: item.views,
                rating: item.rating,
                type: type,
                tags: tags,
                isAnimatedImage: item.isAnimatedImage,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt
            )
        }
    }

    private let workshopBrowseBase = "https://steamcommunity.com/workshop/browse/"

    // MARK: - HTML Parsing

    private func parseWorkshopHTML(_ html: String, page: Int) throws -> [WorkshopWallpaper] {
        let document = try SwiftSoup.parse(html)
        let elements = try document.select(".workshopItem")

        var wallpapers: [WorkshopWallpaper] = []
        for element in elements {
            if let wallpaper = try? parseWorkshopItem(element) {
                wallpapers.append(wallpaper)
            }
        }

        // 旧版 selector 未命中时，尝试解析新版 React 页面（2024+ 的哈希 class 结构）
        if wallpapers.isEmpty {
            wallpapers = try parseModernWorkshopHTML(document)
        }

        return wallpapers
    }

    /// 解析新版 Steam Workshop React 页面（class 名为哈希，没有 .workshopItem）
    private func parseModernWorkshopHTML(_ document: Document) throws -> [WorkshopWallpaper] {
        let links = try document.select("a[href*=/sharedfiles/filedetails/?id=]")

        var wallpapers: [WorkshopWallpaper] = []
        var seenIDs = Set<String>()

        for link in links {
            guard let img = try? link.select("img[alt][src*=/ugc/]").first() else { continue }

            let href = (try? link.attr("href")) ?? ""
            guard let id = href.components(separatedBy: "id=").last?.components(separatedBy: "&").first, !id.isEmpty else { continue }
            guard !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)

            let title = (try? img.attr("alt")) ?? "Untitled"
            let src = (try? img.attr("src")) ?? ""
            let previewURL = src.isEmpty ? nil : URL(string: src)

            // 向上遍历祖先节点提取作者名（新版 Workshop 页面 class 为哈希，优先找用户资料链接）
            var authorName = "Unknown"
            var current: Element? = link
            for _ in 0..<5 {
                guard let parent = current?.parent() else { break }
                current = parent
                // 策略1：找指向 /profiles/ 或 /id/ 的链接（作者个人页）
                let profileLinks = try? parent.select("a[href*=/profiles/], a[href*=/id/]")
                for profileLink in profileLinks ?? Elements() {
                    let name = (try? profileLink.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !name.isEmpty && name != "Untitled" && !name.contains("http") {
                        authorName = name
                        break
                    }
                }
                if authorName != "Unknown" { break }
                // 策略2：fallback 到旧版文本匹配
                let all = try? parent.select("*")
                for el in all ?? Elements() {
                    let text = (try? el.text()) ?? ""
                    if text.contains("创作者：") || text.contains("Author:") || text.contains("By ") {
                        authorName = text.replacingOccurrences(of: "创作者：", with: "")
                            .replacingOccurrences(of: "Author:", with: "")
                            .replacingOccurrences(of: "By ", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
                if authorName != "Unknown" { break }
            }

            // 提取作者头像 URL
            var authorAvatarURL: URL? = nil
            var avatarEl: Element? = link
            for _ in 0..<5 {
                guard let parent = avatarEl?.parent() else { break }
                avatarEl = parent
                // 尝试从 img 的 srcset/src 取
                if let img = try? parent.select(".playerAvatar img, .playerAvatarMedium img, img.avatar, .playerAvatar picture img").first() {
                    var src = (try? img.attr("srcset")) ?? ""
                    if src.isEmpty { src = (try? img.attr("src")) ?? "" }
                    if src.isEmpty { src = (try? img.attr("data-src")) ?? "" }
                    // srcset 取第一个 URL
                    if let firstURL = src.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) {
                        src = firstURL.components(separatedBy: " ").first ?? firstURL
                    }
                    if !src.isEmpty {
                        var cleanURL = src.components(separatedBy: "?").first ?? src
                        if cleanURL.hasPrefix("//") { cleanURL = "https:" + cleanURL }
                        authorAvatarURL = URL(string: cleanURL)
                    }
                    break
                }
                // 尝试从 picture source 取
                if authorAvatarURL == nil,
                   let sourceEl = try? parent.select(".playerAvatar source, .playerAvatar picture source").first() {
                    var src = (try? sourceEl.attr("srcset")) ?? ""
                    if !src.isEmpty {
                        if let firstURL = src.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) {
                            src = firstURL.components(separatedBy: " ").first ?? firstURL
                        }
                        var cleanURL = src.components(separatedBy: "?").first ?? src
                        if cleanURL.hasPrefix("//") { cleanURL = "https:" + cleanURL }
                        authorAvatarURL = URL(string: cleanURL)
                    }
                    break
                }
            }

            let isAnimatedImage = previewURL?.absoluteString.lowercased().contains(".gif") ?? false
            wallpapers.append(WorkshopWallpaper(
                id: id,
                title: title,
                description: nil,
                previewURL: previewURL,
                author: WorkshopAuthor(steamID: "", name: authorName, avatarURL: authorAvatarURL),
                fileSize: nil,
                fileURL: nil,
                steamAppID: wallpaperEngineAppID,
                subscriptions: nil,
                favorites: nil,
                views: nil,
                rating: nil,
                type: .unknown,
                tags: [],
                isAnimatedImage: isAnimatedImage,
                createdAt: nil,
                updatedAt: nil
            ))
        }

        return wallpapers
    }

    /// 从 HTML DOM 提取作者映射（用于补充 JSON/SSR 提取缺失的作者显示名和头像）
    private func extractAuthorMapFromHTML(_ html: String) -> [String: WorkshopAuthor] {
        guard let document = try? SwiftSoup.parse(html) else { return [:] }
        let links = try? document.select("a[href*=/sharedfiles/filedetails/?id=]")

        var authorMap: [String: WorkshopAuthor] = [:]
        var seenIDs = Set<String>()

        for link in links ?? Elements() {
            let href = (try? link.attr("href")) ?? ""
            guard let id = href.components(separatedBy: "id=").last?.components(separatedBy: "&").first, !id.isEmpty else { continue }
            guard !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)

            var author = WorkshopAuthor(steamID: "", name: "Unknown", avatarURL: nil)
            var current: Element? = link
            for _ in 0..<5 {
                guard let parent = current?.parent() else { break }
                current = parent
                let profileLinks = try? parent.select("a[href*=/profiles/], a[href*=/id/]")
                for profileLink in profileLinks ?? Elements() {
                    let name = (try? profileLink.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !name.isEmpty && name != "Untitled" && !name.contains("http") {
                        author = WorkshopAuthor(
                            steamID: steamID(fromProfileHref: (try? profileLink.attr("href")) ?? ""),
                            name: name,
                            avatarURL: extractAvatarURL(near: parent)
                        )
                        break
                    }
                }
                if author.name != "Unknown" || author.avatarURL != nil { break }
            }

            if author.name != "Unknown" || author.avatarURL != nil || !author.steamID.isEmpty {
                authorMap[id] = author
            }
        }

        return authorMap
    }

    private func mergedAuthor(_ existing: WorkshopAuthor, _ parsed: WorkshopAuthor) -> WorkshopAuthor {
        WorkshopAuthor(
            steamID: !parsed.steamID.isEmpty ? parsed.steamID : existing.steamID,
            name: bestAuthorName(parsed.name, fallback: existing.name),
            avatarURL: parsed.avatarURL ?? existing.avatarURL
        )
    }

    private func bestAuthorName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != "Unknown" {
            return trimmed
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown" : fallback
    }

    private func steamID(fromProfileHref href: String) -> String {
        guard let range = href.range(of: #"/profiles/([0-9]+)"#, options: .regularExpression) else { return "" }
        return String(href[range])
            .replacingOccurrences(of: "/profiles/", with: "")
            .components(separatedBy: "/")
            .first ?? ""
    }

    private func extractAvatarURL(near element: Element) -> URL? {
        let selectors = [
            ".playerAvatar img",
            ".playerAvatarMedium img",
            ".friendBlockAvatar img",
            "img.avatar",
            ".playerAvatar picture img",
            "#HeaderUserAvatar img"
        ]
        for selector in selectors {
            if let img = try? element.select(selector).first(),
               let url = normalizedSteamImageURL(from: (try? img.attr("srcset")) ?? "", fallback: (try? img.attr("src")) ?? "", dataSource: (try? img.attr("data-src")) ?? "") {
                return url
            }
        }
        if let styleElement = try? element.select("[style*=avatars]").first(),
           let url = steamAvatarURL(fromStyle: (try? styleElement.attr("style")) ?? "") {
            return url
        }
        let sourceSelectors = [
            ".playerAvatar source",
            ".playerAvatar picture source",
            "#HeaderUserAvatar source"
        ]
        for selector in sourceSelectors {
            if let source = try? element.select(selector).first(),
               let url = normalizedSteamImageURL(from: (try? source.attr("srcset")) ?? "", fallback: "", dataSource: "") {
                return url
            }
        }
        return nil
    }

    private func normalizedSteamImageURL(from srcset: String, fallback: String, dataSource: String) -> URL? {
        var src = srcset
        if src.isEmpty { src = fallback }
        if src.isEmpty { src = dataSource }
        if let firstURL = src.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines) {
            src = firstURL.components(separatedBy: " ").first ?? firstURL
        }
        var cleanURL = src.components(separatedBy: "?").first ?? src
        if cleanURL.hasPrefix("//") { cleanURL = "https:" + cleanURL }
        return cleanURL.isEmpty ? nil : URL(string: cleanURL)
    }

    private func steamAvatarURL(fromStyle style: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"url\(['"]?([^'")]+avatars[^'")]+)['"]?\)"#, options: []) else {
            return nil
        }
        let range = NSRange(style.startIndex..., in: style)
        guard let match = regex.firstMatch(in: style, options: [], range: range),
              let swiftRange = Range(match.range(at: 1), in: style) else {
            return nil
        }
        var raw = String(style[swiftRange])
        if raw.hasPrefix("//") { raw = "https:" + raw }
        return URL(string: raw)
    }

    private func parseWorkshopItem(_ element: Element) throws -> WorkshopWallpaper? {
        do {
            var id = try element.attr("data-publishedfileid")
            if id.isEmpty {
                if let link = try element.select("a[href*=/sharedfiles/filedetails/?id=]").first() {
                    let href = try link.attr("href")
                    if let extractedID = href.components(separatedBy: "id=").last?.components(separatedBy: "&").first {
                        id = extractedID
                    }
                }
            }
            guard !id.isEmpty else { return nil }

            let title = try element.select(".workshopItemTitle").first()?.text() ??
                       element.select(".workshopItemDetailsTitle").first()?.text() ??
                       element.select("a[href*=/sharedfiles/filedetails]").first()?.text() ??
                       "Untitled"

            var previewURL: URL?
            let imgSelectors = [
                "img.workshopItemPreviewImage",
                ".workshopItemPreviewImage img",
                ".workshopItemPreviewImageHolder img",
                ".publishedfile_preview img",
                "img.preview",
                "img[id^=previewimage]",
                "img[src*=.jpg]",
                "img[src*=.png]",
                "img"
            ]
            for selector in imgSelectors {
                if let img = try element.select(selector).first() {
                    var src = try img.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
                    if src.isEmpty {
                        src = try img.attr("data-src").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if !src.isEmpty {
                        var cleanURL = src.components(separatedBy: "?").first ?? src
                        if cleanURL.hasPrefix("//") {
                            cleanURL = "https:" + cleanURL
                        }
                        previewURL = URL(string: cleanURL)
                        break
                    }
                }
            }

            var subscriptions = 0
            let statsSelectors = [".subscriptionCount", ".subscriptions", "[data-subscriptions]", ".stats"]
            for selector in statsSelectors {
                if let statEl = try element.select(selector).first() {
                    let statText = try statEl.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    subscriptions = parseNumber(statText)
                    break
                }
            }

            var fileSize: Int64? = nil
            let sizeSelectors = [".fileSize", ".file_size", "[data-filesize]"]
            for selector in sizeSelectors {
                if let sizeEl = try element.select(selector).first() {
                    let sizeText = try sizeEl.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    fileSize = parseFileSize(sizeText)
                    break
                }
            }

            var authorName = "Unknown"
            var authorAvatarURL: URL? = nil
            let authorSelectors = [
                ".workshopItemAuthorName",
                ".author",
                ".workshopAuthor",
                "[data-author]",
                ".creator"
            ]
            for selector in authorSelectors {
                if let authorEl = try element.select(selector).first() {
                    authorName = try authorEl.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    authorName = authorName.replacingOccurrences(of: "作者：", with: "")
                        .replacingOccurrences(of: "Author:", with: "")
                        .replacingOccurrences(of: "By ", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // 提取作者头像 URL（playerAvatar 下的 img，兼容 srcset 和 picture 元素）
                    if let avatarImg = try authorEl.select(".playerAvatar img, .playerAvatarMedium img, img.avatar, .playerAvatar picture img, #HeaderUserAvatar img").first() {
                        var src = try avatarImg.attr("srcset")
                        if src.isEmpty {
                            src = try avatarImg.attr("src")
                        }
                        if src.isEmpty {
                            src = try avatarImg.attr("data-src")
                        }
                        // 从 srcset 中取第一个 URL（逗号分隔）
                        if let firstURL = src.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) {
                            src = firstURL.components(separatedBy: " ").first ?? firstURL
                        }
                        if !src.isEmpty {
                            var cleanURL = src.components(separatedBy: "?").first ?? src
                            if cleanURL.hasPrefix("//") {
                                cleanURL = "https:" + cleanURL
                            }
                            authorAvatarURL = URL(string: cleanURL)
                        }
                    }
                    // 如果上面没取到，尝试从 source[srcset] 拿
                    if authorAvatarURL == nil,
                       let sourceEl = try authorEl.select(".playerAvatar source, .playerAvatar picture source, #HeaderUserAvatar source").first() {
                        var src = try sourceEl.attr("srcset")
                        if !src.isEmpty {
                            if let firstURL = src.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) {
                                src = firstURL.components(separatedBy: " ").first ?? firstURL
                            }
                            var cleanURL = src.components(separatedBy: "?").first ?? src
                            if cleanURL.hasPrefix("//") { cleanURL = "https:" + cleanURL }
                            authorAvatarURL = URL(string: cleanURL)
                        }
                    }
                    break
                }
            }

            var tags: [String] = []
            let tagElements = try element.select(".workshopTags a, .tags a, .tag, [data-tag]")
            for tagEl in tagElements {
                let tagText = try tagEl.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if !tagText.isEmpty {
                    tags.append(tagText)
                }
            }

            let author = WorkshopAuthor(
                steamID: "",
                name: authorName,
                avatarURL: authorAvatarURL
            )

            let isAnimatedImage = previewURL?.absoluteString.lowercased().contains(".gif") ?? false

            return WorkshopWallpaper(
                id: id,
                title: title,
                description: nil,
                previewURL: previewURL,
                author: author,
                fileSize: fileSize,
                fileURL: nil,
                steamAppID: wallpaperEngineAppID,
                subscriptions: subscriptions,
                favorites: nil,
                views: nil,
                rating: nil,
                type: WorkshopWallpaper.detectType(fromTags: tags),
                tags: tags,
                isAnimatedImage: isAnimatedImage,
                createdAt: nil,
                updatedAt: nil
            )
        } catch {
            AppLogger.error(.media, "Error parsing item", metadata: ["error": "\(error)"])
            return nil
        }
    }

    private func extractFromJSON(_ html: String) -> [WorkshopWallpaper] {
        var wallpapers: [WorkshopWallpaper] = []

        if let ssrItems = extractFromSSRJSON(html), !ssrItems.isEmpty {
            wallpapers = ssrItems
            AppLogger.info(.media, "Extracted \(wallpapers.count) items from SSR dehydrated JSON")
            return wallpapers
        }

        let patterns = [
            #"var\s+rgPublishedFileDetails\s*=\s*(\[.*?\]);"#,
            #"var\s+g_publishedFileDetails\s*=\s*(\[.*?\]);"#,
            #"rgPublishedFileDetails\s*=\s*(\[.*?\]);"#,
            #"g_publishedFileDetails\s*=\s*(\[.*?\]);"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, options: [], range: range),
                  let jsonRange = Range(match.range(at: 1), in: html) else { continue }

            let jsonString = String(html[jsonRange])
            guard let jsonData = jsonString.data(using: .utf8) else { continue }

            do {
                let items = try JSONDecoder().decode([SteamHTMLWorkshopItem].self, from: jsonData)
                for item in items {
                    let isAnimatedImage = (item.preview_url ?? "").lowercased().contains(".gif")
                    wallpapers.append(WorkshopWallpaper(
                        id: item.publishedfileid,
                        title: item.title,
                        description: item.description,
                        previewURL: URL(string: item.preview_url ?? ""),
                        author: WorkshopAuthor(steamID: item.creator ?? "", name: "Unknown", avatarURL: nil),
                        fileSize: nil,
                        fileURL: nil,
                        steamAppID: wallpaperEngineAppID,
                        subscriptions: item.subscriptions,
                        favorites: item.favorited,
                        views: item.views,
                        rating: item.vote_data?.score,
                        type: WorkshopWallpaper.detectType(fromTags: item.tags?.map { $0.tag } ?? []),
                        tags: item.tags?.map { $0.tag } ?? [],
                        isAnimatedImage: isAnimatedImage,
                        createdAt: nil,
                        updatedAt: nil
                    ))
                }
                if !wallpapers.isEmpty { break }
            } catch {
                AppLogger.error(.media, "Failed to decode embedded JSON", metadata: ["error": "\(error)"])
            }
        }

        return wallpapers
    }

    private func extractFromSSRJSON(_ html: String) -> [WorkshopWallpaper]? {
        guard let scriptRange = html.range(of: "<script") else { return nil }
        var searchStart = scriptRange.upperBound
        var scriptContent: String?

        while let nextScriptStart = html.range(of: "<script", range: searchStart..<html.endIndex) {
            guard let scriptEnd = html.range(of: "</script>", range: nextScriptStart.upperBound..<html.endIndex) else { break }
            let content = String(html[nextScriptStart.upperBound..<scriptEnd.lowerBound])
            if content.contains("publishedfileid"), !content.hasPrefix("<") {
                if let contentStart = content.range(of: ">") {
                    scriptContent = String(content[contentStart.upperBound...])
                    break
                }
            }
            searchStart = scriptEnd.upperBound
        }

        guard let script = scriptContent else { return nil }

        let resultsSearch = "\\\"results\\\":["
        guard let resultsRange = script.range(of: resultsSearch) else { return nil }
        let arrayStart = script.index(resultsRange.upperBound, offsetBy: -1)

        let chunkStart = arrayStart
        let chunkEnd = script.index(chunkStart, offsetBy: min(120000, script.distance(from: chunkStart, to: script.endIndex)))
        var chunk = String(script[chunkStart..<chunkEnd])

        chunk = chunk.replacingOccurrences(of: "\\\\\\\"", with: "\"")
                     .replacingOccurrences(of: "\\\\\"", with: "\"")
                     .replacingOccurrences(of: "\\\"", with: "\"")

        guard let arrStartIndex = chunk.firstIndex(of: "[") else { return nil }
        var bracketCount = 0
        var inString = false
        var escape = false
        var arrEndIndex = arrStartIndex

        for idx in chunk.indices[arrStartIndex..<chunk.endIndex] {
            let ch = chunk[idx]
            if inString {
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "[" {
                    bracketCount += 1
                } else if ch == "]" {
                    bracketCount -= 1
                    if bracketCount == 0 {
                        arrEndIndex = chunk.index(after: idx)
                        break
                    }
                }
            }
        }

        let jsonString = String(chunk[arrStartIndex..<arrEndIndex])
        guard let jsonData = jsonString.data(using: .utf8) else { return nil }

        do {
            let items = try JSONDecoder().decode([SteamSSRWorkshopItem].self, from: jsonData)
            return items.map { item in
                let isAnimatedImage = item.preview_url.lowercased().contains(".gif")
                return WorkshopWallpaper(
                    id: item.publishedfileid,
                    title: item.title,
                    description: item.short_description,
                    previewURL: URL(string: item.preview_url),
                    author: WorkshopAuthor(steamID: item.creator, name: "Unknown", avatarURL: nil),
                    fileSize: Int64(item.file_size),
                    fileURL: nil,
                    steamAppID: wallpaperEngineAppID,
                    subscriptions: item.subscriptions,
                    favorites: item.favorited,
                    views: item.views,
                    rating: item.star_rating.flatMap { Double($0) },
                    type: WorkshopWallpaper.detectType(fromTags: item.tags.map { $0.tag }),
                    tags: item.tags.map { $0.tag },
                    isAnimatedImage: isAnimatedImage,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(item.time_created)),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(item.time_updated))
                )
            }
        } catch {
            AppLogger.error(.media, "Failed to decode SSR JSON", metadata: ["error": "\(error)"])
            return nil
        }
    }

    private struct SteamSSRWorkshopItem: Codable {
        let publishedfileid: String
        let creator: String
        let preview_url: String
        let title: String
        let short_description: String?
        let file_size: String
        let time_created: Int
        let time_updated: Int
        let subscriptions: Int?
        let favorited: Int?
        let views: Int?
        let star_rating: String?
        let tags: [SteamSSRTag]
    }

    private struct SteamSSRTag: Codable {
        let tag: String
    }

    private struct SteamHTMLWorkshopItem: Codable {
        let publishedfileid: String
        let title: String
        let description: String?
        let preview_url: String?
        let creator: String?
        let subscriptions: Int?
        let favorited: Int?
        let views: Int?
        let vote_data: SteamHTMLVoteData?
        let tags: [SteamHTMLTag]?
    }

    private struct SteamHTMLTag: Codable {
        let tag: String
    }

    private struct SteamHTMLVoteData: Codable {
        let score: Double?
    }

    private func parseNumber(_ text: String) -> Int {
        let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits) ?? 0
    }

    private func parseFileSize(_ text: String) -> Int64? {
        let lower = text.lowercased()
        let numberString = lower.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
        guard let number = Double(numberString) else { return nil }

        if lower.contains("gb") {
            return Int64(number * 1024 * 1024 * 1024)
        } else if lower.contains("mb") {
            return Int64(number * 1024 * 1024)
        } else if lower.contains("kb") {
            return Int64(number * 1024)
        }
        return Int64(number)
    }

    // MARK: - Steam Web API 批量补全

    /// 用 GetPublishedFileDetails 批量补全 Workshop 物品元数据
    private func enrichWithAPIDetails(_ items: [WorkshopWallpaper]) async throws -> [WorkshopWallpaper] {
        let ids = items.map(\.id)
        let details = try await fetchPublishedFileDetails(ids: ids)
        let detailMap = Dictionary(uniqueKeysWithValues: details.map { ($0.publishedfileid, $0) })

        return items.map { item in
            guard let detail = detailMap[item.id] else { return item }
            return WorkshopWallpaper(base: item, detail: detail)
        }
    }

    /// 批量查询 Steam Web API 获取文件详情
    private func fetchPublishedFileDetails(ids: [String]) async throws -> [SteamPublishedFileDetail] {
        guard !ids.isEmpty else { return [] }

        var request = URLRequest(url: URL(string: "\(steamAPIBase)/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = "itemcount=\(ids.count)"
        for (index, id) in ids.enumerated() {
            body += "&publishedfileids[\(index)]=\(id)"
        }
        request.httpBody = body.data(using: .utf8)

        let data = try await NetworkService.shared.fetchData(request: request)

        // Steam 对已删除/下架/转私密的条目只返回 {"publishedfileid","result":9} 骨架
        // （无 title/creator 字段），一条坏数据曾让整批 JSONDecoder 失败，
        // 进而被上层误判为会话失效。先剔除骨架条目再解码。
        let cleanedData: Data
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var response = root["response"] as? [String: Any],
           let details = response["publishedfiledetails"] as? [[String: Any]] {
            let unavailableIDs = details
                .filter { ($0["result"] as? Int ?? 0) != 1 || $0["title"] == nil || $0["creator"] == nil }
                .compactMap { $0["publishedfileid"] as? String }
            if !unavailableIDs.isEmpty {
                AppLogger.info(.media, "Skipped unavailable Workshop entries in API details", metadata: [
                    "count": "\(unavailableIDs.count)",
                    "ids": unavailableIDs.joined(separator: ",")
                ])
                response["publishedfiledetails"] = details.filter {
                    ($0["result"] as? Int ?? 0) == 1 && $0["title"] != nil && $0["creator"] != nil
                }
                var root = root
                root["response"] = response
                cleanedData = try JSONSerialization.data(withJSONObject: root)
            } else {
                cleanedData = data
            }
        } else {
            cleanedData = data
        }

        do {
            let result = try JSONDecoder().decode(SteamPublishedFileResponse.self, from: cleanedData)
            let details = result.response.publishedfiledetails ?? []
            if let first = details.first {
                AppLogger.info(.media, "API detail sample", metadata: ["id": first.publishedfileid, "subs": first.subscriptions ?? -1, "fav": first.favorited ?? -1, "views": first.views ?? -1, "vote": first.vote_data?.score ?? first.score ?? -1])
            }
            return details
        } catch {
            AppLogger.error(.media, "Failed to decode API response", metadata: ["error": "\(error)"])
            if let json = String(data: data, encoding: .utf8) {
                AppLogger.info(.media, "Raw API response (first 500 chars)", metadata: ["response": json.prefix(500)])
            }
            throw WorkshopError.apiError("解析 Steam API 响应失败")
        }
    }

    private struct SteamProfileSummary {
        let steamID: String?
        let name: String
        let avatarURL: URL?
    }

    private func fetchSteamProfile(profileID: String) async throws -> SteamProfileSummary? {
        guard !profileID.isEmpty,
              let url = URL(string: "https://steamcommunity.com\(steamProfilePath(for: profileID))/?xml=1") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let data = try await NetworkService.shared.fetchData(request: request)
        guard let xml = String(data: data, encoding: .utf8) else { return nil }

        let numericSteamID = firstXMLValue(named: "steamID64", in: xml)
        let name = firstXMLValue(named: "steamID", in: xml)
            ?? firstXMLValue(named: "customURL", in: xml)
            ?? profileID
        let avatar = firstXMLValue(named: "avatarFull", in: xml)
            ?? firstXMLValue(named: "avatarMedium", in: xml)
            ?? firstXMLValue(named: "avatarIcon", in: xml)
        return SteamProfileSummary(steamID: numericSteamID, name: name, avatarURL: avatar.flatMap(URL.init(string:)))
    }

    private func steamProfilePath(for profileID: String) -> String {
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.allSatisfy(\.isNumber) {
            return "/profiles/\(trimmed)"
        }
        return "/id/\(trimmed)"
    }

    private func firstXMLValue(named tag: String, in xml: String) -> String? {
        let cdataPattern = "<\(tag)>\\s*<!\\[CDATA\\[(.*?)\\]\\]>\\s*</\(tag)>"
        if let value = firstRegexCapture(pattern: cdataPattern, in: xml) {
            return value
        }
        let plainPattern = "<\(tag)>\\s*(.*?)\\s*</\(tag)>"
        return firstRegexCapture(pattern: plainPattern, in: xml)
    }

    private func firstRegexCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let value = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 通过 Steam Workshop URL 解析项目

    /// 从 Steam Workshop URL 解析 publishedfileid，支持多种格式：
    /// - https://steamcommunity.com/sharedfiles/filedetails/?id=3722857902
    /// - https://steamcommunity.com/sharedfiles/filedetails/?id=3722857902&searchtext=...
    /// - steamcommunity.com/sharedfiles/filedetails/?id=3722857902
    /// - 纯数字 ID
    static func extractWorkshopID(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // 纯数字直接返回
        if trimmed.allSatisfy({ $0.isNumber }) {
            return trimmed
        }

        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // 检查路径是否为 sharedfiles/filedetails/
        let path = components.path.lowercased()
        guard path.contains("sharedfiles/filedetails") else { return nil }

        return components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value
    }

    /// 查询创意工坊条目的远端元数据（用于已下载项更新检测）
    /// - Returns: `(updatedAt, fileSize)`；条目不存在或字段缺失时返回 nil
    func fetchWorkshopRemoteUpdateInfo(workshopID: String) async throws -> (updatedAt: Date, fileSize: Int64?)? {
        let details = try await fetchPublishedFileDetails(ids: [workshopID])
        guard let detail = details.first,
              let timeUpdated = detail.time_updated else {
            return nil
        }
        let updatedAt = Date(timeIntervalSince1970: TimeInterval(timeUpdated))
        let fileSize: Int64? = {
            guard let sizeStr = detail.file_size, let size = Int64(sizeStr), size > 0 else {
                return nil
            }
            return size
        }()
        return (updatedAt, fileSize)
    }

    /// 通过 Workshop URL 获取单个项目详情并转换为 MediaItem
    func resolveWorkshopItemByURL(_ urlString: String) async throws -> MediaItem {
        guard let workshopID = Self.extractWorkshopID(from: urlString) else {
            throw WorkshopError.invalidURL
        }

        let details = try await fetchPublishedFileDetails(ids: [workshopID])
        guard let detail = details.first else {
            throw WorkshopError.apiError("未找到该 Workshop 项目")
        }

        guard detail.creator_app_id == 431960 || detail.consumer_app_id == 431960 else {
            throw WorkshopError.workshopNotSupported
        }

        let profile = try? await fetchSteamProfile(profileID: detail.creator)
        let wallpaper = WorkshopWallpaper(
            id: detail.publishedfileid,
            title: detail.title,
            description: detail.description,
            previewURL: detail.preview_url.flatMap { URL(string: $0) },
            author: WorkshopAuthor(
                steamID: profile?.steamID ?? detail.creator,
                name: bestAuthorName("Unknown", fallback: profile?.name ?? detail.creator),
                avatarURL: profile?.avatarURL
            ),
            fileSize: Int64(detail.file_size ?? "0"),
            fileURL: detail.file_url.flatMap { URL(string: $0) },
            steamAppID: String(detail.consumer_app_id ?? 431960),
            subscriptions: detail.subscriptions,
            favorites: detail.favorited,
            views: detail.views,
            rating: detail.vote_data?.score ?? detail.score,
            type: WorkshopWallpaper.detectType(fromTags: detail.tags?.map(\.tag) ?? []),
            tags: detail.tags?.map { $0.tag } ?? [],
            isAnimatedImage: detail.preview_url?.lowercased().contains(".gif"),
            createdAt: detail.time_created.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) },
            updatedAt: detail.time_updated.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
        return convertToMediaItem(wallpaper)
    }

    // MARK: - Type Detection

    private func detectType(from urlString: String) -> WorkshopWallpaper.WallpaperType {
        let lower = urlString.lowercased()
        if lower.contains(".mp4") || lower.contains(".webm") || lower.contains(".mov") {
            return .video
        } else if lower.contains(".html") || lower.contains(".htm") {
            return .web
        } else if lower.contains(".scene") || lower.contains(".unity") {
            return .scene
        } else if lower.contains(".pkg") {
            return .pkg
        } else if lower.contains(".jpg") || lower.contains(".png") || lower.contains(".gif") {
            return .image
        }
        return .unknown
    }

    func loadMore(currentParams: WorkshopSearchParams) async throws -> WorkshopSearchResponse {
        var params = currentParams
        params.page = currentPage + 1
        return try await search(params: params)
    }

    // MARK: - Workshop Download

    func downloadWorkshopItem(
        workshopID: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        // 获取并发下载槽位（超出上限则排队等待）
        try await downloadLimiter.acquire()
        // 更新排队计数
        let queued = await downloadLimiter.queuedCount()
        await MainActor.run { workshopQueuedCount = queued }

        defer {
            Task {
                await downloadLimiter.release()
                let remaining = await downloadLimiter.queuedCount()
                await MainActor.run { workshopQueuedCount = remaining }
            }
        }

        do {
            let downloadedURL = try await SteamServiceManager.shared.downloadItem(
                workshopID: workshopID,
                outputRoot: DownloadPathManager.shared.mediaFolderURL
                    .appendingPathComponent("workshop_\(workshopID)", isDirectory: true),
                progressHandler: progressHandler
            )
            return await VideoTranscodeService.ensureAppleCompatibleContainer(downloadedURL)
        } catch let error as SteamServiceError {
            if case .cancelled = error {
                throw CancellationError()
            }
            throw Self.workshopError(for: error)
        }
    }

    /// 递归计算目录下所有文件的总大小（字节），用于轮询下载进度
    /// 注意：不跳过隐藏文件，因为下载中可能存在隐藏临时文件
    nonisolated private static func dirSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        var total: Int64 = 0
        if let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) {
            for entry in entries {
                var childIsDir: ObjCBool = false
                if fm.fileExists(atPath: entry.path, isDirectory: &childIsDir), childIsDir.boolValue {
                    total += dirSize(entry)
                } else {
                    if let size = try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        total += Int64(size)
                    }
                }
            }
        }
        return total
    }

    // MARK: - App Availability

    func verifySteamLogin(
        username: String,
        password: String,
        guardCode: String? = nil
    ) async throws {
        do {
            try await SteamServiceManager.shared.login(
                username: username,
                password: password,
                guardCode: guardCode
            )
        } catch let error as SteamServiceError {
            throw Self.workshopError(for: error)
        }
    }

    nonisolated private static func workshopError(for error: SteamServiceError) -> WorkshopError {
        switch error {
        case .unavailable(let message):
            return .executionFailed(message)
        case .busy:
            return .executionFailed(error.localizedDescription)
        case .notAuthenticated:
            return .sessionExpired
        case .authenticationFailed(let message, let code):
            switch code {
            case "GUARD_CODE_REQUIRED", "MOBILE_CONFIRMATION_REQUIRED":
                return .guardCodeRequired(message)
            case "AUTH_SERVICE_TEMPORARY", "CONNECTION_LOST":
                return .loginTimeout
            default:
                return .steamLoginFailed(message)
            }
        case .downloadFailed(let message, let code):
            switch code {
            case "NOT_AUTHENTICATED":
                return .sessionExpired
            case "CONNECTION_LOST", "NO_CONTENT_SERVER":
                return .downloadIncomplete(message)
            default:
                return .downloadFailed(message)
            }
        case .cancelled:
            return .timeout
        }
    }

    /// 扫描并清理下载失败产生的空文件夹
    /// 返回清理的文件夹数量和释放的空间
    @MainActor
    func cleanupFailedDownloads() -> (count: Int, bytesFreed: Int64) {
        let mediaFolder = DownloadPathManager.shared.mediaFolderURL
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: mediaFolder, includingPropertiesForKeys: [.fileSizeKey]) else {
            return (0, 0)
        }

        var cleanedCount = 0
        var totalBytesFreed: Int64 = 0

        for item in items {
            guard item.lastPathComponent.hasPrefix("workshop_") else { continue }

            // 检查是否是空文件夹或只有空的中间目录
            let hasRealContent = hasContentFiles(at: item)

            if !hasRealContent {
                // 计算文件夹大小
                let folderSize = Self.dirSize(item)
                totalBytesFreed += folderSize

                // 删除整个 workshop 文件夹
                try? fm.removeItem(at: item)
                cleanedCount += 1
                print("[WorkshopService] 已清理空的下载目录: \(item.lastPathComponent)")
            }
        }

        return (cleanedCount, totalBytesFreed)
    }

    /// 检查目录下是否有实际的内容文件（排除空目录和临时文件）
    private func hasContentFiles(at dir: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }

        while let fileURL = enumerator.nextObject() as? URL {
            // 跳过目录本身
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { continue }

            let filename = fileURL.lastPathComponent
            // 跳过临时文件和隐藏文件
            if filename.hasPrefix(".") || filename == "download_script.txt" { continue }

            // 检查是否有 project.json（Workshop 内容的标志文件）
            if filename == "project.json" { return true }

            // 检查是否有实际的媒体文件
            let ext = filename.lowercased()
            if ["json", "jpg", "jpeg", "png", "gif", "webp", "mp4", "mov", "webm", "avi", "Scene.pak", "scene.pkg"].contains(ext) {
                return true
            }
        }
        return false
    }

    /// 格式化文件大小为可读字符串
    static func formattedByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func isWallpaperEngineAppInstalled() -> Bool {
        let bundleIds = [
            "com.WallpaperEngineX.app",
            "io.wallpaperengine.macos"
        ]
        if bundleIds.contains(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) {
            return true
        }
        let paths = [
            "/Applications/Wallpaper Engine X.app",
            NSHomeDirectory() + "/Applications/Wallpaper Engine X.app",
            "/Applications/Wallpaper Engine.app",
            NSHomeDirectory() + "/Applications/Wallpaper Engine.app"
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }
}


// MARK: - WorkshopWallpaper → MediaItem 转换

extension WorkshopService {
    func convertToMediaItem(_ wallpaper: WorkshopWallpaper) -> MediaItem {
        var downloadOptions: [MediaDownloadOption] = []

        if let fileURL = wallpaper.fileURL {
            let option = MediaDownloadOption(
                label: "Workshop",
                fileSizeLabel: formatFileSize(wallpaper.fileSize),
                detailText: "\(wallpaper.type.rawValue.capitalized)",
                remoteURL: fileURL
            )
            downloadOptions = [option]
        }

        let trimmedAuthorName = wallpaper.author.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAuthorName = !trimmedAuthorName.isEmpty && trimmedAuthorName != "Unknown"
        let hasSteamID = !wallpaper.author.steamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return MediaItem(
            slug: "workshop_\(wallpaper.id)",
            title: wallpaper.title,
            pageURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(wallpaper.id)")!,
            thumbnailURL: wallpaper.previewURL ?? URL(string: "https://steamcommunity.com/favicon.ico")!,
            resolutionLabel: wallpaper.type.rawValue.capitalized,
            collectionTitle: wallpaper.tags.first,
            summary: wallpaper.description,
            previewVideoURL: nil,
            posterURL: wallpaper.previewURL,
            tags: wallpaper.tags,
            exactResolution: nil,
            durationSeconds: nil,
            downloadOptions: downloadOptions,
            sourceName: t("wallpaperEngine"),
            isAnimatedImage: wallpaper.isAnimatedImage,
            subscriptionCount: wallpaper.subscriptions,
            favoriteCount: wallpaper.favorites,
            viewCount: wallpaper.views,
            ratingScore: wallpaper.rating,
            authorName: hasAuthorName ? trimmedAuthorName : nil,
            authorSteamID: hasSteamID ? wallpaper.author.steamID : nil,
            authorAvatarURL: wallpaper.author.avatarURL,
            fileSize: wallpaper.fileSize,
            createdAt: wallpaper.createdAt,
            updatedAt: wallpaper.updatedAt
        )
    }

    func convertToMediaItems(_ wallpapers: [WorkshopWallpaper]) -> [MediaItem] {
        wallpapers.map { convertToMediaItem($0) }
    }

    private func formatFileSize(_ bytes: Int64?) -> String {
        guard let bytes = bytes else { return "Unknown" }
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Error & Status

// MARK: - Workshop 下载目录 → 真实 WE 工程根

extension WorkshopService {
    /// Canonicalize both the outer Workshop download directory and the nested content directory.
    /// This keeps media-library registration stable when callers resolve the playable project root.
    ///
    /// 实现注意：不要在循环里反复碰 `URL.path` / `lastPathComponent` / `deletingLastPathComponent`。
    /// Foundation 每次都会 percent-decode / 重新 parse，下载后立刻「设为壁纸」时会把主线程卡死
    ///（sample 里整段采样窗口都耗在这里），桌面层已停旧壁纸时就表现为黑屏 + RSS 顶高。
    nonisolated static func canonicalWorkshopContentURL(for workshopID: String, startingAt url: URL) -> URL {
        let fileManager = FileManager.default
        let standardizedPath = (url.path as NSString).standardizingPath
        var components = (standardizedPath as NSString).pathComponents

        // 已是 .../431960/<id>
        if components.count >= 2,
           components[components.count - 2] == "431960",
           components[components.count - 1] == workshopID {
            return URL(fileURLWithPath: standardizedPath, isDirectory: true)
        }

        let workshopRootName = "workshop_\(workshopID)"
        // 纯字符串向上走，避免每层重建 BridgedURL
        while !components.isEmpty {
            if components.last == workshopRootName {
                let rootPath = NSString.path(withComponents: components)
                let contentPath = (rootPath as NSString)
                    .appendingPathComponent("steamapps/workshop/content/431960/\(workshopID)")
                if fileManager.fileExists(atPath: contentPath) {
                    return URL(fileURLWithPath: contentPath, isDirectory: true)
                }
            }
            // 到文件系统根就停（["/"] 或 ["C:"]）
            if components.count <= 1 { break }
            components.removeLast()
        }

        let fallbackURL = URL(fileURLWithPath: standardizedPath, isDirectory: true)
        return resolveWallpaperEngineProjectRoot(startingAt: fallbackURL)
    }

    /// Workshop 下载路径常为 `.../steamapps/workshop/content/431960/<id>/`，但 `project.json` 往往在**唯一子目录**或**多子目录之一**内。
    /// 在根目录没有 `project.json`、`.pkg`、视频文件时向下解析，避免类型检测与 CLI 加载失败。
    nonisolated static func resolveWallpaperEngineProjectRoot(startingAt base: URL, maxDescend: UInt = 8) -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
            return base
        }
        return resolveWEProjectRootRecursive(base, depthLeft: maxDescend, fm: fm)
    }

    private nonisolated static func resolveWEProjectRootRecursive(_ url: URL, depthLeft: UInt, fm: FileManager) -> URL {
        if depthLeft == 0 { return url }
        if fm.fileExists(atPath: url.appendingPathComponent("project.json").path) {
            return url
        }
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return url
        }
        let hasRootPkg = entries.contains { $0.pathExtension.lowercased() == "pkg" }
        let hasRootVideo = entries.contains { ["mp4", "mov", "webm"].contains($0.pathExtension.lowercased()) }
        if hasRootPkg || hasRootVideo {
            return url
        }
        var childDirs: [URL] = []
        for entry in entries {
            var d: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &d), d.boolValue else { continue }
            // 下载壳目录：downloads / temp 不含 project.json，跳过可加速定位 content/<appid>/<id>
            let name = entry.lastPathComponent.lowercased()
            if name == "downloads" || name == "temp" { continue }
            childDirs.append(entry)
        }
        if childDirs.isEmpty {
            return url
        }
        if childDirs.count == 1 {
            return resolveWEProjectRootRecursive(childDirs[0], depthLeft: depthLeft - 1, fm: fm)
        }

        // 多子目录：先看直接子目录是否带 project.json
        let withProject = childDirs
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if let first = withProject.first {
            return first
        }

        // Steam 路径常为 steamapps/workshop/content/431960/<id>/project.json：
        // 当前层（如 workshop）有 content/downloads/temp 等多个目录，直接子层也没有 project.json。
        // 继续向下搜索，优先 content 目录。
        let orderedChildren = childDirs.sorted { a, b in
            let aContent = a.lastPathComponent.lowercased() == "content"
            let bContent = b.lastPathComponent.lowercased() == "content"
            if aContent != bContent { return aContent && !bContent }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        for child in orderedChildren {
            let resolved = resolveWEProjectRootRecursive(child, depthLeft: depthLeft - 1, fm: fm)
            if fm.fileExists(atPath: resolved.appendingPathComponent("project.json").path) {
                return resolved
            }
            // 子树里若已落在含 pkg/视频 的工程根，也接受
            if let childEntries = try? fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
               childEntries.contains(where: {
                   $0.pathExtension.lowercased() == "pkg" ||
                   ["mp4", "mov", "webm"].contains($0.pathExtension.lowercased())
               }) {
                return resolved
            }
        }
        return url
    }
}

enum WorkshopError: LocalizedError {
    case invalidURL
    case apiError(String)
    case credentialsRequired
    case invalidCredentials
    case steamLoginFailed(String)
    case sessionExpired
    case loginTimeout
    case guardCodeRequired(String)
    case confirmationRequired(String)
    case timeout
    case downloadIncomplete(String)
    case downloadFailed(String)
    case executionFailed(String)
    case workshopNotSupported

    var requiresSteamLoginRecovery: Bool {
        switch self {
        case .credentialsRequired,
             .invalidCredentials,
             .sessionExpired,
             .guardCodeRequired,
             .confirmationRequired:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的链接"
        case .apiError(let msg): return msg
        case .credentialsRequired:
            return "需要登录 Steam 账号。下载任务已保留，请在设置中登录；成功后将自动继续。"
        case .invalidCredentials:
            return "Steam 会话需要重新验证。下载任务已保留，请在设置中重新登录；密码和验证码不会保存。"
        case .steamLoginFailed(let msg): return msg
        case .sessionExpired:
            return "Steam 会话需要重新登录。下载任务已保留，登录成功后将自动继续；账号名不会被清除。"
        case .loginTimeout: return "Steam 登录超时，可能是网络不稳定或 Steam 服务器繁忙，请检查网络后重试"
        case .guardCodeRequired(let msg): return msg
        case .confirmationRequired(let msg): return msg
        case .timeout: return "下载超时（已等待 10 分钟），可能是网络波动或文件过大，请检查网络后重试"
        case .downloadIncomplete(let msg): return msg.isEmpty ? "下载未完成，请重试" : msg
        case .downloadFailed(let msg): return "下载失败：\(msg)"
        case .executionFailed(let msg): return "执行失败：\(msg)"
        case .workshopNotSupported: return "非 Workshop 项目"
        }
    }
}

