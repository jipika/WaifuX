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
        case .general: return "gearshape"
        case .download: return "arrow.down.circle"
        case .scheduler: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

// MARK: - 窗口控制按钮（保持不变）
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

// MARK: - 设置标签栏 - Apple 风格分段控件
private struct SettingsSegmentedControl: View {
    @Binding var selectedTab: SettingsTab
    let controlHeight: CGFloat

    @Namespace private var selectionNamespace
    @State private var hoveredTab: SettingsTab?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .medium))

                        Text(tab.title)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(labelColor(for: tab))
                    .frame(minWidth: itemWidth(for: tab), height: controlHeight - 10)
                    .background {
                        if selectedTab == tab {
                            ZStack {
                                // 主背景
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.22),
                                                Color.white.opacity(0.14)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )

                                // 高光边缘
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.4),
                                                Color.white.opacity(0.15),
                                                Color.white.opacity(0.05)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 0.5
                                    )

                                // 内部微弱阴影感
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
                            }
                            .matchedGeometryEffect(id: "settingsSelectedTab", in: selectionNamespace)
                        } else if hoveredTab == tab {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.18)) {
                        hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
                    }
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func itemWidth(for tab: SettingsTab) -> CGFloat {
        switch tab {
        case .general: return 64
        case .download: return 76
        case .scheduler: return 76
        case .about: return 60
        }
    }

    private func labelColor(for tab: SettingsTab) -> Color {
        if selectedTab == tab {
            return .white
        }
        if hoveredTab == tab {
            return Color.white.opacity(0.75)
        }
        return Color.white.opacity(0.45)
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
            // 顶部工具栏
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
            .padding(.bottom, 12)
            .background(
                // 工具栏微妙渐变背景
                ZStack {
                    Color(hex: "0D0D0D")

                    // 底部分隔线
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    Color.white.opacity(0.02),
                                    Color.clear
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(height: 1)
                        .offset(y: 0.5)
                }
            )

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
            .background(settingsContentBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "0D0D0D"))
        .id(localization.currentLanguage)
    }

    /// 内容区微妙渐变背景
    private var settingsContentBackground: some View {
        ZStack {
            // 基础深色
            Color(hex: "111113")

            // 微妙的径向光晕
            RadialGradient(
                colors: [
                    Color.white.opacity(0.015),
                    Color.clear
                ],
                center: .top,
                startRadius: 50,
                endRadius: 350
            )
        }
    }
}

// MARK: - 通用设置标签（Apple 精致风格）
private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showClearCacheAlert = false
    @State private var importProfileURL = ""

    // 噪点效果设置
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

    private var localization: LocalizationService { LocalizationService.shared }

    var body: some View {
        MacSettingsForm {
            // === 外观设置组 ===
            MacSettingsSection(header: t("appearance"), icon: "paintbrush") {
                MacSettingsRow(
                    icon: "sparkles",
                    iconColor: Color(hex: "0A84FF"),
                    title: t("grainTextureEffect"),
                    subtitle: t("grainTextureSubtitle"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $grainTextureEnabled)
                }

                MacSettingsRow(
                    icon: "arrow.down.circle",
                    iconColor: Color(hex: "5856D6"),
                    title: t("autoDownloadOriginal"),
                    subtitle: nil,
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.autoDownloadOriginal)
                }
            }

            // === 启动与系统设置组 ===
            MacSettingsSection(header: t("system"), icon: "desktopcomputer") {
                MacSettingsRow(
                    icon: "power",
                    iconColor: Color(hex: "30D158"),
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
                    icon: "folder.badge.plus",
                    iconColor: Color(hex: "34C759"),
                    title: t("saveToDownloadsFolder"),
                    subtitle: nil,
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.saveToDownloads)
                }
            }

            // === API 与缓存管理组 ===
            MacSettingsSection(header: t("dataManagement"), icon: "externaldrive") {
                // API Key 行
                HStack(spacing: 13) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: "FF9F0A").opacity(0.15))
                            .frame(width: 32, height: 32)

                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "FF9F0A").opacity(0.95), Color(hex: "FF8000")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 28, height: 28)

                        Image(systemName: "key.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("apiKey"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.92))

                        Text(viewModel.apiKey.isEmpty ? t("apiNotConfigured") : t("apiConfigured"))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(viewModel.apiKey.isEmpty ? Color.white.opacity(0.38) : Color(hex: "30D158"))
                    }

                    Spacer()

                    HStack(spacing: 7) {
                        SecureField(t("api.key.placeholder"), text: apiKeyBinding)
                            .font(.system(size: 13, weight: .regular))
                            .textFieldStyle(.plain)
                            .frame(width: 240)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.07))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                    )
                            )
                            .foregroundStyle(Color.white.opacity(0.9))

                        Link(destination: URL(string: "https://wallhaven.cc/settings/account")!) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color(hex: "0A84FF"))
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)

                Divider()
                    .background(
                        LinearGradient(
                            colors: [Color.clear, Color.white.opacity(0.08), Color.white.opacity(0.04), Color.clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.leading, 58)

                // 缓存管理行
                HStack(spacing: 13) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: "FF453A").opacity(0.15))
                            .frame(width: 32, height: 32)

                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "FF453A").opacity(0.95), Color(hex: "E63B33")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 28, height: 28)

                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("clearCache"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.92))
                        Text(viewModel.cacheSize)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.38))
                    }

                    Spacer()

                    Button(t("clear")) {
                        showClearCacheAlert = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "FF453A"))
                    .controlSize(.small)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
            }

            // === 语言与地区设置组 ===
            MacSettingsSection(header: t("languageRegion"), icon: "globe") {
                HStack(spacing: 13) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: "BF5AF2").opacity(0.15))
                            .frame(width: 32, height: 32)

                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "BF5AF2").opacity(0.95), Color(hex: "A048DD")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 28, height: 28)

                        Image(systemName: "globe")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text(t("displayLanguage"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.92))

                    Spacer()

                    Menu {
                        ForEach(LocalizationService.Language.allCases, id: \.self) { language in
                            Button(language.displayName) {
                                LocalizationService.shared.setLanguage(language)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(localization.currentLanguage.displayName)
                                .font(.system(size: 13, weight: .medium))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Color.white.opacity(0.55))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                                )
                        )
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
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
            MacSettingsSection(header: t("downloadPreferences"), icon: "arrow.down.circle") {
                MacSettingsRow(
                    icon: "arrow.down.circle",
                    iconColor: Color(hex: "0A84FF"),
                    title: t("autoDownloadOriginal"),
                    subtitle: t("autoDownloadDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.autoDownloadOriginal)
                }

                MacSettingsRow(
                    icon: "folder",
                    iconColor: Color(hex: "007AFF"),
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
            MacSettingsSection(header: t("autoReplace"), icon: "clock.arrow.circlepath") {
                MacSettingsRow(
                    icon: "clock.arrow.circlepath",
                    iconColor: Color(hex: "BF5AF2"),
                    title: t("enableAutoReplace"),
                    subtitle: viewModel.schedulerViewModel.isRunning ? t("currentlyRunning") : t("currentlyStopped"),
                    showDivider: false
                ) {
                    MacToggle(isOn: schedulerEnabledBinding)
                }
            }

            // 调度配置组
            MacSettingsSection(header: t("scheduleConfig"), icon: "slider.horizontal.3") {
                // 间隔选择
                HStack(spacing: 13) {
                    ZStack {
                        Circle().fill(Color(hex: "0A84FF").opacity(0.15)).frame(width: 32, height: 32)
                        Circle().fill(LinearGradient(colors: [Color(hex: "0A84FF").opacity(0.9), Color(hex: "0066CC")], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 28, height: 28)
                        Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text(t("replaceInterval")).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.white.opacity(0.92))
                    Spacer()
                    Menu {
                        ForEach(SchedulerConfig.intervalOptions, id: \.self) { minutes in
                            Button(intervalLabel(for: minutes)) {
                                viewModel.schedulerViewModel.updateInterval(minutes)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(intervalLabel(for: viewModel.schedulerViewModel.config.intervalMinutes)).font(.system(size: 13, weight: .medium))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Color.white.opacity(0.55))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5)))
                    }.menuStyle(.borderlessButton)
                }.padding(.horizontal, 15).padding(.vertical, 11)

                dividerLine

                // 顺序选择
                HStack(spacing: 13) {
                    ZStack {
                        Circle().fill(Color(hex: "30D158").opacity(0.15)).frame(width: 32, height: 32)
                        Circle().fill(LinearGradient(colors: [Color(hex: "30D158").opacity(0.9), Color(hex: "24AA48")], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 28, height: 28)
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text(t("replaceOrder")).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.white.opacity(0.92))
                    Spacer()
                    Picker("", selection: Binding(get: { viewModel.schedulerViewModel.config.order }, set: { viewModel.schedulerViewModel.updateOrder($0) })) {
                        Text(t("sequential")).tag(ScheduleOrder.sequential)
                        Text(t("random")).tag(ScheduleOrder.random)
                    }.pickerStyle(.segmented).controlSize(.small).frame(width: 110, alignment: .trailing)
                }.padding(.horizontal, 15).padding(.vertical, 11)

                dividerLine

                // 来源选择
                HStack(spacing: 13) {
                    ZStack {
                        Circle().fill(Color(hex: "FF9F0A").opacity(0.15)).frame(width: 32, height: 32)
                        Circle().fill(LinearGradient(colors: [Color(hex: "FF9F0A").opacity(0.9), Color(hex: "E68A00")], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 28, height: 28)
                        Image(systemName: "photo.on.rectangle").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text(t("wallpaperSource")).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.white.opacity(0.92))
                    Spacer()
                    Picker("", selection: Binding(get: { viewModel.schedulerViewModel.config.source }, set: { viewModel.schedulerViewModel.updateSource($0) })) {
                        Text(t("online")).tag(WallpaperSource.online)
                        Text(t("local")).tag(WallpaperSource.local)
                        Text(t("favorites")).tag(WallpaperSource.favorites)
                    }.pickerStyle(.segmented).controlSize(.small).frame(width: 140, alignment: .trailing)
                }.padding(.horizontal, 15).padding(.vertical, 11)
            }
        }
    }

    private var dividerLine: some View {
        Divider()
            .background(LinearGradient(colors: [Color.clear, Color.white.opacity(0.08), Color.white.opacity(0.04), Color.clear], startPoint: .leading, endPoint: .trailing))
            .padding(.leading, 58)
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
            // 应用信息卡片
            MacSettingsSection {
                HStack(spacing: 16) {
                    // 图标带精致阴影
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("WaifuX")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.94))

                        Text(viewModel.updateChecker.fullVersionString)
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.42))
                    }

                    Spacer()

                    if viewModel.hasUpdate {
                        Button(t("downloadUpdate")) {
                            viewModel.openDownloadPage()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "30D158"))
                        .controlSize(.regular)
                    } else {
                        Button(t("checkForUpdates")) {
                            Task { await viewModel.checkForUpdates() }
                        }
                        .disabled(viewModel.isCheckingUpdate)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
                .padding(16)
            }

            // 项目信息组
            MacSettingsSection(header: t("projectInfo"), icon: "curlybraces") {
                infoRow(icon: "person.fill", color: Color(hex: "BF5AF2"), title: t("developer"), value: "jipika", isLast: false)
                infoRow(icon: "photo.on.rectangle.angled", color: Color(hex: "0A84FF"), title: t("wallpaperRuleSource"), value: wallpaperRuleSourceText, isLast: false)
                infoRow(icon: "play.rectangle.fill", color: Color(hex: "FF9F0A"), title: t("animeRuleSource"), value: "KazumiRules", isLast: false)
                infoRow(icon: "hammer.fill", color: Color(hex: "30D158"), title: t("techStack"), value: "SwiftUI + AppKit", isLast: true)
            }

            // 外部链接组
            MacSettingsSection(header: t("links"), icon: "link") {
                Link(destination: URL(string: "https://wallhaven.cc")!) {
                    externalLinkRow(
                        icon: "globe",
                        color: Color(hex: "0A84FF"),
                        title: t("visitWebsite")
                    )
                }
                .buttonStyle(.plain)

                Divider()
                    .background(LinearGradient(colors: [Color.clear, Color.white.opacity(0.08), Color.white.opacity(0.04), Color.clear], startPoint: .leading, endPoint: .trailing))
                    .padding(.leading, 58)

                Link(destination: URL(string: "https://github.com/jipika/WaifuX")!) {
                    externalLinkRow(
                        icon: "exclamationmark.bubble",
                        color: Color(hex: "FF453A"),
                        title: t("reportProblem")
                    )
                }
                .buttonStyle(.plain)
            }
        }
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

    /// 统一的信息行组件
    @ViewBuilder
    private func infoRow(icon: String, color: Color, title: String, value: String, isLast: Bool) -> some View {
        MacSettingsRow(
            icon: icon,
            iconColor: color,
            title: title,
            subtitle: nil,
            showDivider: !isLast
        ) {
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }

    /// 统一的外部链接行组件
    private func externalLinkRow(icon: String, color: Color, title: String) -> some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 32, height: 32)
                Circle().fill(LinearGradient(colors: [color.opacity(0.9), color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 28, height: 28)
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.white.opacity(0.92))
            Spacer()
            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.35))
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }
}
