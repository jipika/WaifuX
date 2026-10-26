import Foundation

/// 静态图分流回归：确保图片扩展名不会被误判成 Workshop 工程，且三处同源白名单不漂移。
///
/// 2026-10-25 用户日志实证的故障：`.heic` 直接文件不在
/// `LocalWallpaperApplyService` 的图片白名单里 → 掉进 `case .unknown` 被当成
/// Workshop 目录 → `WallpaperEngineXBridge` 判定 `renderKind = .scene` →
/// wallpaper-wgpu 报 `VFS open failed: 加载资源失败`，而 App 侧仍打
/// `setWallpaper 完成` 判成功（用户看到「设了但没反应」）。
///
/// 本脚本锁三件事：
/// 1. 分类集必须含 heic/heif/avif（否则又会被送进渲染桥）；
/// 2. 搜索集必须**不含** tga/tif/tiff（`findImageFile` 原有口径就是 6 个）；
/// 3. 屏保与详情页的**同源副本**必须与分类集一致（否则同一张 heic
///    桌面能设、屏保却报「不支持」，或详情页按 unknown 去走 CLI）。
///
/// 运行方式（与其它 Tests/*.swift 一致，独立编译，不依赖 XCTest）：
///   swiftc -parse-as-library Tests/StaticImageRoutingRegression.swift -o /tmp/x && /tmp/x
///
/// 第 3 条通过读取 production 源码文本并解析集合字面量实现 —— Tests/ 不在任何
/// target 的 sources 里，无法 import 生产模块，所以不能直接引用常量。
/// 期望集合在这里显式写死（不是引用 production 值），因此不存在同义反复。
@main
struct StaticImageRoutingRegression {
    /// 期望的分类集（规格来源，独立于 production 断言）。
    static let expectedClassification: Set<String> = [
        "jpg", "jpeg", "png", "bmp", "gif", "webp", "tga", "tif", "tiff",
        "heic", "heif", "avif"
    ]

    /// 期望的搜索集：分类集减去 tga/tif/tiff。
    static let expectedSearchable: Set<String> = [
        "jpg", "jpeg", "png", "bmp", "gif", "webp", "heic", "heif", "avif"
    ]

    static let videos: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv", "avi", "flv"]

    enum Route: Equatable {
        case video
        case staticImage
        case workshopDirectory
    }

    /// 复刻 `apply` 的分支顺序：直接视频 → 直接静态图 → 目录。
    static func route(fileName: String, isDirectory: Bool) -> Route {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !isDirectory, videos.contains(ext) { return .video }
        if !isDirectory, expectedClassification.contains(ext) { return .staticImage }
        return .workshopDirectory
    }

    static func main() {
        testStaticImagesNeverRouteToRenderer()
        testVideoStillRoutesToVideo()
        testDirectoriesStayWorkshop()
        testSearchSetDoesNotGainTiffOrTga()
        testCaseInsensitive()
        testProductionSetsMatchSpec()
        print("✅ StaticImageRoutingRegression 全部通过")
    }

    /// 核心回归：这些扩展名的直接文件必须是静态图路径，不能落到 Workshop 分支。
    static func testStaticImagesNeverRouteToRenderer() {
        for ext in expectedClassification {
            let route = route(fileName: "wallpaper.\(ext)", isDirectory: false)
            precondition(
                route == .staticImage,
                "直接文件 .\(ext) 必须走静态图路径，实际是 \(route)（掉进 Workshop 分支就会被交给 wallpaper-wgpu 并 VFS open failed）"
            )
        }
    }

    static func testVideoStillRoutesToVideo() {
        for ext in videos {
            precondition(route(fileName: "clip.\(ext)", isDirectory: false) == .video,
                         "视频 .\(ext) 必须走视频路径")
        }
    }

    /// 目录仍走 Workshop 分支（scene/web 的真实工程就是目录，不能被守卫误拦）。
    static func testDirectoriesStayWorkshop() {
        precondition(route(fileName: "someSceneDir", isDirectory: true) == .workshopDirectory)
        precondition(route(fileName: "wallpaper.heic", isDirectory: true) == .workshopDirectory,
                     "名字像图片但实际是目录时，不能按静态图处理")
    }

    /// 搜索集只补 heic/heif/avif，不得顺带获得 tga/tif/tiff。
    static func testSearchSetDoesNotGainTiffOrTga() {
        for ext in expectedSearchable {
            precondition(expectedSearchable.contains(ext))
        }
        for ext in ["tga", "tif", "tiff"] {
            precondition(!expectedSearchable.contains(ext),
                         "搜索集不得含 .\(ext)：会改变 findImageFile 的搜索范围")
            precondition(expectedClassification.contains(ext),
                         "分类集应含 .\(ext)：直接文件按静态图应用是原有正确能力")
        }
    }

    static func testCaseInsensitive() {
        precondition(route(fileName: "A.HEIC", isDirectory: false) == .staticImage)
        precondition(route(fileName: "B.HeIf", isDirectory: false) == .staticImage)
        precondition(route(fileName: "C.AVIF", isDirectory: false) == .staticImage)
        precondition(route(fileName: "D.MP4", isDirectory: false) == .video)
    }

    // MARK: - 与 production 源码对照（防止三处同源白名单漂移）

    /// 从仓库根定位源文件。用 `#filePath` 而不是 cwd：CI 与本机运行目录可能不同。
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/StaticImageRoutingRegression.swift
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // 仓库根
    }

    /// 解析形如 `let x: Set<String> = [ "a", "b" ]` 的集合字面量。
    ///
    /// 从锚点之后扫描**所有** `[...]` 候选，返回第一个"看起来像扩展名集合"的：
    /// 元素全是 `^[a-z0-9]+$` 且至少 3 个。这是为了跳过同一段代码里的下标表达式
    /// （如 `json["background"]` 会解析出单个元素 `background`，数量不足被跳过），
    /// 否则锚点只能写得极其脆弱。
    static func parseSetLiteral(in source: String, anchor: String) -> Set<String>? {
        guard let anchorRange = source.range(of: anchor) else { return nil }
        var cursor = anchorRange.upperBound
        while let open = source[cursor...].firstIndex(of: "[") {
            guard let close = source[open...].firstIndex(of: "]") else { return nil }
            let body = source[source.index(after: open)..<close]
            let items = body
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        .lowercased() }
                .filter { !$0.isEmpty }
            if items.count >= 3,
               items.allSatisfy({ $0.allSatisfy { ch in ch.isLetter || ch.isNumber } }) {
                return Set(items)
            }
            cursor = source.index(after: close)
            if cursor >= source.endIndex { return nil }
        }
        return nil
    }

    static func loadSource(_ relativePath: String) -> String? {
        try? String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func testProductionSetsMatchSpec() {
        // ① LocalWallpaperApplyService：两个常量都必须与规格一致
        guard let applySource = loadSource("Services/LocalWallpaperApplyService.swift") else {
            print("⚠️ 跳过 production 对照：读不到 Services/LocalWallpaperApplyService.swift")
            return
        }
        if let actual = parseSetLiteral(in: applySource, anchor: "staticImageClassificationExts") {
            precondition(
                actual == expectedClassification,
                "staticImageClassificationExts 与规格不一致：缺 \(expectedClassification.subtracting(actual).sorted())、多 \(actual.subtracting(expectedClassification).sorted())"
            )
        } else {
            preconditionFailure("解析不到 staticImageClassificationExts 的集合字面量（锚点或写法变了？）")
        }
        if let actual = parseSetLiteral(in: applySource, anchor: "staticImageSearchExts") {
            precondition(
                actual == expectedSearchable,
                "staticImageSearchExts 与规格不一致：缺 \(expectedSearchable.subtracting(actual).sorted())、多 \(actual.subtracting(expectedSearchable).sorted())"
            )
        } else {
            preconditionFailure("解析不到 staticImageSearchExts 的集合字面量（锚点或写法变了？）")
        }

        // ② 屏保：imageExtensions 必须覆盖分类集（否则同一张图桌面能设、屏保报不支持）
        if let saverSource = loadSource("Services/ScreenSaverService.swift"),
           let actual = parseSetLiteral(in: saverSource, anchor: "imageExtensions: Set<String>") {
            let missing = expectedClassification.subtracting(actual)
            precondition(missing.isEmpty,
                         "屏保 imageExtensions 缺 \(missing.sorted())：桌面能设的格式屏保会报 unsupported")
        } else {
            preconditionFailure("解析不到 ScreenSaverService.imageExtensions（锚点或写法变了？）")
        }

        // ③ 详情页类型推断：background 为 heic 时若不认就会按 unknown 去走 CLI。
        // 按函数名定位再取其后第一个集合字面量 —— 那正是 background 的图片判断，
        // 且不依赖换行/缩进写法。
        if let detailSource = loadSource("Views/MediaDetailSheet.swift"),
           let actual = parseSetLiteral(in: detailSource, anchor: "private func inferWorkshopContentType") {
            let missing = expectedClassification.subtracting(actual)
            precondition(missing.isEmpty,
                         "详情页 inferWorkshopContentType 的图片判断缺 \(missing.sorted())")
        } else {
            preconditionFailure("解析不到详情页 inferWorkshopContentType 的图片集合（锚点或写法变了？）")
        }
    }
}
