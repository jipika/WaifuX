import AppKit
import Combine

// MARK: - 菜单栏音量滑块自定义视图
private final class WallpaperVolumeSliderView: NSView {
    private let iconView = NSImageView()
    private let slider = NSSlider()
    private var cancellables = Set<AnyCancellable>()

    var onVolumeChanged: ((Double) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // 图标
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // 滑块
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            slider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = Double(sender.doubleValue) / 100.0
        onVolumeChanged?(value)
        updateIcon(volume: value)
    }

    func setVolume(_ volume: Double, isMuted: Bool) {
        let effectiveVolume = isMuted ? 0 : volume
        slider.doubleValue = effectiveVolume * 100
        updateIcon(volume: effectiveVolume)
    }

    private func updateIcon(volume: Double) {
        let name: String
        if volume == 0 {
            name = "speaker.slash.fill"
        } else if volume < 0.35 {
            name = "speaker.wave.1.fill"
        } else if volume < 0.7 {
            name = "speaker.wave.2.fill"
        } else {
            name = "speaker.wave.3.fill"
        }
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

// MARK: - 菜单栏播放速度滑块
private final class WallpaperPlaybackRateSliderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "1x")
    private let slider = NSSlider()

    var onRateChanged: ((Double) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        titleLabel.stringValue = t("statusbar.playbackSpeed")
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = VideoWallpaperManager.minPlaybackRate
        slider.maxValue = VideoWallpaperManager.maxPlaybackRate
        slider.numberOfTickMarks = 7
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor,
                constant: 8
            ),
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            slider.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let rate = sender.doubleValue
        valueLabel.stringValue = Self.format(rate)
        onRateChanged?(rate)
    }

    func setRate(_ rate: Double) {
        let clamped = min(
            VideoWallpaperManager.maxPlaybackRate,
            max(VideoWallpaperManager.minPlaybackRate, rate)
        )
        slider.doubleValue = clamped
        valueLabel.stringValue = Self.format(clamped)
    }

    private static func format(_ rate: Double) -> String {
        if abs(rate - rate.rounded()) < 0.05 {
            return String(format: "%.0fx", rate.rounded())
        }
        return String(format: "%.2gx", rate)
    }
}

// MARK: - 单屏幕音量控制（名称 + 滑块）
private final class ScreenVolumeControlView: NSView {
    private let nameLabel = NSTextField()
    private let sliderView = WallpaperVolumeSliderView()

    var onVolumeChanged: ((Double) -> Void)? {
        didSet { sliderView.onVolumeChanged = onVolumeChanged }
    }

    init(screenName: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        setupUI(screenName: screenName)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI(screenName: String) {
        nameLabel.stringValue = screenName
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.backgroundColor = .clear
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        sliderView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nameLabel)
        addSubview(sliderView)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            sliderView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            sliderView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            sliderView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            sliderView.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    func setVolume(_ volume: Double, isMuted: Bool) {
        sliderView.setVolume(volume, isMuted: isMuted)
    }
}

private final class TaskQueueRowView: NSView {
    static let menuWidth: CGFloat = 300
    private let titleLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    /// 进度条文字直接贴行尾（无取消按钮时的布局）
    private var progressTrailingToRowConstraint: NSLayoutConstraint?
    /// 进度条文字贴取消按钮左侧（有取消按钮时的布局）
    private var progressTrailingToButtonConstraint: NSLayoutConstraint?
    var onCancel: (() -> Void)?

    init(
        title: String,
        progress: Double,
        isSectionHeader: Bool = false,
        showsCancelButton: Bool = false,
        onCancel: (() -> Void)? = nil
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: 24))
        self.onCancel = onCancel
        titleLabel.font = NSFont.systemFont(ofSize: isSectionHeader ? 13 : 12, weight: isSectionHeader ? .semibold : .regular)
        titleLabel.textColor = isSectionHeader ? .secondaryLabelColor : .disabledControlTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .disabledControlTextColor
        progressLabel.alignment = .right
        progressLabel.translatesAutoresizingMaskIntoConstraints = false

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "取消下载")?
            .withSymbolConfiguration(symbolConfig)
        cancelButton.isBordered = false
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.toolTip = "取消下载"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(progressLabel)
        addSubview(cancelButton)
        progressTrailingToRowConstraint = progressLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        progressTrailingToButtonConstraint = progressLabel.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -6)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressLabel.leadingAnchor, constant: -8),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 18),
            progressLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressTrailingToRowConstraint!
        ])
        setShowsCancelButton(showsCancelButton)
        update(title: title, progress: progress, isSectionHeader: isSectionHeader)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setShowsCancelButton(_ shows: Bool) {
        cancelButton.isHidden = !shows
        if shows {
            progressTrailingToRowConstraint?.isActive = false
            progressTrailingToButtonConstraint?.isActive = true
        } else {
            progressTrailingToButtonConstraint?.isActive = false
            progressTrailingToRowConstraint?.isActive = true
        }
    }

    @objc private func cancelClicked() {
        onCancel?()
    }

    func update(title: String, progress: Double, isSectionHeader: Bool = false) {
        titleLabel.stringValue = title
        progressLabel.stringValue = isSectionHeader ? "" : "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}

@MainActor
final class StatusBarController: NSObject {
    private enum WallpaperDesignTarget {
        case web(String)
        case scene(String)
        case sceneDesign(String)

        var wallpaperPath: String {
            switch self {
            case .web(let path), .scene(let path), .sceneDesign(let path):
                return path
            }
        }
    }

    // MARK: - 单例
    static let shared = StatusBarController()

    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private lazy var quickSwitcherController = MenuBarQuickSwitcherController()

    private lazy var openWindowItem = NSMenuItem(title: t("statusbar.showWindow"), action: #selector(showMainWindow), keyEquivalent: "")
    private lazy var openLibraryItem = NSMenuItem(title: t("statusbar.openMyLibrary"), action: #selector(openMyLibrary), keyEquivalent: "")
    private lazy var openSettingsItem = NSMenuItem(title: t("settings"), action: #selector(openAppSettingsPanel), keyEquivalent: "")
    private lazy var releaseMemoryItem = NSMenuItem(title: t("statusbar.releaseMemory"), action: #selector(releaseForegroundMemory), keyEquivalent: "")
    private lazy var muteItem = NSMenuItem(title: t("statusbar.muteWallpaper"), action: #selector(toggleMute), keyEquivalent: "")
    private lazy var desktopIconsItem = NSMenuItem(title: t("statusbar.hideDesktopIcons"), action: #selector(toggleDesktopIcons), keyEquivalent: "")
    private lazy var designWallpaperItem = NSMenuItem(title: t("design.designWallpaper"), action: #selector(openWebWallpaperDesignPanel), keyEquivalent: "")
    private lazy var sceneConfigItem = NSMenuItem(title: t("statusbar.sceneAdvancedSettings"), action: #selector(openSceneConfigPanel), keyEquivalent: "")
    private lazy var checkUpdateItem = NSMenuItem(title: t("checkForUpdates"), action: #selector(checkForUpdates), keyEquivalent: "")
    private lazy var quitItem = NSMenuItem(title: t("statusbar.quit"), action: #selector(quitApplication), keyEquivalent: "q")

    private let videoWallpaperManager = VideoWallpaperManager.shared
    private let weBridge = WallpaperEngineXBridge.shared
    private var showWindowHandler: (() -> Void)?
    private var releaseMemoryHandler: (() -> Void)?
    private var quitHandler: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()

    // 各屏幕独立音量条
    private var screenVolumeItems: [NSMenuItem] = []
    // 各屏幕独立暂停/关闭菜单项
    private var wallpaperControlItems: [NSMenuItem] = []

    // MARK: - 统一任务队列状态栏显示（仅有进行中任务时出现，完成后隐藏，不常驻）
    private var originalButtonImage: NSImage?
    private lazy var taskQueueItem = NSMenuItem(title: t("statusbar.taskQueue"), action: nil, keyEquivalent: "")
    private lazy var taskQueueMenu = NSMenu(title: t("statusbar.taskQueue"))
    private lazy var cancelAllDownloadsItem = NSMenuItem(
        title: t("statusbar.taskQueue.cancelAllDownloads"),
        action: #selector(cancelAllDownloadQueueTasks),
        keyEquivalent: ""
    )
    /// 紧跟任务队列项的分隔线；队列隐藏时一并移除。
    private lazy var taskQueueSeparatorItem = NSMenuItem.separator()
    private var taskQueueRowsByID: [String: TaskQueueRowView] = [:]
    private var taskQueueStructure: [String] = []
    private var isTaskQueueMenuVisible = false

    // 标记是否已配置，防止重复配置
    private var isConfigured = false

    var backgroundSnapshot: [String: Any] {
        ["configured": isConfigured, "visible": isConfigured && statusItem.isVisible,
         "hasButton": isConfigured && statusItem.button != nil]
    }

    private override init() {
        super.init()
        guard BackgroundRuntimeRole.isHelper else { return }
        configureStatusItem()
        bindWallpaperState()
        bindTaskQueueState()
        bindLocalizationState()
        refreshMenuState()
    }

    /// 配置处理程序（只能调用一次）
    func configure(
        showWindow: @escaping () -> Void,
        releaseMemory: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        guard !isConfigured else {
            print("[StatusBarController] Already configured, skipping...")
            return
        }
        self.showWindowHandler = showWindow
        self.releaseMemoryHandler = releaseMemory
        self.quitHandler = quit
        self.isConfigured = true
        AppLogger.info(.startup, "Helper menu bar configured", metadata: backgroundSnapshot)
    }

    private func configureStatusItem() {
        // 确保状态栏项的按钮存在
        guard let button = statusItem.button else {
            print("[StatusBarController] Failed to get status item button")
            return
        }

        // 尝试使用系统图标，如果不存在则使用备用图标
        let systemImageNames = ["sparkles.tv", "photo.fill", "tv.fill", "desktopcomputer"]
        var image: NSImage?

        for name in systemImageNames {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "WaifuX") {
                image = img
                break
            }
        }

        if let image = image {
            image.isTemplate = true
            // 在 macOS 14 上需要设置合适的图标大小
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        } else {
            // 最后的备选方案：使用文字
            button.title = "WH"
            button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        }

        button.toolTip = "WaifuX"
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        openWindowItem.target = self
        openLibraryItem.target = self
        openSettingsItem.target = self
        releaseMemoryItem.target = self
        muteItem.target = self
        desktopIconsItem.target = self
        designWallpaperItem.target = self
        sceneConfigItem.target = self
        checkUpdateItem.target = self
        quitItem.target = self
        cancelAllDownloadsItem.target = self

        menu.addItem(openWindowItem)
        menu.addItem(openLibraryItem)
        menu.addItem(releaseMemoryItem)
        menu.addItem(openSettingsItem)
        // 任务队列不在初始化时常驻；有进行中任务时再动态插入。
        taskQueueItem.submenu = taskQueueMenu
        menu.addItem(desktopIconsItem)
        menu.addItem(designWallpaperItem)
        menu.addItem(sceneConfigItem)
        menu.addItem(muteItem)
        menu.addItem(.separator())
        menu.addItem(checkUpdateItem)
        menu.addItem(quitItem)

        // Keep the contextual controls on the right click only. The left click opens
        // the local-library quick switcher, so assigning `statusItem.menu` here would
        // make AppKit consume both clicks before the button action can route them.
        statusItem.menu = nil
        menu.delegate = self
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        let clickActionsSwapped = WaifuXPreferences.shared.bool(forKey: "menu_bar_swap_click_actions")
        let showQuickSwitcher = (event.type == .leftMouseUp) != clickActionsSwapped

        if showQuickSwitcher {
            let targetScreen = sender.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
            // 打开前的参数准备（按屏查当前壁纸 / 解析设计目标）也可能是慢点，
            // 单独打点才能区分「点击到弹窗出现」到底耗在哪一段。
            let urlStart = Date()
            let currentURL = targetScreen.flatMap { currentWallpaperURL(for: $0) }
            let urlDone = Date()
            let designTarget = resolvedWallpaperDesignTarget()
            let designDone = Date()
            AppLogger.debug(.general, "状态栏左键参数准备耗时", metadata: [
                "urlMS": String(Int(urlDone.timeIntervalSince(urlStart) * 1000)),
                "designMS": String(Int(designDone.timeIntervalSince(urlDone) * 1000)),
                "hasURL": currentURL == nil ? "0" : "1",
                "design": designTarget == nil ? "0" : "1",
            ])
            quickSwitcherController.toggle(
                relativeTo: sender,
                targetScreen: targetScreen,
                currentWallpaperURL: currentURL,
                canDesignCurrentWallpaper: designTarget != nil,
                onOpenSettings: { [weak self] in
                    self?.openAppSettingsPanel()
                },
                onOpenDesignWallpaper: { [weak self] in
                    self?.openWebWallpaperDesignPanel()
                },
                onOpenDetail: { request in
                    MainNavigationRequestStore.requestWallpaperDetail(request)
                    WaifuXUIActions.perform(.wallpaperDetail)
                },
                onQuit: { [weak self] in
                    // 与右键菜单退出同链路：quitHandler → WaifuXApp.quitApplication()
                    // （applicationWillTerminate 清理 + 退出诊断都依赖这条路径）。
                    self?.quitApplication()
                }
            )
        } else if event.type == .leftMouseUp || event.type == .rightMouseUp {
            // 右键弹菜单前的准备耗时：`refreshMenuState()` 会逐屏查锁屏暂停态/静音/
            // 当前壁纸，并解析当前壁纸工程的 project.json。`popUpMenu` 本身是阻塞的
            // （要到菜单关闭才返回），所以打点必须放在它之前，否则量到的是「菜单
            // 存活时长」而不是准备耗时。
            let menuPrepareStart = Date()
            quickSwitcherController.dismiss()
            refreshMenuState()
            AppLogger.debug(.general, "状态栏右键菜单准备耗时", metadata: [
                "refreshMS": Int(Date().timeIntervalSince(menuPrepareStart) * 1000),
            ])
            statusItem.popUpMenu(menu)
        }
    }

    private func bindLocalizationState() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLanguageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
    }

    @objc private func handleLanguageDidChange() {
        taskQueueStructure.removeAll()
        updateTaskQueue(TaskQueueStatusService.shared.entries)
        refreshMenuState()
    }

    private func bindWallpaperState() {
        videoWallpaperManager.$currentVideoURL
            .combineLatest(videoWallpaperManager.$isPaused, videoWallpaperManager.$isMuted, videoWallpaperManager.$volume)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshMenuState()
            }
            .store(in: &cancellables)

        weBridge.$isControllingExternalEngine
            .combineLatest(weBridge.$isExternalPaused)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshMenuState()
            }
            .store(in: &cancellables)

        // 设计目标缓存的失效订阅：只挂 `computeWallpaperDesignTarget()` 真正依赖的输入
        // （WE 是否在控 / 当前渲染类型 / 当前视频），不去蹭上面两条为菜单刷新而生的链
        // —— 音量、静音、暂停都不影响设计目标，蹭进来会让缓存白做。
        // `renderStateChangeCount` 承载 `isCurrentWallpaperWeb` / `isCurrentWallpaperScene`
        // 的变化，而 WE 停止后 `currentWallpaperPathForDesign` 仍会残留旧路径，
        // 光靠 key 区分不出「刚停」和「没变」。
        weBridge.$isControllingExternalEngine
            .combineLatest(weBridge.$renderStateChangeCount, videoWallpaperManager.$currentVideoURL)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.invalidateDesignTargetCache()
            }
            .store(in: &cancellables)

        WallpaperSchedulerService.shared.$config
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMenuState()
            }
            .store(in: &cancellables)
    }

    // MARK: - Unified task queue status

    private func bindTaskQueueState() {
        originalButtonImage = statusItem.button?.image
        TaskQueueStatusService.shared.$entries
            .throttle(for: .milliseconds(180), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                self?.updateTaskQueue(entries)
            }
            .store(in: &cancellables)
    }

    private func updateTaskQueue(_ entries: [TaskQueueStatusService.Entry]) {
        setTaskQueueMenuVisible(!entries.isEmpty)
        updateTaskQueueButton(entries)

        guard !entries.isEmpty else {
            taskQueueStructure = []
            taskQueueMenu.removeAllItems()
            taskQueueRowsByID.removeAll()
            return
        }

        let structure = entries.map { "\($0.category.localizationKey):\($0.id)" }
        if structure != taskQueueStructure {
            taskQueueStructure = structure
            rebuildTaskQueueMenu(entries)
        } else {
            for entry in entries {
                taskQueueRowsByID[entry.id]?.update(title: entry.title, progress: entry.progress)
            }
        }
    }

    /// 任务队列只在有进行中任务时挂到菜单；全部完成后从菜单移除，避免空队列常驻。
    private func setTaskQueueMenuVisible(_ visible: Bool) {
        guard visible != isTaskQueueMenuVisible else { return }
        isTaskQueueMenuVisible = visible

        if visible {
            guard taskQueueItem.menu == nil else { return }
            let insertIndex: Int
            if let settingsIndex = menu.items.firstIndex(of: openSettingsItem) {
                insertIndex = settingsIndex + 1
            } else {
                insertIndex = min(menu.numberOfItems, 4)
            }
            menu.insertItem(taskQueueItem, at: insertIndex)
            menu.insertItem(taskQueueSeparatorItem, at: insertIndex + 1)
            return
        }

        if taskQueueItem.menu != nil {
            menu.removeItem(taskQueueItem)
        }
        if taskQueueSeparatorItem.menu != nil {
            menu.removeItem(taskQueueSeparatorItem)
        }
    }

    private func updateTaskQueueButton(_ entries: [TaskQueueStatusService.Entry]) {
        guard let button = statusItem.button else { return }
        guard !entries.isEmpty else {
            button.image = originalButtonImage
            button.title = ""
            button.toolTip = "WaifuX"
            return
        }
        let progress = entries.reduce(0) { $0 + $1.progress } / Double(entries.count)
        button.image = nil
        button.title = "\(Int((progress * 100).rounded()))% · \(entries.count)"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.toolTip = "WaifuX — \(entries.count)"
    }

    private func rebuildTaskQueueMenu(_ entries: [TaskQueueStatusService.Entry]) {
        taskQueueMenu.removeAllItems()
        taskQueueRowsByID.removeAll()

        if entries.contains(where: { $0.category == .download }) {
            taskQueueMenu.addItem(cancelAllDownloadsItem)
            taskQueueMenu.addItem(.separator())
        }

        // 只展示当前有任务的分类；空分类不占菜单，避免“全是空”的常驻观感。
        let activeCategories = TaskQueueStatusService.Category.allCases.filter { category in
            entries.contains { $0.category == category }
        }
        for (index, category) in activeCategories.enumerated() {
            let section = NSMenuItem()
            section.view = TaskQueueRowView(title: t(category.localizationKey), progress: 0, isSectionHeader: true)
            section.isEnabled = false
            taskQueueMenu.addItem(section)
            for entry in entries where entry.category == category {
                // 仅下载类任务可取消（普通 URL 下载与 Workshop 下载同走
                // DownloadTaskService.cancelTask，由下载队列终止任务）
                let isDownload = entry.category == .download
                let row = TaskQueueRowView(
                    title: entry.title,
                    progress: entry.progress,
                    showsCancelButton: isDownload,
                    onCancel: isDownload ? { [weak self] in
                        self?.cancelDownloadQueueTask(id: entry.id)
                    } : nil
                )
                let item = NSMenuItem()
                item.view = row
                item.isEnabled = false
                taskQueueMenu.addItem(item)
                taskQueueRowsByID[entry.id] = row
            }
            if index < activeCategories.count - 1 {
                taskQueueMenu.addItem(.separator())
            }
        }
    }

    /// 取消一条下载任务。排队中 / 下载中 / 等待 Steam 登录的任务均可取消；
    /// Workshop 下载会经 PersistentDownloadQueueService 取消内嵌 Steam 服务的下载。
    private func cancelDownloadQueueTask(id: String) {
        DownloadTaskService.shared.cancelTask(id: id)
    }

    @objc private func cancelAllDownloadQueueTasks() {
        DownloadTaskService.shared.cancelAllActiveDownloads()
    }

    /// 为指定屏幕构建音量滑块菜单项
    private func buildVolumeMenuItem(for screen: NSScreen) -> NSMenuItem {
        let controlView = ScreenVolumeControlView(screenName: screen.localizedName)
        controlView.onVolumeChanged = { [weak self] volume in
            guard let self = self else { return }
            // 只设该屏幕的音量，不触及其他屏幕，也不动全局静音
            self.videoWallpaperManager.setVolume(volume, for: screen)
            if self.weBridge.isControllingExternalEngine {
                self.weBridge.setVolume(volume, for: screen)
            }
        }
        let item = NSMenuItem()
        item.view = controlView
        let vol = videoWallpaperManager.volume(for: screen)
        // 显示实际音量，不受全局 isMuted 影响
        controlView.setVolume(vol, isMuted: false)
        return item
    }

    /// 全局同步模式下的统一音量滑块（写入全局音量，覆盖各屏独立音量）
    private func buildGlobalVolumeMenuItem() -> NSMenuItem {
        // 父菜单标题已是「全部显示器」，这里不再重复显示屏名
        let controlView = ScreenVolumeControlView(screenName: "")
        controlView.onVolumeChanged = { [weak self] volume in
            guard let self = self else { return }
            self.videoWallpaperManager.setVolume(volume)
            if self.weBridge.isControllingExternalEngine {
                self.weBridge.setVolume(volume)
            }
        }
        let item = NSMenuItem()
        item.view = controlView
        controlView.setVolume(videoWallpaperManager.volume, isMuted: false)
        return item
    }

    private func buildPlaybackRateMenuItem(for screen: NSScreen) -> NSMenuItem? {
        guard videoWallpaperManager.assignedVideoURL(for: screen) != nil else {
            return nil
        }
        let controlView = WallpaperPlaybackRateSliderView()
        controlView.setRate(videoWallpaperManager.playbackRate(for: screen))
        controlView.onRateChanged = { [weak self] rate in
            self?.videoWallpaperManager.setPlaybackRate(rate, for: screen)
        }
        let item = NSMenuItem()
        item.view = controlView
        return item
    }

    private func refreshMenuState() {
        refreshLocalizedTitles()

        let hasNativeWallpaper = videoWallpaperManager.isVideoWallpaperActive
        let hasExternalWallpaper = weBridge.isControllingExternalEngine
        let hasWallpaper = hasNativeWallpaper || hasExternalWallpaper
        let designTarget = resolvedWallpaperDesignTarget()
        designWallpaperItem.representedObject = designTarget?.wallpaperPath
        designWallpaperItem.isHidden = designTarget == nil
        designWallpaperItem.isEnabled = designTarget != nil

        // 场景高级设置（仅在实时渲染场景壁纸时显示）
        let shouldShowSceneConfig = weBridge.isCurrentWallpaperScene
            && WaifuXPreferences.shared.bool(forKey: "scene_realtime_rendering_enabled")
        sceneConfigItem.isHidden = !shouldShowSceneConfig
        sceneConfigItem.isEnabled = shouldShowSceneConfig
        if shouldShowSceneConfig, let path = weBridge.currentWallpaperPathForDesign {
            sceneConfigItem.representedObject = path
        } else {
            sceneConfigItem.representedObject = nil
        }

        // 移除旧的动态菜单项
        for item in wallpaperControlItems {
            if item.menu != nil {
                menu.removeItem(item)
            }
        }
        wallpaperControlItems.removeAll()

        // macOS 26+：扩展控制模式下，动态壁纸由扩展偏好控制。
        let isExtensionMode: Bool
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            isExtensionMode = true
        } else {
            isExtensionMode = false
        }

        let isGlobalDisplaySyncEnabled = WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled
        // 状态栏始终列出当前连接的所有显示器，不再以“当前是否播放动态壁纸”作为可见条件。
        // 全局同步开启时合并为单一入口，避免同一份全局配置重复出现。
        let displayScreens: [NSScreen]
        if isGlobalDisplaySyncEnabled {
            // 全局同步入口用主屏（稳定序第 0 项），避免系统枚举顺序跳动
            displayScreens = NSScreen.screensOrderedForDisplay.first.map { [$0] } ?? []
        } else {
            displayScreens = NSScreen.screensOrderedForDisplay
        }

        // 每屏一个顶层子菜单（多屏直接平铺，无外层「显示器」包裹）
        let hasWallpaperOnAnyScreen = hasWallpaper || hasNativeWallpaper || hasExternalWallpaper

        for screen in displayScreens {
            let screenName = isGlobalDisplaySyncEnabled
                ? t("statusbar.globalDisplaySettings")
                : screen.localizedName

            // 该屏是否有壁纸（决定控件是否启用）
            let screenHasWallpaper: Bool
            if isGlobalDisplaySyncEnabled {
                screenHasWallpaper = hasWallpaperOnAnyScreen
                    || NSScreen.screens.contains {
                        videoWallpaperManager.hasActiveWallpaper(on: $0) || weBridge.isManaging(screen: $0)
                    }
            } else if isExtensionMode {
                screenHasWallpaper = hasWallpaperOnAnyScreen
            } else if weBridge.isManaging(screen: screen) {
                screenHasWallpaper = true
            } else {
                screenHasWallpaper = videoWallpaperManager.hasActiveWallpaper(on: screen)
            }

            // 暂停状态
            let isScreenPaused: Bool
            if isGlobalDisplaySyncEnabled {
                if weBridge.isControllingExternalEngine {
                    isScreenPaused = weBridge.isExternalPaused
                } else {
                    isScreenPaused = videoWallpaperManager.isPaused
                }
            } else if isExtensionMode, #available(macOS 26.0, *),
               let displayID = Self.cgDisplayID(for: screen) {
                isScreenPaused = LockScreenWallpaperService.shared.isDisplayPaused(displayID)
            } else if weBridge.isManaging(screen: screen) {
                isScreenPaused = weBridge.isExternalPaused
            } else {
                isScreenPaused = videoWallpaperManager.isPaused(on: screen)
            }

            let screenMenuItem = NSMenuItem(title: screenName, action: nil, keyEquivalent: "")
            let screenSubMenu = NSMenu(title: screenName)
            screenMenuItem.submenu = screenSubMenu
            let schedulerConfig = isGlobalDisplaySyncEnabled
                ? WallpaperSchedulerService.shared.globalDisplayConfig
                : WallpaperSchedulerService.shared.resolvedDisplayConfig(for: screen)
            let screenHasManagedWallpaper: Bool
            if isGlobalDisplaySyncEnabled {
                screenHasManagedWallpaper = screenHasWallpaper
                    || NSScreen.screens.contains {
                        StaticImageWallpaperOverlayManager.shared.imageURL(for: $0) != nil
                            || DesktopWallpaperSyncManager.shared.imageURL(for: $0) != nil
                    }
            } else {
                screenHasManagedWallpaper = screenHasWallpaper
                    || StaticImageWallpaperOverlayManager.shared.imageURL(for: screen) != nil
                    || DesktopWallpaperSyncManager.shared.imageURL(for: screen) != nil
            }

            // 暂停/关闭/开启只针对「活跃动态壁纸运行时」判定。
            // screenHasManagedWallpaper 含 DesktopWallpaperSyncManager 的系统桌面 poster
            // 登记（视频壁纸设置时写入、App 运行期间不清），会把已关闭的屏误判为有壁纸。
            let screenHasStaticOverlay: Bool
            let screenHasLiveDynamicWallpaper: Bool
            if isGlobalDisplaySyncEnabled {
                screenHasStaticOverlay = NSScreen.screens.contains {
                    StaticImageWallpaperOverlayManager.shared.imageURL(for: $0) != nil
                        || LockScreenWallpaperService.shared.staticImageSourceURL(for: $0) != nil
                }
                screenHasLiveDynamicWallpaper = NSScreen.screens.contains { screen in
                    videoWallpaperManager.hasActiveWallpaper(on: screen)
                        || weBridge.hasLivePresentation(on: screen)
                }
            } else {
                // 扩展本地解码静态图时不建 overlay（交给扩展原生渲染），
                // 用扩展的静态图源登记补足「该屏有静态壁纸」信号。
                screenHasStaticOverlay = StaticImageWallpaperOverlayManager.shared.imageURL(for: screen) != nil
                    || LockScreenWallpaperService.shared.staticImageSourceURL(for: screen) != nil
                screenHasLiveDynamicWallpaper = videoWallpaperManager.hasActiveWallpaper(on: screen)
                    || weBridge.hasLivePresentation(on: screen)
            }

            // 自动切换开关
            let autoSwitchItem = NSMenuItem(
                title: schedulerConfig.isEnabled ? t("statusbar.disableAutoSwitch") : t("statusbar.enableAutoSwitch"),
                action: #selector(togglePerScreenAutoSwitch(_:)),
                keyEquivalent: "")
            autoSwitchItem.target = self
            autoSwitchItem.representedObject = screen
            screenSubMenu.addItem(autoSwitchItem)

            // 切换下一张壁纸
            let nextWallpaperItem = NSMenuItem(
                title: t("statusbar.nextWallpaper"),
                action: #selector(nextWallpaperForScreen(_:)),
                keyEquivalent: "")
            nextWallpaperItem.target = self
            nextWallpaperItem.representedObject = screen
            nextWallpaperItem.isEnabled = WallpaperSchedulerService.shared.hasSchedulableItems(for: screen.wallpaperScreenIdentifier)
            screenSubMenu.addItem(nextWallpaperItem)

            // 打开该屏幕当前正在显示的壁纸详情。
            let openCurrentWallpaperItem = NSMenuItem(
                title: t("statusbar.openCurrentWallpaper"),
                action: #selector(openCurrentWallpaper(_:)),
                keyEquivalent: "")
            openCurrentWallpaperItem.target = self
            openCurrentWallpaperItem.representedObject = screen
            openCurrentWallpaperItem.isEnabled = screenHasManagedWallpaper
                && currentWallpaperDetailRequest(for: screen) != nil
            screenSubMenu.addItem(openCurrentWallpaperItem)

            screenSubMenu.addItem(.separator())

            if screenHasLiveDynamicWallpaper {
                let pauseItem = NSMenuItem(
                    title: isScreenPaused ? t("statusbar.resumeWallpaper") : t("statusbar.pauseWallpaper"),
                    action: #selector(perScreenTogglePlayback(_:)),
                    keyEquivalent: "")
                pauseItem.target = self
                pauseItem.representedObject = screen
                pauseItem.isEnabled = screenHasLiveDynamicWallpaper
                screenSubMenu.addItem(pauseItem)
            }

            if screenHasLiveDynamicWallpaper || screenHasStaticOverlay {
                // 关闭该屏动态壁纸：彻底停止渲染并退回系统静态桌面（区别于暂停）
                let stopItem = NSMenuItem(
                    title: t("statusbar.stopWallpaper"),
                    action: #selector(perScreenStopWallpaper(_:)),
                    keyEquivalent: "")
                stopItem.target = self
                stopItem.representedObject = screen
                stopItem.isEnabled = screenHasLiveDynamicWallpaper
                screenSubMenu.addItem(stopItem)
            } else if !screenHasStaticOverlay, Self.hasRestartableWallpaper(for: screen) {
                // 该屏无壁纸但有关闭前的恢复记录 → 提供一键重新开启
                let startItem = NSMenuItem(
                    title: t("statusbar.startWallpaper"),
                    action: #selector(perScreenStartWallpaper(_:)),
                    keyEquivalent: "")
                startItem.target = self
                startItem.representedObject = screen
                screenSubMenu.addItem(startItem)
            }

            // 音量（扩展模式跳过，与原逻辑一致）
            if !isExtensionMode {
                if isGlobalDisplaySyncEnabled {
                    screenSubMenu.addItem(buildGlobalVolumeMenuItem())
                } else {
                    screenSubMenu.addItem(buildVolumeMenuItem(for: screen))
                }
            }
            if let playbackRateItem = buildPlaybackRateMenuItem(for: screen) {
                screenSubMenu.addItem(playbackRateItem)
            }

            screenSubMenu.addItem(.separator())

            // 可视区域调节…
            let isAdjusting = CropAdjustOverlayController.shared.isActive(for: screen)
            let cropAdjustItem = NSMenuItem(
                title: isAdjusting ? t("statusbar.cropExit") : t("statusbar.cropAdjust"),
                action: #selector(toggleCropAdjustment(_:)),
                keyEquivalent: "")
            cropAdjustItem.target = self
            cropAdjustItem.representedObject = screen
            screenSubMenu.addItem(cropAdjustItem)

            // 比例子菜单
            let aspectItem = NSMenuItem(title: t("statusbar.cropAspect"), action: nil, keyEquivalent: "")
            let aspectMenu = NSMenu(title: t("statusbar.cropAspect"))
            let currentSettings = DisplayCropSettingsStore.shared.settings(for: screen)
            for preset in AspectPreset.allCases {
                let title = preset == .autoFill ? t("statusbar.cropAspectAutoFill")
                    : preset == .custom ? t("statusbar.cropAspectCustom")
                    : preset.displayName()
                let item = NSMenuItem(title: title, action: #selector(setCropAspect(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = CropAspectPayload(screen: screen, preset: preset)
                item.state = (currentSettings.aspectPreset == preset) ? .on : .off
                aspectMenu.addItem(item)
            }
            aspectItem.submenu = aspectMenu
            screenSubMenu.addItem(aspectItem)

            // 重置
            let resetItem = NSMenuItem(
                title: t("statusbar.cropReset"),
                action: #selector(resetCrop(_:)),
                keyEquivalent: "")
            resetItem.target = self
            resetItem.representedObject = screen
            screenSubMenu.addItem(resetItem)

            wallpaperControlItems.append(screenMenuItem)
        }

        // 将动态菜单项（每屏一个顶层子菜单）插入到 muteItem 之前
        let separatorIndex = menu.index(of: muteItem)
        if separatorIndex != -1 {
            var currentInsertIndex = separatorIndex
            for item in wallpaperControlItems {
                menu.insertItem(item, at: currentInsertIndex)
                currentInsertIndex += 1
            }
        }

        // 桌面图标开关
        desktopIconsItem.title = DesktopIconManager.shared.areDesktopIconsHidden
            ? t("statusbar.showDesktopIcons")
            : t("statusbar.hideDesktopIcons")

        // 全局静音开关
        muteItem.isEnabled = hasNativeWallpaper || hasExternalWallpaper
        muteItem.title = videoWallpaperManager.isMuted ? t("statusbar.unmuteWallpaper") : t("statusbar.muteWallpaper")
    }

    private func refreshLocalizedTitles() {
        openWindowItem.title = t("statusbar.showWindow")
        openLibraryItem.title = t("statusbar.openMyLibrary")
        openSettingsItem.title = t("settings")
        releaseMemoryItem.title = t("statusbar.releaseMemory")
        desktopIconsItem.title = t("statusbar.hideDesktopIcons")
        muteItem.title = videoWallpaperManager.isMuted ? t("statusbar.unmuteWallpaper") : t("statusbar.muteWallpaper")
        designWallpaperItem.title = t("design.designWallpaper")
        sceneConfigItem.title = t("statusbar.sceneAdvancedSettings")
        checkUpdateItem.title = t("checkForUpdates")
        quitItem.title = t("statusbar.quit")
        cancelAllDownloadsItem.title = t("statusbar.taskQueue.cancelAllDownloads")
    }

    @objc private func showMainWindow() {
        showWindowHandler?()
    }

    @objc private func openMyLibrary() {
        WaifuXUIActions.perform(.library)
    }

    @objc private func openAppSettingsPanel() {
        // 与 Helper 拆分前一致：设置 UI 只在 UI 进程存在，这里走 XPC 让 UI 进程
        // 把原本的完整设置窗口拉出来（Helper 内不做精简版设置面板）。
        WaifuXUIActions.perform(.settings)
    }

    @objc private func releaseForegroundMemory() {
        releaseMemoryHandler?()
    }

    // MARK: - 可视区域调节 (Crop)

    /// 比例菜单项携带的载荷。
    private struct CropAspectPayload {
        let screen: NSScreen
        let preset: AspectPreset
    }

    @objc private func toggleCropAdjustment(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        CropAdjustOverlayController.shared.toggle(for: screen, statusBarItemRef: statusItem)
        refreshMenuState()
    }

    @objc private func setCropAspect(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? CropAspectPayload else { return }
        DisplayCropSettingsStore.shared.update(for: payload.screen) { s in
            s.aspectPreset = payload.preset
            if payload.preset == .autoFill {
                s.pan = CGPoint(x: 0.5, y: 0.5)
                s.zoom = 1.0
            }
        }
        refreshMenuState()
    }

    @objc private func resetCrop(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        DisplayCropSettingsStore.shared.reset(for: screen)
        refreshMenuState()
    }

    @objc private func togglePerScreenAutoSwitch(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
            let isEnabled = WallpaperSchedulerService.shared.globalDisplayConfig.isEnabled
            WallpaperSchedulerService.shared.updateGlobalDisplayEnabled(!isEnabled)
            refreshMenuState()
            return
        }
        let screenID = screen.wallpaperScreenIdentifier
        let isEnabled = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: screenID).isEnabled
        WallpaperSchedulerService.shared.updateDisplayEnabled(!isEnabled, for: screenID)
        refreshMenuState()
    }

    @objc private func nextWallpaperForScreen(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        // 菜单 tracking 模式下立刻 apply 时，desktop 层合帧常被推迟到点一下其它 App。
        // 先关掉菜单，再在下一拍主线程 runloop 里切换，并强制提交桌面窗。
        menu.cancelTracking()
        let targetScreen = screen
        DispatchQueue.main.async {
            if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
                let hasItems = WallpaperSchedulerService.shared.hasSchedulableItems(
                    for: targetScreen.wallpaperScreenIdentifier
                )
                print("[StatusBar] nextWallpaperForScreen global hasItems=\(hasItems)")
                guard hasItems else {
                    print("[StatusBar] nextWallpaper ignored: no schedulable items in global mode")
                    return
                }
                WallpaperSchedulerService.shared.triggerNextGlobalWallpaperNow()
                VideoWallpaperManager.shared.forceCommitDesktopPresentation()
                return
            }
            let screenID = targetScreen.wallpaperScreenIdentifier
            let hasItems = WallpaperSchedulerService.shared.hasSchedulableItems(for: screenID)
            print("[StatusBar] nextWallpaperForScreen screen=\(targetScreen.localizedName) id=\(screenID) hasItems=\(hasItems)")
            guard hasItems else {
                print("[StatusBar] nextWallpaper ignored: no schedulable items for \(screenID)")
                return
            }
            WallpaperSchedulerService.shared.triggerNextWallpaperNow(for: screenID)
            VideoWallpaperManager.shared.forceCommitDesktopPresentation(on: [targetScreen])
        }
    }

    @objc private func openCurrentWallpaper(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen,
              let request = currentWallpaperDetailRequest(for: screen) else {
            NSSound.beep()
            return
        }
        MainNavigationRequestStore.requestWallpaperDetail(request)
        WaifuXUIActions.perform(.wallpaperDetail)
    }

    private func currentWallpaperDetailRequest(for screen: NSScreen) -> MainWallpaperDetailRequest? {
        guard let url = currentWallpaperURL(for: screen) else { return nil }
        if let record = matchingMediaDownloadRecord(for: url) {
            return .media(record.item)
        }
        if let record = matchingWallpaperDownloadRecord(for: url) {
            return .wallpaper(record.wallpaper)
        }
        return nil
    }

    private func matchingMediaDownloadRecord(for currentURL: URL) -> MediaDownloadRecord? {
        MediaLibraryService.shared.downloadedItems.first { record in
            [record.localFilePath, record.resolvedVideoFileURL?.path, record.sceneBakeArtifact?.videoPath]
                .compactMap { $0 }
                .contains { matchesWallpaperPath(currentURL, recordPath: $0) }
        }
    }

    private func matchingWallpaperDownloadRecord(for currentURL: URL) -> WallpaperDownloadRecord? {
        WallpaperLibraryService.shared.downloadedWallpapers.first {
            matchesWallpaperPath(currentURL, recordPath: $0.localFilePath)
        }
    }

    private func matchesWallpaperPath(_ currentURL: URL, recordPath: String) -> Bool {
        guard currentURL.isFileURL else { return false }
        let currentPath = currentURL.standardizedFileURL.path
        let storedPath = URL(fileURLWithPath: recordPath).standardizedFileURL.path
        return currentPath == storedPath
            || currentPath.hasPrefix(storedPath + "/")
            || storedPath.hasPrefix(currentPath + "/")
    }

    private func currentWallpaperURL(for screen: NSScreen) -> URL? {
        // “打开当前壁纸”必须严格按屏查询。`videoURL(for:)` 为兼容旧的
        // 单屏调用会回退到全局 `currentVideoURL`；多屏下目标屏是 Scene/Web、
        // 其它屏是视频时，这个回退会把其它屏的视频误认成目标屏当前壁纸。
        if let videoURL = videoWallpaperManager.assignedVideoURL(for: screen) { return videoURL }
        if let rendererPath = weBridge.currentWallpaperPath(for: screen) {
            return URL(fileURLWithPath: rendererPath)
        }
        if let imageURL = LockScreenWallpaperService.shared.staticImageSourceURL(for: screen) { return imageURL }
        if let imageURL = StaticImageWallpaperOverlayManager.shared.imageURL(for: screen) { return imageURL }
        return DesktopWallpaperSyncManager.shared.imageURL(for: screen)
    }

    @objc private func perScreenTogglePlayback(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else {
            togglePlayback()
            return
        }

        // 每屏暂停/恢复路由诊断：记录点击瞬间的全部门控标志，
        // 定位「点击无反应」被哪个分支吞掉。
        AppLogger.debug(.wallpaper, "菜单每屏播放控制点击", metadata: [
            "screen": screen.localizedName,
            "globalSync": String(WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled),
            "weControl": String(weBridge.isControllingExternalEngine),
            "weManaging": String(weBridge.isManaging(screen: screen)),
            "lockMirror": String(videoWallpaperManager.isLockScreenMirroringActive),
            "isPausedOn": String(videoWallpaperManager.isPaused(on: screen)),
            "extRendering": String(videoWallpaperManager.externalRenderingActiveForDiagnostics)
        ])

        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
            if weBridge.isControllingExternalEngine {
                if weBridge.isExternalPaused {
                    AppLogger.debug(.wallpaper, "每屏控制路由 → 全局WE恢复")
                    weBridge.resumeWallpaper()
                    DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
                } else {
                    AppLogger.debug(.wallpaper, "每屏控制路由 → 全局WE暂停")
                    weBridge.pauseWallpaper()
                }
            } else if videoWallpaperManager.isPaused {
                AppLogger.debug(.wallpaper, "每屏控制路由 → 全局视频恢复")
                videoWallpaperManager.resumeWallpaper()
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            } else {
                AppLogger.debug(.wallpaper, "每屏控制路由 → 全局视频暂停")
                videoWallpaperManager.pauseWallpaper()
            }
            return
        }

        if weBridge.isControllingExternalEngine {
            // CLI 壁纸暂不支持单屏暂停，走全局
            if weBridge.isExternalPaused {
                AppLogger.debug(.wallpaper, "每屏控制路由 → WE全局恢复")
                weBridge.resumeWallpaper()
            } else {
                AppLogger.debug(.wallpaper, "每屏控制路由 → WE全局暂停")
                weBridge.pauseWallpaper()
            }
            return
        }

        // macOS 26+：扩展控制模式下通过共享 prefs 控制 per-display 暂停
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            AppLogger.debug(.wallpaper, "每屏控制路由 → 锁屏扩展prefs（若此刻无锁屏镜像在跑即误路由）")
            if let displayID = Self.cgDisplayID(for: screen) {
                let isPaused = LockScreenWallpaperService.shared.isDisplayPaused(displayID)
                LockScreenWallpaperService.shared.setDisplayPaused(!isPaused, forDisplayID: displayID)
            }
            return
        }

        if videoWallpaperManager.isPaused(on: screen) {
            AppLogger.debug(.wallpaper, "每屏控制路由 → 单屏视频恢复")
            videoWallpaperManager.resumeWallpaper(for: screen)
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
        } else {
            AppLogger.debug(.wallpaper, "每屏控制路由 → 单屏视频暂停")
            videoWallpaperManager.pauseWallpaper(for: screen)
        }
    }

    /// 每屏「关闭动态壁纸」：彻底停止该屏渲染并退回系统静态桌面（区别于暂停）。
    @objc private func perScreenStopWallpaper(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }

        // 关闭会清掉持久化恢复状态，先捕获当前壁纸用于「开启动态壁纸」一键恢复
        Self.recordRestartableWallpaper(for: screen, videoManager: videoWallpaperManager, bridge: weBridge)

        AppLogger.debug(.wallpaper, "菜单每屏关闭壁纸点击", metadata: [
            "screen": screen.localizedName,
            "globalSync": String(WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled),
            "weControl": String(weBridge.isControllingExternalEngine),
            "weManaging": String(weBridge.isManaging(screen: screen)),
            "lockMirror": String(videoWallpaperManager.isLockScreenMirroringActive)
        ])

        // 全局同步：单入口等价于全局关闭
        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
            WallpaperSchedulerService.shared.suppressAutoSwitchGlobally()
            if weBridge.isControllingExternalEngine {
                AppLogger.debug(.wallpaper, "每屏控制路由 → 全局WE关闭（保留恢复状态）")
                weBridge.disableWallpaperKeepingRestoreState()
            } else {
                AppLogger.debug(.wallpaper, "每屏控制路由 → 全局视频关闭")
                videoWallpaperManager.stopWallpaper()
            }
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            return
        }

        if weBridge.isControllingExternalEngine {
            // WE 壁纸（scene/web）：单屏关闭。scene 杀该屏 wgpu 进程，
            // web 按屏 IPC 拆窗口；该屏 render state 同步移除，其余屏幕不受影响。
            AppLogger.debug(.wallpaper, "每屏控制路由 → WE单屏关闭")
            WallpaperSchedulerService.shared.suppressAutoSwitch(forScreen: screen)
            weBridge.stopWallpaper(forScreenID: screen.wallpaperScreenIdentifier)
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            return
        }

        // native 视频 / 锁屏扩展：单屏停止（内部已处理该屏静态 overlay 与 poster 回退）
        AppLogger.debug(.wallpaper, "每屏控制路由 → 单屏关闭")
        WallpaperSchedulerService.shared.suppressAutoSwitch(forScreen: screen)
        videoWallpaperManager.stopWallpaper(for: screen)
        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
    }

    // MARK: - 每屏「开启动态壁纸」（关闭后一键恢复）

    /// 关闭前捕获的壁纸恢复信息：path 为视频文件路径（isVideoWallpaper=true）
    /// 或 WE 壁纸包根路径（scene/web）。按屏幕 fingerprint 隔离存储。
    private struct RestartableWallpaper: Codable {
        var path: String
        var isVideoWallpaper: Bool
        var muted: Bool?
    }

    private static let restartableWallpaperKey = "statusbar_restartable_wallpaper_v1"

    private static func loadRestartableStore() -> [String: RestartableWallpaper] {
        guard let data = WaifuXPreferences.shared.data(forKey: restartableWallpaperKey),
              let store = try? JSONDecoder().decode([String: RestartableWallpaper].self, from: data) else {
            return [:]
        }
        return store
    }

    private static func saveRestartableStore(_ store: [String: RestartableWallpaper]) {
        if let data = try? JSONEncoder().encode(store) {
            WaifuXPreferences.shared.set(data, forKey: restartableWallpaperKey)
        }
    }

    static func recordRestartableWallpaper(for screen: NSScreen,
                                           videoManager: VideoWallpaperManager,
                                           bridge: WallpaperEngineXBridge) {
        var entry: RestartableWallpaper?
        if let videoURL = videoManager.assignedVideoURL(for: screen) {
            entry = RestartableWallpaper(path: videoURL.path, isVideoWallpaper: true,
                                         muted: videoManager.isMuted)
        } else if bridge.isManaging(screen: screen),
                  let path = bridge.currentWallpaperPathForDesign {
            entry = RestartableWallpaper(path: path, isVideoWallpaper: false, muted: nil)
        }
        guard let entry else { return }

        var store = loadRestartableStore()
        store[screen.wallpaperScreenFingerprint] = entry
        saveRestartableStore(store)
    }

    private static func restartableEntry(for screen: NSScreen) -> RestartableWallpaper? {
        loadRestartableStore()[screen.wallpaperScreenFingerprint]
    }

    static func hasRestartableWallpaper(for screen: NSScreen) -> Bool {
        guard let entry = restartableEntry(for: screen) else { return false }
        return FileManager.default.fileExists(atPath: entry.path)
    }

    /// 每屏「开启动态壁纸」：用关闭前捕获的记录重新应用该屏壁纸。
    /// 全局同步模式下恢复到全部屏（单入口语义与关闭对齐）。
    @objc private func perScreenStartWallpaper(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        guard let entry = Self.restartableEntry(for: screen) else { return }
        guard FileManager.default.fileExists(atPath: entry.path) else {
            // 壁纸文件已被删除/移动，记录失效，清理避免菜单残留
            var store = Self.loadRestartableStore()
            store.removeValue(forKey: screen.wallpaperScreenFingerprint)
            Self.saveRestartableStore(store)
            return
        }

        let globalSync = WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled
        AppLogger.debug(.wallpaper, "菜单每屏开启壁纸点击", metadata: [
            "screen": screen.localizedName,
            "kind": entry.isVideoWallpaper ? "video" : "sceneOrWeb",
            "globalSync": String(globalSync),
            "path": entry.path
        ])

        let url = URL(fileURLWithPath: entry.path)
        let targetScreens: [NSScreen]? = globalSync ? nil : [screen]
        let muted = entry.muted ?? true
        Task { @MainActor in
            do {
                if entry.isVideoWallpaper {
                    try await videoWallpaperManager.applyVideoWallpaper(
                        from: url,
                        muted: muted,
                        targetScreens: targetScreens
                    )
                } else {
                    try await weBridge.setWallpaper(
                        path: entry.path,
                        targetScreens: targetScreens,
                        forceRestart: true
                    )
                }
                AppLogger.debug(.wallpaper, "菜单每屏开启壁纸完成", metadata: [
                    "screen": screen.localizedName
                ])
            } catch {
                AppLogger.error(.wallpaper, "菜单每屏开启壁纸失败", metadata: [
                    "screen": screen.localizedName,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    @objc private func togglePlayback() {
        // 如果当前由 Wallpaper Engine X 接管，走 URL Scheme
        if weBridge.isControllingExternalEngine {
            if weBridge.isExternalPaused {
                weBridge.resumeWallpaper()
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            } else {
                weBridge.pauseWallpaper()
            }
            return
        }

        // macOS 26+：扩展控制模式下全局暂停/恢复
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            LockScreenWallpaperService.shared.setPaused(!videoWallpaperManager.isPaused)
            videoWallpaperManager.toggleExtensionGlobalPause()
            return
        }

        // 检测多显示器
        let screens = NSScreen.screens
        if screens.count > 1 && videoWallpaperManager.isVideoWallpaperActive {
            // 多显示器环境下显示选择弹窗
            DisplaySelectorManager.shared.showSelector(
                title: videoWallpaperManager.isPaused ? t("resumeWallpaper") : t("pauseWallpaper"),
                message: t("selectDisplayToControl")
            ) { [weak self] selectedScreen in
                guard let self = self else { return }

                let isPaused = selectedScreen.map {
                    self.videoWallpaperManager.isPaused(on: $0)
                } ?? self.videoWallpaperManager.isPaused
                if isPaused {
                    self.videoWallpaperManager.resumeWallpaper(for: selectedScreen)
                    DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
                } else {
                    self.videoWallpaperManager.pauseWallpaper(for: selectedScreen)
                }
            }
        } else {
            // 单显示器环境下直接操作
            if videoWallpaperManager.isPaused {
                videoWallpaperManager.resumeWallpaper()
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            } else {
                videoWallpaperManager.pauseWallpaper()
            }
        }
    }

    @objc private func toggleMute() {
        // macOS 26+：扩展模式下静音对所有显示器生效（扩展不播放音频，但记录状态）
        if #available(macOS 26.0, *), videoWallpaperManager.isLockScreenMirroringActive {
            let newMuted = !videoWallpaperManager.isMuted
            videoWallpaperManager.setMuted(newMuted)
            // 同步到所有活跃显示器的 prefs
            for screen in NSScreen.screens {
                if let displayID = Self.cgDisplayID(for: screen) {
                    LockScreenWallpaperService.shared.setDisplayMuted(newMuted, forDisplayID: displayID)
                }
            }
            // 同步到 wallpaper-wgpu 渲染进程（音频控制文件）
            if weBridge.isControllingExternalEngine {
                weBridge.setMuted(newMuted)
            }
            return
        }

        let newMuted = !videoWallpaperManager.isMuted
        videoWallpaperManager.setMuted(newMuted)
        if weBridge.isControllingExternalEngine {
            weBridge.setMuted(newMuted)
        }
    }

    @objc private func toggleDesktopIcons() {
        DesktopIconManager.shared.toggle()
        refreshMenuState()
    }

    @objc private func openSceneConfigPanel() {
        guard let wallpaperPath = sceneConfigItem.representedObject as? String ?? weBridge.currentWallpaperPathForDesign else {
            NSSound.beep()
            return
        }
        presentEditorPopover { anchorView in
            WebPropertyEditorPanelController.shared.presentSceneConfig(for: wallpaperPath, from: anchorView)
        }
    }

    @objc private func openWebWallpaperDesignPanel() {
        guard let target = resolvedWallpaperDesignTarget() else {
            NSSound.beep()
            return
        }

        presentEditorPopover { anchorView in
            switch target {
            case .web(let wallpaperPath):
                WebPropertyEditorPanelController.shared.presentWeb(for: wallpaperPath, from: anchorView)
            case .scene(let wallpaperPath):
                WebPropertyEditorPanelController.shared.presentScene(for: wallpaperPath, from: anchorView)
            case .sceneDesign(let wallpaperPath):
                WebPropertyEditorPanelController.shared.presentSceneDesign(for: wallpaperPath, from: anchorView)
            }
        }
    }

    /// 「设计壁纸 / 场景高级设置」两项是否出现，取决于当前壁纸的工程是否可编辑 ——
    /// 而 `hasEditableProperties` 要解析工程的 `project.json`（读盘 + JSON 解码）。
    /// 左键弹窗（`canDesignCurrentWallpaper`）和右键菜单（`refreshMenuState`）**每次**
    /// 都要问一遍，等于每次点图标都去读一次盘，所以这里做缓存。
    ///
    /// 缓存失效走**两条腿**，不去穷举输入维度：
    /// 1. **显式作废**（`invalidateDesignTargetCache()`）：WE 是否在控、渲染类型
    ///    （`renderStateChangeCount`）、当前视频这几个状态一变就清，见 `bindWallpaperState()`。
    /// 2. **TTL 兜底**：`computeWallpaperDesignTarget()` 的输入不止「路径 + 开关」——
    ///    `currentSceneDesignWallpaperPath()` 还要读磁盘上的 sidecar JSON，
    ///    `hasEditableProperties` 读的 `project.json` 本身也可能被下载/烘焙改写。
    ///    这些都无法廉价地并进 key，所以到点重算，保证任何漏掉的输入变化最迟 30 秒自愈。
    ///
    /// 2026-10-15 修的坑：原先只有 key 一条腿（路径 + 实时渲染开关），而 Helper 启动恢复、
    /// 视频→场景切换时 `lastWallpaperPath` 会残留上一张 WE 壁纸的路径，新旧 key 完全相同，
    /// 于是把恢复早期 `isControllingExternalEngine` 还没起来时算出的 `nil` 一路钉死 ——
    /// 表现为「设计壁纸」按钮偶发不出现，得重开 App 或再切一张才恢复。
    private var cachedDesignTarget: WallpaperDesignTarget?
    private var cachedDesignTargetKey: String?
    private var cachedDesignTargetAt: Date?
    private static let designTargetCacheLifetime: TimeInterval = 30

    private func invalidateDesignTargetCache() {
        cachedDesignTargetKey = nil
        cachedDesignTargetAt = nil
        cachedDesignTarget = nil
    }

    private func resolvedWallpaperDesignTarget() -> WallpaperDesignTarget? {
        let key = (weBridge.currentWallpaperPathForDesign ?? "<none>")
            + "|" + String(WaifuXPreferences.shared.bool(forKey: "scene_realtime_rendering_enabled"))
        if let cachedDesignTargetKey, cachedDesignTargetKey == key,
           let cachedDesignTargetAt,
           Date().timeIntervalSince(cachedDesignTargetAt) < Self.designTargetCacheLifetime {
            return cachedDesignTarget
        }
        let resolved = computeWallpaperDesignTarget()
        cachedDesignTargetKey = key
        cachedDesignTargetAt = Date()
        cachedDesignTarget = resolved
        return resolved
    }

    private func computeWallpaperDesignTarget() -> WallpaperDesignTarget? {
        if let sceneWallpaperPath = currentSceneDesignWallpaperPath() {
            return .sceneDesign(sceneWallpaperPath)
        }

        guard let wallpaperPath = weBridge.currentWallpaperPathForDesign else {
            return nil
        }
        if weBridge.isCurrentWallpaperWeb {
            guard WebWallpaperDesignService.shared.hasEditableProperties(for: wallpaperPath) else {
                return nil
            }
            return .web(wallpaperPath)
        }
        if weBridge.isCurrentWallpaperScene {
            return WaifuXPreferences.shared.bool(forKey: "scene_realtime_rendering_enabled")
                ? .scene(wallpaperPath)
                : .sceneDesign(wallpaperPath)
        }
        return nil
    }

    private func presentEditorPopover(_ present: @escaping (NSView) -> Void) {
        guard let statusButton = statusItem.button else {
            NSSound.beep()
            return
        }
        // NSMenu is still tracking while its item's action runs. Presenting on
        // the next turn prevents it from immediately dismissing the popover.
        DispatchQueue.main.async {
            present(statusButton)
        }
    }

    private func currentSceneDesignWallpaperPath() -> String? {
        guard let videoURL = videoWallpaperManager.currentVideoURL,
              let info = WallpaperDynamicTextParser.loadSidecar(for: videoURL),
              info.hasDynamicText,
              let wallpaperPath = info.wallpaperPath,
              !wallpaperPath.isEmpty else {
            return nil
        }
        return wallpaperPath
    }

    @objc private func quitApplication() {
        quitHandler?()
    }

    /// 触发 Sparkle 检查更新（UI 反馈由 Sparkle 内置弹窗处理）
    @objc private func checkForUpdates() {
        WaifuXUIActions.perform(.updates)
    }

    /// 从 NSScreen 获取 CGDirectDisplayID（用于 per-display prefs 的 key）
    private static func cgDisplayID(for screen: NSScreen) -> UInt32? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return screenNumber.uint32Value
    }
}

// MARK: - NSMenuDelegate
extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }
}
