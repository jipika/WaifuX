import Foundation

/// 设计壁纸/场景设计面板的编辑器 HTML 必须能被 **Helper 进程**读到。
///
/// 背景（2026-10-17）：面板在 `WaifuXHelper` 里弹出，`Bundle.main` 指向
/// `Contents/Helpers/WaifuXHelper.app`，而 HTML 只在主 App 的
/// `Contents/Resources/Resources/` 下 —— 旧实现只查 `Bundle.main`，于是永远
/// 落到 fallback「Loading editor…」，面板空白。修复=宿主 bundle 候选 + Helper
/// 资源双保险，本测试把这两个约束钉住。
@main
struct PropertyEditorResourceRegression {
    static func main() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let project = try source("project.yml", from: sourceRoot)
        let controller = try source("Views/WebPropertyEditorPanelController.swift", from: sourceRoot)
        let hostBundle = try source("BackgroundAgent/WaifuXHostBundle.swift", from: sourceRoot)
        let pbxproj = try source("WaifuX.xcodeproj/project.pbxproj", from: sourceRoot)
        let html = try source("Resources/WallpaperPropertyEditor.html", from: sourceRoot)

        precondition(
            project.contains("path: Resources/WallpaperPropertyEditor.html")
                && project.contains("buildPhase: resources"),
            "WaifuXHelper target must ship WallpaperPropertyEditor.html as a resource"
        )
        precondition(
            controller.contains("WaifuXHostBundle.resourceCandidates(named: \"WallpaperPropertyEditor.html\")"),
            "editor HTML lookup must fall back to the host app bundle"
        )
        precondition(
            !controller.contains("Loading editor..."),
            "fallback page must not pretend to be loading; show a real error instead"
        )
        precondition(
            hostBundle.contains("com.waifux.app"),
            "host bundle resolution must verify the outer app identifier"
        )
        precondition(
            pbxproj.contains("WallpaperPropertyEditor.html in Resources"),
            "generated project must reference the editor HTML resource"
        )

        // 四种编辑类型（web / scene / sceneConfig / sceneDesign）共用这一个 HTML 入口：
        // 加载必须发生在类型分支之前，否则资源修好也只覆盖其中一类。
        let htmlLoad = controller.range(of: "let htmlContent = loadHTMLEditorContent()")
        let designBranch = controller.range(of: "if currentType == .sceneDesign {")
        precondition(
            htmlLoad != nil && designBranch != nil && htmlLoad!.lowerBound < designBranch!.lowerBound,
            "editor HTML must be loaded before the per-type data branches"
        )
        // 只查 HTML 本体：Swift 注入脚本里的 `typeof initSceneDesign` 字样不算数。
        precondition(
            html.contains("function initFromData()") && html.contains("function initSceneDesign()"),
            "editor HTML must keep both render modes used by web/scene and sceneDesign"
        )

        // 回写链路：只看 scheduleApply 函数体，确认三种渲染目标各自还在。
        guard let applyStart = controller.range(of: "private func scheduleApply("),
              let typeDetection = controller.range(
                  of: "// MARK: - Type Detection",
                  range: applyStart.upperBound..<controller.endIndex
              ) else {
            preconditionFailure("scheduleApply body not found")
        }
        let applyBody = String(controller[applyStart.lowerBound..<typeDetection.lowerBound])
        precondition(
            applyBody.contains("refreshWallpaperProperties("),
            "scene/sceneConfig edits must still refresh renderer properties"
        )
        precondition(
            applyBody.contains("applyWebWallpaperProperties("),
            "web edits must still push effective properties to the web renderer"
        )

        // sceneDesign 不走 scheduleApply：它经 scheduleSceneDesignRebuild 重建动态文字叠加层。
        guard let rebuildStart = controller.range(of: "private func scheduleSceneDesignRebuild()"),
              let toDouble = controller.range(
                  of: "private static func toDouble(",
                  range: rebuildStart.upperBound..<controller.endIndex
              ) else {
            preconditionFailure("scheduleSceneDesignRebuild body not found")
        }
        let rebuildBody = String(controller[rebuildStart.lowerBound..<toDouble.lowerBound])
        precondition(
            rebuildBody.contains("LiquidGlassClockOverlayManager.shared.rebuildAll()"),
            "scene-design edits must still rebuild the dynamic-text overlay"
        )

        // 有构建产物时，顺手验证资源真的落进了 Helper bundle（源码断言证明不了这一点）。
        let builtApp = sourceRoot.appendingPathComponent("build/Build/Products/Debug/WaifuX.app")
        if FileManager.default.fileExists(atPath: builtApp.path) {
            let helperHTML = builtApp.appendingPathComponent(
                "Contents/Helpers/WaifuXHelper.app/Contents/Resources/WallpaperPropertyEditor.html"
            )
            let size = (try? FileManager.default.attributesOfItem(atPath: helperHTML.path)[.size] as? NSNumber)?.intValue ?? 0
            precondition(size > 0, "built WaifuXHelper.app must contain a non-empty editor HTML (\(helperHTML.path))")
        }

        print("Property editor regression passed: Helper ships the editor HTML; web/scene/sceneConfig/sceneDesign share it and keep their apply paths")
    }

    private static func source(_ relativePath: String, from root: URL) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
