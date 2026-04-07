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

// MARK: - 设置标签栏组件 - 液态玻璃风格
private struct SettingsSegmentedControl: View {
    @Binding var selectedTab: SettingsTab
    let controlHeight: CGFloat

    @Namespace private var selectionNamespace
    @State private var hoveredTab: SettingsTab?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(labelColor(for: tab))
                        .frame(width: itemWidth(for: tab), height: controlHeight - 8)
                        .background {
                            if selectedTab == tab {
                                selectedTabBackground(for: tab)
                            } else if hoveredTab == tab {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.1))
                            }
                        }
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.16)) {
                        hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .liquidGlassSurface(.subtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func itemWidth(for tab: SettingsTab) -> CGFloat {
        switch tab {
        case .general: return 56
        case .download: return 68
        case .scheduler: return 68
        case .about: return 52
        }
    }

    private func labelColor(for tab: SettingsTab) -> Color {
        if selectedTab == tab {
            return Color.white.opacity(0.95)
        }
        if hoveredTab == tab {
            return Color.white.opacity(0.8)
        }
        return Color.white.opacity(0.5)
    }

    @ViewBuilder
    private func selectedTabBackground(for tab: SettingsTab) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(0.2))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
            )
            .matchedGeometryEffect(id: "settingsSelectedTab", in: selectionNamespace)
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
            .padding(.bottom, 10)
            .background(Color(hex: "0D0D0D"))

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
            .background(Color(hex: "1C1C1E"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "0D0D0D"))
        .id(localization.currentLanguage)
    }
}

// MARK: - 通用设置标签
private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showClearCacheAlert = false
    @State private var importProfileURL = ""
    
    // 噪点效果设置
    @AppStorage("grain_texture_enabled") private var grainTextureEnabled = true
    @AppStorage("grain_texture_quality") private var grainTextureQuality = "high"

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
    
    private var localization: LocalizationService { LocalizationService.shared }

    var body: some View {
        MacSettingsForm {
            // 外观效果组 - 蓝色图标
            MacSettingsSection {
                // 噪点效果开关
                MacSettingsRow(
                    icon: "sparkles",
                    iconColor: Color(hex: "0A84FF"),
                    title: t("grainTextureEffect"),
                    subtitle: t("grainTextureSubtitle"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $grainTextureEnabled)
                }
                
                // 自动下载原图
                MacSettingsRow(
                    icon: "arrow.down.circle",
                    iconColor: Color(hex: "0A84FF"),
                    title: t("autoDownloadOriginal"),
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.autoDownloadOriginal)
                }
            }
            
            // 启动和系统设置组 - 绿色图标
            MacSettingsSection {
                MacSettingsRow(
                    icon: "power",
                    iconColor: Color(hex: "30D158"),
                    title: t("launchAtLogin"),
                    showDivider: true
                ) {
                    MacToggle(isOn: Binding(
                        get: { viewModel.launchAtLogin },
                        set: { _ in viewModel.toggleLaunchAtLogin() }
                    ))
                }
                
                MacSettingsRow(
                    icon: "folder",
                    iconColor: Color(hex: "30D158"),
                    title: t("saveToDownloadsFolder"),
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.saveToDownloads)
                }
            }
            
            // API 和缓存组 - 橙色/红色图标
            MacSettingsSection {
                // API Key 行
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(hex: "FF9F0A"))
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "key.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t("apiKey"))
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.9))
                        
                        Text(viewModel.apiKey.isEmpty ? t("apiNotConfigured") : t("apiConfigured"))
                            .font(.system(size: 12))
                            .foregroundStyle(viewModel.apiKey.isEmpty ? Color.white.opacity(0.4) : Color(hex: "30D158"))
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        SecureField(t("api.key.placeholder"), text: apiKeyBinding)
                            .font(.system(size: 13))
                            .textFieldStyle(.plain)
                            .frame(width: 260)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(6)
                            .foregroundStyle(Color.white)
                        
                        Link(destination: URL(string: "https://wallhaven.cc/settings/account")!) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "0A84FF"))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                
                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.leading, 58)
                
                // 缓存管理行
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(hex: "FF453A"))
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t("clearCache"))
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.9))
                        Text(viewModel.cacheSize)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    
                    Spacer()
                    
                    Button(t("clear")) {
                        showClearCacheAlert = true
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(hex: "FF453A"))
                    .controlSize(.regular)
                    .scaleEffect(1.3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            
            // 语言设置组 - 紫色图标
            MacSettingsSection {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(hex: "BF5AF2"))
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "globe")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    
                    Text(t("displayLanguage"))
                        .font(.system(size: 15, weight: .regular))
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
                            Text(localization.currentLanguage.displayName)
                                .font(.system(size: 13))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
            // 下载偏好设置组 - 蓝色图标
            MacSettingsSection {
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
                    iconColor: Color(hex: "0A84FF"),
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
            // 自动替换开关组 - 紫色图标
            MacSettingsSection {
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

            // 替换节奏设置组
            MacSettingsSection {
                // 间隔选择
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(hex: "0A84FF"))
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "timer")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    
                    Text(t("replaceInterval"))
                        .font(.system(size: 15, weight: .regular))
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
                                .font(.system(size: 13))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                
                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.leading, 58)
                
                // 顺序选择
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(hex: "30D158"))
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    
                    Text(t("replaceOrder"))
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.9))
                    
                    Spacer()
                    
                    Picker("", selection: Binding(
                        get: { viewModel.schedulerViewModel.config.order },
                        set: { viewModel.schedulerViewModel.updateOrder($0) }
                    )) {
                        Text(t("sequential")).tag(ScheduleOrder.sequential)
                        Text(t("random")).tag(ScheduleOrder.random)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 110, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                
                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.leading, 58)
                
                // 来源选择
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(hex: "FF9F0A"))
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    
                    Text(t("wallpaperSource"))
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.9))
                    
                    Spacer()
                    
                    Picker("", selection: Binding(
                        get: { viewModel.schedulerViewModel.config.source },
                        set: { viewModel.schedulerViewModel.updateSource($0) }
                    )) {
                        Text(t("online")).tag(WallpaperSource.online)
                        Text(t("local")).tag(WallpaperSource.local)
                        Text(t("favorites")).tag(WallpaperSource.favorites)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 140, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
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
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("WaifuX")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.9))

                        Text(viewModel.updateChecker.fullVersionString)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }

                    Spacer()

                    if viewModel.hasUpdate {
                        Button(t("downloadUpdate")) {
                            viewModel.openDownloadPage()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "30D158"))
                        .controlSize(.regular)
                        .scaleEffect(1.3)
                    } else {
                        Button(t("checkForUpdates")) {
                            Task { await viewModel.checkForUpdates() }
                        }
                        .disabled(viewModel.isCheckingUpdate)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .scaleEffect(1.3)
                    }
                }
                .padding(14)
            }

            // 项目信息组
            MacSettingsSection {
                MacSettingsRow(
                    icon: "person.fill",
                    iconColor: Color(hex: "BF5AF2"),
                    title: t("developer"),
                    showDivider: true
                ) {
                    Text("jipika")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                
                MacSettingsRow(
                    icon: "photo.on.rectangle.angled",
                    iconColor: Color(hex: "0A84FF"),
                    title: t("wallpaperRuleSource"),
                    showDivider: true
                ) {
                    Text(wallpaperRuleSourceText)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                
                MacSettingsRow(
                    icon: "play.rectangle.fill",
                    iconColor: Color(hex: "FF9F0A"),
                    title: t("animeRuleSource"),
                    showDivider: true
                ) {
                    Text("KazumiRules")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                
                MacSettingsRow(
                    icon: "hammer.fill",
                    iconColor: Color(hex: "30D158"),
                    title: t("techStack"),
                    showDivider: false
                ) {
                    Text("SwiftUI + AppKit")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }

            // 外部链接组
            MacSettingsSection {
                Link(destination: URL(string: "https://wallhaven.cc")!) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(hex: "0A84FF"))
                                .frame(width: 32, height: 32)
                            
                            Image(systemName: "globe")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        
                        Text(t("visitWebsite"))
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.9))
                        
                        Spacer()
                        
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                
                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.leading, 58)

                Link(destination: URL(string: "https://github.com/jipika/WaifuX")!) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(hex: "FF453A"))
                                .frame(width: 32, height: 32)
                            
                            Image(systemName: "exclamationmark.bubble")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        
                        Text(t("reportProblem"))
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.9))
                        
                        Spacer()
                        
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
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
}


