import Foundation
import AppKit

// MARK: - 动态桌面（Dynamic Wallpaper）第三方源服务
///
/// 对接「Dynamic Wallpaper」（动态桌面）应用的加密视频壁纸数据。
/// 数据来源为阿里云 OSS 托管的 .cxy（RNCryptor v3 加密）文件，
/// 解密后为 JSON 格式的视频壁纸列表。
///
/// 该服务支持加载本地解密后的 JSON 文件，将其转换为 WaifuX 内部的 MediaItem。
///
/// 数据文件预期位置（按优先级）：
/// 1. App Bundle 内的 Resources/dongtai/ 目录
/// 2. Application Support/com.waifux.app/dongtai/ 目录
/// 3. 用户指定的自定义路径
@MainActor
final class DynamicWallpaperService: ObservableObject {
    static let shared = DynamicWallpaperService()

    // MARK: - Published State

    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var totalItemCount: Int = 0

    // MARK: - 缓存

    /// 所有已加载的原始数据（Collection + Exclusive）
    private var allRawItems: [DynamicWallpaperRawItem] = []
    /// 每个项的 MediaItem 缓存
    private var mediaItemCache: [String: MediaItem] = [:]

    /// 数据就绪标记
    private(set) var isDataReady = false

    // MARK: - 配置

    /// 数据文件是否从 Bundle 加载（而非用户目录）
    private(set) var isUsingBundledData = false

    /// OSS 基础 URL - Collection 视频
    private let collectionOSSBase = "https://whbalzachome.oss-cn-hangzhou.aliyuncs.com/"
    /// OSS 基础 URL - Exclusive 视频
    private let exclusiveOSSBase = "https://hongkongossofwhbalzac.oss-accelerate.aliyuncs.com/"

    // MARK: - 数据文件名

    private let collectionFileName = "list246.json"
    private let exclusiveFileName = "exclusive111.json"
    private let dataSubdirectory = "dongtai"

    // MARK: - Init

    private init() {}

    // MARK: - 数据加载

    /// 加载数据（自动检测可用来源）
    /// - Returns: 是否成功加载
    func loadData() async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 尝试从 Bundle 加载
        if loadFromBundle() {
            isUsingBundledData = true
            isDataReady = true
            return true
        }

        // 尝试从 Application Support 加载
        if loadFromApplicationSupport() {
            isUsingBundledData = false
            isDataReady = true
            return true
        }

        errorMessage = "未找到动态桌面数据文件，请将解密后的 JSON 文件放入应用支持目录"
        isDataReady = false
        return false
    }

    /// 从指定目录加载数据
    /// - Parameter directory: 包含 JSON 文件的目录 URL
    /// - Returns: 是否成功加载
    func loadData(from directory: URL) async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let collectionURL = directory.appendingPathComponent(collectionFileName)
        let exclusiveURL = directory.appendingPathComponent(exclusiveFileName)

        guard loadJSONFiles(collectionURL: collectionURL, exclusiveURL: exclusiveURL) else {
            errorMessage = "在 \(directory.path) 中未找到有效的 JSON 数据文件"
            isDataReady = false
            return false
        }

        isUsingBundledData = false
        isDataReady = true
        return true
    }

    /// 从指定 URL 下载并加载 JSON 数据
    /// - Parameters:
    ///   - collectionURL: Collection 列表 JSON URL
    ///   - exclusiveURL: Exclusive 列表 JSON URL
    /// - Returns: 是否成功加载
    func loadDataFromRemote(collectionURL: URL, exclusiveURL: URL) async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let collectionData = URLSession.shared.data(from: collectionURL).0
            async let exclusiveData = URLSession.shared.data(from: exclusiveURL).0

            let (colData, excData) = try await (collectionData, exclusiveData)

            guard parseAndAppend(data: colData, listType: .collection),
                  parseAndAppend(data: excData, listType: .exclusive) else {
                errorMessage = "远程 JSON 数据解析失败"
                isDataReady = false
                return false
            }

            isDataReady = true
            return true
        } catch {
            errorMessage = "远程数据加载失败: \(error.localizedDescription)"
            isDataReady = false
            return false
        }
    }

    // MARK: - 数据查询

    /// 查询媒体项
    /// - Parameters:
    ///   - params: 搜索/筛选参数
    /// - Returns: 查询结果
    func queryItems(params: DynamicWallpaperSearchParams) -> DynamicWallpaperQueryResult {
        guard isDataReady else {
            return DynamicWallpaperQueryResult(items: [], hasMore: false, totalCount: 0)
        }

        var filtered = allRawItems

        // 按列表类型筛选
        if params.listType != .all {
            filtered = filtered.filter { isMatchingListType($0, type: params.listType) }
        }

        // 按分类筛选
        if !params.categories.isEmpty {
            filtered = filtered.filter { item in
                params.categories.contains { $0.rawValue == item.category }
            }
        }

        // 按音频筛选
        if let hasAudio = params.hasAudio {
            filtered = filtered.filter { $0.hasAudio == (hasAudio ? 1 : 0) }
        }

        // 按 4K 筛选
        if let isFourK = params.isFourK {
            filtered = filtered.filter { $0.isFourK == (isFourK ? 1 : 0) }
        }

        // 搜索
        if !params.query.isEmpty {
            let query = params.query.lowercased()
            filtered = filtered.filter { item in
                item.engTag.lowercased().contains(query) ||
                item.chinaTag.lowercased().contains(query) ||
                item.videoName.lowercased().contains(query)
            }
        }

        // 排序（主排序 + 二级排序确保每次结果顺序确定）
        switch params.sortBy {
        case .popular:
            filtered.sort {
                if $0.isPopular != $1.isPopular { return $0.isPopular > $1.isPopular }
                if $0.newestSortKey != $1.newestSortKey {
                    return $0.newestSortKey > $1.newestSortKey
                }
                return $0.videoName > $1.videoName
            }
        case .newest:
            filtered.sort {
                if $0.newestSortKey != $1.newestSortKey {
                    return $0.newestSortKey > $1.newestSortKey
                }
                return $0.videoName > $1.videoName
            }
        case .audio:
            filtered.sort {
                if $0.hasAudio != $1.hasAudio { return $0.hasAudio > $1.hasAudio }
                if $0.isPopular != $1.isPopular { return $0.isPopular > $1.isPopular }
                if $0.newestSortKey != $1.newestSortKey {
                    return $0.newestSortKey > $1.newestSortKey
                }
                return $0.videoName > $1.videoName
            }
        case .fourK:
            filtered.sort {
                if $0.isFourK != $1.isFourK { return $0.isFourK > $1.isFourK }
                if $0.isPopular != $1.isPopular { return $0.isPopular > $1.isPopular }
                if $0.newestSortKey != $1.newestSortKey {
                    return $0.newestSortKey > $1.newestSortKey
                }
                return $0.videoName > $1.videoName
            }
        }

        totalItemCount = filtered.count

        // 分页
        let startIndex = (params.page - 1) * params.pageSize
        guard startIndex < filtered.count else {
            return DynamicWallpaperQueryResult(items: [], hasMore: false, totalCount: filtered.count)
        }

        let endIndex = min(startIndex + params.pageSize, filtered.count)
        let pageItems = Array(filtered[startIndex..<endIndex])

        // 转换为 MediaItem（使用稳定 ID 缓存，不依赖排序位置）
        let mediaItems = pageItems.enumerated().map { offset, rawItem in
            let cacheKey = rawItem.stableItemID
            if let cached = mediaItemCache[cacheKey] {
                return cached
            }
            let item = rawItem.toMediaItem(index: startIndex + offset)
            mediaItemCache[cacheKey] = item
            return item
        }

        return DynamicWallpaperQueryResult(
            items: mediaItems,
            hasMore: endIndex < filtered.count,
            totalCount: filtered.count
        )
    }

    // MARK: - 获取分类统计

    /// 获取各分类的统计数据
    var categoryStatistics: [(DynamicWallpaperCategory, Int)] {
        guard isDataReady else { return [] }

        var counts: [DynamicWallpaperCategory: Int] = [:]
        for item in allRawItems {
            if let cat = DynamicWallpaperCategory(rawValue: item.category) {
                counts[cat, default: 0] += 1
            }
        }

        return DynamicWallpaperCategory.allCases.compactMap { cat in
            guard let count = counts[cat], count > 0 else { return nil }
            return (cat, count)
        }.sorted { $0.1 > $1.1 }
    }

    /// 含音频和 4K 的统计数据
    var audioItemCount: Int {
        allRawItems.filter { $0.hasAudio == 1 }.count
    }

    var fourKItemCount: Int {
        allRawItems.filter { $0.isFourK == 1 }.count
    }

    var popularItemCount: Int {
        allRawItems.filter { $0.isPopular == 1 }.count
    }

    // MARK: - URL 解析

    /// 判断给定的 URL 字符串是否为本服务可处理的 OSS 视频链接
    func canHandleOSSURL(_ urlString: String) -> Bool {
        urlString.contains("whbalzachome.oss-cn-hangzhou.aliyuncs.com") ||
        urlString.contains("hongkongossofwhbalzac.oss-accelerate.aliyuncs.com")
    }

    /// 通过 OSS 视频 URL 查找对应的 MediaItem
    /// - Parameter urlString: OSS 视频完整 URL
    /// - Throws: 未找到时抛出错误
    /// - Returns: 匹配的 MediaItem
    func resolveItemByOSSURL(_ urlString: String) async throws -> MediaItem {
        if !isDataReady {
            _ = await loadData()
        }
        guard isDataReady else {
            throw NSError(domain: "DynamicWallpaperService", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "动态桌面数据尚未加载"])
        }

        // 从 URL 中提取 videoName（最后一段路径）
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "DynamicWallpaperService", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "无效的 URL"])
        }
        let videoName = url.lastPathComponent
        guard !videoName.isEmpty else {
            throw NSError(domain: "DynamicWallpaperService", code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "无法从 URL 中提取视频文件名"])
        }

        // 在原始数据中查找匹配的 videoName
        guard let rawItem = allRawItems.first(where: { $0.videoName == videoName }) else {
            throw NSError(domain: "DynamicWallpaperService", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "未找到与链接匹配的动态桌面视频"])
        }

        // 检查缓存
        let cacheKey = rawItem.stableItemID
        if let cached = mediaItemCache[cacheKey] {
            return cached
        }

        // 找到该 item 在过滤前全列表中的索引（用于保持稳定 ID）
        let index = allRawItems.firstIndex(where: { $0.videoName == videoName }) ?? 0
        let item = rawItem.toMediaItem(index: index)
        mediaItemCache[cacheKey] = item
        return item
    }

    // MARK: - 资源释放

    func clearData() {
        allRawItems.removeAll()
        mediaItemCache.removeAll()
        isDataReady = false
        totalItemCount = 0
    }

    // MARK: - 私有方法

    /// 从 Bundle 加载数据
    private func loadFromBundle() -> Bool {
        guard let bundleRes = Bundle.main.resourceURL else { return false }

        // 兼容两种 Bundle 布局：
        // 1. Resources/ 作为 folder reference → dongtai/ 在 Resources/Resources/dongtai/
        // 2. 扁平布局 → dongtai/ 在 Resources/dongtai/
        let candidates = [
            bundleRes.appendingPathComponent("Resources").appendingPathComponent(dataSubdirectory),
            bundleRes.appendingPathComponent(dataSubdirectory)
        ]

        for bundleDir in candidates {
            let collectionURL = bundleDir.appendingPathComponent(collectionFileName)
            let exclusiveURL = bundleDir.appendingPathComponent(exclusiveFileName)
            if loadJSONFiles(collectionURL: collectionURL, exclusiveURL: exclusiveURL) {
                return true
            }
        }
        return false
    }

    /// 从 Application Support 加载数据
    private func loadFromApplicationSupport() -> Bool {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }

        let dataDir = appSupport.appendingPathComponent("com.waifux.app").appendingPathComponent(dataSubdirectory)
        let collectionURL = dataDir.appendingPathComponent(collectionFileName)
        let exclusiveURL = dataDir.appendingPathComponent(exclusiveFileName)

        return loadJSONFiles(collectionURL: collectionURL, exclusiveURL: exclusiveURL)
    }

    /// 加载两个 JSON 文件
    private func loadJSONFiles(collectionURL: URL, exclusiveURL: URL) -> Bool {
        let fm = FileManager.default
        var hasAnyData = false

        // 加载 Collection 列表
        if fm.fileExists(atPath: collectionURL.path) {
            if let data = try? Data(contentsOf: collectionURL) {
                if parseAndAppend(data: data, listType: .collection) {
                    hasAnyData = true
                }
            }
        }

        // 加载 Exclusive 列表
        if fm.fileExists(atPath: exclusiveURL.path) {
            if let data = try? Data(contentsOf: exclusiveURL) {
                if parseAndAppend(data: data, listType: .exclusive) {
                    hasAnyData = true
                }
            }
        }

        return hasAnyData
    }

    /// 解析 JSON 并添加到总列表（自动修正数据质量问题）
    private func parseAndAppend(data: Data, listType: DynamicWallpaperListType) -> Bool {
        do {
            let decoder = JSONDecoder()
            var items = try decoder.decode([DynamicWallpaperRawItem].self, from: data)
            // 修正数据：去除 category 字段首尾空白字符
            for i in items.indices {
                items[i].category = items[i].category.trimmingCharacters(in: .whitespaces)
            }
            allRawItems.append(contentsOf: items)
            return true
        } catch {
            print("[DynamicWallpaperService] JSON 解析失败 (\(listType)): \(error)")
            return false
        }
    }

    /// 判断原始项是否匹配指定列表类型
    private func isMatchingListType(_ item: DynamicWallpaperRawItem, type: DynamicWallpaperListType) -> Bool {
        switch type {
        case .all:
            return true
        case .collection:
            return item.detectedListType == "collection"
        case .exclusive:
            return item.detectedListType == "exclusive"
        }
    }
}

// MARK: - 查询结果

struct DynamicWallpaperQueryResult {
    let items: [MediaItem]
    let hasMore: Bool
    let totalCount: Int
}
