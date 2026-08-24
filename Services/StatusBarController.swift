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

    init(title: String, progress: Double, isSectionHeader: Bool = false) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: 24))
        titleLabel.font = NSFont.systemFont(ofSize: isSectionHeader ? 13 : 12, weight: isSectionHeader ? .semibold : .regular)
        titleLabel.textColor = isSectionHeader ? .secondaryLabelColor : .disabledControlTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .disabledControlTextColor
        progressLabel.alignment = .right
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(progressLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -8),
            progressLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progressLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressLabel.widthAnchor.constraint(equalToConstant: 44)
        ])
        update(title: title, progress: progress, isSectionHeader: isSectionHeader)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(title: String, progress: Double, isSectionHeader: Bool = false) {
        titleLabel.stringValue = title
        progressLabel.stringValue = isSectionHeader ? "" : "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}

@MainActor
final class StatusBarController: NSObject {
    // MARK: - 单例
    static let shared = StatusBarController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
    /// 紧跟任务队列项的分隔线；队列隐藏时一并移除。
    private lazy var taskQueueSeparatorItem = NSMenuItem.separator()
    private var taskQueueRowsByID: [String: TaskQueueRowView] = [:]
    private var taskQueueStructure: [String] = []
    private var isTaskQueueMenuVisible = false

    // 标记是否已配置，防止重复配置
    private var isConfigured = false

    private override init() {
        super.init()
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

        let clickActionsSwapped = UserDefaults.standard.bool(forKey: "menu_bar_swap_click_actions")
        let showQuickSwitcher = (event.type == .leftMouseUp) != clickActionsSwapped

        if showQuickSwitcher {
            let targetScreen = sender.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
            quickSwitcherController.toggle(
                relativeTo: sender,
                targetScreen: targetScreen,
                currentWallpaperURL: targetScreen.flatMap { currentWallpaperURL(for: $0) },
                onOpenSettings: { [weak self] in
                    self?.openAppSettingsPanel()
                },
                onOpenDetail: { [weak self] request in
                    MainNavigationRequestStore.requestWallpaperDetail(request)
                    self?.showWindowHandler?()
                }
            )
        } else if event.type == .leftMouseUp || event.type == .rightMouseUp {
            quickSwitcherController.dismiss()
            refreshMenuState()
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
                let row = TaskQueueRowView(title: entry.title, progress: entry.progress)
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

    private func refreshMenuState() {
        refreshLocalizedTitles()

        let hasNativeWallpaper = videoWallpaperManager.isVideoWallpaperActive
        let hasExternalWallpaper = weBridge.isControllingExternalEngine
        let hasWallpaper = hasNativeWallpaper || hasExternalWallpaper
        let shouldShowDesignWallpaperItem: Bool
        if let sceneWallpaperPath = currentSceneDesignWallpaperPath() {
            shouldShowDesignWallpaperItem = true
            designWallpaperItem.representedObject = sceneWallpaperPath
        } else if let wallpaperPath = weBridge.currentWallpaperPathForDesign {
            if weBridge.isCurrentWallpaperWeb {
                shouldShowDesignWallpaperItem = WebWallpaperDesignService.shared.hasEditableProperties(for: wallpaperPath)
                designWallpaperItem.representedObject = wallpaperPath
            } else if weBridge.isCurrentWallpaperScene {
                shouldShowDesignWallpaperItem = true
                designWallpaperItem.representedObject = wallpaperPath
            } else {
                shouldShowDesignWallpaperItem = false
                designWallpaperItem.representedObject = nil
            }
        } else {
            shouldShowDesignWallpaperItem = false
            designWallpaperItem.representedObject = nil
        }
        designWallpaperItem.isHidden = !shouldShowDesignWallpaperItem
        designWallpaperItem.isEnabled = shouldShowDesignWallpaperItem

        // 场景高级设置（仅在实时渲染场景壁纸时显示）
        let shouldShowSceneConfig = weBridge.isCurrentWallpaperScene
            && UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled")
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

            if screenHasManagedWallpaper {
                let pauseItem = NSMenuItem(
                    title: isScreenPaused ? t("statusbar.resumeWallpaper") : t("statusbar.pauseWallpaper"),
                    action: #selector(perScreenTogglePlayback(_:)),
                    keyEquivalent: "")
                pauseItem.target = self
                pauseItem.representedObject = screen
                pauseItem.isEnabled = screenHasWallpaper
                screenSubMenu.addItem(pauseItem)
            }

            // 音量（扩展模式跳过，与原逻辑一致）
            if !isExtensionMode {
                if isGlobalDisplaySyncEnabled {
                    screenSubMenu.addItem(buildGlobalVolumeMenuItem())
                } else {
                    screenSubMenu.addItem(buildVolumeMenuItem(for: screen))
                }
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
    }

    @objc private func showMainWindow() {
        showWindowHandler?()
    }

    @objc private func openMyLibrary() {
        MainNavigationRequestStore.requestLibraryTab()
        showWindowHandler?()
    }

    @objc private func openAppSettingsPanel() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.showSettingsWindow(nil)
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
        showWindowHandler?()
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

                if self.videoWallpaperManager.isPaused {
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
        if let sceneWallpaperPath = currentSceneDesignWallpaperPath() {
            presentEditorPopover { anchorView in
                WebPropertyEditorPanelController.shared.presentSceneDesign(for: sceneWallpaperPath, from: anchorView)
            }
            return
        }

        guard let wallpaperPath = weBridge.currentWallpaperPathForDesign else {
            NSSound.beep()
            return
        }
        if weBridge.isCurrentWallpaperWeb {
            presentEditorPopover { anchorView in
                WebPropertyEditorPanelController.shared.presentWeb(for: wallpaperPath, from: anchorView)
            }
            return
        }
        if weBridge.isCurrentWallpaperScene {
            // 实时渲染模式下，显示属性编辑面板；否则显示文本设计面板
            if UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled") {
                presentEditorPopover { anchorView in
                    WebPropertyEditorPanelController.shared.presentScene(for: wallpaperPath, from: anchorView)
                }
            } else {
                presentEditorPopover { anchorView in
                    WebPropertyEditorPanelController.shared.presentSceneDesign(for: wallpaperPath, from: anchorView)
                }
            }
            return
        }
        NSSound.beep()
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
        AppDelegate.shared?.checkForUpdates()
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
