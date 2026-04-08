import SwiftUI
import AppKit

// MARK: - 液态玻璃背景 (macOS 26 超写实玻璃)
struct LiquidGlassBackgroundView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    init(material: NSVisualEffectView.Material = .hudWindow, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - 液态玻璃卡片样式 (macOS 26 超写实玻璃)
extension View {
    // 液态玻璃卡片 - 超写实玻璃效果
    func liquidGlassCard(padding: CGFloat = 20, cornerRadius: CGFloat = 28) -> some View {
        self
            .padding(padding)
            .liquidGlassSurface(.prominent, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // 液态玻璃浮动控件样式
    func liquidGlassFloatingStyle() -> some View {
        self
            .liquidGlassSurface(.max, in: Circle())
    }
}

// MARK: - 液态玻璃卡片容器 (使用 DesignSystem 版本)
// LiquidGlassCard 已移至 DesignSystem/LiquidGlassDesignSystem.swift

// MARK: - 胶囊标签按钮 (macOS 26 液态玻璃风格) (使用 DesignSystem 版本)
// LiquidGlassPillButton 已移至 DesignSystem/LiquidGlassDesignSystem.swift

// MARK: - 浮动按钮 (液态玻璃发光效果) (使用 DesignSystem 版本)
// LiquidGlassFloatingButton 已移至 DesignSystem/LiquidGlassDesignSystem.swift

// MARK: - Section 标题
struct LiquidGlassSectionHeader: View {
    let title: String
    let icon: String?
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
            Spacer()
        }
    }
}

// MARK: - 玻璃分隔线 (液态玻璃效果)
struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.2),
                        Color.white.opacity(0.1),
                        Color.white.opacity(0.05)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 0.5)
    }
}

// MARK: - 导航按钮 (液态玻璃)
struct LiquidGlassNavButton: View {
    var title: String
    var icon: String
    var isSelected: Bool
    var color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 24)
                    .foregroundStyle(isSelected ? color : LiquidGlassColors.textSecondary)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? LiquidGlassColors.textPrimary : LiquidGlassColors.textSecondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isSelected
                            ? LinearGradient(colors: [color.opacity(0.2), color.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
                            : (isHovered ? LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.04)], startPoint: .leading, endPoint: .trailing) : LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

// MARK: - 玻璃加载视图
struct LiquidGlassLoadingView: View {
    var message: String = t("loading")

    var body: some View {
        VStack(spacing: 16) {
            CustomProgressView(tint: LiquidGlassColors.primaryPink)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 玻璃空状态视图
struct LiquidGlassEmptyState: View {
    var message: String = t("noData")
    var icon: String = "photo.on.rectangle"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(LiquidGlassColors.textTertiary)

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - FlowLayout (流式布局)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
                self.size.width = max(self.size.width, x - spacing)
            }
            self.size.height = y + rowHeight
        }
    }
}
