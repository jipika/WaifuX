//  系统壁纸选择权威探测
//
//  递归扫描 ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist，
//  判断用户是否在系统设置中选择了我们的壁纸扩展实例（Provider == 扩展 bundleID）。
//  此前 App 只能靠扩展 state 的 isActive 行为推断"用户已选择"，扩展未拉载时
//  无法区分「没选过」和「选了但扩展没启动」。
//
//  只读访问，永不写入该文件（与 WallpaperSystemCacheJanitor 的禁令一致）。
//  参考 Mirage (GPL-3.0) 的 WallpaperExtensionController.selectionState()。
//
//  本文件保持自包含（仅 Foundation），供回归脚本单独编译。

import Foundation

enum WallpaperStoreSelectionProbe {
    enum Selection: Equatable {
        case selected
        case notSelected
        case unknown
    }

    static let extensionBundleID = "com.waifux.app.wallpaperextension"

    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedResult: (mtime: Date, displays: Set<String>?, selection: Selection)?

    /// 探测当前选择状态。按文件 mtime 缓存，避免设置页高频刷新反复解析 plist。
    static func currentSelection(displayUUIDs: Set<String>? = nil) -> Selection {
        let url = storeURL
        guard FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let mtime = values.contentModificationDate else {
            // 文件不存在或不可读：macOS < 14 或沙箱不可见 → 未知，不做行为推断
            return .unknown
        }
        cacheLock.lock()
        if let cached = cachedResult, cached.mtime == mtime, cached.displays == displayUUIDs {
            cacheLock.unlock()
            return cached.selection
        }
        cacheLock.unlock()

        let selection = selectionState(at: url, displayUUIDs: displayUUIDs)
        cacheLock.lock()
        cachedResult = (mtime, displayUUIDs, selection)
        cacheLock.unlock()
        return selection
    }

    /// 读取并判定指定 store 文件。根结构缺 Displays/Spaces/SystemDefault 视为 unknown
    /// （系统版本升级后结构变化时宁可报未知，不做误判）。
    static func selectionState(at url: URL, displayUUIDs: Set<String>? = nil) -> Selection {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return .unknown }
        return selectionState(root: root, displayUUIDs: displayUUIDs)
    }

    static func selectionState(root: Any, displayUUIDs: Set<String>? = nil) -> Selection {
        guard var dictionary = root as? [String: Any],
              ["AllSpacesAndDisplays", "Displays", "Spaces", "SystemDefault"].contains(where: { dictionary[$0] != nil })
        else { return .unknown }
        // Keeper/settings retain the conservative, all-records probe. Desktop
        // writes must provide the live topology so disconnected displays and
        // old Spaces cannot indefinitely block the current screen's sync.
        guard let displayUUIDs else {
            return containsProvider(root, identifier: extensionBundleID) ? .selected : .notSelected
        }
        guard !displayUUIDs.isEmpty else { return .unknown }
        let requested = Set(displayUUIDs.map { $0.uppercased() })
        let unifiedChoice = dictionary["AllSpacesAndDisplays"] as? [String: Any]
        if let displays = dictionary["Displays"] as? [String: Any] {
            let live = displays.filter { requested.contains($0.key.uppercased()) }
            guard live.count == requested.count || unifiedChoice.map({ containsChoice($0) }) == true else { return .unknown }
            dictionary["Displays"] = live
        }
        if let spaces = dictionary["Spaces"] as? [String: Any] {
            dictionary["Spaces"] = spaces.mapValues { value -> Any in
                guard var space = value as? [String: Any],
                      let displays = space["Displays"] as? [String: Any] else { return value }
                var live: [String: Any] = [:]
                for identifier in requested {
                    live[identifier] = displays.first { $0.key.uppercased() == identifier }?.value
                        ?? space["Default"]
                }
                space["Displays"] = live
                return space
            }
        }
        // Match normalized UUID keys in both display-wide and Space maps.
        if let displays = dictionary["Displays"] as? [String: Any] {
            dictionary["Displays"] = Dictionary(uniqueKeysWithValues: displays.map { ($0.key.uppercased(), $0.value) })
        }
        // Spaces retains old choices after a display-wide replacement. Only
        // disregard an extension choice when its corresponding display record
        // has a strictly later LastSet. Missing dates/unknown shapes stay safe.
        if let allDisplays = dictionary["AllSpacesAndDisplays"] as? [String: Any],
           containsChoice(allDisplays) {
            if containsProvider(allDisplays, identifier: extensionBundleID) { return .selected }
            if let displays = dictionary["Displays"] as? [String: Any],
               !displays.values.allSatisfy({ extensionChoicesAreSuperseded($0, by: allDisplays) }) {
                return .unknown
            }
            return spaceChoicesAreSuperseded(dictionary["Spaces"], displays: [:], unified: allDisplays)
                ? .notSelected : .unknown
        }
        if let displays = dictionary["Displays"] as? [String: Any], !displays.isEmpty {
            guard displays.values.allSatisfy({ containsChoice($0) }) else { return .unknown }
            if containsProvider(displays, identifier: extensionBundleID) { return .selected }
            return spaceChoicesAreSuperseded(dictionary["Spaces"], displays: displays, unified: nil)
                ? .notSelected : .unknown
        }
        return .unknown
    }

    private static func spaceChoicesAreSuperseded(
        _ spaces: Any?, displays: [String: Any], unified: [String: Any]?
    ) -> Bool {
        guard let spaces, containsProvider(spaces, identifier: extensionBundleID) else { return true }
        guard let records = spaces as? [String: Any] else { return false }
        return records.values.allSatisfy { value in
            guard containsProvider(value, identifier: extensionBundleID) else { return true }
            guard let space = value as? [String: Any],
                  space.keys.allSatisfy({ ["Default", "Displays"].contains($0) }) else { return false }
            if let perDisplay = space["Displays"] as? [String: Any], !perDisplay.isEmpty {
                // A Space's Default is a fallback; explicit display records
                // decide the selection for the displays represented here.
                return perDisplay.allSatisfy { identifier, choice in
                    if let unified { return extensionChoicesAreSuperseded(choice, by: unified) }
                    return extensionChoicesAreSuperseded(choice, by: displays[identifier])
                }
            }
            guard let fallback = space["Default"] else { return false }
            if let unified { return extensionChoicesAreSuperseded(fallback, by: unified) }
            return !displays.isEmpty && displays.values.allSatisfy {
                extensionChoicesAreSuperseded(fallback, by: $0)
            }
        }
    }

    private static func extensionChoicesAreSuperseded(_ older: Any, by newer: Any?) -> Bool {
        guard containsProvider(older, identifier: extensionBundleID) else { return true }
        guard let old = older as? [String: Any], let new = newer as? [String: Any] else { return false }
        if let oldDate = old["LastSet"] as? Date, let newDate = new["LastSet"] as? Date {
            return newDate > oldDate && containsChoice(new)
                && !containsProvider(new, identifier: extensionBundleID)
        }
        guard old["Provider"] as? String != extensionBundleID else { return false }
        // Dates live on Desktop/Idle, alongside Content; compare the same path
        // so a newer desktop image cannot supersede a separate screen saver.
        return old.allSatisfy { key, value in
            extensionChoicesAreSuperseded(value, by: new[key])
        }
    }

    private static func containsChoice(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let provider = dictionary["Provider"] as? String, !provider.isEmpty { return true }
            return dictionary.values.contains { containsChoice($0) }
        }
        if let array = value as? [Any] { return array.contains { containsChoice($0) } }
        return false
    }

    /// 递归查找任意层级的 Provider 字段等于 identifier 的 choice。
    /// 结构随系统版本变化，因此只认字段名不认路径。
    static func containsProvider(_ value: Any, identifier: String) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["Provider"] as? String == identifier { return true }
            return dictionary.values.contains { containsProvider($0, identifier: identifier) }
        }
        if let array = value as? [Any] {
            return array.contains { containsProvider($0, identifier: identifier) }
        }
        return false
    }
}
