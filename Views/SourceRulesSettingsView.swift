import SwiftUI

struct SourceRulesSettingsView: View {
    @StateObject private var viewModel = SourceRulesViewModel()
    @State private var showAddRuleSheet = false
    @State private var showGitHubImportSheet = false
    @State private var showAnimeRulesMarket = false

    var body: some View {
        settingsPage {
            // 说明区域
            SettingsSection(
                title: t("source.rules"),
                subtitle: t("source.rules.desc"),
                accentColor: LiquidGlassColors.tertiaryBlue
            ) {
                SettingsSurfaceCard(tint: LiquidGlassColors.tertiaryBlue.opacity(0.08)) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(LiquidGlassColors.tertiaryBlue)

                            Text(t("sourceRules.supportImport"))
                                .font(.system(size: 13))
                                .foregroundStyle(LiquidGlassColors.textSecondary)
                        }

                        Text(t("sourceRules.defineHowToFetch"))
                            .font(.system(size: 12))
                            .foregroundStyle(LiquidGlassColors.textTertiary)
                            .lineLimit(2)
                    }
                    .padding(16)
                }
            }

            // 已安装规则列表
            SettingsSection(
                title: t("sourceRules.installed"),
                subtitle: t("sourceRules.manageRules"),
                accentColor: LiquidGlassColors.secondaryViolet
            ) {
                VStack(spacing: 8) {
                    ForEach(viewModel.installedRules) { rule in
                        RuleCard(rule: rule) {
                            viewModel.selectedRule = rule
                        } onDelete: {
                            viewModel.deleteRule(rule)
                        }
                    }

                    if viewModel.installedRules.isEmpty {
                        EmptyRulesView()
                    }
                }
            }

            // 动漫规则市场
            SettingsSection(
                title: t("sourceRules.animeRules"),
                subtitle: t("sourceRules.kazumiSource"),
                accentColor: .pink
            ) {
                AddRuleButton(
                    icon: "play.tv",
                    title: t("sourceRules.market"),
                    subtitle: t("sourceRules.kazumiOfficial"),
                    color: .pink
                ) {
                    showAnimeRulesMarket = true
                }
            }

            // 添加按钮
            SettingsSection(
                title: t("sourceRules.add"),
                subtitle: t("sourceRules.importNew"),
                accentColor: LiquidGlassColors.accentCyan
            ) {
                VStack(spacing: 12) {
                    AddRuleButton(
                        icon: "link",
                        title: t("sourceRules.installUrl"),
                        subtitle: t("sourceRules.enterJsonUrl"),
                        color: LiquidGlassColors.accentCyan
                    ) {
                        showAddRuleSheet = true
                    }

                    AddRuleButton(
                        icon: "globe",
                        title: t("sourceRules.installGithub"),
                        subtitle: t("sourceRules.importFromGithub"),
                        color: LiquidGlassColors.onlineGreen
                    ) {
                        showGitHubImportSheet = true
                    }
                }
            }
        }
        .sheet(isPresented: $showAddRuleSheet) {
            AddRuleSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showGitHubImportSheet) {
            GitHubImportSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showAnimeRulesMarket) {
            AnimeRulesMarketView()
                .frame(minWidth: 700, minHeight: 500)
        }
        .task {
            await viewModel.loadRules()
        }
    }
}

// MARK: - Rule Card
struct RuleCard: View {
    let rule: DataSourceRule
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // 图标
                ZStack {
                    Circle()
                        .fill(iconBackgroundColor.opacity(0.15))
                        .frame(width: 40, height: 40)

                    Image(systemName: iconForContentType)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(iconBackgroundColor)
                }

                // 信息
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(rule.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LiquidGlassColors.textPrimary)

                        if rule.deprecated {
                            Text(t("sourceRules.deprecated"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.red.opacity(0.7))
                                )
                        }

                        if rule.useWebview {
                            Image(systemName: "safari")
                                .font(.system(size: 10))
                                .foregroundStyle(LiquidGlassColors.textTertiary)
                        }
                    }

                    Text("\(rule.contentType.displayName) • \(t("sourceRules.version")) \(rule.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                }

                Spacer()

                // 删除按钮
                if isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(.red.opacity(0.8))
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(Color.red.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var iconForContentType: String {
        switch rule.contentType {
        case .wallpaper: return "photo"
        case .anime: return "play.tv"
        case .video: return "film"
        }
    }

    private var iconBackgroundColor: Color {
        switch rule.contentType {
        case .wallpaper: return .blue
        case .anime: return .pink
        case .video: return .purple
        }
    }
}

// MARK: - Empty Rules View
struct EmptyRulesView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(LiquidGlassColors.textTertiary)

            Text(t("sourceRules.noRules"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textSecondary)

            Text(t("sourceRules.clickToAdd"))
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Add Rule Button
struct AddRuleButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                }

                Spacer()

                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(color.opacity(0.7))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add Rule Sheet
struct AddRuleSheet: View {
    @ObservedObject var viewModel: SourceRulesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text(t("sourceRules.importFromUrl"))
                    .font(.system(size: 18, weight: .bold))

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }

            // URL 输入
            VStack(alignment: .leading, spacing: 8) {
                Text(t("sourceRules.ruleUrl"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                LiquidGlassTextField(
                    "https://example.com/rule.json",
                    text: $urlString,
                    icon: "link"
                )
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.1))
                    )
            }

            Spacer()

            // 按钮
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text(t("cancel"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    installRule()
                } label: {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        Text(t("sourceRules.install"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor)
                )
                .buttonStyle(.plain)
                .disabled(urlString.isEmpty || isLoading)
            }
        }
        .padding(24)
        .frame(width: 400, height: 280)
    }

    private func installRule() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                _ = try await RuleLoader.shared.installRule(from: urlString)
                await viewModel.loadRules()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

// MARK: - GitHub Import Sheet
struct GitHubImportSheet: View {
    @ObservedObject var viewModel: SourceRulesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var owner = "Predidit"
    @State private var repo = "KazumiRules"
    @State private var path = ""
    @State private var branch = "main"
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text(t("sourceRules.installGithub"))
                    .font(.system(size: 18, weight: .bold))

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }

            // 输入表单
            VStack(spacing: 12) {
                GitHubInputField(title: "仓库所有者", text: $owner, placeholder: "例如: Predidit")
                GitHubInputField(title: "仓库名称", text: $repo, placeholder: "例如: KazumiRules")
                GitHubInputField(title: "文件路径", text: $path, placeholder: "例如: aowu.json")
                GitHubInputField(title: "分支", text: $branch, placeholder: "main")
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.1))
                    )
            }

            Spacer()

            // 按钮
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text(t("cancel"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    installFromGitHub()
                } label: {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        Text(t("sourceRules.install"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green.opacity(0.8))
                )
                .buttonStyle(.plain)
                .disabled(owner.isEmpty || repo.isEmpty || path.isEmpty || isLoading)
            }
        }
        .padding(24)
        .frame(width: 420, height: 420)
    }

    private func installFromGitHub() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                _ = try await RuleLoader.shared.installRuleFromGitHub(
                    owner: owner,
                    repo: repo,
                    path: path,
                    branch: branch
                )
                await viewModel.loadRules()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

struct GitHubInputField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))

        LiquidGlassTextField(placeholder, text: $text)
        }
    }
}

// MARK: - ViewModel
@MainActor
class SourceRulesViewModel: ObservableObject {
    @Published var installedRules: [DataSourceRule] = []
    @Published var selectedRule: DataSourceRule?

    func loadRules() async {
        installedRules = await RuleLoader.shared.allRules()
    }

    func deleteRule(_ rule: DataSourceRule) {
        Task {
            try? await RuleLoader.shared.removeRule(id: rule.id)
            await loadRules()
        }
    }
}
