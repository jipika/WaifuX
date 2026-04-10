import Foundation

// MARK: - TMDB API 配置

enum TMDBAPI {
    static let baseURL = "https://api.themoviedb.org/3"
    static let imageBaseURL = "https://image.tmdb.org/t/p"
    
    // TMDB API Key - 使用公共只读 key（生产环境应使用自己的 key）
    static let apiKey = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiI1YjBlMWRjM2E3YmY4ZGRkY2Y0ZjA5NjFiMTQ3YjEyOCIsInN1YiI6IjYwYjY5ZGNkNjQ2Mjc4MDA0MWEzZDA4MCIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.Q-ztAKH_bURe_4PpHDjBtbHpaQjTDjIJpE_UG3g3Uek"
    
    /// 搜索动漫
    static func searchAnime(query: String) -> String {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return "\(baseURL)/search/tv?query=\(encodedQuery)&language=zh-CN&page=1"
    }
    
    /// 获取 TV 详情
    static func tvDetail(id: Int) -> String {
        return "\(baseURL)/tv/\(id)?language=zh-CN&append_to_response=images,credits"
    }
    
    /// 获取图片 URL
    static func backdropURL(path: String, size: BackdropSize = .w1280) -> String {
        return "\(imageBaseURL)/\(size.rawValue)\(path)"
    }
    
    static func posterURL(path: String, size: PosterSize = .w500) -> String {
        return "\(imageBaseURL)/\(size.rawValue)\(path)"
    }
    
    enum BackdropSize: String {
        case w300 = "w300"
        case w780 = "w780"
        case w1280 = "w1280"
        case original = "original"
    }
    
    enum PosterSize: String {
        case w92 = "w92"
        case w154 = "w154"
        case w185 = "w185"
        case w342 = "w342"
        case w500 = "w500"
        case w780 = "w780"
        case original = "original"
    }
}

// MARK: - TMDB 数据模型

struct TMDBSearchResponse: Codable {
    let results: [TMDBSearchResult]
    let totalResults: Int?
    let totalPages: Int?
    
    enum CodingKeys: String, CodingKey {
        case results
        case totalResults = "total_results"
        case totalPages = "total_pages"
    }
}

struct TMDBSearchResult: Codable, Identifiable {
    let id: Int
    let name: String
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let voteCount: Int?
    let genreIds: [Int]?
    
    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case originalName = "original_name"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case genreIds = "genre_ids"
    }
}

struct TMDBTVDetail: Codable {
    let id: Int
    let name: String
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let lastAirDate: String?
    let voteAverage: Double?
    let voteCount: Int?
    let numberOfSeasons: Int?
    let numberOfEpisodes: Int?
    let episodeRunTime: [Int]?
    let genres: [TMDBGenre]?
    let status: String?
    let tagline: String?
    let homepage: String?
    let images: TMDBImages?
    
    enum CodingKeys: String, CodingKey {
        case id, name, overview, genres, status, tagline, homepage, images
        case originalName = "original_name"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case firstAirDate = "first_air_date"
        case lastAirDate = "last_air_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case numberOfSeasons = "number_of_seasons"
        case numberOfEpisodes = "number_of_episodes"
        case episodeRunTime = "episode_run_time"
    }
}

struct TMDBGenre: Codable {
    let id: Int
    let name: String
}

struct TMDBImages: Codable {
    let backdrops: [TMDBImage]?
    let posters: [TMDBImage]?
    
    /// 获取最佳横屏背景图
    var bestBackdrop: TMDBImage? {
        guard let backdrops = backdrops, !backdrops.isEmpty else { return nil }
        // 优先选择英文且分辨率高的
        return backdrops.sorted { $0.voteAverage > $1.voteAverage }.first
    }
}

struct TMDBImage: Codable {
    let filePath: String
    let width: Int
    let height: Int
    let aspectRatio: Double
    let voteAverage: Double
    let voteCount: Int
    
    enum CodingKeys: String, CodingKey {
        case width, height
        case filePath = "file_path"
        case aspectRatio = "aspect_ratio"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
    }
}

// MARK: - TMDB 服务

actor TMDBService {
    static let shared = TMDBService()
    
    private let session: URLSession
    private let decoder: JSONDecoder
    
    // 缓存
    private var backdropCache: [String: String] = [:] // animeName -> backdropURL
    private static let backdropCacheKey = "tmdb_backdrop_cache"
    
    // 重试配置
    private let maxRetries = 2
    private let retryDelays: [TimeInterval] = [1.0, 2.0]
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10   // 10秒超时，快速降级
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        
        // 从 UserDefaults 恢复持久化缓存 - 在 Task 中异步调用
        Task {
            await restoreBackdropCache()
        }
    }
    
    // MARK: - 持久化缓存
    
    private func restoreBackdropCache() async {
        guard let data = UserDefaults.standard.data(forKey: Self.backdropCacheKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        backdropCache = decoded
    }
    
    private func persistBackdropCache() {
        guard let data = try? JSONEncoder().encode(backdropCache) else { return }
        UserDefaults.standard.set(data, forKey: Self.backdropCacheKey)
    }
    
    // MARK: - 搜索动漫并获取横屏背景
    
    /// 根据动漫名称搜索并返回最佳匹配的背景图 URL
    /// 使用多种搜索策略确保能找到结果
    func fetchBackdropURL(for animeName: String, originalName: String? = nil) async -> String? {
        // 检查缓存（含持久化）
        if let cached = backdropCache[animeName] {
            return cached
        }
        
        // 策略1: 使用完整名称搜索
        if let result = try? await searchAnimeWithRetry(query: animeName) {
            return await fetchBackdropFromTV(id: result.id, animeName: animeName)
        }
        
        // 策略2: 提取核心关键词搜索
        let keywords = extractCoreKeywords(animeName)
        if keywords.count > 1 {
            let keywordQuery = keywords.joined(separator: " ")
            if let result = try? await searchAnimeWithRetry(query: keywordQuery) {
                return await fetchBackdropFromTV(id: result.id, animeName: animeName)
            }
        }
        
        // 策略3: 使用原名（日文/英文）搜索
        if let originalName = originalName, originalName != animeName {
            if let result = try? await searchAnimeWithRetry(query: originalName) {
                return await fetchBackdropFromTV(id: result.id, animeName: animeName)
            }
        }
        
        // 策略4: 尝试去除"第二季"、"剧场版"等后缀搜索
        let seasonPattern = try? NSRegularExpression(pattern: "第[一二三四五六七八九十0-9]+季|Season\\s*\\d+|剧场版|Movie|OVA|Special", options: [])
        let range = NSRange(animeName.startIndex..., in: animeName)
        if let cleanedName = seasonPattern?.stringByReplacingMatches(in: animeName, options: [], range: range, withTemplate: "").trimmingCharacters(in: .whitespaces),
           cleanedName != animeName,
           !cleanedName.isEmpty {
            if let result = try? await searchAnimeWithRetry(query: cleanedName) {
                return await fetchBackdropFromTV(id: result.id, animeName: animeName)
            }
        }
        
        // 策略5: 尝试取前N个字符搜索（适合长标题）
        if animeName.count > 10 {
            let shortName = String(animeName.prefix(10))
            if let result = try? await searchAnimeWithRetry(query: shortName) {
                return await fetchBackdropFromTV(id: result.id, animeName: animeName)
            }
        }
        
        return nil
    }
    
    /// 获取动漫详情中的背景图
    func fetchBackdropFromTV(id: Int, animeName: String) async -> String? {
        do {
            let detail = try await fetchTVDetailWithRetry(id: id)
            
            // 优先使用 backdropPath
            if let backdropPath = detail.backdropPath, !backdropPath.isEmpty {
                let url = TMDBAPI.backdropURL(path: backdropPath, size: .original)
                backdropCache[animeName] = url
                persistBackdropCache()
                return url
            }
            
            // 备用：从 images.backdrops 中获取
            if let bestBackdrop = detail.images?.bestBackdrop {
                let url = TMDBAPI.backdropURL(path: bestBackdrop.filePath, size: .original)
                backdropCache[animeName] = url
                persistBackdropCache()
                return url
            }
            
            return nil
            
        } catch {
            return nil
        }
    }
    
    // MARK: - 搜索动漫（模糊匹配 + 静默重试）
    
    /// 带静默重试的搜索
    func searchAnimeWithRetry(query: String) async throws -> TMDBSearchResult {
        var lastError: Error?
        
        for attempt in 0...maxRetries {
            do {
                return try await searchAnime(query: query)
            } catch {
                lastError = error
                // 超时或网络错误才重试，其他错误直接抛
                guard error.isRetryable, attempt < maxRetries else { break }
                try? await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
            }
        }
        
        throw lastError ?? TMDBError.networkError(URLError(.unknown))
    }
    
    func searchAnime(query: String) async throws -> TMDBSearchResult {
        let urlString = TMDBAPI.searchAnime(query: query)
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(TMDBAPI.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WallHaven/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw TMDBError.invalidResponse
        }
        
        let searchResponse = try decoder.decode(TMDBSearchResponse.self, from: data)
        
        guard !searchResponse.results.isEmpty else {
            throw TMDBError.noResults
        }
        
        // 使用模糊匹配算法找到最佳匹配
        let bestMatch = findBestMatch(query: query, results: searchResponse.results)
        
        return bestMatch
    }
    
    /// 模糊匹配算法：通用智能匹配，不依赖固定映射
    private func findBestMatch(query: String, results: [TMDBSearchResult]) -> TMDBSearchResult {
        let queryLower = query.lowercased()
        let querySimplified = simplifyChinese(query)
        
        var scoredResults: [(result: TMDBSearchResult, score: Double)] = []
        
        for result in results {
            var score: Double = 0
            
            let nameLower = result.name.lowercased()
            let originalLower = result.originalName?.lowercased() ?? ""
            let nameSimplified = simplifyChinese(result.name)
            let originalSimplified = result.originalName.map(simplifyChinese) ?? ""
            
            // 1. 完全匹配（最高优先级）
            if nameLower == queryLower || originalLower == queryLower {
                score += 100
            }
            
            // 2. 简化中文完全匹配
            if nameSimplified == querySimplified || originalSimplified == querySimplified {
                score += 95
            }
            
            // 3. 前缀匹配
            if nameLower.hasPrefix(queryLower) || originalLower.hasPrefix(queryLower) {
                score += 80
            }
            
            // 4. 包含匹配
            if nameLower.contains(queryLower) || originalLower.contains(queryLower) {
                score += 60
            }
            
            // 5. 简化中文包含匹配
            if nameSimplified.contains(querySimplified) || originalSimplified.contains(querySimplified) {
                score += 55
            }
            
            // 6. 核心关键词匹配（智能分词）
            let keywordScore = max(
                calculateKeywordMatchScore(query: query, target: result.name),
                calculateKeywordMatchScore(query: query, target: result.originalName ?? "")
            )
            score += keywordScore * 40
            
            // 7. 编辑距离相似度（容错拼写）
            let nameSimilarity = calculateSimilarity(queryLower, nameLower)
            let originalSimilarity = calculateSimilarity(queryLower, originalLower)
            score += max(nameSimilarity, originalSimilarity) * 30
            
            // 8. 字符级别匹配（适合中日文）
            let charOverlap = calculateCharacterOverlap(query: queryLower, target: nameLower)
            let originalCharOverlap = calculateCharacterOverlap(query: queryLower, target: originalLower)
            score += max(charOverlap, originalCharOverlap) * 25
            
            // 9. N-gram 相似度
            let ngramScore = max(
                calculateNGramSimilarity(queryLower, nameLower),
                calculateNGramSimilarity(queryLower, originalLower)
            )
            score += ngramScore * 20
            
            // 10. 单词级别匹配（英文）
            let queryWords = extractWords(queryLower)
            let nameWords = extractWords(nameLower)
            let originalWords = extractWords(originalLower)
            
            for word in queryWords {
                if nameWords.contains(word) || originalWords.contains(word) {
                    score += 15
                }
                // 部分单词匹配
                for nameWord in nameWords {
                    if nameWord.contains(word) || word.contains(nameWord) {
                        score += 8
                    }
                }
            }
            
            // 11. 投票数和质量加成（用于打破平局）
            let voteBonus = min(Double(result.voteCount ?? 0) / 1000.0, 10)
            score += voteBonus
            
            // 12. 有背景图的额外加分
            if result.backdropPath != nil {
                score += 5
            }
            
            // 13. 流行度加成
            if let voteAverage = result.voteAverage, voteAverage > 7.0 {
                score += (voteAverage - 7.0) * 2
            }
            
            scoredResults.append((result, score))
        }
        
        // 按分数排序，返回最高分的结果
        scoredResults.sort { $0.score > $1.score }
        
        return scoredResults.first?.result ?? results[0]
    }
    
    /// 计算字符重叠度（适合中日文）
    private func calculateCharacterOverlap(query: String, target: String) -> Double {
        guard !query.isEmpty && !target.isEmpty else { return 0 }
        
        let queryChars = Set(query)
        let targetChars = Set(target)
        
        let intersection = queryChars.intersection(targetChars)
        let union = queryChars.union(targetChars)
        
        return Double(intersection.count) / Double(union.count)
    }
    
    /// 计算 N-gram 相似度
    private func calculateNGramSimilarity(_ s1: String, _ s2: String, n: Int = 2) -> Double {
        guard s1.count >= n && s2.count >= n else { return 0 }
        
        let grams1 = extractNGrams(s1, n: n)
        let grams2 = extractNGrams(s2, n: n)
        
        guard !grams1.isEmpty && !grams2.isEmpty else { return 0 }
        
        let intersection = grams1.intersection(grams2)
        let union = grams1.union(grams2)
        
        return Double(intersection.count) / Double(union.count)
    }
    
    /// 提取 N-grams
    private func extractNGrams(_ text: String, n: Int) -> Set<String> {
        let chars = Array(text)
        guard chars.count >= n else { return [] }
        
        var grams: Set<String> = []
        for i in 0...(chars.count - n) {
            let gram = String(chars[i..<(i + n)])
            grams.insert(gram)
        }
        return grams
    }
    
    /// 提取核心关键词（去除虚词）
    private func extractCoreKeywords(_ text: String) -> [String] {
        // 去除常见虚词和停用词
        let stopWords: Set<String> = ["的", "之", "与", "和", "在", "是", "了", "我", "你", "有", "就", "不", "人", "都", "一", "一个", "上", "也", "很", "到", "说", "要", "去", "会", "着", "没有", "看", "好", "自己", "这", "那", "这些", "那些"]
        
        // 简单的字符过滤：保留字母、数字、中文、日文
        let filtered = text.filter { char in
            let scalar = char.unicodeScalars.first!.value
            return (scalar >= 65 && scalar <= 90) ||   // A-Z
                   (scalar >= 97 && scalar <= 122) ||  // a-z
                   (scalar >= 48 && scalar <= 57) ||   // 0-9
                   (scalar >= 0x4E00 && scalar <= 0x9FFF) || // CJK
                   (scalar >= 0x3040 && scalar <= 0x309F) || // Hiragana
                   (scalar >= 0x30A0 && scalar <= 0x30FF)    // Katakana
        }
        
        // 分词
        var words: [String] = []
        var currentWord = ""
        
        for char in filtered {
            let scalar = char.unicodeScalars.first!.value
            // 如果是中日文字符，单独成词
            if (scalar >= 0x4E00 && scalar <= 0x9FFF) ||
               (scalar >= 0x3040 && scalar <= 0x30FF) ||
               (scalar >= 0x30A0 && scalar <= 0x30FF) {
                if !currentWord.isEmpty {
                    let word = currentWord.trimmingCharacters(in: .whitespaces).lowercased()
                    if word.count >= 2 && !stopWords.contains(word) {
                        words.append(word)
                    }
                    currentWord = ""
                }
                let charStr = String(char)
                if !stopWords.contains(charStr) {
                    words.append(charStr)
                }
            } else {
                currentWord.append(char)
            }
        }
        
        // 处理剩余的英文单词
        if !currentWord.isEmpty {
            let word = currentWord.trimmingCharacters(in: .whitespaces).lowercased()
            if word.count >= 2 && !stopWords.contains(word) {
                words.append(word)
            }
        }
        
        return words
    }
    
    /// 计算关键词匹配分数
    private func calculateKeywordMatchScore(query: String, target: String) -> Double {
        let queryKeywords = Set(extractCoreKeywords(query))
        let targetKeywords = Set(extractCoreKeywords(target))
        
        guard !queryKeywords.isEmpty else { return 0 }
        
        let intersection = queryKeywords.intersection(targetKeywords)
        let union = queryKeywords.union(targetKeywords)
        
        // Jaccard 相似度
        let jaccard = Double(intersection.count) / Double(union.count)
        
        // 额外奖励：如果核心词完全匹配
        let exactMatchBonus = intersection.count == queryKeywords.count ? 0.3 : 0
        
        return jaccard + exactMatchBonus
    }
    
    /// 计算两个字符串的相似度（0-1）
    private func calculateSimilarity(_ s1: String, _ s2: String) -> Double {
        let len1 = s1.count
        let len2 = s2.count
        guard len1 > 0 && len2 > 0 else { return 0 }
        
        // 简化版：计算最长公共子串长度比例
        let maxLen = max(len1, len2)
        var commonChars = 0
        
        for char in s1 {
            if s2.contains(char) {
                commonChars += 1
            }
        }
        
        return Double(commonChars) / Double(maxLen)
    }
    
    /// 简化中文字符（去除常见变体）
    private func simplifyChinese(_ text: String) -> String {
        // 常见动漫名称简化规则
        let simplified = text
            .replacingOccurrences(of: "之", with: "的")
            .replacingOccurrences(of: "戰", with: "战")
            .replacingOccurrences(of: "記", with: "记")
            .replacingOccurrences(of: "劇", with: "剧")
            .replacingOccurrences(of: "場", with: "场")
            .replacingOccurrences(of: "時", with: "时")
            .replacingOccurrences(of: "間", with: "间")
            .replacingOccurrences(of: "進", with: "进")
            .replacingOccurrences(of: "擊", with: "击")
            .replacingOccurrences(of: "層", with: "层")
            .replacingOccurrences(of: "東", with: "东")
            .replacingOccurrences(of: "西", with: "西")
            .replacingOccurrences(of: "話", with: "话")
        
        return simplified.lowercased()
    }
    
    /// 提取单词（用于分词匹配）
    private func extractWords(_ text: String) -> [String] {
        // 简单的分词：按空格和非字母数字字符分割
        let separators = CharacterSet.whitespaces.union(.punctuationCharacters)
        return text.components(separatedBy: separators)
            .filter { !$0.isEmpty && $0.count >= 2 }
    }
    
    // MARK: - 获取 TV 详情（静默重试）
    
    func fetchTVDetailWithRetry(id: Int) async throws -> TMDBTVDetail {
        var lastError: Error?
        
        for attempt in 0...maxRetries {
            do {
                return try await fetchTVDetail(id: id)
            } catch {
                lastError = error
                guard error.isRetryable, attempt < maxRetries else { break }
                try? await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
            }
        }
        
        throw lastError ?? TMDBError.networkError(URLError(.unknown))
    }
    
    func fetchTVDetail(id: Int) async throws -> TMDBTVDetail {
        let urlString = TMDBAPI.tvDetail(id: id)
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(TMDBAPI.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WallHaven/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw TMDBError.invalidResponse
        }
        
        return try decoder.decode(TMDBTVDetail.self, from: data)
    }
    
    // MARK: - 获取更详细的动漫信息
    
    func fetchAnimeInfo(animeName: String, originalName: String? = nil) async -> TMDBAnimeInfo? {
        // 先搜索
        guard let searchResult = try? await searchAnimeWithRetry(query: animeName) else {
            if let originalName = originalName, originalName != animeName {
                guard let originalResult = try? await searchAnimeWithRetry(query: originalName) else {
                    return nil
                }
                return await fetchAnimeInfoFromTV(id: originalResult.id)
            }
            return nil
        }
        
        return await fetchAnimeInfoFromTV(id: searchResult.id)
    }
    
    private func fetchAnimeInfoFromTV(id: Int) async -> TMDBAnimeInfo? {
        do {
            let detail = try await fetchTVDetailWithRetry(id: id)
            
            let backdropURL: String?
            if let backdropPath = detail.backdropPath {
                backdropURL = TMDBAPI.backdropURL(path: backdropPath, size: .original)
            } else if let bestBackdrop = detail.images?.bestBackdrop {
                backdropURL = TMDBAPI.backdropURL(path: bestBackdrop.filePath, size: .original)
            } else {
                backdropURL = nil
            }
            
            let posterURL: String?
            if let posterPath = detail.posterPath {
                posterURL = TMDBAPI.posterURL(path: posterPath, size: .w500)
            } else {
                posterURL = nil
            }
            
            return TMDBAnimeInfo(
                id: detail.id,
                name: detail.name,
                originalName: detail.originalName,
                overview: detail.overview,
                backdropURL: backdropURL,
                posterURL: posterURL,
                firstAirDate: detail.firstAirDate,
                voteAverage: detail.voteAverage,
                genres: detail.genres?.map { $0.name },
                status: detail.status,
                tagline: detail.tagline,
                numberOfSeasons: detail.numberOfSeasons,
                numberOfEpisodes: detail.numberOfEpisodes
            )
            
        } catch {
            return nil
        }
    }
}

// MARK: - TMDB 动漫信息（简化版）

struct TMDBAnimeInfo {
    let id: Int
    let name: String
    let originalName: String?
    let overview: String?        // 英文简介
    let backdropURL: String?     // 横屏背景图
    let posterURL: String?       // 竖图海报
    let firstAirDate: String?
    let voteAverage: Double?
    let genres: [String]?
    let status: String?          // 状态（Returning Series, Ended等）
    let tagline: String?         // 标语
    let numberOfSeasons: Int?
    let numberOfEpisodes: Int?
}

enum TMDBError: Error {
    case invalidURL
    case invalidResponse
    case decodingError(Error)
    case noResults
    case networkError(Error)
}
