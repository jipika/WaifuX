import AppKit
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
        viewModel.prepare(
            targetScreen: targetScreen,
            currentWallpaperURL: currentWallpaperURL,
            canDesignCurrentWallpaper: canDesignCurrentWallpaper
        )
        mountContentIfNeeded()

        positionPanel(relativeTo: anchorView, on: targetScreen)
        panel.alphaValue = 1
        // A nonactivating panel can become key for input without making WaifuX the
        // foreground application, so background Screen Time does not resume here.
        panel.makeKeyAndOrderFront(nil)
        installDismissMonitors()
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

    @Published private(set) var batchItems: [MenuBarQuickWallpaperItem] = []
    @Published private(set) var selectedItem: MenuBarQuickWallpaperItem?
    @Published private(set) var isApplying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var previewWarmupToken = UUID()
    @Published private(set) var canDesignCurrentWallpaper = false
    /// nil = 我的库（全部本地项目）；非空数组 = 选中的下载文件夹。
    @Published private(set) var selectedFolderIDs: [String]?

    var onOpenSettings: (() -> Void)?
    var onOpenDesignWallpaper: (() -> Void)?
    var onApplied: (() -> Void)?
    var onOpenDetail: ((MainWallpaperDetailRequest) -> Void)?
    var onQuitApplication: (() -> Void)?

    private var targetScreenID: String?
    private var targetScreenFingerprint: String?
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

        guard !batchItems.isEmpty, !didChangeFolderSelection else {
            replaceBatch(preferredCurrentURL: currentWallpaperURL, avoidPreviousBatch: false)
            return
        }

        if let current = MenuBarQuickWallpaperRepository
            .shared
            .items(folderIDs: selectedFolderIDs)
            .first(where: { Self.matchesCurrentWallpaper(currentWallpaperURL, localURL: $0.localURL) }) {
            if !batchItems.contains(where: { $0.id == current.id }) {
                var refreshedBatch = batchItems
                // Keep current wallpaper near the start of the visible rail.
                if refreshedBatch.indices.contains(1) {
                    refreshedBatch[1] = current
                } else {
                    refreshedBatch.insert(current, at: 0)
                }
                batchItems = Array(refreshedBatch.prefix(Self.batchSize))
                lastBatchIDs = Set(batchItems.map(\.id))
                previewWarmupToken = UUID()
            }
            select(current)
        }
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
        replaceBatch(preferredCurrentURL: nil, avoidPreviousBatch: true)
    }

    func toggleFavorite() {
        guard let selectedItem else { return }
        switch selectedItem.source {
        case .wallpaper(let wallpaper):
            WallpaperLibraryService.shared.toggleFavorite(wallpaper)
        case .media(let item):
            MediaLibraryService.shared.toggleFavorite(item)
        }
        objectWillChange.send()
    }

    func openSettings() {
        onOpenSettings?()
    }

    func quitApplication() {
        onQuitApplication?()
    }

    private func updateFolderSelection(_ folderIDs: [String]?) {
        guard selectedFolderIDs != folderIDs else { return }
        selectedFolderIDs = folderIDs
        MenuBarQuickFolderSelectionStore.save(folderIDs, scopeID: folderSelectionScopeID)
        persistFolderSelectionToScheduler(folderIDs)
        replaceBatch(preferredCurrentURL: nil, avoidPreviousBatch: false)
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

            AppLogger.info(.wallpaper, "菜单栏快速设置壁纸", metadata: [
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
            AppLogger.debug(.wallpaper, "菜单栏设置壁纸分段耗时", metadata: [
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
                    : screens.first?.wallpaperScreenIdentifier
            )
            isApplying = false
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

    func warmVisiblePreviews() async {
        let itemsToWarm = batchItems.filter { $0.thumbnailURL == nil }
        for item in itemsToWarm {
            if Task.isCancelled { return }
            guard previewTasks[item.id] == nil else { continue }
            while previewTasks.count >= Self.previewWarmupConcurrency {
                try? await Task.sleep(for: .milliseconds(40))
                if Task.isCancelled { return }
            }
            previewTasks[item.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                let thumbnailURL = await MenuBarQuickWallpaperRepository.shared.previewURL(for: item)
                guard !Task.isCancelled else { return }
                self.updateThumbnail(thumbnailURL, for: item.id)
                self.previewTasks[item.id] = nil
            }
        }
    }

    func suspendPreviewWork() {
        for task in previewTasks.values {
            task.cancel()
        }
        previewTasks.removeAll()
    }

    private func replaceBatch(preferredCurrentURL: URL?, avoidPreviousBatch: Bool) {
        let allItems = MenuBarQuickWallpaperRepository.shared.items(folderIDs: selectedFolderIDs)
        guard !allItems.isEmpty else {
            batchItems = []
            selectedItem = nil
            errorMessage = nil
            previewWarmupToken = UUID()
            return
        }

        let preferredItem = preferredCurrentURL.flatMap { currentURL in
            allItems.first { Self.matchesCurrentWallpaper(currentURL, localURL: $0.localURL) }
        }

        let limit = min(Self.batchSize, allItems.count)
        var candidates = allItems
        if avoidPreviousBatch {
            let fresh = candidates.filter { !lastBatchIDs.contains($0.id) }
            if fresh.count >= min(limit, allItems.count) {
                candidates = fresh
            }
        }

        var nextBatch = Array(candidates.shuffled().prefix(limit))
        if let preferredItem {
            nextBatch.removeAll { $0.id == preferredItem.id }
            // Prefer near the leading edge so the current wallpaper is easy to find while scrolling.
            nextBatch.insert(preferredItem, at: min(1, nextBatch.count))
            nextBatch = Array(nextBatch.prefix(limit))
        }
        if nextBatch.isEmpty {
            nextBatch = Array(allItems.prefix(limit))
        }

        batchItems = nextBatch
        selectedItem = preferredItem ?? nextBatch[min(1, nextBatch.count - 1)]
        lastBatchIDs = Set(nextBatch.map(\.id))
        errorMessage = nil
        previewWarmupToken = UUID()
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

    private static func matchesCurrentWallpaper(_ currentURL: URL?, localURL: URL) -> Bool {
        guard let currentURL, currentURL.isFileURL else { return false }
        let currentPath = currentURL.standardizedFileURL.path
        let localPath = localURL.standardizedFileURL.path
        return currentPath == localPath
            || currentPath.hasPrefix(localPath + "/")
            || localPath.hasPrefix(currentPath + "/")
    }
}

@MainActor
private final class MenuBarQuickWallpaperRepository {
    static let shared = MenuBarQuickWallpaperRepository()

    private let fileManager = FileManager.default

    /// 打开弹窗的路径是同步的，而重建一次列表要对每条记录做多次存在性检查
    /// （原片还挂在外置盘上）：库一大，单次就是几百次 stat，直接表现为
    /// 「点开菜单栏要等一等」。这里按「文件夹选择 + 记录指纹」整份缓存结果；
    /// 记录集合、归属或路径一变指纹就变、缓存自动失效 —— 指纹只做内存遍历，
    /// 比磁盘 stat 便宜几个数量级。
    private var cachedItems: [MenuBarQuickWallpaperItem] = []
    private var cachedKey: String?

    func items(folderIDs: [String]?) -> [MenuBarQuickWallpaperItem] {
        let key = recordFingerprint(folderIDs: folderIDs)
        if cachedKey == key {
            return cachedItems
        }
        let items = buildItems(folderIDs: folderIDs)
        cachedItems = items
        cachedKey = key
        return items
    }

    private func recordFingerprint(folderIDs: [String]?) -> String {
        var hasher = Hasher()
        hasher.combine(folderIDs?.joined(separator: "|") ?? "*")
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
        return String(hasher.finalize())
    }

    private func buildItems(folderIDs: [String]?) -> [MenuBarQuickWallpaperItem] {
        let wallpaperItems = WallpaperLibraryService.shared.downloadedWallpapers
            .filter {
                matchesFolderSelection($0.folderID, selectedFolderIDs: folderIDs)
                    && MenuBarQuickSwitcherFolderVisibility.isVisible(
                        folderID: $0.folderID,
                        contentType: .wallpaper
                    )
            }
            .compactMap { makeWallpaperItem(from: $0) }
        let mediaItems = MediaLibraryService.shared.downloadedItems
            .filter {
                matchesFolderSelection($0.folderID, selectedFolderIDs: folderIDs)
                    && MenuBarQuickSwitcherFolderVisibility.isVisible(
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
            bakedVideoPath: nil
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
            bakedVideoPath: usableBakePath
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
        if let listThumbnail = await VideoThumbnailCache.shared.listThumbnailJPEGFileURL(
            forLocalVideo: videoURL
        ) {
            return listThumbnail
        }
        return await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoURL)
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
