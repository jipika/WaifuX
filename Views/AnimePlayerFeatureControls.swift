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

/// 弹幕面板（Kazumi 分区结构：来源 / 屏蔽 / 显示 / 样式）。
/// 与 AnimePlaybackSettingsView 同款原生 grouped Form 控件；
/// 所有行控件写入同一份 DanmakuSettings，播放中的弹幕层即时生效。
struct AnimeDanmakuSettingsPanel: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @State private var blockedText = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: boolBinding(\.isEnabled)) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("danmaku.title"))
                            Text(statusSubtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if viewModel.isLoadingDanmaku {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }

            if viewModel.danmakuError != nil || !DanmakuCredentials.isConfigured {
                Section {
                    Label {
                        Text(viewModel.danmakuError ?? t("anime.player.danmakuAuthMissing"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 12) {
                        if viewModel.currentEpisode != nil {
                            Button(t("anime.player.danmakuReload")) { viewModel.retryDanmakuLoad() }
                                .buttonStyle(.link)
                        }
                        Button(t("anime.player.chooseDanmaku")) { viewModel.showDanmakuSourcePicker = true }
                            .buttonStyle(.link)
                            .disabled(viewModel.currentEpisode == nil)
                    }
                    .font(.caption)
                }
            }

            sourceSection
            shieldSection
            displaySection
            styleSection

            Section {
                Button {
                    viewModel.updateDanmakuSettings(viewModel.danmakuSettings.resettingAppearance())
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("anime.player.danmakuResetDefaults"))
                        Text(t("anime.player.danmakuResetHint"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { blockedText = viewModel.danmakuSettings.blockedKeywords.joined(separator: ", ") }
    }

    private var statusSubtitle: String {
        if viewModel.isLoadingDanmaku { return t("anime.player.danmakuLoading") }
        if !viewModel.danmakuList.isEmpty {
            return String(format: t("anime.player.danmakuCount"), viewModel.danmakuList.count)
        }
        if !DanmakuCredentials.isConfigured { return t("settings.danmaku.sourceNone") }
        return t("anime.player.danmakuSourceName")
    }

    // MARK: 弹幕来源

    private var sourceSection: some View {
        Section(t("anime.player.danmakuSectionSource")) {
            LabeledContent(t("anime.player.danmakuSourceName")) {
                Text(viewModel.danmakuManualSourceActive ? t("anime.player.danmakuManualMatched") : t("anime.player.danmakuAutoMatched"))
                    .foregroundStyle(.secondary)
            }
            Button {
                viewModel.showDanmakuSourcePicker = true
            } label: {
                HStack {
                    Text(t("anime.player.chooseDanmaku"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.currentEpisode == nil)
            Stepper(value: doubleBinding(\.timeOffset), in: -120...120, step: 0.5) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("anime.player.danmakuTimeOffset"))
                        Text(t("anime.player.danmakuOffsetHint"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: t("anime.player.danmakuTimeOffsetValue"), viewModel.danmakuSettings.timeOffset))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Toggle(t("anime.player.cacheDanmaku"), isOn: boolBinding(\.cacheEnabled))
        }
    }

    // MARK: 弹幕屏蔽

    private var shieldSection: some View {
        Section(t("anime.player.danmakuSectionShield")) {
            HStack {
                Text(t("anime.player.danmakuShieldKeywords"))
                Spacer()
                Button(t("anime.player.applyBlockedKeywords")) { saveBlockedWords() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            TextField(t("anime.player.blockedKeywords"), text: $blockedText, axis: .vertical)
                .lineLimit(2...4)
                .onSubmit { saveBlockedWords() }
            Text(t("anime.player.danmakuShieldHint"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 弹幕显示

    private var displaySection: some View {
        Section(t("anime.player.danmakuSectionDisplay")) {
            DanmakuPanelSliderRow(title: t("anime.player.danmakuArea"),
                                  value: doubleBinding(\.area), range: 0.25...1.0, step: 0.125,
                                  valueText: "\(Int(viewModel.danmakuSettings.area * 100))%")
            DanmakuPanelSliderRow(title: t("anime.player.danmakuDuration"),
                                  value: doubleBinding(\.durationSeconds), range: 2...16, step: 1,
                                  valueText: String(format: t("anime.player.danmakuDurationValue"), viewModel.danmakuSettings.durationSeconds))
            DanmakuPanelSliderRow(title: t("anime.player.danmakuLineHeight"),
                                  value: doubleBinding(\.lineHeight), range: 1.0...2.5, step: 0.1,
                                  valueText: String(format: "%.1f", viewModel.danmakuSettings.lineHeight))
            DanmakuPanelToggleRow(title: t("anime.player.danmakuFollowSpeed"),
                                  subtitle: t("anime.player.danmakuFollowSpeedHint"),
                                  isOn: boolBinding(\.followSpeed))
            Toggle(t("danmaku.top"), isOn: boolBinding(\.enableTop))
            Toggle(t("danmaku.bottom"), isOn: boolBinding(\.enableBottom))
            Toggle(t("danmaku.scroll"), isOn: boolBinding(\.enableScroll))
            DanmakuPanelToggleRow(title: t("anime.player.danmakuMassive"),
                                  subtitle: t("anime.player.danmakuMassiveHint"),
                                  isOn: boolBinding(\.massiveMode))
            DanmakuPanelToggleRow(title: t("player.enableDeduplication"),
                                  subtitle: t("anime.player.danmakuDeduplicationHint"),
                                  isOn: boolBinding(\.enableDeduplication))
        }
    }

    // MARK: 弹幕样式

    private var styleSection: some View {
        Section(t("anime.player.danmakuSectionStyle")) {
            Toggle(t("anime.player.danmakuBorder"), isOn: boolBinding(\.showBorder))
            if viewModel.danmakuSettings.showBorder {
                DanmakuPanelSliderRow(title: t("anime.player.danmakuBorderWidth"),
                                      value: doubleBinding(\.borderWidth), range: 0.1...3.0, step: 0.1,
                                      valueText: String(format: "%.1f", viewModel.danmakuSettings.borderWidth))
            }
            Toggle(t("anime.player.danmakuColorful"), isOn: boolBinding(\.allowColor))
            DanmakuPanelSliderRow(title: t("danmaku.fontSize"),
                                  value: doubleBinding(\.fontSize), range: 10...48, step: 1,
                                  valueText: "\(Int(viewModel.danmakuSettings.fontSize))")
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
            DanmakuPanelSliderRow(title: t("player.opacity"),
                                  value: doubleBinding(\.opacity), range: 0.1...1.0, step: 0.05,
                                  valueText: "\(Int(viewModel.danmakuSettings.opacity * 100))%")
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

// MARK: - 弹幕面板行（原生 Form 行；分组/分隔线由 Form 提供）

private struct DanmakuPanelToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .focusable(false)
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
