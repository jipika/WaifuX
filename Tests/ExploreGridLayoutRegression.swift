import AppKit

// 仅满足生产 ExploreGridScrollView 弱引用的协调器接口；不实例化完整生产协调器。
@MainActor
final class ExploreGridCoordinator: NSObject {
    func handleHeaderPhaseScrollWheel(_ event: NSEvent) -> Bool { false }
    func scrollingWillBeginOrContinue() {}
    func viewportDidResize() {}
    func visibilityDidChange(isVisible: Bool) {}
}

@MainActor
private final class GridLayoutDelegate: NSObject, ExploreGridCollectionViewLayoutDelegate {
    func collectionView(_ collectionView: NSCollectionView, aspectRatioForItemAt indexPath: IndexPath) -> CGFloat {
        indexPath.item.isMultiple(of: 3) ? 0.75 : 1.5
    }
}

@MainActor
private final class GridDataSource: NSObject, NSCollectionViewDataSource {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { 240 }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = NSCollectionViewItem()
        item.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 180))
        return item
    }
}

@main
@MainActor
private struct ExploreGridLayoutRegression {
    static func main() {
        print("stage: application")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        print("stage: scroll view")
        let scrollView = ExploreGridScrollView()
        let collectionView = NSCollectionView()
        let layout = ExploreGridCollectionViewLayout()
        let layoutDelegate = GridLayoutDelegate()
        let dataSource = GridDataSource()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = dataSource
        layout.delegate = layoutDelegate
        scrollView.documentView = collectionView
        // 与生产 init 完全相同：滚动条只在配置入口设置。
        let invisibleV = ExploreGridInvisibleScroller()
        invisibleV.scrollerStyle = .overlay
        let invisibleH = ExploreGridInvisibleScroller()
        invisibleH.scrollerStyle = .overlay
        scrollView.verticalScroller = invisibleV
        scrollView.horizontalScroller = invisibleH
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        let coordinator = ExploreGridCoordinator()
        scrollView.gridCoordinator = coordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.contentView = scrollView
        // 普通离屏测试窗口，不是壁纸窗口；不写桌面、不接触生产 Helper。
        window.orderBack(nil)
        print("stage: window ordered")
        let sizes = [
            NSSize(width: 960, height: 720), NSSize(width: 480, height: 600),
            NSSize(width: 1280, height: 800), NSSize(width: 700, height: 500),
        ]
        for iteration in 0..<120 {
            if iteration.isMultiple(of: 10) { print("stage: iteration \(iteration)") }
            window.setContentSize(sizes[iteration % sizes.count])
            scrollView.layoutSubtreeIfNeeded()
            let travel = max(0, collectionView.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: travel * CGFloat(iteration % 11) / 10))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            if iteration.isMultiple(of: 12) { collectionView.reloadData() }
            window.displayIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        precondition(collectionView.numberOfItems(inSection: 0) == 240)
        // AppKit 会在内容溢出时自动重挂 scroller 开关（这正是旧 tile() 覆写想对抗、
        // 结果引发递归崩溃的行为）。真正的视觉/命中不变量是：挂上的滚动条
        // 必须是隐形占位类——不绘制、不响应命中。hitTest 取 scroller 自身
        // bounds 中心，保证探测点真实落在滚动条上而非恒空。
        if let v = scrollView.verticalScroller {
            precondition(v is ExploreGridInvisibleScroller, "vertical scroller must stay invisible placeholder")
            let center = NSPoint(x: v.bounds.midX, y: v.bounds.midY)
            precondition(v.hitTest(center) == nil, "invisible scroller must not hit-test")
        }
        precondition(scrollView.horizontalScroller is ExploreGridInvisibleScroller || scrollView.horizontalScroller == nil,
                     "horizontal scroller must stay invisible placeholder or absent")
        precondition(collectionView.collectionViewLayout === layout)
        window.orderOut(nil)
        window.contentView = nil
        print("ExploreGridLayoutRegression: production scroll view/layout survived 120 resize+scroll+tile cycles")
    }
}

