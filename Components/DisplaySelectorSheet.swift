import SwiftUI
import AppKit

// MARK: - 显示器选择弹窗 - 液态玻璃风格
struct DisplaySelectorSheet: View {
    let title: String
    let message: String
    let allowsBackgroundDismiss: Bool
    let onSelect: (NSScreen?) -> Void
    let onCancel: () -> Void

    @State private var isVisible = false
    @State private var selectedScreenID: String? = nil
    @State private var pendingScreenID: String?
    @State private var isShowingDisableSyncConfirmation = false
    @ObservedObject private var scheduler = WallpaperSchedulerService.shared

    private var screens: [NSScreen] {
        NSScreen.screens
    }

    /// 根据 ID 获取对应的屏幕
    private func screen(forID id: String?) -> NSScreen? {
        guard let id = id else { return nil }
        return screens.first { $0.screenIdentifier == id }
    }

    var body: some View {
        ZStack {
            // 半透明背景
            Color.black
                .opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    if allowsBackgroundDismiss {
                        dismiss()
                    }
                }

            // 弹窗内容
            selectorContent

            if isShowingDisableSyncConfirmation {
                disableSyncConfirmation
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .zIndex(1)
            }
        }
    }

    private var selectorContent: some View {
        VStack(spacing: 20) {
                // 标题
                VStack(spacing: 8) {
                    Image(systemName: "display.2")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Color.accentColor)

                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.textPrimary)

                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }

                // 显示器选择按钮
                VStack(spacing: 12) {
                    // 所有显示器选项
                    DisplayOptionButton(
                        icon: "display",
                        title: t("allDisplays"),
                        subtitle: "\(screens.count) \(t("screensCount"))",
                        isSelected: selectedScreenID == nil,
                        action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedScreenID = nil
                            }
                        }
                    )

                    // 单个显示器选项
                    ForEach(Array(screens.enumerated()), id: \.element.screenIdentifier) { index, screen in
                        DisplayOptionButton(
                            icon: "display",
                            title: "\(t("display")) \(index + 1)",
                            subtitle: screen.localizedName,
                            isSelected: selectedScreenID == screen.screenIdentifier,
                            isRestricted: scheduler.config.syncAllDisplays,
                            action: {
                                guard scheduler.config.syncAllDisplays else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        selectedScreenID = screen.screenIdentifier
                                    }
                                    return
                                }
                                pendingScreenID = screen.screenIdentifier
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    isShowingDisableSyncConfirmation = true
                                }
                            }
                        )
                    }
                }
                .frame(maxWidth: 320)

                // 操作按钮
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Text(t("cancel"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(LiquidGlassColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .liquidGlassSurface(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        confirmSelection()
                    } label: {
                        Text(t("confirm"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .liquidGlassSurface(
                                .max,
                                tint: Color.accentColor.opacity(0.3),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 320)
            }
        .padding(24)
        .frame(maxWidth: 360)
        .liquidGlassSurface(
            .prominent,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .scaleEffect(isVisible ? 1.0 : 0.88)
        .opacity(isVisible ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isVisible = true
            }
        }
    }

    private var disableSyncConfirmation: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isShowingDisableSyncConfirmation = false
                    }
                }

            VStack(spacing: 18) {
                Image(systemName: "display.2")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.accentColor)

                Text("是否关闭同步所有显示器设定")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button(t("cancel")) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isShowingDisableSyncConfirmation = false
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .liquidGlassSurface(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Button(t("confirm")) {
                        scheduler.updateSyncAllDisplays(false)
                        selectedScreenID = pendingScreenID
                        pendingScreenID = nil
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isShowingDisableSyncConfirmation = false
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .liquidGlassSurface(
                        .max,
                        tint: Color.accentColor.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
            }
            .padding(22)
            .frame(width: 310)
            .liquidGlassSurface(.prominent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onCancel()
        }
    }

    private func confirmSelection() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onSelect(screen(forID: selectedScreenID))
        }
    }
}

// MARK: - 显示器选项按钮
private struct DisplayOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    var isRestricted: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 图标
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isRestricted ? LiquidGlassColors.textQuaternary : (isSelected ? Color.accentColor : LiquidGlassColors.textSecondary))
                    .frame(width: 36, height: 36)
                    .liquidGlassSurface(
                        isSelected ? .prominent : .subtle,
                        tint: isSelected ? Color.accentColor.opacity(0.15) : nil,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                // 文字
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isRestricted ? LiquidGlassColors.textQuaternary : (isSelected ? LiquidGlassColors.textPrimary : LiquidGlassColors.textSecondary))

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(LiquidGlassColors.textQuaternary)
                }

                Spacer()

                // 选中指示器
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .liquidGlassSurface(
                isSelected ? .prominent : (isHovered ? .regular : .subtle),
                tint: isSelected ? Color.accentColor.opacity(0.1) : nil,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.3) : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .opacity(isRestricted ? 0.48 : 1)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 显示器选择弹窗管理器
@MainActor
class DisplaySelectorManager: ObservableObject {
    static let shared = DisplaySelectorManager()

    @Published var isShowingSelector = false
    @Published private(set) var selectorTitle: String = ""
    @Published private(set) var selectorMessage: String = ""
    @Published private(set) var allowsBackgroundDismiss = false

    private var completionHandler: ((NSScreen?) -> Void)?

    private init() {}

    /// 显示显示器选择弹窗
    /// - Parameters:
    ///   - title: 弹窗标题
    ///   - message: 弹窗消息
    ///   - completion: 选择完成回调，参数为选中的屏幕，nil 表示所有屏幕
    func showSelector(
        title: String,
        message: String,
        allowsBackgroundDismiss: Bool = false,
        completion: @escaping (NSScreen?) -> Void
    ) {
        self.completionHandler = completion
        self.selectorTitle = title
        self.selectorMessage = message
        self.allowsBackgroundDismiss = allowsBackgroundDismiss
        self.isShowingSelector = true
    }

    func handleSelection(_ screen: NSScreen?) {
        isShowingSelector = false
        completionHandler?(screen)
        completionHandler = nil
    }

    func handleCancel() {
        isShowingSelector = false
        completionHandler = nil
    }

    /// 主窗口进入后台极致释放时清掉待执行闭包，避免闭包继续持有详情页或 ViewModel。
    func cancelForMemoryRelease() {
        selectorTitle = ""
        selectorMessage = ""
        allowsBackgroundDismiss = false
        isShowingSelector = false
        completionHandler = nil
    }
}

// MARK: - 便捷扩展
extension View {
    /// 添加显示器选择弹窗覆盖层
    func displaySelectorOverlay() -> some View {
        self.overlay {
            DisplaySelectorOverlay()
        }
    }
}

// MARK: - 显示器选择弹窗覆盖层
public struct DisplaySelectorOverlay: View {
    @ObservedObject private var manager = DisplaySelectorManager.shared

    public var body: some View {
        Group {
            if manager.isShowingSelector {
                DisplaySelectorSheet(
                    title: manager.selectorTitle.isEmpty ? t("selectDisplay") : manager.selectorTitle,
                    message: manager.selectorMessage.isEmpty ? t("selectDisplayMessage") : manager.selectorMessage,
                    allowsBackgroundDismiss: manager.allowsBackgroundDismiss,
                    onSelect: { screen in
                        manager.handleSelection(screen)
                    },
                    onCancel: {
                        manager.handleCancel()
                    }
                )
                .transition(.opacity)
                // 每次弹出时用 id 强制重建 View，确保 selectedScreen 重置为默认值（nil = 所有显示器）
                .id(manager.selectorTitle + manager.selectorMessage)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: manager.isShowingSelector)
    }
}

// MARK: - 私有屏幕标识符扩展
private extension NSScreen {
    var screenIdentifier: String {
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return screenNumber.stringValue
        }
        return localizedName + ":\(frame.origin.x):\(frame.origin.y)"
    }
}


// MARK: - 预览
#Preview {
    ZStack {
        LiquidGlassColors.deepBackground
            .ignoresSafeArea()

        DisplaySelectorSheet(
            title: t("displaySelector.title"),
            message: t("displaySelector.message"),
            allowsBackgroundDismiss: false,
            onSelect: { screen in
                print("Selected screen: \(screen?.localizedName ?? "All")")
            },
            onCancel: {
                print("Cancelled")
            }
        )
    }
}
