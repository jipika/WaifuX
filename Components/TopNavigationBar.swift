import SwiftUI
import AppKit

enum MainTopBarLayout {
    static let legacyContentTopPadding: CGFloat = 80
}

private struct MainTopBarContentPaddingKey: EnvironmentKey {
    static let defaultValue: CGFloat = MainTopBarLayout.legacyContentTopPadding
}

extension EnvironmentValues {
    var mainTopBarContentPadding: CGFloat {
        get { self[MainTopBarContentPaddingKey.self] }
        set { self[MainTopBarContentPaddingKey.self] = newValue }
    }
}

// MARK: - 主标签类型
public enum MainTab: String, CaseIterable {
    case home, wallpaperExplore, mediaExplore, animeExplore, myMedia

    var title: String {
        switch self {
        case .home: return t("nav.home")
        case .wallpaperExplore: return t("nav.wallpaper")
        case .animeExplore: return t("nav.anime")
        case .mediaExplore: return t("nav.media")
        case .myMedia: return t("nav.myMedia")
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .wallpaperExplore: return "photo"
        case .animeExplore: return "play.tv"
        case .mediaExplore: return "film"
        case .myMedia: return "heart"
        }
    }
}

// MARK: - 顶部导航栏组件
struct TopNavigationBar: View {
    @Binding var selectedTab: MainTab
    var isChromeHidden: Bool = false
    let onOpenSettings: () -> Void
    let onGuessYouLike: () -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onMaximize: () -> Void
    let onZoom: () -> Void

    @State private var showHelpPopover = false
    private let controlHeight: CGFloat = 34

    private static let lastTutorialVersionKey = "lastShownTutorialVersion"

    var body: some View {
        ZStack {
            // 底层：左右按钮各自靠边
            HStack(alignment: .center, spacing: 0) {
                // 左侧红绿灯 - 固定宽高，内容居中
                CustomWindowControls(
                    onClose: onClose,
                    onMinimize: onMinimize,
                    onMaximize: onMaximize
                )
                .frame(width: 80, height: controlHeight, alignment: .center)

                Spacer()

                // 右侧按钮组
                HStack(spacing: 8) {
                    // 猜你喜欢按钮
                    GuessYouLikeNavButton(action: onGuessYouLike)

                    // 帮助按钮（操作手册）
                    TopBarCircleButton(icon: "questionmark", size: controlHeight) {
                        showHelpPopover.toggle()
                    }
                    .popover(isPresented: $showHelpPopover, arrowEdge: .bottom) {
                        HelpPopoverView(isPresented: $showHelpPopover)
                    }

                    // 设置按钮
                    TopBarCircleButton(icon: "gearshape", size: controlHeight) {
                        onOpenSettings()
                    }
                }
                .opacity(isChromeHidden ? 0 : 1)
                .allowsHitTesting(!isChromeHidden)
            }

            // 顶层：Tabs 绝对居中于整个顶栏宽度
            // （不受左侧红绿灯 80pt 与右侧按钮组约 180pt 宽度不对称的影响）
            TopBarSegmentedControl(
                selectedTab: $selectedTab,
                controlHeight: controlHeight
            )
            .frame(height: controlHeight, alignment: .center)
            .opacity(isChromeHidden ? 0 : 1)
            .allowsHitTesting(!isChromeHidden)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { _ in onZoom() }
        )
        .onAppear {
            checkAndShowTutorialOnNewVersion()
        }
    }

    /// 新版本首次启动时自动弹出使用教程
    private func checkAndShowTutorialOnNewVersion() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let lastVersion = UserDefaults.standard.string(forKey: Self.lastTutorialVersionKey) ?? ""
        guard !currentVersion.isEmpty else { return }
        if currentVersion != lastVersion {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                showHelpPopover = true
            }
            UserDefaults.standard.set(currentVersion, forKey: Self.lastTutorialVersionKey)
        }
    }
}

// MARK: - 红绿灯按钮组
struct CustomWindowControls: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onMaximize: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            WindowControlButton(
                fillColor: Color(hex: "FF5F57"),
                symbol: "xmark",
                action: onClose
            )
            WindowControlButton(
                fillColor: Color(hex: "FFBD2E"),
                symbol: "minus",
                action: onMinimize
            )
            WindowControlButton(
                fillColor: Color(hex: "28C840"),
                symbol: "plus",
                action: onMaximize
            )
        }
    }

    /// 主窗口红绿灯（关闭=隐藏主窗口，黄=最小化，绿=全屏）
    static func mainWindow() -> CustomWindowControls {
        CustomWindowControls(
            onClose: {
                (NSApp.delegate as? AppDelegate)?.hideMainWindow()
            },
            onMinimize: {
                NSApp.mainWindow?.miniaturize(nil)
            },
            onMaximize: {
                NSApp.mainWindow?.toggleFullScreen(nil)
            }
        )
    }
}

// MARK: - 详情页顶部栏布局
/// 红绿灯独占窗口标题栏一行；返回/右侧工具在其下方，避免并排。
enum DetailSheetTopBarLayout {
    static let windowControlsTop: CGFloat = 12
    static let windowControlsLeading: CGFloat = 12
    static let windowControlsHeight: CGFloat = 34
    /// 红绿灯行底边 + 与主顶栏 bottom 10 对齐的间距
    static let actionRowTop: CGFloat = windowControlsTop + windowControlsHeight + 10 // 56
    static let actionRowLeading: CGFloat = 28
    static let actionRowTrailing: CGFloat = 20
    /// Hero 内容相对窗口顶部的预留（动作行 + 按钮高度余量）
    static let heroContentTop: CGFloat = actionRowTop + 44 // 100
}

// MARK: - 详情页顶部红绿灯
/// 贴在窗口标题栏区域；返回按钮等动作控件使用 `DetailSheetTopBarLayout.actionRowTop` 另起一行。
struct DetailSheetWindowControls: View {
    var body: some View {
        CustomWindowControls.mainWindow()
            .frame(
                width: 80,
                height: DetailSheetTopBarLayout.windowControlsHeight,
                alignment: .center
            )
            .padding(.top, DetailSheetTopBarLayout.windowControlsTop)
            .padding(.leading, DetailSheetTopBarLayout.windowControlsLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(true)
    }
}

struct WindowControlButton: View {
    let fillColor: Color
    let symbol: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fillColor.opacity(isHovered ? 0.95 : 0.88))
                .frame(width: 13, height: 13)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                )
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.black.opacity(isHovered ? 0.58 : 0.0))
                }
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

private struct TopBarCircleButton: View {
    let icon: String
    let size: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 1.0 : 0.88))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .background { Circle().fill(topBarBaseColor(isHovered: isHovered)) }
                .detailGlassCircleChrome(
                    tint: Color.white.opacity(isHovered ? 0.16 : 0.09),
                    level: .max
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 猜你喜欢导航按钮（与设置按钮相同液态玻璃风格）

struct GuessYouLikeNavButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                Text(t("common.youMayLike"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(isHovered ? 0.96 : 0.82))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background { Capsule().fill(topBarBaseColor(isHovered: isHovered)) }
            .detailGlassCapsuleChrome(
                tint: Color.white.opacity(isHovered ? 0.16 : 0.09),
                level: .max
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.025 : 1.0)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
    }
}

private func topBarBaseColor(isHovered: Bool) -> Color {
    Color(
        red: isHovered ? 0.34 : 0.25,
        green: isHovered ? 0.34 : 0.25,
        blue: isHovered ? 0.34 : 0.25
    )
}

// MARK: - 帮助/操作手册弹窗

struct HelpPopoverView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(t("tutorial.title"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push(); return }
                    NSCursor.pop()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 第1节：网络与数据源
                    tutorialSection(
                        icon: "globe",
                        title: t("tutorial.network.title"),
                        lines: [
                            t("tutorial.network.l1"),
                            t("tutorial.network.l2"),
                            t("tutorial.network.l3"),
                            t("tutorial.network.l5"),
                            t("tutorial.network.l6"),
                            t("tutorial.network.l7"),
                            t("tutorial.network.l8"),
                            t("tutorial.network.l9")
                        ]
                    )

                    // 第2节：壁纸引擎
                    tutorialSection(
                        icon: "rectangle.and.text.magnifyingglass",
                        title: t("tutorial.we.title"),
                        lines: [
                            t("tutorial.we.l1"),
                            t("tutorial.we.l2"),
                            t("tutorial.we.l3")
                        ]
                    )

                    // 第3节：设置功能
                    tutorialSection(
                        icon: "gearshape.2",
                        title: t("tutorial.settings.title"),
                        lines: [
                            t("tutorial.settings.l1"),
                            t("tutorial.settings.l2"),
                            t("tutorial.settings.l3"),
                            t("tutorial.settings.l4"),
                            t("tutorial.settings.l5"),
                            t("tutorial.settings.l6"),
                            t("tutorial.settings.l7")
                        ]
                    )

                    // 第4节：我的库与导入
                    tutorialSection(
                        icon: "tray.and.arrow.down.fill",
                        title: t("tutorial.library.title"),
                        lines: [
                            t("tutorial.library.l1"),
                            t("tutorial.library.l2"),
                            t("tutorial.library.l3"),
                            t("tutorial.library.l4"),
                            t("tutorial.library.l5"),
                            t("tutorial.library.l6"),
                            t("tutorial.library.l7"),
                            t("tutorial.library.l8"),
                            t("tutorial.library.l9")
                        ]
                    )

                    // 第5节：壁纸详情
                    tutorialSection(
                        icon: "doc.text.magnifyingglass",
                        title: t("tutorial.detail.title"),
                        lines: [
                            t("tutorial.detail.l1"),
                            t("tutorial.detail.l2"),
                            t("tutorial.detail.l3"),
                            t("tutorial.detail.l4"),
                            t("tutorial.detail.l5")
                        ]
                    )

                    // 第6节：场景/Web壁纸编辑
                    tutorialSection(
                        icon: "pencil.and.outline",
                        title: t("tutorial.sceneWeb.title"),
                        lines: [
                            t("tutorial.sceneWeb.l1"),
                            t("tutorial.sceneWeb.l2"),
                            t("tutorial.sceneWeb.l3"),
                            t("tutorial.sceneWeb.l4"),
                            t("tutorial.sceneWeb.l5"),
                            t("tutorial.sceneWeb.l6")
                        ]
                    )

                    // 第7节：动态锁屏
                    tutorialSection(
                        icon: "lock.display",
                        title: t("tutorial.lockScreen.title"),
                        lines: [
                            t("tutorial.lockScreen.l1"),
                            t("tutorial.lockScreen.l2"),
                            t("tutorial.lockScreen.l3"),
                            t("tutorial.lockScreen.l4"),
                            t("tutorial.lockScreen.l5"),
                            t("tutorial.lockScreen.l6")
                        ]
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            }
            .frame(width: 340, height: 400)

            // 底部提示
            VStack(spacing: 4) {
                Text(t("tutorial.closeHint"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func tutorialSection(icon: String, title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: "7C8DFF").opacity(0.9))
                    .frame(width: 20, alignment: .center)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

private struct TopBarSegmentedControl: View {
    @Binding var selectedTab: MainTab
    let controlHeight: CGFloat

    @Namespace private var selectionNamespace
    @State private var hoveredTab: MainTab?

    var body: some View {
        HStack(spacing: 6) {
            // 仅显示启动快照启用的 tab（home/myMedia 永远显示；三个 Explore 受功能模块开关门控）
            ForEach(MainTab.allCases.filter { ModuleAvailability.shared.isTabEnabled($0) }, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(labelColor(for: tab))
                        .frame(width: itemWidth(for: tab), height: controlHeight - 8)
                        .background {
                            if selectedTab == tab {
                                selectedTabGlass(for: tab)
                            } else if hoveredTab == tab {
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            }
                        }
                }
                .buttonStyle(.plain)
                .contentShape(Capsule(style: .continuous))
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.16)) {
                        hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .liquidGlassSurface(.prominent, tint: Color.black.opacity(0.18), in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private func itemWidth(for tab: MainTab) -> CGFloat {
        return 76
    }

    private func labelColor(for tab: MainTab) -> Color {
        if selectedTab == tab {
            return .white.opacity(0.96)
        }
        if hoveredTab == tab {
            return .white.opacity(0.86)
        }
        return .white.opacity(0.72)
    }

    @ViewBuilder
    private func selectedTabGlass(for tab: MainTab) -> some View {
        if #available(macOS 26.0, *) {
            // macOS 26: 使用原生玻璃效果
            Capsule(style: .continuous)
                .liquidGlassSurface(.max, tint: Color.black.opacity(0.18), in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.34),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                .matchedGeometryEffect(id: "topBarSelectedTabGlass", in: selectionNamespace)
        } else {
            // macOS 14/15: 使用深色毛玻璃效果
            ZStack {
                Capsule(style: .continuous)
                    .fill(.ultraThickMaterial.opacity(0.9))

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "1A1A2E").opacity(0.5),
                                Color(hex: "12121F").opacity(0.6)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.12),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.25),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            .matchedGeometryEffect(id: "topBarSelectedTabGlass", in: selectionNamespace)
        }
    }
}
