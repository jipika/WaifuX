import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 时间流只重绘弹幕子树，不把播放器的高频时钟提升到整个窗口。
struct AnimeDanmakuPlaybackOverlay: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @ObservedObject var player: NativeVideoPlayer
    @State private var mediaTime: Double = 0

    /// 「弹幕跟随视频倍速」关闭时按 1x 推进；开启时弹幕与画面同速（Kazumi danmakuFollowSpeed）。
    private var effectiveRate: Double {
        viewModel.danmakuSettings.followSpeed ? player.playbackRate : 1.0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: player.state != .playing)) { _ in
            // 仅用刷新节拍触发重绘，位置始终读取AVPlayer的真实媒体时间。
            let liveTime = player.avPlayer.currentTime().seconds
            DanmakuView(danmakuList: viewModel.danmakuList, settings: viewModel.danmakuSettings,
                        currentTime: liveTime.isFinite ? max(0, liveTime) : mediaTime,
                        isPlaying: player.state == .playing, playbackRate: effectiveRate)
        }
            .onReceive(player.currentTimePublisher) { mediaTime = $0 }
            .onChange(of: viewModel.playbackID) { _, _ in mediaTime = viewModel.currentStartTime }
            .onAppear { mediaTime = player.currentTime }
            .clipped()
    }
}

struct AnimePlaybackAccessories: View {
    let syncPlay: AnimeSyncPlayService
    let episodeNumber: Int?
    let hasVideo: Bool
    @ObservedObject var player: NativeVideoPlayer
    @State private var showSyncPlay = false
    @State private var screenshotBusy = false
    @State private var screenshotError: String?

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button(t("anime.player.syncPlay"), systemImage: "person.2") { showSyncPlay = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 28, height: 32)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(t("anime.player.playbackMenu"))
            .help(t("anime.player.playbackMenu"))

            if hasVideo {
                Button { Task { await saveScreenshot() } } label: {
                    Group {
                        if screenshotBusy { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "camera") }
                    }
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(screenshotBusy || !player.state.isReady)
                .accessibilityLabel(t("anime.player.screenshot"))
                .help(t("anime.player.screenshot"))
            }
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white)
        .sheet(isPresented: $showSyncPlay) {
            AnimePlayerFeatureSheet { AnimeSyncPlayView(service: syncPlay) }
        }
        .alert(t("anime.player.screenshotFailed"), isPresented: Binding(
            get: { screenshotError != nil }, set: { if !$0 { screenshotError = nil } }
        )) { Button(t("common.ok"), role: .cancel) {} } message: { Text(screenshotError ?? "") }
    }

    @MainActor private func saveScreenshot() async {
        screenshotBusy = true
        defer { screenshotBusy = false }
        do {
            let image = try await player.captureCurrentFrame()
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else {
                screenshotError = t("anime.player.screenshotFailed")
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "WaifuX-\(episodeNumber ?? 0)-\(Int(max(0, player.currentTime))).png"
            let result: NSApplication.ModalResponse
            if let window = NSApp.keyWindow {
                result = await withCheckedContinuation { continuation in
                    panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                }
            } else {
                result = await withCheckedContinuation { continuation in
                    panel.begin { continuation.resume(returning: $0) }
                }
            }
            guard result == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            screenshotError = error.localizedDescription
        }
    }
}

private struct AnimePlayerFeatureSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(t("done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.top, 12)
            content
        }
    }
}

struct AnimePlaybackSettingsView: View {
    @ObservedObject var viewModel: AnimeDetailViewModel

    var body: some View {
        Form {
            Section {
                Toggle(t("player.autoPlayNext"), isOn: boolBinding(\.autoPlayNext))
                Toggle(t("player.skipOpEd"), isOn: boolBinding(\.skipOpeningEnding))
                if viewModel.enhancementSettings.skipOpeningEnding {
                    Stepper(value: secondsBinding(\.openingSeconds), in: 0...300, step: 5) {
                        Text(String(format: t("anime.player.openingSeconds"), Int(viewModel.enhancementSettings.openingSeconds)))
                    }
                    Stepper(value: secondsBinding(\.endingSeconds), in: 0...300, step: 5) {
                        Text(String(format: t("anime.player.endingSeconds"), Int(viewModel.enhancementSettings.endingSeconds)))
                    }
                    Text(t("anime.player.skipExplanation"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text(t("player.settings")) }
            Section {
                Text(t("anime.player.enhancementUnavailable"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func boolBinding(_ path: WritableKeyPath<AnimeDetailViewModel.PlayerEnhancementSettings, Bool>) -> Binding<Bool> {
        Binding(get: { viewModel.enhancementSettings[keyPath: path] }, set: {
            var settings = viewModel.enhancementSettings
            settings[keyPath: path] = $0
            viewModel.updateEnhancementSettings(settings)
        })
    }

    private func secondsBinding(_ path: WritableKeyPath<AnimeDetailViewModel.PlayerEnhancementSettings, Double>) -> Binding<Double> {
        Binding(get: { viewModel.enhancementSettings[keyPath: path] }, set: {
            var settings = viewModel.enhancementSettings
            settings[keyPath: path] = $0
            viewModel.updateEnhancementSettings(settings)
        })
    }
}

/// 弹幕面板（Kazumi 分区结构：来源 / 屏蔽 / 显示 / 样式），液态玻璃分组卡片。
/// 所有行控件写入同一份 DanmakuSettings，播放中的弹幕层即时生效。
struct AnimeDanmakuSettingsPanel: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @State private var blockedText = ""

    var body: some View {
        ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                statusHeader

                if viewModel.danmakuError != nil || !DanmakuCredentials.isConfigured {
                    issueBanner
                }

                sourceSection
                shieldSection
                displaySection
                styleSection

                Button {
                    viewModel.updateDanmakuSettings(viewModel.danmakuSettings.resettingAppearance())
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("anime.player.danmakuResetDefaults"))
                                .font(.system(size: 13, weight: .medium))
                            Text(t("anime.player.danmakuResetHint"))
                                .font(.system(size: 11))
                                .foregroundStyle(LiquidGlassColors.textTertiary)
                        }
                        Spacer()
                    }
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .liquidGlassSurface(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { blockedText = viewModel.danmakuSettings.blockedKeywords.joined(separator: ", ") }
    }

    // MARK: 状态头

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.primaryPink)
            VStack(alignment: .leading, spacing: 2) {
                Text(t("danmaku.title"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
            }
            Spacer()
            if viewModel.isLoadingDanmaku {
                ProgressView().controlSize(.small)
            }
            LiquidGlassSwitch(isOn: boolBinding(\.isEnabled))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .liquidGlassSurface(.prominent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusSubtitle: String {
        if viewModel.isLoadingDanmaku { return t("anime.player.danmakuLoading") }
        if !viewModel.danmakuList.isEmpty {
            return String(format: t("anime.player.danmakuCount"), viewModel.danmakuList.count)
        }
        if !DanmakuCredentials.isConfigured { return t("settings.danmaku.sourceNone") }
        return t("anime.player.danmakuSourceName")
    }

    private var issueBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(LiquidGlassColors.warningOrange)
                Text(viewModel.danmakuError ?? t("anime.player.danmakuAuthMissing"))
                    .font(.system(size: 12))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if viewModel.currentEpisode != nil {
                    Button(t("anime.player.danmakuReload")) { viewModel.retryDanmakuLoad() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.accentCyan)
                }
                Button(t("anime.player.chooseDanmaku")) { viewModel.showDanmakuSourcePicker = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.accentCyan)
                    .disabled(viewModel.currentEpisode == nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(.regular, tint: LiquidGlassColors.warningOrange.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 弹幕来源

    private var sourceSection: some View {
        DanmakuPanelSection(title: t("anime.player.danmakuSectionSource")) {
            DanmakuPanelRow {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 13))
                        .foregroundStyle(LiquidGlassColors.accentCyan)
                    Text(t("anime.player.danmakuSourceName"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                    Spacer()
                    Text(viewModel.danmakuManualSourceActive ? t("anime.player.danmakuManualMatched") : t("anime.player.danmakuAutoMatched"))
                        .font(.system(size: 11))
                        .foregroundStyle(LiquidGlassColors.textTertiary)
                }
            }
            DanmakuPanelDivider()
            DanmakuPanelRow {
                Button {
                    viewModel.showDanmakuSourcePicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                        Text(t("anime.player.chooseDanmaku"))
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LiquidGlassColors.textTertiary)
                    }
                    .foregroundStyle(viewModel.currentEpisode == nil ? LiquidGlassColors.textTertiary : LiquidGlassColors.textPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.currentEpisode == nil)
            }
            DanmakuPanelDivider()
            DanmakuPanelRow {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("anime.player.danmakuTimeOffset"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LiquidGlassColors.textPrimary)
                        Text(t("anime.player.danmakuOffsetHint"))
                            .font(.system(size: 11))
                            .foregroundStyle(LiquidGlassColors.textTertiary)
                    }
                    Spacer()
                    Stepper(value: doubleBinding(\.timeOffset), in: -120...120, step: 0.5) {
                        Text(String(format: t("anime.player.danmakuTimeOffsetValue"), viewModel.danmakuSettings.timeOffset))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(LiquidGlassColors.accentCyan)
                            .frame(minWidth: 52, alignment: .trailing)
                    }
                    .fixedSize()
                }
            }
            DanmakuPanelDivider()
            DanmakuPanelToggleRow(title: t("anime.player.cacheDanmaku"), isOn: boolBinding(\.cacheEnabled), isLast: true)
        }
    }

    // MARK: 弹幕屏蔽

    private var shieldSection: some View {
        DanmakuPanelSection(title: t("anime.player.danmakuSectionShield")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "nosign")
                        .font(.system(size: 12))
                        .foregroundStyle(LiquidGlassColors.warningOrange)
                    Text(t("anime.player.danmakuShieldKeywords"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                    Spacer()
                    Button(t("anime.player.applyBlockedKeywords")) { saveBlockedWords() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.accentCyan)
                }
                TextField(t("anime.player.blockedKeywords"), text: $blockedText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .font(.system(size: 12))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                    .onSubmit { saveBlockedWords() }
                Text(t("anime.player.danmakuShieldHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: 弹幕显示

    private var displaySection: some View {
        DanmakuPanelSection(title: t("anime.player.danmakuSectionDisplay")) {
            DanmakuPanelSliderRow(title: t("anime.player.danmakuArea"),
                                  value: doubleBinding(\.area), range: 0.25...1.0, step: 0.125,
                                  valueText: "\(Int(viewModel.danmakuSettings.area * 100))%")
            DanmakuPanelDivider()
            DanmakuPanelSliderRow(title: t("anime.player.danmakuDuration"),
                                  value: doubleBinding(\.durationSeconds), range: 2...16, step: 1,
                                  valueText: String(format: t("anime.player.danmakuDurationValue"), viewModel.danmakuSettings.durationSeconds))
            DanmakuPanelDivider()
            DanmakuPanelSliderRow(title: t("anime.player.danmakuLineHeight"),
                                  value: doubleBinding(\.lineHeight), range: 1.0...2.5, step: 0.1,
                                  valueText: String(format: "%.1f", viewModel.danmakuSettings.lineHeight))
            DanmakuPanelDivider()
            DanmakuPanelToggleRow(title: t("anime.player.danmakuFollowSpeed"),
                                  subtitle: t("anime.player.danmakuFollowSpeedHint"),
                                  isOn: boolBinding(\.followSpeed))
            DanmakuPanelDivider()
            DanmakuPanelToggleRow(title: t("danmaku.top"), isOn: boolBinding(\.enableTop))
            DanmakuPanelDivider()
            DanmakuPanelToggleRow(title: t("danmaku.bottom"), isOn: boolBinding(\.enableBottom))
            DanmakuPanelDivider()
            DanmakuPanelToggleRow(title: t("danmaku.scroll"), isOn: boolBinding(\.enableScroll))
            DanmakuPanelDivider()
            DanmakuPanelToggleRow(title: t("anime.player.danmakuMassive"),
                                  subtitle: t("anime.player.danmakuMassiveHint"),
                                  isOn: boolBinding(\.massiveMode))
            DanmakuPanelDivider()
            DanmakuPanelToggleRow(title: t("player.enableDeduplication"),
                                  subtitle: t("anime.player.danmakuDeduplicationHint"),
                                  isOn: boolBinding(\.enableDeduplication), isLast: true)
        }
    }

    // MARK: 弹幕样式

    private var styleSection: some View {
        DanmakuPanelSection(title: t("anime.player.danmakuSectionStyle")) {
            DanmakuPanelToggleRow(title: t("anime.player.danmakuBorder"), isOn: boolBinding(\.showBorder))
            if viewModel.danmakuSettings.showBorder {
                DanmakuPanelDivider()
                DanmakuPanelSliderRow(title: t("anime.player.danmakuBorderWidth"),
                                      value: doubleBinding(\.borderWidth), range: 0.1...3.0, step: 0.1,
                                      valueText: String(format: "%.1f", viewModel.danmakuSettings.borderWidth))
            }
            DanmakuPanelDivider()
            DanmakuPanelToggleRow(title: t("anime.player.danmakuColorful"), isOn: boolBinding(\.allowColor))
            DanmakuPanelDivider()
            DanmakuPanelSliderRow(title: t("danmaku.fontSize"),
                                  value: doubleBinding(\.fontSize), range: 10...48, step: 1,
                                  valueText: "\(Int(viewModel.danmakuSettings.fontSize))")
            DanmakuPanelDivider()
            DanmakuPanelSliderRow(title: t("anime.player.danmakuFontWeight"),
                                  value: Binding(
                                    get: { Double(viewModel.danmakuSettings.fontWeight) },
                                    set: { newValue in
                                        var settings = viewModel.danmakuSettings
                                        settings.fontWeight = Int(newValue.rounded())
                                        viewModel.updateDanmakuSettings(settings)
                                    }),
                                  range: 1...9, step: 1,
                                  valueText: "\(viewModel.danmakuSettings.fontWeight)")
            DanmakuPanelDivider()
            DanmakuPanelSliderRow(title: t("player.opacity"),
                                  value: doubleBinding(\.opacity), range: 0.1...1.0, step: 0.05,
                                  valueText: "\(Int(viewModel.danmakuSettings.opacity * 100))%", isLast: true)
        }
    }

    // MARK: Bindings

    private func boolBinding(_ keyPath: WritableKeyPath<DanmakuSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { viewModel.danmakuSettings[keyPath: keyPath] },
            set: { newValue in
                var settings = viewModel.danmakuSettings
                settings[keyPath: keyPath] = newValue
                viewModel.updateDanmakuSettings(settings)
            }
        )
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<DanmakuSettings, Double>) -> Binding<Double> {
        Binding(
            get: { viewModel.danmakuSettings[keyPath: keyPath] },
            set: { newValue in
                var settings = viewModel.danmakuSettings
                settings[keyPath: keyPath] = newValue
                viewModel.updateDanmakuSettings(settings)
            }
        )
    }

    private func saveBlockedWords() {
        var settings = viewModel.danmakuSettings
        settings.blockedKeywords = blockedText.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        viewModel.updateDanmakuSettings(settings)
    }
}

// MARK: - 弹幕面板分组卡片

private struct DanmakuPanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textTertiary)
                .padding(.leading, 6)
            VStack(spacing: 0) {
                content
            }
            .liquidGlassSurface(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct DanmakuPanelRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DanmakuPanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

private struct DanmakuPanelToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var isLast: Bool = false

    var body: some View {
        DanmakuPanelRow {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(LiquidGlassColors.textTertiary)
                    }
                }
                Spacer()
                LiquidGlassSwitch(isOn: $isOn)
            }
        }
    }
}

private struct DanmakuPanelSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String
    var isLast: Bool = false

    var body: some View {
        DanmakuPanelRow {
            VStack(spacing: 6) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                    Spacer()
                    Text(valueText)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(LiquidGlassColors.accentCyan)
                }
                Slider(value: $value, in: range, step: step)
                    .tint(LiquidGlassColors.primaryPink)
                    .controlSize(.small)
                    .focusable(false)
            }
        }
    }
}

struct AnimeEpisodeActionsMenu: View {
    let sourceID: String
    let episodes: [AnimeDetail.AnimeEpisodeItem]
    let onBackToSearch: (() -> Void)?
    @ObservedObject var viewModel: AnimeDetailViewModel
    @State private var activeSheet: Destination?

    private enum Destination: Identifiable {
        case downloads
        case batch(sourceID: String, episodes: [AnimeDetail.AnimeEpisodeItem])

        var id: String {
            switch self {
            case .downloads: return "downloads"
            case .batch: return "batch"
            }
        }
    }

    var body: some View {
        Menu {
            Button(t("anime.player.batchDownload"), systemImage: "arrow.down.to.line") {
                activeSheet = .batch(sourceID: sourceID, episodes: episodes)
            }
            .disabled(episodes.isEmpty)
            Button(t("anime.player.downloads"), systemImage: "arrow.down.circle") {
                activeSheet = .downloads
            }
            if let onBackToSearch {
                Divider()
                Button(t("player.backToSearch"), systemImage: "arrow.uturn.backward", action: onBackToSearch)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(t("anime.player.episodeActions"))
        .help(t("anime.player.episodeActions"))
        .sheet(item: $activeSheet) { destination in
            switch destination {
            case .downloads:
                AnimePlayerFeatureSheet { AnimeDownloadManagementView(animeId: viewModel.anime.id) }
            case .batch(let sourceID, let episodes):
                AnimeBatchDownloadPicker(episodes: episodes) { selection in
                    guard let index = viewModel.sourceResults.firstIndex(where: { $0.id == sourceID }) else { return }
                    viewModel.downloadEpisodes(selection, from: index)
                }
            }
        }
    }
}

@MainActor
private struct AnimeBatchDownloadPicker: View {
    let episodes: [AnimeDetail.AnimeEpisodeItem]
    let onEnqueue: ([AnimeDetail.AnimeEpisodeItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>

    init(episodes: [AnimeDetail.AnimeEpisodeItem], onEnqueue: @escaping ([AnimeDetail.AnimeEpisodeItem]) -> Void) {
        self.episodes = episodes
        self.onEnqueue = onEnqueue
        _selected = State(initialValue: Set(episodes.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("anime.player.batchDownload")).font(.headline)
            HStack {
                Button(t("anime.player.selectAllEpisodes")) { selected = Set(episodes.map(\.id)) }
                Button(t("anime.player.clearSelection")) { selected.removeAll() }
            }
            List(episodes) { episode in
                Toggle(episode.name ?? String(format: t("episode.number"), episode.episodeNumber), isOn: Binding(
                    get: { selected.contains(episode.id) },
                    set: { if $0 { selected.insert(episode.id) } else { selected.remove(episode.id) } }
                ))
            }
            HStack {
                Button(t("cancel"), role: .cancel) { dismiss() }
                Spacer()
                Button(t("anime.player.addDownloads")) {
                    onEnqueue(episodes.filter { selected.contains($0.id) })
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(24).frame(minWidth: 440, minHeight: 420)
    }
}
