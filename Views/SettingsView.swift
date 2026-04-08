import SwiftUI
import AppKit

// MARK: - 毛玻璃背景视图
private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

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
        case .general: return "gearshape"
        case .download: return "arrow.down.circle"
        case .scheduler: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

// MARK: - 侧边栏导航项
private struct SidebarItem: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .frame(width: 20)

                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))

                Spacer()
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : (isHovered ? Color.white.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.12) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering && !isSelected
            }
        }
    }
}

// MARK: - 主视图 - 左侧导航栏 + 右侧内容区
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var localization = LocalizationService.shared
    @State private var selectedTab: SettingsTab = .general

    private let sidebarWidth: CGFloat = 180

    var body: some View {
        HStack(spacing: 0) {
            // === 左侧导航栏 ===
            sidebar

            Divider()
                .background(Color.white.opacity(0.08))

            // === 右侧内容区 ===
            VStack(spacing: 0) {
                // 标题行（标题 + 关闭按钮）
                HStack {
                    Text(selectedTab.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Spacer()

                    Button {
                        (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)

                Divider()
                    .background(Color.white.opacity(0.06))

                // 内容区域
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
        }
        .background(Color(hex: "1C1C1E"))
        .id(localization.currentLanguage)
    }

    // MARK: 左侧导航栏
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                SidebarItem(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    }
                )
            }

            Spacer()
        }
        .padding(.top, 16)
        .padding(.horizontal, 10)
        .frame(width: sidebarWidth)
        .background(
            ZStack {
                Color(hex: "1A1A1A").opacity(0.85)

                VisualEffectView(material: .hudWindow)
                    .allowsHitTesting(false)
            }
        )
    }
}

// MARK: - 通用设置标签
private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showClearCacheAlert = false
    @State private var importProfileURL = ""

    @AppStorage("grain_texture_enabled") private var grainTextureEnabled = true
    @AppStorage("grain_texture_quality") private var grainTextureQuality = "high"

    private var apiKeyBinding: Binding<String> {
        Binding(get: { viewModel.apiKey }, set: { viewModel.apiKey = $0 })
    }

    private var languageBinding: Binding<LocalizationService.Language> {
        Binding(
            get: { LocalizationService.shared.currentLanguage },
            set: { LocalizationService.shared.setLanguage($0) }
        )
    }

    var body: some View {
        MacSettingsForm {
            // 语言设置组
            MacSettingsSection(header: t("languageRegion")) {
                VStack(spacing: 0) {
                    // 显示语言
                    HStack(spacing: 12) {
                        Text(t("displayLanguage"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))

                        Spacer()

                        Menu {
                            ForEach(LocalizationService.Language.allCases, id: \.self) { language in
                                Button(language.displayName) {
                                    LocalizationService.shared.setLanguage(language)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(LocalizationService.shared.currentLanguage.displayName)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(Color.white.opacity(0.6))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.35))
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                    // 语言描述
                    HStack {
                        Text(t("displayLanguageDesc"))
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.4))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            // 外观设置组
            MacSettingsSection(header: t("appearance")) {
                MacSettingsRow(
                    title: t("grainTextureEffect"),
                    subtitle: t("grainTextureSubtitle"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $grainTextureEnabled)
                }

                MacSettingsRow(
                    title: t("autoDownloadOriginal"),
                    subtitle: nil,
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.autoDownloadOriginal)
                }
            }

            // 动态壁纸设置组
            MacSettingsSection(header: t("videoWallpaper")) {
                MacSettingsRow(
                    title: t("showPosterOnLock"),
                    subtitle: t("showPosterOnLockDesc"),
                    showDivider: false
                ) {
                    MacToggle(isOn: Binding(
                        get: { viewModel.showPosterOnLock },
                        set: { newValue in
                            viewModel.showPosterOnLock = newValue
                            viewModel.syncVideoWallpaperSettings()
                        }
                    ))
                }
            }

            // 系统设置组
            MacSettingsSection(header: t("system")) {
                MacSettingsRow(
                    title: t("launchAtLogin"),
                    subtitle: nil,
                    showDivider: true
                ) {
                    MacToggle(isOn: Binding(
                        get: { viewModel.launchAtLogin },
                        set: { _ in viewModel.toggleLaunchAtLogin() }
                    ))
                }

                MacSettingsRow(
                    title: t("saveToDownloadsFolder"),
                    subtitle: nil,
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.saveToDownloads)
                }
            }

            // 数据管理组
            MacSettingsSection(header: t("dataManagement")) {
                // API Key
                HStack(spacing: 12) {
                    Text(t("apiKey"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Spacer()

                    SecureField(t("api.key.placeholder"), text: apiKeyBinding)
                        .font(.system(size: 12, weight: .regular))
                        .textFieldStyle(.plain)
                        .frame(width: 200)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                )
                        )
                        .foregroundStyle(Color.white.opacity(0.85))

                    Link(destination: URL(string: "https://wallhaven.cc/settings/account")!) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(hex: "0A84FF").opacity(0.7))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                // 缓存管理
                HStack(spacing: 12) {
                    Text(t("clearCache"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Spacer()

                    Text(viewModel.cacheSize)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.4))

                    Button(t("clear")) {
                        showClearCacheAlert = true
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: "FF453A"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .alert(t("clearCache"), isPresented: $showClearCacheAlert) {
            Button(t("cancel"), role: .cancel) {}
            Button(t("clear"), role: .destructive) {
                Task { await viewModel.clearCache() }
            }
        } message: {
            Text(t("clearCacheConfirm"))
        }
    }
}

// MARK: - 下载设置标签
private struct DownloadSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        MacSettingsForm {
            MacSettingsSection(header: t("downloadPreferences")) {
                MacSettingsRow(
                    title: t("autoDownloadOriginal"),
                    subtitle: t("autoDownloadDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.autoDownloadOriginal)
                }

                MacSettingsRow(
                    title: t("saveToDownloadsFolder"),
                    subtitle: t("saveToDownloadsDesc"),
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.saveToDownloads)
                }
            }
        }
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
        MacSettingsForm {
            // 开关组
            MacSettingsSection(header: t("autoReplace")) {
                MacSettingsRow(
                    title: t("enableAutoReplace"),
                    subtitle: viewModel.schedulerViewModel.isRunning ? t("currentlyRunning") : t("currentlyStopped"),
                    showDivider: false
                ) {
                    MacToggle(isOn: schedulerEnabledBinding)
                }
            }

            // 配置组
            MacSettingsSection(header: t("scheduleConfig")) {
                // 间隔选择
                HStack(spacing: 12) {
                    Text(t("replaceInterval"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Spacer()

                    Menu {
                        ForEach(SchedulerConfig.intervalOptions, id: \.self) { minutes in
                            Button(intervalLabel(for: minutes)) {
                                viewModel.schedulerViewModel.updateInterval(minutes)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(intervalLabel(for: viewModel.schedulerViewModel.config.intervalMinutes))
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(Color.white.opacity(0.6))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.35))
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                dividerLine

                // 顺序选择
                HStack(spacing: 12) {
                    Text(t("replaceOrder"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Spacer()

                    Picker("", selection: Binding(get: { viewModel.schedulerViewModel.config.order }, set: { viewModel.schedulerViewModel.updateOrder($0) })) {
                        Text(t("sequential")).tag(ScheduleOrder.sequential)
                        Text(t("random")).tag(ScheduleOrder.random)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                dividerLine

                // 来源选择
                HStack(spacing: 12) {
                    Text(t("wallpaperSource"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Spacer()

                    Picker("", selection: Binding(get: { viewModel.schedulerViewModel.config.source }, set: { viewModel.schedulerViewModel.updateSource($0) })) {
                        Text(t("online")).tag(WallpaperSource.online)
                        Text(t("local")).tag(WallpaperSource.local)
                        Text(t("favorites")).tag(WallpaperSource.favorites)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var dividerLine: some View {
        Divider()
            .background(Color.white.opacity(0.06))
            .padding(.leading, 16)
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
    @State private var showAutoUpdateSheet = false

    private var wallpaperRuleSourceText: String {
        if viewModel.currentRuleRepository.isEmpty {
            return "GitHub"
        }
        let url = viewModel.currentRuleRepository
        if let range = url.range(of: "github.com/") {
            let repo = String(url[range.upperBound...])
            return repo.replacingOccurrences(of: ".git", with: "")
        }
        return "GitHub"
    }

    var body: some View {
        MacSettingsForm {
            // 自动更新区域
            autoUpdateSection

            // 项目信息组
            MacSettingsSection(header: t("projectInfo")) {
                infoRow(title: t("developer"), value: "jipika", isLast: false)
                infoRow(title: t("wallpaperRuleSource"), value: wallpaperRuleSourceText, isLast: false)
                infoRow(title: t("animeRuleSource"), value: "KazumiRules", isLast: false)
                infoRow(title: t("techStack"), value: "SwiftUI + AppKit", isLast: true)
            }

            // 链接组
            MacSettingsSection(header: t("links")) {
                Link(destination: URL(string: "https://wallhaven.cc")!) {
                    MacLinkRow(title: t("visitWebsite"), action: nil)
                }
                .buttonStyle(.plain)

                Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                Link(destination: URL(string: "https://github.com/jipika/WaifuX")!) {
                    MacLinkRow(title: t("reportProblem"), action: nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func infoRow(title: String, value: String, isLast: Bool) -> some View {
        MacInfoRow(title: title, value: value)
        if !isLast {
            Divider()
                .background(Color.white.opacity(0.06))
                .padding(.leading, 16)
        }
    }
    
    // MARK: - 自动更新区域
    
    @ViewBuilder
    private var autoUpdateSection: some View {
        MacSettingsSection {
            VStack(alignment: .leading, spacing: 16) {
                // 应用信息头部
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("WaifuX")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.92))

                        Text(viewModel.updateChecker.fullVersionString)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }

                    Spacer()

                    // 更新状态指示
                    updateStatusIndicator
                }
                
                // 更新操作区域
                HStack(spacing: 12) {
                    Button {
                        Task {
                            await viewModel.checkForUpdates()
                            // 如果有更新，显示弹窗
                            if case .updateAvailable = viewModel.updateCheckResult {
                                showAutoUpdateSheet = true
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if viewModel.isCheckingUpdate || viewModel.updateChecker.isChecking {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.8)
                            }
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                            Text(viewModel.isCheckingUpdate || viewModel.updateChecker.isChecking ? "检查中..." : "检查更新")
                                .font(.system(size: 13))
                        }
                        .frame(height: 28)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isCheckingUpdate || viewModel.updateChecker.isChecking)
                    
                    if let lastCheck = viewModel.updateChecker.lastCheckDate {
                        Text("上次检查: \(formatRelativeDate(lastCheck))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                
                // 已下载但未安装的提示
                if case .downloaded = UpdateManager.shared.state {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("更新已下载")
                            .font(.system(size: 13))
                        Spacer()
                        Button {
                            UpdateManager.shared.installUpdate()
                        } label: {
                            Text("立即安装")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding(14)
        }
        .sheet(isPresented: $showAutoUpdateSheet) {
            if case .updateAvailable(let current, let release, let commit) = viewModel.updateCheckResult {
                AutoUpdateSheet(
                    currentVersion: current,
                    latestVersion: release.version,
                    release: release,
                    commit: commit,
                    onClose: { showAutoUpdateSheet = false }
                )
            }
        }
    }
    
    @ViewBuilder
    private var updateStatusIndicator: some View {
        switch viewModel.updateCheckResult {
        case .updateAvailable(_, let release, _):
            Button {
                showAutoUpdateSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.blue)
                    Text("v\(release.version) 可用")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.blue)
                }
            }
            .buttonStyle(.plain)
            
        case .noUpdate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("已是最新")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        default:
            EmptyView()
        }
    }
    
    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 设置页更新检查视图

struct SettingsUpdateSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var updateChecker = UpdateChecker.shared
    @ObservedObject var updateManager = UpdateManager.shared
    @State private var showUpdateSheet = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 版本信息
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前版本")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(viewModel.appVersion)
                        .font(.system(size: 14, weight: .medium))
                }
                
                Spacer()
                
                // 更新状态指示
                updateStatusView
            }
            
            // 检查更新按钮
            HStack(spacing: 12) {
                Button {
                    Task {
                        await viewModel.checkForUpdates()
                        // 如果有更新，自动显示弹窗
                        if case .updateAvailable = viewModel.updateCheckResult {
                            showUpdateSheet = true
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isCheckingUpdate || updateChecker.isChecking {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.8)
                        }
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                        Text(viewModel.isCheckingUpdate || updateChecker.isChecking ? "检查中..." : "检查更新")
                            .font(.system(size: 13))
                    }
                    .frame(height: 28)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isCheckingUpdate || updateChecker.isChecking)
                
                if let lastCheck = updateChecker.lastCheckDate {
                    Text("上次检查: \(formatRelativeDate(lastCheck))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            
            // 已下载但未安装的提示
            if case .downloaded(let path) = updateManager.state {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("更新已下载")
                        .font(.system(size: 13))
                    Spacer()
                    Button {
                        updateManager.installUpdate()
                    } label: {
                        Text("立即安装")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
        .sheet(isPresented: $showUpdateSheet) {
            if case .updateAvailable(let current, let release, let commit) = viewModel.updateCheckResult {
                AutoUpdateSheet(
                    currentVersion: current,
                    latestVersion: release.version,
                    release: release,
                    commit: commit,
                    onClose: { showUpdateSheet = false }
                )
            }
        }
    }
    
    @ViewBuilder
    private var updateStatusView: some View {
        switch viewModel.updateCheckResult {
        case .updateAvailable(_, let release, _):
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                Text("v\(release.version) 可用")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.blue)
            }
        case .noUpdate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("已是最新版本")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        default:
            EmptyView()
        }
    }
    
    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    AutoUpdateSheet(
        currentVersion: "38.0.22",
        latestVersion: "38.0.25",
        release: GitHubRelease(
            tagName: "v38.0.25",
            name: "WaifuX 38.0.25",
            body: "修复了一些问题",
            htmlUrl: "https://github.com/jipika/WaifuX/releases/tag/v38.0.25",
            publishedAt: "2024-01-01T00:00:00Z",
            prerelease: false,
            draft: false,
            targetCommitish: "abc1234"
        ),
        commit: GitHubCommit(
            sha: "abc1234567890",
            commit: GitHubCommit.CommitDetails(
                message: "修复了内存泄漏问题\n\n优化了图片加载性能",
                author: GitHubCommit.CommitDetails.AuthorInfo(
                    name: "Developer",
                    date: "2024-01-01T00:00:00Z"
                )
            )
        ),
        onClose: {}
    )
    .frame(width: 400, height: 500)
}
