import Foundation

/// 动态锁屏加固回归守卫（Mirage 参考点落地）：
/// 1. 系统壁纸 store 选择探测（Index.plist 递归扫描）的行为断言
/// 2. 扩展 state 心跳字段（pid/lastError）提取 + 进程存活判定的行为断言
/// 3. PlugInKit 选举输出解析的行为断言
/// 4. 其余加固点（唤醒重挂、兜底图、no-op 跳过、设置页状态行）的源码锚点
///
/// 编译运行（与其余三个自包含文件一起）：
///   swiftc Tests/LockScreenHardeningRegression.swift \
///     Services/WallpaperStoreSelectionProbe.swift \
///     Utilities/ProcessLiveness.swift \
///     Utilities/WallpaperExtensionElection.swift \
///     -o /tmp/LockScreenHardeningRegression && /tmp/LockScreenHardeningRegression
@main
struct LockScreenHardeningRegression {
    static var failures: [String] = []

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    static func source(_ relativePath: String, from sourceRoot: URL) -> String {
        let url = sourceRoot.appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            failures.append("无法读取源文件: \(relativePath)")
            return ""
        }
        return content
    }

    static func main() {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        testSelectionProbe()
        testProcessLiveness()
        testElectionParsing()
        testSourceAnchors(from: sourceRoot)

        if failures.isEmpty {
            print("PASS: LockScreenHardeningRegression (\(totalChecks) checks)")
        } else {
            for failure in failures {
                print("FAIL: \(failure)")
            }
            exit(1)
        }
    }

    static var totalChecks = 0

    static func expect(_ condition: Bool, _ message: String) {
        totalChecks += 1
        check(condition, message)
    }

    // MARK: - 1. Index.plist 选择探测

    static func testSelectionProbe() {
        func choice(_ provider: String, setAt: TimeInterval = 100) -> [String: Any] {
            ["Desktop": ["LastSet": Date(timeIntervalSince1970: setAt),
                         "Content": ["Choices": [["Provider": provider]]]]]
        }
        let extensionChoice = choice(WallpaperStoreSelectionProbe.extensionBundleID, setAt: 100)
        let imageChoice = choice("com.apple.wallpaper.choice.image", setAt: 200)
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: [
                "Displays": ["current": imageChoice],
                "Spaces": ["old-space": ["Default": extensionChoice, "Displays": ["current": extensionChoice]]],
                "SystemDefault": imageChoice
            ], displayUUIDs: ["current"]) == .notSelected,
            "旧 Space 的扩展记录不能阻止当前普通系统墙纸同步"
        )
        let disconnectedRoot: [String: Any] = [
            "Displays": ["current": imageChoice, "disconnected": extensionChoice],
            "Spaces": ["old-space": ["Default": extensionChoice,
                "Displays": ["current": extensionChoice, "disconnected": extensionChoice]]]
        ]
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: disconnectedRoot, displayUUIDs: ["current"]) == .notSelected,
            "拔掉的显示器与历史 Space 不能阻止当前屏幕跟随"
        )
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: disconnectedRoot) == .selected,
            "未提供在线显示器的 keeper 探测保持原有保守语义"
        )
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: [
                "Displays": ["current": imageChoice],
                "Spaces": ["new-space": ["Displays": ["current":
                    choice(WallpaperStoreSelectionProbe.extensionBundleID, setAt: 300)]]]
            ], displayUUIDs: ["current"]) == .unknown,
            "Space 中较新的扩展选择必须继续受保护"
        )
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: [
                "Displays": ["current": imageChoice],
                "Spaces": ["other-space": ["Displays": ["other": extensionChoice]]]
            ], displayUUIDs: ["current", "other"]) == .unknown,
            "另一显示器的普通墙纸不能覆盖未匹配显示器的扩展选择"
        )
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: [
                "Displays": ["current": imageChoice],
                "Spaces": ["undated-space": ["Default": ["Desktop": ["Content":
                    ["Choices": [["Provider": WallpaperStoreSelectionProbe.extensionBundleID]]]]]]]
            ], displayUUIDs: ["current"]) == .unknown,
            "缺少设置日期时不能猜测 Space 扩展已过期"
        )
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: [
                "Displays": ["current": imageChoice],
                "Spaces": ["idle-space": ["Displays": ["current": ["Idle": extensionChoice["Desktop"]!]]]]
            ], displayUUIDs: ["current"]) == .unknown,
            "新桌面图片不能覆盖独立 Idle 扩展选择"
        )
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: [
                "Displays": ["first": imageChoice, "second": extensionChoice]
            ], displayUUIDs: ["first", "second"]) == .selected,
            "任一显示器仍选扩展时必须保护其系统选择"
        )
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: [
                "AllSpacesAndDisplays": extensionChoice,
                "Displays": ["old": imageChoice]
            ], displayUUIDs: ["old"]) == .selected,
            "统一应用到所有显示器的扩展选择优先"
        )
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: [
                "AllSpacesAndDisplays": imageChoice, "Displays": [String: Any]()
            ], displayUUIDs: ["current"]) == .notSelected,
            "统一系统墙纸允许没有逐屏记录"
        )
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: [
                "SystemDefault": imageChoice
            ], displayUUIDs: ["current"]) == .unknown,
            "仅有系统默认值不足以断言在线显示器没有选择扩展"
        )
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: [
                "Displays": ["current": ["Unrecognized": true]],
                "SystemDefault": imageChoice
            ], displayUUIDs: ["current"]) == .unknown,
            "无法识别当前显示器 choice 时不得放行系统墙纸覆盖"
        )
        // 已选择：Displays 根 + 深层嵌套的 Provider
        let selectedRoot: [String: Any] = [
            "Displays": [
                "display-1": [
                    "Desktop": [
                        "Content": [
                            "Choices": [[
                                "Configuration": Data(),
                                "Files": [],
                                "Provider": WallpaperStoreSelectionProbe.extensionBundleID
                            ]]
                        ]
                    ]
                ]
            ]
        ]
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: selectedRoot) == .selected,
            "Displays 下嵌套的 Provider 应判定为 selected"
        )

        // Spaces 根 + 数组嵌套
        let spacesRoot: [String: Any] = [
            "Spaces": [[
                "wallpaper": [["Provider": WallpaperStoreSelectionProbe.extensionBundleID]]
            ]]
        ]
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: spacesRoot) == .selected,
            "Spaces 数组下的 Provider 应判定为 selected"
        )

        // 有效根结构但没有我们的 Provider → notSelected
        let notSelectedRoot: [String: Any] = [
            "SystemDefault": [
                "Desktop": ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.solar"]]]]
            ]
        ]
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: notSelectedRoot) == .notSelected,
            "有效根结构但无匹配 Provider 应判定为 notSelected"
        )

        // 根结构不认识 → unknown（系统版本升级时宁可未知，不误判）
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: ["Unexpected": 1]) == .unknown,
            "无 Displays/Spaces/SystemDefault 的根应判定为 unknown"
        )
        expect(
            WallpaperStoreSelectionProbe.selectionState(root: "not-a-dict") == .unknown,
            "非字典根应判定为 unknown"
        )
    }

    // MARK: - 2. 心跳字段 + 进程存活

    static func testProcessLiveness() {
        expect(ProcessLiveness.isAlive(ProcessInfo.processInfo.processIdentifier), "自身进程应判定存活")
        expect(!ProcessLiveness.isAlive(0), "pid=0 应判定死亡")
        expect(!ProcessLiveness.isAlive(-1), "负 pid 应判定死亡")

        let withHeartbeat = ProcessLiveness.heartbeat(fromJSON: [
            "isActive": true, "pid": 4242, "lastError": "switch_video 失败: boom"
        ])
        expect(withHeartbeat.pid == 4242, "heartbeat 应提取 pid")
        expect(withHeartbeat.lastError == "switch_video 失败: boom", "heartbeat 应提取 lastError")

        let legacy = ProcessLiveness.heartbeat(fromJSON: ["isActive": false])
        expect(legacy.pid == nil && legacy.lastError == nil, "旧版 state（无心跳字段）应返回 nil 并走旧逻辑")

        let intPid = ProcessLiveness.heartbeat(fromJSON: ["pid": Int(8)])
        expect(intPid.pid == 8, "JSON int pid 应可解码")
    }

    // MARK: - 3. PlugInKit 选举解析

    static func testElectionParsing() {
        let output = """
        +    com.waifux.app.wallpaperextension((null))\tF83A09C6-89E9-463E-BFD7-E033A64DB588\t2026-09-17 09:20:41 +0000\t/Applications/WaifuX.app/Contents/PlugIns/WaifuXWallpaperExtension.appex
             com.waifux.app.wallpaperextension((null))\t1A2B3C4D-0000-0000-0000-000000000000\t2026-09-01 00:00:00 +0000\t/private/tmp/WaifuX Build/Products/Debug/WaifuX.app/Contents/PlugIns/WaifuXWallpaperExtension.appex
             com.apple.some.OtherExtension(1.0)\tABCD\t2026-09-01 00:00:00 +0000\t/System/Library/Extensions/Other.appex
        """
        let records = WallpaperExtensionElection.parse(output: output)
        expect(records.count == 3, "应解析出 3 条 .appex 记录，实际 \(records.count)")
        expect(records.first?.isElected == true, "行首 + 应解析为 elected")
        expect(
            records.dropFirst().first?.path == "/private/tmp/WaifuX Build/Products/Debug/WaifuX.app/Contents/PlugIns/WaifuXWallpaperExtension.appex",
            "含空格路径应从第一个 / 取到行尾"
        )
        expect(
            WallpaperExtensionElection.isElected(
                output: output,
                targetPath: "/Applications/WaifuX.app/Contents/PlugIns/WaifuXWallpaperExtension.appex"
            ),
            "被选中副本的路径 isElected 应为 true"
        )
        expect(
            !WallpaperExtensionElection.isElected(
                output: output,
                targetPath: "/private/tmp/WaifuX Build/Products/Debug/WaifuX.app/Contents/PlugIns/WaifuXWallpaperExtension.appex"
            ),
            "未选中副本 isElected 应为 false"
        )
        expect(
            !WallpaperExtensionElection.isElected(output: "(0 plug-ins)", targetPath: "/Applications/WaifuX.app"),
            "空输出应判定未当选"
        )
    }

    // MARK: - 4. 源码锚点（不可单独编译的改动）

    static func testSourceAnchors(from root: URL) {
        let prefs = source("WaifuXWallpaperExtension/WallpaperPrefs.swift", from: root)
        expect(prefs.contains("var pid: Int32?"), "StateFile 必须含 pid 心跳字段")
        expect(prefs.contains("var updatedAt: TimeInterval?"), "StateFile 必须含 updatedAt 心跳字段")
        expect(prefs.contains("var lastError: String?"), "StateFile 必须含 lastError 字段")
        expect(prefs.contains("func reportError"), "扩展侧必须有 reportError 入口")
        expect(prefs.contains("guard changed else { return }"), "prefs reload 必须 no-op 跳过")

        let manager = source("Services/VideoWallpaperManager.swift", from: root)
        expect(manager.contains("ProcessLiveness.isAlive(pid)"), "宿主必须做 pid 验活")
        expect(manager.contains("writeExtensionStateInactive(reason: \"pid 失活\")"), "pid 失活必须立即清理 state")

        let extMain = source("WaifuXWallpaperExtension/WaifuXWallpaperExtension.swift", from: root)
        expect(extMain.contains("caContext.layer = context.rootLayer"), "唤醒恢复必须重挂远端 CAContext layer")
        expect(extMain.contains("WallpaperXPCHandler.invalidateSnapshotsAfterWake()"), "唤醒恢复必须失效系统快照缓存")

        let xpcHandler = source("WaifuXWallpaperExtension/WallpaperXPCHandler.swift", from: root)
        expect(xpcHandler.contains("static func invalidateSnapshotsAfterWake()"), "XPCHandler 必须暴露快照失效入口")
        expect(xpcHandler.contains("SystemFallbackImage.image()"), "acquire 无缓存快照时必须挂系统兜底图")

        let videoRenderer = source("WaifuXWallpaperExtension/VideoRenderer.swift", from: root)
        expect(videoRenderer.contains("SystemFallbackImage.image()"), "底图链第三级必须是系统桌面图")

        let appMain = source("App/WaifuXApp.swift", from: root)
        expect(appMain.contains("WallpaperExtensionElection.isElected"), "注册修复必须做选举验证")
        expect(appMain.contains("isExtensionElected(extensionURL: extensionURL)"), "注册修复必须有健康闸门（指纹未变且已 elected 时跳过）")
        expect(appMain.contains("wallpaper_extension_registration_fingerprint"), "注册指纹必须独立持久化（与 reload 指纹 key 分离）")

        let settingsVM = source("ViewModels/SettingsViewModel.swift", from: root)
        expect(settingsVM.contains("WallpaperStoreSelectionProbe.currentSelection()"), "设置页必须接权威选择探测")

        let settingsView = source("Views/SettingsView.swift", from: root)
        expect(settingsView.contains("lockScreenSelectionStatus"), "设置页必须显示选择状态行")
    }
}
