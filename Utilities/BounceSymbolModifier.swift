import SwiftUI

/// macOS 15+ 的 symbolEffect 弹跳动画修饰符，旧版自动降级（无动画）
struct BounceSymbolModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.symbolEffect(.bounce, options: .repeat(1))
        } else {
            content
        }
    }
}
