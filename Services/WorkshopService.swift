import Foundation
import AppKit
import CFNetwork
import SwiftSoup
import WebKit

// MARK: - SteamCMD 并发下载限制器
/// SteamCMD 虽无明确的 CLI 并发限制，但 Steam 后端会对同一账号的
/// 同时登录/下载请求进行限流（RateLimitExceeded），因此需要控制并发数。
/// 实测超过 2 个同时进行的 SteamCMD 下载即可能触发限流。
///
/// ⚠️ 使用轮询而非 Continuation 实现排队，原因：
/// 如果用 `withCheckedContinuation` 在满负荷时挂起调用方，当用户在
/// 排队等待期间取消下载任务时，continuation 会泄露在 waiters 数组中，
/// 导致内存泄漏和运行时 "SWIFT TASK CONTINUATION MISUSE" 警告。
/// 轮询方案通过 Task.sleep 等待，取消时正确抛出 CancellationError，
/// 不存在延续泄露的风险。
private actor SteamCMDDownloadLimiter {
    /// 最大同时下载数
    private let maxConcurrent = 2
    /// 当前活跃下载数
    private var activeCount = 0
    /// 当前正在轮询等待的任务数（近似排队深度）
    private var waitCount = 0
    /// 轮询间隔
    private let pollInterval: UInt64 = 500_000_000 // 0.5s

    /// 获取一个下载槽位；若已满则每隔 0.5s 轮询一次
    func acquire() async {
        while true {
            if activeCount < maxConcurrent {
                activeCount += 1
                return
            }
            waitCount += 1
            // 休眠期间若 Task 被取消，CancellationError 被 try? 静默吞掉，
            // 循环继续检查槽位。实际下载操作在 acquire 返回后进行，
            // 那里会通过 try await 抛出 CancellationError 并被外层捕获。
            try? await Task.sleep(nanoseconds: pollInterval)
            waitCount = max(0, waitCount - 1)
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
    /// SteamCMD 下载排队数量（超过并发上限时排队等待）
    @Published var steamCMDQueuedCount: Int = 0

    // MARK: - Configuration

    private let wallpaperEngineAppID = "431960"
    private let steamAPIBase = "https://api.steampowered.com"
    private let authorPageSize = 30
    private var currentPage = 1
    private let pageSize = 20

    /// SteamCMD 并发下载限制器（全局，限制同时进行的 steamcmd 进程数）
    private let downloadLimiter = SteamCMDDownloadLimiter()

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

    /// 从 Steam 订阅页面抓取用户已订阅的壁纸列表
    /// - Parameters:
    ///   - steamID: Steam 64位数字 ID
    ///   - page: 页码（从 1 开始）
    /// - Returns: 壁纸列表
    func fetchSubscriptions(steamID: String, page: Int = 1) async throws -> [WorkshopWallpaper] {
        let profilePath = steamProfilePath(for: steamID)
        var components = URLComponents(string: "https://steamcommunity.com\(profilePath)/myworkshopfiles/")
        components?.queryItems = [
            URLQueryItem(name: "appid", value: wallpaperEngineAppID),
            URLQueryItem(name: "sort", value: "score"),
            URLQueryItem(name: "browsefilter", value: "mysubscriptions"),
            URLQueryItem(name: "view", value: "imagewall"),
            URLQueryItem(name: "p", value: String(page)),
            URLQueryItem(name: "numperpage", value: String(authorPageSize))
        ]
        guard let url = components?.url else {
            throw WorkshopError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(steamCommunityUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        // 直接从 WKWebsiteDataStore 读取 cookie（绕过 HTTPCookieStorage.shared 同步链路，避免同步失败）
        if let cookies = await steamCookiesFromWKDataStore(), !cookies.isEmpty {
            let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
            if let cookieHeader, !cookieHeader.isEmpty {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                AppLogger.info(.media, "Applied Steam cookies from WKWebsiteDataStore", metadata: ["count": "\(cookies.count)"])
            }
        } else {
            // 降级：从 HTTPCookieStorage.shared 读（兼容无 WKWebView 的场景）
            applySteamCookies(to: &request)
        }

        let data = try await NetworkService.shared.fetchData(request: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw WorkshopError.apiError("无法解析 HTML 响应")
        }

        // 先尝试从 SSR JSON 提取
        var wallpapers = extractFromJSON(html)
        if !wallpapers.isEmpty {
            AppLogger.info(.media, "fetchSubscriptions used JSON/SSR extraction: \(wallpapers.count) items")
            do {
                wallpapers = try await enrichWithAPIDetails(wallpapers)
            } catch {
                AppLogger.error(.media, "fetchSubscriptions API enrichment failed", metadata: ["steamID": steamID, "error": "\(error)"])
            }
            return wallpapers
        }

        // 降级：从 HTML DOM 解析
        AppLogger.info(.media, "fetchSubscriptions falling back to HTML DOM parsing")
        let doc = try SwiftSoup.parse(html)
        try validateSteamSubscriptionHTML(doc, html: html, steamID: steamID, page: page)
        let items = try doc.select(".workshopItem, .workshopItemWrapper, [id*='sharedfiles_']")
        var parsed = try items.compactMap { try parseWorkshopItem($0) }
        if parsed.isEmpty {
            parsed = try parseModernWorkshopHTML(doc)
        }
        // 如果还为空，尝试解析当前 Steam 订阅页面格式（workshopItemSubscription）
        if parsed.isEmpty {
            parsed = try parseSubscriptionPageHTML(doc)
        }
        // HTML 解析可能因 CSS 选择器匹配到同一项的多个元素而产生重复，按 id 去重
        var seenIDs = Set<String>()
        parsed = parsed.filter { seenIDs.insert($0.id).inserted }
        do {
            parsed = try await enrichWithAPIDetails(parsed)
        } catch {
            AppLogger.error(.media, "fetchSubscriptions HTML API enrichment failed", metadata: ["steamID": steamID, "error": "\(error)"])
        }
        return parsed
    }

    /// 从 WKWebsiteDataStore（WKWebView 的持久 cookie 存储）获取 Steam 域名下的 cookie
    /// 这是最可靠的 cookie 来源——WKWebView 中的 Steam 登录会话始终在此存储中，
    /// 不需要经过 WebViewCookieSync 的中转同步步骤。
    private func steamCookiesFromWKDataStore() async -> [HTTPCookie]? {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let filtered = cookies.filter { cookie in
                    ["steamcommunity.com", "steampowered.com", "steamcdn.com"].contains(where: { domain in
                        cookie.domain.contains(domain)
                    })
                }
                continuation.resume(returning: filtered.isEmpty ? nil : filtered)
            }
        }
    }

    private func applySteamCookies(to request: inout URLRequest) {
        guard let url = request.url,
              let cookies = HTTPCookieStorage.shared.cookies(for: url),
              !cookies.isEmpty else { return }
        let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            AppLogger.info(.media, "Applied Steam cookies to subscription request", metadata: ["count": "\(cookies.count)"])
        }
    }

    private func validateSteamSubscriptionHTML(_ document: Document, html: String, steamID: String, page: Int) throws {
        let lowercaseHTML = html.lowercased()
        let loginForm = try document.select("form[action*='login'], form[action*='steampowered.com/login'], input[name='openid.identity']").first()
        let globalLoginAction = try document.select("#global_action_menu a[href*='login'], a.global_action_link[href*='login']").first()
        if loginForm != nil
            || globalLoginAction != nil
            || lowercaseHTML.contains("g_steamid = false")
            || lowercaseHTML.contains("sign in through steam") {
            throw WorkshopError.sessionExpired
        }

        if lowercaseHTML.contains("there was a problem accessing the item")
            || lowercaseHTML.contains("specified profile could not be found")
            || lowercaseHTML.contains("无法找到指定的个人资料")
            || lowercaseHTML.contains("该个人资料是私密的") {
            throw WorkshopError.apiError("无法访问 Steam 订阅页，请确认 SteamID 正确且订阅列表可见")
        }

        if page == 1,
           lowercaseHTML.contains("mysubscriptions"),
           !lowercaseHTML.contains("workshopitem")
            && !lowercaseHTML.contains("publishedfileid")
            && !lowercaseHTML.contains("sharedfiles/filedetails") {
            AppLogger.info(.media, "Steam subscription page has no parseable item markers", metadata: ["steamID": steamID])
        }
    }

    // MARK: - Web 登录相关

    /// 检查当前是否已通过 Web 登录
    /// - Parameter steamID: Steam 64位数字 ID
    /// - Returns: 登录状态
    func checkWebLoginStatus(steamID: String) async -> Bool {
        let profilePath = steamProfilePath(for: steamID)
        let urlString = "https://steamcommunity.com\(profilePath)/myworkshopfiles/?appid=431960&browsefilter=mysubscriptions"

        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        // 带上 WebView 会话 cookie 才能正确检测登录状态
        if let cookies = await steamCookiesFromWKDataStore(), !cookies.isEmpty {
            let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
            if let cookieHeader, !cookieHeader.isEmpty {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
        }

        do {
            let data = try await NetworkService.shared.fetchData(request: request)
            guard let html = String(data: data, encoding: .utf8) else { return false }

            // 检查页面是否包含登录表单（未登录状态）
            let doc = try SwiftSoup.parse(html)
            let loginForm = try doc.select("form[action*='login']").first()
            let loginLink = try doc.select("a[href*='login']").first()

            // 如果有登录表单或登录链接，说明未登录
            if loginForm != nil || loginLink != nil {
                AppLogger.info(.media, "checkWebLoginStatus: 未登录", metadata: ["steamID": steamID])
                return false
            }

            // 检查页面是否包含订阅内容
            let workshopItems = try doc.select(".workshopItem, .workshopItemWrapper, [id*='sharedfiles_']")
            if !workshopItems.isEmpty() {
                AppLogger.info(.media, "checkWebLoginStatus: 已登录且有订阅内容", metadata: ["steamID": steamID, "items": "\(workshopItems.size())"])
                return true
            }

            // 检查页面是否包含用户信息（即使没有订阅）
            let userInfo = try doc.select(".playerAvatar, .persona .actual_persona_name").first()
            if userInfo != nil {
                AppLogger.info(.media, "checkWebLoginStatus: 已登录但可能没有订阅", metadata: ["steamID": steamID])
                return true
            }

            return false
        } catch {
            AppLogger.error(.media, "checkWebLoginStatus failed", metadata: ["steamID": steamID, "error": "\(error)"])
            return false
        }
    }

    /// 获取用户所有已订阅的壁纸（自动翻页）
    /// - Parameter steamID: Steam 64位数字 ID
    /// - Returns: 所有已订阅壁纸
    func fetchAllSubscriptions(steamID: String) async throws -> [WorkshopWallpaper] {
        var allItems: [WorkshopWallpaper] = []
        var seenIDs = Set<String>()
        var page = 1
        var hasMore = true
        var emptyPageCount = 0

        while hasMore {
            let items = try await fetchSubscriptions(steamID: steamID, page: page)
            for item in items {
                if seenIDs.insert(item.id).inserted {
                    allItems.append(item)
                }
            }
            // Steam 订阅页面固定每页最多返回 10 条（忽略 numperpage），
            // 不能用 authorPageSize(30) 来判断是否有下一页。
            // 改用：如果当前页有数据就继续翻页，连续两页为空则停止。
            if items.isEmpty {
                emptyPageCount += 1
                if emptyPageCount >= 2 {
                    hasMore = false
                }
            } else {
                emptyPageCount = 0
            }
            page += 1
            // 避免无限循环，最多 50 页（1500 条）
            if page > 50 { break }
        }

        AppLogger.info(.media, "fetchAllSubscriptions total: \(allItems.count) unique items across \(page - 1) pages")
        return allItems
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
            case .application: requiredTags.append("Application")
            default: break
            }
        }
        if !params.tags.isEmpty {
            requiredTags.append(contentsOf: params.tags)
        }
        // 新版 browse 页面中内容级别通过 requiredtags[]=Mature/Questionable/Everyone 实现
        // 内容级别由开关控制：开启时放行 Mature，关闭时强制降级为 Everyone
        let effectiveContentLevel = params.contentLevel ?? "Everyone"
        let showAllContent = UserDefaults.standard.bool(forKey: "show_all_workshop_content")
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

    /// 解析当前 Steam 订阅页面格式（2025+）
    /// 选择器：div.workshopItemSubscription（每个订阅项）
    private func parseSubscriptionPageHTML(_ document: Document) throws -> [WorkshopWallpaper] {
        let containers = try document.select("div.workshopItemSubscription")
        guard !containers.isEmpty() else { return [] }

        var wallpapers: [WorkshopWallpaper] = []
        var seenIDs = Set<String>()

        for container in containers {
            let containerID = try container.attr("id")

            // Steam 页面为每个订阅项生成两个容器：
            //   <div id="Subscription3579766653">   — 已订阅状态（可见）
            //   <div id="Unsubscribed3579766653">   — 未订阅状态（隐藏，无预览图）
            // 必须跳过 Unsubscribed 容器，否则会提取出 "scribed3579766653" 这样的错误 ID。
            guard !containerID.hasPrefix("Unsubscribed") else { continue }

            // 优先从容器内的详情链接 URL 提取 publishedfileid（最可靠）
            var id: String?
            if let link = try container.select("a[href*=\"/sharedfiles/filedetails/?id=\"]").first() {
                let href = try link.attr("href")
                id = href.components(separatedBy: "id=").last?.components(separatedBy: "&").first
            }
            // 降级：从容器 ID "Subscription{id}" 提取
            if id == nil || id!.isEmpty {
                id = containerID.components(separatedBy: "Subscription").last
            }
            guard let resolvedID = id, !resolvedID.isEmpty, !seenIDs.contains(resolvedID) else { continue }
            seenIDs.insert(resolvedID)

            // 标题
            let titleEl = try container.select(".workshopItemTitle").first()
            let title = (try titleEl?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled"

            // 预览图
            let previewImg = try container.select(".workshopItemPreviewImage").first()
            let previewSrc = try (previewImg?.attr("src") ?? "")
            let previewURL = previewSrc.isEmpty ? nil : URL(string: previewSrc)

            // 应用名
            let appEl = try container.select(".workshopItemApp").first()
            let _ = (try appEl?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // 日期
            let dateEls = try container.select(".workshopItemDate")
            if dateEls.size() >= 1 {
                let _ = try dateEls.get(0).text()
            }
            if dateEls.size() >= 2 {
                let _ = try dateEls.get(1).text()
            }

            let isAnimatedImage = previewSrc.lowercased().contains(".gif")

            wallpapers.append(WorkshopWallpaper(
                id: resolvedID,
                title: title,
                description: nil,
                previewURL: previewURL,
                author: WorkshopAuthor(steamID: "", name: "Unknown", avatarURL: nil),
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

        do {
            let result = try JSONDecoder().decode(SteamPublishedFileResponse.self, from: data)
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

        let wallpaper = WorkshopWallpaper(
            id: detail.publishedfileid,
            title: detail.title,
            description: detail.description,
            previewURL: detail.preview_url.flatMap { URL(string: $0) },
            author: WorkshopAuthor(
                steamID: detail.creator,
                name: "Unknown",
                avatarURL: nil
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

    // MARK: - SteamCMD Download

    func downloadWorkshopItem(
        workshopID: String,
        guardCode: String? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        // 获取并发下载槽位（超出上限则排队等待）
        await downloadLimiter.acquire()
        // 更新排队计数
        let queued = await downloadLimiter.queuedCount()
        await MainActor.run { steamCMDQueuedCount = queued }

        defer {
            Task {
                await downloadLimiter.release()
                let remaining = await downloadLimiter.queuedCount()
                await MainActor.run { steamCMDQueuedCount = remaining }
            }
        }

        // 先尝试不带密码的 login，复用已保存的 session token
        // 如果 session 已失效，再 fallback 到带密码的登录
        do {
            return try await downloadWorkshopItemOnce(
                workshopID: workshopID,
                guardCode: guardCode,
                attempt: 0,
                usePassword: false,
                progressHandler: progressHandler
            )
        } catch let error as WorkshopError {
            switch error {
            case .sessionExpired, .confirmationRequired, .guardCodeRequired, .invalidCredentials:
                // session 已失效或需要重新认证，使用密码重试一次
                AppLogger.info(.download, "Workshop 无密码登录失败，尝试使用密码", metadata:
                    ["workshopID": workshopID, "error": error.localizedDescription])
                return try await downloadWorkshopItemWithRetry(
                    workshopID: workshopID,
                    guardCode: guardCode,
                    progressHandler: progressHandler
                )
            default:
                throw error
            }
        }
    }

    private func downloadWorkshopItemWithRetry(
        workshopID: String,
        guardCode: String? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        // 最多重试 2 次（共 3 次尝试），仅对可恢复的网络/下载错误重试
        let maxRetries = 2
        var lastError: Error?

        for attempt in 0...maxRetries {
            do {
                return try await downloadWorkshopItemOnce(
                    workshopID: workshopID,
                    guardCode: guardCode,
                    attempt: attempt,
                    usePassword: true,
                    progressHandler: progressHandler
                )
            } catch let error as WorkshopError {
                lastError = error
                // 仅对超时、网络错误和下载不完整重试，其他错误直接抛出
                switch error {
                case .timeout, .loginTimeout, .downloadIncomplete:
                    if attempt < maxRetries {
                        AppLogger.info(.download, "Workshop 下载失败，正在重试", metadata:
                            ["workshopID": workshopID, "attempt": attempt + 1, "error": error.localizedDescription])
                        continue
                    }
                default:
                    throw error
                }
            }
        }
        throw lastError ?? WorkshopError.downloadFailed("未知错误")
    }

    private func downloadWorkshopItemOnce(
        workshopID: String,
        guardCode: String? = nil,
        attempt: Int,
        usePassword: Bool = false,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard let steamcmdPath = WorkshopSourceManager.shared.steamCMDExecutableURL() else {
            throw WorkshopError.steamcmdNotFound
        }

        if WorkshopSourceManager.shared.steamCredentials == nil {
            WorkshopSourceManager.shared.refreshStoredSteamCredentials()
        }

        guard let credentials = WorkshopSourceManager.shared.steamCredentials else {
            throw WorkshopError.credentialsRequired
        }

        let downloadDir = DownloadPathManager.shared.mediaFolderURL
            .appendingPathComponent("workshop_\(workshopID)")

        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        // SteamCMD 不提供下载进度输出（+download_progress 是无效命令），
        // 因此通过 Steam API 获取文件大小，再用轮询下载目录的方式估算进度。
        let totalSize: Int64
        do {
            let details = try await fetchPublishedFileDetails(ids: [workshopID])
            if let detail = details.first, let sizeStr = detail.file_size, let size = Int64(sizeStr), size > 0 {
                totalSize = size
            } else {
                totalSize = 0  // 无法获取大小时，禁用百分比进度
            }
        } catch {
            totalSize = 0
        }

        // 优先尝试不带密码的 login，复用已保存的 session token
        // 如果传密码，steamcmd 会执行 SetLoginInformation 清除内存 token 并强制重新认证
        let loginLineNoPassword = [
            "login",
            Self.steamCMDScriptArgument(credentials.username)
        ].joined(separator: " ")
        let loginLineWithPassword = [
            "login",
            Self.steamCMDScriptArgument(credentials.username),
            Self.steamCMDScriptArgument(credentials.password)
        ].joined(separator: " ")

        let scriptContentNoPassword = [
            "@NoPromptForPassword 1",
            "force_install_dir \(Self.steamCMDScriptArgument(downloadDir.path))",
            loginLineNoPassword,
            "workshop_download_item \(wallpaperEngineAppID) \(workshopID)",
            "quit"
        ].joined(separator: "\n")
        let scriptContentWithPassword = [
            "@NoPromptForPassword 1",
            "force_install_dir \(Self.steamCMDScriptArgument(downloadDir.path))",
            loginLineWithPassword,
            "workshop_download_item \(wallpaperEngineAppID) \(workshopID)",
            "quit"
        ].joined(separator: "\n")

        let contentPath = downloadDir
            .appendingPathComponent("steamapps/workshop/content/\(wallpaperEngineAppID)/\(workshopID)")

        let activeScriptContent = usePassword ? scriptContentWithPassword : scriptContentNoPassword

        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            // 直接执行 steamcmd 二进制，绕过 steamcmd.sh 脚本中路径空格导致的解析问题
            // 同时通过 stdin Pipe 发送命令，绕过 macOS 上 +runscript 卡死的问题
            let steamcmdBinURL = steamcmdPath.deletingLastPathComponent().appendingPathComponent("steamcmd")
            task.executableURL = steamcmdBinURL
            task.arguments = []
            task.currentDirectoryURL = steamcmdPath.deletingLastPathComponent()
            let environment = Self.steamCMDEnvironment(steamcmdDirectory: steamcmdPath.deletingLastPathComponent())
            task.environment = environment

            let inputPipe = Pipe()
            task.standardInput = inputPipe
            if let data = activeScriptContent.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
                inputPipe.fileHandleForWriting.closeFile()
            }

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe

            // steamcmd 创意工坊下载不创建中间文件，无法轮询字节数。
            // 进度通过时间估算：假设下载速度不低于 200KB/s，按已耗时推算进度，上限 99%。
            var lastReportedProgress: Double = 0
            let startTime = Date()
            let minSpeed: Double = 500 * 1024  // 500KB/s 最低预估速度
            let pollingTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    guard totalSize > 0 else { continue }
                    let elapsed = Date().timeIntervalSince(startTime)
                    // 基于时间的估算进度 = min(已下载估算 / 总大小, 0.99)
                    // 已下载估算 = max(实际字节数, elapsed * minSpeed)
                    let currentBytes = Self.dirSize(downloadDir.appendingPathComponent("steamapps"))
                    let estimatedBytes = max(Double(currentBytes), elapsed * minSpeed)
                    let progress = min(estimatedBytes / Double(totalSize), 0.99)
                    if progress > lastReportedProgress + 0.001 {
                        lastReportedProgress = progress
                        progressHandler?(progress)
                    }
                }
            }

            final class OutputBox: @unchecked Sendable {
                var output = ""
                var error = ""
                private let lock = NSLock()
                func appendOutput(_ str: String) {
                    lock.lock(); output.append(str); lock.unlock()
                }
                func appendError(_ str: String) {
                    lock.lock(); error.append(str); lock.unlock()
                }
                func combined() -> String {
                    lock.lock(); defer { lock.unlock() }
                    return output + "\n" + error
                }
                func outputString() -> String {
                    lock.lock(); defer { lock.unlock() }
                    return output
                }
                func errorString() -> String {
                    lock.lock(); defer { lock.unlock() }
                    return error
                }
            }
            let outputBox = OutputBox()

            // steamcmd 创意工坊下载不输出进度，所有输出仅用于最终错误判断
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                if let str = String(data: handle.availableData, encoding: .utf8) {
                    outputBox.appendOutput(str)
                }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                if let str = String(data: handle.availableData, encoding: .utf8) {
                    outputBox.appendError(str)
                }
            }

            final class TimeoutFlag: @unchecked Sendable {
                private let lock = NSLock()
                private var _value = false
                var value: Bool {
                    get { lock.lock(); defer { lock.unlock() }; return _value }
                    set { lock.lock(); _value = newValue; lock.unlock() }
                }
            }
            let timeoutFlag = TimeoutFlag()

            final class ResumeBox<T: Sendable>: @unchecked Sendable {
                private var didResume = false
                private let lock = NSLock()
                private let continuation: CheckedContinuation<T, any Error>
                private let outputPipe: Pipe?
                private let errorPipe: Pipe?
                private let timeoutTask: Task<Void, Never>?
                private let pollingTask: Task<Void, Never>?
                init(continuation: CheckedContinuation<T, any Error>, outputPipe: Pipe? = nil, errorPipe: Pipe? = nil, timeoutTask: Task<Void, Never>? = nil, pollingTask: Task<Void, Never>? = nil) {
                    self.continuation = continuation
                    self.outputPipe = outputPipe
                    self.errorPipe = errorPipe
                    self.timeoutTask = timeoutTask
                    self.pollingTask = pollingTask
                }
                private func cleanup() {
                    timeoutTask?.cancel()
                    pollingTask?.cancel()
                    outputPipe?.fileHandleForReading.readabilityHandler = nil
                    errorPipe?.fileHandleForReading.readabilityHandler = nil
                }
                func resume(returning value: T) {
                    lock.lock()
                    guard !didResume else { lock.unlock(); return }
                    didResume = true
                    lock.unlock()
                    cleanup()
                    continuation.resume(returning: value)
                }
                func resume(throwing error: Error) {
                    lock.lock()
                    guard !didResume else { lock.unlock(); return }
                    didResume = true
                    lock.unlock()
                    cleanup()
                    continuation.resume(throwing: error)
                }
            }

            let timeoutSeconds: UInt64 = 600
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if task.isRunning {
                    timeoutFlag.value = true
                    task.terminate()
                }
            }

            let resumeBox = ResumeBox<URL>(
                continuation: continuation,
                outputPipe: outputPipe,
                errorPipe: errorPipe,
                timeoutTask: timeoutTask,
                pollingTask: pollingTask
            )

            task.terminationHandler = { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
                    // 超时导致的终止，直接返回明确的超时错误
                    if timeoutFlag.value {
                        resumeBox.resume(throwing: WorkshopError.timeout)
                        return
                    }

                    let combinedOutput = outputBox.combined()
                    AppLogger.info(.media, "downloadWorkshopItem steamcmd output", metadata: ["output": combinedOutput])

                    // 检查是否需要用户通过手机 App 确认登录（移动验证器类型）
                    let needsMobileConfirmation = [
                        "Please confirm the login",
                        "Waiting for confirmation"
                    ].contains { combinedOutput.localizedCaseInsensitiveContains($0) }
                    // 如果需要确认，检查是否已经确认成功
                    let mobileConfirmationSucceeded = combinedOutput.localizedCaseInsensitiveContains("Waiting for confirmation...OK")
                        || combinedOutput.localizedCaseInsensitiveContains("Waiting for confirmation... OK")

                    // 移动验证器确认已成功 → 登录通过，不需要再检查 guardCode
                    if needsMobileConfirmation && mobileConfirmationSucceeded {
                        // 继续往下检查下载是否成功
                    } else {
                        // 非移动确认场景：检查是否需要验证码（邮箱验证器、独立验证器等）
                        let needsGuardCode = [
                            "Steam Guard code:",
                            "Enter your two-factor authentication code"
                        ].contains { combinedOutput.localizedCaseInsensitiveContains($0) }

                        // 移动确认场景但确认未成功
                        let confirmationMissing = needsMobileConfirmation && !mobileConfirmationSucceeded

                        // 需要移动确认但用户未确认 → 账号本身没问题，保留凭据，提示去 App 确认
                        if confirmationMissing {
                            resumeBox.resume(throwing: WorkshopError.confirmationRequired("请在 Steam App 中确认登录请求后重试下载"))
                            return
                        }

                        // 需要邮箱验证码但没有提供 → 登录会话无效，清理本地账号
                        let guardCodeMissing = needsGuardCode
                        if guardCodeMissing {
                            Task { @MainActor in
                                WorkshopSourceManager.shared.clearSteamCredentials()
                            }
                            resumeBox.resume(throwing: WorkshopError.sessionExpired)
                            return
                        }
                    }

                    // 检查 SteamCMD 自身的登录超时（网络问题导致连接 Steam 服务器超时）
                    // 纯网络问题不清账号
                    let loginTimeoutIndicators = [
                        "ERROR (Timeout)",
                        "Connection timed out",
                        "Could not connect to Steam network",
                        "Operation timed out",
                        "Network is unreachable",
                        "No route to host",
                        "Connection refused",
                        "Unable to connect to Steam",
                        "Failed to connect to Steam",
                        "login failed: No Connection"
                    ]
                    if loginTimeoutIndicators.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) }) {
                        let cleaned = Self.cleanSteamCMDError(outputBox.errorString().isEmpty ? outputBox.outputString() : outputBox.errorString())
                        resumeBox.resume(throwing: WorkshopError.loginTimeout)
                        AppLogger.error(.media, "downloadWorkshopItem login timeout detected", metadata: ["detail": cleaned])
                        return
                    }

                    // 真实登录/会话错误：清理本地账号，要求重新登录
                    let sessionExpiredKeywords = [
                        "ERROR! Not logged on",
                        "Not logged on",
                        "No login session, exiting"
                    ]
                    if sessionExpiredKeywords.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) }) {
                        Task { @MainActor in
                            WorkshopSourceManager.shared.clearSteamCredentials()
                        }
                        resumeBox.resume(throwing: WorkshopError.sessionExpired)
                        return
                    }

                    // 限流 / 无订阅：不是账号密码错误，保留凭据
                    if combinedOutput.localizedCaseInsensitiveContains("RateLimitExceeded") {
                        resumeBox.resume(throwing: WorkshopError.downloadFailed("Steam 请求过于频繁，请稍后再试"))
                        return
                    }
                    if combinedOutput.localizedCaseInsensitiveContains("No subscriptions") {
                        resumeBox.resume(throwing: WorkshopError.downloadFailed("当前 Steam 账号没有可用的 Workshop 订阅权限"))
                        return
                    }

                    let authFailureKeywords = [
                        "Invalid Password",
                        "Login Failure",
                        "FAILED (Account",
                        "Account Logon Denied",
                        "Account disabled",
                        "Account locked",
                        "Two-factor code mismatch"
                    ]
                    if authFailureKeywords.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) }) {
                        Task { @MainActor in
                            WorkshopSourceManager.shared.clearSteamCredentials()
                        }
                        resumeBox.resume(throwing: WorkshopError.invalidCredentials)
                        return
                    }

                    // Workshop 下载失败（SteamCMD 侧报告，可能是临时网络问题，可重试）
                    let downloadFailureKeywords = [
                        "Workshop download failed",
                        "Download item",  // 仅匹配 "Download item XXXXX failed" 类错误
                        "ERROR! Download"
                    ]
                    if downloadFailureKeywords.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) })
                        && !combinedOutput.localizedCaseInsensitiveContains("Download Complete") {
                        let cleaned = Self.cleanSteamCMDError(outputBox.errorString().isEmpty ? outputBox.outputString() : outputBox.errorString())
                        resumeBox.resume(throwing: WorkshopError.downloadIncomplete(cleaned))
                        return
                    }

                    if FileManager.default.fileExists(atPath: contentPath.path) {
                        resumeBox.resume(returning: contentPath)
                        return
                    }

                    let isSelfUpdate = combinedOutput.localizedCaseInsensitiveContains("Update complete, launching")
                    if isSelfUpdate {
                        Task {
                            let pollTimeoutSeconds = 180
                            AppLogger.info(.media, "SteamCMD self-update detected", metadata: ["timeout": pollTimeoutSeconds])
                            for elapsed in 1...pollTimeoutSeconds {
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                if elapsed % 10 == 0 || elapsed == 1 {
                                    AppLogger.info(.media, "Polling SteamCMD", metadata: ["elapsed": elapsed])
                                }
                                if FileManager.default.fileExists(atPath: contentPath.path) {
                                    AppLogger.info(.media, "Workshop content detected", metadata: ["elapsed": elapsed])
                                    resumeBox.resume(returning: contentPath)
                                    return
                                }
                            }
                            let cleaned = Self.cleanSteamCMDError(outputBox.errorString().isEmpty ? outputBox.outputString() : outputBox.errorString())
                            resumeBox.resume(throwing: WorkshopError.downloadFailed("SteamCMD 正在更新，但壁纸未能在预期时间内下载完成（已等待 \(pollTimeoutSeconds) 秒，建议重试）\n\(cleaned)"))
                        }
                        return
                    }

                    let confirmationTimedOut = combinedOutput.localizedCaseInsensitiveContains("Wait for confirmation timed out")
                        || combinedOutput.localizedCaseInsensitiveContains("Timed out waiting for confirmation")
                    if confirmationTimedOut {
                        resumeBox.resume(throwing: WorkshopError.guardCodeRequired("等待 Steam Guard 确认超时。如使用手机验证器，请在 Steam App 中点击确认后重试。"))
                        return
                    }

                    let trimmedOutput = combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedOutput.isEmpty || trimmedOutput.localizedCaseInsensitiveContains("killed") {
                        resumeBox.resume(throwing: WorkshopError.timeout)
                        return
                    }

                    if task.terminationStatus == 0 {
                        let cleaned = Self.cleanSteamCMDError(outputBox.errorString().isEmpty ? outputBox.outputString() : outputBox.errorString())
                        let detail = cleaned.isEmpty ? "SteamCMD 已退出但未生成下载内容" : cleaned
                        resumeBox.resume(throwing: WorkshopError.downloadFailed("下载未完成: \(detail)"))
                    } else {
                        let cleaned = Self.cleanSteamCMDError(outputBox.errorString().isEmpty ? outputBox.outputString() : outputBox.errorString())
                        resumeBox.resume(throwing: WorkshopError.downloadFailed(cleaned))
                    }
                }
            }

            do {
                try task.run()
            } catch {
                resumeBox.resume(throwing: WorkshopError.executionFailed(error.localizedDescription))
            }
        }
    }

    /// 从 SteamCMD 输出中解析下载进度
    /// 支持旧格式 "[ 10%]" 和新格式 "[Progress] X.X% (Y / Z bytes)"
    nonisolated private static func extractSteamCMDProgress(from output: String) -> Double? {
        // 旧格式: "[  0%]", "[ 10%]", "[100%]" 等
        let legacyPattern = #"\[\s*(\d+)%\]"#
        // 新格式 (2023+): "[Progress] 45.2% (1024000 / 2270464 bytes)"
        let progressPattern = #"\[Progress\]\s*(\d+(?:\.\d+)?)%"#

        for pattern in [progressPattern, legacyPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..., in: output)
            // 取最后一处匹配（最新的进度）
            guard let match = regex.matches(in: output, options: [], range: range).last,
                  let numberRange = Range(match.range(at: 1), in: output),
                  let percent = Double(output[numberRange]) else { continue }
            // 旧格式是 0-100，新格式可能是 0.0-100.0
            return percent > 1 ? percent / 100.0 : percent
        }
        return nil
    }

    /// 递归计算目录下所有文件的总大小（字节），用于轮询下载进度
    /// 注意：不跳过隐藏文件，因为 steamcmd 下载时可能创建隐藏临时文件
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

    /// 清理 steamcmd 错误输出
    nonisolated private static func cleanSteamCMDError(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines)
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            if trimmed.localizedCaseInsensitiveContains("Redirecting stderr") { return false }
            if trimmed.localizedCaseInsensitiveContains("Checking for available update") { return false }
            if trimmed.localizedCaseInsensitiveContains("Download Complete") && trimmed.hasPrefix("[") { return false }
            if trimmed.localizedCaseInsensitiveContains("Update complete") { return false }
            if trimmed.hasPrefix("[") && trimmed.contains("%") && trimmed.localizedCaseInsensitiveContains("Downloading update") { return false }
            if trimmed.hasPrefix("[----]") && (trimmed.contains("Extracting") || trimmed.contains("Installing") || trimmed.contains("Cleaning up") || trimmed.contains("Applying update") || trimmed.contains("Launching")) { return false }
            if trimmed.contains("ILocalize::AddFile() failed") { return false }
            return true
        }
        var result = filtered.joined(separator: "\n")
        let maxLength = 800
        if result.count > maxLength {
            let endIndex = result.index(result.startIndex, offsetBy: maxLength)
            result = String(result[..<endIndex]) + "\n..."
        }
        return result
    }

    /// 将 SteamCMD 登录阶段的原始输出整理成可展示给用户的诊断信息。
    nonisolated private static func steamCMDLoginFailureDetail(from raw: String) -> String {
        let cleaned = cleanSteamCMDError(raw)
        let detail = cleaned.isEmpty ? "SteamCMD 未返回可解析的错误输出。" : cleaned

        let knownReasons: [(String, String)] = [
            ("Invalid Password", "Steam 返回：账号名或密码不正确。"),
            ("Two-factor code mismatch", "Steam 返回：Steam Guard 验证码不正确或已过期。"),
            ("RateLimitExceeded", "Steam 返回：登录尝试过于频繁，请稍后再试。"),
            ("Account Logon Denied", "Steam 返回：登录被拒绝，可能需要邮箱确认、Steam Guard 或解除账号安全限制。"),
            ("FAILED (Account", "Steam 返回：账号登录失败，请检查账号状态或 Steam Guard 要求。"),
            ("Account disabled", "Steam 返回：账号已被禁用。"),
            ("Account locked", "Steam 返回：账号已被锁定。"),
            ("No subscriptions", "Steam 返回：该账号没有可用订阅或无权访问该内容。"),
            ("Login Failure", "Steam 返回：登录失败。")
        ]

        if let reason = knownReasons.first(where: { raw.localizedCaseInsensitiveContains($0.0) })?.1 {
            return "\(reason)\n\nSteamCMD 原始信息：\n\(detail)"
        }

        return "SteamCMD 登录失败。\n\nSteamCMD 原始信息：\n\(detail)"
    }

    /// SteamCMD runscript 参数使用双引号包裹；这里统一转义会破坏脚本行结构的字符。
    nonisolated private static func steamCMDScriptArgument(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return "\"\(escaped)\""
    }

    nonisolated private static func steamCMDEnvironment(steamcmdDirectory: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_LIBRARY_PATH"] = steamcmdDirectory.path
        environment["DYLD_FRAMEWORK_PATH"] = steamcmdDirectory.path
        applySteamCMDProxyEnvironment(to: &environment)
        return environment
    }

    nonisolated private static func applySteamCMDProxyEnvironment(to environment: inout [String: String]) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "proxy_enabled"),
           let host = defaults.string(forKey: "proxy_host"), !host.isEmpty,
           let portStr = defaults.string(forKey: "proxy_port"),
           let port = Int(portStr), port > 0 {
            let proxyURL = "http://\(host):\(port)"
            environment["HTTP_PROXY"] = proxyURL
            environment["HTTPS_PROXY"] = proxyURL
            environment["http_proxy"] = proxyURL
            environment["https_proxy"] = proxyURL
            return
        }

        guard let systemProxy = systemProxyEnvironmentForSteamCMD() else { return }
        for (key, value) in systemProxy {
            environment[key] = value
        }
    }

    nonisolated private static func systemProxyEnvironmentForSteamCMD() -> [String: String]? {
        guard let unmanagedSettings = CFNetworkCopySystemProxySettings() else { return nil }
        let settings = unmanagedSettings.takeRetainedValue() as NSDictionary
        var environment: [String: String] = [:]

        if let httpProxy = proxyURL(
            settings: settings,
            enabledKey: kCFNetworkProxiesHTTPEnable,
            hostKey: kCFNetworkProxiesHTTPProxy,
            portKey: kCFNetworkProxiesHTTPPort,
            scheme: "http"
        ) {
            environment["HTTP_PROXY"] = httpProxy
            environment["http_proxy"] = httpProxy
        }

        if let httpsProxy = proxyURL(
            settings: settings,
            enabledKey: kCFNetworkProxiesHTTPSEnable,
            hostKey: kCFNetworkProxiesHTTPSProxy,
            portKey: kCFNetworkProxiesHTTPSPort,
            scheme: "http"
        ) {
            environment["HTTPS_PROXY"] = httpsProxy
            environment["https_proxy"] = httpsProxy
        } else if let httpProxy = environment["HTTP_PROXY"] {
            environment["HTTPS_PROXY"] = httpProxy
            environment["https_proxy"] = httpProxy
        }

        if let socksProxy = proxyURL(
            settings: settings,
            enabledKey: kCFNetworkProxiesSOCKSEnable,
            hostKey: kCFNetworkProxiesSOCKSProxy,
            portKey: kCFNetworkProxiesSOCKSPort,
            scheme: "socks5h"
        ) {
            environment["ALL_PROXY"] = socksProxy
            environment["all_proxy"] = socksProxy
        }

        return environment.isEmpty ? nil : environment
    }

    nonisolated private static func proxyURL(
        settings: NSDictionary,
        enabledKey: CFString,
        hostKey: CFString,
        portKey: CFString,
        scheme: String
    ) -> String? {
        let enabled = (settings[enabledKey] as? NSNumber)?.boolValue ?? false
        guard enabled,
              let host = settings[hostKey] as? String, !host.isEmpty,
              let port = (settings[portKey] as? NSNumber)?.intValue, port > 0 else {
            return nil
        }
        return "\(scheme)://\(host):\(port)"
    }

    /// 判断 SteamCMD 输出是否表示登录成功
    nonisolated private static func isSteamLoginSuccessful(_ output: String) -> Bool {
        let patterns = [
            "Waiting for user info\\.\\.\\.\\s*OK",
            "Logged in OK",
            "Logon successful"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - App Availability

    func verifySteamLogin(username: String, password: String, guardCode: String? = nil, retryCount: Int = 0) async throws {
        guard let steamcmdPath = WorkshopSourceManager.shared.steamCMDExecutableURL() else {
            throw WorkshopError.steamcmdNotFound
        }

        AppLogger.info(.media, "verifySteamLogin", metadata: ["path": steamcmdPath.path])

        var loginParts = [
            "login",
            Self.steamCMDScriptArgument(username),
            Self.steamCMDScriptArgument(password)
        ]
        if let code = guardCode, !code.isEmpty {
            loginParts.append(Self.steamCMDScriptArgument(code))
        }
        let loginLine = loginParts.joined(separator: " ")

        let scriptContent = ["@NoPromptForPassword 1", loginLine, "quit"].joined(separator: "\n")

        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            // 直接执行 steamcmd 二进制，绕过 steamcmd.sh 脚本中路径空格导致的解析问题
            // 同时通过 stdin Pipe 发送命令，绕过 macOS 上 +runscript 卡死的问题
            let steamcmdBinURL = steamcmdPath.deletingLastPathComponent().appendingPathComponent("steamcmd")
            task.executableURL = steamcmdBinURL
            task.arguments = []
            task.currentDirectoryURL = steamcmdPath.deletingLastPathComponent()
            let environment = WorkshopService.steamCMDEnvironment(steamcmdDirectory: steamcmdPath.deletingLastPathComponent())
            task.environment = environment

            let inputPipe = Pipe()
            task.standardInput = inputPipe
            if let data = scriptContent.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
                inputPipe.fileHandleForWriting.closeFile()
            }

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe

            final class VerifyOutputBox: @unchecked Sendable {
                var output = ""
                var error = ""
                private let lock = NSLock()
                func appendOutput(_ str: String) {
                    lock.lock(); output.append(str); lock.unlock()
                }
                func appendError(_ str: String) {
                    lock.lock(); error.append(str); lock.unlock()
                }
                func combined() -> String {
                    lock.lock(); defer { lock.unlock() }
                    return output + "\n" + error
                }
                func outputString() -> String {
                    lock.lock(); defer { lock.unlock() }
                    return output
                }
                func errorString() -> String {
                    lock.lock(); defer { lock.unlock() }
                    return error
                }
            }
            let outputBox = VerifyOutputBox()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                if let str = String(data: handle.availableData, encoding: .utf8) {
                    outputBox.appendOutput(str)
                }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                if let str = String(data: handle.availableData, encoding: .utf8) {
                    outputBox.appendError(str)
                }
            }

            final class ResumeBox<T: Sendable>: @unchecked Sendable {
                private var didResume = false
                private let lock = NSLock()
                private let continuation: CheckedContinuation<T, any Error>
                private let outputPipe: Pipe?
                private let errorPipe: Pipe?
                private let timeoutTask: Task<Void, Never>?
                init(continuation: CheckedContinuation<T, any Error>, outputPipe: Pipe? = nil, errorPipe: Pipe? = nil, timeoutTask: Task<Void, Never>? = nil) {
                    self.continuation = continuation
                    self.outputPipe = outputPipe
                    self.errorPipe = errorPipe
                    self.timeoutTask = timeoutTask
                }
                private func cleanup() {
                    timeoutTask?.cancel()
                    outputPipe?.fileHandleForReading.readabilityHandler = nil
                    errorPipe?.fileHandleForReading.readabilityHandler = nil
                }
                func resume(returning value: T) {
                    lock.lock()
                    guard !didResume else { lock.unlock(); return }
                    didResume = true
                    lock.unlock()
                    cleanup()
                    continuation.resume(returning: value)
                }
                func resume(throwing error: Error) {
                    lock.lock()
                    guard !didResume else { lock.unlock(); return }
                    didResume = true
                    lock.unlock()
                    cleanup()
                    continuation.resume(throwing: error)
                }
            }

            let timeoutSeconds: UInt64 = 300
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if task.isRunning {
                    task.terminate()
                }
            }

            let resumeBox = ResumeBox<Void>(
                continuation: continuation,
                outputPipe: outputPipe,
                errorPipe: errorPipe,
                timeoutTask: timeoutTask
            )

            task.terminationHandler = { _ in
                // 小延迟确保 readabilityHandler 处理完最后的数据
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
                    let combinedOutput = outputBox.combined()
                    AppLogger.info(.media, "verifySteamLogin steamcmd output", metadata: ["output": combinedOutput])

                    let isSelfUpdate = combinedOutput.localizedCaseInsensitiveContains("Update complete, launching")
                    if isSelfUpdate {
                        guard retryCount < 2 else {
                            resumeBox.resume(throwing: WorkshopError.downloadFailed("SteamCMD 自更新重试次数过多"))
                            return
                        }
                        Task { @MainActor in
                            do {
                                try await self.verifySteamLogin(username: username, password: password, guardCode: guardCode, retryCount: retryCount + 1)
                                resumeBox.resume(returning: ())
                            } catch {
                                resumeBox.resume(throwing: error)
                            }
                        }
                        return
                    }

                    // 检查是否需要用户通过手机 App 确认登录（移动验证器类型）
                    let needsMobileConfirmation = combinedOutput.localizedCaseInsensitiveContains("Please confirm the login")
                    // 如果需要确认，检查是否已经确认成功（"Waiting for confirmation...OK" 表示用户已在 App 中确认）
                    let mobileConfirmationSucceeded = combinedOutput.localizedCaseInsensitiveContains("Waiting for confirmation...OK")
                        || combinedOutput.localizedCaseInsensitiveContains("Waiting for confirmation... OK")

                    // 移动验证器确认已成功 → 登录通过，不需要再检查 guardCode
                    if needsMobileConfirmation && mobileConfirmationSucceeded {
                        // 继续往下检查登录是否真正成功
                    } else {
                        // 非移动确认场景：检查是否需要验证码（邮箱验证器、独立验证器等）
                        let needsGuardCode = [
                            "Steam Guard code:",
                            "Enter your two-factor authentication code"
                        ].contains { combinedOutput.localizedCaseInsensitiveContains($0) }

                        // 移动确认场景但确认未成功
                        let confirmationMissing = needsMobileConfirmation && !mobileConfirmationSucceeded

                        // 如果需要验证码但没有提供，或者需要移动确认但确认未成功，都报错
                        let guardCodeMissing = needsGuardCode && (guardCode?.isEmpty != false)
                        if guardCodeMissing || confirmationMissing {
                            resumeBox.resume(throwing: WorkshopError.guardCodeRequired("该账号受 Steam Guard 保护。如需验证码请填写后重试；如使用手机验证器，请在 Steam App 中确认登录后重试。"))
                            return
                        }
                    }

                    // 检查 SteamCMD 自身的登录超时（网络问题导致连接 Steam 服务器超时）
                    let loginTimeoutIndicators = [
                        "ERROR (Timeout)",
                        "Connection timed out",
                        "Could not connect to Steam network",
                        "Operation timed out",
                        "Network is unreachable",
                        "No route to host",
                        "Connection refused",
                        "Unable to connect to Steam",
                        "Failed to connect to Steam"
                    ]
                    if loginTimeoutIndicators.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) }) {
                        AppLogger.error(.media, "verifySteamLogin login timeout detected")
                        resumeBox.resume(throwing: WorkshopError.loginTimeout)
                        return
                    }

                    let authFailureKeywords = [
                        "Invalid Password",
                        "Login Failure",
                        "FAILED (Account",
                        "Account Logon Denied",
                        "Account disabled",
                        "Account locked",
                        "RateLimitExceeded",
                        "Two-factor code mismatch",
                        "No subscriptions"
                    ]
                    if authFailureKeywords.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) }) {
                        let detail = WorkshopService.steamCMDLoginFailureDetail(from: combinedOutput)
                        resumeBox.resume(throwing: WorkshopError.steamLoginFailed(detail))
                        return
                    }

                    if Self.isSteamLoginSuccessful(combinedOutput) {
                        resumeBox.resume(returning: ())
                        return
                    }

                    let confirmationTimedOut = combinedOutput.localizedCaseInsensitiveContains("Wait for confirmation timed out")
                        || combinedOutput.localizedCaseInsensitiveContains("Timed out waiting for confirmation")
                    if confirmationTimedOut {
                        resumeBox.resume(throwing: WorkshopError.guardCodeRequired("等待 Steam Guard 确认超时。如使用手机验证器，请在 Steam App 中点击确认后重试。"))
                        return
                    }

                    let trimmedOutput = combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedOutput.isEmpty || trimmedOutput.localizedCaseInsensitiveContains("killed") {
                        resumeBox.resume(throwing: WorkshopError.timeout)
                        return
                    }

                    let cleaned = WorkshopService.cleanSteamCMDError(outputBox.errorString().isEmpty ? outputBox.outputString() : outputBox.errorString())
                    resumeBox.resume(throwing: WorkshopError.downloadFailed(cleaned))
                }
            }

            do {
                try task.run()
            } catch {
                resumeBox.resume(throwing: WorkshopError.executionFailed(error.localizedDescription))
            }
        }
    }

    func checkSteamCMDStatus() -> SteamCMDStatus {
        guard let steamcmdPath = WorkshopSourceManager.shared.steamCMDExecutableURL() else {
            if let setupError = WorkshopSourceManager.shared.steamCMDLastSetupError {
                return .error(setupError)
            }
            return .notInstalled
        }
        // steamCMDExecutableURL() 已验证安装完整性，此处再确认二进制文件存在
        let steamcmdBinPath = steamcmdPath.deletingLastPathComponent().appendingPathComponent("steamcmd")
        guard FileManager.default.fileExists(atPath: steamcmdBinPath.path) else {
            if let setupError = WorkshopSourceManager.shared.steamCMDLastSetupError {
                return .error(setupError)
            }
            return .notInstalled
        }
        return .ready
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

// MARK: - SteamCMD 解压目录 → 真实 WE 工程根

extension WorkshopService {
    /// Canonicalize both SteamCMD's outer download directory and the nested content directory.
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

    /// SteamCMD 解压路径常为 `.../steamapps/workshop/content/431960/<id>/`，但 `project.json` 往往在**唯一子目录**或**多子目录之一**内。
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
            // SteamCMD 下载壳目录：downloads / temp 不含 project.json，跳过可加速定位 content/<appid>/<id>
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
    case steamcmdNotFound
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

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的链接"
        case .apiError(let msg): return msg
        case .steamcmdNotFound: return "SteamCMD 组件缺失，请重新安装应用"
        case .credentialsRequired: return "需要登录 Steam 账号，请在设置中登录 SteamCMD"
        case .invalidCredentials: return "Steam 账号或密码错误，或需要 Steam Guard 验证码"
        case .steamLoginFailed(let msg): return msg
        case .sessionExpired: return "Steam 登录已过期，请在设置中重新登录"
        case .loginTimeout: return "Steam 登录超时，可能是网络不稳定或 Steam 服务器繁忙，请检查网络后重试"
        case .guardCodeRequired(let msg): return msg
        case .confirmationRequired(let msg): return msg
        case .timeout: return "下载超时（已等待 10 分钟），可能是网络波动或文件过大，请检查网络后重试"
        case .downloadIncomplete(let msg): return msg.isEmpty ? "下载未完成，SteamCMD 进程异常退出，请重试" : msg
        case .downloadFailed(let msg): return "下载失败：\(msg)"
        case .executionFailed(let msg): return "执行失败：\(msg)"
        case .workshopNotSupported: return "非 Workshop 项目"
        }
    }
}

enum SteamCMDStatus {
    case ready
    case notInstalled
    case error(String)
    case downloading
}
