import SwiftUI

struct TabSearchField: View {
    @Binding var text: String
    @Binding var selectedTab: SearchTab
    var onSubmit: () -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var isHovering: Bool = false

    enum SearchTab: String, CaseIterable {
        case all
        case anime
        case people
        case nature
        case technology

        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .anime: return "sparkles"
            case .people: return "person"
            case .nature: return "leaf"
            case .technology: return "cpu"
            }
        }

        var categoryMask: String {
            switch self {
            case .all: return "111"
            case .anime: return "010"
            case .people: return "001"
            case .nature: return "100"
            case .technology: return "100"
            }
        }

        var displayName: String {
            switch self {
            case .all: return t("tab.all")
            case .anime: return t("filter.anime")
            case .people: return t("filter.people")
            case .nature: return t("filter.nature")
            case .technology: return t("filter.tech")
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧 Tab 选择器
            TabSelector(selectedTab: $selectedTab)

            // 分隔线
            Rectangle()
                .fill(GlassStyleColors.glassBorder)
                .frame(width: 1)
                .padding(.vertical, 8)

            // 右侧搜索输入框
            SearchInput(text: $text, isFocused: $isFocused, onSubmit: onSubmit)
        }
        .frame(height: 44)
        .liquidGlassSurface(
            isFocused ? .max : .prominent,
            tint: isFocused ? GlassStyleColors.primaryPink.opacity(0.12) : LiquidGlassColors.glassTint,
            in: RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.large, style: .continuous)
        )
        .glassContainer(spacing: 12)
        .shadow(color: isFocused ? GlassStyleColors.primaryPink.opacity(0.15) : .clear, radius: 6)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}

// MARK: - Tab 选择器
private struct TabSelector: View {
    @Binding var selectedTab: TabSearchField.SearchTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TabSearchField.SearchTab.allCases, id: \.self) { tab in
                TabButton(tab: tab, isSelected: selectedTab == tab) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                }
            }
        }
        .padding(.leading, 8)
    }
}

// MARK: - Tab 按钮
private struct TabButton: View {
    let tab: TabSearchField.SearchTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .medium))

                Text(tab.displayName)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isSelected ? GlassStyleColors.textPrimary : GlassStyleColors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .liquidGlassSurface(
                isSelected ? .prominent : .subtle,
                tint: isSelected ? GlassStyleColors.primaryPink.opacity(0.18) : nil,
                in: RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.small, style: .continuous)
            )
            .shadow(color: isSelected ? GlassStyleColors.primaryPink.opacity(0.2) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - 搜索输入框
private struct SearchInput: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isFocused.wrappedValue ? GlassStyleColors.primaryPink : GlassStyleColors.textSecondary)

            TextField(t("search.placeholder"), text: $text)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(GlassStyleColors.textPrimary)
                .focused(isFocused)
                .onSubmit {
                    onSubmit()
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(GlassStyleColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - 预览
#Preview {
    VStack(spacing: 20) {
        TabSearchField(
            text: .constant(""),
            selectedTab: .constant(.all)
        )

        TabSearchField(
            text: .constant("风景"),
            selectedTab: .constant(.nature)
        )

        TabSearchField(
            text: .constant("动漫壁纸"),
            selectedTab: .constant(.anime)
        )
    }
    .padding(40)
    .background(GlassBackground())
}
