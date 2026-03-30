import SwiftUI

// MARK: - Deprecated: 使用 AnimeExploreView 替代
// 此文件保留用于兼容性，实际功能已移至 AnimeExploreView

struct AnimeContentView: View {
    var body: some View {
        AnimeExploreView()
    }
}

struct AnimeContentViewPlaceholder: View {
    var body: some View {
        Text("使用 AnimeExploreView 替代")
            .foregroundColor(.white)
    }
}
