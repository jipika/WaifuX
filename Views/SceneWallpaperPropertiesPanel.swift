import SwiftUI
import AppKit

/// 场景壁纸属性编辑面板（实时渲染模式下使用）
@MainActor
final class SceneWallpaperPropertiesPanelController {
    static let shared = SceneWallpaperPropertiesPanelController()

    private var windowController: NSWindowController?
    private var currentPath: String?

    private init() {}

    func present(for wallpaperPath: String) {
        if currentPath == wallpaperPath, let window = windowController?.window {
            anchorWindow(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = SceneWallpaperPropertiesViewModel(wallpaperPath: wallpaperPath) { [weak self] in
            self?.closePanel()
        }
        let window = KeyableBorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "设计场景"
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

        let rootView = SceneWallpaperPropertiesPanel(viewModel: viewModel)
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

        // 异步加载壁纸属性，避免 .pkg 解压等 I/O 阻塞主线程
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

// MARK: - ViewModel

@MainActor
final class SceneWallpaperPropertiesViewModel: ObservableObject {
    struct PropertyRow: Identifiable {
        let id: String
        let property: SceneWallpaperProperty
        var currentValue: AnyCodableValue

        var isModified: Bool {
            property.originalValue != currentValue
        }
    }

    @Published private(set) var wallpaperName: String
    @Published var rows: [PropertyRow] = []
    @Published private(set) var isLoading: Bool = true

    let wallpaperPath: String
    private let onClose: () -> Void
    private var applyTask: Task<Void, Never>?

    init(wallpaperPath: String, onClose: @escaping () -> Void) {
        self.wallpaperPath = wallpaperPath
        self.onClose = onClose
        self.wallpaperName = URL(fileURLWithPath: wallpaperPath).lastPathComponent
    }

    func loadAsync() async {
        await MainActor.run { isLoading = true }
        let name = await Task.detached(priority: .userInitiated) {
            SceneWallpaperDesignService.wallpaperTitle(for: self.wallpaperPath)
        }.value
        let properties = await SceneWallpaperPropertiesService.loadVisiblePropertiesAsync(for: wallpaperPath)
        await MainActor.run {
            wallpaperName = name
            rows = properties.map { prop in
                PropertyRow(id: prop.key, property: prop, currentValue: prop.currentValue)
            }
            isLoading = false
        }
    }

    func updateProperty(key: String, value: AnyCodableValue) {
        guard let index = rows.firstIndex(where: { $0.id == key }) else { return }
        rows[index].currentValue = value
        try? SceneWallpaperPropertiesService.setProperty(key: key, value: value, for: wallpaperPath)
        // 重新加载可见属性（条件可能变化）
        Task { await reloadVisibleAsync() }
        scheduleApply()
    }

    func resetProperty(key: String) {
        guard let index = rows.firstIndex(where: { $0.id == key }) else { return }
        rows[index].currentValue = rows[index].property.originalValue
        try? SceneWallpaperPropertiesService.resetProperty(key: key, for: wallpaperPath)
        Task { await reloadVisibleAsync() }
        scheduleApply()
    }

    func resetAll() {
        try? SceneWallpaperPropertiesService.resetAllProperties(for: wallpaperPath)
        Task { await loadAsync() }
        scheduleApply()
    }

    private func reloadVisibleAsync() async {
        let properties = await SceneWallpaperPropertiesService.loadVisiblePropertiesAsync(for: wallpaperPath)
        await MainActor.run {
            rows = properties.map { prop in
                PropertyRow(id: prop.key, property: prop, currentValue: prop.currentValue)
            }
        }
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let json = SceneWallpaperPropertiesService.propertiesOverrideJSON(for: wallpaperPath)
            do {
                try await WallpaperEngineXBridge.shared.refreshWallpaperProperties(userProperties: json)
            } catch {
                print("[SceneWallpaperPropertiesPanel] 重启渲染器失败: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        onClose()
    }
}

// MARK: - 属性 key 中文翻译映射

private let scenePropertyKeyTranslations: [String: String] = [
    // 布尔开关
    "bEnable": "启用",
    "bEnabled": "启用",
    "enable": "启用",
    "enabled": "启用",
    "bVisible": "可见",
    "visible": "可见",
    "bLoop": "循环",
    "loop": "循环",
    "bAnimated": "动画",
    "animated": "动画",
    "bBounce": "反弹",
    "bounce": "反弹",
    "bAutoPlay": "自动播放",
    "autoplay": "自动播放",
    "bShowFPS": "显示帧率",
    "bParallax": "视差效果",
    "parallax": "视差",
    "bMirror": "镜像",
    "mirror": "镜像",
    "bFlip": "翻转",
    "flip": "翻转",
    "bInvert": "反转",
    "invert": "反转",
    "bBlur": "模糊",
    "blur": "模糊",
    "bGlow": "发光",
    "glow": "发光",
    "bShadow": "阴影",
    "shadow": "阴影",
    "bBloom": "泛光",
    "bloom": "泛光",
    "bGrayscale": "灰度",
    "bSepia": "复古色调",
    "bNoise": "噪点",
    "noise": "噪点",
    "bDistortion": "扭曲",
    "bWave": "波浪",
    "wave": "波浪",
    "bRipple": "涟漪",
    "bRain": "下雨",
    "rain": "雨",
    "bSnow": "下雪",
    "snow": "雪",
    "bParticle": "粒子效果",
    "bFire": "火焰",
    "fire": "火",
    "bSmoke": "烟雾",
    "smoke": "烟雾",
    "bLightning": "闪电",
    "bStars": "星星",
    "stars": "星星",
    "bClouds": "云",
    "clouds": "云",
    "bWind": "风",
    "wind": "风",
    "bWater": "水",
    "water": "水",
    "bClock": "显示时钟",
    "clock": "时钟",
    "bShowClock": "显示时钟",
    "showclock": "显示时钟",
    "bShowTime": "显示时间",
    "bShowDate": "显示日期",
    "bShowMusic": "显示音乐",
    "showmusic": "显示音乐",
    "bMusic": "音乐可视化",
    "music": "音乐",
    "bAudioVisualizer": "音频可视化",
    "audio": "音频",
    "bShowAudio": "显示音频",
    "bMouse": "鼠标交互",
    "mouse": "鼠标",
    "bInteractive": "交互",
    "bDepth": "深度效果",
    "bScanlines": "扫描线",
    "bVignette": "暗角",
    "bChromatic": "色差",
    "bLensFlare": "镜头光晕",
    "bGodRays": "体积光",
    "bDOF": "景深",
    "bAutoRotation": "自动旋转",
    "bColorShift": "色相偏移",

    // 浮点数
    "fSpeed": "速度",
    "speed": "速度",
    "fScale": "缩放",
    "scale": "缩放",
    "fOpacity": "不透明度",
    "opacity": "不透明度",
    "fBrightness": "亮度",
    "brightness": "亮度",
    "fContrast": "对比度",
    "contrast": "对比度",
    "fSaturation": "饱和度",
    "saturation": "饱和度",
    "fHue": "色相",
    "hue": "色相",
    "fRotation": "旋转",
    "rotation": "旋转",
    "fAngle": "角度",
    "angle": "角度",
    "fSize": "大小",
    "size": "大小",
    "fWidth": "宽度",
    "width": "宽度",
    "fHeight": "高度",
    "height": "高度",
    "fX": "X 位置",
    "x": "X 位置",
    "fY": "Y 位置",
    "y": "Y 位置",
    "fPosX": "X 位置",
    "fPosY": "Y 位置",
    "fOffsetX": "X 偏移",
    "fOffsetY": "Y 偏移",
    "fAlpha": "透明度",
    "alpha": "透明度",
    "fVolume": "音量",
    "volume": "音量",
    "fFrequency": "频率",
    "frequency": "频率",
    "fAmplitude": "振幅",
    "amplitude": "振幅",
    "fDensity": "密度",
    "density": "密度",
    "fIntensity": "强度",
    "intensity": "强度",
    "fDuration": "持续时间",
    "duration": "持续时间",
    "fDelay": "延迟",
    "delay": "延迟",
    "fThickness": "厚度",
    "thickness": "厚度",
    "fRadius": "半径",
    "radius": "半径",
    "fBlur": "模糊强度",
    "fGlow": "发光强度",
    "fSpread": "扩散",
    "spread": "扩散",
    "fDecay": "衰减",
    "decay": "衰减",
    "fGravity": "重力",
    "gravity": "重力",
    "fTurbulence": "湍流",
    "turbulence": "湍流",
    "fDrag": "阻力",
    "drag": "阻力",
    "fLife": "生命",
    "life": "生命",
    "fRate": "速率",
    "rate": "速率",
    "fCount": "数量",
    "count": "数量",
    "iCount": "数量",
    "iMax": "最大值",
    "iMin": "最小值",
    "fZoom": "缩放",
    "zoom": "缩放",
    "fShake": "抖动",
    "fParallax": "视差深度",

    // 颜色
    "sColor": "颜色",
    "color": "颜色",
    "color1": "颜色 1",
    "color2": "颜色 2",
    "color3": "颜色 3",
    "schemecolor": "主题色",
    "backgroundcolor": "背景色",

    // 文本/字符串
    "sText": "文本",
    "text": "文本",
    "sFont": "字体",
    "font": "字体",
    "sImage": "图片",
    "image": "图片",
    "sTexture": "纹理",
    "texture": "纹理",
    "sBackground": "背景",
    "background": "背景",
    "sForeground": "前景",
    "foreground": "前景",
    "sOverlay": "叠加层",
    "overlay": "叠加",

    // 整数/枚举
    "nType": "类型",
    "type": "类型",
    "nMode": "模式",
    "mode": "模式",
    "nStyle": "样式",
    "style": "样式",
    "nQuality": "质量",
    "quality": "质量",
    "nResolution": "分辨率",
    "resolution": "分辨率",
    "effect": "效果",
    "direction": "方向",
    "shape": "形状",
    "blend": "混合模式",
    "material": "材质",
    "particle": "粒子",
    "particles": "粒子",

    // 时钟相关
    "hour": "时",
    "minute": "分",
    "second": "秒",
    "ampm": "上午/下午",
    "24h": "24小时制",
    "use24h": "24小时制",
    "showseconds": "显示秒",
    "delimiter": "分隔符",

    // 音乐相关
    "musictype": "音乐类型",
    "musicsize": "音乐大小",
    "musiccolor": "音乐颜色",
    "barcount": "频段数量",
    "barspacing": "频段间距",
]

private func translatedLabel(for property: SceneWallpaperProperty) -> String {
    if let text = property.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return text
    }
    let keyLower = property.key.lowercased()
    if let translated = scenePropertyKeyTranslations[keyLower] {
        return translated
    }
    if let translated = scenePropertyKeyTranslations[property.key] {
        return translated
    }
    return property.key
}

// MARK: - Panel View

struct SceneWallpaperPropertiesPanel: View {
    @ObservedObject var viewModel: SceneWallpaperPropertiesViewModel
    @ObservedObject private var localization = LocalizationService.shared
    private let accentTint = Color(nsColor: .controlAccentColor)
    private let labelWidth: CGFloat = 88

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 4)
            glassDivider

            if viewModel.isLoading {
                loadingState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.rows.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.rows) { row in
                            propertyRow(row)
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
            .fill(LinearGradient(
                colors: [accentTint.opacity(0.3), .white.opacity(0.06), accentTint.opacity(0.3)],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(height: 0.5)
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundStyle(accentTint)
                Text(t("design.noEditableSceneProps"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
            }
            Text(t("design.noScriptProperties"))
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private var resetButton: some View {
        Button {
            viewModel.resetAll()
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

    // MARK: - Property Row

    @ViewBuilder
    private func propertyRow(_ row: SceneWallpaperPropertiesViewModel.PropertyRow) -> some View {
        let label = translatedLabel(for: row.property)
        switch row.property.type {
        case "group":
            sectionHeader(row.property.text ?? row.property.key)
        case "description", "label":
            if let text = row.property.text, !text.isEmpty {
                descriptionRow(text)
            }
        case "slider":
            glassCard {
                sliderRow(
                    label,
                    value: sliderBinding(for: row),
                    text: sliderDisplayText(for: row),
                    range: (row.property.min ?? 0)...(row.property.max ?? 100),
                    step: row.property.step ?? 1
                )
            }
        case "bool":
            glassCard {
                toggleRow(label, isOn: boolBinding(for: row))
            }
        case "color":
            glassCard {
                colorRow(row, label: label)
            }
        case "combo":
            glassCard {
                fieldRow(label) {
                    Picker("", selection: comboBinding(for: row)) {
                        ForEach(Array((row.property.options ?? [:]).keys.sorted()), id: \.self) { key in
                            Text(row.property.options?[key] ?? key).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .tint(accentTint)
                    .accentColor(accentTint)
                }
            }
        case "textinput":
            glassCard {
                fieldRow(label) {
                    TextField("", text: textBinding(for: row))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .tint(accentTint)
                        .accentColor(accentTint)
                }
            }
        case "file":
            glassCard {
                fieldRow(label) {
                    HStack(spacing: 6) {
                        Text(row.currentValue.stringValue.isEmpty ? "未选择" : URL(fileURLWithPath: row.currentValue.stringValue).lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(LiquidGlassColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = row.property.type == "file" ? false : true
                            panel.canChooseFiles = true
                            if panel.runModal() == .OK, let url = panel.url {
                                viewModel.updateProperty(key: row.id, value: .string(url.path))
                            }
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(accentTint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        default:
            glassCard {
                fieldRow(label) {
                    TextField("", text: textBinding(for: row))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .tint(accentTint)
                        .accentColor(accentTint)
                }
            }
        }
    }

    // MARK: - Bindings

    private func sliderBinding(for row: SceneWallpaperPropertiesViewModel.PropertyRow) -> Binding<Double> {
        Binding<Double>(
            get: {
                switch row.currentValue {
                case .number(let n): return n
                case .string(let s): return Double(s) ?? (row.property.min ?? 0)
                default: return row.property.min ?? 0
                }
            },
            set: { viewModel.updateProperty(key: row.id, value: .number($0)) }
        )
    }

    private func sliderDisplayText(for row: SceneWallpaperPropertiesViewModel.PropertyRow) -> String {
        let value: Double
        switch row.currentValue {
        case .number(let n): value = n
        case .string(let s): value = Double(s) ?? 0
        default: value = 0
        }
        if abs(value.rounded() - value) < 0.0001 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.2f", value)
    }

    private func boolBinding(for row: SceneWallpaperPropertiesViewModel.PropertyRow) -> Binding<Bool> {
        Binding<Bool>(
            get: {
                switch row.currentValue {
                case .bool(let b): return b
                case .string(let s): return s == "true"
                case .number(let n): return n != 0
                default: return false
                }
            },
            set: { viewModel.updateProperty(key: row.id, value: .bool($0)) }
        )
    }

    private func textBinding(for row: SceneWallpaperPropertiesViewModel.PropertyRow) -> Binding<String> {
        Binding<String>(
            get: { row.currentValue.stringValue },
            set: { viewModel.updateProperty(key: row.id, value: .string($0)) }
        )
    }

    private func comboBinding(for row: SceneWallpaperPropertiesViewModel.PropertyRow) -> Binding<String> {
        Binding<String>(
            get: { row.currentValue.stringValue },
            set: { viewModel.updateProperty(key: row.id, value: .string($0)) }
        )
    }

    // MARK: - Shared UI Components

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
    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        text: String,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
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

    private func colorRow(_ row: SceneWallpaperPropertiesViewModel.PropertyRow, label: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textPrimary)
                .frame(width: labelWidth, alignment: .leading)
            Spacer(minLength: 0)
            let selection = Binding<Color>(
                get: { Self.color(from: row.currentValue.stringValue) },
                set: { viewModel.updateProperty(key: row.id, value: .string(Self.string(from: $0))) }
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

    @ViewBuilder
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

    @ViewBuilder
    private func descriptionRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(LiquidGlassColors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private static func color(from raw: String) -> Color {
        let numbers = raw
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }
        guard numbers.count >= 3 else { return .white }
        return Color(
            .sRGB,
            red: numbers[0],
            green: numbers[1],
            blue: numbers[2],
            opacity: numbers.count >= 4 ? numbers[3] : 1
        )
    }

    private static func string(from color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "%.5f %.5f %.5f",
            nsColor.redComponent,
            nsColor.greenComponent,
            nsColor.blueComponent
        )
    }
}

// MARK: - 玻璃背景修饰器
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
