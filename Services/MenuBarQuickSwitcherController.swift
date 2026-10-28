import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarQuickSwitcherController: NSObject {
    private let contentSize = MenuBarQuickSwitcherView.panelSize
    private let viewModel = MenuBarQuickSwitcherViewModel()
    private let panel: MenuBarQuickSwitcherPanel
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var presentationGeneration = 0

    override init() {
        panel = MenuBarQuickSwitcherPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.hidesOnDeactivate = false

        viewModel.onApplied = { [weak self] in
            self?.dismiss()
        }
    }

    private func mountContentIfNeeded() {
        guard panel.contentViewController == nil else { return }

        let hostingController = NSHostingController(
            rootView: MenuBarQuickSwitcherView(viewModel: viewModel)
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hostingController
    }

    func toggle(
        relativeTo anchorView: NSView,
        targetScreen: NSScreen?,
        currentWallpaperURL: URL?,
        canDesignCurrentWallpaper: Bool,
        onOpenSettings: @escaping () -> Void,
        onOpenDesignWallpaper: @escaping () -> Void,
        onOpenDetail: @escaping (MainWallpaperDetailRequest) -> Void,
        onQuit: @escaping () -> Void
    ) {
        if panel.isVisible {
            dismiss()
            return
        }

        presentationGeneration &+= 1
        viewModel.onOpenSettings = { [weak self] in
            self?.dismiss()
            onOpenSettings()
        }
        viewModel.onOpenDesignWallpaper = { [weak self] in
            self?.dismiss()
            onOpenDesignWallpaper()
        }
        viewModel.onOpenDetail = { [weak self] request in
            self?.dismiss()
            onOpenDetail(request)
        }
        viewModel.onQuitApplication = onQuit
        let prepareStart = Date()
        viewModel.prepare(
            targetScreen: targetScreen,
            currentWallpaperURL: currentWallpaperURL,
            canDesignCurrentWallpaper: canDesignCurrentWallpaper
        )
        let prepareDone = Date()
        mountContentIfNeeded()
        let mountDone = Date()

        positionPanel(relativeTo: anchorView, on: targetScreen)
        panel.alphaValue = 1
        // A nonactivating panel can become key for input without making WaifuX the
        // foreground application, so background Screen Time does not resume here.
        panel.makeKeyAndOrderFront(nil)
        let frontDone = Date()
        installDismissMonitors()

        // 「点开菜单栏要等一等」的分段耗时：prepare（数据/当前壁纸定位）、
        // mount（NSHostingController + SwiftUI 树重建）、front（panel 可见）。
        AppLogger.debug(.general, "状态栏左键弹窗打开耗时", metadata: [
            "prepareMS": String(Int(prepareDone.timeIntervalSince(prepareStart) * 1000)),
            "mountMS": String(Int(mountDone.timeIntervalSince(prepareDone) * 1000)),
            "frontMS": String(Int(frontDone.timeIntervalSince(mountDone) * 1000)),
            "dataMS": String(viewModel.lastDataDurationMS),
            "currentMS": String(viewModel.lastCurrentLookupMS),
            "repoHit": viewModel.lastRepositoryCacheHit ? "1" : "0",
            "repoBuildMS": String(viewModel.lastRepositoryBuildMS),
            "batch": String(viewModel.batchItems.count),
        ])
    }

    func dismiss() {
        removeDismissMonitors()
        guard panel.isVisible || panel.contentViewController != nil else { return }

        presentationGeneration &+= 1
        let dismissedGeneration = presentationGeneration
        panel.orderOut(nil)
        viewModel.suspendPreviewWork()

        // Keep the responder tree alive until AppKit finishes dispatching the
        // mouse event that dismissed the panel, then release its players,
        // tracking areas, layers, and hosted SwiftUI hierarchy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self,
                  self.presentationGeneration == dismissedGeneration,
                  !self.panel.isVisible else {
                return
            }
            self.panel.contentViewController = nil
        }
    }

    private func positionPanel(relativeTo anchorView: NSView, on screen: NSScreen?) {
        guard let anchorWindow = anchorView.window else {
            panel.center()
            return
        }

        let anchorRect = anchorView.convert(anchorView.bounds, to: nil)
        let screenRect = anchorWindow.convertToScreen(anchorRect)
        let visibleFrame = (screen ?? anchorWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? .zero

        var origin = NSPoint(
            x: screenRect.midX - (contentSize.width / 2),
            y: screenRect.minY - contentSize.height - 10
        )
        origin.x = min(
            max(origin.x, visibleFrame.minX + 12),
            max(visibleFrame.minX + 12, visibleFrame.maxX - contentSize.width - 12)
        )
        origin.y = max(visibleFrame.minY + 12, origin.y)

        panel.setFrame(NSRect(origin: origin, size: contentSize), display: false)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                self.dismiss()
                return nil
            }

            if event.window !== self.panel {
                self.dismiss()
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss()
            }
        }
    }

    private func removeDismissMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }
}

private final class MenuBarQuickSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum MenuBarQuickFolderSelectionStore {
    private static let defaultsKey = "menu_bar_quick_switcher_folder_selections_v1"

    static func load(scopeID: String) -> (found: Bool, folderIDs: [String]?) {
        let selections = loadSelections()
        guard let storedFolderIDs = selections[scopeID] else {
            return (false, nil)
        }
        return (true, storedFolderIDs.isEmpty ? nil : storedFolderIDs)
    }

    static func save(_ folderIDs: [String]?, scopeID: String) {
        var selections = loadSelections()
        selections[scopeID] = folderIDs ?? []
        guard let data = try? JSONEncoder().encode(selections) else { return }
        WaifuXPreferences.shared.set(data, forKey: defaultsKey)
    }

    private static func loadSelections() -> [String: [String]] {
        guard let data = WaifuXPreferences.shared.data(forKey: defaultsKey),
              let selections = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return selections
    }
}

@MainActor
final class MenuBarQuickSwitcherViewModel: ObservableObject {
    /// Enough candidates for a real horizontal scroll; ~5 remain visible in the rail.
    static let batchSize = 16

    /// 播放控制条依赖的一份状态快照。
    /// 这些值分属三个单例（视频管理器、WE 桥、调度器），弹窗只观察本 ViewModel，
    /// 所以统一折算成快照后由下面订阅转发——值不变就不触发重绘。
    struct PlaybackSnapshot: Equatable {
        var hasLivePlayback = false
        var isPaused = false
        var canGoPrevious = false
        var canGoNext = false
        var volume: Double = 1.0
        var rate: Double?

        static let empty = PlaybackSnapshot()
    }

    @Published private(set) var batchItems: [MenuBarQuickWallpaperItem] = []
    @Published private(set) var selectedItem: MenuBarQuickWallpaperItem?
    @Published private(set) var isApplying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var previewWarmupToken = UUID()
    @Published private(set) var canDesignCurrentWallpaper = false
    /// nil = 我的库（全部本地项目）；非空数组 = 选中的下载文件夹。
    @Published private(set) var selectedFolderIDs: [String]?

    /// 播放控制条读的这些值都住在别的单例里（VideoWallpaperManager /
    /// WallpaperEngineXBridge / WallpaperSchedulerService）。视图只观察本
    /// ViewModel，所以必须把它们的变更转发进来，否则暂停后图标不会变、
    /// 「上一张」可用性也不会刷新——这正是「按了暂停还显示暂停图标」的成因。
    /// 这里用 CombineLatest 合成一份快照，值相等就丢弃，避免三个服务各报一次
    /// 变更导致弹窗重复重绘。
    @Published private(set) var playbackSnapshot = PlaybackSnapshot.empty
    private var playbackObservers: Set<AnyCancellable> = []
    private var playbackRefreshWorkItem: DispatchWorkItem?

    var onOpenSettings: (() -> Void)?
    var onOpenDesignWallpaper: (() -> Void)?
    var onApplied: (() -> Void)?
    var onOpenDetail: ((MainWallpaperDetailRequest) -> Void)?
    var onQuitApplication: (() -> Void)?

    private var targetScreenID: String?
    private var targetScreenFingerprint: String?
    /// 菜单栏所在屏幕当前正在使用的那张壁纸（prepare 传入）。
    /// 它必须始终在候选项中，并且默认被选中。
    private var currentWallpaperURL: URL?
    /// 打开耗时诊断（`状态栏左键弹窗打开耗时` 日志用）。
    private(set) var lastDataDurationMS = 0
    private(set) var lastCurrentLookupMS = 0
    private(set) var lastRepositoryCacheHit = true
    private(set) var lastRepositoryBuildMS = 0
    private var lastBatchIDs = Set<String>()
    private var previewTasks: [String: Task<Void, Never>] = [:]
    /// contentRoot 解析与 dependency 就绪状态缓存：每次点「设壁纸」都要读
    /// project.json 并探外置盘路径，缓存后同一工程只算一次（依赖下载完成后
    /// 立即写入 `dependencyReadyRoots`）。与 `items()` 的记录指纹缓存同一思路。
    private var resolvedContentRoots: [String: URL] = [:]
    private var dependencyReadyRoots: Set<String> = []

    var isSelectedItemFavorite: Bool {
        guard let selectedItem else { return false }
        switch selectedItem.source {
        case .wallpaper(let wallpaper):
            return WallpaperLibraryService.shared.isFavorite(wallpaper)
        case .media(let item):
            return MediaLibraryService.shared.isFavorite(item)
        case .external:
            return false
        }
    }

    /// external 项（库里没有记录）没有详情页可开。
    var canOpenSelectedDetail: Bool {
        selectedItem?.isLibraryItem ?? false
    }

    /// 弹窗项目 → 调度器候选池的 itemID（`wp_dl_*` / `media_dl_*`）。
    /// 两边 ID 是两套体系：弹窗用 `wallpaper.<recordID>` / `media.<recordID>`，
    /// 调度器用下载记录 ID。手动设为壁纸时要把这个 ID 记进轮换历史，
    /// 否则「上一张」永远判定为无历史而保持灰色。
    static func schedulerItemID(for item: MenuBarQuickWallpaperItem) -> String? {
        switch item.source {
        case .wallpaper(let wallpaper):
            guard let record = WallpaperLibraryService.shared.downloadRecord(
                forLocalFilePath: item.localURL.path
            ) ?? WallpaperLibraryService.shared.downloadRecords.first(where: {
                $0.isActive && $0.wallpaper.id == wallpaper.id
            }) else { return nil }
            return "wp_dl_\(record.id)"
        case .media(let mediaItem):
            guard let record = MediaLibraryService.shared.downloadRecord(
                forLocalFilePath: item.localURL.path
            ) ?? MediaLibraryService.shared.downloadRecords.first(where: {
                $0.isActive && $0.item.id == mediaItem.id
            }) else { return nil }
            return "media_dl_\(record.id)"
        case .external:
            // 库里没有记录的文件不在候选池里，没有对应 itemID。
            return nil
        }
    }

    func openDetail() {
        guard let selectedItem else { return }
        let request: MainWallpaperDetailRequest
        switch selectedItem.source {
        case .wallpaper(let wallpaper):
            request = .wallpaper(wallpaper)
        case .media(let item):
            request = .media(item)
        case .external:
            return
        }
        onOpenDetail?(request)
    }

    func openDesignWallpaper() {
        guard canDesignCurrentWallpaper else { return }
        onOpenDesignWallpaper?()
    }

    func prepare(
        targetScreen: NSScreen?,
        currentWallpaperURL: URL?,
        canDesignCurrentWallpaper: Bool
    ) {
        targetScreenID = targetScreen?.wallpaperScreenIdentifier
        targetScreenFingerprint = targetScreen?.wallpaperScreenFingerprint
        self.canDesignCurrentWallpaper = canDesignCurrentWallpaper
        // 记住该屏正在使用的壁纸：后面每次重建批次、换一批、切文件夹都要保证
        // 它仍作为候选项出现，并且默认被选中（hero 大图同步）。
        self.currentWallpaperURL = currentWallpaperURL
        errorMessage = nil

        let schedulerConfig = activeSchedulerConfig()
        let storedSelection = MenuBarQuickFolderSelectionStore.load(scopeID: folderSelectionScopeID)
        let restoredFolderIDs = storedSelection.found
            ? validatedFolderIDs(storedSelection.folderIDs)
            : validatedFolderIDs(schedulerConfig?.folderIDs)
        let didChangeFolderSelection = selectedFolderIDs != restoredFolderIDs
        selectedFolderIDs = restoredFolderIDs
        if !storedSelection.found, let restoredFolderIDs {
            MenuBarQuickFolderSelectionStore.save(restoredFolderIDs, scopeID: folderSelectionScopeID)
        }

        let dataStart = Date()
        if batchItems.isEmpty || didChangeFolderSelection {
            replaceBatch(avoidPreviousBatch: false)
        } else {
            // 批次还在：只把「当前壁纸」同步成选中项（它可能刚在别处被换掉）。
            ensureCurrentWallpaperInBatch()
        }
        lastDataDurationMS = Int(Date().timeIntervalSince(dataStart) * 1000)
        let repository = MenuBarQuickWallpaperRepository.shared
        lastCurrentLookupMS = repository.lastCurrentLookupMS
        lastRepositoryCacheHit = repository.lastAllItemsCacheHit
        lastRepositoryBuildMS = repository.lastBuildDurationMS

        startObservingPlaybackState()
        refreshPlaybackSnapshot()
    }

    func item(at index: Int) -> MenuBarQuickWallpaperItem? {
        guard batchItems.indices.contains(index) else { return nil }
        return batchItems[index]
    }

    func select(_ item: MenuBarQuickWallpaperItem) {
        selectedItem = item
        errorMessage = nil
    }

    func selectNextItem() {
        guard !batchItems.isEmpty else { return }
        guard let selectedItem,
              let index = batchItems.firstIndex(where: { $0.id == selectedItem.id }) else {
            self.selectedItem = batchItems.first
            return
        }
        self.selectedItem = batchItems[(index + 1) % batchItems.count]
        errorMessage = nil
    }

    var isUsingEntireLibrary: Bool {
        selectedFolderIDs == nil
    }

    var selectedFolderLabel: String {
        guard let selectedFolderIDs, !selectedFolderIDs.isEmpty else {
            return t("menubar.quick.myLibrary")
        }

        let names = selectedFolderIDs.compactMap { id in
            availableFolders.first(where: { $0.id == id }).map(folderOptionLabel)
        }
        if names.isEmpty {
            return t("menubar.quick.myLibrary")
        }
        if names.count == 1 {
            return names[0]
        }
        if names.count <= 3 {
            return names.joined(separator: ", ")
        }
        return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
    }

    var availableFolders: [LibraryFolder] {
        let config = activeSchedulerConfig()
        let folderStore = LibraryFolderStore.shared
        var folders: [LibraryFolder] = []
        if config?.includeWallpapers ?? true {
            folders.append(contentsOf: folderStore.folders(for: .wallpaper, collection: .downloads))
        }
        if config?.includeMedia ?? true {
            folders.append(contentsOf: folderStore.folders(for: .media, collection: .downloads))
        }
        return folders
            .filter {
                MenuBarQuickSwitcherFolderVisibility.isVisible(
                    folderID: $0.id,
                    contentType: $0.contentType
                )
            }
            .sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            if lhs.contentType != rhs.contentType {
                return lhs.contentType.rawValue < rhs.contentType.rawValue
            }
            return lhs.id < rhs.id
        }
    }

    func isFolderSelected(_ folderID: String) -> Bool {
        selectedFolderIDs?.contains(folderID) == true
    }

    func selectEntireLibrary() {
        MenuBarQuickFolderSelectionStore.save(nil, scopeID: folderSelectionScopeID)
        if selectedFolderIDs == nil, activeSchedulerConfig()?.folderIDs != nil {
            persistFolderSelectionToScheduler(nil)
        }
        updateFolderSelection(nil)
    }

    func toggleFolderSelection(_ folderID: String) {
        var selected = Set(selectedFolderIDs ?? [])
        if selectedFolderIDs == nil {
            selected = [folderID]
        } else if selected.contains(folderID) {
            selected.remove(folderID)
        } else {
            selected.insert(folderID)
        }

        let orderedIDs = availableFolders
            .map(\.id)
            .filter { selected.contains($0) }
        updateFolderSelection(orderedIDs.isEmpty ? nil : orderedIDs)
    }

    func refreshBatch() {
        replaceBatch(avoidPreviousBatch: true)
    }

    func toggleFavorite() {
        guard let selectedItem else { return }
        switch selectedItem.source {
        case .wallpaper(let wallpaper):
            WallpaperLibraryService.shared.toggleFavorite(wallpaper)
        case .media(let item):
            MediaLibraryService.shared.toggleFavorite(item)
        case .external:
            return
        }
        objectWillChange.send()
    }

    func openSettings() {
        onOpenSettings?()
    }

    // MARK: - 每屏播放控制（与状态栏右键菜单同一套能力）

    /// 弹窗所在屏（prepare 时记录）；拿不到时回退主屏。
    private var playbackTargetScreen: NSScreen? {
        resolvedTargetScreen() ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// 该屏是否有活跃动态壁纸（视频 / WE scene/web），决定暂停/音量/速度是否可用。
    var hasLivePlayback: Bool { readPlaybackSnapshot().hasLivePlayback }

    /// 音量键是否显示：锁屏扩展模式的壁纸跑在扩展进程里，宿主侧只有
    /// per-display 静音/暂停 prefs、没有连续音量接口（与右键菜单
    /// `if !isExtensionMode` 跳过音量滑块同一约束），此时隐藏音量键。
    /// scene/web/本机视频都可用：WE 的 setVolume 热推渲染器 audioControl
    /// 文件 + web daemon IPC，视频写 per-screen 存储。
    var showsVolumeControl: Bool {
        if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenMirroringActive {
            return false
        }
        return hasLivePlayback
    }

    /// 该屏当前是否暂停（视频按屏查；WE 只有全局暂停态）。
    var isPlaybackPaused: Bool { readPlaybackSnapshot().isPaused }

    /// 该屏音量（视频按屏独立；WE 走 VideoWallpaperManager 的每屏音量）。
    var playbackVolume: Double { readPlaybackSnapshot().volume }

    /// 该屏播放速度（只对本机视频有效；WE/静态壁纸返回 nil → 面板隐藏）。
    var playbackRate: Double? { readPlaybackSnapshot().rate }

    /// 是否可以切上一张/下一张（有可轮换的调度项）。
    var canSwitchWallpaper: Bool { readPlaybackSnapshot().canGoNext }

    /// 是否有可回退的上一张。
    var canGoPrevious: Bool { readPlaybackSnapshot().canGoPrevious }

    /// 从各服务现算一份快照（真值来源）。视图只认 `playbackSnapshot`，
    /// 这里用于订阅回调与首次求值。
    func readPlaybackSnapshot() -> PlaybackSnapshot {
        guard let screen = playbackTargetScreen else { return .empty }
        let videoManager = VideoWallpaperManager.shared
        let bridge = WallpaperEngineXBridge.shared
        let scheduler = WallpaperSchedulerService.shared
        let screenID = screen.wallpaperScreenIdentifier

        var snapshot = PlaybackSnapshot()
        snapshot.hasLivePlayback = videoManager.hasActiveWallpaper(on: screen)
            || bridge.hasLivePresentation(on: screen)

        if bridge.isControllingExternalEngine {
            snapshot.isPaused = bridge.isExternalPaused
        } else if #available(macOS 26.0, *), videoManager.isLockScreenMirroringActive {
            snapshot.isPaused = videoManager.isPaused
        } else {
            snapshot.isPaused = videoManager.isPaused(on: screen)
        }

        snapshot.volume = videoManager.volume(for: screen)
        if videoManager.assignedVideoURL(for: screen) != nil {
            snapshot.rate = videoManager.playbackRate(for: screen)
        } else {
            snapshot.rate = nil
        }
        snapshot.canGoNext = scheduler.hasSchedulableItems(for: screenID)
        snapshot.canGoPrevious = scheduler.hasWallpaperHistory(for: screenID)
        return snapshot
    }

    /// 把快照推给视图；值没变就不发布，避免三个服务各报一次变更造成的重复重绘。
    func refreshPlaybackSnapshot() {
        let next = readPlaybackSnapshot()
        guard next != playbackSnapshot else { return }
        playbackSnapshot = next
    }

    /// 订阅三个单例的发布：它们各自的暂停/音量/切换历史变化都要反映到弹窗。
    /// 合并窗口 30ms，一次用户操作里多个服务连环发通知只重绘一次。
    func startObservingPlaybackState() {
        guard playbackObservers.isEmpty else { return }
        let merged = Publishers.MergeMany(
            VideoWallpaperManager.shared.objectWillChange.map { _ in () }
                .eraseToAnyPublisher(),
            WallpaperEngineXBridge.shared.objectWillChange.map { _ in () }
                .eraseToAnyPublisher(),
            WallpaperSchedulerService.shared.objectWillChange.map { _ in () }
                .eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)

        merged
            .sink { [weak self] in
                guard let self else { return }
                self.playbackRefreshWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    self?.refreshPlaybackSnapshot()
                }
                self.playbackRefreshWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: item)
            }
            .store(in: &playbackObservers)
    }

    func togglePlaybackForTargetScreen() {
        guard let screen = playbackTargetScreen else { return }
        let videoManager = VideoWallpaperManager.shared
        let bridge = WallpaperEngineXBridge.shared

        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
            if bridge.isControllingExternalEngine {
                if bridge.isExternalPaused {
                    bridge.resumeWallpaper()
                    DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
                } else {
                    bridge.pauseWallpaper()
                }
            } else if videoManager.isPaused {
                videoManager.resumeWallpaper()
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            } else {
                videoManager.pauseWallpaper()
            }
            return
        }

        if bridge.isControllingExternalEngine {
            // CLI 壁纸（scene/web）不支持单屏暂停，走全局
            if bridge.isExternalPaused {
                bridge.resumeWallpaper()
            } else {
                bridge.pauseWallpaper()
            }
            return
        }

        if #available(macOS 26.0, *), videoManager.isLockScreenMirroringActive {
            if let displayID = Self.cgDisplayID(for: screen) {
                let isPaused = LockScreenWallpaperService.shared.isDisplayPaused(displayID)
                LockScreenWallpaperService.shared.setDisplayPaused(!isPaused, forDisplayID: displayID)
            }
            return
        }

        if videoManager.isPaused(on: screen) {
            videoManager.resumeWallpaper(for: screen)
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
        } else {
            videoManager.pauseWallpaper(for: screen)
        }
    }

    func nextWallpaperForTargetScreen() {
        guard let screen = playbackTargetScreen else { return }
        let scheduler = WallpaperSchedulerService.shared
        guard scheduler.hasSchedulableItems(for: screen.wallpaperScreenIdentifier) else { return }
        if scheduler.isGlobalDisplaySyncEnabled {
            scheduler.triggerNextGlobalWallpaperNow()
        } else {
            scheduler.triggerNextWallpaperNow(for: screen.wallpaperScreenIdentifier)
        }
        VideoWallpaperManager.shared.forceCommitDesktopPresentation(on: [screen])
    }

    func previousWallpaperForTargetScreen() {
        guard let screen = playbackTargetScreen else { return }
        let scheduler = WallpaperSchedulerService.shared
        guard scheduler.hasSchedulableItems(for: screen.wallpaperScreenIdentifier) else { return }
        scheduler.triggerPreviousWallpaperNow(for: screen.wallpaperScreenIdentifier)
        VideoWallpaperManager.shared.forceCommitDesktopPresentation(on: [screen])
    }

    /// 只调该屏音量，不碰其它屏和全局静音（与右键菜单音量滑块同语义）。
    func setPlaybackVolume(_ volume: Double) {
        guard let screen = playbackTargetScreen else { return }
        let clamped = min(1.0, max(0.0, volume))
        VideoWallpaperManager.shared.setVolume(clamped, for: screen)
        if WallpaperEngineXBridge.shared.isControllingExternalEngine {
            WallpaperEngineXBridge.shared.setVolume(clamped, for: screen)
        }
    }

    func setPlaybackRate(_ rate: Double) {
        guard let screen = playbackTargetScreen else { return }
        VideoWallpaperManager.shared.setPlaybackRate(rate, for: screen)
    }

    private static func cgDisplayID(for screen: NSScreen) -> UInt32? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    func quitApplication() {
        onQuitApplication?()
    }

    private func updateFolderSelection(_ folderIDs: [String]?) {
        guard selectedFolderIDs != folderIDs else { return }
        selectedFolderIDs = folderIDs
        MenuBarQuickFolderSelectionStore.save(folderIDs, scopeID: folderSelectionScopeID)
        persistFolderSelectionToScheduler(folderIDs)
        replaceBatch(avoidPreviousBatch: false)
    }

    private var folderSelectionScopeID: String {
        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
            return "global"
        }
        if let fingerprint = targetScreenFingerprint, !fingerprint.isEmpty {
            return "display:\(fingerprint)"
        }
        if let screenID = targetScreenID, !screenID.isEmpty {
            return "display-id:\(screenID)"
        }
        return "display:default"
    }

    private func validatedFolderIDs(_ folderIDs: [String]?) -> [String]? {
        guard let folderIDs else { return nil }
        let visibleFolderIDs = Set(availableFolders.map(\.id))
        let validated = folderIDs.filter { visibleFolderIDs.contains($0) }
        return validated.isEmpty ? nil : validated
    }

    private func persistFolderSelectionToScheduler(_ folderIDs: [String]?) {
        let scheduler = WallpaperSchedulerService.shared
        if scheduler.isGlobalDisplaySyncEnabled {
            scheduler.updateGlobalDisplayFolderIDs(folderIDs)
            return
        }

        guard let screen = resolvedTargetScreen() ?? NSScreen.screens.first else { return }
        let screenID = scheduler.displayConfigScreenID(for: screen)
        scheduler.updateDisplayFolderIDs(folderIDs, for: screenID)
    }

    private func activeSchedulerConfig() -> DisplaySchedulerConfig? {
        let scheduler = WallpaperSchedulerService.shared
        if scheduler.isGlobalDisplaySyncEnabled {
            return scheduler.globalDisplayConfig
        }
        guard let screen = resolvedTargetScreen() ?? NSScreen.screens.first else { return nil }
        return scheduler.resolvedDisplayConfig(for: screen)
    }

    func folderOptionLabel(for folder: LibraryFolder) -> String {
        let contentType = folder.contentType == .wallpaper ? t("wallpapers") : t("media")
        return "\(contentType) · \(folder.name)"
    }

    /// 通过菜单栏所在屏幕设置壁纸；全局显示器同步开启时仍覆盖全部屏幕。
    func applySelectedItem() {
        guard let selectedItem, !isApplying else { return }

        errorMessage = nil
        let globallySynced = WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled
        let screens = NSScreen.screens

        // 全局同步保持其原有的全屏行为。
        if globallySynced {
            startApply(
                selectedItem,
                targetScreens: NSScreen.screens,
                globallySynced: globallySynced
            )
            return
        }

        // 菜单栏面板已在打开时记录所在屏幕，直接应用到该屏幕，不显示选择器。
        if let screen = resolvedTargetScreen() ?? screens.first {
            startApply(
                selectedItem,
                targetScreens: [screen],
                globallySynced: globallySynced
            )
        } else {
            startApply(
                selectedItem,
                targetScreens: nil,
                globallySynced: globallySynced
            )
        }
    }

    private func startApply(
        _ selectedItem: MenuBarQuickWallpaperItem,
        targetScreens: [NSScreen]?,
        globallySynced: Bool
    ) {
        isApplying = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            await self.performApply(
                selectedItem,
                targetScreens: targetScreens,
                globallySynced: globallySynced
            )
        }
    }

    private func performApply(
        _ selectedItem: MenuBarQuickWallpaperItem,
        targetScreens: [NSScreen]?,
        globallySynced: Bool
    ) async {
        let applyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Menu bar quick wallpaper apply"
        )
        defer { ProcessInfo.processInfo.endActivity(applyActivity) }
    
        do {
            // Workshop 目录：先解析 content root，且补齐 dependency（与 MediaDetailSheet 一致）。
            let prepareStart = Date()
            let applyURL = try await prepareApplyURL(for: selectedItem)
            let prepareDone = Date()
    
            // 入库校验：确保 MediaLibraryService.shared.downloadRecord(forLocalFilePath:) 能命中，
            // 否则后续 bake artifact 查找会失败。异步补录，不阻塞设壁纸热路径。
            if case .media(let mediaItem) = selectedItem.source {
                await MainActor.run {
                    MediaLibraryService.shared.ensureDownloadRecord(
                        item: mediaItem, localFileURL: selectedItem.localURL
                    )
                }
            }
    
            let screens = targetScreens.flatMap { $0.isEmpty ? nil : $0 } ?? NSScreen.screens
            let bakePath = resolvedBakedVideoPath(for: selectedItem, applyURL: applyURL)

            let coversMultiple = screens.count > 1

            // 菜单栏只解析当前选中项；类型分发、烘焙产物选择、海报生成和实际设置
            // 都由 LocalWallpaperApplyService 统一处理，和详情页/调度器保持一致。
            let options = LocalWallpaperApplyService.Options(
                animatedTransition: true,
                requirePlaybackEndSupport: false,
                muted: VideoWallpaperManager.shared.isMuted,
                generatePosterFromVideoIfNeeded: true,
                sceneBakeItemID: selectedItem.sceneBakeItemID,
                bakedVideoPath: bakePath,
                usesSharedVideoDecoder: globallySynced || coversMultiple,
                reason: "menu-bar-quick-switch"
            )

            AppLogger.error(.wallpaper, "菜单栏快速设置壁纸", metadata: [
                "item": selectedItem.id,
                "path": applyURL.path,
                "screens": screens.map(\.wallpaperScreenIdentifier).joined(separator: ","),
            ])
            let success = try await LocalWallpaperApplyService.apply(
                localURL: applyURL,
                targetScreens: screens,
                options: options
            )
            // 分段耗时：定位「点设壁纸后要等」到底卡在 prepare（工程解析/dependency）
            // 还是 apply 本体（渲染切换）。
            AppLogger.error(.wallpaper, "菜单栏设置壁纸分段耗时", metadata: [
                "item": selectedItem.id,
                "prepareMS": Int(prepareDone.timeIntervalSince(prepareStart) * 1000),
                "applyMS": Int(Date().timeIntervalSince(prepareDone) * 1000),
            ])
            guard success else {
                throw LocalWallpaperApplyService.ApplyError.failed(
                    t("menubar.quick.applyFailed")
                )
            }
    
            // 手动切换后强制合帧，避免菜单栏路径桌面层挂起（与调度器 manual-next 一致）。
            VideoWallpaperManager.shared.forceCommitDesktopPresentation(on: screens)
    
            WallpaperSchedulerService.shared.notifyManualWallpaperChange(
                screenID: globallySynced || screens.count != 1
                    ? nil
                    : screens.first?.wallpaperScreenIdentifier,
                itemID: Self.schedulerItemID(for: selectedItem)
            )
            isApplying = false
            refreshPlaybackSnapshot()
            onApplied?()
        } catch {
            AppLogger.error(.wallpaper, "菜单栏快速设置壁纸失败", metadata: [
                "item": selectedItem.id,
                "error": error.localizedDescription,
            ])
            errorMessage = error.localizedDescription
            isApplying = false
        }
    }

    /// 解析实际 apply 路径，并在需要时下载 Workshop dependency。
    private func prepareApplyURL(for item: MenuBarQuickWallpaperItem) async throws -> URL {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: item.localURL.path, isDirectory: &isDirectory)

        // 普通文件（静态图 / 视频）直接用原路径。
        if !isDirectory.boolValue {
            return item.localURL
        }

        let cacheKey = item.localURL.standardizedFileURL.path
        let contentRoot = resolvedContentRoots[cacheKey]
            ?? WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: item.localURL)
        resolvedContentRoots[cacheKey] = contentRoot

        // dependency 已就绪的工程直接放行；否则读一次 project.json 并在需要时下载。
        if !dependencyReadyRoots.contains(contentRoot.path),
           let dependencyID = readWorkshopDependencyID(from: contentRoot),
           !isWorkshopDependencyDownloaded(dependencyID: dependencyID) {
            errorMessage = t("menubar.quick.downloadingDependency")
            try await WorkshopService.shared.downloadWorkshopItem(
                workshopID: dependencyID,
                progressHandler: { progress in
                    print("[MenuBarQuickSwitcher] dependency \(dependencyID) \(String(format: "%.0f", progress * 100))%")
                }
            )
            errorMessage = nil
        }

        // 只有走完 dependency 检查才标记就绪；下载刚完成也算就绪。
        dependencyReadyRoots.insert(contentRoot.path)
        return contentRoot
    }

    private func resolvedBakedVideoPath(
        for item: MenuBarQuickWallpaperItem,
        applyURL: URL
    ) -> String? {
        if let path = item.bakedVideoPath,
           SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: path)) {
            return path
        }
        if case .media(let mediaItem) = item.source,
           let record = MediaLibraryService.shared.downloadedItems.first(where: { $0.item.id == mediaItem.id }),
           let art = SceneOfflineBakeService.usableArtifact(from: record),
           SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath)) {
            return art.videoPath
        }
        // 也尝试按 content root 命中库记录（LocalWallpaperApplyService 内部会再查一次）
        if let record = MediaLibraryService.shared.downloadRecord(forLocalFilePath: applyURL.path),
           let art = SceneOfflineBakeService.usableArtifact(from: record),
           SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath)) {
            return art.videoPath
        }
        return item.bakedVideoPath
    }

    private func readWorkshopDependencyID(from contentDir: URL) -> String? {
        let projectURL = contentDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["dependency"] as? String
    }

    private func isWorkshopDependencyDownloaded(dependencyID: String) -> Bool {
        let fm = FileManager.default
        let mediaFolder = DownloadPathManager.shared.mediaFolderURL
        let depItemID = "workshop_\(dependencyID)"
        if MediaLibraryService.shared.downloadedItems.contains(where: { $0.item.id == depItemID }) {
            return true
        }
        let depPaths = [
            mediaFolder.appendingPathComponent(
                "workshop_\(dependencyID)/steamapps/workshop/content/431960/\(dependencyID)"
            ),
            mediaFolder.appendingPathComponent("workshop_\(dependencyID)")
        ]
        for path in depPaths where fm.fileExists(atPath: path.path) {
            let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: path)
            if fm.fileExists(atPath: resolved.appendingPathComponent("project.json").path) {
                return true
            }
        }
        return false
    }

    /// 同时最多跑几个缩略图生成任务。
    ///
    /// 缩略图要读原片抽帧（原片常常在外置盘），一次开十几个任务会互相抢 IO，
    /// 且每个任务完成都会触发一次 SwiftUI 重排 —— 直接表现为「弹窗一出来就卡」。
    private static let previewWarmupConcurrency = 2

    /// 槽位释放信号：某个预热任务完成后置 true，派发循环消费掉它补位。
    /// 只在 MainActor 上读写，无锁。
    private var previewSlotReleased = false

    func warmVisiblePreviews() async {
        let itemsToWarm = batchItems.filter { $0.thumbnailURL == nil }
        var inFlight = 0
        for item in itemsToWarm {
            if Task.isCancelled { return }
            guard previewTasks[item.id] == nil else { continue }
            // 并发槽占满时等一个释放信号再派发 —— 完成即补位。等待用短 sleep
            // 让位 MainActor（完成回调要靠主线程置位），比旧版 40ms 轮询
            // 「数任务字典」更直接，也不会在等待期独占主线程。
            while inFlight >= Self.previewWarmupConcurrency {
                if previewSlotReleased {
                    previewSlotReleased = false
                    inFlight -= 1
                    break
                }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
            previewTasks[item.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                let thumbnailURL = await MenuBarQuickWallpaperRepository.shared.previewURL(for: item)
                guard !Task.isCancelled else { return }
                self.updateThumbnail(thumbnailURL, for: item.id)
                self.previewTasks[item.id] = nil
                self.previewSlotReleased = true
            }
            inFlight += 1
        }
    }

    func suspendPreviewWork() {
        for task in previewTasks.values {
            task.cancel()
        }
        previewTasks.removeAll()
        previewSlotReleased = false
    }

    /// 重建候选批次。
    ///
    /// 「当前壁纸」的落位规则（用户明确要求）：
    /// - 不在当前文件夹筛选内（或库里没有记录）→ 固定作为第一个候选；
    /// - 在筛选内 → 保持它被随机抽到的位置（原样）；若随机没抽中，则随机补进
    ///   批次里（保证它一定在候选项中），不强行置顶。
    /// 无论哪种情况，最终都默认选中它，hero 大图随之显示当前壁纸。
    private func replaceBatch(avoidPreviousBatch: Bool) {
        let pool = MenuBarQuickWallpaperRepository.shared.items(folderIDs: selectedFolderIDs)
        let currentItem = MenuBarQuickWallpaperRepository.shared.currentItem(
            matching: currentWallpaperURL
        )
        let currentIsInPool: Bool = {
            guard let currentItem else { return false }
            return pool.contains { $0.id == currentItem.id }
        }()

        guard !pool.isEmpty || currentItem != nil else {
            batchItems = []
            selectedItem = nil
            errorMessage = nil
            previewWarmupToken = UUID()
            return
        }

        let limit = min(Self.batchSize, max(pool.count, currentItem == nil ? 0 : 1))
        var candidates = pool
        if avoidPreviousBatch {
            let fresh = candidates.filter { !lastBatchIDs.contains($0.id) }
            if fresh.count >= min(limit, pool.count) {
                candidates = fresh
            }
        }

        var nextBatch = Array(candidates.shuffled().prefix(limit))
        if let currentItem, !nextBatch.contains(where: { $0.id == currentItem.id }) {
            // 不属于当前文件夹 → 第一个；属于当前文件夹但没抽中 → 随机位置补进。
            // 随机位置排除末尾，截断时 removeLast 才不会把刚补进来的它删掉。
            let insertionIndex = currentIsInPool && !nextBatch.isEmpty
                ? Int.random(in: 0..<nextBatch.count)
                : 0
            nextBatch.insert(currentItem, at: insertionIndex)
            if nextBatch.count > limit {
                nextBatch.removeLast()
            }
        }
        if nextBatch.isEmpty, let currentItem {
            nextBatch = [currentItem]
        }
        if nextBatch.isEmpty {
            nextBatch = Array(pool.prefix(limit))
        }

        batchItems = nextBatch
        if let currentItem,
           let index = nextBatch.firstIndex(where: { $0.id == currentItem.id }) {
            selectedItem = nextBatch[index]
        } else {
            selectedItem = nextBatch[min(1, nextBatch.count - 1)]
        }
        lastBatchIDs = Set(nextBatch.map(\.id))
        errorMessage = nil
        previewWarmupToken = UUID()
    }

    /// 批次还在时（同一文件夹下再次打开），把「当前壁纸」同步成候选项与选中项。
    private func ensureCurrentWallpaperInBatch() {
        guard let current = MenuBarQuickWallpaperRepository.shared.currentItem(
            matching: currentWallpaperURL
        ) else { return }

        // 上一次打开合成了 external「当前壁纸」；这次换成了别的壁纸就把它清掉，
        // 避免同一张壁纸以两条候选出现。
        var updated = batchItems.filter { $0.isLibraryItem || $0.id == current.id }
        if !updated.contains(where: { Self.isSameWallpaper($0, current) }) {
            updated.insert(current, at: 0)
            if updated.count > Self.batchSize {
                updated.removeLast()
            }
        }
        guard !updated.isEmpty else {
            replaceBatch(avoidPreviousBatch: false)
            return
        }
        if updated.map(\.id) != batchItems.map(\.id) {
            batchItems = updated
            lastBatchIDs = Set(updated.map(\.id))
            previewWarmupToken = UUID()
        }
        selectedItem = batchItems.first { Self.isSameWallpaper($0, current) } ?? current
        errorMessage = nil
    }

    private static func isSameWallpaper(
        _ lhs: MenuBarQuickWallpaperItem,
        _ rhs: MenuBarQuickWallpaperItem
    ) -> Bool {
        lhs.id == rhs.id
            || lhs.localURL.standardizedFileURL.path == rhs.localURL.standardizedFileURL.path
    }

    private func updateThumbnail(_ thumbnailURL: URL?, for itemID: String) {
        guard let thumbnailURL else { return }
        batchItems = batchItems.map { item in
            item.id == itemID ? item.replacingThumbnail(with: thumbnailURL) : item
        }
        if selectedItem?.id == itemID,
           let refreshed = batchItems.first(where: { $0.id == itemID }) {
            selectedItem = refreshed
        }
    }

    private func resolvedTargetScreen() -> NSScreen? {
        NSScreen.screens.first {
            $0.wallpaperScreenIdentifier == targetScreenID
                || $0.wallpaperScreenFingerprint == targetScreenFingerprint
        }
    }
}

@MainActor
private final class MenuBarQuickWallpaperRepository {
    static let shared = MenuBarQuickWallpaperRepository()

    private let fileManager = FileManager.default

    /// 打开弹窗的路径是同步的，而重建一次列表要对每条记录做多次存在性检查
    /// （原片还挂在外置盘上）：库一大，单次就是几百次 stat，直接表现为
    /// 「点开菜单栏要等一等」。
    ///
    /// 分两层缓存：
    /// - `allItems()`：整份候选项（不做文件夹筛选），按「记录指纹」缓存。指纹只做
    ///   内存遍历，比磁盘 stat 便宜几个数量级；
    /// - `items(folderIDs:)`：在 allItems 上做内存过滤，并按选择缓存。
    /// 「当前壁纸」也要出现在候选里，如果为它单独再构建一遍全量，就会把打开弹窗
    /// 的 stat 开销翻倍 —— 所以全量构建只做一次。external（库里没有记录）的
    /// 当前壁纸不进缓存，由 `currentItem(matching:)` 每次按当前屏 URL 实时合成。
    private var cachedAllItems: [MenuBarQuickWallpaperItem] = []
    private var cachedAllFingerprint: String?
    private var cachedFilteredItems: [String: [MenuBarQuickWallpaperItem]] = [:]
    /// 当前壁纸的定位结果（键 = 当前路径 + allItems 指纹），避免每次打开都全扫一遍。
    private var cachedCurrentKey: String?
    private var cachedCurrentItem: MenuBarQuickWallpaperItem?
    /// 记录指纹按 0.5s 复用：一次打开会连着问两三次，没必要重复遍历整个库。
    private var cachedFingerprint: String?
    private var cachedFingerprintAt: Date = .distantPast

    /// 打开耗时诊断（日志用）。
    private(set) var lastAllItemsCacheHit = true
    private(set) var lastBuildDurationMS = 0
    private(set) var lastCurrentLookupMS = 0

    func allItems() -> [MenuBarQuickWallpaperItem] {
        let fingerprint = recordFingerprint()
        if cachedAllFingerprint == fingerprint {
            lastAllItemsCacheHit = true
            return cachedAllItems
        }
        lastAllItemsCacheHit = false
        let buildStart = Date()
        let items = buildItems()
        lastBuildDurationMS = Int(Date().timeIntervalSince(buildStart) * 1000)
        cachedAllItems = items
        cachedAllFingerprint = fingerprint
        cachedFilteredItems.removeAll(keepingCapacity: true)
        cachedCurrentKey = nil
        cachedCurrentItem = nil
        return items
    }

    func items(folderIDs: [String]?) -> [MenuBarQuickWallpaperItem] {
        let all = allItems()
        guard let folderIDs else { return all }
        let key = folderIDs.isEmpty ? "<unfiled>" : folderIDs.joined(separator: "|")
        if let cached = cachedFilteredItems[key] {
            return cached
        }
        let filtered = all.filter {
            matchesFolderSelection($0.folderID, selectedFolderIDs: folderIDs)
        }
        cachedFilteredItems[key] = filtered
        return filtered
    }

    /// 当前屏正在使用的壁纸对应的候选项。
    ///
    /// - 命中一条可见的下载记录：直接复用记录项（缩略图、详情、收藏都可用）。
    /// - 命中记录但所在文件夹被锁定/隐藏：返回 nil —— 状态栏弹窗不展示锁定文件夹
    ///   的内容，这条既有约束优先于「当前壁纸必须出现」。
    /// - 没有记录：合成一个 external 项（文件必须仍存在），不进缓存。
    ///
    /// 打开弹窗是同步路径：先按未标准化的路径做纯字符串快筛，没命中才退回
    /// `standardizedFileURL` 的等价判定（保持与旧实现相同的匹配语义），
    /// 结果再按「路径 + 记录指纹」缓存 —— 库大时不能每次打开都 O(n) 全扫。
    func currentItem(matching currentURL: URL?) -> MenuBarQuickWallpaperItem? {
        guard let currentURL, currentURL.isFileURL else { return nil }
        let lookupStart = Date()
        let all = allItems()
        let rawPath = Self.normalizedPath(currentURL.path)
        let cacheKey = "\(rawPath)#\(cachedAllFingerprint ?? "")"
        if cachedCurrentKey == cacheKey {
            lastCurrentLookupMS = Int(Date().timeIntervalSince(lookupStart) * 1000)
            return cachedCurrentItem
        }

        var item = all.first { Self.matches(rawPath, item: $0) }
        if item == nil {
            let standardizedPath = Self.normalizedPath(currentURL.standardizedFileURL.path)
            if standardizedPath != rawPath {
                item = all.first {
                    Self.matches(standardizedPath, item: $0, standardizeItemPaths: true)
                }
            }
        }
        if item == nil {
            if matchingRecord(for: currentURL) != nil {
                // 记录存在却没出现在 allItems 里：要么被锁定文件夹过滤（保持隐藏），
                // 要么原片此刻不存在（没有可展示的项）。两种都不注入。
                item = nil
            } else {
                item = externalItem(for: currentURL)
            }
        }
        cachedCurrentKey = cacheKey
        cachedCurrentItem = item
        lastCurrentLookupMS = Int(Date().timeIntervalSince(lookupStart) * 1000)
        return item
    }

    private func matchingRecord(
        for currentURL: URL
    ) -> (folderID: String?, contentType: LibraryFolder.FolderContentType)? {
        let rawPath = Self.normalizedPath(currentURL.path)
        let standardizedPath = Self.normalizedPath(currentURL.standardizedFileURL.path)
        func matchesPath(_ candidate: String) -> Bool {
            Self.pathMatches(rawPath, candidate) || Self.pathMatches(standardizedPath, candidate)
        }
        if let record = WallpaperLibraryService.shared.downloadedWallpapers.first(where: {
            matchesPath($0.localFilePath)
        }) {
            return (record.folderID, .wallpaper)
        }
        for record in MediaLibraryService.shared.downloadedItems {
            if matchesPath(record.localFilePath) {
                return (record.folderID, .media)
            }
            if let bakedPath = record.sceneBakeArtifact?.videoPath, matchesPath(bakedPath) {
                return (record.folderID, .media)
            }
            // 解析后的视频路径也算命中（会做目录遍历，所以只在这条兜底链上查）。
            if let resolved = record.resolvedVideoFileURL, matchesPath(resolved.path) {
                return (record.folderID, .media)
            }
        }
        return nil
    }

    private func externalItem(for url: URL) -> MenuBarQuickWallpaperItem? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        let isVideo = !isDirectory.boolValue
            && Self.videoExtensions.contains(url.pathExtension.lowercased())
        let title = url.deletingPathExtension().lastPathComponent
        return MenuBarQuickWallpaperItem(
            id: "current.\(url.standardizedFileURL.path)",
            title: title.isEmpty ? url.lastPathComponent : title,
            localURL: url,
            // 静态图直接拿原图当缩略图；视频/工程目录留给 previewURL(for:) 抽帧。
            thumbnailURL: (!isDirectory.boolValue && !isVideo) ? url : nil,
            videoPreviewURL: isVideo ? url : nil,
            downloadedAt: .distantPast,
            source: .external,
            sceneBakeItemID: nil,
            bakedVideoPath: nil,
            folderID: nil
        )
    }

    private static func matches(
        _ currentPath: String,
        item: MenuBarQuickWallpaperItem,
        standardizeItemPaths: Bool = false
    ) -> Bool {
        func candidatePath(_ url: URL) -> String {
            normalizedPath(standardizeItemPaths ? url.standardizedFileURL.path : url.path)
        }
        if pathMatches(currentPath, candidatePath(item.localURL)) {
            return true
        }
        if let videoPreviewURL = item.videoPreviewURL,
           pathMatches(currentPath, candidatePath(videoPreviewURL)) {
            return true
        }
        if let bakedVideoPath = item.bakedVideoPath,
           pathMatches(currentPath, normalizedPath(bakedVideoPath)) {
            return true
        }
        return false
    }

    /// 纯字符串判定：当前壁纸可能就是记录本身、记录目录里的文件，或记录的父目录。
    private static func pathMatches(_ currentPath: String, _ candidatePath: String) -> Bool {
        guard !currentPath.isEmpty, !candidatePath.isEmpty else { return false }
        let candidate = normalizedPath(candidatePath)
        return currentPath == candidate
            || currentPath.hasPrefix(candidate + "/")
            || candidate.hasPrefix(currentPath + "/")
    }

    private static func normalizedPath(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private func recordFingerprint() -> String {
        let now = Date()
        if let cachedFingerprint,
           now.timeIntervalSince(cachedFingerprintAt) < 0.5 {
            return cachedFingerprint
        }
        var hasher = Hasher()
        for record in WallpaperLibraryService.shared.downloadedWallpapers {
            hasher.combine(record.id)
            hasher.combine(record.folderID)
            hasher.combine(record.localFilePath)
        }
        for record in MediaLibraryService.shared.downloadedItems {
            hasher.combine(record.id)
            hasher.combine(record.folderID)
            hasher.combine(record.localFilePath)
            hasher.combine(record.sceneBakeArtifact?.videoPath)
        }
        let value = String(hasher.finalize())
        cachedFingerprint = value
        cachedFingerprintAt = now
        return value
    }

    private func buildItems() -> [MenuBarQuickWallpaperItem] {
        let wallpaperItems = WallpaperLibraryService.shared.downloadedWallpapers
            .filter {
                MenuBarQuickSwitcherFolderVisibility.isVisible(
                    folderID: $0.folderID,
                    contentType: .wallpaper
                )
            }
            .compactMap { makeWallpaperItem(from: $0) }
        let mediaItems = MediaLibraryService.shared.downloadedItems
            .filter {
                MenuBarQuickSwitcherFolderVisibility.isVisible(
                    folderID: $0.folderID,
                    contentType: .media
                )
            }
            .compactMap { makeMediaItem(from: $0) }
        return (wallpaperItems + mediaItems)
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }

    private func matchesFolderSelection(
        _ folderID: String?,
        selectedFolderIDs: [String]?
    ) -> Bool {
        guard let selectedFolderIDs else { return true }
        let normalizedFolderID = folderID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedFolderIDs.isEmpty {
            return normalizedFolderID?.isEmpty ?? true
        }
        guard let normalizedFolderID, !normalizedFolderID.isEmpty else { return false }
        return selectedFolderIDs.contains(normalizedFolderID)
    }

    func previewURL(for item: MenuBarQuickWallpaperItem) async -> URL? {
        if let thumbnailURL = item.thumbnailURL {
            return thumbnailURL
        }

        if let videoURL = item.videoPreviewURL {
            return await highQualityVideoPreviewURL(for: videoURL)
        }

        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: item.localURL.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            // Scene/Web 工程没有可播放成片时，只显示它们明确提供的本地预览。
            if let preview = MediaItem.resolveLocalWorkshopPreviewImage(from: item.localURL) {
                return await localRasterPreviewURL(for: preview)
            }
            // Fallback: try cached frame thumbnails from VideoThumbnailCache
            if let videoURL = item.videoPreviewURL,
               let cached = VideoThumbnailCache.shared.cachedListThumbnailFileURLIfExists(forLocalVideo: videoURL) {
                return cached
            }
            if let bakedPath = item.bakedVideoPath {
                let bakedURL = URL(fileURLWithPath: bakedPath)
                if let cached = VideoThumbnailCache.shared.cachedListThumbnailFileURLIfExists(forLocalVideo: bakedURL)
                    ?? VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(itemID: item.sceneBakeItemID ?? "") {
                    return cached
                }
            }
            return nil
        }

        if LocalImageThumbnailCache.isGIFFile(item.localURL) {
            return item.localURL
        }
        if LocalImageThumbnailCache.isRasterImageFile(item.localURL) {
            return await localRasterPreviewURL(for: item.localURL)
        }
        return nil
    }

    private func makeWallpaperItem(
        from record: WallpaperDownloadRecord
    ) -> MenuBarQuickWallpaperItem? {
        guard fileManager.fileExists(atPath: record.localFilePath) else { return nil }
        return MenuBarQuickWallpaperItem(
            id: "wallpaper.\(record.id)",
            title: record.wallpaper.title ?? record.wallpaper.id,
            localURL: record.localFileURL,
            thumbnailURL: record.localFileURL,
            videoPreviewURL: nil,
            downloadedAt: record.downloadedAt,
            source: .wallpaper(record.wallpaper),
            sceneBakeItemID: nil,
            bakedVideoPath: nil,
            folderID: record.folderID
        )
    }

    private func makeMediaItem(
        from record: MediaDownloadRecord
    ) -> MenuBarQuickWallpaperItem? {
        guard fileManager.fileExists(atPath: record.localFilePath) else { return nil }

        let localURL = record.localFileURL
        let videoPreviewURL = resolvedVideoPreviewURL(for: record)
        let thumbnailURL: URL?
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
        if let videoPreviewURL,
           let thumbnail = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(
                forLocalFile: videoPreviewURL
           ) {
            thumbnailURL = thumbnail
        } else if let bakedVideoPath = record.sceneBakeArtifact?.videoPath,
           let thumbnail = VideoThumbnailCache.shared.cachedListThumbnailFileURLIfExists(
                forLocalVideo: URL(fileURLWithPath: bakedVideoPath)
           ) ?? VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(itemID: record.item.id) {
            thumbnailURL = thumbnail
        } else if !isDirectory.boolValue {
            thumbnailURL = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(
                forLocalFile: localURL
            )
        } else {
            // Fallback: try cached frame thumbnails from VideoThumbnailCache
            if let videoURL = videoPreviewURL ?? record.sceneBakeArtifact.map({ URL(fileURLWithPath: $0.videoPath) }),
               let cached = VideoThumbnailCache.shared.cachedListThumbnailFileURLIfExists(forLocalVideo: videoURL) {
                thumbnailURL = cached
            } else if let cached = VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(itemID: record.item.id) {
                thumbnailURL = cached
            } else {
                thumbnailURL = nil
            }
        }

        // 只暴露 usable 烘焙产物；过期/损坏路径留给 LocalWallpaperApplyService 再解析。
        let usableBakePath = SceneOfflineBakeService.usableArtifact(from: record)?.videoPath

        return MenuBarQuickWallpaperItem(
            id: "media.\(record.id)",
            title: record.item.title,
            localURL: localURL,
            thumbnailURL: thumbnailURL,
            videoPreviewURL: videoPreviewURL,
            downloadedAt: record.downloadedAt,
            source: .media(record.item),
            sceneBakeItemID: record.item.id,
            bakedVideoPath: usableBakePath,
            folderID: record.folderID
        )
    }

    private func resolvedVideoPreviewURL(for record: MediaDownloadRecord) -> URL? {
        if let artifact = SceneOfflineBakeService.usableArtifact(from: record) {
            let bakedURL = URL(fileURLWithPath: artifact.videoPath)
            if fileManager.fileExists(atPath: bakedURL.path) {
                return bakedURL
            }
        }

        let localURL = record.localFileURL
        let projectType = MediaItem.localWorkshopProjectType(from: localURL)
        if let projectType, projectType != "video" {
            return nil
        }

        if Self.videoExtensions.contains(localURL.pathExtension.lowercased()) {
            return localURL
        }

        if let videoURL = MediaItem.resolveLocalVideoFile(from: localURL),
           Self.videoExtensions.contains(videoURL.pathExtension.lowercased()),
           fileManager.fileExists(atPath: videoURL.path) {
            return videoURL
        }

        return nil
    }

    private func highQualityVideoPreviewURL(for videoURL: URL) async -> URL? {
        // 弹窗 chip 只有 56px、hero 342pt —— 列表帧（960 上限、2 并发）完全够用。
        // 不要落进 posterJPEGFileURL：那是 3840×2160 全分辨率 letterbox 扫描、
        // 全局串行 1 并发，一张外置盘冷读 2.6s 的 4K 会把整条缩略图队列卡死
        //（2026-10-13 弹窗图片/视频出得慢的主因之一）。
        if let listThumbnail = await VideoThumbnailCache.shared.listThumbnailJPEGFileURL(
            forLocalVideo: videoURL
        ) {
            return listThumbnail
        }
        // 仅当列表帧彻底生成失败时才退到 poster 缓存（只查已存在的，不再触发生成；
        // 桌面/锁屏 poster 由设壁纸链路自己生成，弹窗只是读取方）。
        return VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(
            forLocalFile: videoURL
        )
    }

    private func localRasterPreviewURL(for url: URL) async -> URL {
        if LocalImageThumbnailCache.isGIFFile(url) {
            return url
        }
        return await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: url) ?? url
    }

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "webm", "m4v", "mkv"
    ]
}

@MainActor
private enum MenuBarQuickSwitcherFolderVisibility {
    /// The status-item panel must never reveal content in a locked library folder.
    /// A child folder is also hidden when any of its ancestors is locked.
    static func isVisible(
        folderID: String?,
        contentType: LibraryFolder.FolderContentType
    ) -> Bool {
        var nextFolderID = normalizedFolderID(folderID)
        var visitedFolderIDs = Set<String>()

        while let currentFolderID = nextFolderID {
            // A cyclic hierarchy is invalid, but treat it as unavailable to avoid
            // exposing content from an ambiguous locked path.
            guard visitedFolderIDs.insert(currentFolderID).inserted else {
                return false
            }
            guard let folder = LibraryFolderStore.shared.folder(
                withID: currentFolderID,
                contentType: contentType
            ) else {
                return true
            }
            guard !folder.isLocked else {
                return false
            }
            nextFolderID = normalizedFolderID(folder.parentFolderID)
        }

        return true
    }

    private static func normalizedFolderID(_ folderID: String?) -> String? {
        guard let folderID else { return nil }
        let trimmed = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
