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
private struct SettingsWindowControlButtons: View {
    var body: some View {
        HStack(spacing: 8) {
            SettingsWindowControlButton(
                fillColor: Color(hex: "FF5F57"),
                symbol: "xmark",
                action: closeWindow
            )
            SettingsWindowControlButton(
                fillColor: Color(hex: "FFBD2E"),
                symbol: "minus",
                action: minimizeWindow
            )
            SettingsWindowControlButton(
                fillColor: Color(hex: "28C840"),
                symbol: "plus",
                action: maximizeWindow
            )
        }
        .frame(height: 34, alignment: .center)
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

private struct SettingsWindowControlButton: View {
    let fillColor: Color
    let symbol: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fillColor.opacity(isHovered ? 0.95 : 0.88))
                .frame(width: 13, height: 13)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                )
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.black.opacity(isHovered ? 0.58 : 0.0))
                }
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 设置标签栏组件
private struct SettingsSegmentedControl: View {
    @Binding var selectedTab: SettingsTab
    let controlHeight: CGFloat

    @Namespace private var selectionNamespace
    @State private var hoveredTab: SettingsTab?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(labelColor(for: tab))
                        .frame(width: itemWidth(for: tab), height: controlHeight - 8)
                        .background {
                            if selectedTab == tab {
                                selectedTabGlass(for: tab)
                            } else if hoveredTab == tab {
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            }
                        }
                }
                .buttonStyle(.plain)
                .contentShape(Capsule(style: .continuous))
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.16)) {
                        hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .liquidGlassSurface(.prominent, in: Capsule(style: .continuous))
        .glassContainer(spacing: 10)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private func itemWidth(for tab: SettingsTab) -> CGFloat {
        switch tab {
        case .general: return 60
        case .download: return 72
        case .scheduler: return 72
        case .about: return 56
        }
    }

    private func labelColor(for tab: SettingsTab) -> Color {
        if selectedTab == tab {
            return .white.opacity(0.96)
        }
        if hoveredTab == tab {
            return .white.opacity(0.86)
        }
        return .white.opacity(0.72)
    }

    @ViewBuilder
    private func selectedTabGlass(for tab: SettingsTab) -> some View {
        Capsule(style: .continuous)
            .liquidGlassSurface(.max, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                            lineWidth: 0.8
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .matchedGeometryEffect(id: "settingsSelectedTabGlass", in: selectionNamespace)
    }
}

// MARK: - 主视图
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var localization = LocalizationService.shared
    @State private var selectedTab: SettingsTab = .general

    private let controlHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                SettingsWindowControlButtons()
                    .frame(width: 88, alignment: .leading)

                Spacer()

                SettingsSegmentedControl(
                    selectedTab: $selectedTab,
                    controlHeight: controlHeight
                )

                Spacer()

                Spacer()
                    .frame(width: 88)
            }
            .padding(.horizontal, 26)
            .padding(.top, 8)
            .padding(.bottom, 10)

            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsTab(viewModel: viewModel)
                case .download:
                    DownloadSettingsTab(viewModel: viewModel)
                case .scheduler:
                    SchedulerSettingsTab(viewModel: viewModel)
                case .about:
                    AboutSettingsTab(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(localization.currentLanguage)
    }
}

// MARK: - 通用设置标签
private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showClearCacheAlert = false
    @State private var importProfileURL = ""

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
                LiquidGlassToggle(
                    t("launchAtLogin"),
                    isOn: Binding(
                        get: { viewModel.launchAtLogin },
                        set: { _ in viewModel.toggleLaunchAtLogin() }
                    )
                )
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
                LiquidGlassTextField(
                    t("api.key.placeholder"),
                    text: apiKeyBinding,
                    icon: "key.fill",
                    isSecure: true
                )

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
                HStack(spacing: 12) {
                    LiquidGlassTextField(
                        "https://github.com/owner/repo",
                        text: $viewModel.ruleRepositoryURL,
                        icon: "globe"
                    )

                    Button(t("save")) {
                        Task { await viewModel.saveRuleRepository() }
                    }
                    .disabled(viewModel.ruleRepositoryURL.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .tint(LiquidGlassColors.primaryPink)
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

            // 数据来源配置
            Section {
                Picker(t("activeProfile"), selection: Binding(
                    get: { viewModel.activeDataSourceProfileID },
                    set: { viewModel.selectDataSourceProfile(id: $0) }
                )) {
                    ForEach(viewModel.dataSourceProfiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 12) {
                    Button(t("testProfile")) {
                        Task { await viewModel.runDataSourceDiagnostics() }
                    }

                    Spacer()

                    Button(t("resetProfile")) {
                        viewModel.resetDataSourceProfiles()
                    }
                }

                HStack(spacing: 12) {
                    LiquidGlassTextField(
                        "https://example.com/profile.json",
                        text: $importProfileURL,
                        icon: "arrow.down.document"
                    )

                    Button(t("importFromURL")) {
                        guard let url = URL(string: importProfileURL) else { return }
                        Task {
                            await viewModel.importDataSourceProfiles(fromRemoteURL: url)
                            importProfileURL = ""
                        }
                    }
                    .disabled(importProfileURL.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .tint(LiquidGlassColors.tertiaryBlue)
                }
            } header: {
                Text(t("dataSourceProfiles"))
            } footer: {
                Text(t("dataSourceProfilesDesc"))
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
                LiquidGlassToggle(t("autoDownloadOriginal"), isOn: $viewModel.autoDownloadOriginal)
                    .padding(.vertical, 4)
                LiquidGlassToggle(t("saveToDownloadsFolder"), isOn: $viewModel.saveToDownloads)
                    .padding(.vertical, 4)
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
                LiquidGlassToggle(t("enableAutoReplace"), isOn: schedulerEnabledBinding)
                    .padding(.vertical, 4)

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
                LabeledContent(t("animeSource"), value: "Predidit / KazumiRules")
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


