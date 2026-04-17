import AppKit
import Combine

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
            .combineLatest(videoWallpaperManager.$isPaused, videoWallpaperManager.$isMuted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
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
