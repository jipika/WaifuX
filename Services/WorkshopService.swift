import Foundation
import AppKit
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
        // 新版 Steam Workshop browse 使用字符串排序值（返回 React 页面）
        switch sort {
        case .ranked: return "trend"
        case .subscriptions: return "subscribed"
        case .updated: return "updated"
        case .created: return "created"
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
        if let contentLevel = params.contentLevel {
            requiredTags.append(contentLevel)
        }
        for tag in requiredTags {
            queryItems.append(URLQueryItem(name: "requiredtags[]", value: tag))
        }

        queryItems.append(URLQueryItem(name: "p", value: String(params.page)))
        queryItems.append(URLQueryItem(name: "num_per_page", value: String(params.pageSize)))

        var components = URLComponents(string: workshopBrowseBase)
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw WorkshopError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw WorkshopError.apiError("无法解析 HTML 响应")
        }

        // 优先从 SSR JSON 或内嵌 JSON 提取，现代 Steam 页面数据主要在 dehydrated JSON 里
        let extracted = extractFromJSON(html)
        let wallpapers: [WorkshopWallpaper]
        if !extracted.isEmpty {
            wallpapers = extracted
            print("[WorkshopService] searchHTML used JSON/SSR extraction: \(extracted.count) items")
        } else {
            wallpapers = try parseWorkshopHTML(html, page: params.page)
            print("[WorkshopService] searchHTML used HTML parsing: \(wallpapers.count) items")
        }

        // Steam Workshop browse 列表页不返回标签/类型，用请求参数做兜底注入
        let enriched = enrichWorkshopItems(wallpapers, params: params)

        return WorkshopSearchResponse(
            items: enriched,
            total: enriched.count,
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

            // 向上遍历祖先节点，找包含作者信息的文本
            var authorName = "Unknown"
            var current: Element? = link
            for _ in 0..<5 {
                guard let parent = current?.parent() else { break }
                current = parent
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
                subscriptions: 0,
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
            print("[WorkshopService] Error parsing item: \(error)")
            return nil
        }
    }

    private func extractFromJSON(_ html: String) -> [WorkshopWallpaper] {
        var wallpapers: [WorkshopWallpaper] = []

        if let ssrItems = extractFromSSRJSON(html), !ssrItems.isEmpty {
            wallpapers = ssrItems
            print("[WorkshopService] Extracted \(wallpapers.count) items from SSR dehydrated JSON")
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
                        author: WorkshopAuthor(steamID: "", name: item.creator ?? "Unknown", avatarURL: nil),
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
                print("[WorkshopService] Failed to decode embedded JSON: \(error)")
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
            print("[WorkshopService] Failed to decode SSR JSON: \(error)")
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
        guard let steamcmdPath = WorkshopSourceManager.shared.steamCMDExecutableURL() else {
            throw WorkshopError.steamcmdNotFound
        }

        guard let credentials = WorkshopSourceManager.shared.steamCredentials else {
            throw WorkshopError.credentialsRequired
        }

        let downloadDir = DownloadPathManager.shared.mediaFolderURL
            .appendingPathComponent("workshop_\(workshopID)")

        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        // SteamCMD 正确用法：登录时只传用户名，使用缓存的 session token（无需密码和验证码）
        // session token 由 verifySteamLogin 成功后自动缓存在 steamcmd/config/ 目录下
        // 只有 token 过期时才需要重新完整登录（此时用户应回到设置页重新验证）
        let loginLine = "login \"\(credentials.username)\""

        let scriptContent = [
            "@NoPromptForPassword 1",
            "force_install_dir \"\(downloadDir.path)\"",
            loginLine,
            "workshop_download_item \(wallpaperEngineAppID) \(workshopID)",
            "quit"
        ].joined(separator: "\n")

        let scriptURL = downloadDir.appendingPathComponent("download_script.txt")
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)

        let contentPath = downloadDir
            .appendingPathComponent("steamapps/workshop/content/\(wallpaperEngineAppID)/\(workshopID)")

        // 进度脉冲任务
        let progressTask: Task<Void, Never>? = (progressHandler != nil) ? Task {
            var progress: Double = 0.05
            progressHandler?(progress)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                progress = min(progress + 0.03, 0.90)
                progressHandler?(progress)
            }
        } : nil

        defer {
            progressTask?.cancel()
            try? FileManager.default.removeItem(at: scriptURL)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            // steamcmd.sh 是 shell 脚本，需要通过 bash 执行，不能直接作为 Process 的 executable
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [steamcmdPath.path, "+runscript", scriptURL.path]
            task.currentDirectoryURL = steamcmdPath.deletingLastPathComponent()
            var environment = ProcessInfo.processInfo.environment
            environment["DYLD_LIBRARY_PATH"] = steamcmdPath.deletingLastPathComponent().path
            task.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe

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

            let resumeBox = ResumeBox<URL>(
                continuation: continuation,
                outputPipe: outputPipe,
                errorPipe: errorPipe,
                timeoutTask: timeoutTask
            )

            task.terminationHandler = { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    let combinedOutput = outputBox.combined()
                    print("[WorkshopService] downloadWorkshopItem steamcmd output:\n\(combinedOutput)")

                    // 检查是否需要用户通过手机 App 确认登录（移动验证器类型）
                    let needsMobileConfirmation = combinedOutput.localizedCaseInsensitiveContains("Please confirm the login")
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

                        // 如果需要验证码但没有提供，或者需要移动确认但确认未成功，都报错
                        let guardCodeMissing = needsGuardCode  // 下载时不传 guardCode，如果需要说明 token 彻底失效
                        if guardCodeMissing || confirmationMissing {
                            resumeBox.resume(throwing: WorkshopError.sessionExpired)
                            return
                        }
                    }

                    // 检查 SteamCMD 自身的登录超时（网络问题导致连接 Steam 服务器超时）
                    let loginTimeoutIndicators = [
                        "ERROR (Timeout)",
                        "Connection timed out",
                        "Could not connect to Steam network"
                    ]
                    if loginTimeoutIndicators.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) }) {
                        let cleaned = Self.cleanSteamCMDError(outputBox.errorString().isEmpty ? outputBox.outputString() : outputBox.errorString())
                        resumeBox.resume(throwing: WorkshopError.loginTimeout)
                        print("[WorkshopService] downloadWorkshopItem login timeout detected: \(cleaned)")
                        return
                    }

                    // session token 过期：只传用户名登录时 token 无效
                    let sessionExpiredKeywords = [
                        "ERROR! Not logged on",
                        "Not logged on",
                        "No login session, exiting",
                        "login failed: No Connection"
                    ]
                    if sessionExpiredKeywords.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) }) {
                        resumeBox.resume(throwing: WorkshopError.sessionExpired)
                        return
                    }

                    let authFailureKeywords = [
                        "Invalid Password",
                        "Login Failure",
                        "FAILED (Account",
                        "Account Logon Denied",
                        "RateLimitExceeded",
                        "Two-factor code mismatch",
                        "No subscriptions"
                    ]
                    if authFailureKeywords.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) }) {
                        resumeBox.resume(throwing: WorkshopError.invalidCredentials)
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
                            print("[WorkshopService] SteamCMD self-update detected, polling up to \(pollTimeoutSeconds)s")
                            for elapsed in 1...pollTimeoutSeconds {
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                if elapsed % 10 == 0 || elapsed == 1 {
                                    print("[WorkshopService] Polling... elapsed: \(elapsed)s")
                                }
                                if FileManager.default.fileExists(atPath: contentPath.path) {
                                    print("[WorkshopService] Workshop content detected after \(elapsed)s")
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
                        resumeBox.resume(throwing: WorkshopError.downloadIncomplete)
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

    /// 判断 SteamCMD 输出是否表示登录成功
    nonisolated private static func isSteamLoginSuccessful(_ output: String) -> Bool {
        let successIndicators = [
            "Waiting for user info...OK",
            "Waiting for user info... OK",
            "Logged in OK",
            "Logon successful"
        ]
        return successIndicators.contains { output.localizedCaseInsensitiveContains($0) }
    }

    // MARK: - App Availability

    func verifySteamLogin(username: String, password: String, guardCode: String? = nil) async throws {
        guard let steamcmdPath = WorkshopSourceManager.shared.steamCMDExecutableURL() else {
            throw WorkshopError.steamcmdNotFound
        }

        print("[WorkshopService] verifySteamLogin using path: \(steamcmdPath.path)")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("steamcmd_verify_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 密码转义：先转义反斜杠，再转义双引号
        let escapedPassword = password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var loginLine = "login \"\(username)\" \"\(escapedPassword)\""
        if let code = guardCode, !code.isEmpty {
            loginLine += " \"\(code)\""
        }

        let scriptContent = ["@NoPromptForPassword 1", loginLine, "quit"].joined(separator: "\n")
        let scriptURL = tempDir.appendingPathComponent("verify_script.txt")
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            // steamcmd.sh 是 shell 脚本，需要通过 bash 执行，不能直接作为 Process 的 executable
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [steamcmdPath.path, "+runscript", scriptURL.path]
            task.currentDirectoryURL = steamcmdPath.deletingLastPathComponent()
            var environment = ProcessInfo.processInfo.environment
            environment["DYLD_LIBRARY_PATH"] = steamcmdPath.deletingLastPathComponent().path
            task.environment = environment

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
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    let combinedOutput = outputBox.combined()
                    print("[WorkshopService] verifySteamLogin steamcmd output:\n\(combinedOutput)")

                    let isSelfUpdate = combinedOutput.localizedCaseInsensitiveContains("Update complete, launching")
                    if isSelfUpdate {
                        Task { @MainActor in
                            do {
                                try await self.verifySteamLogin(username: username, password: password, guardCode: guardCode)
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
                        "Could not connect to Steam network"
                    ]
                    if loginTimeoutIndicators.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) }) {
                        print("[WorkshopService] verifySteamLogin login timeout detected")
                        resumeBox.resume(throwing: WorkshopError.loginTimeout)
                        return
                    }

                    let authFailureKeywords = [
                        "Invalid Password",
                        "Login Failure",
                        "FAILED (Account",
                        "Account Logon Denied",
                        "RateLimitExceeded",
                        "Two-factor code mismatch",
                        "No subscriptions"
                    ]
                    if authFailureKeywords.contains(where: { combinedOutput.localizedCaseInsensitiveContains($0) }) {
                        resumeBox.resume(throwing: WorkshopError.invalidCredentials)
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
            return .notInstalled
        }
        guard FileManager.default.fileExists(atPath: steamcmdPath.path) else {
            return .notInstalled
        }
        return .ready
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
            isAnimatedImage: wallpaper.isAnimatedImage
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

enum WorkshopError: LocalizedError {
    case invalidURL
    case apiError(String)
    case steamcmdNotFound
    case credentialsRequired
    case invalidCredentials
    case sessionExpired
    case loginTimeout
    case guardCodeRequired(String)
    case timeout
    case downloadIncomplete
    case downloadFailed(String)
    case executionFailed(String)
    case workshopNotSupported

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .apiError(let msg): return msg
        case .steamcmdNotFound: return "SteamCMD not found"
        case .credentialsRequired: return "Steam credentials required"
        case .invalidCredentials: return "Invalid Steam credentials or 2FA required"
        case .sessionExpired: return "Steam 登录已过期，请在设置中重新验证登录"
        case .loginTimeout: return "Steam 登录超时，请检查网络连接后重试"
        case .guardCodeRequired(let msg): return msg
        case .timeout: return "SteamCMD 响应超时，请检查网络连接或稍后重试"
        case .downloadIncomplete: return "Download incomplete"
        case .downloadFailed(let msg): return msg
        case .executionFailed(let msg): return msg
        case .workshopNotSupported: return "Not a Workshop item"
        }
    }
}

enum SteamCMDStatus {
    case ready
    case notInstalled
    case error(String)
    case downloading
}
