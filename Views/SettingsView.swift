import SwiftUI
import AppKit
import ApplicationServices
import CoreImage
import CoreImage.CIFilterBuiltins

private let settingsSliderTint = Color(hex: "30D158")

private func snappedSliderBinding(
    _ binding: Binding<Double>,
    in range: ClosedRange<Double>,
    step: Double
) -> Binding<Double> {
    Binding(
        get: { binding.wrappedValue },
        set: { newValue in
            let snappedValue = ((newValue - range.lowerBound) / step).rounded() * step + range.lowerBound
            binding.wrappedValue = min(max(snappedValue, range.lowerBound), range.upperBound)
        }
    )
}

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

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView {
        DragHandleView()
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {}
}

private final class DragHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - 设置标签
private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case modules
    case download
    case wallhaven
    case workshop
    case pixiv
    case konachan
    case scheduler
    case sync
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return t("general")
        case .modules: return t("settings.modules")
        case .download: return t("download")
        case .wallhaven: return t("wallhaven")
        case .workshop: return t("wallpaperEngine")
        case .pixiv: return "Pixiv"
        case .konachan: return "Konachan"
        case .scheduler: return t("scheduler")
        case .sync: return t("cloudSync")
        case .about: return t("about")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .modules: return "square.grid.2x2"
        case .download: return "arrow.down.circle"
        case .wallhaven: return "w.circle"
        case .workshop: return "gearshape.2" // Steam/Workshop 风格
        case .pixiv: return "p.circle"
        case .konachan: return "k.circle"
        case .scheduler: return "clock.arrow.circlepath"
        case .sync: return "icloud"
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
                // 标题行（标题 + 拖拽区域，原生红绿灯在左侧）
                HStack {
                    Text(selectedTab.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))

                    WindowDragHandle()
                        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                }
                .padding(.leading, 20)
                .padding(.trailing, 28)
                .padding(.vertical, 16)

                Divider()
                    .background(Color.white.opacity(0.06))

                // 内容区域
                Group {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsTab(viewModel: viewModel)
                    case .modules:
                        ModulesSettingsTab(viewModel: viewModel)
                    case .download:
                        DownloadSettingsTab(viewModel: viewModel)
                    case .wallhaven:
                        WallhavenSettingsTab(viewModel: viewModel)
                    case .workshop:
                        WorkshopSettingsTab(viewModel: viewModel)
                    case .pixiv:
                        PixivSettingsTab()
                    case .konachan:
                        KonachanSettingsTab()
                    case .scheduler:
                        SchedulerSettingsTab(viewModel: viewModel)
                    case .sync:
                        SyncSettingsTab()
                    case .about:
                        AboutSettingsTab(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(hex: "1C1C1E"))
        .id(localization.currentLanguage)
        .onAppear {
            let key = "settings.openSchedulerOnNextAppearance"
            if WaifuXPreferences.shared.bool(forKey: key) {
                WaifuXPreferences.shared.removeObject(forKey: key)
                selectedTab = .scheduler
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSchedulerSettings)) { _ in
            WaifuXPreferences.shared.removeObject(forKey: "settings.openSchedulerOnNextAppearance")
            selectedTab = .scheduler
        }
    }

    // MARK: 左侧导航栏
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases.filter { $0 != .sync }, id: \.self) { tab in
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
        .padding(.top, 42)
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

// MARK: - 功能模块设置标签
private struct ModulesSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showRestartConfirm = false

    var body: some View {
        MacSettingsForm {
            // 功能模块开关组
            MacSettingsSection(header: t("settings.modules.title")) {
                MacSettingsRow(
                    title: t("settings.modules.wallpaper"),
                    subtitle: t("settings.modules.wallpaper.subtitle"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.wallpaperModuleEnabled)
                }

                MacSettingsRow(
                    title: t("settings.modules.media"),
                    subtitle: t("settings.modules.media.subtitle"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.mediaModuleEnabled)
                }

                MacSettingsRow(
                    title: t("settings.modules.anime"),
                    subtitle: t("settings.modules.anime.subtitle"),
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.animeModuleEnabled)
                }
            }

            // 待应用改动区块（仅当有改动时显示）
            if viewModel.hasPendingModuleChanges {
                MacSettingsSection(header: t("settings.modules.apply")) {
                    MacSettingsRow(
                        title: t("settings.modules.pending"),
                        subtitle: viewModel.pendingModulesDescription,
                        showDivider: false
                    ) {
                        Button(t("settings.modules.restartNow")) {
                            confirmRestart()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: "0A84FF"))
                    }
                }
            }
        }
        .glassAlert(t("settings.modules.restartConfirm.title"), isPresented: $showRestartConfirm,
                    message: t("settings.modules.restartConfirm.message"),
                    actions: [
                        GlassAlertAction(t("settings.modules.restartNow")) {
                            AppRelauncher.relaunch()
                        },
                        GlassAlertAction(t("cancel"), role: .cancel)
                    ])
    }

    /// 重启确认弹窗
    private func confirmRestart() {
        showRestartConfirm = true
    }
}

// MARK: - 通用设置标签
private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared
    @State private var showClearLockScreenAlert = false
    @State private var importProfileURL = ""

    /// 系统壁纸 store 的选择状态说明（设置页动态锁屏区展示）
    private var lockScreenSelectionDescription: String {
        switch viewModel.lockScreenSelectionStatus {
        case .selected: return t("lockScreenSelectionSelected")
        case .notSelected: return t("lockScreenSelectionNotSelected")
        case .unknown: return t("lockScreenSelectionUnknown")
        }
    }

    private var lockScreenSelectionColor: Color {
        switch viewModel.lockScreenSelectionStatus {
        case .selected: return Color(hex: "30D158")
        case .notSelected: return Color(hex: "FF9F0A")
        case .unknown: return Color.white.opacity(0.35)
        }
    }

    private var languageBinding: Binding<LocalizationService.Language> {
        Binding(
            get: { LocalizationService.shared.currentLanguage },
            set: { LocalizationService.shared.setLanguage($0) }
        )
    }

    private var needsWindowCoverageAccessibilityHint: Bool {
        viewModel.pauseWhenWindowCoverage && !AXIsProcessTrusted()
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
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
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.grainTextureEnabled)
                }

                if viewModel.grainTextureEnabled {
                    HStack(spacing: 12) {
                        Text(t("grainIntensity"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))

                        Spacer()

                        Slider(
                            value: snappedSliderBinding($viewModel.grainIntensity, in: 0...1, step: 0.05),
                            in: 0...1
                        )
                        .tint(settingsSliderTint)
                        .accessibilityLabel(t("grainIntensity"))
                        .frame(width: 160)

                        Text("\(Int(viewModel.grainIntensity * 100))%")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .frame(width: 36, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                MacSettingsRow(
                    title: t("compactMode"),
                    subtitle: t("compactModeDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $arcSettings.compactMode)
                }

                MacSettingsRow(
                    title: t("autoRemoveVideoLetterbox"),
                    subtitle: t("autoRemoveVideoLetterboxDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.autoRemoveVideoLetterbox)
                }

                MacSettingsRow(
                    title: t("portraitBlurFill"),
                    subtitle: t("portraitBlurFillDesc"),
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.portraitBlurFillEnabled)
                }
            }

            // 动态壁纸设置组
            MacSettingsSection(header: t("videoWallpaper")) {
                // 系统壁纸同步总开关（默认开启）：关闭后冻结 setDesktopImageURL 链路，
                // 仅 App 内 mp4/场景/web 动态壁纸引擎继续工作。
                MacSettingsRow(
                    title: t("systemWallpaperSync"),
                    subtitle: t("systemWallpaperSyncDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.systemWallpaperSyncEnabled)
                }
                .onAppear { viewModel.refreshWallpaperCacheAccessStatus() }

                MacSettingsRow(
                    title: t("externalVideoRenderer"),
                    subtitle: t("externalVideoRendererDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.externalVideoRendererEnabled)
                }

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
                    title: t("pauseInactiveDisplays"),
                    subtitle: t("pauseInactiveDisplaysDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: Binding(
                        get: { viewModel.pauseInactiveDisplays },
                        set: { newValue in
                            viewModel.pauseInactiveDisplays = newValue
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
                    title: t("pauseRotationOnBattery"),
                    subtitle: t("pauseRotationOnBatteryDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.pauseRotationOnBattery)
                }

                // 壁纸扩展守护：App 退出后 pkd 清杀扩展时自动重新拉载
                MacSettingsRow(
                    title: t("wallpaperExtensionKeeper"),
                    subtitle: t("wallpaperExtensionKeeperDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.wallpaperExtensionKeeperEnabled)
                }

                // 系统壁纸缓存授权提示：清理器改由主 App 执行后，「能不能读到缓存目录」
                // 直接决定磁盘会不会无限增长，所以必须在用户可见处给出出口。
                // 只在「同步开着（确实会产出这份缓存）且读不到」时才提示：
                // 关掉同步的用户不产生该缓存，提示他们授权只是噪音；
                // 这与 scheduleRun 在同步关闭时直接早退的逻辑保持一致。
                if viewModel.systemWallpaperSyncEnabled,
                   viewModel.wallpaperCacheInaccessibleRootCount > 0 {
                    MacSettingsRow(
                        title: t("wallpaperCacheAccessRequired"),
                        subtitle: t("wallpaperCacheAccessRequiredDesc"),
                        showDivider: true
                    ) {
                        Button {
                            openFullDiskAccessSettings()
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(hex: "0A84FF"))
                                .frame(width: 28, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(t("openFullDiskAccessSettings"))
                    }
                }

                MacSettingsRow(
                    title: t("pauseWhenWindowCoverage"),
                    subtitle: t("pauseWhenWindowCoverageDesc"),
                    showDivider: !viewModel.pauseWhenWindowCoverage
                ) {
                    MacToggle(isOn: Binding(
                        get: { viewModel.pauseWhenWindowCoverage },
                        set: { newValue in
                            viewModel.pauseWhenWindowCoverage = newValue
                            viewModel.syncAutoPauseSettings()
                        }
                    ))
                }

                if viewModel.pauseWhenWindowCoverage {
                    MacSettingsRow(
                        title: t("windowCoverageThreshold"),
                        showDivider: false
                    ) {
                        HStack(spacing: 8) {
                            Text("\(Int(viewModel.windowCoveragePauseThreshold))%")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 36, alignment: .trailing)
                            Slider(
                                value: snappedSliderBinding(
                                    $viewModel.windowCoveragePauseThreshold,
                                    in: 30...100,
                                    step: 5
                                ),
                                in: 30...100,
                                onEditingChanged: { editing in
                                    if !editing { viewModel.syncAutoPauseSettings() }
                                }
                            )
                            .tint(settingsSliderTint)
                            .accessibilityLabel(t("windowCoverageThreshold"))
                            .frame(width: 120)
                        }
                    }

                    if needsWindowCoverageAccessibilityHint {
                        MacSettingsRow(
                            title: t("windowCoverageAccessibilityRequired"),
                            subtitle: t("windowCoverageAccessibilityDesc"),
                            showDivider: true
                        ) {
                            Button {
                                openAccessibilitySettings()
                            } label: {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color(hex: "0A84FF"))
                                    .frame(width: 28, height: 24)
                            }
                            .buttonStyle(.plain)
                            .help(t("openAccessibilitySettings"))
                        }
                    }
                }

                MacSettingsRow(
                    title: t("hdrEnabled"),
                    subtitle: t("hdrEnabledDesc"),
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.hdrEnabled)
                }

            }

            MacSettingsSection(header: t("dynamicLockScreen")) {
                // 动态锁屏壁纸开关（仅 macOS 26+ 可用）
                if #available(macOS 26.0, *) {
                    MacSettingsRow(
                        title: t("dynamicLockScreen"),
                        subtitle: t("dynamicLockScreenDesc"),
                        showDivider: true
                    ) {
                        MacToggle(isOn: $viewModel.dynamicLockScreenEnabled)
                    }
                    .guideAnchor(.lockscreenToggle)

                    MacSettingsRow(
                        title: t("lockScreenSelectionStatus"),
                        subtitle: lockScreenSelectionDescription,
                        showDivider: true
                    ) {
                        Circle()
                            .fill(lockScreenSelectionColor)
                            .frame(width: 8, height: 8)
                    }
                    .guideAnchor(.lockscreenStatusRow)
                    .onAppear {
                        viewModel.refreshLockScreenSelectionStatus()
                        // 滚动到动态锁屏区块首次可见时播放教程（WaifuX GuideKit）
                        GuideEngine.shared.noteSheetOpened(GuideTours.lockscreen)
                    }

                    MacSettingsRow(
                        title: t("clearLockScreenInstances"),
                        subtitle: t("clearLockScreenInstancesDesc"),
                        showDivider: false
                    ) {
                        Button(t("clear")) {
                            showClearLockScreenAlert = true
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: "FF453A"))
                    }
                }
            }

            // 屏保组（安装/跟随状态，跟随桌面壁纸，与动态锁屏同语义）
            ScreenSaverSettingsTab()

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
                    MacSettingsRow(
                        title: t("proxyHost"),
                        showDivider: true
                    ) {
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

                    MacSettingsRow(
                        title: t("proxyPort"),
                        showDivider: false
                    ) {
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
                    title: t("menuBarClickActions"),
                    subtitle: t("menuBarClickActionsDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.swapMenuBarClickActions)
                }

                MacSettingsRow(
                    title: t("preventSystemSleep"),
                    subtitle: t("preventSystemSleepDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.preventSystemSleep)
                }

                MacSettingsRow(
                    title: t("hideNotch"),
                    subtitle: t("hideNotchDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.hideNotch)
                }

                MacSettingsRow(
                    title: t("saveToDownloadsFolder"),
                    subtitle: nil,
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.saveToDownloads)
                }
            }
        }
        .glassAlert(t("clearLockScreenInstances"), isPresented: $showClearLockScreenAlert,
                    message: t("clearLockScreenInstancesConfirm"),
                    actions: [
                        GlassAlertAction(t("cancel"), role: .cancel),
                        GlassAlertAction(t("clear"), role: .destructive) {
                            viewModel.clearLockScreenInstances()
                        }
                    ])
    }

}

// MARK: - 下载设置标签
private struct DownloadSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showMigrationSheet = false
    @State private var isRepairing = false
    @State private var showRepairAlert = false
    @State private var showClearCacheAlert = false
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
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
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

            // 动态壁纸优化设置组。自动任务均由公共优化队列串行处理。
            // 手动「优化视频」始终可走循环分析 + 补帧；此处只控制下载后自动优化与目标帧率。
            MacSettingsSection(header: t("videoOptimizationSection")) {
                MacSettingsRow(
                    title: t("videoOptimizationAutoAfterDownload"),
                    subtitle: t("videoOptimizationAutoAfterDownloadDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.autoOptimizeVideosAfterDownload)
                }

                MacSettingsRow(
                    title: t("frameInterpolationTargetFPS"),
                    subtitle: nil,
                    showDivider: false
                ) {
                    Picker("", selection: $viewModel.frameInterpolationTargetFPS) {
                        ForEach(FrameInterpolationTargetFPSResolver.allowedFixedFPSValues, id: \.self) { fps in
                            Text("\(fps)")
                                .tag(Double(fps))
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }

            // 缓存管理
            MacSettingsSection(header: t("dataManagement")) {
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
        .id(pathRefreshID)
        .sheet(isPresented: $showMigrationSheet) {
            DirectoryMigrationSheet(isPresented: $showMigrationSheet)
        }
        .glassAlert(t("repairData"), isPresented: $showRepairAlert,
                    message: t("repairDataConfirm"),
                    actions: [
                        GlassAlertAction(t("cancel"), role: .cancel),
                        GlassAlertAction(t("repair"), role: .destructive) {
                            startRepair()
                        }
                    ])
        .glassAlert(t("clearCache"), isPresented: $showClearCacheAlert,
                    message: t("clearCacheConfirm"),
                    actions: [
                        GlassAlertAction(t("cancel"), role: .cancel),
                        GlassAlertAction(t("clear"), role: .destructive) {
                            Task { await viewModel.clearCache() }
                        }
                    ])
        .glassAlert(repairResultMessage, isPresented: Binding(
            get: { !repairResultMessage.isEmpty && !isRepairing },
            set: { if !$0 { repairResultMessage = "" } }
        ), actions: [
            GlassAlertAction("OK", role: .cancel) { repairResultMessage = "" }
        ])
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
            var messages: [String] = []
            if result.indexedCount == 0
                && result.repairedCount == 0
                && result.removedCount == 0
                && result.migratedCount == 0
                && result.orphanedMembershipCount == 0 {
                messages.append(t("repairNoIssues"))
            } else {
                messages.append(String(
                    format: t("repairResult"),
                    result.indexedCount,
                    result.repairedCount,
                    result.migratedCount,
                    result.removedCount,
                    result.healthyCount
                ))
            }
            if result.orphanedMembershipCount > 0 {
                messages.append(String(format: t("repairOrphanMemberships"), result.orphanedMembershipCount))
            }
            if result.orphanedMembershipAborted {
                messages.append(t("repairOrphanAborted"))
            }
            repairResultMessage = messages.joined(separator: "\n")
            NotificationCenter.default.post(name: .downloadPathChanged, object: nil)
        }
    }
}

// MARK: - 调度器设置标签
private struct SchedulerSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    private var screens: [NSScreen] {
        // 勿直接用 NSScreen.screens：系统枚举顺序会在睡眠/唤醒后打乱，
        // 导致「显示器 2/3」标签对调，看起来像自动切换配置串台。
        NSScreen.screensOrderedForDisplay
    }

    private var isGlobalDisplaySyncEnabled: Bool {
        viewModel.schedulerViewModel.isGlobalDisplaySyncEnabled
    }

    var body: some View {
        MacSettingsForm {
            MacSettingsSection(header: t("globalSchedulerConfig")) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t("syncAllDisplaysWallpaper"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.9))
                            Text(t("syncAllDisplaysWallpaperDesc"))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.48))
                        }

                        Spacer()

                        MacToggle(isOn: Binding(
                            get: { isGlobalDisplaySyncEnabled },
                            set: { viewModel.schedulerViewModel.updateGlobalDisplaySyncEnabled($0) }
                        ))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if isGlobalDisplaySyncEnabled {
                        let globalConfig = viewModel.schedulerViewModel.globalDisplayConfig

                        dividerLine

                        HStack(spacing: 12) {
                            Text(t("autoSwitchEnabled"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.9))

                            Spacer()

                            MacToggle(isOn: Binding(
                                get: { globalConfig.isEnabled },
                                set: { viewModel.schedulerViewModel.updateGlobalDisplayEnabled($0) }
                            ))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        if globalConfig.isEnabled {
                            globalSchedulerControls(config: globalConfig)
                        }
                    }
                }
            }

            if !isGlobalDisplaySyncEnabled {
                // 每屏配置（独立模式）
                MacSettingsSection(header: t("scheduleConfig")) {
                    ForEach(Array(screens.enumerated()), id: \.element.wallpaperScreenIdentifier) { (index: Int, screen: NSScreen) in
                        // 勿在 body 内调用会写 UserDefaults / 改 @Published 的 migrate；
                        // 读路径 resolvedDisplayConfig 会按 fingerprint 找回旧配置，
                        // 写路径 update* 使用当前 wallpaperScreenIdentifier。
                        let screenID = screen.wallpaperScreenIdentifier
                        let displayConfig = viewModel.schedulerViewModel.displayConfig(for: screen)

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

                                perDisplaySchedulerControls(
                                    config: displayConfig,
                                    screenID: screenID
                                )
                            }
                        }

                        if index < screens.count - 1 {
                            dividerLine
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func globalSchedulerControls(config: DisplaySchedulerConfig) -> some View {
        dividerLine

        HStack(spacing: 12) {
            Text(t("replaceInterval"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))

            Spacer()

            Menu {
                ForEach(SchedulerConfig.intervalOptions, id: \.self) { minutes in
                    Button(intervalLabel(for: minutes)) {
                        viewModel.schedulerViewModel.updateGlobalDisplayInterval(minutes)
                    }
                }
                Divider()
                Button(intervalLabel(for: SchedulerConfig.intervalOnEndMinutes)) {
                    viewModel.schedulerViewModel.updateGlobalDisplayInterval(SchedulerConfig.intervalOnEndMinutes)
                }
                Button(intervalLabel(for: SchedulerConfig.intervalOnUnlockMinutes)) {
                    viewModel.schedulerViewModel.updateGlobalDisplayInterval(SchedulerConfig.intervalOnUnlockMinutes)
                }
            } label: {
                Text(intervalLabel(for: config.intervalMinutes))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if config.isOnEndMode {
            dividerLine

            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Text(t("webSceneSwitchInterval"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Spacer()

                    let seconds = config.webSceneSwitchSeconds ?? 0
                    if seconds == 0 {
                        Text(t("intervalOnEnd"))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.6))
                    } else {
                        Text(seconds >= 60 ? "\(seconds / 60) \(t("minutes"))" : "\(seconds) \(t("seconds"))")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }

                Slider(
                    value: snappedSliderBinding(
                        Binding(
                            get: { Double(config.webSceneSwitchSeconds ?? 0) },
                            set: { newValue in
                                let intVal = Int(newValue)
                                viewModel.schedulerViewModel.updateGlobalDisplayWebSceneSwitchSeconds(intVal == 0 ? nil : intVal)
                            }
                        ),
                        in: 0...3600,
                        step: 10
                    ),
                    in: 0...3600
                )
                .tint(settingsSliderTint)
                .accessibilityLabel(t("webSceneSwitchInterval"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }

        dividerLine

        HStack(spacing: 12) {
            Text(t("replaceOrder"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))

            Spacer()

            Picker("", selection: Binding(
                get: { config.order },
                set: { viewModel.schedulerViewModel.updateGlobalDisplayOrder($0) }
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

        HStack(spacing: 12) {
            Text(t("contentTypes"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))

            Spacer()

            HStack(spacing: 16) {
                Toggle(isOn: Binding(
                    get: { config.includeWallpapers },
                    set: { viewModel.schedulerViewModel.updateGlobalDisplayIncludeWallpapers($0) }
                )) {
                    Text(t("wallpapers"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { config.includeMedia },
                    set: { viewModel.schedulerViewModel.updateGlobalDisplayIncludeMedia($0) }
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

        dividerLine

        GlobalFolderPickerRow(
            folderIDs: config.folderIDs,
            includeWallpapers: config.includeWallpapers,
            includeMedia: config.includeMedia,
            viewModel: viewModel
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func perDisplaySchedulerControls(config: DisplaySchedulerConfig, screenID: String) -> some View {
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
                Divider()
                Button(intervalLabel(for: SchedulerConfig.intervalOnEndMinutes)) {
                    viewModel.schedulerViewModel.updateDisplayInterval(SchedulerConfig.intervalOnEndMinutes, for: screenID)
                }
                Button(intervalLabel(for: SchedulerConfig.intervalOnUnlockMinutes)) {
                    viewModel.schedulerViewModel.updateDisplayInterval(SchedulerConfig.intervalOnUnlockMinutes, for: screenID)
                }
            } label: {
                Text(intervalLabel(for: config.intervalMinutes))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        // "播完即换"模式下的 Web/Scene 壁纸切换间隔滑块
        if config.isOnEndMode {
            dividerLine

            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Text(t("webSceneSwitchInterval"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Spacer()

                    let seconds = config.webSceneSwitchSeconds ?? 0
                    if seconds == 0 {
                        Text(t("intervalOnEnd"))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.6))
                    } else {
                        Text(seconds >= 60 ? "\(seconds / 60) \(t("minutes"))" : "\(seconds) \(t("seconds"))")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }

                Slider(
                    value: snappedSliderBinding(
                        Binding(
                            get: { Double(config.webSceneSwitchSeconds ?? 0) },
                            set: { newValue in
                                let intVal = Int(newValue)
                                viewModel.schedulerViewModel.updateDisplayWebSceneSwitchSeconds(intVal == 0 ? nil : intVal, for: screenID)
                            }
                        ),
                        in: 0...3600,
                        step: 10
                    ),
                    in: 0...3600
                )
                .tint(settingsSliderTint)
                .accessibilityLabel(t("webSceneSwitchInterval"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }

        dividerLine

        // 顺序选择
        HStack(spacing: 12) {
            Text(t("replaceOrder"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))

            Spacer()

            Picker("", selection: Binding(
                get: { config.order },
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
                    get: { config.includeWallpapers },
                    set: { newValue in
                        viewModel.schedulerViewModel.updateDisplayIncludeWallpapers(newValue, for: screenID)
                    }
                )) {
                    Text(t("wallpapers"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { config.includeMedia },
                    set: { newValue in
                        viewModel.schedulerViewModel.updateDisplayIncludeMedia(newValue, for: screenID)
                    }
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

        dividerLine

        // 文件夹选择
        FolderPickerRow(
            folderIDs: config.folderIDs,
            includeWallpapers: config.includeWallpapers,
            includeMedia: config.includeMedia,
            screenID: screenID,
            viewModel: viewModel
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 文件夹选择组件（支持多选）
    private struct FolderPickerRow: View {
        let folderIDs: [String]?
        let includeWallpapers: Bool
        let includeMedia: Bool
        let screenID: String
        @ObservedObject var viewModel: SettingsViewModel
        @ObservedObject private var folderStore = LibraryFolderStore.shared

        var body: some View {
            HStack(spacing: 12) {
                Text("文件夹")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))

                Spacer()

                Menu {
                    Button(action: {
                        viewModel.schedulerViewModel.updateDisplayFolderIDs(nil, for: screenID)
                    }) {
                        HStack {
                            Text("全部")
                            if folderIDs == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    if !allFolders.isEmpty {
                        Divider()
                        ForEach(allFolders) { folder in
                            Button(action: {
                                toggleFolder(folder.id)
                            }) {
                                HStack {
                                    Text(folderOptionLabel(for: folder))
                                    if isSelected(folder.id) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text(folderIDsLabel)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
                .help(folderIDsLabel)
            }
        }

        private var allFolders: [LibraryFolder] {
            var combined: [LibraryFolder] = []
            if includeWallpapers { combined.append(contentsOf: folderStore.folders(for: .wallpaper)) }
            if includeMedia { combined.append(contentsOf: folderStore.folders(for: .media)) }
            return combined.sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                if lhs.contentType != rhs.contentType {
                    return lhs.contentType.rawValue < rhs.contentType.rawValue
                }
                return lhs.id < rhs.id
            }
        }

        private var selectedFolderIDSet: Set<String> {
            Set(folderIDs ?? [])
        }

        private func isSelected(_ folderID: String) -> Bool {
            guard folderIDs != nil else { return false }
            return selectedFolderIDSet.contains(folderID)
        }

        /// 多选切换：
        /// - 当前为「全部」(nil) 时点某个文件夹 → 仅选中该文件夹
        /// - 已有选中时点已选项 → 取消；取消后空集合回退为「全部」
        /// - 点未选项 → 加入集合
        private func toggleFolder(_ folderID: String) {
            var next: Set<String>
            if let folderIDs {
                next = Set(folderIDs)
            } else {
                // 从「全部」进入多选：只选中当前点的这一项
                viewModel.schedulerViewModel.updateDisplayFolderIDs([folderID], for: screenID)
                return
            }

            if next.contains(folderID) {
                next.remove(folderID)
            } else {
                next.insert(folderID)
            }

            if next.isEmpty {
                viewModel.schedulerViewModel.updateDisplayFolderIDs(nil, for: screenID)
            } else {
                // 保持稳定顺序：按文件夹名称排序
                let ordered = allFolders
                    .map(\.id)
                    .filter { next.contains($0) }
                // 若有已删除文件夹 id 仍在集合里，追加在末尾以免静默丢配置
                let leftovers = next.subtracting(ordered)
                viewModel.schedulerViewModel.updateDisplayFolderIDs(
                    ordered + leftovers.sorted(),
                    for: screenID
                )
            }
        }

        private var folderIDsLabel: String {
            guard let folderIDs else { return "全部" }
            if folderIDs.isEmpty { return "全部" }
            let names = folderIDs.compactMap { id in
                allFolders.first(where: { $0.id == id }).map(folderOptionLabel)
            }
            if names.isEmpty { return "全部" }
            if names.count == 1 { return names[0] }
            if names.count <= 3 {
                return names.joined(separator: ", ")
            }
            return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
        }

        private func folderOptionLabel(for folder: LibraryFolder) -> String {
            let contentType = folder.contentType == .wallpaper ? t("wallpapers") : t("media")
            return "\(contentType) · \(folder.name)"
        }
    }

    // MARK: - Global folder picker (multi-select against the shared global policy)
    private struct GlobalFolderPickerRow: View {
        let folderIDs: [String]?
        let includeWallpapers: Bool
        let includeMedia: Bool
        @ObservedObject var viewModel: SettingsViewModel
        @ObservedObject private var folderStore = LibraryFolderStore.shared

        var body: some View {
            HStack(spacing: 12) {
                Text(t("folders"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))

                Spacer()

                Menu {
                    Button(action: {
                        viewModel.schedulerViewModel.updateGlobalDisplayFolderIDs(nil)
                    }) {
                        HStack {
                            Text(t("all"))
                            if folderIDs == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    if !allFolders.isEmpty {
                        Divider()
                        ForEach(allFolders) { folder in
                            Button(action: {
                                toggleFolder(folder.id)
                            }) {
                                HStack {
                                    Text(folderOptionLabel(for: folder))
                                    if isSelected(folder.id) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text(folderIDsLabel)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
                .help(folderIDsLabel)
            }
        }

        private var allFolders: [LibraryFolder] {
            var combined: [LibraryFolder] = []
            if includeWallpapers { combined.append(contentsOf: folderStore.folders(for: .wallpaper)) }
            if includeMedia { combined.append(contentsOf: folderStore.folders(for: .media)) }
            return combined.sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                if lhs.contentType != rhs.contentType {
                    return lhs.contentType.rawValue < rhs.contentType.rawValue
                }
                return lhs.id < rhs.id
            }
        }

        private var selectedFolderIDSet: Set<String> {
            Set(folderIDs ?? [])
        }

        private func isSelected(_ folderID: String) -> Bool {
            guard folderIDs != nil else { return false }
            return selectedFolderIDSet.contains(folderID)
        }

        private func toggleFolder(_ folderID: String) {
            var next: Set<String>
            if let folderIDs {
                next = Set(folderIDs)
            } else {
                viewModel.schedulerViewModel.updateGlobalDisplayFolderIDs([folderID])
                return
            }

            if next.contains(folderID) {
                next.remove(folderID)
            } else {
                next.insert(folderID)
            }

            if next.isEmpty {
                viewModel.schedulerViewModel.updateGlobalDisplayFolderIDs(nil)
            } else {
                let ordered = allFolders
                    .map(\.id)
                    .filter { next.contains($0) }
                let leftovers = next.subtracting(ordered)
                viewModel.schedulerViewModel.updateGlobalDisplayFolderIDs(
                    ordered + leftovers.sorted()
                )
            }
        }

        private var folderIDsLabel: String {
            guard let folderIDs else { return t("all") }
            if folderIDs.isEmpty { return t("all") }
            let names = folderIDs.compactMap { id in
                allFolders.first(where: { $0.id == id }).map(folderOptionLabel)
            }
            if names.isEmpty { return t("all") }
            if names.count == 1 { return names[0] }
            if names.count <= 3 {
                return names.joined(separator: ", ")
            }
            return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
        }

        private func folderOptionLabel(for folder: LibraryFolder) -> String {
            let contentType = folder.contentType == .wallpaper ? t("wallpapers") : t("media")
            return "\(contentType) · \(folder.name)"
        }
    }

    private var dividerLine: some View {
        Divider()
            .background(Color.white.opacity(0.06))
            .padding(.leading, 16)
    }

    private func intervalLabel(for minutes: Int) -> String {
        if minutes == SchedulerConfig.intervalOnEndMinutes {
            return t("intervalOnEnd")
        }
        if minutes == SchedulerConfig.intervalOnUnlockMinutes {
            return t("intervalOnUnlock")
        }
        switch minutes {
        case 1: return "1 \(t("minutes"))"
        case 3: return "3 \(t("minutes"))"
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
    @State private var showResetAlert = false
    @State private var showExportLogConfirm = false
    @State private var showExportResultAlert = false
    @State private var exportedLogURL: URL?
    @State private var exportResultTitle = ""
    @State private var exportResultMessage = ""

    var body: some View {
        ZStack {
            MacSettingsForm {
                // 自动更新区域
                autoUpdateSection

                // 项目信息组
                MacSettingsSection(header: t("projectInfo")) {
                    infoRow(title: t("developer"), value: "jipika", isLast: false)
                    infoRow(title: t("animeRuleSource"), value: "KazumiRules", isLast: false)
                    infoRow(title: t("techStack"), value: "SwiftUI + AppKit", isLast: true)
                }

                // 链接组
                MacSettingsSection(header: t("links")) {
                    MacLinkRow(title: t("visitWebsite"), action: {
                        if let url = URL(string: "https://jipika.github.io/WaifuX") {
                            NSWorkspace.shared.open(url)
                        }
                    })

                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                    MacLinkRow(title: t("reportProblem"), action: {
                        if let url = URL(string: "https://github.com/jipika/WaifuX/issues") {
                            NSWorkspace.shared.open(url)
                        }
                    })

                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                    MacLinkRow(title: t("joinQQGroup"), action: {
                        if let url = URL(string: "https://qm.qq.com/q/SRCj8msygq") {
                            NSWorkspace.shared.open(url)
                        }
                    })

                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)

                    MacRewardRow(title: t("reward"), imageName: "RewardQRCode")
                }

                // 日志诊断组
                MacSettingsSection(header: t("settings.diagnostics")) {
                    MacLinkRow(title: t("settings.exportLog"), action: {
                        showExportLogConfirm = true
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
            .glassAlert(t("resetAllData"), isPresented: $showResetAlert,
                        message: t("resetAllDataConfirm"),
                        actions: [
                            GlassAlertAction(t("cancel"), role: .cancel),
                            GlassAlertAction(t("reset"), role: .destructive) {
                                Task { await viewModel.resetAllData() }
                            }
                        ])
            .glassAlert(t("settings.exportLog"), isPresented: $showExportLogConfirm,
                        message: t("settings.exportLog.confirm"),
                        actions: [
                            GlassAlertAction(t("cancel"), role: .cancel),
                            GlassAlertAction(t("confirm")) {
                                exportLog()
                            }
                        ])
            .glassAlert(exportResultTitle, isPresented: $showExportResultAlert,
                        message: exportResultMessage,
                        actions: exportResultActions)
        }
    }

    /// 导出结果弹窗按钮：成功时附加「在 Finder 中显示」
    private var exportResultActions: [GlassAlertAction] {
        var actions: [GlassAlertAction] = []
        if let url = exportedLogURL {
            actions.append(GlassAlertAction(t("settings.exportLog.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        }
        actions.append(GlassAlertAction(t("ok"), role: .cancel))
        return actions
    }

    /// 确认导出后执行：复制运行日志到桌面，成功/失败都弹结果框。
    private func exportLog() {
        do {
            if let url = try AppLogger.exportLogToDesktop() {
                exportedLogURL = url
                exportResultTitle = t("settings.exportLog.successTitle")
                exportResultMessage = String(format: t("settings.exportLog.success"), url.lastPathComponent)
            } else {
                exportedLogURL = nil
                exportResultTitle = t("settings.exportLog.failedTitle")
                exportResultMessage = t("settings.exportLog.noLog")
            }
        } catch {
            exportedLogURL = nil
            exportResultTitle = t("settings.exportLog.failedTitle")
            exportResultMessage = error.localizedDescription
            AppLogger.error(.general, "日志导出失败", metadata: ["error": error.localizedDescription])
        }
        showExportResultAlert = true
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

    // MARK: - 自动更新区域（Sparkle 驱动）

    @ViewBuilder
    private var autoUpdateSection: some View {
        MacSettingsSection {
            VStack(alignment: .leading, spacing: 16) {
                // 应用信息头部 + 检查更新按钮
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

                        Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · \(WallpaperEngineAvailability.currentArchitecture)版")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }

                    Spacer()

                    // 检查更新按钮（委托 Sparkle 处理）
                    Button {
                        AppDelegate.shared?.checkForUpdates()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                            Text("检查更新")
                                .font(.system(size: 13))
                        }
                        .frame(height: 28)
                    }
                    .buttonStyle(.bordered)
                }

                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("渲染组件").font(.system(size: 13, weight: .medium))
                        Text("Scene、Web 与视频引擎可独立更新")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("检查组件更新") {
                        RendererComponentUpdater.shared.check(userInitiated: true)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
        }
    }
}


// MARK: - Workshop 设置标签
private enum SteamLoginMethod {
    case qr
    case password
}

private struct WorkshopSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var sourceManager = WorkshopSourceManager.shared
    @ObservedObject private var workshopService = WorkshopService.shared
    @ObservedObject private var steamService = SteamServiceManager.shared
    @ObservedObject private var clockSettings = LiquidGlassClockSettings.shared
    @State private var steamUsername = ""
    @State private var steamPassword = ""
    @State private var steamGuardCode = ""
    @State private var isSteamPasswordVisible = false
    @State private var showLoginForm = false
    @State private var steamLoginMethod: SteamLoginMethod = .qr
    @State private var isVerifyingSteamLogin = false
    @State private var steamLoginStatusText: String?
    @State private var cleanupResult: (count: Int, bytesFreed: Int64)?
    @State private var isCleaningUp = false

    /// 所有已连接显示器的最高刷新率，作为 FPS 滑块的上限
    private var maxSliderFPS: Double {
        Double(NSScreen.screens.map(\.maxRefreshRate).max() ?? 60)
    }

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

                steamServiceStatusSection

                steamLoginSection

                // 场景壁纸实时渲染模式
                MacSettingsSection {
                    MacSettingsRow(title: t("workshop.sceneRealtimeRendering"), subtitle: t("workshop.sceneRealtimeRenderingDesc"), showDivider: false) {
                        MacToggle(isOn: Binding(
                            get: { viewModel.sceneRealtimeRenderingEnabled },
                            set: { newValue in
                                viewModel.sceneRealtimeRenderingEnabled = newValue
                                // 与桌面动态元素互斥
                                if newValue && clockSettings.config.enabled {
                                    clockSettings.update { $0.enabled = false }
                                }
                            }
                        ))
                    }
                }

                // 超分辨率模式
                MacSettingsSection {
                    MacSettingsRow(title: t("workshop.upscalingMode"), subtitle: t("workshop.upscalingModeDesc"), showDivider: true) {
                        MacToggle(isOn: Binding(
                            get: { viewModel.upscalingEnabled },
                            set: { viewModel.upscalingEnabled = $0 }
                        ))
                    }

                    if viewModel.upscalingEnabled {
                        MacSettingsRow(title: t("workshop.upscalingRatio"), showDivider: true) {
                            HStack(spacing: 8) {
                                Text("\(Int(viewModel.upscalingPercent))%")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 36, alignment: .trailing)
                                Slider(
                                    value: snappedSliderBinding($viewModel.upscalingPercent, in: 30...100, step: 5),
                                    in: 30...100
                                )
                                .tint(settingsSliderTint)
                                .accessibilityLabel(t("workshop.upscalingRatio"))
                                .frame(width: 120)
                            }
                        }

                        MacSettingsRow(title: t("workshop.effectReduction"), subtitle: t("workshop.effectReductionDesc"), showDivider: false) {
                            MacToggle(isOn: Binding(
                                get: { viewModel.effectReductionEnabled },
                                set: { viewModel.effectReductionEnabled = $0 }
                            ))
                        }
                    }
                }

                // 渲染帧率上限
                VStack(alignment: .leading, spacing: 6) {
                    MacSettingsSection {
                        MacSettingsRow(title: t("workshop.fps"), subtitle: t("workshop.fpsDesc")) {
                            HStack(spacing: 8) {
                                Text("\(Int(viewModel.wallpaperEngineFPS)) FPS")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 52, alignment: .trailing)
                                Slider(
                                    value: snappedSliderBinding(
                                        $viewModel.wallpaperEngineFPS,
                                        in: 60...max(60, maxSliderFPS),
                                        step: 5
                                    ),
                                    in: 60...max(60, maxSliderFPS)
                                )
                                .tint(settingsSliderTint)
                                .accessibilityLabel(t("workshop.fps"))
                                .frame(width: 120)
                            }
                        }
                        MacSettingsRow(title: t("workshop.webRenderScale"), subtitle: t("workshop.webRenderScaleDesc"), showDivider: false) {
                            HStack(spacing: 8) {
                                Text("\(Int(viewModel.webWallpaperRenderScalePercent))%")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 52, alignment: .trailing)
                                Slider(
                                    value: snappedSliderBinding(
                                        $viewModel.webWallpaperRenderScalePercent,
                                        in: 50...100,
                                        step: 5
                                    ),
                                    in: 50...100
                                )
                                .tint(settingsSliderTint)
                                .accessibilityLabel(t("workshop.webRenderScale"))
                                .frame(width: 120)
                            }
                        }
                    }
                    Text(t("workshop.fpsHint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.75))
                        .padding(.leading, 2)
                }

                // 桌面动态元素（时钟、音频柱状图等）
                MacSettingsSection {
                    MacSettingsRow(title: t("workshop.desktopDynamicElements"), subtitle: t("workshop.desktopDynamicElementsDesc"), showDivider: false) {
                        MacToggle(isOn: Binding(
                            get: { clockSettings.config.enabled },
                            set: { newValue in
                                clockSettings.update { $0.enabled = newValue }
                                // 与场景壁纸实时渲染互斥
                                if newValue && viewModel.sceneRealtimeRenderingEnabled {
                                    viewModel.sceneRealtimeRenderingEnabled = false
                                }
                            }
                        ))
                    }
                }

                // 烘焙帧率
                MacSettingsSection {
                    MacSettingsRow(title: t("workshop.bakeFps"), subtitle: t("workshop.bakeFpsDesc"), showDivider: true) {
                        HStack(spacing: 8) {
                            Text("\(Int(viewModel.sceneBakeFPS)) FPS")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 52, alignment: .trailing)
                            Slider(
                                value: snappedSliderBinding(
                                    $viewModel.sceneBakeFPS,
                                    in: 15...maxSliderFPS,
                                    step: 5
                                ),
                                in: 15...maxSliderFPS
                            )
                            .tint(settingsSliderTint)
                            .accessibilityLabel(t("workshop.bakeFps"))
                            .frame(width: 120)
                        }
                    }

                    MacSettingsRow(title: t("workshop.bakeDuration"), subtitle: t("workshop.bakeDurationDesc"), showDivider: true) {
                        HStack(spacing: 8) {
                            Text("\(Int(viewModel.sceneBakeDuration))s")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 36, alignment: .trailing)
                            Slider(
                                value: snappedSliderBinding($viewModel.sceneBakeDuration, in: 5...60, step: 5),
                                in: 5...60
                            )
                            .tint(settingsSliderTint)
                            .accessibilityLabel(t("workshop.bakeDuration"))
                            .frame(width: 120)
                        }
                    }

                    MacSettingsRow(title: t("workshop.autoBakeScene"), subtitle: t("workshop.autoBakeSceneDesc"), showDivider: false) {
                        MacToggle(isOn: $viewModel.autoBakeScene)
                    }
                }

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

                // 清理下载缓存
                cleanupSection

                Spacer()
            }
            .padding(24)
        }
        .onAppear {
            steamService.start()
            sourceManager.refreshStoredSteamIdentity()
            syncCredentialPresentation()
        }
        .onChange(of: sourceManager.steamCredentialState) { _, _ in
            syncCredentialPresentation()
        }
        .onChange(of: steamService.loginState) { _, newState in
            handleSteamLoginStateChange(newState)
        }
    }

    private var steamLoginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.cyan)
                Text(t("steamServiceAccount"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if case .available = sourceManager.steamCredentialState {
                    Label("已保存用户名", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if case .available(let username) = sourceManager.steamCredentialState, !showLoginForm, !isSteamQRFlowActive {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: t("accountSaved"), username))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("下载会复用 WaifuX 的 Steam 会话。密码和 Guard 验证码不会保存。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.85))
                        if let steamLoginStatusText {
                            Text(steamLoginStatusText)
                                .font(.system(size: 10))
                                .foregroundStyle(loginStatusColor)
                        }
                    }
                    Spacer()
                    Button(t("relogin")) {
                        steamUsername = username
                        steamPassword = ""
                        steamGuardCode = ""
                        steamLoginStatusText = nil
                        steamLoginMethod = .password
                        showLoginForm = true
                    }
                    .controlSize(.small)
                    Button(t("logout")) {
                        SteamServiceManager.shared.logout()
                        sourceManager.clearSteamIdentity()
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
            } else if steamLoginMethod == .qr, !isVerifyingSteamLogin {
                steamQRLoginView
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

                    HStack(alignment: .top) {
                        if isVerifyingSteamLogin {
                            ProgressView()
                                .scaleEffect(0.8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(isWaitingForSteamGuardCode ? "Steam 正在等待验证码…" : "正在验证账号并连接 Steam…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(isWaitingForSteamGuardCode
                                     ? "输入收到的 Steam Guard 验证码后提交。"
                                     : t("steamLoginMobileConfirmHint"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        } else if let steamLoginStatusText {
                            Text(steamLoginStatusText)
                                .font(.system(size: 11))
                                .foregroundStyle(loginStatusColor)
                        }

                        Spacer()

                        if isVerifyingSteamLogin {
                            Button("取消") {
                                SteamServiceManager.shared.cancelLogin()
                            }
                            .controlSize(.small)
                        } else if case .available = sourceManager.steamCredentialState {
                            Button("取消") {
                                showLoginForm = false
                                steamPassword = ""
                                steamGuardCode = ""
                                steamLoginStatusText = nil
                            }
                            .controlSize(.small)
                        }

                        Button(isWaitingForSteamGuardCode ? "提交验证码" : "验证并保存") {
                            if isWaitingForSteamGuardCode {
                                SteamServiceManager.shared.submitGuardCode(steamGuardCode)
                                steamGuardCode = ""
                                steamLoginStatusText = "验证码已提交，正在等待 Steam 验证。"
                                return
                            }

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
                                    PersistentDownloadQueueService.shared.resumeWaitingForSteamLogin()
                                    await MainActor.run {
                                        sourceManager.setSteamIdentity(username: steamUsername)
                                        if !steamService.steamID.isEmpty {
                                            sourceManager.steamProfileID = steamService.steamID
                                        }
                                        steamPassword = ""
                                        steamGuardCode = ""
                                        if case .available = sourceManager.steamCredentialState {
                                            steamLoginStatusText = "Steam 会话验证成功。会话令牌已保存到 macOS 钥匙串，密码和验证码未保存。"
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
                                            steamLoginStatusText = "连接 Steam 服务超时，请稍后重试。"
                                        case .loginTimeout:
                                            steamLoginStatusText = "Steam 登录超时，请检查网络或代理设置后重试。"
                                        case .sessionExpired:
                                            steamLoginStatusText = "Steam 会话需要重新登录。"
                                        case .invalidCredentials:
                                            steamLoginStatusText = "账号、密码或验证码不正确，请检查后重试。"
                                        case .steamLoginFailed(let msg):
                                            steamLoginStatusText = msg
                                        case .downloadFailed(let msg):
                                            steamLoginStatusText = msg
                                        case .executionFailed(let msg):
                                            steamLoginStatusText = "Steam 服务执行失败：\(msg)"
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
                        .disabled(
                            isWaitingForSteamGuardCode
                            ? steamGuardCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            : steamUsername.isEmpty || steamPassword.isEmpty || isVerifyingSteamLogin
                        )
                    }

                    if !isVerifyingSteamLogin {
                        HStack {
                            Spacer()
                            Button("改用二维码扫码登录") {
                                showLoginForm = false
                                steamLoginMethod = .qr
                                steamLoginStatusText = nil
                                SteamServiceManager.shared.cancelLogin()
                                SteamServiceManager.shared.loginWithQR()
                            }
                            .controlSize(.small)
                            .buttonStyle(.link)
                        }
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.03))
                .cornerRadius(8)
            }

            Text("扫码登录的二维码在本机生成，凭据不经过第三方。Steam 下载只保存会话令牌到 macOS 钥匙串，密码与 Guard 验证码仅用于当前登录，不会写入本地。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }



    private var steamServiceStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 14))
                    .foregroundStyle(.cyan)
                Text(t("steamServiceStatus"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("刷新") {
                    steamService.start()
                }
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                Circle()
                    .fill(steamServiceStatusColor)
                    .frame(width: 8, height: 8)

                Text(steamServiceStatusText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Spacer()

                Label(steamServiceStatusLabel, systemImage: steamServiceStatusIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(steamServiceStatusColor)
                    .lineLimit(2)
            }
            .padding(12)
            .background(Color.white.opacity(0.03))
            .cornerRadius(8)
        }
    }

    // MARK: - Steam 二维码扫码登录（对齐 MirageWallpaper 的登录流程）

    /// 二维码登录流程进行中（连接/等待扫码/等待确认）时，登录卡片需让位给二维码视图。
    private var isSteamQRFlowActive: Bool {
        guard steamLoginMethod == .qr else { return false }
        switch steamService.loginState {
        case .loggingIn, .waitingForQR, .waitingForMobileConfirmation, .waitingForCode:
            return true
        case .idle, .success, .failed:
            return false
        }
    }

    private var steamQRLoginView: some View {
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

            steamQRStateView

            if let steamLoginStatusText {
                Text(steamLoginStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(loginStatusColor)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var steamQRStateView: some View {
        switch steamService.loginState {
        case .waitingForQR(let challenge):
            steamQRCodeView(challenge)
        case .loggingIn:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("正在连接 Steam，请稍候…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消登录") {
                    SteamServiceManager.shared.cancelLogin()
                }
                .controlSize(.small)
            }
        case .waitingForMobileConfirmation:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("已扫码，请在 Steam 手机 App 上确认登录…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消登录") {
                    SteamServiceManager.shared.cancelLogin()
                }
                .controlSize(.small)
            }
        case .waitingForCode:
            VStack(alignment: .leading, spacing: 8) {
                Text("Steam 要求补充验证码，请改用账号密码登录后提交。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("改用账户密码登录") {
                    SteamServiceManager.shared.cancelLogin()
                    steamLoginMethod = .password
                    showLoginForm = true
                }
                .controlSize(.small)
            }
        case .success:
            Label("登录成功。", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    SteamServiceManager.shared.loginWithQR()
                } label: {
                    Label("使用 Steam 手机 App 扫码登录", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)

                Button("改用账户密码登录") {
                    steamLoginMethod = .password
                    showLoginForm = true
                    steamLoginStatusText = nil
                }
                .controlSize(.small)
                .buttonStyle(.link)
            }
        }
    }

    private func steamQRCodeView(_ challenge: String) -> some View {
        VStack(spacing: 10) {
            Group {
                if let image = Self.steamQRCodeImage(for: challenge) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 168, height: 168)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .id(challenge)
                } else {
                    Text("二维码生成失败，请点击下方刷新。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 168, height: 168)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity)

            Text("使用 Steam 手机 App 扫描二维码")
                .font(.system(size: 12, weight: .medium))
            Text("打开 Steam 手机 App 的扫码功能，扫描后按提示确认登录；二维码会自动更新。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    SteamServiceManager.shared.loginWithQR()
                } label: {
                    Label("刷新二维码", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)

                Button("取消登录") {
                    SteamServiceManager.shared.cancelLogin()
                }
                .controlSize(.small)

                Spacer()

                Button("改用账户密码登录") {
                    SteamServiceManager.shared.cancelLogin()
                    steamLoginMethod = .password
                    showLoginForm = true
                    steamLoginStatusText = nil
                }
                .controlSize(.small)
                .buttonStyle(.link)
            }
        }
    }

    private static func steamQRCodeImage(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    private func handleSteamLoginStateChange(_ state: SteamServiceLoginState) {
        switch state {
        case .success:
            let username = steamService.accountName
            guard !username.isEmpty else { return }
            sourceManager.setSteamIdentity(username: username)
            if !steamService.steamID.isEmpty {
                sourceManager.steamProfileID = steamService.steamID
            }
            PersistentDownloadQueueService.shared.resumeWaitingForSteamLogin()
            isVerifyingSteamLogin = false
            steamPassword = ""
            steamGuardCode = ""
            steamLoginStatusText = "登录成功。会话令牌已保存到 macOS 钥匙串，密码和验证码未保存。"
            showLoginForm = false
        case .failed(let message):
            // 密码登录路径的失败信息由 verifySteamLogin 的 catch 分支负责展示。
            guard !isVerifyingSteamLogin else { return }
            steamLoginStatusText = message
        default:
            break
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

    private var isWaitingForSteamGuardCode: Bool {
        if case .waitingForCode = steamService.loginState {
            return true
        }
        return false
    }

    private var steamServiceStatusColor: Color {
        if steamService.isAvailable {
            return .green
        }
        if case .failed = steamService.loginState {
            return .red
        }
        return .blue
    }

    private var steamServiceStatusText: String {
        if steamService.isAvailable {
            return steamService.isLoggedIn
                ? "Steam 会话已连接，将在后续下载中复用。"
                : "Steam 服务已就绪，登录后会自动恢复会话。"
        }
        if case .failed(let message) = steamService.loginState {
            return String(format: t("steamServiceError"), message)
        }
        return "正在启动 Steam 服务…"
    }

    private var steamServiceStatusLabel: String {
        if steamService.isAvailable {
            return steamService.isLoggedIn ? "已登录" : t("steamServiceReady")
        }
        if case .failed = steamService.loginState {
            return "不可用"
        }
        return t("downloading")
    }

    private var steamServiceStatusIcon: String {
        if steamService.isAvailable {
            return steamService.isLoggedIn ? "person.crop.circle.badge.checkmark" : "checkmark.circle"
        }
        if case .failed = steamService.loginState {
            return "exclamationmark.triangle"
        }
        return "arrow.down.circle"
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
            return "未发现 Steam 会话账号"
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
            return "当前没有可用于会话探测的 Steam 用户名。登录成功后只保存用户名，不保存密码。"
        case .failure(let message):
            return "读取本地已保存账号时发生错误：\(message)"
        case .available:
            return "本机已记录 Steam 账号。启动时会从 macOS 钥匙串恢复会话。"
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

    private func syncCredentialPresentation() {
        if case .available(let username) = sourceManager.steamCredentialState {
            steamUsername = username
            steamPassword = ""
            steamGuardCode = ""
            if !isVerifyingSteamLogin {
                showLoginForm = false
            }
        } else if !isVerifyingSteamLogin {
            // 与 Mirage 一致：未登录时默认展示二维码扫码入口。
            showLoginForm = false
            steamLoginMethod = .qr
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
        .background(DarkLiquidGlassBackground(cornerRadius: 16, isHovered: false))
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
