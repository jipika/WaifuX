import SwiftUI

private struct ScrollBottomSentinelMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ScrollBottomSentinel: View {
    let coordinateSpaceName: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ScrollBottomSentinelMinYPreferenceKey.self,
                value: proxy.frame(in: .named(coordinateSpaceName)).minY
            )
        }
        .frame(height: 1)
    }
}

extension View {
    func onScrollBottomSentinelChange(_ perform: @escaping (CGFloat) -> Void) -> some View {
        onPreferenceChange(ScrollBottomSentinelMinYPreferenceKey.self, perform: perform)
    }
}
