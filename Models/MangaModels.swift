import Foundation

/// 漫画数据源（预留扩展）
enum MangaSource: String, Codable, Hashable {
    case pixiv
    // case ehentai, local, etc.
}

/// 漫画页（一张图）
struct MangaPage: Identifiable, Hashable {
    let id: Int
    let thumbURL: String
    let smallURL: String
    let regularURL: String
    let originalURL: String

    /// 阅读器默认加载的 URL（regular 级别，内存友好）
    var readerURL: String { regularURL }
}

/// 漫画章节 / 单本作品
/// - 当作品为单话（pageCount=1 或无系列）时，自身即为一章
/// - 当作品为系列中的一话时，代表系列中的一章
struct MangaChapter: Identifiable, Hashable {
    let id: String
    let title: String
    let coverURL: String
    let pageCount: Int
    let createdAt: Date?
    /// 该章的页列表（按需懒加载；来自 seed 或后续请求）
    var pages: [MangaPage]
}

/// 漫画系列（多话合集）
struct MangaSeries: Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let authorId: String
    let description: String
    let tags: [String]
    let coverURL: String
    let chapters: [MangaChapter]
    let source: MangaSource
}

/// 进入漫画详情的最小入参（传给 MangaDetailSheet）
struct MangaRoutePayload: Hashable {
    let source: MangaSource
    let illustId: String
    /// 来自卡片点击时已知的"种子章"（避免二次请求）
    let seedTitle: String?
    let seedCoverURL: String?

    init(source: MangaSource, illustId: String, seedTitle: String? = nil, seedCoverURL: String? = nil) {
        self.source = source
        self.illustId = illustId
        self.seedTitle = seedTitle
        self.seedCoverURL = seedCoverURL
    }
}

/// 阅读器模式
enum MangaReaderMode: String, CaseIterable, Identifiable {
    case singlePage      // 单页
    case verticalScroll  // 纵向卷轴

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .singlePage: return "单页"
        case .verticalScroll: return "纵向卷轴"
        }
    }

    var systemImage: String {
        switch self {
        case .singlePage: return "book.pages"
        case .verticalScroll: return "rectangle.portrait.on.rectangle.portrait"
        }
    }
}
