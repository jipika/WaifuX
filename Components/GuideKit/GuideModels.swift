import SwiftUI
import AppKit

// MARK: - WaifuX GuideKit · 模型与锚点注册
// 设计文档：Docs/Guide-Kit-Design.md
// 锚点登记只存「窗口本地矩形（AppKit y 向上）+ 弱引用 window」；
// 引擎播放每步时才 convertToScreen，窗口平移天然跟随。

/// 全局唯一的引导锚点 ID。每个可引导元素一个 case，禁止复用。
enum GuideAnchorID: Hashable {
    /// 顶栏「?」帮助按钮（操作手册 + 功能导览入口）
    case topBarHelp
    /// 首页 hero 轮播区（单击进入沉浸模式、拖拽换页）
    case homeHero
    /// 首页 hero 浮层操作按钮组（查看壁纸 / 收藏）
    case homeHeroActions
    /// 菜单栏状态项。特殊锚点：真值由 Helper XPC 上报（Phase 3），
    /// 当前由引擎解析为主屏菜单栏右侧兜底区域。
    case menubarStatusItem
    // 静态壁纸探索
    case exploreSourceMenu
    case exploreHeader
    case exploreRatioMenu
    case exploreScrollToTop
    // 动态壁纸探索
    case mediaSourceMenu
    case mediaContentChips
    case mediaResolutionMenu
    // 番剧
    case animeScrollToTop
    case animeBackgroundPanel
    case animeResetFilters
    // 我的库
    case libraryEditButton
    case librarySearchControl
    // 详情页（Media / Wallpaper 两个 sheet 共用）
    case detailHeroInfo
    case libraryImportButton
    case libraryMoreMenuButton
    // 详情页·信息行的作者胶囊（点开作者面板）
    case detailAuthorLink
    // 顶部标签栏（首页/壁纸/媒体/动漫/我的）
    case homeTabBar
    // 设置页·动态锁屏区块
    case lockscreenToggle
    case lockscreenStatusRow
    // 设置页·左侧导航十个分类
    case settingsTabGeneral
    case settingsTabModules
    case settingsTabDownload
    case settingsTabWallhaven
    case settingsTabWorkshop
    case settingsTabPixiv
    case settingsTabKonachan
    case settingsTabScheduler
    case settingsTabSync
    case settingsTabAbout
    case detailActionRow
    /// 详情「更多选项」popover 内容（独立 NSWindow，遮罩层级会自适应抬高）
    case detailMorePopover
    /// 作者滑出面板 header（主窗口内 overlay）
    case authorSheetHeader
    // 探索页搜索行三个快捷圆钮（链接导入 / 氛围背景 / 重置筛选）
    case exploreActionCircles
    case mediaActionCircles
}

/// 导览步骤。anchor 为 nil 表示无目标居中文字卡（如欢迎步）。
struct GuideStep: Identifiable, Equatable {
    let id = UUID()
    let anchor: GuideAnchorID?
    let titleKey: String
    let bodyKey: String
    /// Phase 3 保留：洞内点击穿透、引导用户真实操作
    var isInteractive: Bool = false

    static func == (lhs: GuideStep, rhs: GuideStep) -> Bool { lhs.id == rhs.id }
}

/// 一段页面导览 = 有序步骤 + 内容版本（version bump 会触发自动重播一次）。
struct GuideTour {
    let id: String
    let contentVersion: Int
    let steps: [GuideStep]
}

// MARK: - 锚点注册表
@MainActor
final class GuideAnchorRegistry {
    static let shared = GuideAnchorRegistry()

    private struct Entry {
        weak var window: NSWindow?
        var frameInWindow: CGRect
    }

    private var entries: [GuideAnchorID: Entry] = [:]

    func report(_ id: GuideAnchorID, frameInWindow: CGRect, window: NSWindow?) {
        entries[id] = Entry(window: window, frameInWindow: frameInWindow)
    }

    /// 解析为「遮罩窗口本地矩形」（y 向下，原点=遮罩窗左上）。
    /// window 为空（窗口已释放）或坐标无效时返回 nil。
    func localFrame(on screen: NSScreen, for id: GuideAnchorID) -> CGRect? {
        guard let entry = entries[id], let window = entry.window else { return nil }
        let frame = entry.frameInWindow
        guard frame.width > 1, frame.height > 1 else { return nil }
        let screenRect = window.convertToScreen(frame)
        // 全局屏幕坐标（y 向上）→ 遮罩窗本地（y 向下）
        let local = CGRect(
            x: screenRect.minX - screen.frame.minX,
            y: screen.frame.maxY - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )
        guard local.minX >= -8, local.minY >= -8 else { return nil }
        return local
    }

    func remove(_ id: GuideAnchorID) {
        entries[id] = nil
    }

    /// 锚点所在宿主窗口的层级（popover 内容在独立 NSWindow 里，层级 > 主窗口）。
    /// 引擎据此把遮罩窗抬高到该层级之上，保证挖洞与气泡盖得住浮层。
    func windowLevel(for id: GuideAnchorID) -> NSWindow.Level? {
        guard let entry = entries[id], let window = entry.window else { return nil }
        return window.level
    }

    func removeAll() {
        entries.removeAll()
    }
}

// MARK: - .guideAnchor() 修饰符
struct GuideAnchorModifier: ViewModifier {
    let id: GuideAnchorID
    /// 最近一次布局帧（可逃逸的纯值，供延迟重报使用）。
    @State private var lastFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        lastFrame = geo.frame(in: .global)
                        reportIfPossible()
                        scheduleLateRetries()
                    }
                    .onChange(of: geo.frame(in: .global)) { _, new in
                        lastFrame = new
                        reportIfPossible()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                        // 顶栏等启动最早期渲染的视图，onAppear 时主窗口还不是 key，
                        // 首次上报会被 guard 掉；窗口就绪后补报一次。
                        reportIfPossible()
                    }
                    .onDisappear {
                        // 条件视图（回顶部按钮、详情浮层按钮等）隐藏时注销，
                        // 避免引擎拿到过期的洞位置。
                        GuideAnchorRegistry.shared.remove(id)
                    }
            }
        )
    }

    /// 启动早期窗口尚未建立时，稍后补报几次（顶栏锚点曾因此永久缺失）。
    private func scheduleLateRetries() {
        Task { @MainActor in
            for delay in [0.25, 0.8, 2.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                reportIfPossible()
            }
        }
    }

    private func reportIfPossible() {
        let frame = lastFrame
        guard frame.width > 0, frame.height > 0 else { return }
        // tour 播放期间不再刷新登记帧：registry 保留开播前的正确宿主与矩形
        //（此时遮罩窗是 keyWindow，用它换算会拿到错误宿主）。
        guard !GuideEngine.shared.isTourActive else { return }
        // 宿主窗口判定：key 窗口浮在主窗口之上（popover/浮层面板）时，
        // 锚点在浮层里；否则属于主内容窗口。
        let key = NSApp.keyWindow
        let main = NSApp.mainWindow
        let window: NSWindow?
        if let key, key != main {
            // key ≠ main 一律视为锚点在独立窗口（popover、设置窗等）——
            // 设置窗与主窗同为 normal level，不能再用 level 比较。
            window = key
        } else {
            window = main ?? key
        }
        guard let window else { return }
        // SwiftUI global（y 向下）→ AppKit 窗口本地（y 向上）
        let local = CGRect(
            x: frame.minX,
            y: window.frame.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        GuideAnchorRegistry.shared.report(id, frameInWindow: local, window: window)
    }
}

extension View {
    /// 把当前视图注册为引导锚点。布局变化时自动刷新登记帧。
    func guideAnchor(_ id: GuideAnchorID) -> some View {
        modifier(GuideAnchorModifier(id: id))
    }
}
