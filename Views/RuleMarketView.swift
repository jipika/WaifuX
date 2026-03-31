import SwiftUI

// MARK: - 规则市场视图

struct RuleMarketView: View {
    @StateObject private var viewModel = RuleMarketViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(message: error)
            } else {
                contentView
            }
        }
        .frame(width: 700, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.loadIndex()
        }
    }

    // MARK: - 头部

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("规则市场")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("浏览并安装来自社区的解析规则")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                // 搜索框
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索规则...", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .frame(width: 160)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

                // 刷新按钮
                Button(action: { viewModel.loadIndex() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLoading)

                // 关闭按钮
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
    }

    // MARK: - 内容区

    private var contentView: some View {
        HStack(spacing: 0) {
            // 左侧分类导航
            categorySidebar

            Divider()

            // 右侧规则列表
            rulesListView
        }
    }

    // MARK: - 分类侧边栏

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("分类")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            ForEach(RuleCategory.allCases, id: \.self) { category in
                Button(action: {
                    viewModel.selectedCategory = category
                }) {
                    HStack {
                        Image(systemName: category.icon)
                            .frame(width: 20)
                        Text(category.displayName)
                        Spacer()
                        Text("\(viewModel.ruleCount(for: category))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        viewModel.selectedCategory == category
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            Divider()
                .padding(.vertical, 8)

            // 一键同步按钮
            Button(action: {
                viewModel.syncAllRules()
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .frame(width: 20)
                    Text("一键同步")
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isInstalling)

            Spacer()
        }
        .frame(width: 160)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - 规则列表

    private var rulesListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.filteredRules) { rule in
                    RuleMarketItemView(
                        rule: rule,
                        isInstalled: viewModel.isRuleInstalled(rule.id),
                        isInstalling: viewModel.installingRuleIds.contains(rule.id),
                        onInstall: { viewModel.installRule(rule) },
                        onUpdate: { viewModel.updateRule(rule) },
                        onRemove: { viewModel.removeRule(rule) }
                    )
                }
            }
            .padding()
        }
    }

    // MARK: - 加载中

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("正在加载规则索引...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 错误

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text("加载失败")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                viewModel.loadIndex()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - 规则项视图

struct RuleMarketItemView: View {
    let rule: RemoteRuleInfo
    let isInstalled: Bool
    let isInstalling: Bool
    let onInstall: () -> Void
    let onUpdate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(categoryColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: categoryIcon)
                    .font(.title2)
                    .foregroundColor(categoryColor)
            }

            // 信息
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rule.name)
                        .font(.headline)
                    if rule.deprecated {
                        Text("已弃用")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                    if isInstalled {
                        Text("已安装")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }

                if let description = rule.description {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Label("v\(rule.version)", systemImage: "tag")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // 操作按钮
            HStack(spacing: 8) {
                if !isInstalled {
                    Button(action: onInstall) {
                        if isInstalling {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Label("安装", systemImage: "plus.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                } else {
                    Button(action: onUpdate) {
                        Label("更新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button(action: onRemove) {
                        Label("移除", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var categoryIcon: String {
        switch rule.type {
        case "wallpaper": return "photo"
        case "anime": return "play.tv"
        case "video": return "film"
        default: return "doc"
        }
    }

    private var categoryColor: Color {
        switch rule.type {
        case "wallpaper": return .blue
        case "anime": return .purple
        case "video": return .orange
        default: return .gray
        }
    }
}

// MARK: - 规则分类

enum RuleCategory: String, CaseIterable {
    case all
    case wallpaper
    case anime
    case video

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .wallpaper: return "壁纸"
        case .anime: return "动漫"
        case .video: return "视频"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .wallpaper: return "photo"
        case .anime: return "play.tv"
        case .video: return "film"
        }
    }
}

// MARK: - 远程规则信息

struct RemoteRuleInfo: Identifiable {
    let id: String
    let name: String
    let type: String
    let version: String
    let deprecated: Bool
    let url: String
    let description: String?
}

// MARK: - ViewModel

@MainActor
class RuleMarketViewModel: ObservableObject {
    @Published var rules: [RemoteRuleInfo] = []
    @Published var searchQuery = ""
    @Published var selectedCategory: RuleCategory = .all
    @Published var isLoading = false
    @Published var isInstalling = false
    @Published var errorMessage: String?
    @Published var installedRuleIds: Set<String> = []
    @Published var installingRuleIds: Set<String> = []

    private let ruleRepository = RuleRepository.shared
    private let ruleLoader = RuleLoader.shared
    private let animeRuleStore = AnimeRuleStore.shared

    var filteredRules: [RemoteRuleInfo] {
        var result = rules

        if selectedCategory != .all {
            result = result.filter { $0.type == selectedCategory.rawValue }
        }

        if !searchQuery.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchQuery) ||
                ($0.description?.localizedCaseInsensitiveContains(searchQuery) ?? false)
            }
        }

        return result
    }

    func ruleCount(for category: RuleCategory) -> Int {
        if category == .all {
            return rules.count
        }
        return rules.filter { $0.type == category.rawValue }.count
    }

    func isRuleInstalled(_ id: String) -> Bool {
        installedRuleIds.contains(id)
    }

    func loadIndex() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // 检查是否已配置仓库
                guard await ruleRepository.isConfigured() else {
                    errorMessage = "请先在设置中配置规则仓库地址"
                    isLoading = false
                    return
                }

                // 获取索引
                let index = try await ruleRepository.fetchIndex()
                parseRulesFromIndex(index)

                await loadInstalledRules()
                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func parseRulesFromIndex(_ index: RepositoryIndex) {
        var newRules: [RemoteRuleInfo] = []

        if let wallpaperItems = index.categories?.wallpaper?.items {
            for item in wallpaperItems {
                newRules.append(RemoteRuleInfo(
                    id: item.name,
                    name: item.name,
                    type: "wallpaper",
                    version: item.version ?? "1.0.0",
                    deprecated: item.deprecated ?? false,
                    url: item.url ?? "",
                    description: nil
                ))
            }
        }

        self.rules = newRules
    }

    private func loadInstalledRules() async {
        let dataSourceRules = await ruleLoader.allRules()
        let dataSourceIds = Set(dataSourceRules.map { $0.id })

        let animeRules = await animeRuleStore.allRules()
        let animeIds = Set(animeRules.map { $0.id })

        installedRuleIds = dataSourceIds.union(animeIds)
    }

    func installRule(_ rule: RemoteRuleInfo) {
        installingRuleIds.insert(rule.id)

        Task {
            do {
                if rule.type == "anime" {
                    _ = try await animeRuleStore.installRule(from: rule.url)
                } else {
                    _ = try await ruleLoader.installRule(from: rule.url)
                }
                installedRuleIds.insert(rule.id)
                installingRuleIds.remove(rule.id)
            } catch {
                print("[RuleMarket] Failed to install rule: \(error)")
                installingRuleIds.remove(rule.id)
            }
        }
    }

    func updateRule(_ rule: RemoteRuleInfo) {
        installingRuleIds.insert(rule.id)

        Task {
            do {
                if rule.type == "anime" {
                    _ = try await animeRuleStore.installRule(from: rule.url)
                } else {
                    _ = try await ruleLoader.installRule(from: rule.url)
                }
                installingRuleIds.remove(rule.id)
            } catch {
                print("[RuleMarket] Failed to update rule: \(error)")
                installingRuleIds.remove(rule.id)
            }
        }
    }

    func removeRule(_ rule: RemoteRuleInfo) {
        Task {
            do {
                if rule.type == "anime" {
                    try await animeRuleStore.removeRule(id: rule.id)
                } else {
                    try await ruleLoader.removeRule(id: rule.id)
                }
                installedRuleIds.remove(rule.id)
            } catch {
                print("[RuleMarket] Failed to remove rule: \(error)")
            }
        }
    }

    func syncAllRules() {
        isInstalling = true

        Task {
            do {
                try await ruleRepository.syncAllRules()
                await loadInstalledRules()
                loadIndex()
                isInstalling = false
            } catch {
                print("[RuleMarket] Failed to sync rules: \(error)")
                isInstalling = false
            }
        }
    }
}
