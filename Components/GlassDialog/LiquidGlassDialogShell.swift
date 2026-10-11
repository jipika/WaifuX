import SwiftUI

// MARK: - 统一玻璃弹窗按钮模型
/// role 决定玻璃样式与键盘快捷键；handler 在弹窗关闭后执行（cancel 也可以带清理闭包）
struct GlassAlertAction: Identifiable {
    enum Role {
        /// 中性玻璃 + Esc 取消
        case cancel
        /// 红色玻璃（删除/重置类）
        case destructive
        /// 普通玻璃；若为最后一个非 cancel 按钮，则自动升级为主操作样式（accent 玻璃 + Return）
        case plain
        /// 显式主操作（accent 玻璃 + Return），优先级高于「最后非 cancel」推断
        case primary
    }

    let id = UUID()
    let title: String
    let role: Role
    let handler: (() -> Void)?

    init(_ title: String, role: Role = .plain, handler: (() -> Void)? = nil) {
        self.title = title
        self.role = role
        self.handler = handler
    }

    /// 走系统原生 alert 时的按钮 role 映射：cancel 让系统接管 Esc，destructive 走系统红字；
    /// plain / primary 由系统按 alert 规则选默认按钮（不再由我们推断）
    var nativeRole: ButtonRole? {
        switch role {
        case .cancel:
            return .cancel
        case .destructive:
            return .destructive
        case .plain, .primary:
            return nil
        }
    }
}

// MARK: - 统一玻璃弹窗卡片
/// `.glassAlert` overlay 与 `GlassAlertCenter` 共用的卡片视觉，对齐 DisplaySelectorSheet 的玻璃语言
struct GlassAlertCard: View {
    let title: String
    var message: String? = nil
    var icon: String? = nil
    var iconTint: Color = LiquidGlassColors.primaryPink
    var actions: [GlassAlertAction] = []
    var accessory: AnyView? = nil
    let fire: (Int) -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            if let icon {
                ZStack {
                    Circle()
                        .fill(iconTint.opacity(0.15))
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
                .liquidGlassSurface(.regular, tint: iconTint.opacity(0.12), in: Circle())
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let accessory {
                accessory
            }

            actionButtons
        }
        .padding(20)
        .frame(width: 300)
        .liquidGlassSurface(.prominent, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.3), radius: 20, y: 8)
        .scaleEffect(appeared ? 1.0 : 0.92)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }

    // MARK: 按钮

    /// 按钮区：两个按钮并排（对齐系统 alert 的双按钮形态），其余情况纵列
    @ViewBuilder
    private var actionButtons: some View {
        if actions.count == 2 {
            HStack(spacing: 8) {
                button(at: 0)
                button(at: 1)
            }
        } else {
            VStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    alertButton(action, index: index) {
                        fire(index)
                    }
                }
            }
        }
    }

    private func button(at index: Int) -> some View {
        alertButton(actions[index], index: index) {
            fire(index)
        }
    }

    @ViewBuilder
    private func alertButton(_ action: GlassAlertAction, index: Int, onTap: @escaping () -> Void) -> some View {
        let base = Button {
            onTap()
        } label: {
            Text(action.title)
                .font(.system(size: 13, weight: isDefaultAction(action) ? .semibold : .medium))
                .foregroundStyle(buttonForeground(action))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .liquidGlassSurface(
                    surfaceLevel(for: action),
                    tint: surfaceTint(for: action),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(.plain)

        if action.role == .cancel {
            base.keyboardShortcut(.cancelAction)
        } else if isDefaultAction(action) {
            base.keyboardShortcut(.defaultAction)
        } else {
            base
        }
    }

    /// 主操作判定：显式 .primary 优先，否则取最后一个非 cancel 按钮（对齐系统 alert 的默认按钮位置）
    private func isDefaultAction(_ action: GlassAlertAction) -> Bool {
        if let explicit = actions.first(where: { $0.role == .primary }) {
            return explicit.id == action.id
        }
        guard actions.count > 1 else { return false }
        guard let lastNonCancel = actions.last(where: { $0.role != .cancel }) else { return false }
        return lastNonCancel.id == action.id
    }

    private func surfaceLevel(for action: GlassAlertAction) -> LiquidGlassLevel {
        switch action.role {
        case .cancel:
            return .regular
        case .plain:
            return isDefaultAction(action) ? .max : .regular
        case .destructive, .primary:
            return .max
        }
    }

    private func surfaceTint(for action: GlassAlertAction) -> Color? {
        switch action.role {
        case .cancel:
            return nil
        case .plain:
            // 主色调 0.45：原生 glassEffect 上 0.3 染色太淡，主按钮会失去辨识度
            return isDefaultAction(action) ? Color.accentColor.opacity(0.45) : nil
        case .destructive:
            return Color.red.opacity(0.45)
        case .primary:
            return Color.accentColor.opacity(0.45)
        }
    }

    private func buttonForeground(_ action: GlassAlertAction) -> Color {
        switch action.role {
        case .cancel:
            return LiquidGlassColors.textSecondary
        case .plain:
            return isDefaultAction(action) ? .white : LiquidGlassColors.textPrimary
        case .destructive:
            return Color.red
        case .primary:
            return .white
        }
    }
}

// MARK: - 应用内玻璃卡片弹层
/// 与 DisplaySelectorSheet 同款呈现：背景压暗 + 居中玻璃卡片悬浮在当前视图内容上，
/// macOS 26 原生 glassEffect 可真实采样背后内容。替代 .sheet 承载玻璃弹窗
/// （sheet 是独立窗口，原生玻璃在窗口内采样不到主界面）。
struct GlassOverlayCardShell<Card: View>: View {
    /// 点击压暗背景时触发；传 nil 则背景点击无效（多选等不能误触丢弃状态的场景）
    var backdropTapToDismiss: (() -> Void)? = nil
    @ViewBuilder let card: () -> Card

    @State private var appeared = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.38))
                .contentShape(Rectangle())
                .onTapGesture { backdropTapToDismiss?() }

            card()
                .scaleEffect(appeared ? 1.0 : 0.92)
                .opacity(appeared ? 1.0 : 0.0)
                .onAppear {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        appeared = true
                    }
                }
        }
        .transition(.opacity)
        .onExitCommand { backdropTapToDismiss?() }
    }
}
