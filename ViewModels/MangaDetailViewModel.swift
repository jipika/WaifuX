import Foundation
import SwiftUI
import Kingfisher

/// 漫画详情页 ViewModel
/// 当前只接 Pixiv 一个数据源；后续扩展 EHentai / 本地漫画时，
/// 只需新增 MangaDataSource 实现，并在 load() 中按 source 分发即可。
@MainActor
final class MangaDetailViewModel: ObservableObject {

    // MARK: - Published state
    @Published var series: MangaSeries?
    @Published var currentChapter: MangaChapter?
    @Published var currentPageIndex: Int = 0
    @Published var readerMode: MangaReaderMode = .singlePage
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var loadingProgress: String?

    // MARK: - Dependencies
    private let pixiv = PixivService.shared
    private let route: MangaRoutePayload

    init(route: MangaRoutePayload) {
        self.route = route
    }

    // MARK: - Computed
    var chapters: [MangaChapter] { series?.chapters ?? [] }
    var currentPages: [MangaPage] { currentChapter?.pages ?? [] }
    var totalPageCount: Int { currentPages.count }
    var hasPreviousPage: Bool { currentPageIndex > 0 }
    var hasNextPage: Bool { currentPageIndex + 1 < totalPageCount }

    var seriesTitle: String { series?.title ?? "漫画" }
    var authorName: String { series?.author ?? "" }
    var seriesDescription: String { series?.description ?? "" }
    var seriesTags: [String] { series?.tags ?? [] }

    // MARK: - Load
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        loadingProgress = "加载中…"

        defer {
            isLoading = false
            loadingProgress = nil
        }

        do {
            switch route.source {
            case .pixiv:
                try await loadFromPixiv(illustId: route.illustId,
                                        seedTitle: route.seedTitle,
                                        seedCover: route.seedCoverURL)
            }
        } catch {
            print("❌ [MangaDetailViewModel] load failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pixiv pipeline
    private func loadFromPixiv(illustId: String, seedTitle: String?, seedCover: String?) async throws {
        loadingProgress = "加载作品信息…"

        // 1. 作品详情（拿 title、author、tags、seriesId、pageCount）
        let detail = try await pixiv.illustDetail(id: illustId)

        let title = detail.illustTitle.isEmpty ? (seedTitle ?? "pixiv_\(illustId)") : detail.illustTitle
        let author = detail.userName.isEmpty ? "unknown" : detail.userName
        let tags = detail.tags.tags.map { $0.tag }.filter { !$0.isEmpty }
        let description = detail.illustComment
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let seedChapter = MangaChapter(
            id: illustId,
            title: title,
            coverURL: seedCover ?? detail.urls.regular,
            pageCount: detail.pageCount,
            createdAt: Self.isoDate(from: detail.uploadDate),
            pages: []
        )

        // 2. 尝试查系列；失败时退化到单章
        var loadedChapters: [MangaChapter]
        var seriesTitleFinal = title
        var seriesDescriptionFinal = description
        var seriesId: String? = detail.seriesNavData?.seriesId

        // 没有 seriesNavData 时，尝试根据 userId 拿其所有作品作为"章节"（仅限漫画类型）
        if seriesId == nil, detail.illustType == 2 {
            // 不强求：系列聚合逻辑留给后续迭代；单作品先展示
        }

        if let seriesId = seriesId {
            do {
                loadingProgress = "加载系列章节…"
                let seriesBody = try await pixiv.seriesChapters(seriesId: seriesId)
                seriesTitleFinal = seriesBody.series?.title ?? title
                seriesDescriptionFinal = seriesBody.series?.caption ?? description

                var seriesChapters: [MangaChapter] = []
                let entries = seriesBody.page.series?.data ?? []
                // 按 order 升序
                let sorted = entries.sorted { $0.order < $1.order }

                for (idx, entry) in sorted.enumerated() {
                    let isCurrentEntry = entry.id == illustId
                    // 当前作品已知，其他作品稍后按需加载 pages
                    let ch = MangaChapter(
                        id: entry.id,
                        title: entry.title.isEmpty ? "第\(idx + 1)话" : entry.title,
                        coverURL: entry.coverUrl ?? detail.urls.regular,
                        pageCount: entry.pageCount ?? 0,
                        createdAt: Self.isoDate(from: entry.createDate),
                        pages: isCurrentEntry ? [] : [] // 默认空：用户点击再加载
                    )
                    seriesChapters.append(ch)
                }

                if seriesChapters.isEmpty {
                    loadedChapters = [seedChapter]
                } else {
                    loadedChapters = seriesChapters
                }
            } catch {
                print("⚠️ [MangaDetailViewModel] 加载系列失败，退化到单作品: \(error)")
                loadedChapters = [seedChapter]
            }
        } else {
            loadedChapters = [seedChapter]
        }

        // 3. 找到当前作品对应的章节，并加载其 pages
        guard let currentIndex = loadedChapters.firstIndex(where: { $0.id == illustId }) else {
            loadedChapters = [seedChapter]
            currentChapter = seedChapter
            series = MangaSeries(
                id: seriesId ?? illustId,
                title: seriesTitleFinal,
                author: author,
                authorId: detail.userId,
                description: seriesDescriptionFinal,
                tags: tags,
                coverURL: seedCover ?? detail.urls.regular,
                chapters: loadedChapters,
                source: .pixiv
            )
            currentPageIndex = 0
            await loadCurrentChapterPages()
            prefetchPages(force: true)
            return
        }

        series = MangaSeries(
            id: seriesId ?? illustId,
            title: seriesTitleFinal,
            author: author,
            authorId: detail.userId,
            description: seriesDescriptionFinal,
            tags: tags,
            coverURL: seedCover ?? detail.urls.regular,
            chapters: loadedChapters,
            source: .pixiv
        )
        currentChapter = loadedChapters[currentIndex]
        currentPageIndex = 0

        await loadCurrentChapterPages()
        prefetchPages(force: true)
    }

    // MARK: - Chapter / Page navigation
    func select(chapter: MangaChapter) async {
        guard let series = series,
              let idx = series.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }

        var updatedChapters = series.chapters
        var chosen = updatedChapters[idx]

        // 当前章 pages 为空时懒加载
        if chosen.pages.isEmpty {
            do {
                let entries = try await pixiv.mangaPages(id: chosen.id)
                chosen = MangaChapter(
                    id: chosen.id,
                    title: chosen.title,
                    coverURL: chosen.coverURL,
                    pageCount: chosen.pageCount,
                    createdAt: chosen.createdAt,
                    pages: Self.mapPages(entries)
                )
                updatedChapters[idx] = chosen
                self.series = MangaSeries(
                    id: series.id,
                    title: series.title,
                    author: series.author,
                    authorId: series.authorId,
                    description: series.description,
                    tags: series.tags,
                    coverURL: series.coverURL,
                    chapters: updatedChapters,
                    source: series.source
                )
            } catch {
                print("❌ [MangaDetailViewModel] load pages for chapter \(chosen.id) failed: \(error)")
                errorMessage = "加载章节失败：\(error.localizedDescription)"
                return
            }
        }

        currentChapter = chosen
        currentPageIndex = 0
        prefetchPages(force: true)
    }

    func nextPage() {
        guard hasNextPage else { return }
        currentPageIndex += 1
        prefetchPages(force: true)
    }

    func previousPage() {
        guard hasPreviousPage else { return }
        currentPageIndex -= 1
        // 回退不主动预加载，交给 onReceive 兜底
    }

    func toggleReaderMode() {
        switch readerMode {
        case .singlePage: readerMode = .verticalScroll
        case .verticalScroll: readerMode = .singlePage
        }
        prefetchPages()
    }

    // MARK: - 预加载
    /// 触发预加载：当前章后 N 张 + 下一章前 2 张
    /// - Parameters:
    ///   - ahead: 向后预取的页数（默认 3）
    ///   - force: 是否强制取消旧任务（默认 false；翻页/切章时传 true）
    func prefetchPages(ahead: Int = 3, force: Bool = false) {
        var urls: [URL] = []

        // 当前章后续 N 页
        if let ch = currentChapter {
            let start = currentPageIndex + 1
            let end = min(start + ahead, ch.pages.count)
            for i in start..<end {
                if let u = URL(string: ch.pages[i].regularURL) { urls.append(u) }
            }
        }

        // 下一章前 2 张
        if let series = series, let current = currentChapter,
           let idx = series.chapters.firstIndex(where: { $0.id == current.id }),
           idx + 1 < series.chapters.count {
            let nextCh = series.chapters[idx + 1]
            // 如果下一章 pages 为空（懒加载），在这里主动请求一次
            if nextCh.pages.isEmpty {
                Task { await prefetchChapterPages(nextCh) }
            } else {
                for i in 0..<min(2, nextCh.pages.count) {
                    if let u = URL(string: nextCh.pages[i].regularURL) { urls.append(u) }
                }
            }
        }

        guard !urls.isEmpty else { return }
        prefetchURLs(urls)
    }

    /// 统一的预加载入口：把一组 URL 丢给 Kingfisher 预取（自动去重 + 走缓存）
    private func prefetchURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        ImagePrefetcher(urls: urls, options: [.backgroundDecode]).start()
    }

    /// 预加载某一章的前 2 页（用于下一章提前缓存）
    private func prefetchChapterPages(_ chapter: MangaChapter) async {
        do {
            let entries = try await pixiv.mangaPages(id: chapter.id)
            let pages = Self.mapPages(entries)
            let updated = MangaChapter(
                id: chapter.id,
                title: chapter.title,
                coverURL: chapter.coverURL,
                pageCount: chapter.pageCount,
                createdAt: chapter.createdAt,
                pages: pages
            )
            // 更新到 series
            if let series = series,
               let idx = series.chapters.firstIndex(where: { $0.id == chapter.id }) {
                var newChapters = series.chapters
                newChapters[idx] = updated
                self.series = MangaSeries(
                    id: series.id,
                    title: series.title,
                    author: series.author,
                    authorId: series.authorId,
                    description: series.description,
                    tags: series.tags,
                    coverURL: series.coverURL,
                    chapters: newChapters,
                    source: series.source
                )
            }
            // 同时把这一章前 2 张加入预取
            let toPrefetch = updated.pages.prefix(2).compactMap { URL(string: $0.regularURL) }
            if !toPrefetch.isEmpty {
                prefetchURLs(toPrefetch)
            }
        } catch {
            print("⚠️ [MangaDetailViewModel] prefetch next chapter failed: \(error)")
        }
    }

    // MARK: - Helpers
    private func loadCurrentChapterPages() async {
        guard var chapter = currentChapter, chapter.pages.isEmpty else { return }
        do {
            let entries = try await pixiv.mangaPages(id: chapter.id)
            let pages = Self.mapPages(entries)
            chapter = MangaChapter(
                id: chapter.id,
                title: chapter.title,
                coverURL: chapter.coverURL,
                pageCount: chapter.pageCount,
                createdAt: chapter.createdAt,
                pages: pages
            )
            currentChapter = chapter
            // 同步回 series
            if let series = series,
               let idx = series.chapters.firstIndex(where: { $0.id == chapter.id }) {
                var newChapters = series.chapters
                newChapters[idx] = chapter
                self.series = MangaSeries(
                    id: series.id,
                    title: series.title,
                    author: series.author,
                    authorId: series.authorId,
                    description: series.description,
                    tags: series.tags,
                    coverURL: series.coverURL,
                    chapters: newChapters,
                    source: series.source
                )
            }
        } catch {
            print("❌ [MangaDetailViewModel] load initial pages failed: \(error)")
            errorMessage = "加载页面失败：\(error.localizedDescription)"
        }
    }

    private static func mapPages(_ entries: [PixivMangaPageEntry]) -> [MangaPage] {
        entries.enumerated().map { idx, e in
            MangaPage(
                id: idx,
                thumbURL: e.urls.thumbMini,
                smallURL: e.urls.small,
                regularURL: e.urls.regular,
                originalURL: e.urls.original
            )
        }
    }

    private static func isoDate(from str: String?) -> Date? {
        guard let str = str, !str.isEmpty else { return nil }
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = df.date(from: str) { return d }
        df.formatOptions = [.withInternetDateTime]
        if let d = df.date(from: str) { return d }
        return nil
    }
}
