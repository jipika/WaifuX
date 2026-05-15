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
    case workshop
    case scheduler
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return t("general")
        case .download: return t("download")
        case .workshop: return t("wallpaperEngine")
        case .scheduler: return t("scheduler")
        case .about: return t("about")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .download: return "arrow.down.circle"
        case .workshop: return "gearshape.2" // Steam/Workshop 风格
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
                    case .workshop:
                        WorkshopSettingsTab(viewModel: viewModel)
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

                VisualEffectView(material: .sidebar)
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
                            Text(LocalizationService.shared.currentLanguage.displayName)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Color.white.opacity(0.6))
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
                    subtitle: t("grainTextureEffectDesc"),
                    showDivider: viewModel.grainTextureEnabled
                ) {
                    MacToggle(isOn: $viewModel.grainTextureEnabled)
                }

                if viewModel.grainTextureEnabled {
                    HStack(spacing: 12) {
                        Text(t("grainIntensity"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))

                        Spacer()

                        Slider(value: $viewModel.grainIntensity, in: 0...1, step: 0.05)
                            .frame(width: 160)
                            .tint(Color(hex: "30D158"))

                        Text("\(Int(viewModel.grainIntensity * 100))%")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .frame(width: 36, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            // 动态壁纸设置组
            MacSettingsSection(header: t("videoWallpaper")) {
                MacSettingsRow(
                    title: t("pauseWhenOtherAppForeground"),
                    subtitle: t("pauseWhenOtherAppForegroundDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: Binding(
                        get: { viewModel.pauseWhenOtherAppForeground },
                        set: { newValue in
                            viewModel.pauseWhenOtherAppForeground = newValue
                            viewModel.syncAutoPauseSettings()
                        }
                    ))
                }

                MacSettingsRow(
                    title: t("pauseWhenFullscreenCovers"),
                    subtitle: t("pauseWhenFullscreenCoversDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: Binding(
                        get: { viewModel.pauseWhenFullscreenCovers },
                        set: { newValue in
                            viewModel.pauseWhenFullscreenCovers = newValue
                            viewModel.syncAutoPauseSettings()
                        }
                    ))
                }

                MacSettingsRow(
                    title: t("pauseOnBatteryPower"),
                    subtitle: t("pauseOnBatteryPowerDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: Binding(
                        get: { viewModel.pauseOnBatteryPower },
                        set: { newValue in
                            viewModel.pauseOnBatteryPower = newValue
                            viewModel.syncAutoPauseSettings()
                        }
                    ))
                }

                MacSettingsRow(
                    title: t("hdrEnabled"),
                    subtitle: t("hdrEnabledDesc"),
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.hdrEnabled)
                }
            }

            // 代理设置组
            MacSettingsSection(header: t("proxySettings")) {
                MacSettingsRow(
                    title: t("proxyEnabled"),
                    subtitle: t("proxyEnabledDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.proxyEnabled)
                }

                if viewModel.proxyEnabled {
                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                    HStack(spacing: 12) {
                        Text(t("proxyHost"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))

                        Spacer()

                        TextField(t("proxyHostPlaceholder"), text: $viewModel.proxyHost)
                            .font(.system(size: 12, weight: .regular))
                            .textFieldStyle(.plain)
                            .frame(width: 140)
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
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                    HStack(spacing: 12) {
                        Text(t("proxyPort"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))

                        Spacer()

                        TextField(t("proxyPortPlaceholder"), text: $viewModel.proxyPort)
                            .font(.system(size: 12, weight: .regular))
                            .textFieldStyle(.plain)
                            .frame(width: 80)
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
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
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

                    TextField(t("api.key.placeholder"), text: apiKeyBinding)
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

                Text(t("apiKeyDescription"))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

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
    @State private var showMigrationSheet = false
    @State private var isRepairing = false
    @State private var showRepairAlert = false
    @State private var repairResultMessage = ""
    @State private var pathRefreshID = UUID()

    var body: some View {
        MacSettingsForm {
            MacSettingsSection(header: t("downloadPreferences")) {
                MacSettingsRow(
                    title: t("saveToDownloadsFolder"),
                    subtitle: t("saveToDownloadsDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.saveToDownloads)
                }

                // 下载目录选择
                MacSettingsRow(
                    title: t("downloadDirectory"),
                    subtitle: currentPathDisplay,
                    showDivider: true
                ) {
                    Button {
                        showMigrationSheet = true
                    } label: {
                        Text(t("change"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }

                // 数据修复按钮
                MacSettingsRow(
                    title: t("repairData"),
                    subtitle: t("repairDataDesc"),
                    showDivider: false
                ) {
                    Button {
                        showRepairAlert = true
                    } label: {
                        HStack(spacing: 4) {
                            if isRepairing {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                            }
                            Text(isRepairing ? t("repairing") : t("repair"))
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.orange.opacity(0.2))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .disabled(isRepairing)
                }
            }
        }
        .id(pathRefreshID)
        .sheet(isPresented: $showMigrationSheet) {
            DirectoryMigrationSheet(isPresented: $showMigrationSheet)
        }
        .alert(t("repairData"), isPresented: $showRepairAlert) {
            Button(t("cancel"), role: .cancel) {}
            Button(t("repair"), role: .destructive) {
                startRepair()
            }
        } message: {
            Text(t("repairDataConfirm"))
        }
        .alert(repairResultMessage, isPresented: Binding(
            get: { !repairResultMessage.isEmpty && !isRepairing },
            set: { if !$0 { repairResultMessage = "" } }
        )) {
            Button("OK") { repairResultMessage = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadPathChanged)) { _ in
            pathRefreshID = UUID()
        }
    }

    private var currentPathDisplay: String {
        let path = DownloadPathManager.shared.currentRootPathDisplay
        if path.count > 60 {
            return "..." + String(path.suffix(57))
        }
        return path
    }

    private func startRepair() {
        isRepairing = true
        Task {
            let result = await DirectoryMigrationService.shared.repairBrokenRecords()
            isRepairing = false
            if result.repairedCount == 0 && result.removedCount == 0 && result.migratedCount == 0 {
                repairResultMessage = t("repairNoIssues")
            } else {
                repairResultMessage = String(
                    format: t("repairResult"),
                    result.repairedCount, result.migratedCount, result.removedCount, result.healthyCount
                )
            }
            NotificationCenter.default.post(name: .downloadPathChanged, object: nil)
        }
    }
}

// MARK: - 调度器设置标签
private struct SchedulerSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    private var screens: [NSScreen] {
        NSScreen.screens
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

            // 每屏配置
            MacSettingsSection(header: t("scheduleConfig")) {
                ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                    let screenID = screen.wallpaperScreenIdentifier
                    let displayConfig = viewModel.schedulerViewModel.displayConfig(for: screenID)

                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("\(t("display")) \(index + 1) · \(screen.localizedName)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.9))

                            Spacer()

                            MacToggle(isOn: Binding(
                                get: { displayConfig.isEnabled },
                                set: { viewModel.schedulerViewModel.updateDisplayEnabled($0, for: screenID) }
                            ))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        if displayConfig.isEnabled {
                            dividerLine

                            // 间隔选择
                            HStack(spacing: 12) {
                                Text(t("replaceInterval"))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.9))

                                Spacer()

                                Menu {
                                    ForEach(SchedulerConfig.intervalOptions, id: \.self) { minutes in
                                        Button(intervalLabel(for: minutes)) {
                                            viewModel.schedulerViewModel.updateDisplayInterval(minutes, for: screenID)
                                        }
                                    }
                                } label: {
                                    Text(intervalLabel(for: displayConfig.intervalMinutes))
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundStyle(Color.white.opacity(0.6))
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

                                Picker("", selection: Binding(
                                    get: { displayConfig.order },
                                    set: { viewModel.schedulerViewModel.updateDisplayOrder($0, for: screenID) }
                                )) {
                                    Text(t("sequential")).tag(ScheduleOrder.sequential)
                                    Text(t("random")).tag(ScheduleOrder.random)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 130, alignment: .trailing)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            dividerLine

                            // 内容类型选择
                            HStack(spacing: 12) {
                                Text(t("contentTypes"))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.9))

                                Spacer()

                                HStack(spacing: 16) {
                                    Toggle(isOn: Binding(
                                        get: { displayConfig.includeWallpapers },
                                        set: { viewModel.schedulerViewModel.updateDisplayIncludeWallpapers($0, for: screenID) }
                                    )) {
                                        Text(t("wallpapers"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.white.opacity(0.8))
                                    }
                                    .toggleStyle(.checkbox)

                                    Toggle(isOn: Binding(
                                        get: { displayConfig.includeMedia },
                                        set: { viewModel.schedulerViewModel.updateDisplayIncludeMedia($0, for: screenID) }
                                    )) {
                                        Text(t("media"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.white.opacity(0.8))
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }

                    if index < screens.count - 1 {
                        dividerLine
                    }
                }
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
        case 1: return "1 \(t("minutes"))"
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
    @State private var showResetAlert = false

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
        ZStack {
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
                    MacLinkRow(title: t("visitWebsite"), action: {
                        if let url = URL(string: "https://github.com/jipika/WaifuX") {
                            NSWorkspace.shared.open(url)
                        }
                    })

                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                    MacLinkRow(title: t("reportProblem"), action: {
                        if let url = URL(string: "https://github.com/jipika/WaifuX") {
                            NSWorkspace.shared.open(url)
                        }
                    })

                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                    MacLinkRow(title: t("joinQQGroup"), action: {
                        if let url = URL(string: "https://qm.qq.com/q/SRCj8msygq") {
                            NSWorkspace.shared.open(url)
                        }
                    })
                }

                // 重置所有数据
                MacSettingsSection(header: t("resetAllData")) {
                    HStack(spacing: 12) {
                        Text(t("resetAllData"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))

                        Spacer()

                        Button(t("reset")) {
                            showResetAlert = true
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: "FF453A"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .alert(t("resetAllData"), isPresented: $showResetAlert) {
                Button(t("cancel"), role: .cancel) {}
                Button(t("reset"), role: .destructive) {
                    Task { await viewModel.resetAllData() }
                }
            } message: {
                Text(t("resetAllDataConfirm"))
            }

            // 更新弹窗 - 使用 ZStack overlay，居中显示，不创建新窗口
            if showAutoUpdateSheet,
               case .updateAvailable(let current, let release, let commit) = viewModel.updateCheckResult {
                AutoUpdateSheet(
                    currentVersion: current,
                    latestVersion: release.version,
                    release: release,
                    commit: commit,
                    onClose: { showAutoUpdateSheet = false }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.animation(.easeOut(duration: 0.25)))
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
                            // 用户主动点击，强制检查
                            await viewModel.checkForUpdates(force: true)
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
        ZStack {
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
                            // 用户主动点击，强制检查
                            await viewModel.checkForUpdates(force: true)
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
                if case .downloaded(_) = updateManager.state {
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

            // 更新弹窗 - 使用 ZStack overlay，居中显示，不创建新窗口
            if showUpdateSheet,
               case .updateAvailable(let current, let release, let commit) = viewModel.updateCheckResult {
                AutoUpdateSheet(
                    currentVersion: current,
                    latestVersion: release.version,
                    release: release,
                    commit: commit,
                    onClose: { showUpdateSheet = false }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.animation(.easeOut(duration: 0.25)))
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


// MARK: - Workshop 设置标签
private struct WorkshopSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var sourceManager = WorkshopSourceManager.shared
    @ObservedObject private var workshopService = WorkshopService.shared
    @State private var steamUsername = ""
    @State private var steamPassword = ""
    @State private var steamGuardCode = ""
    @State private var isSteamPasswordVisible = false
    @State private var showLoginForm = false
    @State private var isVerifyingSteamLogin = false
    @State private var steamLoginStatusText: String?
    @State private var cleanupResult: (count: Int, bytesFreed: Int64)?
    @State private var isCleaningUp = false
    @State private var steamCMDStatus: SteamCMDStatus = .downloading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 标题
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("wallpaperEngineSettings"))
                        .font(.system(size: 20, weight: .bold))
                    Text(t("wallpaperEngineSettingsDesc"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Divider()

                // SteamCMD 状态
                steamCMDStatusSection

                // SteamCMD 登录
                steamCMDLoginSection

                // 清理下载缓存
                cleanupSection

                // 显示全部内容（仅登录 Steam 后显示）
                if sourceManager.isSteamAuthenticated {
                    MacSettingsSection {
                        MacSettingsRow(title: t("workshop.showAllContent"), subtitle: t("workshop.showAllContentDesc"), showDivider: false) {
                            MacToggle(isOn: Binding(
                                get: { viewModel.showAllWorkshopContent },
                                set: { viewModel.showAllWorkshopContent = $0 }
                            ))
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
        }
        .onAppear {
            refreshSteamCMDStatus()
            sourceManager.refreshStoredSteamCredentials()
            syncCredentialPresentation()
        }
        .onChange(of: sourceManager.steamCredentialState) { _, _ in
            syncCredentialPresentation()
        }
    }

    private var steamCMDLoginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.cyan)
                Text(t("steamCMDAccount"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if case .available = sourceManager.steamCredentialState {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
            }

            if case .available(let username) = sourceManager.steamCredentialState, !showLoginForm {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: t("accountSaved"), username))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("下次下载需要 Steam 账号的 Workshop 内容时会直接使用这组凭据。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.85))
                    }
                    Spacer()
                    Button(t("relogin")) {
                        steamUsername = username
                        steamPassword = ""
                        steamGuardCode = ""
                        steamLoginStatusText = nil
                        showLoginForm = true
                    }
                    .controlSize(.small)
                    Button(t("logout")) {
                        sourceManager.clearSteamCredentials()
                        steamUsername = ""
                        steamPassword = ""
                        steamGuardCode = ""
                        steamLoginStatusText = "已清除已保存账号。"
                        showLoginForm = true
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(Color.white.opacity(0.03))
                .cornerRadius(8)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Label(credentialStateTitle, systemImage: credentialStateIcon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(credentialStateColor)
                        Spacer()
                    }

                    Text(credentialStateDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField(t("steamUsernamePlaceholder"), text: $steamUsername)
                        .textFieldStyle(.roundedBorder)
                    steamPasswordField
                    TextField(t("steamGuardCodePlaceholder"), text: $steamGuardCode)
                        .textFieldStyle(.roundedBorder)
                    Text("只有在邮箱验证码或备用令牌场景下才需要填写验证码；大多数情况下可以留空，按提示去 Steam App 里确认即可。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack {
                        if isVerifyingSteamLogin {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("正在验证账号并连接 SteamCMD…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else if let steamLoginStatusText {
                            Text(steamLoginStatusText)
                                .font(.system(size: 11))
                                .foregroundStyle(loginStatusColor)
                        }

                        Spacer()

                        if case .available = sourceManager.steamCredentialState {
                            Button("取消") {
                                showLoginForm = false
                                steamPassword = ""
                                steamGuardCode = ""
                                steamLoginStatusText = nil
                            }
                            .controlSize(.small)
                        }

                        Button("验证并保存") {
                            guard !steamUsername.isEmpty, !steamPassword.isEmpty else { return }
                            isVerifyingSteamLogin = true
                            steamLoginStatusText = nil
                            Task {
                                do {
                                    try await workshopService.verifySteamLogin(
                                        username: steamUsername,
                                        password: steamPassword,
                                        guardCode: steamGuardCode
                                    )
                                    sourceManager.setSteamCredentials(
                                        username: steamUsername,
                                        password: steamPassword,
                                        guardCode: steamGuardCode
                                    )
                                    await MainActor.run {
                                        steamPassword = ""
                                        steamGuardCode = ""
                                        if case .available = sourceManager.steamCredentialState {
                                            steamLoginStatusText = "账号验证成功，已保存到本机。"
                                            showLoginForm = false
                                        } else {
                                            steamLoginStatusText = "账号验证成功，但本机保存状态未更新。可以先尝试下载，如仍提示需要登录，再重新保存一次。"
                                        }
                                        isVerifyingSteamLogin = false
                                    }
                                } catch let error as WorkshopError {
                                    await MainActor.run {
                                        switch error {
                                        case .guardCodeRequired(let msg):
                                            steamLoginStatusText = msg
                                        case .timeout:
                                            steamLoginStatusText = "连接 SteamCMD 超时，请稍后重试。"
                                        case .loginTimeout:
                                            steamLoginStatusText = "Steam 登录超时，请检查网络或代理设置后重试。"
                                        case .sessionExpired:
                                            steamLoginStatusText = "Steam 登录已过期，请重新验证。"
                                        case .invalidCredentials:
                                            steamLoginStatusText = "账号、密码或验证码不正确，请检查后重试。"
                                        case .steamLoginFailed(let msg):
                                            steamLoginStatusText = msg
                                        case .steamcmdNotFound:
                                            steamLoginStatusText = "SteamCMD 组件不可用，请先检查安装状态。"
                                        case .downloadFailed(let msg):
                                            steamLoginStatusText = msg
                                        case .executionFailed(let msg):
                                            steamLoginStatusText = "SteamCMD 执行失败：\(msg)"
                                        default:
                                            steamLoginStatusText = error.localizedDescription
                                        }
                                        isVerifyingSteamLogin = false
                                    }
                                } catch {
                                    await MainActor.run {
                                        steamLoginStatusText = error.localizedDescription
                                        isVerifyingSteamLogin = false
                                    }
                                }
                            }
                        }
                        .controlSize(.small)
                        .disabled(steamUsername.isEmpty || steamPassword.isEmpty || isVerifyingSteamLogin)
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.03))
                .cornerRadius(8)
            }

            Text("SteamCMD 下载会使用这里保存的账号进行验证。未保存账号时，涉及 Steam 账号校验的 Workshop 内容将无法完成下载。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    // MARK: - SteamCMD 状态
    private var steamCMDStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.cyan)
                Text(t("steamCMDStatus"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("刷新") {
                    refreshSteamCMDStatus()
                }
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                Circle()
                    .fill(steamCMDStatusColor(steamCMDStatus))
                    .frame(width: 8, height: 8)

                Text(steamCMDStatusText(steamCMDStatus))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Spacer()

                steamCMDStatusTrailingLabel(steamCMDStatus)
            }
            .padding(12)
            .background(Color.white.opacity(0.03))
            .cornerRadius(8)
        }
    }

    private var steamPasswordField: some View {
        HStack(spacing: 6) {
            Group {
                if isSteamPasswordVisible {
                    TextField(t("steamPasswordPlaceholder"), text: $steamPassword)
                } else {
                    SecureField(t("steamPasswordPlaceholder"), text: $steamPassword)
                }
            }
            .textFieldStyle(.roundedBorder)

            Button {
                isSteamPasswordVisible.toggle()
            } label: {
                Image(systemName: isSteamPasswordVisible ? "eye.slash" : "eye")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(isSteamPasswordVisible ? "隐藏密码" : "显示密码")
            .accessibilityLabel(isSteamPasswordVisible ? "隐藏 Steam 密码" : "显示 Steam 密码")
        }
    }

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                Text("清理下载缓存")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            Text("删除下载失败产生的空文件夹，释放磁盘空间")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if let result = cleanupResult, result.count > 0 {
                    Label("已清理 \(result.count) 个文件夹，释放 \(WorkshopService.formattedByteCount(result.bytesFreed))",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else if let result = cleanupResult, result.count == 0 {
                    Label("没有需要清理的文件夹", systemImage: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Spacer()

                Button {
                    isCleaningUp = true
                    Task {
                        let result = workshopService.cleanupFailedDownloads()
                        withAnimation {
                            cleanupResult = result
                            isCleaningUp = false
                        }
                    }
                } label: {
                    if isCleaningUp {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("清理")
                    }
                }
                .controlSize(.small)
                .disabled(isCleaningUp)
            }
            .padding(12)
            .background(Color.white.opacity(0.03))
            .cornerRadius(8)
        }
    }

    private func steamCMDStatusColor(_ status: SteamCMDStatus) -> Color {
        switch status {
        case .ready: return .green
        case .notInstalled: return .orange
        case .error: return .red
        case .downloading: return .blue
        }
    }

    private func steamCMDStatusText(_ status: SteamCMDStatus) -> String {
        switch status {
        case .ready: return t("steamCMDReady")
        case .notInstalled: return t("steamCMDNotInstalled")
        case .error(let msg): return String(format: t("steamCMDError"), msg)
        case .downloading: return t("downloading")
        }
    }

    @ViewBuilder
    private func steamCMDStatusTrailingLabel(_ status: SteamCMDStatus) -> some View {
        switch status {
        case .ready:
            Label(t("steamCMDReady"), systemImage: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .notInstalled:
            Label(t("steamCMDNotInstalled"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        case .error(let msg):
            Label(String(format: t("steamCMDError"), msg), systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .lineLimit(2)
        case .downloading:
            Label(t("downloading"), systemImage: "arrow.down.circle")
                .font(.system(size: 12))
                .foregroundStyle(.blue)
        }
    }

    private var loginStatusColor: Color {
        guard let steamLoginStatusText else { return .secondary }
        if steamLoginStatusText.contains("成功") || steamLoginStatusText.contains("已保存") {
            return .green
        }
        if steamLoginStatusText.contains("超时") || steamLoginStatusText.contains("错误") || steamLoginStatusText.contains("失败") {
            return .orange
        }
        return .secondary
    }

    private var credentialStateTitle: String {
        switch sourceManager.steamCredentialState {
        case .unknown:
            return "尚未加载本地账号"
        case .missing:
            return "未发现已保存账号"
        case .failure:
            return "读取本地账号失败"
        case .available(let username):
            return "已检测到账号 \(username)"
        }
    }

    private var credentialStateDescription: String {
        switch sourceManager.steamCredentialState {
        case .unknown:
            return "正在准备本地账号信息。"
        case .missing:
            return "当前没有检测到已保存的 SteamCMD 账号。你可以直接填写下面的表单进行验证并保存。"
        case .failure(let message):
            return "读取本地已保存账号时发生错误：\(message)"
        case .available:
            return "本机已经保存了可用账号。如果你想换账号，可以直接在下面重新验证并覆盖保存。"
        }
    }

    private var credentialStateIcon: String {
        switch sourceManager.steamCredentialState {
        case .unknown: return "questionmark.circle"
        case .missing: return "person.crop.circle.badge.exclamationmark"
        case .failure: return "exclamationmark.triangle"
        case .available: return "checkmark.circle"
        }
    }

    private var credentialStateColor: Color {
        switch sourceManager.steamCredentialState {
        case .available: return .green
        case .unknown: return .secondary
        case .missing: return .orange
        case .failure: return .red
        }
    }

    private func refreshSteamCMDStatus() {
        steamCMDStatus = workshopService.checkSteamCMDStatus()
    }

    private func syncCredentialPresentation() {
        if case .available(let username) = sourceManager.steamCredentialState {
            steamUsername = username
            if let credentials = sourceManager.steamCredentials {
                steamPassword = credentials.password
                steamGuardCode = credentials.guardCode ?? ""
            }
            if !isVerifyingSteamLogin {
                showLoginForm = false
            }
        } else if !isVerifyingSteamLogin {
            showLoginForm = true
        }
    }
}

// MARK: - 目录迁移 Sheet
private struct DirectoryMigrationSheet: View {
    @Binding var isPresented: Bool
    @State private var isMigrating = false
    @State private var progress: MigrationProgress = MigrationProgress(
        step: .copying,
        currentFileName: "",
        processedCount: 0,
        totalCount: 0,
        fractionCompleted: 0
    )
    @State private var result: MigrationResult?
    @State private var selectedDirectoryPath: String = ""

    private let downloadPathManager = DownloadPathManager.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(t("migrateDownloadDirectory"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                Text(t("migrateDownloadDirectoryDesc"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            if let result = result {
                resultView(result: result)
            } else if isMigrating {
                migrationProgressView
            } else {
                directorySelectionView
            }

            Spacer()
        }
        .frame(width: 480, height: 320)
        .background(Color(hex: "0F1115"))
    }

    private var directorySelectionView: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(t("currentPath"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                Text(downloadPathManager.currentRootPathDisplay)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 24)

            if !selectedDirectoryPath.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(selectedDirectoryPath)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 24)
            }

            HStack(spacing: 12) {
                Button {
                    isPresented = false
                } label: {
                    Text(t("cancel"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    pickDirectory()
                } label: {
                    Text(t("selectDirectory"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(hex: "3B82F6"))
                        )
                }
                .buttonStyle(.plain)

                if !selectedDirectoryPath.isEmpty {
                    Button {
                        startMigration()
                    } label: {
                        Text(t("migrate"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(hex: "10B981"))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.top, 16)
    }

    private var migrationProgressView: some View {
        VStack(spacing: 20) {
            Spacer()

            // 阶段描述
            Text(progress.step.description)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)

            // 当前文件名
            Text(progress.currentFileName.isEmpty ? t("preparing") : progress.currentFileName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .frame(maxWidth: 360)

            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "3B82F6"), Color(hex: "60A5FA")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * CGFloat(progress.fractionCompleted)), height: 8)
                    }
                }
                .frame(height: 8)

                HStack {
                    Text("\(progress.processedCount) / \(progress.totalCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    Text("\(Int(progress.fractionCompleted * 100))%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: 360)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func resultView(result: MigrationResult) -> some View {
        VStack(spacing: 20) {
            Spacer()

            switch result {
            case .success(let movedFiles, _):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(hex: "10B981"))

                Text(t("migrationSuccess"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Text("\(t("migratedFiles")): \(movedFiles)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))

            case .partial(let successCount, let failCount, let errors):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(hex: "F59E0B"))

                Text(t("migrationPartial"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(t("success")): \(successCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "10B981"))
                    Text("\(t("failed")): \(failCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "EF4444"))
                }

                if !errors.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(errors.prefix(5).enumerated()), id: \.offset) { _, error in
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxHeight: 60)
                }

            case .failure(let error):
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(hex: "EF4444"))

                Text(t("migrationFailed"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button {
                isPresented = false
            } label: {
                Text(t("done"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func pickDirectory() {
        guard let selectedURL = downloadPathManager.showDirectoryPicker() else { return }
        selectedDirectoryPath = selectedURL.path
    }

    private func startMigration() {
        guard !selectedDirectoryPath.isEmpty else { return }

        let oldRoot = downloadPathManager.rootFolderURL
        let selectedURL = URL(fileURLWithPath: selectedDirectoryPath)

        let oldPath = oldRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let newParentPath = selectedURL.resolvingSymlinksInPath().standardizedFileURL.path
        let oldPathSlash = oldPath.hasSuffix("/") ? oldPath : oldPath + "/"
        let newPathSlash = newParentPath.hasSuffix("/") ? newParentPath : newParentPath + "/"
        if oldPath == newParentPath || newPathSlash.hasPrefix(oldPathSlash) || oldPathSlash.hasPrefix(newPathSlash) {
            result = .failure(error: t("invalidDirectorySelection"))
            return
        }

        isMigrating = true

        guard downloadPathManager.setCustomRoot(parentURL: selectedURL) else {
            isMigrating = false
            result = .failure(error: t("failedToSetDirectory"))
            return
        }

        let newRoot = downloadPathManager.rootFolderURL

        Task {
            let migrationResult = await DirectoryMigrationService.shared.migrate(
                from: oldRoot,
                to: newRoot
            ) { progress in
                self.progress = progress
            }

            self.result = migrationResult
            self.isMigrating = false

            NotificationCenter.default.post(name: .downloadPathChanged, object: nil)
            await LocalWallpaperScanner.shared.forceRescan()
        }
    }
}

// MARK: - Cursor Extension
private extension View {
    func pointingHandCursor() -> some View {
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
