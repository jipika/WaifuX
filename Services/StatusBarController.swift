import AppKit
import Combine

// MARK: - 菜单栏音量滑块自定义视图
private final class WallpaperVolumeSliderView: NSView {
    private let iconView = NSImageView()
    private let slider = NSSlider()
    private var cancellables = Set<AnyCancellable>()

    var onVolumeChanged: ((Double) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
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
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            slider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
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

@MainActor
final class StatusBarController: NSObject {
    // MARK: - 单例
    static let shared = StatusBarController()
    
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private lazy var openWindowItem = NSMenuItem(title: t("statusbar.showWindow"), action: #selector(showMainWindow), keyEquivalent: "")
    private lazy var toggleWallpaperItem = NSMenuItem(title: t("statusbar.enableWallpaper"), action: #selector(toggleDynamicWallpaper), keyEquivalent: "")
    private lazy var playPauseItem = NSMenuItem(title: t("statusbar.pauseWallpaper"), action: #selector(togglePlayback), keyEquivalent: "")
    private lazy var muteItem = NSMenuItem(title: t("statusbar.muteWallpaper"), action: #selector(toggleMute), keyEquivalent: "")
    private lazy var quitItem = NSMenuItem(title: t("statusbar.quit"), action: #selector(quitApplication), keyEquivalent: "q")

    private let videoWallpaperManager = VideoWallpaperManager.shared
    private let weBridge = WallpaperEngineXBridge.shared
    private var showWindowHandler: (() -> Void)?
    private var quitHandler: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    
    // 音量滑块
    private lazy var volumeSliderView = WallpaperVolumeSliderView()
    private lazy var volumeSliderItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = volumeSliderView
        volumeSliderView.onVolumeChanged = { [weak self] volume in
            self?.videoWallpaperManager.setVolume(volume)
            if volume > 0 && self?.videoWallpaperManager.isMuted == true {
                self?.videoWallpaperManager.setMuted(false)
            } else if volume == 0 && self?.videoWallpaperManager.isMuted == false {
                self?.videoWallpaperManager.setMuted(true)
            }
        }
        return item
    }()
    
    // 标记是否已配置，防止重复配置
    private var isConfigured = false

    private override init() {
        super.init()
        configureStatusItem()
        bindWallpaperState()
        refreshMenuState()
    }

    /// 配置处理程序（只能调用一次）
    func configure(showWindow: @escaping () -> Void, quit: @escaping () -> Void) {
        guard !isConfigured else {
            print("[StatusBarController] Already configured, skipping...")
            return
        }
        self.showWindowHandler = showWindow
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

        openWindowItem.target = self
        toggleWallpaperItem.target = self
        playPauseItem.target = self
        muteItem.target = self
        quitItem.target = self

        menu.addItem(openWindowItem)
        menu.addItem(.separator())
        menu.addItem(toggleWallpaperItem)
        menu.addItem(playPauseItem)
        menu.addItem(muteItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func bindWallpaperState() {
        videoWallpaperManager.$currentVideoURL
            .combineLatest(videoWallpaperManager.$isPaused, videoWallpaperManager.$isMuted, videoWallpaperManager.$volume)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshMenuState()
            }
            .store(in: &cancellables)

        weBridge.$isControllingExternalEngine
            .combineLatest(weBridge.$isExternalPaused)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshMenuState()
            }
            .store(in: &cancellables)
    }

    private func refreshMenuState() {
        let hasNativeWallpaper = videoWallpaperManager.currentVideoURL != nil
        let hasExternalWallpaper = weBridge.isControllingExternalEngine
        let hasWallpaper = hasNativeWallpaper || hasExternalWallpaper

        // 开启/关闭动态壁纸菜单项
        toggleWallpaperItem.title = hasWallpaper ? t("statusbar.disableWallpaper") : t("statusbar.enableWallpaper")

        // 暂停/恢复只在有动态壁纸时可用
        playPauseItem.isEnabled = hasWallpaper
        playPauseItem.title = (hasExternalWallpaper ? weBridge.isExternalPaused : videoWallpaperManager.isPaused)
            ? t("statusbar.resumeWallpaper")
            : t("statusbar.pauseWallpaper")

        // 静音只在本机视频壁纸时可用（外部引擎自行处理音频）
        muteItem.isEnabled = hasNativeWallpaper
        muteItem.title = videoWallpaperManager.isMuted ? t("statusbar.unmuteWallpaper") : t("statusbar.muteWallpaper")

        // 音量滑块：只在有本机视频动态壁纸时显示（CLI 暂不支持音量调节）
        updateVolumeSliderVisibility()
    }

    private func updateVolumeSliderVisibility() {
        let hasNativeWallpaper = videoWallpaperManager.currentVideoURL != nil

        if hasNativeWallpaper {
            if volumeSliderItem.menu == nil {
                // 插入到 muteItem 后面
                let muteIndex = menu.index(of: muteItem)
                if muteIndex != -1 {
                    menu.insertItem(volumeSliderItem, at: muteIndex + 1)
                }
            }
            volumeSliderView.setVolume(videoWallpaperManager.volume, isMuted: videoWallpaperManager.isMuted)
        } else {
            if volumeSliderItem.menu != nil {
                menu.removeItem(volumeSliderItem)
            }
        }
    }

    @objc private func showMainWindow() {
        showWindowHandler?()
    }

    @objc private func togglePlayback() {
        // 如果当前由 Wallpaper Engine X 接管，走 URL Scheme
        if weBridge.isControllingExternalEngine {
            if weBridge.isExternalPaused {
                weBridge.resumeWallpaper()
            } else {
                weBridge.pauseWallpaper()
            }
            return
        }

        // 检测多显示器
        let screens = NSScreen.screens
        if screens.count > 1 && videoWallpaperManager.currentVideoURL != nil {
            // 多显示器环境下显示选择弹窗
            DisplaySelectorManager.shared.showSelector(
                title: videoWallpaperManager.isPaused ? t("resumeWallpaper") : t("pauseWallpaper"),
                message: t("selectDisplayToControl")
            ) { [weak self] selectedScreen in
                guard let self = self else { return }

                if self.videoWallpaperManager.isPaused {
                    self.videoWallpaperManager.resumeWallpaper(for: selectedScreen)
                } else {
                    self.videoWallpaperManager.pauseWallpaper(for: selectedScreen)
                }
            }
        } else {
            // 单显示器环境下直接操作
            if videoWallpaperManager.isPaused {
                videoWallpaperManager.resumeWallpaper()
            } else {
                videoWallpaperManager.pauseWallpaper()
            }
        }
    }

    @objc private func toggleDynamicWallpaper() {
        if weBridge.isControllingExternalEngine {
            // 关闭外部引擎壁纸
            weBridge.stopWallpaper()
            return
        }

        if videoWallpaperManager.currentVideoURL != nil {
            // 关闭动态壁纸
            videoWallpaperManager.stopWallpaper()
        } else {
            // 先尝试恢复上次保存的壁纸，没有则打开主窗口让用户选择
            videoWallpaperManager.restoreIfNeeded()
            if videoWallpaperManager.currentVideoURL == nil {
                weBridge.restoreIfNeeded()
                if !weBridge.isControllingExternalEngine {
                    showWindowHandler?()
                }
            }
        }
    }

    @objc private func toggleMute() {
        videoWallpaperManager.setMuted(!videoWallpaperManager.isMuted)
    }

    @objc private func quitApplication() {
        quitHandler?()
    }
}
