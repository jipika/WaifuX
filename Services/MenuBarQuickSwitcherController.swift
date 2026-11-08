import AppKit
import Combine
import Kingfisher
import QuartzCore
import SwiftUI

@MainActor
final class MenuBarQuickSwitcherController: NSObject {
    private let contentSize = MenuBarQuickSwitcherView.panelSize
    private let viewModel = MenuBarQuickSwitcherViewModel()
    private let panel: MenuBarQuickSwitcherPanel
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var presentationGeneration = 0
    private var prewarmSubscription: AnyCancellable?
    private var prewarmWorkItem: DispatchWorkItem?
    private var isDismissing = false
    private weak var statusAnchorView: NSView?
    private var presentationAnchorX: CGFloat = 0.5
    private let presentationAnimationKey = "quickSwitcher.presentation"

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
        panel.animationBehavior = .none
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
        if dismissForStatusItemClick() { return }

        statusAnchorView = anchorView
        isDismissing = false
        panel.ignoresMouseEvents = false
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
        let performanceStart = ProcessInfo.processInfo.systemUptime
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
        preparePresentationLayer()
        panel.alphaValue = 1
        // A nonactivating panel can become key for input without making WaifuX the
        // foreground application, so background Screen Time does not resume here.
        panel.makeKeyAndOrderFront(nil)
        animatePresentation(visible: true)
        let frontDone = Date()
        installDismissMonitors()
        InteractionPerformanceLog.record(.menuOpen, since: performanceStart, metadata: [
            "phase": "orderFront", "batch": String(viewModel.batchItems.count),
            "indexReady": MenuBarQuickWallpaperRepository.shared.isReady ? "1" : "0"
        ])

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

    /// Build the small static hosting tree once, outside the first click.
    func prewarm() {
        guard !panel.isVisible else { return }
        viewModel.prewarmCandidates()
        mountContentIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()
        guard prewarmSubscription == nil else { return }
        prewarmSubscription = MenuBarQuickWallpaperRepository.shared.changes.sink { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.prewarmWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.panel.isVisible else { return }
                self.viewModel.prewarmCandidates()
                self.panel.contentView?.layoutSubtreeIfNeeded()
            }
            self.prewarmWorkItem = work
            DispatchQueue.main.async(execute: work)
        }
    }

    func updateDesignAvailability(_ available: Bool) {
        viewModel.updateDesignAvailability(available)
    }

    /// A click on an already-visible menu belongs to its close, including its exit.
    /// Check this before preparing wallpaper/design metadata in the status action.
    @discardableResult
    func dismissForStatusItemClick() -> Bool {
        guard panel.isVisible || isDismissing || viewModel.isPresented else { return false }
        dismiss()
        return true
    }

    func dismiss() {
        guard !isDismissing, panel.isVisible || viewModel.isPresented else { return }
        removeDismissMonitors()
        isDismissing = true
        presentationGeneration &+= 1
        panel.ignoresMouseEvents = true
        // Stop decoding immediately, but keep covers mounted until the exit finishes.
        viewModel.suspendPreviewWork(keepingPresentation: true)
        animatePresentation(visible: false)
    }

    private var collapsedTransform: CATransform3D {
        // Keep the point beneath the status item stationary, even near screen edges.
        // A transform changes no AppKit frames and causes no SwiftUI relayout.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return CATransform3DIdentity }
        let scale: CGFloat = 0.94
        let layer = panel.contentView?.layer
        let anchor = layer?.anchorPoint ?? .zero
        let pivotX = (presentationAnchorX - anchor.x) * contentSize.width
        let isFlipped = panel.contentView?.isFlipped ?? false
        let pivotY = ((isFlipped ? 0 : 1) - anchor.y) * contentSize.height
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(pivotX * (1 - scale), pivotY * (1 - scale), 0))
    }

    private func preparePresentationLayer() {
        guard let layer = panel.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: presentationAnimationKey)
        layer.transform = collapsedTransform
        layer.opacity = 0
        CATransaction.commit()
    }

    private func animatePresentation(visible: Bool) {
        let generation = presentationGeneration
        guard let layer = panel.contentView?.layer else {
            if !visible { finishDismissal(generation: generation) }
            return
        }
        // A hidden, prewarmed layer can still have an old presentation value.
        // Only an in-flight transition should supply the starting screen value.
        let current = layer.animation(forKey: presentationAnimationKey) != nil
            ? (layer.presentation() ?? layer) : layer
        let fromTransform = current.transform
        let fromOpacity = current.opacity
        let targetTransform = visible ? CATransform3DIdentity : collapsedTransform
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: TimeInterval = reducedMotion ? 0.08 : (visible ? 0.18 : 0.13)
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: fromTransform)
        transform.toValue = NSValue(caTransform3D: targetTransform)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fromOpacity
        opacity.toValue = visible ? Float(1) : Float(0)
        transform.duration = duration
        opacity.duration = duration
        let group = CAAnimationGroup()
        group.animations = [transform, opacity]
        group.duration = duration
        group.timingFunction = visible
            ? CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            : CAMediaTimingFunction(controlPoints: 0.2, 0, 0.6, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !visible {
            CATransaction.setCompletionBlock { [weak self] in
                // Core Animation calls completion after replacement as well as completion.
                // The presentation generation prevents an old close hiding a new open.
                Task { @MainActor [weak self] in
                    self?.finishDismissal(generation: generation)
                }
            }
        }
        layer.transform = targetTransform
        layer.opacity = visible ? 1 : 0
        layer.add(group, forKey: presentationAnimationKey)
        CATransaction.commit()
    }

    private func finishDismissal(generation: Int) {
        guard presentationGeneration == generation, isDismissing else { return }
        panel.orderOut(nil)
        viewModel.finishHidingPresentation()
        isDismissing = false
        panel.ignoresMouseEvents = false
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
        presentationAnchorX = min(max((screenRect.midX - origin.x) / contentSize.width, 0), 1)
    }

    private func isStatusItemMouseDown(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown || event.type == .rightMouseDown,
              let anchor = statusAnchorView, let window = anchor.window else { return false }
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        // Status-item input may arrive through a system window/global monitor.
        // A windowless event already carries screen coordinates.
        let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
            ?? event.locationInWindow
        return frame.contains(location)
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

            if self.isStatusItemMouseDown(event) {
                // The status item's mouseUp action owns the toggle. Dismissing on
                // mouseDown would turn that same click into a mid-exit reopen.
                return event
            }
            if event.window !== self.panel { self.dismiss() }
            return event
        }

        let generation = presentationGeneration
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // AppKit invokes event monitors on the main thread. Capture the hit now;
            // a later cursor position could belong to a different click.
            let isStatusItemClick = MainActor.assumeIsolated {
                self?.isStatusItemMouseDown(event) ?? false
            }
            guard !isStatusItemClick else { return }
            DispatchQueue.main.async {
                guard let self, self.presentationGeneration == generation else { return }
                self.dismiss()
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
        var showsVolumeControl = false

        static let empty = PlaybackSnapshot()
    }

    @Published private(set) var batchItems: [MenuBarQuickWallpaperItem] = []
    @Published private(set) var selectedItem: MenuBarQuickWallpaperItem?
    @Published private(set) var applyProgress = WallpaperApplyProgressState()
    var isApplying: Bool { applyProgress.isApplying }
    var isBlockingApply: Bool { applyProgress.isBlocking }
    var synchronizationStatus: String? {
        guard isApplying, !isBlockingApply else { return nil }
        return t(applyProgress.stage == .committing
            ? "menubar.quick.finishingApply" : "menubar.quick.syncingWallpaper")
    }
    private var applyTask: Task<Void, Never>?
    @Published private(set) var errorMessage: String?
    @Published private(set) var previewWarmupToken = UUID()
    @Published private(set) var isPresented = false
    @Published private(set) var isPreviewActive = false
    private(set) var activationGeneration: UInt64 = 0
    let playbackActivity = LoopingVideoPlaybackActivity()
    private var warmupGeneration: UInt64 = 0
    private var userSelectedCandidate = false
    private var coverVersions: [String: Int] = [:]

    func coverRevision(for id: String) -> Int {
        coverVersions[id, default: 0] + MenuBarQuickWallpaperRepository.shared.previewRevision(for: id)
    }
    private func isActive(_ generation: UInt64) -> Bool {
        isPreviewActive && activationGeneration == generation
    }
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
    /// 封面同路径覆盖（重新抽帧）时 URL 不变，KFImage 不会重载；视图把它拼进 `.id` 强制换图。
    @Published private(set) var coverRevision = 0
    private var coverObservers: Set<AnyCancellable> = []
    /// 封面更新通知触发的重解析任务；与 `previewTasks` 分开，免得打乱预热并发槽计数。
    private var coverRefreshTasks: [String: Task<Void, Never>] = [:]
    private var playbackObservers: Set<AnyCancellable> = []
    private var libraryObservers: Set<AnyCancellable> = []
    private var playbackRefreshWorkItem: DispatchWorkItem?
    private var currentWallpaperIdentityTask: Task<Void, Never>?

    var onOpenSettings: (() -> Void)?
    var onOpenDesignWallpaper: (() -> Void)?
    var onApplied: (() -> Void)?
    var onOpenDetail: ((MainWallpaperDetailRequest) -> Void)?
    var onQuitApplication: (() -> Void)?

    private var targetScreenID: String?
    private var targetScreenFingerprint: String?
    /// 菜单栏所在屏幕实际显示的壁纸；竖屏时可能是 blur-fill 派生图。
    private var currentWallpaperURL: URL?
    /// 用于反查库记录的 URL；派生图异步映射回原图，普通壁纸保持原值。
    private var currentWallpaperLookupURL: URL?
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

    func prewarmCandidates() {
        guard !isPresented else { return }
        reconcileCachedBatch()
        if batchItems.isEmpty { replaceBatch(avoidPreviousBatch: false) }
    }

    func updateDesignAvailability(_ available: Bool) {
        guard isPresented, canDesignCurrentWallpaper != available else { return }
        canDesignCurrentWallpaper = available
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
        activationGeneration &+= 1
        playbackActivity.resume()
        isPresented = true
        isPreviewActive = true
        userSelectedCandidate = false
        targetScreenID = targetScreen?.wallpaperScreenIdentifier
        targetScreenFingerprint = targetScreen?.wallpaperScreenFingerprint
        self.canDesignCurrentWallpaper = canDesignCurrentWallpaper
        // 记住该屏正在使用的壁纸：后面每次重建批次、换一批、切文件夹都要保证
        // 它仍作为候选项出现，并且默认被选中（hero 大图同步）。
        self.currentWallpaperURL = currentWallpaperURL
        self.currentWallpaperLookupURL = currentWallpaperURL
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
        reconcileCachedBatch()
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
        startObservingCoverUpdates()
        startObservingLibraryState()
        previewWarmupToken = UUID()
        let generation = activationGeneration
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isActive(generation) else { return }
            self.resolveCurrentWallpaperIdentity()
            self.refreshPlaybackSnapshot()
        }
    }

    func item(at index: Int) -> MenuBarQuickWallpaperItem? {
        guard batchItems.indices.contains(index) else { return nil }
        return batchItems[index]
    }

    func select(_ item: MenuBarQuickWallpaperItem) {
        userSelectedCandidate = true
        selectedItem = item
        previewWarmupToken = UUID()
        errorMessage = nil
    }

    func selectNextItem() {
        userSelectedCandidate = true
        previewWarmupToken = UUID()
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
    var hasLivePlayback: Bool { playbackSnapshot.hasLivePlayback }

    /// 音量键是否显示：锁屏扩展模式的壁纸跑在扩展进程里，宿主侧只有
    /// per-display 静音/暂停 prefs、没有连续音量接口（与右键菜单
    /// `if !isExtensionMode` 跳过音量滑块同一约束），此时隐藏音量键。
    /// scene/web/本机视频都可用：WE 的 setVolume 热推渲染器 audioControl
    /// 文件 + web daemon IPC，视频写 per-screen 存储。
    var showsVolumeControl: Bool { playbackSnapshot.showsVolumeControl }

    /// 该屏当前是否暂停（视频按屏查；WE 只有全局暂停态）。
    var isPlaybackPaused: Bool { playbackSnapshot.isPaused }

    /// 该屏音量（视频按屏独立；WE 走 VideoWallpaperManager 的每屏音量）。
    var playbackVolume: Double { playbackSnapshot.volume }

    /// 该屏播放速度（只对本机视频有效；WE/静态壁纸返回 nil → 面板隐藏）。
    var playbackRate: Double? { playbackSnapshot.rate }

    /// 是否可以切上一张/下一张（有可轮换的调度项）。
    var canSwitchWallpaper: Bool { playbackSnapshot.canGoNext }

    /// 是否有可回退的上一张。
    var canGoPrevious: Bool { playbackSnapshot.canGoPrevious }

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

        if #available(macOS 26.0, *), videoManager.isLockScreenMirroringActive {
            snapshot.showsVolumeControl = false
        } else {
            snapshot.showsVolumeControl = snapshot.hasLivePlayback
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
        guard isPreviewActive else { return }
        let next = readPlaybackSnapshot()
        guard next != playbackSnapshot else { return }
        playbackSnapshot = next
    }

    /// 订阅三个单例的发布：它们各自的暂停/音量/切换历史变化都要反映到弹窗。
    /// 合并窗口 30ms，一次用户操作里多个服务连环发通知只重绘一次。
    func startObservingPlaybackState() {
        guard playbackObservers.isEmpty else { return }
        let generation = activationGeneration
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
                guard let self, self.isActive(generation) else { return }
                self.playbackRefreshWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.isActive(generation) else { return }
                    self.refreshPlaybackSnapshot()
                }
                self.playbackRefreshWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: item)
            }
            .store(in: &playbackObservers)
    }

    /// 抽帧/烘焙封面落盘后（`.sceneOfflineBakeThumbnailDidUpdate`，object = itemID）
    /// 刷新候选项封面。抽帧不改下载记录，仓库按记录指纹缓存的旧 preview 必须显式失效。
    func startObservingCoverUpdates() {
        guard coverObservers.isEmpty else { return }
        let generation = activationGeneration
        NotificationCenter.default.publisher(for: .sceneOfflineBakeThumbnailDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, self.isActive(generation), let itemID = notification.object as? String else { return }
                let posterURL = notification.userInfo?["thumbnailURL"] as? URL
                self.handleCoverUpdate(itemID: itemID, posterURL: posterURL)
            }
            .store(in: &coverObservers)
    }

    /// 库快照/当前屏路径晚于弹窗到达时，重新计算当前项，不把 provisional external 留到最后。
    private func startObservingLibraryState() {
        guard libraryObservers.isEmpty else { return }
        let generation = activationGeneration
        MenuBarQuickWallpaperRepository.shared.changes
            .sink { [weak self] in
                guard let self, self.isActive(generation) else { return }
                self.reconcileCachedBatch()
                if self.batchItems.isEmpty {
                    self.replaceBatch(avoidPreviousBatch: false)
                } else {
                    self.ensureCurrentWallpaperInBatch(selectCurrent: !self.userSelectedCandidate)
                }
                self.previewWarmupToken = UUID()
            }.store(in: &libraryObservers)

        CurrentWallpaperService.shared.$activeURLByScreenID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] values in
                guard let self, self.isActive(generation),
                      let screen = self.resolvedTargetScreen(),
                      let url = values[screen.wallpaperScreenIdentifier],
                      self.currentWallpaperURL != url else { return }
                self.currentWallpaperURL = url
                self.resolveCurrentWallpaperIdentity()
            }
            .store(in: &libraryObservers)
    }

    private func resolveCurrentWallpaperIdentity() {
        currentWallpaperIdentityTask?.cancel()
        currentWallpaperIdentityTask = nil
        guard let presentedURL = currentWallpaperURL else {
            currentWallpaperLookupURL = nil
            return
        }
        // 先沿原路径立即展示，避免读映射拖延弹窗；异步命中库记录后再替换 external。
        currentWallpaperLookupURL = presentedURL
        reconcileCurrentWallpaperSelection()
        // 非派生图路径（视频 / scene / web / 原图直设）不读 blur-fill 映射。
        let derivedDirectory = VideoThumbnailCache.libraryLookupContext().root
            .appendingPathComponent("DerivedWallpapers", isDirectory: true)
        let derivedPrefix = derivedDirectory
            .appendingPathComponent("PortraitBlurFill", isDirectory: true)
            .standardizedFileURL.path + "/"
        guard presentedURL.standardizedFileURL.path.hasPrefix(derivedPrefix) else { return }
        let generation = activationGeneration
        currentWallpaperIdentityTask = Task { @MainActor [weak self] in
            let sourceURL = await PortraitBlurFillWallpaperService.shared.originalSourceURL(
                forDerivedWallpaperAt: presentedURL,
                derivedWallpapersDirectory: derivedDirectory
            )
            guard let self, !Task.isCancelled, self.isActive(generation),
                  self.currentWallpaperURL == presentedURL else { return }
            self.currentWallpaperIdentityTask = nil
            self.currentWallpaperLookupURL = sourceURL ?? presentedURL
            self.reconcileCurrentWallpaperSelection()
        }
    }

    private func reconcileCurrentWallpaperSelection() {
        // 用户已手动点选另一张库壁纸时，异步身份结果只更新候选，不抢走选中。
        let userPickedOther = userSelectedCandidate
        ensureCurrentWallpaperInBatch(selectCurrent: !userPickedOther)
    }

    private func handleCoverUpdate(itemID: String, posterURL: URL?) {
        let generation = activationGeneration
        let targets = batchItems.filter { $0.sceneBakeItemID == itemID }
        for item in targets {
            coverVersions[item.id, default: 0] &+= 1
            previewTasks[item.id]?.cancel()
            previewTasks[item.id] = nil
            coverRefreshTasks[item.id]?.cancel()
            coverRefreshTasks[item.id] = Task { @MainActor [weak self] in
                if let posterURL {
                    let processor = DownsamplingImageProcessor(size: CGSize(width: 768, height: 768))
                    try? await ImageCache.default.removeImage(forKey: posterURL.cacheKey,
                        processorIdentifier: processor.identifier)
                }
                guard let self, !Task.isCancelled, self.isActive(generation) else { return }
                let resolved = await MenuBarQuickWallpaperRepository.shared.resolvePreview(for: item)
                guard !Task.isCancelled, self.isActive(generation) else { return }
                self.coverRefreshTasks[item.id] = nil
                self.updateResolvedPreview(resolved, replacing: item.id)
            }
        }
        coverRevision &+= 1
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
        guard !folderIDs.isEmpty else { return [] }
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
        guard let selectedItem, !isBlockingApply else { return }

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
        applyTask?.cancel()
        let requestID = UUID()
        let presentation = activationGeneration
        applyProgress.begin(requestID)
        errorMessage = nil
        applyTask = Task { [weak self] in
            guard let self else { return }
            await self.performApply(
                selectedItem,
                targetScreens: targetScreens,
                globallySynced: globallySynced,
                requestID: requestID,
                presentation: presentation
            )
        }
    }

    private func performApply(
        _ selectedItem: MenuBarQuickWallpaperItem,
        targetScreens: [NSScreen]?,
        globallySynced: Bool,
        requestID: UUID,
        presentation: UInt64
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
            try Task.checkCancellation()
            guard applyProgress.requestID == requestID else { throw CancellationError() }
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
                options: options,
                onStageChange: { [weak self] stage in
                    _ = self?.applyProgress.report(stage, for: requestID)
                }
            )
            try Task.checkCancellation()
            guard applyProgress.requestID == requestID else { throw CancellationError() }
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
            guard applyProgress.finish(requestID) else { return }
            applyTask = nil
            refreshPlaybackSnapshot()
            // Keep browsing open if the user selected another candidate while
            // the previous wallpaper was synchronizing in the background.
            if isActive(presentation), self.selectedItem?.id == selectedItem.id { onApplied?() }
        } catch {
            // A cancelled/older request may clean up its own renderer, but must
            // never dismiss this panel or clear a newer request's progress/error.
            guard applyProgress.requestID == requestID else { return }
            if error is CancellationError || Task.isCancelled {
                _ = applyProgress.finish(requestID)
                applyTask = nil
                return
            }
            AppLogger.error(.wallpaper, "菜单栏快速设置壁纸失败", metadata: [
                "item": selectedItem.id,
                "error": error.localizedDescription,
            ])
            if isActive(presentation) { errorMessage = error.localizedDescription }
            _ = applyProgress.finish(requestID)
            applyTask = nil
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
           let art = SceneOfflineBakeService.usableCurrentArtifact(from: record),
           SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath)) {
            return art.videoPath
        }
        // 也尝试按 content root 命中库记录（LocalWallpaperApplyService 内部会再查一次）
        if let record = MediaLibraryService.shared.downloadRecord(forLocalFilePath: applyURL.path),
           let art = SceneOfflineBakeService.usableCurrentArtifact(from: record),
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
        guard isPreviewActive else { return }
        warmupGeneration &+= 1
        let warmup = warmupGeneration
        let generation = activationGeneration
        for task in previewTasks.values { task.cancel() }
        previewTasks.removeAll()
        // Current hero first; the remainder is bounded to this sixteen-item batch.
        var items = batchItems
        if let selected = selectedItem {
            items.removeAll { $0.id == selected.id }
            items.insert(selected, at: 0)
        }
        for item in items {
            guard !Task.isCancelled, isActive(generation), warmupGeneration == warmup else { return }
            guard !MenuBarQuickWallpaperRepository.shared.cachedPreviewIsFresh(for: item.id),
                  coverRefreshTasks[item.id] == nil else { continue }
            while previewTasks.count >= Self.previewWarmupConcurrency {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, isActive(generation), warmupGeneration == warmup else { return }
            }
            previewTasks[item.id] = Task { @MainActor [weak self] in
                let resolved = await MenuBarQuickWallpaperRepository.shared.resolvePreview(for: item)
                guard let self, !Task.isCancelled, self.isActive(generation),
                      self.warmupGeneration == warmup else { return }
                self.previewTasks[item.id] = nil
                self.updateResolvedPreview(resolved, replacing: item.id)
            }
        }
    }

    func suspendPreviewWork(keepingPresentation: Bool = false) {
        playbackActivity.suspend()
        isPreviewActive = false
        if !keepingPresentation { isPresented = false }
        activationGeneration &+= 1
        warmupGeneration &+= 1
        playbackObservers.removeAll()
        coverObservers.removeAll()
        libraryObservers.removeAll()
        playbackRefreshWorkItem?.cancel()
        playbackRefreshWorkItem = nil
        currentWallpaperIdentityTask?.cancel()
        currentWallpaperIdentityTask = nil
        for task in previewTasks.values { task.cancel() }
        previewTasks.removeAll()
        for task in coverRefreshTasks.values { task.cancel() }
        coverRefreshTasks.removeAll()
    }

    func finishHidingPresentation() { isPresented = false }

    private func reconcileCachedBatch() {
        let repository = MenuBarQuickWallpaperRepository.shared
        let current = repository.currentItem(matching: currentWallpaperLookupURL)
        batchItems = batchItems.compactMap { item in
            if item.isLibraryItem {
                guard let refreshed = repository.item(id: item.id),
                      repository.contains(refreshed, folderIDs: selectedFolderIDs)
                        || refreshed.id == current?.id else { return nil }
                return refreshed
            }
            return current
        }
        if let selected = selectedItem {
            selectedItem = batchItems.first { $0.id == selected.id }
        }
        coverVersions = coverVersions.filter { id, _ in batchItems.contains { $0.id == id } }
    }

    private func updateResolvedPreview(_ resolved: MenuBarQuickWallpaperItem?, replacing id: String) {
        if let resolved {
            batchItems = batchItems.map { $0.id == id ? resolved : $0 }
            if selectedItem?.id == id { selectedItem = resolved }
        } else if MenuBarQuickWallpaperRepository.shared.isTemporarilyUnavailable(id: id) {
            batchItems.removeAll { $0.id == id }
            if selectedItem?.id == id { selectedItem = batchItems.first }
        }
    }

    /// 重建候选批次。
    ///
    /// 「当前壁纸」的落位规则（用户明确要求）：
    /// - 不在当前文件夹筛选内（或库里没有记录）→ 固定作为第一个候选；
    /// - 在筛选内 → 保持它被随机抽到的位置（原样）；若随机没抽中，则随机补进
    ///   批次里（保证它一定在候选项中），不强行置顶。
    /// 无论哪种情况，最终都默认选中它，hero 大图随之显示当前壁纸。
    private func replaceBatch(avoidPreviousBatch: Bool) {
        let repository = MenuBarQuickWallpaperRepository.shared
        let currentItem = repository.currentItem(matching: currentWallpaperLookupURL)
        let currentIsInPool = currentItem.map { repository.contains($0, folderIDs: selectedFolderIDs) } ?? false
        var nextBatch = repository.sample(folderIDs: selectedFolderIDs,
            excluding: avoidPreviousBatch ? lastBatchIDs : [], limit: Self.batchSize)
        let limit = Self.batchSize
        guard !nextBatch.isEmpty || currentItem != nil else {
            batchItems = []
            selectedItem = nil
            errorMessage = nil
            previewWarmupToken = UUID()
            return
        }
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
    /// - Parameter selectCurrent: false 时只更新候选与 external 替身，不抢用户已点选的项。
    private func ensureCurrentWallpaperInBatch(selectCurrent: Bool = true) {
        guard let current = MenuBarQuickWallpaperRepository.shared.currentItem(
            matching: currentWallpaperLookupURL
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
        guard selectCurrent else { return }
        if let selected = selectedItem, !updated.contains(where: { $0.id == selected.id }) {
            // 原选中项被移出批次（external 被库记录替换等），退回当前壁纸选中。
            selectedItem = nil
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

    private func resolvedTargetScreen() -> NSScreen? {
        NSScreen.screens.first {
            $0.wallpaperScreenIdentifier == targetScreenID
                || $0.wallpaperScreenFingerprint == targetScreenFingerprint
        }
    }
}

@MainActor
final class MenuBarQuickWallpaperRepository {
    static let shared = MenuBarQuickWallpaperRepository()
    let changes = PassthroughSubject<Void, Never>()
    private var subscriptions = Set<AnyCancellable>()
    private var indexingTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var index = MenuBarQuickIndex()
    private var payloads: [String: MenuBarQuickWallpaperItem] = [:]
    private var resolved: [String: MenuBarQuickPreviewResult] = [:]
    private var previewVersions: [String: UInt64] = [:]
    private var wallpaperRecords: [WallpaperDownloadRecord] = []
    private var mediaRecords: [MediaDownloadRecord] = []
    private var wallpaperFolders: [LibraryFolder] = []
    private var mediaFolders: [LibraryFolder] = []
    private var context: LibraryThumbnailLookupContext?
    private var started = false
    private var rootPreparationTask: Task<Void, Never>?
    private var activePreviewReads = 0
    private var posterIndexNeedsInvalidation = false
    private(set) var isReady = false
    private(set) var lastAllItemsCacheHit = true
    private(set) var lastBuildDurationMS = 0
    private(set) var lastCurrentLookupMS = 0

    /// Start only after the Helper restored records AND folder definitions.
    /// No file reads, bookmark resolution or service initialization in init.
    func start() {
        guard !started, BackgroundRuntimeRole.isHelper,
              LibraryFolderStore.shared.didRestoreFromDisk else { return }
        started = true
        wallpaperRecords = WallpaperLibraryService.shared.downloadRecords
        mediaRecords = MediaLibraryService.shared.downloadRecords
        wallpaperFolders = LibraryFolderStore.shared.wallpaperFolders
        mediaFolders = LibraryFolderStore.shared.mediaFolders
        context = VideoThumbnailCache.libraryLookupContext()
        rebuildIndex()
        rootPreparationTask = Task { [weak self] in
            await DownloadPathManager.shared.prepareLibraryRootSnapshot()
            guard let self, !Task.isCancelled else { return }
            let prepared = VideoThumbnailCache.libraryLookupContext()
            if self.context != prepared {
                self.context = prepared
                self.resolved.removeAll()
                self.rebuildIndex()
            }
            self.rootPreparationTask = nil
        }
        WallpaperLibraryService.shared.$downloadRecords.dropFirst().sink { [weak self] records in
            self?.wallpaperRecords = records
            self?.rebuildIndex()
        }.store(in: &subscriptions)
        MediaLibraryService.shared.$downloadRecords.dropFirst().sink { [weak self] records in
            self?.mediaRecords = records
            self?.rebuildIndex()
        }.store(in: &subscriptions)
        // Consume the published NEW value. Reading the store in willSet would retain old locks.
        LibraryFolderStore.shared.$wallpaperFolders.dropFirst().sink { [weak self] folders in
            self?.wallpaperFolders = folders
            self?.rebuildIndex()
        }.store(in: &subscriptions)
        LibraryFolderStore.shared.$mediaFolders.dropFirst().sink { [weak self] folders in
            self?.mediaFolders = folders
            self?.rebuildIndex()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .downloadPathChanged)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                self.context = VideoThumbnailCache.libraryLookupContext()
                self.resolved.removeAll()
                self.rebuildIndex()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .sceneOfflineBakeThumbnailDidUpdate)
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
                guard let self, let id = notification.object as? String else { return }
                self.invalidatePreview(itemID: "media.\(id)")
            }.store(in: &subscriptions)
    }

    private func rebuildIndex() {
        generation &+= 1
        isReady = false
        let version = generation
        indexingTask?.cancel()
        let start = ProcessInfo.processInfo.systemUptime
        let oldPayloads = payloads
        var next: [String: MenuBarQuickWallpaperItem] = [:]
        var entries: [MenuBarQuickIndexEntry] = []
        let wpFolders = Dictionary(wallpaperFolders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mdFolders = Dictionary(mediaFolders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func visible(_ folderID: String?, folders: [String: LibraryFolder]) -> Bool {
            var id = folderID
            var visited = Set<String>()
            while let raw = id {
                let current = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !current.isEmpty else { return true }
                guard visited.insert(current).inserted else { return false }
                guard let folder = folders[current] else { return true }
                guard !folder.isLocked else { return false }
                id = folder.parentFolderID
            }
            return true
        }
        for record in wallpaperRecords where record.isActive {
            let id = "wallpaper.\(record.id)"
            let allowed = visible(record.folderID, folders: wpFolders)
            entries.append(.init(id: id, path: record.localFilePath, bakedPath: nil,
                folderKey: record.folderID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", downloadedAt: record.downloadedAt, visible: allowed))
            if allowed {
                next[id] = MenuBarQuickWallpaperItem(id: id, title: record.wallpaper.title ?? record.wallpaper.id,
                    localURL: URL(filePath: record.localFilePath, directoryHint: .inferFromPath), thumbnailURL: nil, videoPreviewURL: nil,
                    downloadedAt: record.downloadedAt, source: .wallpaper(record.wallpaper),
                    sceneBakeItemID: nil, bakedVideoPath: nil, folderID: record.folderID)
            }
        }
        for record in mediaRecords where record.isActive {
            let id = "media.\(record.id)"
            let allowed = visible(record.folderID, folders: mdFolders)
            entries.append(.init(id: id, path: record.localFilePath, bakedPath: record.sceneBakeArtifact?.videoPath,
                folderKey: record.folderID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", downloadedAt: record.downloadedAt, visible: allowed))
            if allowed {
                next[id] = MenuBarQuickWallpaperItem(id: id, title: record.item.title,
                    localURL: URL(filePath: record.localFilePath, directoryHint: .inferFromPath), thumbnailURL: nil, videoPreviewURL: nil,
                    downloadedAt: record.downloadedAt, source: .media(record.item),
                    sceneBakeItemID: record.item.id, bakedVideoPath: record.sceneBakeArtifact?.videoPath,
                    folderID: record.folderID)
            }
        }
        // Privacy/deletions apply immediately, before a background index can complete.
        // Preserve only preview results for identical sources and artifacts.
        payloads = next
        resolved = resolved.filter { id, _ in
            guard let old = oldPayloads[id], let new = next[id] else { return false }
            return old.localURL == new.localURL && old.bakedVideoPath == new.bakedVideoPath
        }
        previewVersions = previewVersions.filter { next[$0.key] != nil }
        changes.send()
        let snapshot = entries
        indexingTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { MenuBarQuickIndex.build(snapshot) }
            let built = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.generation == version else { return }
            self.index = built
            self.isReady = true
            self.lastBuildDurationMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            self.indexingTask = nil
            self.changes.send()
        }
    }

    func item(id: String) -> MenuBarQuickWallpaperItem? {
        guard let item = payloads[id] else { return nil }
        if let preview = resolved[id], preview.exists {
            return item.replacingPreview(thumbnailURL: preview.thumbnailURL,
                videoURL: preview.videoURL, bakedVideoPath: preview.bakedVideoPath)
        }
        if let preview = resolved[id], !preview.exists,
           Date().timeIntervalSince(preview.checkedAt) < 5 { return nil }
        return item
    }

    func sample(folderIDs: [String]?, excluding: Set<String>, limit: Int) -> [MenuBarQuickWallpaperItem] {
        index.sample(folderIDs: folderIDs, excluding: excluding, limit: limit).compactMap {
            guard let candidate = item(id: $0), contains(candidate, folderIDs: folderIDs) else { return nil }
            return candidate
        }
    }

    func contains(_ item: MenuBarQuickWallpaperItem, folderIDs: [String]?) -> Bool {
        guard payloads[item.id] != nil else { return false }
        let folder = item.folderID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return folderIDs.map { $0.isEmpty ? folder.isEmpty : $0.contains(folder) } ?? true
    }

    func currentItem(matching url: URL?) -> MenuBarQuickWallpaperItem? {
        guard let url, url.isFileURL, isReady else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        defer { lastCurrentLookupMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000) }
        if let owner = index.owner(of: url.path) { return item(id: owner) }
        // While a new library revision is indexing, unknown identities fail closed.
        guard indexingTask == nil else { return nil }
        // Derived images can belong to a hidden source; wait for async source identity.
        if url.path.contains("/DerivedWallpapers/PortraitBlurFill/") { return nil }
        let id = "current.\(MenuBarQuickIndex.normalizedPath(url.path))"
        let cached = resolved[id].flatMap { $0.exists ? $0 : nil }
        if let cached = resolved[id], !cached.exists, Date().timeIntervalSince(cached.checkedAt) < 5 { return nil }
        return MenuBarQuickWallpaperItem(id: id, title: url.deletingPathExtension().lastPathComponent,
            localURL: url, thumbnailURL: cached?.thumbnailURL, videoPreviewURL: cached?.videoURL,
            downloadedAt: .distantPast, source: .external, sceneBakeItemID: nil,
            bakedVideoPath: nil, folderID: nil)
    }

    func previewRevision(for id: String) -> Int { Int(truncatingIfNeeded: previewVersions[id, default: 0]) }

    private func invalidatePreview(itemID: String) {
        guard payloads[itemID] != nil else { return }
        previewVersions[itemID, default: 0] &+= 1
        resolved.removeValue(forKey: itemID)
        posterIndexNeedsInvalidation = true
        changes.send()
    }

    /// Only the displayed batch reaches disk. At most two callers are admitted by the ViewModel.
    func resolvePreview(for item: MenuBarQuickWallpaperItem) async -> MenuBarQuickWallpaperItem? {
        // A cancelled slow read still owns its slot until it actually returns.
        // Reopening cannot accumulate another batch of blocked filesystem calls.
        while activePreviewReads >= 2 {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard !Task.isCancelled, let context else { return nil }
        activePreviewReads += 1
        defer { activePreviewReads -= 1 }
        let version = generation
        let previewVersion = previewVersions[item.id, default: 0]
        let source = MenuBarQuickPreviewRequest(id: item.id, localURL: item.localURL,
            itemID: item.sceneBakeItemID, bakedPath: payloads[item.id]?.bakedVideoPath,
            context: context)
        let invalidatePosterIndex = posterIndexNeedsInvalidation
        posterIndexNeedsInvalidation = false
        var result = await MenuBarQuickPreviewReader.shared.read(source, invalidatePosterIndex: invalidatePosterIndex)
        if result.exists, result.thumbnailURL == nil, let video = result.videoURL, !Task.isCancelled {
            result.thumbnailURL = await VideoThumbnailCache.menuListThumbnail(for: video, cacheDirectory: context.videoCache)
        }
        if let url = result.thumbnailURL, previewVersion > 0, !Task.isCancelled {
            let processor = DownsamplingImageProcessor(size: CGSize(width: 768, height: 768))
            try? await ImageCache.default.removeImage(forKey: url.cacheKey, processorIdentifier: processor.identifier)
        }
        guard !Task.isCancelled, generation == version,
              previewVersions[item.id, default: 0] == previewVersion,
              self.context == context,
              !item.isLibraryItem || payloads[item.id]?.localURL == item.localURL else { return nil }
        if resolved.count >= 96 { resolved.removeAll(keepingCapacity: true) }
        resolved[item.id] = result
        guard result.exists else { return nil }
        return item.replacingPreview(thumbnailURL: result.thumbnailURL,
            videoURL: result.videoURL, bakedVideoPath: result.bakedVideoPath)
    }

    func isTemporarilyUnavailable(id: String) -> Bool {
        guard let preview = resolved[id], !preview.exists else { return false }
        return Date().timeIntervalSince(preview.checkedAt) < 5
    }

    func cachedPreviewIsFresh(for id: String) -> Bool {
        guard let preview = resolved[id] else { return false }
        return Date().timeIntervalSince(preview.checkedAt) < (preview.exists ? 30 : 5)
    }
}

private struct MenuBarQuickPreviewRequest: Sendable {
    let id: String
    let localURL: URL
    let itemID: String?
    let bakedPath: String?
    let context: LibraryThumbnailLookupContext
}

private struct MenuBarQuickPreviewResult: Sendable {
    let exists: Bool
    var thumbnailURL: URL?
    var videoURL: URL?
    var bakedVideoPath: String?
    let checkedAt = Date()
}

/// No MainActor singletons. Performs source checks and existing-cache reads only;
/// missing frame generation is separately bounded by the visible preview queue.
private actor MenuBarQuickPreviewReader {
    static let shared = MenuBarQuickPreviewReader()
    private struct Poster { let url: URL; let date: Date }
    private var posterContext: LibraryThumbnailLookupContext?
    private var posterIndex: [String: [Poster]] = [:]
    private var posterIndexAt = Date.distantPast

    func read(_ request: MenuBarQuickPreviewRequest, invalidatePosterIndex: Bool) -> MenuBarQuickPreviewResult {
        if invalidatePosterIndex { posterIndexAt = .distantPast }
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard !Task.isCancelled, fm.fileExists(atPath: request.localURL.path, isDirectory: &directory) else {
            return MenuBarQuickPreviewResult(exists: false)
        }
        var result = MenuBarQuickPreviewResult(exists: true)
        let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]
        func usableImage(_ url: URL) -> URL? {
            guard !Task.isCancelled else { return nil }
            return LibraryThumbnailDiskReader.isUsableImage(at: url) ? url : nil
        }
        func namedImage(_ name: String) -> URL? {
            for folder in [request.context.covers, request.context.videoCache] {
                if let found = usableImage(folder.appendingPathComponent(name)) { return found }
            }
            return nil
        }
        if let path = request.bakedPath, !Task.isCancelled,
           SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: path)) {
            result.bakedVideoPath = path
            result.videoURL = URL(fileURLWithPath: path)
        }
        if result.videoURL == nil {
            if !directory.boolValue, videoExtensions.contains(request.localURL.pathExtension.lowercased()) {
                result.videoURL = request.localURL
            } else if directory.boolValue, !Task.isCancelled {
                let type = MediaItem.localWorkshopProjectType(from: request.localURL)
                if type == nil || type == "video" {
                    result.videoURL = MediaItem.resolveLocalVideoFile(from: request.localURL)
                }
            }
        }
        // Preserve menu priority: bake poster, video list frame, realtime poster, Workshop preview.
        if let id = request.itemID { result.thumbnailURL = namedImage("scene_bake_\(id.md5).jpg") }
        if result.thumbnailURL == nil, let video = result.videoURL {
            let path = video.standardizedFileURL.path
            result.thumbnailURL = usableImage(request.context.videoCache.appendingPathComponent("list_\(path.md5).jpg"))
            if result.thumbnailURL == nil {
                let prefix = request.context.root.standardizedFileURL.path + "/"
                let key = path.hasPrefix(prefix) ? "lib:" + String(path.dropFirst(prefix.count)) : path
                result.thumbnailURL = usableImage(request.context.covers.appendingPathComponent("poster_wallpaper_\(key.md5).jpg"))
                    ?? usableImage(request.context.videoCache.appendingPathComponent("poster_wallpaper_\(path.md5).jpg"))
            }
        }
        if result.thumbnailURL == nil, let id = request.itemID, !Task.isCancelled {
            result.thumbnailURL = realtimePoster(itemID: id, context: request.context)
        }
        if result.thumbnailURL == nil, !Task.isCancelled {
            if !directory.boolValue, LocalImageThumbnailCache.isRasterImageFile(request.localURL)
                || LocalImageThumbnailCache.isGIFFile(request.localURL) {
                result.thumbnailURL = request.localURL
            } else if directory.boolValue {
                result.thumbnailURL = MediaItem.resolveLocalWorkshopPreviewImage(from: request.localURL)
            }
        }
        return result
    }

    private func realtimePoster(itemID: String, context: LibraryThumbnailLookupContext) -> URL? {
        if posterContext != context || Date().timeIntervalSince(posterIndexAt) >= 10 {
            var next: [String: [Poster]] = [:]
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
            for folder in [context.covers, context.videoCache] {
                guard let files = FileManager.default.enumerator(at: folder,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }
                for case let file as URL in files {
                    guard !Task.isCancelled else { return nil }
                    let name = file.lastPathComponent
                    guard name.hasPrefix("scene_realtime_"), file.pathExtension == "jpg" else { continue }
                    let body = name.dropFirst("scene_realtime_".count)
                    guard let separator = body.firstIndex(of: "_") else { continue }
                    let values = try? file.resourceValues(forKeys: keys)
                    guard values?.isRegularFile != false else { continue }
                    next[String(body[..<separator]), default: []].append(
                        Poster(url: file, date: values?.contentModificationDate ?? .distantPast))
                }
            }
            posterIndex = next
            posterContext = context
            posterIndexAt = Date()
        }
        return posterIndex[itemID.md5, default: []].sorted { $0.date > $1.date }
            .first { !Task.isCancelled && LibraryThumbnailDiskReader.isUsableImage(at: $0.url) }?.url
    }
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
