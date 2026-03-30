import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
        case .general: return "gearshape"
        case .download: return "arrow.down.circle"
        case .scheduler: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }

    var accentColor: Color {
        switch self {
        case .general: return LiquidGlassColors.secondaryViolet
        case .download: return LiquidGlassColors.tertiaryBlue
        case .scheduler: return LiquidGlassColors.accentCyan
        case .about: return LiquidGlassColors.accentOrange
        }
    }

    var summary: String {
        switch self {
        case .general: return t("general.desc")
        case .download: return t("download.desc")
        case .scheduler: return t("scheduler.desc")
        case .about: return t("about.desc")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var localization = LocalizationService.shared
    @State private var showClearCacheAlert = false
    @State private var selectedTab: SettingsTab = .general
    private let contentColumnWidth: CGFloat = 680

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { viewModel.apiKey },
            set: { viewModel.apiKey = $0 }
        )
    }

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

    private var languageBinding: Binding<LocalizationService.Language> {
        Binding(
            get: { localization.currentLanguage },
            set: { localization.setLanguage($0) }
        )
    }

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 0) {
                windowChrome
                tabHeader

                Rectangle()
                    .fill(LiquidGlassColors.borderSubtle)
                    .frame(height: 1)
                    .padding(.horizontal, 24)

                currentTabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        .frame(width: 800, height: 620)
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
        .id(localization.currentLanguage)
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

    private var windowChrome: some View {
        HStack(alignment: .center) {
            CustomWindowControls(
                onClose: closeWindow,
                onMinimize: minimizeWindow,
                onMaximize: maximizeWindow
            )
            .frame(width: 88, alignment: .leading)

            Spacer()

            Text(t("settings.title"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textSecondary)

            Spacer()

            Color.clear
                .frame(width: 88, height: 1)
        }
        .frame(maxWidth: contentColumnWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    LiquidGlassColors.deepBackground,
                    LiquidGlassColors.midBackground.opacity(0.94)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(selectedTab.accentColor.opacity(0.22))
                    .frame(width: 260, height: 260)
                    .blur(radius: 90)
                    .offset(x: -60, y: -90)
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(LiquidGlassColors.primaryPink.opacity(0.12))
                    .frame(width: 220, height: 220)
                    .blur(radius: 110)
                    .offset(x: 50, y: -110)
            }

            // 颗粒材质覆盖层
            GrainTextureOverlay()
        }
        .ignoresSafeArea()
    }

    private var tabHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("preferences"))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(LiquidGlassColors.textPrimary)

                    Text(selectedTab.summary)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                }

                Spacer()

                Image(systemName: selectedTab.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selectedTab.accentColor)
                    .frame(width: 42, height: 42)
                    .liquidGlassSurface(.max, tint: selectedTab.accentColor.opacity(0.28), in: Circle())
            }

            HStack(spacing: 10) {
                ForEach(SettingsTab.allCases) { tab in
                    LiquidGlassPillButton(
                        title: tab.title,
                        icon: tab.icon,
                        isSelected: selectedTab == tab,
                        color: tab.accentColor
                    ) {
                        selectedTab = tab
                    }
                }
            }
        }
        .frame(maxWidth: contentColumnWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var currentTabContent: some View {
        switch selectedTab {
        case .general:
            generalSettings
        case .download:
            downloadSettings
        case .scheduler:
            schedulerSettings
        case .about:
            aboutSettings
        }
    }

    private var generalSettings: some View {
        settingsPage {
            SettingsSection(
                title: t("languageSettings"),
                subtitle: t("languageSettingsDesc"),
                accentColor: LiquidGlassColors.secondaryViolet
            ) {
                SettingsSurfaceCard(tint: LiquidGlassColors.secondaryViolet.opacity(0.08)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(t("displayLanguage"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LiquidGlassColors.textSecondary)

                        Picker(t("displayLanguage"), selection: languageBinding) {
                            ForEach(LocalizationService.Language.allCases, id: \.self) { language in
                                Text(language.displayName)
                                    .tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        Text(t("languageImmediateApply"))
                            .font(.system(size: 12))
                            .foregroundStyle(LiquidGlassColors.textSecondary)
                    }
                }
            }

            SettingsSection(
                title: t("launchAtLogin"),
                subtitle: t("launchAtLoginDesc"),
                accentColor: LiquidGlassColors.secondaryViolet
            ) {
                SettingsSurfaceCard(padding: 0, tint: LiquidGlassColors.secondaryViolet.opacity(0.08)) {
                    SettingsToggleRow(
                        title: t("launchAtLogin"),
                        subtitle: t("launchAtLoginSubtitle"),
                        isOn: Binding(
                            get: { viewModel.launchAtLogin },
                            set: { _ in viewModel.toggleLaunchAtLogin() }
                        )
                    )
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }

            SettingsSection(
                title: t("apiAccess"),
                subtitle: t("apiAccessDesc"),
                accentColor: LiquidGlassColors.tertiaryBlue
            ) {
                SettingsSurfaceCard(padding: 0, tint: LiquidGlassColors.tertiaryBlue.opacity(0.08)) {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("WallHaven API Key")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LiquidGlassColors.textSecondary)

                            SecureField(t("api.key.placeholder"), text: apiKeyBinding)
                                .textFieldStyle(.plain)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(LiquidGlassColors.textPrimary)
                                .padding(.horizontal, 14)
                                .frame(height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(LiquidGlassColors.midBackground.opacity(0.72))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(LiquidGlassColors.borderSubtle, lineWidth: 1)
                                )
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 16)

                        SettingsRowDivider()
                            .padding(.horizontal, 20)

                        HStack {
                            SettingsStatusBadge(
                                title: viewModel.apiKey.isEmpty ? t("apiNotConfigured") : t("apiConfigured"),
                                systemImage: viewModel.apiKey.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill",
                                color: viewModel.apiKey.isEmpty ? LiquidGlassColors.textTertiary : LiquidGlassColors.onlineGreen
                            )

                            Spacer()

                            SettingsLinkButton(title: t("getApiKey"), destination: URL(string: "https://wallhaven.cc/settings/account")!)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)

                        Text(t("afterConfig"))
                            .font(.system(size: 13))
                            .foregroundStyle(LiquidGlassColors.textSecondary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                    }
                }
            }

            SettingsSection(
                title: t("appearanceSettings"),
                subtitle: t("appearanceSettingsDesc"),
                accentColor: LiquidGlassColors.accentCyan
            ) {
                SettingsSurfaceCard(padding: 0, tint: LiquidGlassColors.accentCyan.opacity(0.08)) {
                    SettingsToggleRow(
                        title: t("grainTextureEffect"),
                        subtitle: t("grainTextureEffectDesc"),
                        isOn: Binding(
                            get: { viewModel.grainTextureEnabled },
                            set: { viewModel.grainTextureEnabled = $0 }
                        )
                    )
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }

            SettingsSection(
                title: "规则仓库",
                subtitle: "配置 GitHub 仓库地址，自动同步壁纸、媒体、动漫规则",
                accentColor: LiquidGlassColors.secondaryViolet
            ) {
                SettingsSurfaceCard(padding: 0, tint: LiquidGlassColors.secondaryViolet.opacity(0.08)) {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("仓库地址")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LiquidGlassColors.textSecondary)

                            HStack {
                                TextField("https://github.com/owner/repo", text: $viewModel.ruleRepositoryURL)
                                    .textFieldStyle(.plain)
                                    .textSelection(.enabled)
                                    .font(.system(size: 14))
                                    .padding(.horizontal, 14)
                                    .frame(height: 40)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(LiquidGlassColors.midBackground.opacity(0.72))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(LiquidGlassColors.borderSubtle, lineWidth: 1)
                                    )

                                Button("保存") {
                                    Task {
                                        await viewModel.saveRuleRepository()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.ruleRepositoryURL.isEmpty)
                            }

                            if viewModel.isRuleRepositoryConfigured {
                                Text("已配置: \(viewModel.currentRuleRepository)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 16)
                        
                        // 动漫规则源切换
                        SettingsRowDivider()
                            .padding(.horizontal, 20)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Text("动漫规则源")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LiquidGlassColors.textSecondary)
                            
                            Text("选择动漫内容的来源规则")
                                .font(.system(size: 12))
                                .foregroundStyle(LiquidGlassColors.textTertiary)
                            
                            Picker("动漫规则源", selection: $viewModel.animeRuleSource) {
                                ForEach(AnimeRuleStore.RuleSource.allCases, id: \.self) { source in
                                    HStack(spacing: 6) {
                                        Text(source.rawValue)
                                    }
                                    .tag(source)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .onChange(of: viewModel.animeRuleSource) { oldValue, newValue in
                                Task {
                                    await viewModel.switchAnimeRuleSource(to: newValue)
                                }
                            }
                            
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(LiquidGlassColors.textTertiary)
                                
                                Text(viewModel.animeRuleSource == .kazumi 
                                     ? "使用 Kazumi 社区维护的规则(16+ 个源)"
                                     : "使用你自己仓库的规则")
                                    .font(.system(size: 11))
                                    .foregroundStyle(LiquidGlassColors.textTertiary)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                }
            }

            SettingsSection(
                title: t("cacheManagement"),
                subtitle: t("cacheManagementDesc"),
                accentColor: LiquidGlassColors.primaryPink
            ) {
                SettingsSurfaceCard(padding: 0, tint: LiquidGlassColors.primaryPink.opacity(0.08)) {
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t("cacheUsed"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(LiquidGlassColors.textPrimary)

                                Text(t("thumbnailsTemp"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(LiquidGlassColors.textSecondary)
                            }

                            Spacer()

                            Text(viewModel.cacheSize)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(LiquidGlassColors.textPrimary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 12)

                        SettingsProgressBar(
                            progress: viewModel.cacheProgress,
                            color: selectedTab.accentColor
                        )
                        .padding(.horizontal, 20)

                        HStack {
                            Text(t("clearWhenLarge"))
                                .font(.system(size: 12))
                                .foregroundStyle(LiquidGlassColors.textSecondary)

                            Spacer()

                            SettingsActionButton(title: t("clearCache"), tint: Color.red.opacity(0.88), role: .destructive) {
                                showClearCacheAlert = true
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
    }

    private var downloadSettings: some View {
        settingsPage {
            SettingsSection(
                title: t("downloadPrefs"),
                subtitle: t("downloadPrefsDesc"),
                accentColor: selectedTab.accentColor
            ) {
                SettingsSurfaceCard(padding: 0, tint: selectedTab.accentColor.opacity(0.08)) {
                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: t("autoDownloadOriginal"),
                            subtitle: t("autoDownloadDesc"),
                            isOn: $viewModel.autoDownloadOriginal
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                        SettingsRowDivider()
                            .padding(.horizontal, 20)

                        SettingsToggleRow(
                            title: t("saveToDownloadsFolder"),
                            subtitle: t("saveToDownloadsDesc"),
                            isOn: $viewModel.saveToDownloads
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                }
            }

            SettingsSection(
                title: t("downloadTasks"),
                subtitle: t("downloadTasksDesc"),
                accentColor: LiquidGlassColors.accentCyan
            ) {
                SettingsSurfaceCard(padding: 0, tint: LiquidGlassColors.accentCyan.opacity(0.07)) {
                    if viewModel.downloadTaskViewModel.tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(t("noDownloadTasks"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LiquidGlassColors.textPrimary)

                            Text(t("downloadTasksHint"))
                                .font(.system(size: 12))
                                .foregroundStyle(LiquidGlassColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                    } else {
                        VStack(spacing: 14) {
                            ForEach(Array(viewModel.downloadTaskViewModel.tasks.prefix(6).enumerated()), id: \.element.id) { index, task in
                                DownloadTaskSettingsRow(task: task)

                                if index < min(viewModel.downloadTaskViewModel.tasks.count, 6) - 1 {
                                    SettingsRowDivider()
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                    }
                }
            }
        }
    }

    private var schedulerSettings: some View {
        settingsPage {
            SettingsSection(
                title: t("autoReplace"),
                subtitle: t("autoReplaceDesc"),
                accentColor: LiquidGlassColors.onlineGreen
            ) {
                SettingsSurfaceCard(padding: 0, tint: LiquidGlassColors.onlineGreen.opacity(0.07)) {
                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: t("enableAutoReplace"),
                            subtitle: viewModel.schedulerViewModel.isRunning
                                ? t("currentlyRunning")
                                : t("currentlyStopped"),
                            isOn: schedulerEnabledBinding
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                        SettingsRowDivider()
                            .padding(.horizontal, 20)

                        HStack {
                            SettingsStatusBadge(
                                title: viewModel.schedulerViewModel.isRunning ? t("running") : t("stopped"),
                                systemImage: viewModel.schedulerViewModel.isRunning ? "play.circle.fill" : "pause.circle.fill",
                                color: viewModel.schedulerViewModel.isRunning ? LiquidGlassColors.onlineGreen : LiquidGlassColors.textTertiary
                            )

                            Spacer()

                            if let wallpaper = viewModel.schedulerViewModel.lastChangedWallpaper {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(t("recentChange"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(LiquidGlassColors.textSecondary)
                                    Text(wallpaper.id)
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(LiquidGlassColors.textPrimary)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                }
            }

            SettingsSection(
                title: t("replaceRhythm"),
                subtitle: t("replaceRhythmDesc"),
                accentColor: selectedTab.accentColor
            ) {
                SettingsSurfaceCard(padding: 0, tint: selectedTab.accentColor.opacity(0.08)) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t("replaceInterval"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(LiquidGlassColors.textPrimary)

                                Text(t("intervalDesc"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(LiquidGlassColors.textSecondary)
                            }

                            Spacer()

                            Picker(t("interval"), selection: Binding(
                                get: { viewModel.schedulerViewModel.config.intervalMinutes },
                                set: { viewModel.schedulerViewModel.updateInterval($0) }
                            )) {
                                ForEach(SchedulerConfig.intervalOptions, id: \.self) { minutes in
                                    Text(intervalLabel(for: minutes)).tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 160)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                        SettingsRowDivider()
                            .padding(.horizontal, 20)

                        VStack(alignment: .leading, spacing: 10) {
                            Text(t("replaceOrder"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LiquidGlassColors.textPrimary)

                            Picker(t("order"), selection: Binding(
                                get: { viewModel.schedulerViewModel.config.order },
                                set: { viewModel.schedulerViewModel.updateOrder($0) }
                            )) {
                                Text(t("sequential")).tag(ScheduleOrder.sequential)
                                Text(t("random")).tag(ScheduleOrder.random)
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                        SettingsRowDivider()
                            .padding(.horizontal, 20)

                        VStack(alignment: .leading, spacing: 10) {
                            Text(t("wallpaperSource"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LiquidGlassColors.textPrimary)

                            Picker(t("source"), selection: Binding(
                                get: { viewModel.schedulerViewModel.config.source },
                                set: { viewModel.schedulerViewModel.updateSource($0) }
                            )) {
                                Text(t("online")).tag(WallpaperSource.online)
                                Text(t("local")).tag(WallpaperSource.local)
                                Text(t("favorites")).tag(WallpaperSource.favorites)
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                }
            }
        }
    }

    private var aboutSettings: some View {
        settingsPage {
            SettingsSurfaceCard(padding: 0, tint: selectedTab.accentColor.opacity(0.08)) {
                HStack(spacing: 18) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(LiquidGlassColors.borderDefault, lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 6) {
                        Text(t("wallhaven"))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(LiquidGlassColors.textPrimary)

                        Text("\(t("version")) \(viewModel.appVersion)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LiquidGlassColors.textSecondary)

                        Text(t("elegantApp"))
                            .font(.system(size: 13))
                            .foregroundStyle(LiquidGlassColors.textSecondary)
                    }

                    Spacer()
                }
                .padding(20)
            }

            SettingsSection(
                title: t("projectInfo"),
                subtitle: t("projectInfoDesc"),
                accentColor: selectedTab.accentColor
            ) {
                SettingsSurfaceCard(padding: 0, tint: selectedTab.accentColor.opacity(0.08)) {
                    VStack(spacing: 0) {
                        SettingsInfoRow(title: t("developer"), value: "jipika")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                        SettingsRowDivider()
                            .padding(.horizontal, 20)
                        SettingsInfoRow(title: t("dataSource"), value: "wallhaven.cc / motionbgs.com")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                        SettingsRowDivider()
                            .padding(.horizontal, 20)
                        SettingsInfoRow(title: t("techStack"), value: "SwiftUI + AppKit")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                }
            }

            SettingsSection(
                title: t("externalLinks"),
                subtitle: t("externalLinksDesc"),
                accentColor: LiquidGlassColors.tertiaryBlue
            ) {
                SettingsSurfaceCard(padding: 0, tint: LiquidGlassColors.tertiaryBlue.opacity(0.08)) {
                    VStack(spacing: 0) {
                        SettingsLinkRow(
                            title: t("visitWebsite"),
                            subtitle: t("visitWebsiteDesc"),
                            destination: URL(string: "https://wallhaven.cc")!
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)

                        SettingsRowDivider()
                            .padding(.horizontal, 20)

                        SettingsLinkRow(
                            title: t("reportProblem"),
                            subtitle: t("reportProblemDesc"),
                            destination: URL(string: "https://github.com")!
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                }
            }
        }
    }

    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                content()
            }
            .frame(maxWidth: contentColumnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 34)
        }
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

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)

                Spacer(minLength: 16)

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.large)
            }

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
            }

            Spacer()

            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
        }
    }
}

private struct SettingsLinkButton: View {
    let title: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.up.right")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LiquidGlassColors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .liquidGlassSurface(.subtle, tint: LiquidGlassColors.tertiaryBlue.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsActionButton: View {
    let title: String
    let tint: Color
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .liquidGlassSurface(.prominent, tint: tint.opacity(0.4), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsLinkRow: View {
    let title: String
    let subtitle: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LiquidGlassColors.tertiaryBlue)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsStatusBadge: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .liquidGlassSurface(.subtle, tint: color.opacity(0.18), in: Capsule())
    }
}

private struct SettingsProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = max(0, min(progress, 1))
            let fillWidth = max(12, proxy.size.width * clampedProgress)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LiquidGlassColors.midBackground.opacity(0.5))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0.8),
                                LiquidGlassColors.primaryPink.opacity(0.85)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
            }
        }
        .frame(height: 10)
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(LiquidGlassColors.borderSubtle)
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}

private struct DownloadTaskSettingsRow: View {
    let task: DownloadTask

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .lineLimit(1)

                    Text(task.badgeText.isEmpty ? task.itemID : "\(task.itemID) · \(task.badgeText)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            SettingsProgressBar(progress: task.progress, color: statusColor)
        }
    }

    private var statusText: String {
        switch task.status {
        case .pending: return t("status.pending")
        case .downloading: return t("status.downloading")
        case .paused: return t("status.paused")
        case .completed: return t("status.completed")
        case .failed: return t("status.failed")
        case .cancelled: return t("status.cancelled")
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending: return LiquidGlassColors.textTertiary
        case .downloading: return LiquidGlassColors.tertiaryBlue
        case .paused: return LiquidGlassColors.warningOrange
        case .completed: return LiquidGlassColors.onlineGreen
        case .failed: return Color.red.opacity(0.85)
        case .cancelled: return LiquidGlassColors.textTertiary
        }
    }
}
