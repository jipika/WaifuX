import Foundation

/// Background indexing uses paths and IDs only; library service payloads stay on MainActor.
struct MenuBarQuickIndexEntry: Sendable {
    let id: String
    let path: String
    let bakedPath: String?
    let folderKey: String
    let downloadedAt: Date
    let visible: Bool
}

struct MenuBarQuickIndex: Sendable {
    var ids: [String] = []
    var idsByFolder: [String: [String]] = [:]
    var visibleIDs = Set<String>()
    /// Includes hidden records: a known hidden path must never become an external item.
    var ownerByPath: [String: String] = [:]
    var descendantOwnerByPath: [String: String] = [:]
    var hiddenPaths = Set<String>()

    static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    static func build(_ entries: [MenuBarQuickIndexEntry]) -> Self {
        var index = Self()
        for entry in entries.sorted(by: { $0.downloadedAt > $1.downloadedAt }) {
            guard !Task.isCancelled else { return Self() }
            if entry.visible {
                index.ids.append(entry.id)
                index.visibleIDs.insert(entry.id)
                index.idsByFolder[entry.folderKey, default: []].append(entry.id)
            }
            for raw in [entry.path, entry.bakedPath].compactMap({ $0 }) {
                let path = normalizedPath(raw)
                index.ownerByPath[path] = entry.id
                if !entry.visible { index.hiddenPaths.insert(path) }
                var parent = (path as NSString).deletingLastPathComponent
                while parent.count > 1 {
                    // Ambiguous parent paths fail closed for current-item lookup.
                    if let previous = index.descendantOwnerByPath[parent], previous != entry.id {
                        index.descendantOwnerByPath[parent] = ""
                    } else if index.descendantOwnerByPath[parent] == nil {
                        index.descendantOwnerByPath[parent] = entry.id
                    }
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
        }
        return index
    }

    func owner(of rawPath: String) -> String? {
        let path = Self.normalizedPath(rawPath)
        if hiddenPaths.contains(path) { return "" }
        var privacyParent = (path as NSString).deletingLastPathComponent
        while privacyParent.count > 1 {
            if hiddenPaths.contains(privacyParent) { return "" }
            privacyParent = (privacyParent as NSString).deletingLastPathComponent
        }
        if let exact = ownerByPath[path] { return exact }
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            if let owner = ownerByPath[parent] { return owner }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return descendantOwnerByPath[path]
    }

    /// Samples at most `limit` entries without shuffling or copying the whole library.
    func sample(folderIDs: [String]?, excluding: Set<String>, limit: Int) -> [String] {
        let pools = folderIDs.map { selection in
            (selection.isEmpty ? [""] : selection).map { idsByFolder[$0] ?? [] }
        } ?? [ids]
        let count = pools.reduce(0) { $0 + $1.count }
        guard count > 0, limit > 0 else { return [] }
        func element(at offset: Int) -> String {
            var remaining = offset
            for pool in pools {
                if remaining < pool.count { return pool[remaining] }
                remaining -= pool.count
            }
            return ""
        }
        var result: [String] = []
        var chosen = Set<String>()
        for _ in 0..<(min(count, limit) * 8) {
            let id = element(at: Int.random(in: 0..<count))
            if !excluding.contains(id), chosen.insert(id).inserted { result.append(id) }
            if result.count == min(count, limit) { return result }
        }
        // Bounded fallback for small pools or an almost-exhausted previous batch.
        let start = Int.random(in: 0..<count)
        for offset in 0..<min(count, limit * 2 + excluding.count) {
            let id = element(at: (start + offset) % count)
            if !excluding.contains(id), chosen.insert(id).inserted { result.append(id) }
            if result.count == min(count, limit) { return result }
        }
        // Only when fresh candidates really cannot fill the batch, reuse old ones.
        for offset in 0..<min(count, limit * 2 + excluding.count) {
            let id = element(at: (start + offset) % count)
            if chosen.insert(id).inserted { result.append(id) }
            if result.count == min(count, limit) { break }
        }
        return result
    }
}

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

    func replacingPreview(thumbnailURL: URL?, videoURL: URL?, bakedVideoPath: String?) -> Self {
        Self(id: id, title: title, localURL: localURL, thumbnailURL: thumbnailURL,
             videoPreviewURL: videoURL, downloadedAt: downloadedAt, source: source,
             sceneBakeItemID: sceneBakeItemID, bakedVideoPath: bakedVideoPath, folderID: folderID)
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
