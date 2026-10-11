import Foundation

// MARK: - 动态桌面（Dynamic Wallpaper）数据模型

/// 对应解密后的 JSON 结构
struct DynamicWallpaperRawItem: Decodable, Hashable {
    let hasAudio: Int
    let isFourK: Int
    let isLooped: Int
    let isWidescreen: Int
    let videoPathHangzhou: String
    let videoPathHongkong: String
    let videoName: String
    let engTag: String
    let chinaTag: String
    var category: String
    let isPopular: Int
    let isAtWork: Int
    /// 2026-10 新增字段（list247/exclusive112）：疑似会员解锁标记；
    /// 实测 hidden=1 的老条目视频在新 CDN 上仍可下载，解析时容忍缺失，不据此过滤
    let isHidden: Int?

    enum CodingKeys: String, CodingKey {
        case hasAudio = "has_audio"
        case isFourK = "is_four_k"
        case isLooped = "is_looped"
        case isWidescreen = "is_widescreen"
        case videoPathHangzhou = "video_path_hangzhou"
        case videoPathHongkong = "video_path_hongkong"
        case videoName = "video_name"
        case engTag = "eng_tag"
        case chinaTag = "china_tag"
        case category = "category"
        case isPopular = "is_popular"
        case isAtWork = "is_at_work"
        case isHidden = "is_hidden"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hasAudio = try container.decode(Int.self, forKey: .hasAudio)
        // 独家 JSON 可能缺少 is_four_k / is_looped 字段，缺失时默认为 0
        self.isFourK = try container.decodeIfPresent(Int.self, forKey: .isFourK) ?? 0
        self.isLooped = try container.decodeIfPresent(Int.self, forKey: .isLooped) ?? 0
        self.isWidescreen = try container.decode(Int.self, forKey: .isWidescreen)
        self.videoPathHangzhou = try container.decode(String.self, forKey: .videoPathHangzhou)
        self.videoPathHongkong = try container.decode(String.self, forKey: .videoPathHongkong)
        self.videoName = try container.decode(String.self, forKey: .videoName)
        self.engTag = try container.decode(String.self, forKey: .engTag)
        self.chinaTag = try container.decode(String.self, forKey: .chinaTag)
        self.category = try container.decode(String.self, forKey: .category)
        self.isPopular = try container.decode(Int.self, forKey: .isPopular)
        self.isAtWork = try container.decode(Int.self, forKey: .isAtWork)
        self.isHidden = try container.decodeIfPresent(Int.self, forKey: .isHidden)
    }
}

// MARK: - 列表类型

enum DynamicWallpaperListType: String, CaseIterable, Identifiable {
    case all = "all"
    case collection = "collection"
    case exclusive = "exclusive"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .collection: return t("dongtai.list.collection")
        case .exclusive: return t("dongtai.list.exclusive")
        case .all: return t("dongtai.list.all")
        }
    }
}

// MARK: - 分类映射

/// Dynamic Wallpaper 的分类系统（1-10）
/// 注意：分类编号必须与 JSON 中的 category 字段严格对应。
/// JSON 数据分析结果：
///   1=动漫, 2=风景, 3=动物, 4=游戏, 5=科幻/创意,
///   6=国风/奇幻, 7=人物/美女, 8=可视化音乐, 9=影视, 10=AI绘画
enum DynamicWallpaperCategory: String, CaseIterable, Identifiable {
    case anime = "1"        // 卡通动漫
    case nature = "2"       // 自然人文
    case animal = "3"       // 萌宠萌物
    case game = "4"         // 游戏世界
    case scifi = "5"        // 创意壁纸（原科幻/未来）
    case chineseFantasy = "6" // 奇幻国漫（原"其他"）
    case people = "7"       // 怡人尤物
    case visualMusic = "8"  // 可视化音乐（原"抽象/艺术"）
    case movieStar = "9"    // 影视明星（原"节日/季节"）
    case aiArt = "10"       // 绘画作品（原"建筑/城市"）

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anime: return t("dongtai.category.anime")
        case .nature: return t("dongtai.category.nature")
        case .animal: return t("dongtai.category.animal")
        case .game: return t("dongtai.category.game")
        case .scifi: return t("dongtai.category.scifi")
        case .chineseFantasy: return t("dongtai.category.chineseFantasy")
        case .people: return t("dongtai.category.people")
        case .visualMusic: return t("dongtai.category.visualMusic")
        case .movieStar: return t("dongtai.category.movieStar")
        case .aiArt: return t("dongtai.category.aiArt")
        }
    }

    var icon: String {
        switch self {
        case .anime: return "person.crop.rectangle.stack.fill"
        case .nature: return "leaf.fill"
        case .animal: return "pawprint.fill"
        case .game: return "gamecontroller.fill"
        case .scifi: return "bolt.fill"
        case .chineseFantasy: return "crown.fill"
        case .people: return "person.fill"
        case .visualMusic: return "music.note.list"
        case .movieStar: return "video.fill"
        case .aiArt: return "paintpalette.fill"
        }
    }

    var accentColors: [String] {
        switch self {
        case .anime: return ["FF5E98", "FF9A5B"]
        case .nature: return ["2EC4B6", "1A936F"]
        case .animal: return ["A8E6CF", "1A936F"]
        case .game: return ["FFBE0B", "FB5607"]
        case .scifi: return ["00BBF9", "3A86FF"]
        case .chineseFantasy: return ["FF6B6B", "C44A4A"]
        case .people: return ["FF5E98", "FF9A5B"]
        case .visualMusic: return ["FB5607", "FFBE0B"]
        case .movieStar: return ["FFBE0B", "FF006E"]
        case .aiArt: return ["A8DADC", "457B9D"]
        }
    }
}

// MARK: - Dynamic Wallpaper 服务响应

struct DynamicWallpaperListResponse {
    let items: [DynamicWallpaperRawItem]
    let listType: DynamicWallpaperListType
    let totalCount: Int
}

// MARK: - 搜索/筛选参数

struct DynamicWallpaperSearchParams {
    var query: String = ""
    var listType: DynamicWallpaperListType = .all
    var categories: Set<DynamicWallpaperCategory> = []
    var sortBy: DynamicWallpaperSortOption = .popular
    var page: Int = 1
    var pageSize: Int = 20
    var hasAudio: Bool? = nil
    var isFourK: Bool? = nil
}

// MARK: - 排序选项

enum DynamicWallpaperSortOption: String, CaseIterable, Identifiable, SortOptionProtocol {
    case popular = "popular"
    case newest = "newest"
    case audio = "audio"
    case fourK = "fourK"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popular: return t("dongtai.sort.popular")
        case .newest: return t("dongtai.sort.newest")
        case .audio: return t("dongtai.sort.audio")
        case .fourK: return t("dongtai.sort.fourK")
        }
    }

    var menuTitle: String { title }
}

// MARK: - 媒体项转换

extension DynamicWallpaperRawItem {
    /// 从文件名提取用于“最新”排序的时间序列。
    /// Collection 文件名以分类号开头，不能直接按完整文件名比较。
    var newestSortKey: String {
        let stem = videoName.hasSuffix(".mp4")
            ? String(videoName.dropLast(4))
            : videoName
        let parts = stem.split(separator: "_", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return stem }
        return parts.dropFirst().map(String.init).joined(separator: "_")
    }

    /// 基于 videoName 的稳定唯一标识（不依赖排序位置）
    var stableItemID: String {
        if videoName.contains("_") && !videoName.hasPrefix("168") {
            // Collection: {category}_{timestamp}_{seq}.mp4
            "col_\(videoName.replacingOccurrences(of: ".mp4", with: "").replacingOccurrences(of: "_", with: ""))"
        } else {
            // Exclusive: {timestamp}.mp4
            "exc_\(videoName.replacingOccurrences(of: ".mp4", with: ""))"
        }
    }

    /// 判断是 Collection 还是 Exclusive
    var detectedListType: String {
        videoName.contains("_") && !videoName.hasPrefix("168") ? "collection" : "exclusive"
    }

    /// OSS/CDN 基础 URL
    /// 2026-10-06: 原阿里云 OSS 双节点已失效（杭州 404 / 香港 403 referer 白名单），统一走新 CDN
    var ossBaseURL: String {
        "https://cdn.dynamicwallpaperengine.com/"
    }

    /// 完整的远程视频 URL
    var remoteVideoURL: URL {
        let path = detectedListType == "collection" ? videoPathHangzhou : videoPathHongkong
        return URL(string: "\(ossBaseURL)\(path)\(videoName)")!
    }

    /// 封面 URL：改由客户端抽帧生成。
    ///
    /// 旧实现是给视频地址挂 `?x-oss-process=video/snapshot,t_1000,f_jpg,w_640`——
    /// 数据源迁到 `cdn.dynamicwallpaperengine.com`（Cloudflare 前置静态桶）后该参数被**整体忽略**，
    /// 返回的是整段 mp4（实测连回源 MISS 也一样），Kingfisher 必然解码失败、封面永远空着；
    /// 服务端也没有任何截图资源可换。因此改走 `DynamicWallpaperPosterService`（Range 取片 + 抽帧），
    /// 由 `DynamicWallpaperPosterURLProtocol` 在 Kingfisher 传输层接住。
    var remoteThumbnailURL: URL {
        DynamicWallpaperPosterRoute.posterURL(for: remoteVideoURL)
    }

    /// 详情页/首页背景用的**轻量预览片**（`.../Videos/00_preview/{video_name}`）。
    ///
    /// 原片 19~96MB、AVPlayer 起播 2~7.75s；官方预览片实测 60KB~4MB、约 1.9s 起播，
    /// 详情页背景循环用它能显著省流量、快速动起来（代价是 720×480，全屏背景略糊）。
    /// 2026-10-08 抽样：collection 31/31 命中（含带空格文件名），
    /// **exclusive 抽样 0/5 全 404**（官方没给独家条目做预览片）→ 这类仍回退原片。
    var remotePreviewVideoURL: URL? {
        guard detectedListType == "collection" else { return nil }
        var path = videoPathHangzhou
        if !path.hasSuffix("/") { path += "/" }
        return URL(string: "\(ossBaseURL)\(path)00_preview/\(videoName)")
    }

    /// 转换为统一的 MediaItem（index 仅用于顺序参考，不作为 ID）
    func toMediaItem(index: Int) -> MediaItem {
        let slug = "dongtai_\(stableItemID)"

        // 标签：合并英文和中文标签
        var tags: [String] = []
        let engTags = engTag.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let chinaTags = chinaTag.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        tags.append(contentsOf: engTags.filter { !$0.isEmpty })
        tags.append(contentsOf: chinaTags.filter { !$0.isEmpty })

        // 标题：优先使用中文标签第一个，否则用英文标签第一个
        let title = chinaTags.first ?? engTags.first ?? videoName

        // 分辨率：默认推断
        let resolutionLabel = isFourK == 1 ? "4K" : "HD"

        let durationSeconds: Double? = nil // 可根据视频元数据获取

        let downloadOption = MediaDownloadOption(
            label: resolutionLabel,
            fileSizeLabel: "",
            detailText: "\(resolutionLabel) mp4",
            remoteURL: remoteVideoURL
        )

        let categoryEnum = DynamicWallpaperCategory(rawValue: category)

        return MediaItem(
            slug: slug,
            title: title,
            pageURL: remoteVideoURL,
            thumbnailURL: remoteThumbnailURL,
            resolutionLabel: resolutionLabel,
            collectionTitle: categoryEnum?.title,
            summary: nil,
            previewVideoURL: remotePreviewVideoURL ?? remoteVideoURL,
            previewVideoFallbackURL: remotePreviewVideoURL == nil ? nil : remoteVideoURL,
            posterURL: remoteThumbnailURL,
            tags: tags,
            exactResolution: isFourK == 1 ? "3840x2160" : "1920x1080",
            durationSeconds: durationSeconds,
            downloadOptions: [downloadOption],
            sourceName: t("dongtai"),
            isAnimatedImage: nil,
            subscriptionCount: nil,
            favoriteCount: nil,
            viewCount: nil,
            ratingScore: isPopular == 1 ? 4.0 : nil,
            authorName: nil,
            authorSteamID: nil,
            authorAvatarURL: nil,
            fileSize: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }
}

// MARK: - 封面抽帧路由

/// 「动态桌面」封面伪 URL 的路由约定：Host 侧 `DynamicWallpaperPosterURLProtocol` /
/// `DynamicWallpaperPosterService` 与 Model 侧共用同一套 host 与编解码规则。
///
/// 放在本文件（而不是 Protocol 文件）是因为 `Models/DynamicWallpaperItem.swift`
/// 同时被 **WaifuXHelper** target 编译，而 Helper 的 sources 是显式清单、
/// 不含封面抽帧实现——路由约定必须落在两个 target 都能看到的文件里，
/// 否则 Helper 编译 `remoteThumbnailURL` 时会报 cannot find ... in scope。
enum DynamicWallpaperPosterRoute {
    /// 伪 host：`.invalid` 为保留顶级域，万一某条链路没注册 Protocol，
    /// DNS 会立刻失败而不是发出真实请求（`.local` 会走 mDNS 查询，慢且噪声大）。
    static let host = "dongtai-poster.waifux.invalid"

    /// 由视频地址构造封面伪 URL：`https://<host>/poster?src=<encode(视频地址)>`
    static func posterURL(for videoURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/poster"
        components.queryItems = [URLQueryItem(name: "src", value: videoURL.absoluteString)]
        if let url = components.url {
            return url
        }
        // URLComponents 对合法 http(s) 输入不会失败；兜底仍返回一个必然失败、
        // 但绝不会让 Kingfisher 去下载整段视频的地址
        return URL(string: "https://\(host)/poster")!
    }

    /// 从封面伪 URL 还原视频地址；不是本路由的 URL 返回 nil。
    static func videoURL(from posterURL: URL) -> URL? {
        guard posterURL.host?.lowercased() == host,
              let components = URLComponents(url: posterURL, resolvingAgainstBaseURL: false),
              let source = components.queryItems?.first(where: { $0.name == "src" })?.value,
              let videoURL = URL(string: source) else {
            return nil
        }
        return videoURL
    }
}

// MARK: - 排序函数

extension DynamicWallpaperRawItem {
    /// 用于排序的比较权重
    var sortPopularity: Int { isPopular }
    var sortAudio: Int { hasAudio }
    var sortFourK: Int { isFourK }
}
