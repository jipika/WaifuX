import SwiftUI

// MARK: - WaifuX GuideKit · 遮罩与气泡 UI
// 遮罩 = even-odd 挖洞（整屏 − 洞）+ 系统强调色描边微光；
// 气泡 = ultraThinMaterial 玻璃卡（圆角 16 / 白描边 / 深阴影）。
// 定位约束：气泡/文字卡一律夹取在 engine.usableRect（screen.visibleFrame，
// 已剔除菜单栏与 Dock）内；卡片高度用 PreferenceKey 实测，不靠估算，
// 避免实测反馈中的压 Dock 问题（2026-10-25 用户实测反馈修复）。

/// 卡片实测高度上报：定位需要精确高度决定放洞下方还是上方。
private struct GuideCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct GuideOverlayView: View {
    @ObservedObject var engine: GuideEngine

    private let bubbleWidth: CGFloat = 340
    private let screenInset: CGFloat = 24
    private let bubbleGap: CGFloat = 20
    /// 首帧高度猜测值，PreferenceKey 上报后立即被实测值替换。
    @State private var measuredCardHeight: CGFloat = 200

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                maskLayer(container: geo.size)
                    .onTapGesture { engine.advanceFromMaskTap() }

                if let hole = engine.currentHole {
                    bubble(at: hole, container: geo.size)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if let step = engine.currentStep {
                    centeredCard(step: step, container: geo.size)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: engine.currentHole)
            .animation(.easeInOut(duration: 0.2), value: engine.stepIndex)
            .onPreferenceChange(GuideCardHeightKey.self) { height in
                guard height > 0 else { return }
                measuredCardHeight = height
            }
        }
    }

    /// 可用区兜底：usableRect 缺失时退回整屏（不遮挡判定退化为旧行为）。
    private func usableBounds(_ container: CGSize) -> CGRect {
        engine.usableRect ?? CGRect(origin: .zero, size: container)
    }

    // MARK: 遮罩

    private func maskLayer(container: CGSize) -> some View {
        ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: container))
                if let hole = engine.currentHole {
                    path.addRoundedRect(
                        in: hole,
                        cornerSize: CGSize(width: 10, height: 10)
                    )
                }
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true, antialiased: true))

            if let hole = engine.currentHole {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.95), lineWidth: 2)
                    .frame(width: hole.width + 12, height: hole.height + 12)
                    .position(x: hole.midX, y: hole.midY)
                    .shadow(color: Color.accentColor.opacity(0.5), radius: 10)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: 气泡（洞的下方/上方，夹取在可用区内）

    private struct BubblePlacement {
        let centerX: CGFloat
        let centerY: CGFloat
        let arrow: GuideCardArrow
    }

    private func bubblePlacement(
        for hole: CGRect,
        container: CGSize,
        width: CGFloat
    ) -> BubblePlacement {
        let usable = usableBounds(container)
        let height = measuredCardHeight

        // 上下空间按可用区（而非整屏）计算：Dock / 菜单栏区域不算空间
        let spaceBelow = usable.maxY - hole.maxY
        let spaceAbove = hole.minY - usable.minY
        let need = height + bubbleGap + 8
        let placeBelow = spaceBelow >= need || spaceAbove < need

        let lowerX = usable.minX + width / 2 + screenInset
        let upperX = max(lowerX, usable.maxX - width / 2 - screenInset)
        let centerX = min(max(hole.midX, lowerX), upperX)

        var centerY = placeBelow
            ? hole.maxY + bubbleGap + height / 2
            : hole.minY - bubbleGap - height / 2
        // 两侧都放不下时夹回可用区：宁可盖住部分高亮，也不压 Dock/菜单栏
        let topBound = usable.minY + height / 2 + 8
        let bottomBound = usable.maxY - height / 2 - 8
        if bottomBound >= topBound {
            centerY = min(max(centerY, topBound), bottomBound)
        }

        let bubbleLeft = centerX - width / 2
        let arrowOffset = width > 40
            ? min(max(hole.midX - bubbleLeft, 22), width - 22)
            : width / 2
        return BubblePlacement(
            centerX: centerX,
            centerY: centerY,
            arrow: placeBelow ? .top(offset: arrowOffset) : .bottom(offset: arrowOffset)
        )
    }

    @ViewBuilder
    private func bubble(at hole: CGRect, container: CGSize) -> some View {
        if let step = engine.currentStep {
            let width = min(bubbleWidth, container.width - screenInset * 2)
            let placement = bubblePlacement(for: hole, container: container, width: width)
            guideCard(step, width: width, arrow: placement.arrow)
                .position(x: placement.centerX, y: placement.centerY)
        }
    }

    // MARK: 居中文字卡（欢迎步等无锚点步骤，居中于可用区）

    @ViewBuilder
    private func centeredCard(step: GuideStep, container: CGSize) -> some View {
        let width = min(bubbleWidth, container.width - screenInset * 2)
        let usable = usableBounds(container)
        guideCard(step, width: width, arrow: .none)
            .position(
                x: container.width / 2,
                y: max(usable.midY, usable.minY + measuredCardHeight / 2 + 8)
            )
    }

    private func guideCard(
        _ step: GuideStep,
        width: CGFloat,
        arrow: GuideCardArrow
    ) -> some View {
        GuideCardView(
            step: step,
            stepIndex: engine.stepIndex,
            stepCount: engine.stepCount,
            width: width,
            arrow: arrow,
            onPrevious: { engine.previous() },
            onNext: { engine.next() },
            onSkip: { engine.end(markCompleted: true) }
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: GuideCardHeightKey.self, value: geo.size.height)
            }
        )
    }
}

// MARK: - 玻璃说明卡

struct GuideCardView: View {
    let step: GuideStep
    let stepIndex: Int
    let stepCount: Int
    let width: CGFloat
    let arrow: GuideCardArrow
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    private var isLastStep: Bool { stepIndex >= stepCount - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行 + 跳过
            HStack(alignment: .firstTextBaseline) {
                Text(t(step.titleKey))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onSkip) {
                    Text(t("guide.skip"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            Text(t(step.bodyKey))
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.78))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            // 进度点 + 步数
            HStack(spacing: 5) {
                ForEach(0..<max(stepCount, 1), id: \.self) { index in
                    Capsule()
                        .fill(index == stepIndex
                              ? Color.accentColor
                              : Color.white.opacity(0.28))
                        .frame(width: index == stepIndex ? 16 : 6, height: 6)
                        .animation(.easeInOut(duration: 0.2), value: stepIndex)
                }
                Spacer()
                Text("\(stepIndex + 1) / \(stepCount)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }

            // 按钮行
            HStack(spacing: 10) {
                if stepIndex > 0 {
                    guideButton(title: t("guide.prev"), filled: false) { onPrevious() }
                }
                Spacer()
                guideButton(
                    title: isLastStep ? t("guide.finish") : t("guide.next"),
                    filled: true
                ) { onNext() }
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 10)
        .background(arrowShape)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 指向锚点的箭头，画在卡片背后、探出边缘。
    @ViewBuilder
    private var arrowShape: some View {
        switch arrow {
        case .top(let offset):
            GuideArrowShape()
                .fill(.ultraThinMaterial)
                .overlay(GuideArrowShape().stroke(Color.white.opacity(0.14), lineWidth: 1))
                .frame(width: 20, height: 12)
                .offset(x: offset - width / 2, y: -6)
        case .bottom(let offset):
            GuideArrowShape(inverted: true)
                .fill(.ultraThinMaterial)
                .overlay(GuideArrowShape(inverted: true).stroke(Color.white.opacity(0.14), lineWidth: 1))
                .frame(width: 20, height: 12)
                .offset(x: offset - width / 2, y: 6)
        case .none:
            EmptyView()
        }
    }

    private func guideButton(title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(filled ? Color.white : Color.white.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(filled
                              ? AnyShapeStyle(Color.accentColor.opacity(0.9))
                              : AnyShapeStyle(Color.white.opacity(0.1)))
                )
        }
        .buttonStyle(.plain)
    }
}

enum GuideCardArrow {
    /// 箭头在卡片上边缘（气泡在洞下方）
    case top(offset: CGFloat)
    /// 箭头在卡片下边缘（气泡在洞上方）
    case bottom(offset: CGFloat)
    case none
}

/// 指向锚点的小三角；inverted 时顶点朝下（气泡在洞上方时用）。
struct GuideArrowShape: Shape {
    var inverted: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if inverted {
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}
