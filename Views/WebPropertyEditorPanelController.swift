import SwiftUI
import AppKit
import WebKit

// MARK: - Web Property Editor Panel Controller
// 统一的 WKWebView 属性编辑器，支持三种类型：
// 1. 场景壁纸属性 (scene) → SceneWallpaperPropertiesService
// 2. Web 壁纸属性 (web) → WebWallpaperDesignService
// 3. 场景高级设置 (sceneConfig) → SceneConfigOverrideService

@MainActor
final class WebPropertyEditorPanelController {
    static let shared = WebPropertyEditorPanelController()

    private var windowController: NSWindowController?
    private var webView: WKWebView?
    private var currentPath: String?
    private var currentType: WallpaperEditorType = .scene
    private var currentTitle: String = "设计场景"
    private var applyTask: Task<Void, Never>?
    private var pendingInject: String?
    private var navigationDelegate: PropertyEditorNavigationDelegate?
    private var pageIsReady = false
    private var activeLoadID = UUID()

    private init() {}

    // MARK: - Public API

    /// 场景壁纸设计弹窗
    func presentScene(for wallpaperPath: String) {
        present(for: wallpaperPath, type: .scene, title: "设计场景")
    }

    /// Web 壁纸设计弹窗
    func presentWeb(for wallpaperPath: String) {
        present(for: wallpaperPath, type: .web, title: "设计壁纸")
    }

    /// 场景高级设置弹窗（SceneConfigOverride）
    func presentSceneConfig(for wallpaperPath: String) {
        present(for: wallpaperPath, type: .sceneConfig, title: "场景高级设置")
    }

    /// 桌面动态元素设计弹窗（烘焙视频的文本覆盖编辑）
    func presentSceneDesign(for wallpaperPath: String) {
        present(for: wallpaperPath, type: .sceneDesign, title: "设计壁纸")
    }

    /// 自动检测类型并呈现（兼容旧调用方式）
    func present(for wallpaperPath: String, title: String = "设计场景") {
        let type = detectType(for: wallpaperPath)
        let autoTitle = type == .scene ? "设计场景" : "设计壁纸"
        present(for: wallpaperPath, type: type, title: title == "设计场景" ? autoTitle : title)
    }

    func closePanel() {
        activeLoadID = UUID()
        pendingInject = nil
        pageIsReady = false
        webView?.navigationDelegate = nil
        navigationDelegate = nil
        webView = nil
        windowController?.close()
        windowController = nil
        currentPath = nil
    }

    // MARK: - Internal Present

    private func present(for wallpaperPath: String, type: WallpaperEditorType, title: String) {
        if currentPath == wallpaperPath, let window = windowController?.window {
            anchorWindow(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        closePanel()

        let window = KeyableBorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 620),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.hasShadow = true
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 380, height: 620))
        window.minSize = NSSize(width: 360, height: 500)
        window.maxSize = NSSize(width: 500, height: 800)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.level = .floating

        // WKWebView configuration
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        let handler = ScriptMessageHandlerProxy(target: self)
        userContentController.add(handler, name: "propertyChanged")
        userContentController.add(handler, name: "closePanel")
        userContentController.add(handler, name: "resetAll")
        userContentController.add(handler, name: "selectFile")
        userContentController.add(handler, name: "editorReady")
        userContentController.add(handler, name: "sceneDesignChanged")
        userContentController.add(handler, name: "selectLanguage")

        config.userContentController = userContentController

        let webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        let navigationDelegate = PropertyEditorNavigationDelegate(target: self)
        webView.navigationDelegate = navigationDelegate

        window.contentView = webView
        // Round corners to match the existing panel style
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 20
        window.contentView?.layer?.masksToBounds = true

        anchorWindow(window)

        let controller = NSWindowController(window: window)
        windowController = controller
        currentPath = wallpaperPath
        currentType = type
        currentTitle = title
        self.webView = webView
        self.navigationDelegate = navigationDelegate
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        Task { await loadAndInjectData() }
    }

    // MARK: - Data Loading

    private func loadAndInjectData() async {
        guard let webView = webView, let wallpaperPath = currentPath else { return }
        let loadID = UUID()
        activeLoadID = loadID
        pageIsReady = false
        pendingInject = nil

        let htmlContent = loadHTMLEditorContent()

        // Scene design uses a completely different data model (dynamic text entries)
        if currentType == .sceneDesign {
            let designData = Self.loadSceneDesignData(for: wallpaperPath)
            let designJSON = try? JSONSerialization.data(withJSONObject: designData, options: [])
            let designJS = String(data: designJSON ?? Data(), encoding: .utf8) ?? "{}"

            let escapedTitle = currentTitle.jsEscaped
            let escapedWallpaperTitle = (designData["wallpaperTitle"] as? String ?? "").jsEscaped
            let accentHex = NSColor.controlAccentColor.hexString

            let injectScript = """
            window.sceneDesignData = \(designJS);
            window.wallpaperTitle = "\(escapedWallpaperTitle)";
            window.accentColor = "\(accentHex)";
            document.getElementById('panelTitle').textContent = "\(escapedTitle)";
            if (typeof initSceneDesign === 'function') initSceneDesign();
            """

            pendingInject = injectScript
            webView.loadHTMLString(htmlContent, baseURL: nil)

            // Safety timeout if the navigation callback is not delivered.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, activeLoadID == loadID, self.webView === webView else { return }
            injectPendingDataIfPossible(force: true)
            return
        }

        // Load property data for scene / web / sceneConfig
        let result: PropertyLoadResult
        do {
            let type = currentType
            let path = wallpaperPath
            if type == .sceneConfig {
                result = try Self.loadSceneConfigData(for: path)
            } else {
                result = try Self.loadPropertyData(for: path, type: type)
            }
        } catch {
            print("[WebPropertyEditor] Failed to load properties: \(error)")
            return
        }

        // Build injection script (will be executed when HTML signals DOM ready)
        let propertiesJSON = try? JSONSerialization.data(
            withJSONObject: result.properties.map { $0.toDict() },
            options: []
        )
        let propertiesJS = String(data: propertiesJSON ?? Data(), encoding: .utf8) ?? "[]"

        let valuesJSON = try? JSONSerialization.data(withJSONObject: result.currentValues, options: [])
        let valuesJS = String(data: valuesJSON ?? Data(), encoding: .utf8) ?? "{}"

        let escapedTitle = currentTitle.jsEscaped
        let escapedWallpaperTitle = result.wallpaperTitle.jsEscaped
        let accentHex = NSColor.controlAccentColor.hexString

        let injectScript = """
        window.wallpaperProperties = \(propertiesJS);
        window.currentValues = \(valuesJS);
        window.wallpaperTitle = "\(escapedWallpaperTitle)";
        window.accentColor = "\(accentHex)";
        document.getElementById('panelTitle').textContent = "\(escapedTitle)";
        if (typeof initFromData === 'function') initFromData();
        """

        pendingInject = injectScript

        // Load HTML — the page will post "editorReady" when DOM is ready
        webView.loadHTMLString(htmlContent, baseURL: nil)

        // Safety timeout if the navigation callback is not delivered.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard !Task.isCancelled, activeLoadID == loadID, self.webView === webView else { return }
        injectPendingDataIfPossible(force: true)
    }

    /// Called when HTML page signals DOM is ready
    func handleEditorReady() {
        injectPendingDataIfPossible()
    }

    func handlePageFinishedLoading(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        pageIsReady = true
        injectPendingDataIfPossible()
    }

    private func injectPendingDataIfPossible(force: Bool = false) {
        guard (pageIsReady || force), let webView = webView, let script = pendingInject else { return }
        pendingInject = nil
        webView.evaluateJavaScript(script) { _, error in
            if let error = error {
                print("[WebPropertyEditor] JS inject failed: \(error.localizedDescription)")
            }
        }
    }

    private func loadHTMLEditorContent() -> String {
        // Try standard bundle path first (Contents/Resources/)
        if let url = Bundle.main.url(forResource: "WallpaperPropertyEditor", withExtension: "html"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        // Resources is a folder reference → nested at Contents/Resources/Resources/
        if let resourceURL = Bundle.main.resourceURL {
            let nested = resourceURL
                .appendingPathComponent("Resources")
                .appendingPathComponent("WallpaperPropertyEditor.html")
            if let content = try? String(contentsOf: nested, encoding: .utf8) {
                return content
            }
        }
        return Self.fallbackHTML
    }

    // MARK: - Message Handlers

    func handlePropertyChanged(key: String, value: Any) {
        guard let path = currentPath else { return }

        switch currentType {
        case .scene:
            let codableValue = Self.toAnyCodableValue(value)
            try? SceneWallpaperPropertiesService.setProperty(key: key, value: codableValue, for: path)
        case .web:
            let webValue = Self.toWebPropertyValue(value)
            handleWebPropertyChange(path: path, key: key, value: webValue)
        case .sceneConfig:
            guard let overrideKey = SceneConfigOverrideKey(rawValue: key) else { return }
            let codableValue = Self.toAnyCodableValue(value)
            SceneConfigOverrideService.setOverride(key: overrideKey, value: codableValue, for: path)
        case .sceneDesign:
            break // sceneDesign uses sceneDesignChanged handler instead
        }

        scheduleApply()
    }

    func handleResetAll() {
        guard let path = currentPath else { return }

        switch currentType {
        case .scene:
            try? SceneWallpaperPropertiesService.resetAllProperties(for: path)
        case .web:
            handleWebReset(path: path)
        case .sceneConfig:
            SceneConfigOverrideService.resetAllOverrides(for: path)
        case .sceneDesign:
            SceneWallpaperDesignService.resetDocument(for: path)
            LiquidGlassClockOverlayManager.shared.rebuildAll()
        }

        Task { await loadAndInjectData() }
        scheduleApply()
    }

    func handleSelectFile(key: String, isDirectory: Bool) {
        // Scene config and scene design don't use file selection
        guard currentType != .sceneConfig, currentType != .sceneDesign else { return }
        guard let path = currentPath else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = !isDirectory
        panel.canChooseDirectories = isDirectory
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            switch currentType {
            case .scene:
                let codableValue: AnyCodableValue = .string(url.path)
                try? SceneWallpaperPropertiesService.setProperty(key: key, value: codableValue, for: path)
            case .web:
                let webValue: WebWallpaperPropertyValue = .string(url.path)
                handleWebPropertyChange(path: path, key: key, value: webValue)
            case .sceneConfig:
                break
            case .sceneDesign:
                break
            }
            scheduleApply()
        }
    }

    func handleClosePanel() {
        closePanel()
    }

    // MARK: - Web Wallpaper Specific Handlers

    private func handleWebPropertyChange(path: String, key: String, value: WebWallpaperPropertyValue) {
        // Load current document, update value, save
        guard let doc = try? WebWallpaperDesignService.loadDocumentFromDisk(for: path) else { return }
        var values = doc.currentValues
        values[key] = value
        try? WebWallpaperDesignService.shared.saveOverrides(
            for: path,
            properties: doc.properties,
            currentValues: values
        )
    }

    private func handleWebReset(path: String) {
        // Use service to reset: saveOverrides with empty values removes design.json
        guard let doc = try? WebWallpaperDesignService.loadDocumentFromDisk(for: path) else { return }
        try? WebWallpaperDesignService.shared.saveOverrides(
            for: path,
            properties: doc.properties,
            currentValues: [:]
        )
    }

    // MARK: - Apply to Renderer

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard let path = currentPath else { return }

            do {
                switch currentType {
                case .scene:
                    let json = SceneWallpaperPropertiesService.propertiesOverrideJSON(for: path)
                    try await WallpaperEngineXBridge.shared.refreshWallpaperProperties(userProperties: json)

                case .web:
                    let doc = try WebWallpaperDesignService.loadDocumentFromDisk(for: path)
                    if let json = try WebWallpaperDesignService.shared.makeEffectivePropertiesJSON(
                        properties: doc.properties,
                        currentValues: doc.currentValues
                    ), !json.isEmpty {
                        try await WallpaperEngineXBridge.shared.applyWebWallpaperProperties(json)
                    }

                case .sceneConfig:
                    let baseJSON = SceneWallpaperPropertiesService.propertiesOverrideJSON(for: path)
                    let mergedJSON = SceneConfigOverrideService.mergedPropertiesJSON(
                        userPropertiesJSON: baseJSON,
                        for: path
                    )
                    try await WallpaperEngineXBridge.shared.refreshWallpaperProperties(userProperties: mergedJSON)

                case .sceneDesign:
                    // Scene design changes are applied via LiquidGlassClockOverlayManager.rebuildAll()
                    // directly in handleSceneDesignChanged, no bridge call needed
                    break
                }
            } catch {
                print("[WebPropertyEditor] Apply failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Type Detection

    private func detectType(for wallpaperPath: String) -> WallpaperEditorType {
        let contentDir = Self.resolveContentDir(for: wallpaperPath)
        let projectURL = contentDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return .scene
        }
        return type.lowercased() == "web" ? .web : .scene
    }

    // MARK: - Anchor

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

    // MARK: - Value Conversion Helpers

    private static func toAnyCodableValue(_ value: Any) -> AnyCodableValue {
        // NSNumber(0) 来自 JavaScript 可以转成 Bool(false) 或 Double(0.0)，
        // 先判数字类型避免 0/1 被错误转成 bool
        if let n = value as? Double { return .number(n) }
        if let n = value as? Int { return .number(Double(n)) }
        if let b = value as? Bool { return .bool(b) }
        if let s = value as? String { return .string(s) }
        return .string(String(describing: value))
    }

    private static func toWebPropertyValue(_ value: Any) -> WebWallpaperPropertyValue {
        if let b = value as? Bool { return .bool(b) }
        if let n = value as? Double { return .number(n) }
        if let n = value as? Int { return .number(Double(n)) }
        if let s = value as? String { return .string(s) }
        return .string(String(describing: value))
    }

    // MARK: - Property Data Loading (background thread)

    private struct PropertyLoadResult {
        let properties: [PropertyEditorItem]
        let currentValues: [String: Any]
        let wallpaperTitle: String
    }

    private static func loadPropertyData(for wallpaperPath: String, type: WallpaperEditorType) throws -> PropertyLoadResult {
        let contentDir = resolveContentDir(for: wallpaperPath)
        let projectURL = contentDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "WebPropertyEditor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to read project.json"])
        }

        let wallpaperTitle = (json["title"] as? String) ?? URL(fileURLWithPath: wallpaperPath).lastPathComponent

        guard let general = json["general"] as? [String: Any],
              let rawProperties = general["properties"] as? [String: [String: Any]] else {
            return PropertyLoadResult(properties: [], currentValues: [:], wallpaperTitle: wallpaperTitle)
        }

        // Load overrides based on type
        var overrideValues: [String: Any] = [:]

        switch type {
        case .scene:
            let doc = SceneWallpaperPropertiesService.loadDocument(for: wallpaperPath)
            overrideValues = doc.overrides.mapValues { $0.foundationValue }

        case .web:
            // Load web overrides via service (handles path hashing + decoding)
            if let doc = try? WebWallpaperDesignService.loadDocumentFromDisk(for: wallpaperPath) {
                overrideValues = doc.overrideValues.mapValues { $0.foundationValue }
            }

        case .sceneConfig:
            // Should not reach here; sceneConfig uses loadSceneConfigData() instead
            throw NSError(domain: "WebPropertyEditor", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "sceneConfig uses loadSceneConfigData"])

        case .sceneDesign:
            // Should not reach here; sceneDesign uses loadSceneDesignData() instead
            throw NSError(domain: "WebPropertyEditor", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "sceneDesign uses loadSceneDesignData"])
        }

        var items: [PropertyEditorItem] = []
        var currentValues: [String: Any] = [:]

        for (key, prop) in rawProperties {
            let rawType = prop["type"] as? String ?? "text"
            let text = prop["text"] as? String
            let options = parseOptions(prop["options"])
            let min = prop["min"] as? Double
            let max = prop["max"] as? Double
            let step = prop["step"] as? Double
            let order = prop["order"] as? Int
            let condition = prop["condition"] as? String
            let fraction = prop["fraction"] as? Bool ?? false
            let precision = prop["precision"] as? Int

            let defaultValue = prop["value"]
            currentValues[key] = overrideValues[key] ?? defaultValue

            let normalizedType = normalizeType(rawType)

            let item = PropertyEditorItem(
                key: key,
                type: normalizedType,
                text: text.map { WallpaperEnginePropertyLocalizer.label(for: $0) },
                defaultValue: defaultValue,
                options: options,
                min: min,
                max: max,
                step: step,
                order: order,
                condition: condition,
                fraction: fraction,
                precision: precision
            )
            items.append(item)
        }

        return PropertyLoadResult(
            properties: items.sorted { ($0.order ?? 9999) < ($1.order ?? 9999) },
            currentValues: currentValues,
            wallpaperTitle: wallpaperTitle
        )
    }

    // MARK: - Scene Config Data Loading

    /// 从 SceneConfigOverrideKey 构建固定的属性列表（不读 project.json）
    private static func loadSceneConfigData(for wallpaperPath: String) throws -> PropertyLoadResult {
        let overrides = SceneConfigOverrideService.loadOverrides(for: wallpaperPath)
        let wallpaperTitle = SceneWallpaperDesignService.wallpaperTitle(for: wallpaperPath)

        var items: [PropertyEditorItem] = []
        var currentValues: [String: Any] = [:]
        var order = 0

        // Section helper: insert a group header
        func addSection(_ title: String, keys: [SceneConfigOverrideKey]) {
            items.append(PropertyEditorItem(
                key: "__group_\(title)",
                type: "group",
                text: "<span style=\"font-weight:600\">\(title)</span>",
                defaultValue: nil,
                options: [], min: nil, max: nil, step: nil,
                order: order, condition: nil, fraction: false, precision: nil
            ))
            order += 1

            for key in keys {
                let defaultVal: Any
                if key.isBool {
                    defaultVal = false
                } else if key.isColor {
                    defaultVal = ""
                } else {
                    defaultVal = key.defaultValue
                }

                let propType: String
                if key.isBool {
                    propType = "bool"
                } else if key.isColor {
                    propType = "color"
                } else {
                    propType = "slider"
                }

                let overrideValue = overrides[key]
                let currentValue: Any
                if let ov = overrideValue {
                    switch ov {
                    case .bool(let b): currentValue = b
                    case .number(let n): currentValue = n
                    case .string(let s): currentValue = s
                    case .null: currentValue = defaultVal
                    }
                } else {
                    currentValue = defaultVal
                }

                let fraction = !key.isBool && !key.isColor && key.sliderRange.upperBound <= 10.0
                let precision: Int?
                if key.isBool || key.isColor {
                    precision = nil
                } else {
                    let step: Double = (key == .cameraFarz) ? 10.0 : 0.01
                    if step <= 0.001 { precision = 3 }
                    else if step <= 0.01 { precision = 2 }
                    else if step <= 0.1 { precision = 1 }
                    else { precision = 0 }
                }

                items.append(PropertyEditorItem(
                    key: key.rawValue,
                    type: propType,
                    text: key.displayName,
                    defaultValue: defaultVal,
                    options: [],
                    min: key.isBool || key.isColor ? nil : key.sliderRange.lowerBound,
                    max: key.isBool || key.isColor ? nil : key.sliderRange.upperBound,
                    step: key.isBool || key.isColor ? nil : (key == .cameraFarz ? 10.0 : 0.01),
                    order: order,
                    condition: nil,
                    fraction: fraction,
                    precision: precision
                ))
                currentValues[key.rawValue] = currentValue
                order += 1
            }
        }

        addSection("📷 相机", keys: [.cameraZoom, .cameraFov, .cameraNearz, .cameraFarz])
        addSection("🎯 视差", keys: [.parallaxEnabled, .parallaxAmount, .parallaxDelay, .parallaxMouseInfluence])
        addSection("🖥 显示", keys: [.orthoWidth, .orthoHeight, .textureReduction])
        addSection("🎨 颜色", keys: [.clearColor, .ambientColor, .skylightColor])
        addSection("⚙️ 其他", keys: [.clearEnabled, .cameraFade])

        return PropertyLoadResult(
            properties: items,
            currentValues: currentValues,
            wallpaperTitle: wallpaperTitle
        )
    }

    // MARK: - Scene Design Data Loading

    /// 加载桌面动态元素设计数据（sidecar + 覆盖项），返回可序列化的字典
    private static func loadSceneDesignData(for wallpaperPath: String) -> [String: Any] {
        let wallpaperTitle = SceneWallpaperDesignService.wallpaperTitle(for: wallpaperPath)
        let document = SceneWallpaperDesignService.loadDocument(for: wallpaperPath)

        // 获取 sidecar 动态文本信息（需主线程访问 VideoWallpaperManager）
        let sidecar: WallpaperDynamicTextsInfo? = VideoWallpaperManager.shared.currentVideoURL.flatMap { videoURL in
            guard let info = WallpaperDynamicTextParser.loadSidecar(for: videoURL),
                  let sidecarPath = info.wallpaperPath, !sidecarPath.isEmpty else { return nil }
            let standardizedSidecar = URL(fileURLWithPath: sidecarPath).standardizedFileURL.path
            let standardizedTarget = URL(fileURLWithPath: wallpaperPath).standardizedFileURL.path
            return standardizedSidecar == standardizedTarget ? info : nil
        }

        guard let sidecar = sidecar, sidecar.hasDynamicText else {
            return ["wallpaperTitle": wallpaperTitle, "groups": []]
        }

        let designed = SceneWallpaperDesignService.resolveDesignedInfo(from: sidecar, wallpaperPath: wallpaperPath)

        // 按位置分组（与 SceneWallpaperDesignViewModel.groupByPosition 相同算法）
        struct SimpleRow {
            let id: String
            let key: String
            let name: String
            let value: String
            let source: DynamicTextEntry
            let override: SceneDynamicTextDesignOverride
        }

        let rows: [SimpleRow] = designed.entries.map { entry in
            SimpleRow(
                id: entry.id,
                key: entry.id,
                name: entry.source.name,
                value: entry.source.resolvedText ?? entry.source.value ?? "",
                source: entry.source,
                override: document.overrides[entry.id] ?? SceneDynamicTextDesignOverride()
            )
        }

        // 按位置分组（5 scene units 以内视为同一位置的多语言版本）
        var groups: [[String: Any]] = []
        var used = Set<String>()
        let rowsByParent = Dictionary(grouping: rows) { $0.source.parentID }

        for row in rows {
            guard !used.contains(row.id) else { continue }
            if row.source.parentID != nil { continue }

            let ex = row.source.finalOriginX ?? row.source.originX ?? row.source.finalX ?? row.source.x ?? 0
            let ey = row.source.finalOriginY ?? row.source.originY ?? row.source.finalY ?? row.source.y ?? 0

            let siblings = rows.filter { other in
                guard !used.contains(other.id) else { return false }
                guard other.source.parentID == nil else { return false }
                let ox = other.source.finalOriginX ?? other.source.originX ?? other.source.finalX ?? other.source.x ?? 0
                let oy = other.source.finalOriginY ?? other.source.originY ?? other.source.finalY ?? other.source.y ?? 0
                return abs(ox - ex) < 5 && abs(oy - ey) < 5
            }

            let groupName = siblings.first(where: { !$0.name.isEmpty })?.name ?? "未命名"

            // 确定选中语言索引
            let selectedIndex: Int
            if let explicitVisible = siblings.firstIndex(where: { $0.override.hidden == false }) {
                selectedIndex = explicitVisible
            } else if let sourceVisible = siblings.firstIndex(where: { $0.source.visible }) {
                selectedIndex = sourceVisible
            } else {
                selectedIndex = siblings.enumerated().max(by: {
                    ($0.element.source.renderOrder ?? 0) < ($1.element.source.renderOrder ?? 0)
                })?.offset ?? 0
            }

            // 语言标签
            let languageLabels: [String] = siblings.enumerated().map { idx, sib in
                let trimmedName = sib.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let pattern = #"\(([A-Za-z]{2,8})\)"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.matches(in: trimmedName, range: NSRange(trimmedName.startIndex..., in: trimmedName)).last,
                   match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: trimmedName) {
                    return String(trimmedName[range]).uppercased()
                }
                return trimmedName.isEmpty ? "语言 \(idx + 1)" : trimmedName
            }

            // 构建每个条目的 JSON 数据
            let entriesData: [[String: Any]] = siblings.map { sib in
                let ov = sib.override
                let src = sib.source
                var entry: [String: Any] = [
                    "id": sib.id,
                    "name": sib.name,
                    "value": sib.value,
                    "behavior": src.behavior,
                    "hidden": ov.hidden ?? !src.visible,
                    "textOverride": ov.textOverride ?? "",
                    "alpha": ov.alpha ?? src.alpha ?? 1.0,
                    "offsetX": ov.offsetX ?? 0,
                    "offsetY": ov.offsetY ?? 0,
                    "scaleMultiplier": ov.scaleMultiplier ?? 1,
                    "fontSizeMultiplier": ov.fontSizeMultiplier ?? 1,
                    "rotation": ov.rotationOverride ?? src.finalAngle ?? src.rotation ?? 0,
                    "maxWidth": ov.maxWidthOverride ?? src.maxWidth ?? 500,
                    "fontName": ov.fontFamilyOverride ?? src.fontFamily ?? "",
                    "fontPath": ov.fontPathOverride ?? src.fontPath ?? "",
                    "alignment": ov.alignmentOverride ?? src.alignment ?? "center center",
                ]
                // 颜色: [r, g, b] → hex string
                let colorArr = ov.color ?? src.color ?? [1.0, 1.0, 1.0]
                if colorArr.count >= 3 {
                    let r = Int(round(colorArr[0] * 255))
                    let g = Int(round(colorArr[1] * 255))
                    let b = Int(round(colorArr[2] * 255))
                    entry["color"] = String(format: "#%02x%02x%02x", r, g, b)
                } else {
                    entry["color"] = "#ffffff"
                }
                // 时钟特有选项
                if src.behavior == "clock" {
                    entry["use24hFormat"] = ov.use24hFormat ?? true
                    entry["showSeconds"] = ov.showSeconds ?? false
                    entry["delimiter"] = ov.delimiter ?? ""
                }
                return entry
            }

            // 收集该组所有 key（包括子条目）
            let languageEntryKeys: [[String]] = siblings.map { sib in
                var keys = [sib.key]
                if let parentID = sib.source.id {
                    keys += rowsByParent[parentID]?.map(\.key) ?? []
                }
                return Array(Set(keys))
            }

            let group: [String: Any] = [
                "id": siblings.first?.id ?? row.id,
                "displayName": groupName,
                "entries": entriesData,
                "selectedLanguageIndex": selectedIndex,
                "languageLabels": languageLabels,
                "languageEntryKeys": languageEntryKeys,
            ]
            groups.append(group)

            for s in siblings {
                used.insert(s.id)
                if let parentID = s.source.id {
                    for child in rowsByParent[parentID] ?? [] {
                        used.insert(child.id)
                    }
                }
            }
        }

        return [
            "wallpaperTitle": wallpaperTitle,
            "groups": groups,
        ]
    }

    // MARK: - Scene Design Message Handlers

    /// 处理场景设计属性变更（来自 JS）
    func handleSceneDesignChanged(entryKey: String, field: String, value: Any) {
        guard let path = currentPath else { return }
        var document = SceneWallpaperDesignService.loadDocument(for: path)
        document.wallpaperPath = path
        var override = document.overrides[entryKey] ?? SceneDynamicTextDesignOverride()

        switch field {
        case "hidden":
            if let b = value as? Bool { override.hidden = b }
        case "textOverride":
            let s = String(describing: value)
            override.textOverride = s.isEmpty ? nil : s
        case "alpha":
            if let n = Self.toDouble(value) { override.alpha = n }
        case "offsetX":
            if let n = Self.toDouble(value) { override.offsetX = n }
        case "offsetY":
            if let n = Self.toDouble(value) { override.offsetY = n }
        case "scaleMultiplier":
            if let n = Self.toDouble(value) { override.scaleMultiplier = n }
        case "fontSizeMultiplier":
            if let n = Self.toDouble(value) { override.fontSizeMultiplier = n }
        case "rotation":
            if let n = Self.toDouble(value) { override.rotationOverride = n }
        case "maxWidth":
            if let n = Self.toDouble(value) { override.maxWidthOverride = n }
        case "fontName":
            let s = String(describing: value)
            override.fontFamilyOverride = s.isEmpty ? nil : s
        case "fontPath":
            let s = String(describing: value)
            override.fontPathOverride = s.isEmpty ? nil : s
        case "alignment":
            let s = String(describing: value)
            override.alignmentOverride = s.isEmpty ? nil : s
        case "color":
            // hex string → [r, g, b] normalized
            if let hex = value as? String {
                override.color = Self.hexToNormalizedRGB(hex)
            }
        case "use24hFormat":
            if let b = value as? Bool { override.use24hFormat = b }
        case "showSeconds":
            if let b = value as? Bool { override.showSeconds = b }
        case "delimiter":
            let s = String(describing: value)
            override.delimiter = s.isEmpty ? nil : s
        default:
            break
        }

        document.overrides[entryKey] = override
        try? SceneWallpaperDesignService.saveDocument(document, for: path)
        scheduleSceneDesignRebuild()
    }

    /// 处理语言切换
    func handleSelectLanguage(groupID: String, index: Int, allEntryKeys: [[String]]) {
        guard let path = currentPath else { return }
        var document = SceneWallpaperDesignService.loadDocument(for: path)
        document.wallpaperPath = path

        // allEntryKeys: 每个语言的 key 数组（包含子条目 key）
        // 需要将该组所有条目的 hidden 设为 true，除了选中语言的条目
        // 但这里我们只知道组级别的 key，需要遍历所有可能的 override key
        // 实际上，我们从 JS 端传入该组所有条目的 id 列表
        // 为简化，JS 端传入 groupAllKeys（该组所有条目的 key 列表）和 selectedKeys
        // 但当前消息只传了 groupID, index, allEntryKeys
        // allEntryKeys[index] 就是选中语言的 key 集合
        let selectedKeys = Set(index < allEntryKeys.count ? allEntryKeys[index] : [])
        let allKeys = Set(allEntryKeys.flatMap { $0 })

        for key in allKeys {
            var ov = document.overrides[key] ?? SceneDynamicTextDesignOverride()
            ov.hidden = !selectedKeys.contains(key)
            document.overrides[key] = ov
        }

        try? SceneWallpaperDesignService.saveDocument(document, for: path)
        LiquidGlassClockOverlayManager.shared.rebuildAll()
    }

    private var rebuildTask: Task<Void, Never>?

    private func scheduleSceneDesignRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            LiquidGlassClockOverlayManager.shared.rebuildAll()
        }
    }

    private static func toDouble(_ value: Any) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func hexToNormalizedRGB(_ hex: String) -> [Double] {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        guard hexSanitized.count == 6,
              let r = UInt32(hexSanitized.prefix(2), radix: 16),
              let g = UInt32(hexSanitized.dropFirst(2).prefix(2), radix: 16),
              let b = UInt32(hexSanitized.suffix(2), radix: 16) else {
            return [1.0, 1.0, 1.0]
        }
        return [Double(r) / 255.0, Double(g) / 255.0, Double(b) / 255.0]
    }

    // MARK: - Static Helpers

    private static func resolveContentDir(for wallpaperPath: String) -> URL {
        let url = URL(fileURLWithPath: wallpaperPath)
        if url.pathExtension.lowercased() == "pkg" {
            if let extracted = extractPKG(at: url) { return extracted }
        }
        return WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
    }

    private static func extractPKG(at url: URL) -> URL? {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wallpaperengine_props_\(url.deletingPathExtension().lastPathComponent)_\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? tempDir : nil
        } catch {
            return nil
        }
    }

    private static func parseOptions(_ raw: Any?) -> [[String: String]] {
        guard let raw else { return [] }
        if let array = raw as? [[String: Any]] {
            return array.compactMap { item in
                guard let value = item["value"], let label = item["label"] as? String else { return nil }
                return ["value": String(describing: value), "label": WallpaperEnginePropertyLocalizer.label(for: label)]
            }
        }
        if let dict = raw as? [String: String] {
            return dict.map { ["value": $0.key, "label": WallpaperEnginePropertyLocalizer.label(for: $0.value)] }
        }
        return []
    }

    private static func normalizeType(_ raw: String) -> String {
        switch raw.lowercased() {
        case "bool", "toggle", "checkbox": return "bool"
        case "slider", "float", "percentage", "integer", "int": return "slider"
        case "color", "schemecolor": return "color"
        case "combo", "dropdown", "select": return "combo"
        case "textinput", "string": return "textinput"
        case "text", "label": return "text"
        case "group": return "group"
        case "description": return "description"
        case "file", "directory", "scenetexture", "replacetexture": return raw.lowercased()
        default: return raw.lowercased()
        }
    }

    private static let fallbackHTML = """
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><style>
    body { background: #1a1d2e; color: #e2e8f0; font-family: system-ui; padding: 20px; }
    </style></head><body><p>Loading editor...</p></body></html>
    """
}

// MARK: - Wallpaper Editor Type

enum WallpaperEditorType {
    case scene       // 场景壁纸 → SceneWallpaperPropertiesService
    case web         // Web 壁纸 → WebWallpaperDesignService
    case sceneConfig // 场景高级设置 → SceneConfigOverrideService
    case sceneDesign // 桌面动态元素设计 → SceneWallpaperDesignService
}

// MARK: - Property Editor Item

struct PropertyEditorItem {
    let key: String
    let type: String
    let text: String?
    let defaultValue: Any?
    let options: [[String: String]]
    let min: Double?
    let max: Double?
    let step: Double?
    let order: Int?
    let condition: String?
    let fraction: Bool
    let precision: Int?

    func toDict() -> [String: Any] {
        var dict: [String: Any] = ["key": key, "type": type]
        if let text = text { dict["text"] = text }
        if let defaultValue = defaultValue { dict["defaultValue"] = defaultValue }
        if !options.isEmpty { dict["options"] = options }
        if let min = min { dict["min"] = min }
        if let max = max { dict["max"] = max }
        if let step = step { dict["step"] = step }
        if let order = order { dict["order"] = order }
        if let condition = condition { dict["condition"] = condition }
        if fraction { dict["fraction"] = true }
        if let precision = precision { dict["precision"] = precision }
        return dict
    }
}

private final class PropertyEditorNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var target: WebPropertyEditorPanelController?

    init(target: WebPropertyEditorPanelController) {
        self.target = target
        super.init()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            self?.target?.handlePageFinishedLoading(webView)
        }
    }
}

// MARK: - Script Message Handler Proxy

private final class ScriptMessageHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebPropertyEditorPanelController?

    init(target: WebPropertyEditorPanelController) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            guard let target = self.target else { return }

            switch message.name {
            case "propertyChanged":
                if let body = message.body as? [String: Any],
                   let key = body["key"] as? String,
                   let value = body["value"] {
                    target.handlePropertyChanged(key: key, value: value)
                }
            case "closePanel":
                target.handleClosePanel()
            case "resetAll":
                target.handleResetAll()
            case "selectFile":
                if let body = message.body as? [String: Any],
                   let key = body["key"] as? String {
                    let isDirectory = body["isDirectory"] as? Bool ?? false
                    target.handleSelectFile(key: key, isDirectory: isDirectory)
                }
            case "editorReady":
                target.handleEditorReady()
            case "sceneDesignChanged":
                if let body = message.body as? [String: Any],
                   let entryKey = body["entryKey"] as? String,
                   let field = body["field"] as? String,
                   let value = body["value"] {
                    target.handleSceneDesignChanged(entryKey: entryKey, field: field, value: value)
                }
            case "selectLanguage":
                if let body = message.body as? [String: Any],
                   let groupID = body["groupID"] as? String,
                   let index = body["index"] as? Int,
                   let allEntryKeys = body["allEntryKeys"] as? [[String]] {
                    target.handleSelectLanguage(groupID: groupID, index: index, allEntryKeys: allEntryKeys)
                }
            default:
                break
            }
        }
    }
}

// MARK: - Helpers

private extension NSColor {
    /// Convert NSColor to hex string like "#3b82f6"
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#3b82f6" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

private extension AnyCodableValue {
    var foundationValue: Any {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .null: return NSNull()
        }
    }
}

private extension String {
    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
