import SwiftUI
import AppKit

/// 浮动设计/属性面板共用的 NSWindow 子类。
///
/// 纯 `.borderless` 窗口默认 `canBecomeKey == false`，导致：
/// 1. SwiftUI `ColorPicker` 找不到 key window，无法弹出 NSColorPanel；
/// 2. 点击控件时 AppKit 把 activation 转交给应用里其它候选窗口，
///    会把用户已经关闭（隐藏）的主窗口重新拉回前台。
/// 这里显式开放 key/main 资格，让面板自身接管输入与 panel 子窗口宿主。
final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SceneWallpaperDesignPanelController {
    static let shared = SceneWallpaperDesignPanelController()

    private var windowController: NSWindowController?
    private var currentPath: String?

    private init() {}

    func present(for wallpaperPath: String) {
        if currentPath == wallpaperPath, let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = SceneWallpaperDesignViewModel(wallpaperPath: wallpaperPath) { [weak self] in
            self?.closePanel()
        }
        let window = KeyableBorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "设计壁纸"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.hasShadow = true
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 360, height: 600))
        window.minSize = NSSize(width: 360, height: 600)
        window.maxSize = NSSize(width: 360, height: 600)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.level = .floating

        let rootView = SceneWallpaperDesignPanel(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView
        anchorWindow(window)

        let controller = NSWindowController(window: window)
        windowController = controller
        currentPath = wallpaperPath
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        // 异步加载设计数据，避免主线程阻塞
        Task { await viewModel.loadAsync() }
    }

    func closePanel() {
        windowController?.close()
        windowController = nil
        currentPath = nil
    }

    private func anchorWindow(_ window: NSWindow) {
        guard let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else {
            window.center()
            return
        }
        let origin = NSPoint(
            x: visibleFrame.minX + 20,
            y: visibleFrame.maxY - window.frame.height - 52
        )
        window.setFrameOrigin(origin)
    }
}

// MARK: - 语言分组

/// 表示一组共享同一屏幕位置的多语言文本条目
struct LanguageGroup: Identifiable {
    let id: String
    let displayName: String
    var entries: [SceneWallpaperDesignViewModel.EntryRow]
    var selectedLanguageIndex: Int
    var languageEntryKeys: [[String]]

    var selectedEntry: SceneWallpaperDesignViewModel.EntryRow {
        entries[safe: selectedLanguageIndex] ?? entries[0]
    }

    /// 语言标签优先使用 renderer 实际回显文本，避免同名多语言对象被显示成错误语言。
    var languageLabels: [String] {
        entries.enumerated().map { idx, entry in
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let languageCode = Self.languageCode(from: trimmedName) {
                return languageCode
            }
            if !trimmedName.isEmpty {
                return trimmedName
            }
            return "语言 \(idx + 1)"
        }
    }

    private static func languageCode(from name: String) -> String? {
        let pattern = #"\(([A-Za-z]{2,8})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: name, range: NSRange(name.startIndex..., in: name)).last,
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: name) else {
            return nil
        }
        return String(name[range]).uppercased()
    }
}

@MainActor
final class SceneWallpaperDesignViewModel: ObservableObject {
    struct EntryRow: Identifiable {
        let id: String
        let name: String
        let value: String
        let key: String
        let source: DynamicTextEntry
        var override: SceneDynamicTextDesignOverride

        var displayText: String {
            if let textOverride = override.textOverride,
               !textOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return textOverride
            }
            return value
        }
    }

    @Published private(set) var wallpaperName: String
    @Published var languageGroups: [LanguageGroup] = []
    @Published private(set) var isLoading: Bool = true

    let wallpaperPath: String
    private let onClose: () -> Void
    private var pendingSaveTasks: [String: Task<Void, Never>] = [:]

    init(wallpaperPath: String, onClose: @escaping () -> Void) {
        self.wallpaperPath = wallpaperPath
        self.onClose = onClose
        self.wallpaperName = URL(fileURLWithPath: wallpaperPath).lastPathComponent
    }

    func loadAsync() async {
        await MainActor.run { isLoading = true }

        // 主线程：访问 VideoWallpaperManager（必须主线程）
        let sidecar = await MainActor.run {
            currentDynamicTextInfo()
        }

        // 后台线程：文件 I/O 和数据处理
        let result = await Task.detached(priority: .userInitiated) { [wallpaperPath] in
            let name = SceneWallpaperDesignService.wallpaperTitle(for: wallpaperPath)
            let document = SceneWallpaperDesignService.loadDocument(for: wallpaperPath)
            guard let sidecar = sidecar else {
                return (name: name, languageGroups: [LanguageGroup](), needsSave: false, doc: document)
            }
            let designed = SceneWallpaperDesignService.resolveDesignedInfo(from: sidecar, wallpaperPath: wallpaperPath)
            let rows: [EntryRow] = designed.entries.map { entry in
                EntryRow(
                    id: entry.id,
                    name: entry.source.name,
                    value: entry.source.resolvedText ?? entry.source.value ?? "",
                    key: entry.id,
                    source: entry.source,
                    override: document.overrides[entry.id] ?? SceneDynamicTextDesignOverride()
                )
            }
            var languageGroups = Self.groupByPosition(rows)
            var doc = document
            var needsSave = false
            for (gIdx, group) in languageGroups.enumerated() where group.entries.count > 1 {
                let hasExplicitOverride = group.entries.contains(where: {
                    doc.overrides[$0.key]?.hidden != nil
                })
                if !hasExplicitOverride {
                    for (eIdx, entry) in group.entries.enumerated() {
                        let shouldHide = eIdx != group.selectedLanguageIndex
                        var mutableEntry = languageGroups[gIdx].entries[eIdx]
                        mutableEntry.override.hidden = shouldHide
                        languageGroups[gIdx].entries[eIdx] = mutableEntry
                        doc.overrides[entry.key] = mutableEntry.override
                    }
                    needsSave = true
                }
            }
            return (name: name, languageGroups: languageGroups, needsSave: needsSave, doc: doc)
        }.value

        // 主线程：更新 UI + 保存文档
        await MainActor.run {
            wallpaperName = result.name
            languageGroups = result.languageGroups
            isLoading = false
        }
        if result.needsSave {
            try? SceneWallpaperDesignService.saveDocument(result.doc, for: wallpaperPath)
            await MainActor.run {
                LiquidGlassClockOverlayManager.shared.rebuildAll()
            }
        }
    }

    private func currentDynamicTextInfo() -> WallpaperDynamicTextsInfo? {
        if let currentVideoURL = VideoWallpaperManager.shared.currentVideoURL,
           let sidecar = WallpaperDynamicTextParser.loadSidecar(for: currentVideoURL),
           pathsMatch(sidecar.wallpaperPath, wallpaperPath) {
            return sidecar
        }
        return nil
    }

    private func pathsMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs, !lhs.isEmpty else { return false }
        return URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    /// 按位置分组（5 scene units 以内视为同一位置的多语言版本）
    nonisolated static func groupByPosition(_ rows: [EntryRow]) -> [LanguageGroup] {
        var groups: [LanguageGroup] = []
        var used = Set<String>()
        let rowsByParent = Dictionary(grouping: rows) { $0.source.parentID }

        for row in rows {
            guard !used.contains(row.id) else { continue }
            if row.source.parentID != nil { continue }
            let ex = row.source.finalOriginX ?? row.source.originX ?? row.source.finalX ?? row.source.x ?? 0
            let ey = row.source.finalOriginY ?? row.source.originY ?? row.source.finalY ?? row.source.y ?? 0

            // 找同位置条目
            let siblings = rows.filter { other in
                guard !used.contains(other.id) else { return false }
                guard other.source.parentID == nil else { return false }
                let ox = other.source.finalOriginX ?? other.source.originX ?? other.source.finalX ?? other.source.x ?? 0
                let oy = other.source.finalOriginY ?? other.source.originY ?? other.source.finalY ?? other.source.y ?? 0
                return abs(ox - ex) < 5 && abs(oy - ey) < 5
            }

            // 确定显示名称：取第一个非空名称，否则用默认名称
            let groupName = siblings.first(where: { !$0.name.isEmpty })?.name ?? t("design.unnamed")

            // 确定当前选中语言：
            // 若有显式覆盖的可见条目，选第一个可见的
            // 否则按 renderOrder 最大的选（与渲染层 deduplicateByPosition 一致）
            let selectedIndex: Int
            let explicitVisible = siblings.firstIndex(where: {
                $0.override.hidden == false
            })
            if let vi = explicitVisible {
                selectedIndex = vi
            } else if let sourceVisible = siblings.firstIndex(where: { $0.source.visible }) {
                selectedIndex = sourceVisible
            } else {
                // 无显式覆盖或全部隐藏 → 仿照 deduplicateByPosition 选 renderOrder 最大的
                selectedIndex = siblings.enumerated().max(by: {
                    ($0.element.source.renderOrder ?? 0) < ($1.element.source.renderOrder ?? 0)
                })?.offset ?? 0
            }

            let group = LanguageGroup(
                id: siblings.first?.id ?? row.id,
                displayName: groupName,
                entries: Array(siblings),
                selectedLanguageIndex: selectedIndex,
                languageEntryKeys: siblings.map { sibling in
                    var keys = [sibling.key]
                    if let parentID = sibling.source.id {
                        keys += rowsByParent[parentID]?.map(\.key) ?? []
                    }
                    return Array(Set(keys))
                }
            )

            for s in siblings {
                used.insert(s.id)
                if let parentID = s.source.id {
                    for child in rowsByParent[parentID] ?? [] {
                        used.insert(child.id)
                    }
                }
            }
            groups.append(group)
        }
        return groups
    }

    /// 切换语言：隐藏旧语言，显示新语言（单次文档写入 + 单次 rebuildAll）
    func selectLanguage(in groupID: String, index: Int) {
        guard let gIdx = languageGroups.firstIndex(where: { $0.id == groupID }),
              index < languageGroups[gIdx].entries.count else { return }
        // 一次读取文档，同时更新整组条目，保证同一位置只有当前语言可见。
        var document = SceneWallpaperDesignService.loadDocument(for: wallpaperPath)
        document.wallpaperPath = wallpaperPath

        let selectedKeys = Set(languageGroups[gIdx].languageEntryKeys[safe: index] ?? [languageGroups[gIdx].entries[index].key])
        let allKeys = Set(languageGroups[gIdx].languageEntryKeys.flatMap { $0 })
        for eIdx in languageGroups[gIdx].entries.indices {
            var entry = languageGroups[gIdx].entries[eIdx]
            entry.override.hidden = eIdx != index
            languageGroups[gIdx].entries[eIdx] = entry
            document.overrides[entry.key] = entry.override
        }
        for key in allKeys where !languageGroups[gIdx].entries.contains(where: { $0.key == key }) {
            var override = document.overrides[key] ?? SceneDynamicTextDesignOverride()
            override.hidden = !selectedKeys.contains(key)
            document.overrides[key] = override
        }

        // 单次写入 + 单次重建
        try? SceneWallpaperDesignService.saveDocument(document, for: wallpaperPath)
        LiquidGlassClockOverlayManager.shared.rebuildAll()

        languageGroups[gIdx].selectedLanguageIndex = index
        objectWillChange.send()
    }

    /// 更新组内当前选中条目的覆盖值
    func updateGroup(_ group: LanguageGroup) {
        guard let gIdx = languageGroups.firstIndex(where: { $0.id == group.id }) else { return }
        languageGroups[gIdx] = group
        let entry = group.selectedEntry
        scheduleSave(entry)
    }

    /// 切换整个组的隐藏状态（组 hidden = 所有条目 hidden）
    func toggleGroupHidden(_ groupID: String) {
        guard let gIdx = languageGroups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = languageGroups[gIdx]
        let currentlyHidden = group.entries.allSatisfy { $0.override.hidden == true }
        var document = SceneWallpaperDesignService.loadDocument(for: wallpaperPath)
        document.wallpaperPath = wallpaperPath

        for (eIdx, _) in group.entries.enumerated() {
            var entry = languageGroups[gIdx].entries[eIdx]
            entry.override.hidden = !currentlyHidden
            languageGroups[gIdx].entries[eIdx] = entry
            document.overrides[entry.key] = entry.override
        }

        try? SceneWallpaperDesignService.saveDocument(document, for: wallpaperPath)
        LiquidGlassClockOverlayManager.shared.rebuildAll()
        objectWillChange.send()
    }

    func resetToDefaults() {
        SceneWallpaperDesignService.resetDocument(for: wallpaperPath)
        Task { await loadAsync() }
        LiquidGlassClockOverlayManager.shared.rebuildAll()
    }

    private func save(_ row: EntryRow) {
        var document = SceneWallpaperDesignService.loadDocument(for: wallpaperPath)
        document.wallpaperPath = wallpaperPath
        document.overrides[row.key] = row.override
        try? SceneWallpaperDesignService.saveDocument(document, for: wallpaperPath)
        LiquidGlassClockOverlayManager.shared.rebuildAll()
    }

    private func scheduleSave(_ row: EntryRow) {
        pendingSaveTasks[row.key]?.cancel()
        pendingSaveTasks[row.key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            self?.save(row)
            self?.pendingSaveTasks[row.key] = nil
        }
    }

    func closePanel() {
        onClose()
    }
}

struct SceneWallpaperDesignPanel: View {
    @ObservedObject var viewModel: SceneWallpaperDesignViewModel
    @ObservedObject private var localization = LocalizationService.shared
    private let accentTint = Color(nsColor: .controlAccentColor)

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 4)
            glassDivider

            if viewModel.isLoading {
                loadingState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if viewModel.languageGroups.isEmpty {
                            Text(t("design.noDesignableText"))
                                .font(.system(size: 12))
                                .foregroundStyle(LiquidGlassColors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        ForEach(viewModel.languageGroups) { group in
                            if group.entries.count > 1 {
                                LanguageGroupEditor(
                                    group: Binding(
                                        get: { viewModel.languageGroups.first(where: { $0.id == group.id }) ?? group },
                                        set: { viewModel.updateGroup($0) }
                                    ),
                                    onSelectLanguage: { index in
                                        viewModel.selectLanguage(in: group.id, index: index)
                                    }
                                )
                            } else if let single = group.entries.first {
                                SceneTextEntryEditor(
                                    row: Binding(
                                        get: {
                                            viewModel.languageGroups
                                                .first(where: { $0.id == group.id })?
                                                .entries.first ?? single
                                        },
                                        set: { newRow in
                                            var g = viewModel.languageGroups.first(where: { $0.id == group.id }) ?? group
                                            g.entries[0] = newRow
                                            viewModel.updateGroup(g)
                                        }
                                    )
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)

                glassDivider

                HStack {
                    resetButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .glassBackground()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(width: 360, height: 600)
        .tint(accentTint)
        .accentColor(accentTint)
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .controlSize(.small)
            Text("加载中...")
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textSecondary)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accentTint)
                .frame(width: 26, height: 26)
                .background(accentTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(t("design.designScene"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                Text(viewModel.wallpaperName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                viewModel.closePanel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(accentTint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var glassDivider: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [accentTint.opacity(0.3), .white.opacity(0.06), accentTint.opacity(0.3)],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(height: 0.5)
    }

    private var resetButton: some View {
        Button {
            viewModel.resetToDefaults()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                Text(t("design.resetToDefault"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(accentTint)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(accentTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

}

// MARK: - 多语言组编辑器

private struct LanguageGroupEditor: View {
    @Binding var group: LanguageGroup
    let onSelectLanguage: (Int) -> Void
    private let accentTint = Color(nsColor: .controlAccentColor)
    private let labelWidth: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 条目标题 + 语言选择器
            HStack(spacing: 8) {
                Circle()
                    .fill(accentTint.opacity(0.6))
                    .frame(width: 6, height: 6)
                Text(group.displayName.isEmpty ? t("design.unnamed") : group.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                Spacer(minLength: 4)
                // 语言菜单 —— 切换即控制显示状态，代替隐藏开关
                Menu {
                    ForEach(Array(group.entries.enumerated()), id: \.offset) { idx, _ in
                        Button {
                            onSelectLanguage(idx)
                        } label: {
                            HStack {
                                Text(group.languageLabels[idx])
                                if idx == group.selectedLanguageIndex {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 10))
                        Text(group.languageLabels[safe: group.selectedLanguageIndex] ?? t("design.language"))
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(accentTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(accentTint.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .stroke(accentTint.opacity(0.25), lineWidth: 0.5)
                            )
                    )
                }
                .fixedSize()
            }

            // 条目内容预览（当前选中语言的值）
            let selected = group.selectedEntry
            if !selected.displayText.isEmpty {
                Text(selected.displayText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
                    .lineLimit(2)
                    .padding(.leading, 14)
            }

            // 当前选中语言的详细配置（不显示隐藏开关——语言切换代替隐藏）
            SceneTextConfigPanel(
                row: Binding(
                    get: {
                        guard let g = group.entries[safe: group.selectedLanguageIndex] else { return group.selectedEntry }
                        return g
                    },
                    set: { newEntry in
                        let idx = group.selectedLanguageIndex
                        guard idx < group.entries.count else { return }
                        group.entries[idx] = newEntry
                    }
                ),
                showHideToggle: false
            )
        }
        .padding(0)
    }
}

// MARK: - 单条目标题编辑器

/// 单条目标题编辑器（带隐藏开关 + 配置面板）
private struct SceneTextEntryEditor: View {
    @Binding var row: SceneWallpaperDesignViewModel.EntryRow
    private let accentTint = Color(nsColor: .controlAccentColor)
    private let labelWidth: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 条目标题
            HStack(spacing: 8) {
                Circle()
                    .fill(accentTint.opacity(0.6))
                    .frame(width: 6, height: 6)
                Text(row.name.isEmpty ? t("design.unnamed") : row.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
            }

            if !row.displayText.isEmpty {
                Text(row.displayText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
                    .lineLimit(2)
                    .padding(.leading, 14)
            }

            SceneTextConfigPanel(row: $row)
        }
        .padding(0)
    }
}

/// 单条目配置面板（不带头部标题，可选隐藏开关，供 SceneTextEntryEditor / LanguageGroupEditor 复用）
private struct SceneTextConfigPanel: View {
    @Binding var row: SceneWallpaperDesignViewModel.EntryRow
    var showHideToggle: Bool = true
    private let accentTint = Color(nsColor: .controlAccentColor)
    private let labelWidth: CGFloat = 80

    @ViewBuilder
    var body: some View {
        // 第一张卡片：隐藏 + 文本覆盖 + 时钟选项
        if showHideToggle {
            glassCard {
                VStack(alignment: .leading, spacing: 10) {
                    toggleRow(t("design.hidden"), isOn: Binding(
                        get: { row.override.hidden ?? false },
                        set: {
                            row.override.hidden = $0
                            row = row
                        }
                    ))
                    textAndClockContent
                }
            }
        } else {
            glassCard {
                VStack(alignment: .leading, spacing: 10) {
                    textAndClockContent
                }
            }
        }

        // 第二张卡片：滑块
        glassCard {
            VStack(alignment: .leading, spacing: 10) {
                sliderRow(t("design.opacity"), value: Binding(
                    get: { row.override.alpha ?? row.source.alpha ?? 1 },
                    set: {
                        row.override.alpha = $0
                        row = row
                    }
                ), range: 0...1, step: 0.05)

                sliderRow(t("design.xOffset"), value: Binding(
                    get: { row.override.offsetX ?? 0 },
                    set: {
                        row.override.offsetX = $0
                        row = row
                    }
                ), range: -400...400, step: 1)

                sliderRow(t("design.yOffset"), value: Binding(
                    get: { row.override.offsetY ?? 0 },
                    set: {
                        row.override.offsetY = $0
                        row = row
                    }
                ), range: -400...400, step: 1)

                sliderRow(t("design.scale"), value: Binding(
                    get: { row.override.scaleMultiplier ?? 1 },
                    set: {
                        row.override.scaleMultiplier = $0
                        row = row
                    }
                ), range: 0.2...3, step: 0.05)

                sliderRow(t("design.fontSizeMultiplier"), value: Binding(
                    get: { row.override.fontSizeMultiplier ?? 1 },
                    set: {
                        row.override.fontSizeMultiplier = $0
                        row = row
                    }
                ), range: 0.2...3, step: 0.05)

                sliderRow(t("design.rotation"), value: Binding(
                    get: { row.override.rotationOverride ?? (row.source.finalAngle ?? row.source.rotation ?? 0) },
                    set: {
                        row.override.rotationOverride = $0
                        row = row
                    }
                ), range: -3.14...3.14, step: 0.01)

                sliderRow(t("design.maxWidth"), value: Binding(
                    get: { row.override.maxWidthOverride ?? row.source.maxWidth ?? 500 },
                    set: {
                        row.override.maxWidthOverride = $0
                        row = row
                    }
                ), range: 50...3000, step: 10)
            }
        }

        // 第三张卡片：字体
        glassCard {
            VStack(alignment: .leading, spacing: 10) {
                fieldRow(t("design.fontName")) {
                    TextField(t("design.fontName"), text: Binding(
                        get: { row.override.fontFamilyOverride ?? "" },
                        set: {
                            row.override.fontFamilyOverride = $0.isEmpty ? nil : $0
                            row = row
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .tint(accentTint)
                    .accentColor(accentTint)
                }

                fieldRow(t("design.fontPath")) {
                    TextField(t("design.fontPath"), text: Binding(
                        get: { row.override.fontPathOverride ?? "" },
                        set: {
                            row.override.fontPathOverride = $0.isEmpty ? nil : $0
                            row = row
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .tint(accentTint)
                    .accentColor(accentTint)
                }

                fieldRow(t("design.alignment")) {
                    Picker("", selection: Binding(
                        get: { row.override.alignmentOverride ?? row.source.alignment ?? "center center" },
                        set: {
                            row.override.alignmentOverride = $0
                            row = row
                        }
                    )) {
                        Text(t("design.alignLeft")).tag("left center")
                        Text(t("design.alignCenter")).tag("center center")
                        Text(t("design.alignRight")).tag("right center")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .tint(accentTint)
                    .accentColor(accentTint)
                }

                colorRow
            }
        }
    }

    // MARK: - 共享的文本/时钟内容（避免 showHideToggle 分支重复）
    @ViewBuilder
    private var textAndClockContent: some View {
        fieldRow(t("design.textOverride")) {
            TextField(t("design.textOverride"), text: Binding(
                get: { row.override.textOverride ?? "" },
                set: {
                    row.override.textOverride = $0.isEmpty ? nil : $0
                    row = row
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(LiquidGlassColors.textPrimary)
            .tint(accentTint)
            .accentColor(accentTint)
        }

        if row.source.behavior == "clock" {
            toggleRow(t("design.use24Hour"), isOn: Binding(
                get: { row.override.use24hFormat ?? true },
                set: {
                    row.override.use24hFormat = $0
                    row = row
                }
            ))

            toggleRow(t("design.showSeconds"), isOn: Binding(
                get: { row.override.showSeconds ?? false },
                set: {
                    row.override.showSeconds = $0
                    row = row
                }
            ))

            fieldRow(t("design.delimiter")) {
                TextField(t("design.delimiter"), text: Binding(
                    get: { row.override.delimiter ?? "" },
                    set: {
                        row.override.delimiter = $0.isEmpty ? nil : $0
                        row = row
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textPrimary)
                .tint(accentTint)
                .accentColor(accentTint)
            }
        }
    }

    // MARK: - 辅助视图组件

    private func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(accentTint.opacity(0.2), lineWidth: 0.5)
                    )
            )
    }

    @ViewBuilder
    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .frame(width: labelWidth, alignment: .leading)
                Spacer(minLength: 0)
                Text(displayNumber(value.wrappedValue))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accentTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accentTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Slider(value: value, in: range, step: step)
                .tint(accentTint)
                .accentColor(accentTint)
                .padding(.leading, labelWidth + 10)
        }
    }

    @ViewBuilder
    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textPrimary)
                .frame(width: labelWidth, alignment: .leading)
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(accentTint)
                .accentColor(accentTint)
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accentTint.opacity(isOn.wrappedValue ? 0.06 : 0))
        )
    }

    @ViewBuilder
    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textPrimary)
                .frame(width: labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var colorRow: some View {
        HStack(spacing: 10) {
            Text(t("design.colorOverride"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textPrimary)
                .frame(width: labelWidth, alignment: .leading)
            Spacer(minLength: 0)
            let selection = Binding<Color>(
                get: {
                    let raw = row.override.color ?? row.source.color ?? [1, 1, 1]
                    return color(from: raw)
                },
                set: {
                    row.override.color = colorArray(from: $0)
                    row = row
                }
            )
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection.wrappedValue)
                    .frame(width: 54, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(accentTint.opacity(0.4), lineWidth: 1)
                    )
                ColorPicker("", selection: selection, supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 54, height: 24)
            }
        }
    }

    private func displayNumber(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.0001 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.2f", value)
    }

    private func color(from raw: [Double]) -> Color {
        let r = raw.indices.contains(0) ? raw[0] : 1
        let g = raw.indices.contains(1) ? raw[1] : 1
        let b = raw.indices.contains(2) ? raw[2] : 1
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    private func colorArray(from color: Color) -> [Double] {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return [
            Double(nsColor.redComponent),
            Double(nsColor.greenComponent),
            Double(nsColor.blueComponent)
        ]
    }
}

// MARK: - 玻璃背景修饰器
private extension View {
    func glassBackground() -> some View {
        self.background(
            ZStack {
                // 轻量液态玻璃材质（优化滚动性能）
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                    .opacity(0.82)

                // 极简边框
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        )
    }
}
