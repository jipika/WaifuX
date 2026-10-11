import SwiftUI

// MARK: - 呈现方式
/// `.glassAlert` 的呈现方式
enum GlassAlertStyle {
    /// 自动（默认）：能用系统原生 alert 就用系统 alert，否则退回自绘玻璃卡片
    case auto
    /// 强制自绘玻璃卡片（需要自定义图标、按钮数量不受限等场景）
    case glass
    /// 强制系统原生 alert（此时 `icon` 参数会被忽略：原生 alert 没有自定义图标位）
    case native
}

// MARK: - .glassAlert 修饰符
/// 默认「原生优先」：能用系统 `.alert` 的场景交给系统 —— macOS 26+ 的系统 alert 本身就是
/// Liquid Glass 材质，材质与按钮语言跟着系统走；不能用的场景（带自定义图标 / 按钮 >2）
/// 退回自绘玻璃卡片，布局对齐系统 alert 的紧凑语言。
/// 调用点迁移 = 把 `.alert(_:isPresented:actions:message:)` 换成
/// `.glassAlert(_:isPresented:message:actions:)`，按钮改用 GlassAlertAction 数组表达。
private struct GlassAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    var message: String?
    var icon: String?
    var iconTint: Color
    var style: GlassAlertStyle
    let actions: [GlassAlertAction]

    /// 是否走系统原生 alert。判定只依赖调用点传入的静态参数（style / icon / 按钮数），
    /// 运行期不会翻转，因此下面 if/else 的两条分支不会造成视图身份反复重建。
    private var usesNativeAlert: Bool {
        switch style {
        case .native:
            return true
        case .glass:
            return false
        case .auto:
            // 原生 alert 没有自定义图标位；按钮 ≤2 才交给系统（≥3 个保持自绘纵列）
            return icon == nil && !actions.isEmpty && actions.count <= 2
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesNativeAlert {
            // 标题/消息用 StringProtocol 版本：t() 已本地化过，不能再被 LocalizedStringKey 查一次表
            content.alert(title, isPresented: $isPresented) {
                nativeActions
            } message: {
                if let message, !message.isEmpty {
                    Text(message)
                }
            }
        } else {
            content
                .overlay {
                    if isPresented {
                        glassOverlay
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: isPresented)
        }
    }

    /// 自绘玻璃卡片（原路径保持不变）
    private var glassOverlay: some View {
        GlassAlertDimmedCard(
            title: title,
            message: message,
            icon: icon,
            iconTint: iconTint,
            actions: actions
        ) { index in
            let action = actions[index]
            withAnimation(.easeInOut(duration: 0.15)) {
                isPresented = false
            }
            // 关闭动画之外执行回调，避免 handler 引发的界面变化被卷入 withAnimation
            if let handler = action.handler {
                DispatchQueue.main.async(execute: handler)
            }
        }
        .transition(.opacity)
    }

    /// 原生 alert 的按钮：显式枚举前两个，不用 ForEach（alert 的 actions 里 ForEach
    /// 存在漏按钮/顺序问题）。文案走 StringProtocol 版本，避免 t() 已本地化的字符串
    /// 被 LocalizedStringKey 再查找一次。
    @ViewBuilder
    private var nativeActions: some View {
        if actions.count == 1 {
            nativeButton(actions[0])
        } else if actions.count >= 2 {
            nativeButton(actions[0])
            nativeButton(actions[1])
        }
    }

    private func nativeButton(_ action: GlassAlertAction) -> some View {
        // 系统保证 alert 关闭后才执行 action，与自绘路径「先关再执行 handler」的语义一致
        Button(action.title, role: action.nativeRole) {
            action.handler?()
        }
    }
}

/// 背景压暗 + 玻璃卡片的组合，GlassAlertCenter 也复用
struct GlassAlertDimmedCard: View {
    let title: String
    var message: String?
    var icon: String?
    var iconTint: Color
    var actions: [GlassAlertAction]
    var accessory: AnyView? = nil
    let fire: (Int) -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.38))
                .contentShape(Rectangle())
                .onTapGesture {} // 吞掉背景点击，防止误触弹窗后面的控件

            GlassAlertCard(
                title: title,
                message: message,
                icon: icon,
                iconTint: iconTint,
                actions: actions,
                accessory: accessory,
                fire: fire
            )
        }
        .transition(.opacity)
    }
}

extension View {
    func glassAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        icon: String? = nil,
        iconTint: Color = LiquidGlassColors.primaryPink,
        style: GlassAlertStyle = .auto,
        actions: [GlassAlertAction]
    ) -> some View {
        modifier(
            GlassAlertModifier(
                isPresented: isPresented,
                title: title,
                message: message,
                icon: icon,
                iconTint: iconTint,
                style: style,
                actions: actions
            )
        )
    }
}

// MARK: - GlassAlertCenter
/// 无 SwiftUI 上下文（Service 层）的玻璃 alert 中转：present 入队，窗口根部挂
/// `glassAlertCenterOverlay()` 呈现。同一时刻只显示一条，关闭后自动展示下一条。
@MainActor
final class GlassAlertCenter: ObservableObject {
    static let shared = GlassAlertCenter()

    struct Request: Identifiable {
        let id = UUID()
        let title: String
        var message: String?
        var icon: String?
        var iconTint: Color
        var actions: [GlassAlertAction]
        var accessory: AnyView?
    }

    @Published private(set) var current: Request?

    private var queue: [Request] = []

    private init() {}

    func present(
        title: String,
        message: String? = nil,
        icon: String? = nil,
        iconTint: Color = LiquidGlassColors.primaryPink,
        accessory: AnyView? = nil,
        actions: [GlassAlertAction]
    ) {
        let request = Request(
            title: title,
            message: message,
            icon: icon,
            iconTint: iconTint,
            actions: actions,
            accessory: accessory
        )
        if current == nil {
            current = request
        } else {
            queue.append(request)
        }
    }

    func handleTap(at index: Int) {
        guard let request = current, request.actions.indices.contains(index) else { return }
        let action = request.actions[index]
        current = queue.isEmpty ? nil : queue.removeFirst()
        if let handler = action.handler {
            DispatchQueue.main.async(execute: handler)
        }
    }

    /// 主窗口极致释放等场景清空待处理请求，避免闭包继续持有旧界面上下文
    func cancelAll() {
        queue.removeAll()
        current = nil
    }
}

// MARK: - Center 呈现层
struct GlassAlertCenterOverlay: View {
    @ObservedObject private var center = GlassAlertCenter.shared

    var body: some View {
        ZStack {
            if let request = center.current {
                GlassAlertDimmedCard(
                    title: request.title,
                    message: request.message,
                    icon: request.icon,
                    iconTint: request.iconTint,
                    actions: request.actions,
                    accessory: request.accessory
                ) { index in
                    center.handleTap(at: index)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: center.current?.id)
    }
}

extension View {
    /// 挂在窗口根视图（与 displaySelectorOverlay 同位），GlassAlertCenter.present 的内容在这里呈现
    func glassAlertCenterOverlay() -> some View {
        overlay {
            GlassAlertCenterOverlay()
        }
    }
}
