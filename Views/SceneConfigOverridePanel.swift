import SwiftUI
import AppKit

/// Scene Config 覆盖参数编辑面板
///
/// 用于调整 wallpaper-wgpu 中 scene.json 定义的内部参数
/// （相机、视差、显示、颜色等），通过 `--user-properties` 的 `__` 前缀键传递。
@MainActor
final class SceneConfigOverridePanelController {
    static let shared = SceneConfigOverridePanelController()

    private var windowController: NSWindowController?
    private var currentPath: String?

    private init() {}

    func present(for wallpaperPath: String) {
        if currentPath == wallpaperPath, let window = windowController?.window {
            anchorWindow(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = SceneConfigOverrideViewModel(wallpaperPath: wallpaperPath) { [weak self] in
            self?.closePanel()
        }
        let window = KeyableBorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 580),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "场景高级设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.hasShadow = true
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 360, height: 580))
        window.minSize = NSSize(width: 360, height: 580)
        window.maxSize = NSSize(width: 360, height: 580)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.level = .floating

        let rootView = SceneConfigOverridePanel(viewModel: viewModel)
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

// MARK: - ViewModel

@MainActor
final class SceneConfigOverrideViewModel: ObservableObject {
    /// 单个配置项
    struct ConfigRow: Identifiable {
        let id: String
        let key: SceneConfigOverrideKey
        var currentValue: AnyCodableValue
        let isModified: Bool
    }

    @Published private(set) var wallpaperName: String
    @Published var rows: [ConfigRow] = []

    let wallpaperPath: String
    private let onClose: () -> Void
    private var applyTask: Task<Void, Never>?
    /// 从 scene.json 读取的真实默认值缓存（避免每次 reset 重新解析 scene.pkg）
    var sceneDefaults: [SceneConfigOverrideKey: AnyCodableValue] = [:]

    init(wallpaperPath: String, onClose: @escaping () -> Void) {
        self.wallpaperPath = wallpaperPath
        self.onClose = onClose
        self.wallpaperName = SceneWallpaperDesignService.wallpaperTitle(for: wallpaperPath)
        load()
    }

    func load() {
        wallpaperName = SceneWallpaperDesignService.wallpaperTitle(for: wallpaperPath)
        let overrides = SceneConfigOverrideService.loadOverrides(for: wallpaperPath)
        // 从 scene.json 读取真实默认值（此前用写死值，导致视差等回显错误）
        sceneDefaults = SceneConfigOverrideService.loadSceneDefaults(for: wallpaperPath)
        rows = SceneConfigOverrideKey.allCases.map { key in
            // 用户 override > scene.json 真实默认值 > 写死兜底
            let value = overrides[key] ?? sceneDefaults[key] ?? defaultCodableValue(for: key)
            return ConfigRow(
                id: key.rawValue,
                key: key,
                currentValue: value,
                isModified: overrides[key] != nil
            )
        }
    }

    func updateValue(key: SceneConfigOverrideKey, value: AnyCodableValue) {
        SceneConfigOverrideService.setOverride(key: key, value: value, for: wallpaperPath)
        if let index = rows.firstIndex(where: { $0.key == key }) {
            rows[index].currentValue = value
        }
        scheduleApply()
    }

    func resetAll() {
        SceneConfigOverrideService.resetAllOverrides(for: wallpaperPath)
        load()
        scheduleApply()
    }

    func reset(key: SceneConfigOverrideKey) {
        SceneConfigOverrideService.resetOverride(key: key, for: wallpaperPath)
        if let index = rows.firstIndex(where: { $0.key == key }) {
            let defaultVal = sceneDefaults[key] ?? defaultCodableValue(for: key)
            rows[index].currentValue = defaultVal
        }
        scheduleApply()
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let mergedJSON = SceneConfigOverrideService.mergedPropertiesJSON(
                userPropertiesJSON: SceneWallpaperPropertiesService.propertiesOverrideJSON(for: wallpaperPath),
                for: wallpaperPath
            )
            do {
                try await WallpaperEngineXBridge.shared.refreshWallpaperProperties(userProperties: mergedJSON)
            } catch {
                print("[SceneConfigOverridePanel] 场景配置更新失败: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        onClose()
    }

    func defaultCodableValue(for key: SceneConfigOverrideKey) -> AnyCodableValue {
        if key.isBool {
            return .bool(key.rawValue == "__parallax_enabled" ? false : true)
        }
        if key.isColor {
            return .string("")
        }
        return .number(key.defaultValue)
    }
}

// MARK: - Panel View

struct SceneConfigOverridePanel: View {
    @ObservedObject var viewModel: SceneConfigOverrideViewModel
    @ObservedObject private var localization = LocalizationService.shared
    private let accentTint = Color(nsColor: .controlAccentColor)
    private let labelWidth: CGFloat = 100

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 4)
            glassDivider

            if viewModel.rows.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        cameraSection
                        parallaxSection
                        displaySection
                        colorSection
                        miscSection
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)

                glassDivider

                HStack {
                    resetButton
                    Spacer()
                    closeButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .glassBackground()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(width: 360, height: 580)
        .tint(accentTint)
        .accentColor(accentTint)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accentTint)
                .frame(width: 26, height: 26)
                .background(accentTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("场景高级设置")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)

                Text(viewModel.wallpaperName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button {
                viewModel.close()
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
            .fill(accentTint.opacity(0.15))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }

    // MARK: - Section Groups

    @ViewBuilder
    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("📷 相机")
            glassCard {
                VStack(spacing: 10) {
                    sliderRow(for: .cameraZoom)
                    sliderRow(for: .cameraFov)
                    sliderRow(for: .cameraNearz)
                    sliderRow(for: .cameraFarz)
                }
            }
        }
    }

    @ViewBuilder
    private var parallaxSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("🎯 视差")
            glassCard {
                VStack(spacing: 10) {
                    toggleRow(for: .parallaxEnabled)
                    sliderRow(for: .parallaxAmount)
                    sliderRow(for: .parallaxDelay)
                    sliderRow(for: .parallaxMouseInfluence)
                }
            }
        }
    }

    @ViewBuilder
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("🖥 显示")
            glassCard {
                VStack(spacing: 10) {
                    sliderRow(for: .orthoWidth)
                    sliderRow(for: .orthoHeight)
                    sliderRow(for: .textureReduction)
                }
            }
        }
    }

    @ViewBuilder
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("🎨 颜色")
            glassCard {
                VStack(spacing: 10) {
                    colorRow(for: .clearColor, label: "背景")
                    colorRow(for: .ambientColor, label: "环境光")
                    colorRow(for: .skylightColor, label: "天光")
                }
            }
        }
    }

    @ViewBuilder
    private var miscSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("⚙️ 其他")
            glassCard {
                VStack(spacing: 10) {
                    toggleRow(for: .clearEnabled)
                    toggleRow(for: .cameraFade)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 32))
                .foregroundStyle(LiquidGlassColors.textTertiary)
            Text("未检测到场景配置")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textTertiary)
        }
    }

    // MARK: - Buttons

    private var resetButton: some View {
        Button {
            viewModel.resetAll()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11))
                Text("重置全部")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(accentTint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(accentTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button {
            viewModel.close()
        } label: {
            Text("关闭")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(accentTint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Control Rows

    @ViewBuilder
    private func sliderRow(for key: SceneConfigOverrideKey) -> some View {
        if let row = viewModel.rows.first(where: { $0.key == key }) {
            let binding = Binding<Double>(
                get: {
                    if case .number(let n) = row.currentValue { return n }
                    return key.defaultValue
                },
                set: { viewModel.updateValue(key: key, value: .number($0)) }
            )
            let displayText: String = {
                let val = binding.wrappedValue
                switch key {
                case .cameraZoom: return String(format: "%.2f×", val)
                case .cameraFov: return String(format: "%.1f°", val)
                case .cameraNearz: return String(format: "%.3f", val)
                case .cameraFarz: return String(format: "%.0f", val)
                case .parallaxAmount: return String(format: "%.2f", val)
                case .parallaxDelay: return String(format: "%.2f", val)
                case .parallaxMouseInfluence: return String(format: "%.2f", val)
                case .orthoWidth: return String(format: "%.0f", val)
                case .orthoHeight: return String(format: "%.0f", val)
                case .textureReduction: return String(format: "%.0f×", val)
                default: return String(format: "%.2f", val)
                }
            }()
            sliderRowControl(
                label: row.key.displayName,
                value: binding,
                text: displayText,
                range: key.sliderRange,
                step: key == .cameraFarz ? 10 : 0.01
            )
        }
    }

    @ViewBuilder
    private func toggleRow(for key: SceneConfigOverrideKey) -> some View {
        if let row = viewModel.rows.first(where: { $0.key == key }) {
            let binding = Binding<Bool>(
                get: {
                    if case .bool(let b) = row.currentValue { return b }
                    // 兜底：用 scene.json 真实默认值，避免视差等回显错误
                    if case .bool(let b) = viewModel.sceneDefaults[key] ?? viewModel.defaultCodableValue(for: key) {
                        return b
                    }
                    return true
                },
                set: { viewModel.updateValue(key: key, value: .bool($0)) }
            )
            toggleRowControl(label: row.key.displayName, isOn: binding)
        }
    }

    @ViewBuilder
    private func colorRow(for key: SceneConfigOverrideKey, label: String) -> some View {
        if let row = viewModel.rows.first(where: { $0.key == key }) {
            let currentColor = Color(nsColor: .controlAccentColor)
            let colorBinding = Binding<Color>(
                get: {
                    if case .string(let s) = row.currentValue, !s.isEmpty {
                        return colorFromString(s)
                    }
                    return colorFromString("0.5 0.5 0.5")
                },
                set: { newColor in
                    let str = stringFromColor(newColor)
                    viewModel.updateValue(key: key, value: .string(str))
                }
            )
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .frame(width: labelWidth - 20, alignment: .leading)
                Spacer(minLength: 0)
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorBinding.wrappedValue)
                        .frame(width: 54, height: 24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(accentTint.opacity(0.4), lineWidth: 1)
                        )
                    ColorPicker("", selection: colorBinding, supportsOpacity: false)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 54, height: 24)
                        .opacity(0.02)
                }
            }
        }
    }

    // MARK: - Reusable Controls

    @ViewBuilder
    private func sliderRowControl(
        label: String,
        value: Binding<Double>,
        text: String,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .frame(width: labelWidth, alignment: .leading)
                Spacer(minLength: 0)
                Text(text)
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
    private func toggleRowControl(label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(label)
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

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(accentTint.opacity(0.5))
                .frame(width: 3, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
        }
        .padding(.top, 4)
    }

    // MARK: - Color Helpers

    private func colorFromString(_ raw: String) -> Color {
        let numbers = raw
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }
        guard numbers.count >= 3 else { return Color(nsColor: .controlAccentColor) }
        return Color(
            .sRGB,
            red: numbers[0],
            green: numbers[1],
            blue: numbers[2],
            opacity: numbers.count >= 4 ? numbers[3] : 1
        )
    }

    private func stringFromColor(_ color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "%.5f %.5f %.5f",
            nsColor.redComponent,
            nsColor.greenComponent,
            nsColor.blueComponent
        )
    }

    // MARK: - Glass Card Container

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
}

// MARK: - Glass Background Modifier

private extension View {
    func glassBackground() -> some View {
        self.background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                    .opacity(0.82)

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        )
    }
}
