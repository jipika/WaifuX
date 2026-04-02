import SwiftUI

// MARK: - 性能优化的悬停修饰符

/// 节流悬停修饰符 - 减少快速滚动时的状态更新
struct ThrottledHoverModifier: ViewModifier {
    let throttleInterval: TimeInterval
    let action: (Bool) -> Void

    @State private var lastUpdateTime: Date = .distantPast
    @State private var pendingState: Bool?
    @State private var workItem: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                let now = Date()
                let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)

                // 取消之前的延迟任务
                workItem?.cancel()

                if timeSinceLastUpdate >= throttleInterval {
                    // 直接更新
                    lastUpdateTime = now
                    action(hovering)
                } else {
                    // 延迟更新
                    pendingState = hovering
                    workItem = Task {
                        try? await Task.sleep(nanoseconds: UInt64(throttleInterval * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            if let state = pendingState {
                                lastUpdateTime = Date()
                                action(state)
                                pendingState = nil
                            }
                        }
                    }
                }
            }
    }
}

extension View {
    /// 节流悬停 - 限制状态更新频率
    func throttledHover(interval: TimeInterval = 0.05, action: @escaping (Bool) -> Void) -> some View {
        modifier(ThrottledHoverModifier(throttleInterval: interval, action: action))
    }
}

// MARK: - 静态卡片样式

/// 无状态悬停样式 - 使用 overlay 避免 @State
struct StaticHoverOverlay: ViewModifier {
    let cornerRadius: CGFloat
    let hoverColor: Color

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(hoverColor, lineWidth: 1)
                    .opacity(0) // 默认隐藏，悬停时通过父视图显示
            )
    }
}
