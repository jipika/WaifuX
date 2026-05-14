import Foundation
import AppKit
import CFNetwork
import SwiftSoup

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

    // MARK: - Configuration

    private let wallpaperEngineAppID = "431960"
    private let steamAPIBase = "https://api.steampowered.com"
    private var currentPage = 1
    private let pageSize = 20

    /// 主窗口长期隐藏后释放 Workshop 浏览结果；后台下载/动态壁纸渲染不依赖这些前台列表。
    func clearForegroundState() {
        isLoading = false
        errorMessage = nil
        searchResults.removeAll()
        hasMorePages = false
        currentPage = 1
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
        // [强制规则] 默认 Everyone；仅允许传入 Everyone 或 Questionable，禁止 Mature
        let effectiveContentLevel = params.contentLevel ?? "Everyone"
        if effectiveContentLevel == "Everyone" || effectiveContentLevel == "Questionable" {
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
                    guard let authorName = authorMap[item.id], authorName != "Unknown" else { return item }
                    return WorkshopWallpaper(
                        id: item.id,
                        title: item.title,
                        description: item.description,
                        previewURL: item.previewURL,
                        author: WorkshopAuthor(steamID: item.author.steamID, name: authorName, avatarURL: item.author.avatarURL),
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

            let isAnimatedImage = previewURL?.absoluteString.lowercased().contains(".gif") ?? false
            wallpapers.append(WorkshopWallpaper(
                id: id,
                title: title,
                description: nil,
                previewURL: previewURL,
                author: WorkshopAuthor(steamID: "", name: authorName, avatarURL: nil),
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

    /// 从 HTML DOM 提取作者名映射（用于补充 JSON/SSR 提取缺失的作者显示名）
    private func extractAuthorMapFromHTML(_ html: String) -> [String: String] {
        guard let document = try? SwiftSoup.parse(html) else { return [:] }
        let links = try? document.select("a[href*=/sharedfiles/filedetails/?id=]")

        var authorMap: [String: String] = [:]
        var seenIDs = Set<String>()

        for link in links ?? Elements() {
            let href = (try? link.attr("href")) ?? ""
            guard let id = href.components(separatedBy: "id=").last?.components(separatedBy: "&").first, !id.isEmpty else { continue }
            guard !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)

            var authorName = "Unknown"
            var current: Element? = link
            for _ in 0..<5 {
                guard let parent = current?.parent() else { break }
                current = parent
                let profileLinks = try? parent.select("a[href*=/profiles/], a[href*=/id/]")
                for profileLink in profileLinks ?? Elements() {
                    let name = (try? profileLink.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !name.isEmpty && name != "Untitled" && !name.contains("http") {
                        authorName = name
                        break
                    }
                }
                if authorName != "Unknown" { break }
            }

            if authorName != "Unknown" {
                authorMap[id] = authorName
            }
        }

        return authorMap
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
                avatarURL: nil
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

                        // 需要移动确认但用户未确认 → 不要清除凭据，提示用户去 App 中确认
                        if confirmationMissing {
                            resumeBox.resume(throwing: WorkshopError.confirmationRequired("请在 Steam App 中确认登录请求后重试下载"))
                            return
                        }

                        // 需要邮箱验证码但没有提供 → 说明缓存已失效，清除凭据
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
                        let cleaned = Self.cleanSteamCMDError(outputBox.errorString().isEmpty ? outputBox.outputString() : outputBox.errorString())
                        resumeBox.resume(throwing: WorkshopError.loginTimeout)
                        AppLogger.error(.media, "downloadWorkshopItem login timeout detected", metadata: ["detail": cleaned])
                        return
                    }

                    // session token 过期或网络导致的登录失败
                    let sessionExpiredKeywords = [
                        "ERROR! Not logged on",
                        "Not logged on",
                        "No login session, exiting",
                        "login failed: No Connection",
                        "Login Failure"
                    ]
                    if sessionExpiredKeywords.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) }) {
                        // 会话已失效，自动清除过期凭据并提示用户重新登录
                        Task { @MainActor in
                            WorkshopSourceManager.shared.clearSteamCredentials()
                        }
                        resumeBox.resume(throwing: WorkshopError.sessionExpired)
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
            authorName: wallpaper.author.name != "Unknown" ? wallpaper.author.name : nil,
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
            childDirs.append(entry)
        }
        if childDirs.count == 1 {
            return resolveWEProjectRootRecursive(childDirs[0], depthLeft: depthLeft - 1, fm: fm)
        }
        if childDirs.count > 1 {
            let withProject = childDirs
                .filter { fm.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            if let first = withProject.first {
                return resolveWEProjectRootRecursive(first, depthLeft: depthLeft - 1, fm: fm)
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
        case .sessionExpired: return "Steam 登录已过期，请在设置中重新验证登录"
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
