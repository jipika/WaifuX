import SwiftUI
import AppKit

// MARK: - 设置标签
private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case download
    case scheduler
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return t("general")
        case .download: return t("download")
        case .scheduler: return t("scheduler")
        case .about: return t("about")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .download: return "arrow.down.circle.fill"
        case .scheduler: return "clock.arrow.circlepath"
        case .about: return "info.circle.fill"
        }
    }
}

// MARK: - 窗口控制按钮
private struct WindowControlButtons: View {
    var body: some View {
        HStack(spacing: 8) {
            Button(action: closeWindow) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.black.opacity(0.5))
                            .opacity(0)
                    )
            }
            .buttonStyle(.plain)

            Button(action: minimizeWindow) {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Image(systemName: "minus")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.black.opacity(0.5))
                            .opacity(0)
                    )
            }
            .buttonStyle(.plain)

            Button(action: maximizeWindow) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(.black.opacity(0.5))
                            .opacity(0)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func closeWindow() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)
    }

    private func minimizeWindow() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.miniaturize(nil)
    }

    private func maximizeWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            window.zoom(nil)
        }
    }
}

// MARK: - 主视图
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var localization = LocalizationService.shared
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏（红绿灯 + 标题 + 站位）
            HStack {
                // 红绿灯
                WindowControlButtons()
                    .frame(width: 60, alignment: .leading)

                Spacer()

                // 标题
                Text(t("settings.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                // 站位
                Color.clear
                    .frame(width: 60)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Divider()

            // TabView 内容
            TabView(selection: $selectedTab) {
                GeneralSettingsTab(viewModel: viewModel)
                    .tabItem {
                        Label(SettingsTab.general.title, systemImage: SettingsTab.general.icon)
                    }
                    .tag(SettingsTab.general)

                DownloadSettingsTab(viewModel: viewModel)
                    .tabItem {
                        Label(SettingsTab.download.title, systemImage: SettingsTab.download.icon)
                    }
                    .tag(SettingsTab.download)

                SchedulerSettingsTab(viewModel: viewModel)
                    .tabItem {
                        Label(SettingsTab.scheduler.title, systemImage: SettingsTab.scheduler.icon)
                    }
                    .tag(SettingsTab.scheduler)

                AboutSettingsTab(viewModel: viewModel)
                    .tabItem {
                        Label(SettingsTab.about.title, systemImage: SettingsTab.about.icon)
                    }
                    .tag(SettingsTab.about)
            }
        }
        .frame(width: 600, height: 480)
        .id(localization.currentLanguage)
    }
}

// MARK: - 通用设置标签
private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showClearCacheAlert = false

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { viewModel.apiKey },
            set: { viewModel.apiKey = $0 }
        )
    }

    private var languageBinding: Binding<LocalizationService.Language> {
        Binding(
            get: { LocalizationService.shared.currentLanguage },
            set: { LocalizationService.shared.setLanguage($0) }
        )
    }

    var body: some View {
        Form {
            // 启动设置
            Section {
                Toggle(t("launchAtLogin"), isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { _ in viewModel.toggleLaunchAtLogin() }
                ))
            } header: {
                Text(t("startup"))
            }

            // 语言设置
            Section {
                Picker(t("displayLanguage"), selection: languageBinding) {
                    ForEach(LocalizationService.Language.allCases, id: \.self) { language in
                        Text(language.displayName)
                            .tag(language)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text(t("languageSettings"))
            }

            // API Key 设置
            Section {
                SecureField(t("api.key.placeholder"), text: apiKeyBinding)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text(viewModel.apiKey.isEmpty ? t("apiNotConfigured") : t("apiConfigured"))
                        .foregroundStyle(viewModel.apiKey.isEmpty ? Color.secondary : Color.green)

                    Spacer()

                    Link(t("getApiKey"), destination: URL(string: "https://wallhaven.cc/settings/account")!)
                }
                .font(.callout)
            } header: {
                Text(t("apiKey"))
            } footer: {
                Text(t("afterConfig"))
                    .font(.caption)
            }

            // 规则仓库
            Section {
                HStack {
                    TextField("https://github.com/owner/repo", text: $viewModel.ruleRepositoryURL)
                        .textFieldStyle(.roundedBorder)

                    Button(t("save")) {
                        Task { await viewModel.saveRuleRepository() }
                    }
                    .disabled(viewModel.ruleRepositoryURL.isEmpty)
                }

                if viewModel.isRuleRepositoryConfigured {
                    Text("\(t("configured")): \(viewModel.currentRuleRepository)")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            } header: {
                Text(t("ruleRepository"))
            } footer: {
                Text(t("ruleRepositoryDesc"))
                    .font(.caption)
            }

            // 缓存管理
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.cacheSize)
                            .font(.body.monospacedDigit())
                        Text(t("thumbnailsTemp"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(t("clearCache"), role: .destructive) {
                        showClearCacheAlert = true
                    }
                }

                ProgressView(value: viewModel.cacheProgress)
                    .progressViewStyle(.linear)
            } header: {
                Text(t("cacheManagement"))
            }
        }
        .formStyle(.grouped)
        .alert(t("clearCache"), isPresented: $showClearCacheAlert) {
            Button(t("cancel"), role: .cancel) {}
            Button(t("clear"), role: .destructive) {
                Task { await viewModel.clearCache() }
            }
        } message: {
            Text(t("clearCacheConfirm"))
        }
        .alert(
            t("dataSourceProfiles"),
            isPresented: Binding(
                get: { viewModel.dataSourceStatusMessage != nil },
                set: { if !$0 { viewModel.dataSourceStatusMessage = nil } }
            )
        ) {
            Button(t("ok"), role: .cancel) {}
        } message: {
            Text(viewModel.dataSourceStatusMessage ?? "")
        }
    }
}

// MARK: - 下载设置标签
private struct DownloadSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle(t("autoDownloadOriginal"), isOn: $viewModel.autoDownloadOriginal)
                Toggle(t("saveToDownloadsFolder"), isOn: $viewModel.saveToDownloads)
            } header: {
                Text(t("downloadPrefs"))
            } footer: {
                Text(t("downloadPrefsDesc"))
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 调度器设置标签
private struct SchedulerSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    private var schedulerEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.schedulerViewModel.isRunning },
            set: { newValue in
                if viewModel.schedulerViewModel.isRunning != newValue {
                    viewModel.schedulerViewModel.toggleScheduler()
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle(t("enableAutoReplace"), isOn: schedulerEnabledBinding)

                HStack {
                    Text(t("status"))
                    Spacer()
                    Text(viewModel.schedulerViewModel.isRunning ? t("running") : t("stopped"))
                        .foregroundStyle(viewModel.schedulerViewModel.isRunning ? .green : .secondary)
                }
            } header: {
                Text(t("autoReplace"))
            }

            Section {
                Picker(t("replaceInterval"), selection: Binding(
                    get: { viewModel.schedulerViewModel.config.intervalMinutes },
                    set: { viewModel.schedulerViewModel.updateInterval($0) }
                )) {
                    ForEach(SchedulerConfig.intervalOptions, id: \.self) { minutes in
                        Text(intervalLabel(for: minutes)).tag(minutes)
                    }
                }
                .pickerStyle(.menu)

                Picker(t("replaceOrder"), selection: Binding(
                    get: { viewModel.schedulerViewModel.config.order },
                    set: { viewModel.schedulerViewModel.updateOrder($0) }
                )) {
                    Text(t("sequential")).tag(ScheduleOrder.sequential)
                    Text(t("random")).tag(ScheduleOrder.random)
                }
                .pickerStyle(.segmented)

                Picker(t("wallpaperSource"), selection: Binding(
                    get: { viewModel.schedulerViewModel.config.source },
                    set: { viewModel.schedulerViewModel.updateSource($0) }
                )) {
                    Text(t("online")).tag(WallpaperSource.online)
                    Text(t("local")).tag(WallpaperSource.local)
                    Text(t("favorites")).tag(WallpaperSource.favorites)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(t("replaceRhythm"))
            }
        }
        .formStyle(.grouped)
    }

    private func intervalLabel(for minutes: Int) -> String {
        switch minutes {
        case 5: return "5 \(t("minutes"))"
        case 15: return "15 \(t("minutes"))"
        case 30: return "30 \(t("minutes"))"
        case 60: return "1 \(t("hour"))"
        case 360: return "6 \(t("hours"))"
        case 1440: return "24 \(t("hours"))"
        default: return "\(minutes) \(t("minutes"))"
        }
    }
}

// MARK: - 关于设置标签
private struct AboutSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            // 应用信息
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("WallHaven")
                            .font(.title2.weight(.semibold))

                        Text(viewModel.updateChecker.fullVersionString)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Text(viewModel.updateChecker.formattedLastCheckDate())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        if viewModel.hasUpdate {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(t("newVersionAvailable")): \(viewModel.latestVersion ?? "")")
                                    .font(.callout)
                                    .foregroundStyle(.green)

                                Button(t("downloadUpdate")) {
                                    viewModel.openDownloadPage()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        } else {
                            Button(t("checkForUpdates")) {
                                Task { await viewModel.checkForUpdates() }
                            }
                            .disabled(viewModel.isCheckingUpdate)
                            .controlSize(.small)
                        }
                    }
                }
            }

            // 项目信息
            Section {
                LabeledContent(t("developer"), value: "jipika")
                LabeledContent(t("dataSource"), value: "wallhaven.cc / motionbgs.com")
                LabeledContent(t("techStack"), value: "SwiftUI + AppKit")
            } header: {
                Text(t("projectInfo"))
            }

            // 链接
            Section {
                Link(destination: URL(string: "https://wallhaven.cc")!) {
                    HStack {
                        Text(t("visitWebsite"))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    }
                }

                Link(destination: URL(string: "https://github.com/jipika/WallHaven")!) {
                    HStack {
                        Text(t("reportProblem"))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("externalLinks"))
            }
        }
        .formStyle(.grouped)
        .alert(t("checkForUpdates"), isPresented: Binding(
            get: { viewModel.updateCheckResult != nil },
            set: { if !$0 { viewModel.updateCheckResult = nil } }
        )) {
            Button(t("ok"), role: .cancel) {}
            if viewModel.hasUpdate {
                Button(t("goToDownload")) {
                    viewModel.openDownloadPage()
                }
            }
        } message: {
            if let result = viewModel.updateCheckResult {
                switch result {
                case .noUpdate:
                    Text(t("alreadyLatestVersion"))
                case .updateAvailable(_, let release):
                    Text("\(t("newVersionFound")) \(release.version)，\(t("goToDownloadQuestion"))")
                case .error(let message):
                    Text(message)
                }
            } else {
                Text("")
            }
        }
    }
}

