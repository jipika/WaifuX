import SwiftUI
import AppKit

// MARK: - Konachan Tag 搜索下拉菜单
///
/// 当数据源为 Konachan 时替代 ExploreSearchBar。
/// 用户在搜索框中输入时自动弹出 tag 建议下拉菜单，
/// 点击 tag 直接搜索，无需用户事先知道 tag 名称。
struct KonachanTagSearchField: View {
    @Binding var text: String
    let placeholder: String
    let tint: Color
    let onSubmit: (String) -> Void
    let onClear: () -> Void

    @Environment(\.arcIsLightMode) private var isLightMode
    private var txt: ArcTextColors { ArcTextColors(isLightMode: isLightMode) }

    @FocusState private var isFocused: Bool
    @State private var isDropdownVisible = false
    @State private var suggestedTags: [KonachanTag] = []
    @State private var isLoadingTags = false
    @State private var hasLoadedInitialTags = false
    @State private var searchTask: Task<Void, Never>?

    private let maxDropdownTags = 30
    private let maxPopularTags = 20

    var body: some View {
        searchField
            .onAppear {
                if !hasLoadedInitialTags {
                    loadPopularTags()
                    hasLoadedInitialTags = true
                }
            }
            .onChange(of: text) { _, newValue in
                if newValue.isEmpty {
                    loadPopularTags()
                } else {
                    searchTags(query: newValue)
                }
                if isFocused {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isDropdownVisible = true
                    }
                }
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    if text.isEmpty {
                        loadPopularTags()
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isDropdownVisible = true
                    }
                }
            }
            .popover(isPresented: $isDropdownVisible, arrowEdge: .bottom) {
                dropdownPopover
            }
    }

    // MARK: - 搜索栏

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(txt.secondary.opacity(0.75))

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(txt.primary.opacity(0.92))
                .focused($isFocused)
                .onSubmit {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isDropdownVisible = false
                        }
                        onSubmit(trimmed)
                    }
                }

            if isLoadingTags {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            }

            if !text.isEmpty {
                Button(action: {
                    text = ""
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isDropdownVisible = isFocused
                    }
                    onClear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(txt.secondary.opacity(0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 460)
        .frame(height: 46)
        .exploreFrostedCapsule(
            tint: tint,
            material: .ultraThinMaterial,
            tintLayerOpacity: 0.06
        )
        .onTapGesture {
            isFocused = true
        }
    }

    // MARK: - Popover 内容

    private var dropdownPopover: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                if suggestedTags.isEmpty && !isLoadingTags {
                    emptyTagsView
                } else {
                    ForEach(suggestedTags) { tag in
                        tagRow(tag)
                        if tag.id != suggestedTags.last?.id {
                            Divider()
                                .opacity(0.15)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 340)
        .frame(minHeight: 80, maxHeight: 380)
    }

    // MARK: - Tag 行

    private func tagRow(_ tag: KonachanTag) -> some View {
        Button(action: {
            text = KonachanService.displayName(for: tag.name)
            withAnimation(.easeInOut(duration: 0.2)) {
                isDropdownVisible = false
            }
            onSubmit(tag.name)
        }) {
            HStack(spacing: 10) {
                // tag 图标
                Image(systemName: tagTypeIcon(for: tag.type ?? 0))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.7))
                    .frame(width: 18, alignment: .center)

                // tag 名称
                Text(KonachanService.displayName(for: tag.name))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(txt.primary.opacity(0.9))
                    .lineLimit(1)

                Spacer(minLength: 8)

                // 使用次数
                HStack(spacing: 4) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 8, weight: .medium))
                    Text("\(tag.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(txt.secondary.opacity(0.55))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(txt.secondary.opacity(0.08))
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            txt.primary.opacity(0.04)
                .opacity(0)
        )
    }

    private var emptyTagsView: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag.slash")
                .font(.system(size: 12))
                .foregroundStyle(txt.secondary.opacity(0.4))
            Text(t("没有找到匹配的标签"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(txt.secondary.opacity(0.5))
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 数据加载

    /// 取消正在执行的搜索任务
    private func cancelPendingSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    /// 加载热门标签（搜索框为空时显示）
    private func loadPopularTags() {
        cancelPendingSearch()
        guard !isLoadingTags else { return }
        isLoadingTags = true

        searchTask = Task { @MainActor in
            defer { isLoadingTags = false }
            do {
                let tags = try await KonachanService.shared.fetchHotTags(limit: maxPopularTags)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.suggestedTags = tags
                }
            } catch {
                guard !Task.isCancelled else { return }
                print("[KonachanTagSearchField] 加载热门标签失败: \(error)")
            }
        }
    }

    /// 根据输入搜索匹配的 tag
    private func searchTags(query: String) {
        cancelPendingSearch()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            loadPopularTags()
            return
        }

        isLoadingTags = true

        searchTask = Task { @MainActor in
            defer { isLoadingTags = false }
            do {
                let tags = try await KonachanService.shared.suggestTags(query: trimmed, limit: maxDropdownTags)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.suggestedTags = tags
                }
            } catch {
                guard !Task.isCancelled else { return }
                print("[KonachanTagSearchField] 搜索标签失败: \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// 根据 tag 类型返回 SF Symbol 图标
    private func tagTypeIcon(for type: Int) -> String {
        switch type {
        case 0: return "tag"          // General
        case 1: return "exclamationmark.tag"  // Artist
        case 2: return "bookmark"     // Character
        case 3: return "building.columns" // Copyright
        default: return "tag"
        }
    }
}
