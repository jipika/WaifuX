import Foundation

/// A local wallpaper candidate shown by the menu-bar quick switcher.
///
/// The item deliberately keeps the original library record payload so actions such as
/// applying the wallpaper and toggling a favorite continue to use the shared services.
struct MenuBarQuickWallpaperItem: Identifiable {
    enum Source {
        case wallpaper(Wallpaper)
        case media(MediaItem)
        /// 当前屏正在使用、但库里没有对应下载记录的文件（例如从 Finder 直接设的图）。
        /// 只能展示与重新设置，没有详情页与收藏入口。
        case external
    }

    let id: String
    let title: String
    let localURL: URL
    let thumbnailURL: URL?
    let videoPreviewURL: URL?
    let downloadedAt: Date
    let source: Source
    let sceneBakeItemID: String?
    let bakedVideoPath: String?
    /// 所属下载文件夹；nil = 未归档（我的库根）。
    /// 文件夹筛选，以及「当前壁纸是否落在所选文件夹内」，都依赖这个字段。
    let folderID: String?

    /// external 项没有库记录，详情/收藏等库操作不可用。
    var isLibraryItem: Bool {
        if case .external = source { return false }
        return true
    }

    func replacingThumbnail(with thumbnailURL: URL?) -> Self {
        MenuBarQuickWallpaperItem(
            id: id,
            title: title,
            localURL: localURL,
            thumbnailURL: thumbnailURL,
            videoPreviewURL: videoPreviewURL,
            downloadedAt: downloadedAt,
            source: source,
            sceneBakeItemID: sceneBakeItemID,
            bakedVideoPath: bakedVideoPath,
            folderID: folderID
        )
    }
}
