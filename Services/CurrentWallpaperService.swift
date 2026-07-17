import Combine
import AppKit

/// 聚合各管理器（Video / WallpaperEngine / StaticOverlay / DesktopSync）的"当前活跃壁纸"路径，
/// 供 UI 层查询某张壁纸是否正在桌面上使用。
@MainActor
final class CurrentWallpaperService: ObservableObject {

    static let shared = CurrentWallpaperService()

    /// 所有屏幕当前活跃壁纸的标准化文件路径集合（仅本地文件）
    @Published private(set) var activeFilePaths: Set<String> = []

    /// 所有活跃壁纸的 URL 字符串集合（含远程 URL，用于反查下载记录）
    @Published private(set) var activeURLStrings: Set<String> = []

    /// 每屏活跃 URL（screenID → URL），供菜单栏反查使用
    @Published private(set) var activeURLByScreenID: [String: URL] = [:]

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // 视频壁纸变化
        VideoWallpaperManager.shared.$wallpaperChangeCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildActivePaths() }
            .store(in: &cancellables)

        VideoWallpaperManager.shared.$currentVideoURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildActivePaths() }
            .store(in: &cancellables)

        // WE 壁纸变化
        WallpaperEngineXBridge.shared.$isControllingExternalEngine
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildActivePaths() }
            .store(in: &cancellables)

        // 外部引擎保持接管状态时，切换 scene/web 只会更新每屏路径，不会改变上面的 Bool。
        WallpaperEngineXBridge.shared.$renderStateChangeCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildActivePaths() }
            .store(in: &cancellables)

        // 静态图片 overlay 变化
        StaticImageWallpaperOverlayManager.shared.$stateChangeSignal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildActivePaths() }
            .store(in: &cancellables)

        // 动态锁屏扩展中的静态图变化
        LockScreenWallpaperService.shared.$staticImageSourceChangeSignal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildActivePaths() }
            .store(in: &cancellables)

        // 屏幕配置变化（外接显示器插拔）
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildActivePaths() }
            .store(in: &cancellables)

        // 初始构建
        rebuildActivePaths()
    }

    // MARK: - 查询

    /// 判断给定的 URL 是否对应当前活跃的壁纸（支持本地文件 URL 和远程 URL）
    func isCurrentWallpaper(localFileURL: URL?) -> Bool {
        guard let localFileURL else { return false }

        // 远程 URL 字符串匹配
        if activeURLStrings.contains(localFileURL.absoluteString) {
            return true
        }

        // 本地文件路径匹配
        guard localFileURL.isFileURL else { return false }
        guard !activeFilePaths.isEmpty else { return false }

        let candidate = localFileURL.standardizedFileURL.path
        if activeFilePaths.contains(candidate) {
            return true
        }
        // 父子目录匹配（workshop 项目目录 vs 内部视频文件）
        for activePath in activeFilePaths {
            if candidate.hasPrefix(activePath + "/") {
                return true
            }
            if activePath.hasPrefix(candidate + "/") {
                return true
            }
        }
        return false
    }

    /// 获取指定屏幕当前活跃壁纸的 URL
    func activeURL(for screenID: String) -> URL? {
        activeURLByScreenID[screenID]
    }

    // MARK: - 重建

    private func rebuildActivePaths() {
        var filePaths = Set<String>()
        var urlStrings = Set<String>()
        var byScreen = [String: URL]()

        let videoMgr = VideoWallpaperManager.shared
        let weBridge = WallpaperEngineXBridge.shared
        let lockScreen = LockScreenWallpaperService.shared
        let staticOverlay = StaticImageWallpaperOverlayManager.shared
        let desktopSync = DesktopWallpaperSyncManager.shared

        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            var found = false

            // 1. 视频壁纸
            if let videoURL = videoMgr.assignedVideoURL(for: screen) {
                let p = videoURL.standardizedFileURL.path
                filePaths.insert(p)
                urlStrings.insert(videoURL.absoluteString)
                byScreen[screenID] = videoURL
                found = true
            }

            // 2. WE scene/web 壁纸
            if !found, let wePath = weBridge.currentWallpaperPath(for: screen) {
                let p = (wePath as NSString).standardizingPath
                filePaths.insert(p)
                urlStrings.insert(wePath)
                byScreen[screenID] = URL(fileURLWithPath: p)
                found = true
            }

            // 3. 动态锁屏扩展中的静态图。扩展渲染的是副本，使用原始来源反查资料库。
            if !found, let imageURL = lockScreen.staticImageSourceURL(for: screen) {
                if imageURL.isFileURL {
                    filePaths.insert(imageURL.standardizedFileURL.path)
                }
                urlStrings.insert(imageURL.absoluteString)
                byScreen[screenID] = imageURL
                found = true
            }

            // 4. 静态图片 overlay（系统壁纸同步关闭时）
            if !found, let imageURL = staticOverlay.imageURL(for: screen) {
                let p = imageURL.standardizedFileURL.path
                filePaths.insert(p)
                urlStrings.insert(imageURL.absoluteString)
                byScreen[screenID] = imageURL
                found = true
            }

            // 5. DesktopWallpaperSyncManager（系统壁纸同步开启时的静态图片）
            // 与 2/3 一致受 found 守卫保护：该屏已有更高优先级的活跃壁纸时，
            // 不再把 sync 历史路径混入活跃集合，避免已被覆盖的旧壁纸被误判为"当前使用中"。
            if !found, let syncURL = desktopSync.imageURL(for: screen) {
                urlStrings.insert(syncURL.absoluteString)
                if syncURL.isFileURL {
                    filePaths.insert(syncURL.standardizedFileURL.path)
                }
                byScreen[screenID] = syncURL
            }
        }

        activeFilePaths = filePaths
        activeURLStrings = urlStrings
        activeURLByScreenID = byScreen
    }
}
