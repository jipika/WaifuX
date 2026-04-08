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
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "WallHaven") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "WH"
            }
            button.toolTip = "WallHaven"
        }

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
    }

    private func refreshMenuState() {
        let hasWallpaper = videoWallpaperManager.currentVideoURL != nil

        // 开启/关闭动态壁纸菜单项
        toggleWallpaperItem.title = hasWallpaper ? t("statusbar.disableWallpaper") : t("statusbar.enableWallpaper")

        // 暂停/恢复、静音菜单项只在有动态壁纸时可用
        playPauseItem.isEnabled = hasWallpaper
        muteItem.isEnabled = hasWallpaper

        playPauseItem.title = videoWallpaperManager.isPaused ? t("statusbar.resumeWallpaper") : t("statusbar.pauseWallpaper")
        muteItem.title = videoWallpaperManager.isMuted ? t("statusbar.unmuteWallpaper") : t("statusbar.muteWallpaper")
    }

    @objc private func showMainWindow() {
        showWindowHandler?()
    }

    @objc private func togglePlayback() {
        if videoWallpaperManager.isPaused {
            videoWallpaperManager.resumeWallpaper()
        } else {
            videoWallpaperManager.pauseWallpaper()
        }
    }

    @objc private func toggleDynamicWallpaper() {
        if videoWallpaperManager.currentVideoURL != nil {
            // 关闭动态壁纸
            videoWallpaperManager.stopWallpaper()
        } else {
            // 先尝试恢复上次保存的壁纸，没有则打开主窗口让用户选择
            videoWallpaperManager.restoreIfNeeded()
            if videoWallpaperManager.currentVideoURL == nil {
                showWindowHandler?()
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
