import SwiftUI
import AppKit

// MARK: - 显示器选择弹窗 - 液态玻璃风格
struct DisplaySelectorSheet: View {
    let title: String
    let message: String
    let onSelect: (NSScreen?) -> Void
    let onCancel: () -> Void
    
    @State private var isVisible = false
    @State private var selectedScreen: NSScreen?
    
    private var screens: [NSScreen] {
        NSScreen.screens
    }
    
    private var hasMultipleDisplays: Bool {
        screens.count > 1
    }
    
    var body: some View {
        ZStack {
            // 半透明背景
            Color.black
                .opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }
            
            // 弹窗内容
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
                        isSelected: selectedScreen == nil,
                        action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedScreen = nil
                            }
                        }
                    )
                    
                    // 单个显示器选项
                    ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                        DisplayOptionButton(
                            icon: "display",
                            title: "\(t("display")) \(index + 1)",
                            subtitle: screen.localizedName,
                            isSelected: selectedScreen == screen,
                            action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedScreen = screen
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
            onSelect(selectedScreen)
        }
    }
}

// MARK: - 显示器选项按钮
private struct DisplayOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 图标
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : LiquidGlassColors.textSecondary)
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
                        .foregroundStyle(isSelected ? LiquidGlassColors.textPrimary : LiquidGlassColors.textSecondary)
                    
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
    
    private var completionHandler: ((NSScreen?) -> Void)?
    
    private init() {}
    
    /// 显示显示器选择弹窗
    /// - Parameters:
    ///   - title: 弹窗标题
    ///   - message: 弹窗消息
    ///   - completion: 选择完成回调，参数为选中的屏幕，nil 表示所有屏幕
    func showSelector(title: String, message: String, completion: @escaping (NSScreen?) -> Void) {
        self.completionHandler = completion
        self.selectorTitle = title
        self.selectorMessage = message
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
    @StateObject private var manager = DisplaySelectorManager.shared
    
    public var body: some View {
        Group {
            if manager.isShowingSelector {
                DisplaySelectorSheet(
                    title: manager.selectorTitle.isEmpty ? t("selectDisplay") : manager.selectorTitle,
                    message: manager.selectorMessage.isEmpty ? t("selectDisplayMessage") : manager.selectorMessage,
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



// MARK: - 预览
#Preview {
    ZStack {
        LiquidGlassColors.deepBackground
            .ignoresSafeArea()
        
        DisplaySelectorSheet(
            title: "设置壁纸",
            message: "检测到多个显示器，请选择要设置的显示器",
            onSelect: { screen in
                print("Selected screen: \(screen?.localizedName ?? "All")")
            },
            onCancel: {
                print("Cancelled")
            }
        )
    }
}
