import SwiftUI
import AppKit
import Combine

// MARK: - WaifuX GuideKit · 引擎
// 步进状态机 + 遮罩窗口 + 键盘推进 + 持久化。
// 遮罩窗 level = .modalPanel(8)：盖住主窗口/详情浮层，但**低于菜单栏(24)/状态项(25)**，
// 菜单栏步骤时菜单栏保持真实可见（有意为之，见 Docs/Guide-Kit-Design.md §3.2）。

@MainActor
final class GuideEngine: ObservableObject {
    static let shared = GuideEngine()
    private init() {}

    // MARK: 状态
    @Published private(set) var activeTour: GuideTour?
    @Published private(set) var stepIndex: Int = 0
    /// 遮罩窗口本地坐标（y 向下）。nil = 无锚点居中文字卡。
    @Published private(set) var currentHole: CGRect?
    /// 遮罩窗口本地的可用区（screen.visibleFrame：剔除菜单栏与 Dock）。
    /// 气泡定位必须夹取在此范围内，避免被 Dock 挡住。
    @Published private(set) var usableRect: CGRect?

    var isTourActive: Bool { activeTour != nil }

    /// 该窗口是否为本引擎的遮罩窗（锚点上报用它排除错误宿主）。
    func isOverlayWindow(_ window: NSWindow) -> Bool {
        window === overlayWindow
    }
    var currentStep: GuideStep? {
        guard let tour = activeTour, tour.steps.indices.contains(stepIndex) else { return nil }
        return tour.steps[stepIndex]
    }
    var stepCount: Int { activeTour?.steps.count ?? 0 }

    private var overlayWindow: NSWindow?
    private var hostScreen: NSScreen?
    private var keyboardMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var recordProgressOnFinish = true
    private let progressStore = GuideProgressStore()
    private var currentTab: MainTab = .home
    private var pendingAutoplayToken = UUID()

    // MARK: - 触达层入口

    /// ContentView 在 onAppear（isInitial: true，延迟更久等首帧/数据）与 tab 切换时调用。
    /// 每次调用都会取消未决的自动播放，再按需为当前 tab 重新调度——
    /// 保证「延迟期间切走 tab」不会在错误页面上开播。
    func noteTabActivated(_ tab: MainTab, isInitial: Bool = false) {
        currentTab = tab
        pendingAutoplayToken = UUID()
        guard !isTourActive else { return }
        guard let tour = GuideTours.tour(for: tab) else { return }
        guard progressStore.needsAutoplay(tour) else { return }
        let token = pendingAutoplayToken
        let delay: TimeInterval = isInitial ? 1.5 : 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard token == self.pendingAutoplayToken else { return }
                guard !self.isTourActive else { return }
                guard self.progressStore.needsAutoplay(tour) else { return }
                self.start(tour, recordProgress: true)
            }
        }
    }

    /// 详情浮层打开时调用（ContentView 在路由变为 wallpaper/media 时触发；
    /// 动漫/漫画详情没有导览锚点，不触发也不记完成）。
    /// 与 tab 自动播放共享 token：打开详情会取消未决的 tab 播放。
    func noteDetailOpened() {
        pendingAutoplayToken = UUID()
        guard !isTourActive else { return }
        let tour = GuideTours.detail
        guard progressStore.needsAutoplay(tour) else { return }
        let token = pendingAutoplayToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard token == self.pendingAutoplayToken else { return }
                guard !self.isTourActive else { return }
                guard self.progressStore.needsAutoplay(tour) else { return }
                self.start(tour, recordProgress: true)
            }
        }
    }

    /// 二级弹层（popover / 滑出面板）打开时的触发入口。
    /// 与 tab/detail 自动播放共享 token：新弹层会取消未决的旧播放。
    func noteSheetOpened(_ tour: GuideTour) {
        pendingAutoplayToken = UUID()
        guard !isTourActive else { return }
        guard progressStore.needsAutoplay(tour) else { return }
        let token = pendingAutoplayToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard token == self.pendingAutoplayToken else { return }
                guard !self.isTourActive else { return }
                guard self.progressStore.needsAutoplay(tour) else { return }
                self.start(tour, recordProgress: true)
            }
        }
    }

    /// 设置页底部「功能导览」按钮等入口：手动重播指定 tour（不写完成状态）。
    func replay(_ tour: GuideTour) {
        guard !isTourActive else { return }
        start(tour, recordProgress: false)
    }

    /// 「?」帮助弹窗等入口手动重播（不写完成状态）。
    func replayTour(for tab: MainTab) {
        guard !isTourActive else { return }
        guard let tour = GuideTours.tour(for: tab) else { return }
        start(tour, recordProgress: false)
    }

    // MARK: - 状态机

    private func start(_ tour: GuideTour, recordProgress: Bool) {
        guard !isTourActive else { return }
        // 锚点可能在独立窗口（设置窗/popover）：遮罩必须落在首步锚点所在屏，
        // 否则设置窗拖到副屏时全部步骤会被「不在遮罩屏内」跳过。
        let anchorScreen = tour.steps.first?.anchor.flatMap {
            GuideAnchorRegistry.shared.window(for: $0)?.screen
        }
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow,
              let screen = anchorScreen ?? window.screen ?? NSScreen.main else {
            AppLogger.error(.general, "[GuideKit] no host window/screen, tour \(tour.id) aborted")
            return
        }

        activeTour = tour
        stepIndex = 0
        recordProgressOnFinish = recordProgress
        hostScreen = screen
        computeUsableRect()
        // 运行时可观察判据：usableRect 应小于整屏（剔除了菜单栏与 Dock）
        if let screen = hostScreen, let usable = usableRect {
            AppLogger.info(.general, "[GuideKit] tour \(tour.id) screen=\(screen.frame) usable=\(usable)")
        }

        installOverlay(on: screen)
        installKeyboardMonitor()
        observeWindowGeometry()

        // 等遮罩窗上屏后再解析第一步锚点，避免拿到旧帧。
        DispatchQueue.main.async { [weak self] in
            self?.showStep(at: 0)
        }
    }

    private func showStep(at index: Int) {
        guard let tour = activeTour else { return }
        guard tour.steps.indices.contains(index) else {
            end(markCompleted: true)
            return
        }
        stepIndex = index
        guard let step = currentStep else { return }
        updateOverlayLevel(for: step)

        guard let anchor = step.anchor else {
            // 无锚点：居中文字卡
            currentHole = nil
            return
        }

        if let hole = resolveHole(anchor) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                currentHole = hole
            }
        } else {
            // 锚点缺失（数据未加载/面板未出现）：跳过该步，不中断导览
            AppLogger.error(.general, "[GuideKit] anchor \(anchor) missing, skip step \(index) of \(tour.id)")
            showStep(at: index + 1)
        }
    }

    /// 可用区（visibleFrame）换算成遮罩窗本地矩形。
    private func computeUsableRect() {
        guard let screen = hostScreen else {
            usableRect = nil
            return
        }
        let vf = screen.visibleFrame
        usableRect = CGRect(
            x: vf.minX - screen.frame.minX,
            y: screen.frame.maxY - vf.maxY,
            width: vf.width,
            height: vf.height
        )
    }

    /// 遮罩层级自适应：锚点在 popover（.popUpMenu=101）等独立浮层窗口时，
    /// 把遮罩抬到该层级之上，否则挖洞和气泡会被浮层压在后面。
    private func updateOverlayLevel(for step: GuideStep) {
        guard let overlay = overlayWindow else { return }
        var target = NSWindow.Level.modalPanel
        if let anchor = step.anchor,
           let anchorLevel = GuideAnchorRegistry.shared.windowLevel(for: anchor) {
            target = max(target, NSWindow.Level(rawValue: anchorLevel.rawValue + 1))
        }
        overlay.level = target
    }

    /// 解析锚点为遮罩窗本地矩形；菜单栏兜底锚点在这里特殊处理。
    private func resolveHole(_ anchor: GuideAnchorID) -> CGRect? {
        guard let screen = hostScreen else { return nil }
        if anchor == .menubarStatusItem {
            // 兜底区域：主屏菜单栏右侧（状态项+时钟一带）。
            // XPC 真值升级点：Helper 上报 statusItem.button.window.frame 后优先使用。
            let f = screen.frame
            let global = CGRect(x: f.maxX - 330, y: f.maxY - 26, width: 220, height: 24)
            return CGRect(
                x: global.minX - f.minX,
                y: f.maxY - global.maxY,
                width: global.width,
                height: global.height
            )
        }
        return GuideAnchorRegistry.shared.localFrame(on: screen, for: anchor)
    }

    func next() {
        guard isTourActive else { return }
        showStep(at: stepIndex + 1)
    }

    func previous() {
        guard isTourActive, stepIndex > 0 else { return }
        showStep(at: stepIndex - 1)
    }

    /// 遮罩点击（洞外）= 下一步；最后一步 = 完成。
    func advanceFromMaskTap() {
        guard isTourActive else { return }
        next()
    }

    /// Esc / 跳过导览：标记完成（不再自动播放）并收尾。
    /// flag 必须在 teardown 之前取出——teardown 会把它复位为 true，
    /// 否则手动重播（recordProgress: false）按 Esc/跳过也会误写完成状态。
    func end(markCompleted: Bool) {
        guard let tour = activeTour else { return }
        let shouldRecord = recordProgressOnFinish
        teardown()
        if markCompleted, shouldRecord {
            progressStore.markCompleted(tour)
        }
    }

    // MARK: - 遮罩窗口

    private func installOverlay(on screen: NSScreen) {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .modalPanel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hostingView = NSHostingView(rootView: GuideOverlayView(engine: self))
        // #130/#132：全屏遮罩尺寸由屏幕决定，禁止 SwiftUI 内容反推窗口尺寸。
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        overlayWindow = window
    }

    private func teardown() {
        activeTour = nil
        currentHole = nil
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
        cancellables.removeAll()
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        hostScreen = nil
        recordProgressOnFinish = true
    }

    // MARK: - 键盘推进（项目惯例：NSEvent local monitor）

    private func installKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated {
                self.handleKeyDown(event)
            }
            return handled ? nil : event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isTourActive else { return false }
        // 文本编辑中（搜索框等 NSTextField / field editor）：Space/Esc/方向键放行，
        // 否则打字里的空格会被吞成「下一步」，Esc 也关不掉输入焦点。
        if let responder = event.window?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return false
        }
        switch event.keyCode {
        case 53: // Esc：结束整段导览
            // 作者滑出面板是详情页自己的弹层：Esc 先交给详情视图关面板，
            // 与详情页「弹窗优先、逐层关闭」的 Esc 语义一致。
            if authorSheetIsOpen { return false }
            end(markCompleted: true)
            return true
        case 124, 49: // → / Space：下一步
            next()
            return true
        case 123: // ←：上一步
            previous()
            return true
        default:
            return false
        }
    }

    /// 作者滑出面板是主窗内 overlay，无法从窗口层级判断；锚点已上报即视为开着。
    private var authorSheetIsOpen: Bool {
        GuideAnchorRegistry.shared.window(for: .authorSheetHeader) != nil
    }

    // MARK: - 窗口几何跟随

    private func observeWindowGeometry() {
        let center = NotificationCenter.default
        cancellables.insert(
            center.publisher(for: NSWindow.didMoveNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshCurrentHole() }
                }
        )
        cancellables.insert(
            center.publisher(for: NSWindow.didEndLiveResizeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshCurrentHole() }
                }
        )
    }

    /// 窗口移动/缩放后按登记的窗口本地矩形重新换算当前洞。
    private func refreshCurrentHole() {
        guard isTourActive else { return }
        computeUsableRect()
        guard let step = currentStep, let anchor = step.anchor else { return }
        guard let hole = resolveHole(anchor) else { return }
        currentHole = hole
    }
}

// MARK: - 完成状态持久化
// UserDefaults 单 key JSON：{ "<tourID>": "<seenAppVersion>#<contentVersion>" }。
// 重播条件 = App 版本跨过 3 个补丁版本，或 tour 的 contentVersion 高于已看值
// （内容修订 bump contentVersion 即可定向重播该 tour）。
// 注意：只在触发/收尾时惰性读写（GuideEngine 是懒加载单例，不在 init 里碰 UserDefaults）。

struct GuideProgressStore {
    private let defaults: UserDefaults
    private let key = "guide.progress.v2"
    private let legacyKey = "guide.progress.v1"
    /// 每 3 个补丁版本（VERSION 最后一段）重播一次。
    private static let replayVersionGap = 3

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 当前 App 版本（CFBundleShortVersionString，如 38.0.153）。
    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 距离上次观看是否已跨过 3 个补丁版本（跨大版本同样重播）。
    private static func gapReached(from seen: String, to current: String) -> Bool {
        let a = seen.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        guard a.count >= 2, b.count >= 2 else { return true }
        if a[0] != b[0] || a[1] != b[1] { return true }
        let seenPatch = a.count >= 3 ? a[2] : 0
        let currentPatch = b.count >= 3 ? b[2] : 0
        return currentPatch - seenPatch >= replayVersionGap
    }

    private func load() -> [String: String] {
        if let data = defaults.data(forKey: key),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            return map
        }
        // 迁移 v1（值是 contentVersion Int）：有记录即视为已在当前版本看过，
        // 之后每 3 个补丁版本再弹。
        guard let legacy = defaults.data(forKey: legacyKey),
              let old = try? JSONDecoder().decode([String: Int].self, from: legacy) else { return [:] }
        var migrated: [String: String] = [:]
        for (tourID, version) in old where version >= 0 {
            migrated[tourID] = "\(Self.currentVersion)#\(version)"
        }
        save(migrated)
        return migrated
    }

    private func save(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }

    /// 存储值 = "<seenAppVersion>#<contentVersion>"；旧值无 "#" 时 contentVersion 记 0，
    /// 因此把某 tour 的 contentVersion bump 到 ≥1 就能让存量用户重播一次。
    private static func splitRecord(_ raw: String) -> (version: String, content: Int) {
        guard let hash = raw.lastIndex(of: "#") else { return (raw, 0) }
        let version = String(raw[..<hash])
        let content = Int(raw[raw.index(after: hash)...]) ?? 0
        return (version, content)
    }

    func needsAutoplay(_ tour: GuideTour) -> Bool {
        guard let seen = load()[tour.id] else { return true }
        let record = Self.splitRecord(seen)
        if tour.contentVersion > record.content { return true }
        return Self.gapReached(from: record.version, to: Self.currentVersion)
    }

    func markCompleted(_ tour: GuideTour) {
        var map = load()
        map[tour.id] = "\(Self.currentVersion)#\(tour.contentVersion)"
        save(map)
    }

    /// Phase 3 设置页「全部重置」入口。
    func resetAll() {
        defaults.removeObject(forKey: key)
    }
}
