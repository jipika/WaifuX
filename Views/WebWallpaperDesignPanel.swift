import SwiftUI
import AppKit

@MainActor
final class WebWallpaperDesignPanelController {
    static let shared = WebWallpaperDesignPanelController()

    private var windowController: NSWindowController?
    private var currentPath: String?

    private init() {}

    func present(for wallpaperPath: String) {
        if currentPath == wallpaperPath, let window = windowController?.window {
            anchorWindow(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = WebWallpaperDesignViewModel(wallpaperPath: wallpaperPath) { [weak self] in
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

        let rootView = WebWallpaperDesignPanel(viewModel: viewModel)
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

        // 异步加载壁纸数据，避免主线程阻塞
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

@MainActor
final class WebWallpaperDesignViewModel: ObservableObject {
    @Published private(set) var title: String
    @Published private(set) var wallpaperName: String
    @Published private(set) var properties: [WebWallpaperProperty] = []
    @Published var currentValues: [String: WebWallpaperPropertyValue] = [:]
    @Published private(set) var errorMessage: String?
    @Published private(set) var saveMessage: String?
    @Published private(set) var isLoading: Bool = true

    let wallpaperPath: String
    private let onClose: () -> Void

    private let service = WebWallpaperDesignService.shared
    private var applyTask: Task<Void, Never>?

    init(wallpaperPath: String, onClose: @escaping () -> Void) {
        self.wallpaperPath = wallpaperPath
        self.onClose = onClose
        self.title = URL(fileURLWithPath: wallpaperPath).lastPathComponent
        self.wallpaperName = URL(fileURLWithPath: wallpaperPath).lastPathComponent
    }

    var visibleProperties: [WebWallpaperProperty] {
        service.visibleProperties(properties, currentValues: currentValues)
    }

    var editablePropertyCount: Int {
        visibleProperties.filter(\.isEditable).count
    }

    func displayLabel(for property: WebWallpaperProperty) -> String {
        service.displayLabel(for: property)
    }

    func boolBinding(for property: WebWallpaperProperty) -> Binding<Bool> {
        Binding(
            get: { self.currentValues[property.key]?.asBool ?? property.defaultValue?.asBool ?? false },
            set: { self.update(.bool($0), for: property) }
        )
    }

    func textBinding(for property: WebWallpaperProperty) -> Binding<String> {
        Binding(
            get: { self.currentValues[property.key]?.stableString ?? property.defaultValue?.stableString ?? "" },
            set: { self.update(.string($0), for: property) }
        )
    }

    func sliderBinding(for property: WebWallpaperProperty) -> Binding<Double> {
        Binding(
            get: { self.currentValues[property.key]?.asDouble ?? property.defaultValue?.asDouble ?? property.minValue ?? 0 },
            set: { self.update(.number($0), for: property) }
        )
    }

    func comboSelection(for property: WebWallpaperProperty) -> Binding<String> {
        Binding(
            get: { self.currentValues[property.key]?.stableString ?? property.defaultValue?.stableString ?? property.options.first?.value.stableString ?? "" },
            set: { raw in
                let matched = property.options.first(where: { $0.value.stableString == raw })?.value ?? .string(raw)
                self.update(matched, for: property)
            }
        )
    }

    func colorBinding(for property: WebWallpaperProperty) -> Binding<Color> {
        Binding(
            get: {
                let raw = self.currentValues[property.key]?.stableString ?? property.defaultValue?.stableString ?? "1 1 1"
                return Self.color(from: raw)
            },
            set: { color in
                self.update(.string(Self.string(from: color)), for: property)
            }
        )
    }

    func fileValue(for property: WebWallpaperProperty) -> String {
        currentValues[property.key]?.stableString ?? property.defaultValue?.stableString ?? ""
    }

    func clearFile(for property: WebWallpaperProperty) {
        update(.string(""), for: property)
    }

    func selectFile(for property: WebWallpaperProperty) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        switch property.fileType?.lowercased() {
        case "video":
            panel.allowedContentTypes = [.audio, .mpeg4Movie, .movie]
        case "image":
            panel.allowedContentTypes = [.image]
        default:
            break
        }

        if panel.runModal() == .OK, let url = panel.url {
            update(.string(url.path), for: property)
        }
    }

    func selectDirectory(for property: WebWallpaperProperty) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            update(.string(url.path), for: property)
        }
    }

    func loadAsync() async {
        await MainActor.run { isLoading = true }
        let path = wallpaperPath
        do {
            let document = try await Task.detached(priority: .userInitiated) {
                try WebWallpaperDesignService.loadDocumentFromDisk(for: path)
            }.value
            await MainActor.run {
                properties = document.properties
                currentValues = document.currentValues
                title = URL(fileURLWithPath: path).lastPathComponent
                wallpaperName = document.wallpaperTitle
                errorMessage = nil
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func reload() {
        Task { await loadAsync() }
    }

    func resetToDefaults() {
        var resetValues: [String: WebWallpaperPropertyValue] = [:]
        for property in properties {
            if let defaultValue = property.defaultValue {
                resetValues[property.key] = defaultValue
            }
        }
        currentValues = resetValues
        saveMessage = t("design.resetDone")
        errorMessage = nil
        do {
            try service.saveOverrides(for: wallpaperPath, properties: properties, currentValues: currentValues)
        } catch {
            errorMessage = error.localizedDescription
        }
        applyCurrentValues()
    }

    func closePanel() {
        onClose()
    }

    private func update(_ value: WebWallpaperPropertyValue, for property: WebWallpaperProperty) {
        currentValues[property.key] = value
        saveMessage = t("design.saved")
        errorMessage = nil

        do {
            try service.saveOverrides(for: wallpaperPath, properties: properties, currentValues: currentValues)
        } catch {
            errorMessage = error.localizedDescription
        }

        applyCurrentValues()
    }

    private func applyCurrentValues() {
        applyTask?.cancel()
        let properties = self.properties
        let currentValues = self.currentValues
        applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            do {
                guard let json = try service.makeEffectivePropertiesJSON(properties: properties, currentValues: currentValues),
                      !json.isEmpty else { return }
                try await WallpaperEngineXBridge.shared.applyWebWallpaperProperties(json)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
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

struct WebWallpaperDesignPanel: View {
    @ObservedObject var viewModel: WebWallpaperDesignViewModel
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
            } else if let errorMessage = viewModel.errorMessage, viewModel.properties.isEmpty {
                errorState(errorMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let errorMessage = viewModel.errorMessage {
                            inlineMessage(errorMessage, tint: accentTint.opacity(0.15))
                        } else if let saveMessage = viewModel.saveMessage {
                            inlineMessage(saveMessage, tint: accentTint.opacity(0.1))
                        }

                        if viewModel.editablePropertyCount == 0 {
                            Text(t("design.noEditableProperties"))
                                .font(.system(size: 12))
                                .foregroundStyle(LiquidGlassColors.textSecondary)
                        }

                        ForEach(viewModel.visibleProperties) { property in
                            propertyRow(property)
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

    private var glassDivider: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [accentTint.opacity(0.3), .white.opacity(0.06), accentTint.opacity(0.3)],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(height: 0.5)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accentTint)
                .frame(width: 26, height: 26)
                .background(accentTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(t("design.designWallpaper"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)

                Text(viewModel.wallpaperName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

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

    @ViewBuilder
    private func propertyRow(_ property: WebWallpaperProperty) -> some View {
        switch property.type {
        case .group:
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentTint)
                    .frame(width: 3, height: 14)
                Text(viewModel.displayLabel(for: property))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentTint)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .padding(.top, 4)
            .padding(.bottom, 2)
        case .text, .label:
            Text(viewModel.displayLabel(for: property))
                .font(.system(size: 11))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bool, .checkbox:
            glassCard {
                toggleRow(viewModel.displayLabel(for: property), isOn: viewModel.boolBinding(for: property))
            }
        case .slider:
            glassCard {
                sliderRow(
                    viewModel.displayLabel(for: property),
                    value: viewModel.sliderBinding(for: property),
                    text: displaySliderValue(property),
                    range: (property.minValue ?? 0)...(property.maxValue ?? 100),
                    step: property.stepValue ?? (property.isFraction ? 0.01 : 1)
                )
            }
        case .combo:
            glassCard {
                fieldRow(viewModel.displayLabel(for: property)) {
                    Picker("", selection: viewModel.comboSelection(for: property)) {
                        ForEach(property.options) { option in
                            Text(option.label).tag(option.value.stableString)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .tint(accentTint)
                    .accentColor(accentTint)
                }
            }
        case .color:
            glassCard {
                HStack(spacing: 12) {
                    Text(viewModel.displayLabel(for: property))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .frame(width: labelWidth, alignment: .leading)
                    Spacer(minLength: 0)
                    let selection = viewModel.colorBinding(for: property)
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
                            .tint(accentTint)
                            .accentColor(accentTint)
                    }
                }
            }
        case .textinput:
            glassCard {
                fieldRow(viewModel.displayLabel(for: property)) {
                    TextField("", text: viewModel.textBinding(for: property))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .tint(accentTint)
                        .accentColor(accentTint)
                }
            }
        case .file, .scenetexture, .replacetexture:
            glassCard {
                fileRow(
                    viewModel.displayLabel(for: property),
                    fileName: fileDisplayText(property),
                    onChoose: { viewModel.selectFile(for: property) },
                    onClear: viewModel.fileValue(for: property).isEmpty ? nil : { viewModel.clearFile(for: property) }
                )
            }
        case .directory:
            glassCard {
                fileRow(
                    viewModel.displayLabel(for: property),
                    fileName: fileDisplayText(property),
                    onChoose: { viewModel.selectDirectory(for: property) },
                    onClear: viewModel.fileValue(for: property).isEmpty ? nil : { viewModel.clearFile(for: property) }
                )
            }
        case .unknown:
            EmptyView()
        }
    }

    /// 玻璃卡片容器 — 包裹每个属性行
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

    private func displaySliderValue(_ property: WebWallpaperProperty) -> String {
        let value = viewModel.currentValues[property.key]?.asDouble ?? property.defaultValue?.asDouble ?? 0
        let precision = property.precision ?? (property.isFraction ? 2 : 0)
        return String(format: "%.\(precision)f", value)
    }

    private func inlineMessage(_ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(accentTint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accentTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func fileDisplayText(_ property: WebWallpaperProperty) -> String {
        let value = viewModel.fileValue(for: property)
        guard !value.isEmpty else { return t("design.noFileSelected") }
        return URL(fileURLWithPath: value).lastPathComponent
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
    private func fileRow(
        _ title: String,
        fileName: String,
        onChoose: @escaping () -> Void,
        onClear: (() -> Void)?
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textPrimary)
                .frame(width: labelWidth, alignment: .leading)

            HStack(spacing: 6) {
                Text(fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(fileName == t("design.noFileSelected") ? LiquidGlassColors.textQuaternary : LiquidGlassColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                glassCapsuleButton(t("design.select"), action: onChoose)

                if let onClear {
                    glassCapsuleButton(t("design.clear"), action: onClear)
                }
            }
        }
    }

    private func glassCapsuleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentTint)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(accentTint.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(accentTint)
                Text(t("design.cannotOpenPanel"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
            }
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
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
