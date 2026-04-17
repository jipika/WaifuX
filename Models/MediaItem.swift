import Foundation

struct MediaListPage: Equatable {
    let items: [MediaItem]
    let nextPagePath: String?
    let sectionTitle: String
}

struct MediaDownloadOption: Identifiable, Codable, Hashable {
    let id: String
    let label: String
    let fileSizeLabel: String
    let detailText: String
    let remoteURL: URL

    init(label: String, fileSizeLabel: String, detailText: String, remoteURL: URL) {
        self.label = label
        self.fileSizeLabel = fileSizeLabel
        self.detailText = detailText
        self.remoteURL = remoteURL
        self.id = "\(label.lowercased())|\(remoteURL.absoluteString)"
    }
}

// MARK: - MediaDownloadOption 扩展
extension MediaDownloadOption {
    /// 分辨率文本（从 detailText 中提取）
    var resolutionText: String {
        // 从 detailText 中提取分辨率部分（格式如 "3840x2160 mp4"）
        let components = detailText.components(separatedBy: " ")
        return components.first ?? detailText
    }
    
    /// 文件大小文本
    var fileSizeText: String {
        fileSizeLabel
    }

    var qualityRank: Int {
        let normalizedLabel = label.uppercased()
        let normalizedResolution = resolutionText.uppercased()

        if normalizedLabel.contains("8K") || normalizedResolution.contains("7680") {
            return 4
        }
        if normalizedLabel.contains("4K") || normalizedResolution.contains("3840") {
            return 3
        }
        if normalizedLabel.contains("HD") || normalizedResolution.contains("1920") {
            return 2
        }
        if normalizedResolution.contains("1280") {
            return 1
        }
        return 0
    }

    var fileSizeMegabytes: Double {
        let normalized = fileSizeLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")

        let numericPart = normalized.replacingOccurrences(of: #"[^0-9\.]+"#, with: "", options: .regularExpression)
        guard let value = Double(numericPart) else { return 0 }

        if normalized.contains("gb") {
            return value * 1024
        }
        if normalized.contains("kb") {
            return value / 1024
        }
        return value
    }
}

struct MediaItem: Identifiable, Codable, Hashable {
    let id: String
    let slug: String
    let title: String
    let pageURL: URL
    let thumbnailURL: URL
    let resolutionLabel: String
    let collectionTitle: String?
    let summary: String?
    let previewVideoURL: URL?
    let posterURL: URL?
    let tags: [String]
    let exactResolution: String?
    let durationSeconds: Double?
    let downloadOptions: [MediaDownloadOption]
    let sourceName: String
    let isAnimatedImage: Bool?

    init(
        slug: String,
        title: String,
        pageURL: URL,
        thumbnailURL: URL,
        resolutionLabel: String,
        collectionTitle: String?,
        summary: String? = nil,
        previewVideoURL: URL? = nil,
        posterURL: URL? = nil,
        tags: [String] = [],
        exactResolution: String? = nil,
        durationSeconds: Double? = nil,
        downloadOptions: [MediaDownloadOption] = [],
        sourceName: String = "MotionBGs",
        isAnimatedImage: Bool? = nil
    ) {
        self.id = slug
        self.slug = slug
        self.title = title
        self.pageURL = pageURL
        self.thumbnailURL = thumbnailURL
        self.resolutionLabel = resolutionLabel
        self.collectionTitle = collectionTitle
        self.summary = summary
        self.previewVideoURL = previewVideoURL
        self.posterURL = posterURL
        self.tags = tags
        self.exactResolution = exactResolution
        self.durationSeconds = durationSeconds
        self.downloadOptions = downloadOptions
        self.sourceName = sourceName
        self.isAnimatedImage = isAnimatedImage
    }

    var primaryBadgeText: String {
        exactResolution ?? resolutionLabel
    }

    var secondaryBadgeText: String {
        if let durationLabel {
            return durationLabel
        }
        return downloadOptions.isEmpty ? sourceName : "\(downloadOptions.count) 个下载"
    }

    var subtitle: String {
        if let firstTag = tags.first {
            return firstTag
        }
        if let collectionTitle, !collectionTitle.isEmpty {
            return collectionTitle
        }
        return sourceName
    }

    var durationLabel: String? {
        guard let durationSeconds else { return nil }

        let totalSeconds = Int(durationSeconds.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var qualityRank: Int {
        let normalized = resolutionLabel.uppercased()
        if normalized.contains("4K") {
            return 3
        }
        if normalized.contains("HD") {
            return 2
        }
        if normalized.contains("MOBILE") {
            return 1
        }
        return 0
    }
}

// MARK: - MediaItem 扩展属性（用于 UI 展示）
extension MediaItem {
    // URL 值（用于兼容 Optional URL 解包）
    var pageURLValue: URL { pageURL }
    var thumbnailURLValue: URL { thumbnailURL }
    var posterURLValue: URL? { posterURL }
    var previewVideoURLValue: URL? { previewVideoURL }
    
    // 主要标签文本
    var primaryTagText: String {
        tags.first ?? collectionTitle ?? sourceName
    }
    
    // 来源文本
    var sourceText: String {
        sourceName
    }
    
    // 分类名称（用于 moewalls 的 tag 分类）
    var categoryName: String? {
        collectionTitle
    }
    
    // 格式文本（分辨率标签）
    var formatText: String {
        primaryBadgeText
    }
    
    // 媒体类型
    var kind: String {
        // 如果有预览视频，标记为 live_wallpaper
        previewVideoURL != nil ? "live_wallpaper" : "static"
    }

    /// 列表/详情封面图 URL（与 UI 一致：海报优先，否则缩略图）。GIF 动效判断与加载都应基于该 URL。
    var coverImageURL: URL {
        posterURL ?? thumbnailURL
    }

    var isGIF: Bool {
        func urlLooksLikeGIF(_ url: URL) -> Bool {
            let str = url.absoluteString.lowercased()
            return str.hasSuffix(".gif")
                || str.contains(".gif?")
                || str.contains(".gif&")
                || url.pathExtension.lowercased() == "gif"
                // Steam CDN 等可能在查询串里标明 GIF，路径无 .gif 后缀
                || str.contains("format=gif")
                || str.contains("output-format=gif")
        }
        return urlLooksLikeGIF(coverImageURL)
    }

    /// 优先使用抓取时探测的 isAnimatedImage；若未探测则回退到 URL 推断。
    var shouldRenderThumbnailAsAnimatedImage: Bool {
        isAnimatedImage ?? isGIF
    }
    
    // 上传日期（用于详情页展示）
    var uploadDate: String? {
        // 可以从 slug 或其他元数据解析，暂时返回 nil
        nil
    }
    
    // 是否有详细数据（用于判断是否加载详情）
    var hasDetailPayload: Bool {
        // 如果有下载选项或预览视频，说明已经有详细数据
        !downloadOptions.isEmpty || previewVideoURL != nil
    }
}

// MARK: - MediaDownloadRecord
struct MediaFavoriteRecord: Identifiable, Codable, Hashable {
    let id: String
    var item: MediaItem
    var metadata: SyncMetadata

    init(item: MediaItem, metadata: SyncMetadata? = nil) {
        self.id = item.id
        self.item = item
        self.metadata = metadata ?? SyncMetadata(
            recordID: "media.favorite.\(item.id)",
            entityType: "media.favorite"
        )
    }

    var isActive: Bool {
        !metadata.isDeleted
    }

    enum CodingKeys: String, CodingKey {
        case id, item, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        item = try container.decode(MediaItem.self, forKey: .item)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? item.id
        metadata = try container.decodeIfPresent(SyncMetadata.self, forKey: .metadata)
            ?? SyncMetadata(recordID: "media.favorite.\(item.id)", entityType: "media.favorite")
    }
}

struct MediaDownloadRecord: Identifiable, Codable, Hashable {
    let id: String
    var item: MediaItem
    var localFilePath: String
    var downloadedAt: Date
    var metadata: SyncMetadata

    init(
        item: MediaItem,
        localFilePath: String,
        downloadedAt: Date = .now,
        metadata: SyncMetadata? = nil
    ) {
        self.id = item.id
        self.item = item
        self.localFilePath = localFilePath
        self.downloadedAt = downloadedAt
        self.metadata = metadata ?? SyncMetadata(
            recordID: "media.download.\(item.id)",
            entityType: "media.download"
        )
    }

    var localFileURL: URL {
        URL(fileURLWithPath: localFilePath)
    }

    var isActive: Bool {
        !metadata.isDeleted
    }

    enum CodingKeys: String, CodingKey {
        case id, item, localFilePath, downloadedAt, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        item = try container.decode(MediaItem.self, forKey: .item)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? item.id
        localFilePath = try container.decode(String.self, forKey: .localFilePath)
        downloadedAt = try container.decodeIfPresent(Date.self, forKey: .downloadedAt) ?? .now
        metadata = try container.decodeIfPresent(SyncMetadata.self, forKey: .metadata)
            ?? SyncMetadata(recordID: "media.download.\(item.id)", entityType: "media.download")
    }
}
