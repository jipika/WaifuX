import SwiftUI

// MARK: - 规则市场视图
// 与 Kazumi 对齐：显示全部可用规则，让用户选择安装

struct AnimeRulesMarketView: View {
    @State private var availableRules: [AnimeRuleInfo] = []
    @State private var installedRuleIds: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            toolbar

            Divider()

            // 规则列表
            if isLoading && availableRules.isEmpty {
                loadingView
            } else if availableRules.isEmpty {
                emptyView
            } else {
                rulesList
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            await loadData()
        }
        .alert("错误", isPresented: $showingError) {
            Button("确定") {}
        } message: {
            Text(errorMessage ?? t("unknown"))
        }
    }

    // MARK: - 工具栏
    private var toolbar: some View {
        HStack {
            Text(t("ruleMarket.title"))
                .font(.title2.bold())

            Spacer()

            // 刷新按钮
            Button {
                Task {
                    await refreshRules()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)
            .help(t("ruleMarket.refresh"))

            // 安装全部按钮
            Button {
                Task {
                    await installAllRules()
                }
            } label: {
                Text(t("animeRules.installAll"))
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isLoading || availableRules.allSatisfy { installedRuleIds.contains($0.id) })
        }
        .padding()
    }

    // MARK: - 加载中视图
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text(t("ruleMarket.loading"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 空视图
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(t("ruleMarket.noRules"))
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 规则列表
    private var rulesList: some View {
        List(availableRules) { rule in
            RuleMarketItem(
                rule: rule,
                isInstalled: installedRuleIds.contains(rule.id),
                onInstall: { await installRule(rule) },
                onUninstall: { await uninstallRule(rule) }
            )
        }
        .listStyle(.inset)
    }

    // MARK: - 加载数据
    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        // 加载已安装的规则
        let installedRules = await AnimeRuleStore.shared.loadAllRules()
        installedRuleIds = Set(installedRules.map { $0.id })

        // 加载可用规则列表
        let available = await AnimeRuleStore.shared.fetchAvailableRules()
        availableRules = available
    }

    // MARK: - 刷新规则
    private func refreshRules() async {
        isLoading = true
        defer { isLoading = false }

        let available = await AnimeRuleStore.shared.fetchAvailableRules()
        availableRules = available
    }

    // MARK: - 安装规则
    private func installRule(_ rule: AnimeRuleInfo) async {
        isLoading = true
        defer { isLoading = false }

        if let _ = await AnimeRuleStore.shared.installRuleByName(rule.id) {
            installedRuleIds.insert(rule.id)
        } else {
            errorMessage = "安装规则 \(rule.name) 失败"
            showingError = true
        }
    }

    // MARK: - 卸载规则
    private func uninstallRule(_ rule: AnimeRuleInfo) async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await AnimeRuleStore.shared.uninstallRule(rule.id)
            installedRuleIds.remove(rule.id)
        } catch {
            errorMessage = "卸载规则失败: \(error.localizedDescription)"
            showingError = true
        }
    }

    // MARK: - 安装全部规则
    private func installAllRules() async {
        isLoading = true
        defer { isLoading = false }

        for rule in availableRules {
            if !installedRuleIds.contains(rule.id) {
                if let _ = await AnimeRuleStore.shared.installRuleByName(rule.id) {
                    installedRuleIds.insert(rule.id)
                }
            }
        }
    }
}

// MARK: - 规则市场项
private struct RuleMarketItem: View {
    let rule: AnimeRuleInfo
    let isInstalled: Bool
    let onInstall: () async -> Void
    let onUninstall: () async -> Void

    @State private var isProcessing = false

    var body: some View {
        HStack(spacing: 16) {
            // 图标
            ZStack {
                Circle()
                    .fill(isInstalled ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
                    .frame(width: 40, height: 40)

                Image(systemName: isInstalled ? "checkmark" : "play.tv")
                    .font(.system(size: 16))
                    .foregroundStyle(isInstalled ? .green : .secondary)
            }

            // 信息
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rule.name)
                        .font(.system(size: 14, weight: .semibold))

                    if isInstalled {
                        Text(t("animeRules.installed"))
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.1))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }

                Text(rule.description ?? "无描述")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    Label(rule.version, systemImage: "number")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if rule.antiCrawlerEnabled {
                        Label("需验证", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            // 操作按钮
            Button {
                isProcessing = true
                Task {
                    if isInstalled {
                        await onUninstall()
                    } else {
                        await onInstall()
                    }
                    isProcessing = false
                }
            } label: {
                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 20, height: 20)
                } else {
                    Text(isInstalled ? "卸载" : "安装")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isInstalled ? Color.clear : Color.accentColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isInstalled ? Color.white.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .disabled(isProcessing)
        }
        .padding(.vertical, 4)
    }
}

