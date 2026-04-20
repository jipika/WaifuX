import SwiftUI
import AppKit

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
    let onOpenSettings: () -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onMaximize: () -> Void
    
    private let controlHeight: CGFloat = 34

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // 左侧红绿灯 - 固定宽高，内容居中
            CustomWindowControls(
                onClose: onClose,
                onMinimize: onMinimize,
                onMaximize: onMaximize
            )
            .frame(width: 80, height: controlHeight, alignment: .center)

            Spacer()

            // 中间 Tabs - 固定高度，垂直居中
            TopBarSegmentedControl(
                selectedTab: $selectedTab,
                controlHeight: controlHeight
            )
            .frame(height: controlHeight, alignment: .center)

            Spacer()

            // 右侧设置按钮 - 固定宽高，内容居中
            TopBarCircleButton(icon: "gearshape", size: controlHeight) {
                onOpenSettings()
            }
            .frame(width: 48, height: controlHeight, alignment: .center)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

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
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(Color.clear)
                        .frame(width: size + 16, height: size + 16)
                )
                .contentShape(Circle())
                .detailGlassCircleChrome()
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .frame(width: size + 16, height: size + 16)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
    }
}

private struct TopBarSegmentedControl: View {
    @Binding var selectedTab: MainTab
    let controlHeight: CGFloat

    @Namespace private var selectionNamespace
    @State private var hoveredTab: MainTab?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(MainTab.allCases, id: \.self) { tab in
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
        .liquidGlassSurface(.prominent, tint: Color.black.opacity(0.25), in: Capsule(style: .continuous))
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
                .liquidGlassSurface(.max, tint: Color.black.opacity(0.3), in: Capsule(style: .continuous))
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
