# 遮挡检测优化 — 移植日志

## 时间线

| 阶段 | 时间 | 内容 |
|------|------|------|
| 研究 | 2026-06-26 | 子代理分别研究 WaifuX 与 stors_wallpaper 的遮挡检测实现 |
| 方案 | 2026-06-26 | 对比优劣，确定移植两项：AXObserver + 网格采样 |
| 开发 | 2026-06-26 | 三个 Agent 顺序执行移植 |
| 验证 | 2026-06-26 | Xcode 27.0 完整构建通过，零错误零警告 |
| 提 PR | 2026-06-26 | [jipika/WaifuX#50](https://github.com/jipika/WaifuX/pull/50) |

---

## 背景

### 现有问题

WaifuX 的 `DynamicWallpaperAutoPauseManager` 使用 3 秒定时轮询检测窗口遮挡：

1. **性能浪费** — 每天调用 `CGWindowListCopyWindowInfo` ~28800 次，99% 的调用结果和上一轮相同
2. **响应延迟** — 用户拖动窗口后最多等 3 秒壁纸才暂停/恢复
3. **检测盲区** — 面积交集法只检测单个窗口，多个小窗口累积覆盖无法感知

### 参考实现

stors_wallpaper 项目的 `AutoPauseManager` 实现了：

1. **AXObserver 事件驱动** — 监听窗口移动/缩放/创建/销毁，<0.5s 响应
2. **50×50 网格采样** — 2500 个采样点逐点检测，支持多窗口累积覆盖

---

## 移植方案

```
之前:  Timer 3s ──> CGWindowListCopyWindowInfo ──> 面积交集 ──> pause/resume

之后:  AXObserver ──> 200ms限速 ──> 500ms防抖 ──> CGWindowListCopyWindowInfo(仅变更时)
         (事件驱动)                                      └─> 网格采样50×50 ──> pause/resume

       无AX权限时 ──> Timer 3s 轮询（降级兜底，行为不变）
```

---

## 修改文件

### 新建文件

| 文件 | 行数 | 说明 |
|------|------|------|
| `Utilities/Debouncer.swift` | 88 | 轻量防抖工具，`OSAllocatedUnfairLock` 线程安全，兼容 C 回调 |

### 修改文件

| 文件 | +行 | −行 | 说明 |
|------|-----|-----|------|
| `Services/DynamicWallpaperAutoPauseManager.swift` | 310 | 50 | 核心改动 |
| `WaifuX.xcodeproj/project.pbxproj` | 4 | 0 | 注册 Debouncer.swift |

---

## 核心改动详解

### 1. AXObserver 事件驱动

#### 新增属性（行 53-59）

```swift
private var axObserver: AXObserver?              // AXObserver 实例
private var axObserverRunLoopSource: CFRunLoopSource?  // RunLoop 事件源
private var currentAXElement: AXUIElement?       // 当前监听的 app
private let windowCoverageDebouncer = Debouncer(delay: 0.5)  // 500ms 防抖
private static let axCallbackLock = NSLock()     // C 回调速率限制锁
private static var lastAXCallbackTime: CFAbsoluteTime = 0  // 上次回调时间
```

#### 新增方法

| 方法 | 行 | 功能 |
|------|-----|------|
| `setupAXObserver(for:)` | L1078-L1134 | 为指定 pid 创建 AXObserver，注册 4 种通知，200ms 速率限制 + 500ms 防抖 |
| `stopAXObserver()` | L1136-L1151 | 移除通知 → 移除 RunLoop 源 → 清空属性 |
| `checkWindowCoverage()` | L1153-L1165 | 由 AXObserver 事件触发，异步执行网格采样覆盖检测 |
| `checkForegroundCoverage(pid:)` | L1167-L1171 | 由 AXObserver 事件触发，重新评估前台覆盖 |
| `clearWindowCoveragePause()` | L1173-L1193 | Finder/本应用到前台时清除窗口覆盖暂停并恢复壁纸 |

#### AXObserver 事件流

```
窗口移动/缩放/创建/销毁
    │
    ▼
AXObserver C 回调 (任意线程)
    │
    ├── 200ms 速率限制 (axCallbackLock + CFAbsoluteTime)
    │
    ├── Unmanaged 取回 self
    │
    ├── Task { @MainActor } 跳回主线程
    │
    ├── windowCoverageDebouncer.debounce(delay: 0.5s)
    │       │
    │       └── checkWindowCoverage()      // 网格采样 → 按屏暂停/恢复
    │           checkForegroundCoverage()  // 重新评估前台覆盖
    │
    └── 无 AX 权限 → 不创建 AXObserver → 走 3s 定时轮询
```

#### 修改的方法

| 方法 | 改动 |
|------|------|
| `updateTimer()` (L194-L271) | AX 可用时窗口覆盖不启动 timer；末尾根据设置管理 AXObserver 生命周期 |
| `stopTimer()` (L285-L291) | 增加 `stopAXObserver()` 调用 |
| `checkAndApply()` (L293-L352) | AX 可用时跳过窗口覆盖的 timer 轮询 |
| `handleAppActivationChange()` (L439-L483) | 扩展 guard 条件；防抖闭包内管理 AXObserver |

### 2. 网格采样法

#### 新增类型（行 1278-1297）

```swift
private enum CoverageSampling {
    static let gridSize = 50          // 50×50 网格
    static let sampleCount = 2500     // 2500 个采样点
}

private struct WindowSnapshot {
    struct Window {
        let pid: pid_t
        let layer: Int
        let alpha: Double
        let bounds: CGRect

        func isVisibleContentWindow(excluding excludedPID: pid_t) -> Bool {
            pid != excludedPID && layer == 0 && alpha > 0
        }
    }
    let screenFrames: [String: CGRect]  // WaifuX 使用 String 屏幕 ID
    let windows: [Window]
}
```

#### 新增方法

| 方法 | 行 | 功能 |
|------|-----|------|
| `captureWindowSnapshot(screenFrames:)` | L744-L779 | 使用 `CGWindowListCopyWindowInfo` 枚举窗口，构建不可变快照 |
| `windowCoverageScreens(in:thresholdRatio:)` | L781-L807 | 对每屏收集候选窗口矩形，调用网格采样判断 |
| `isGridCoverageAtOrAboveThreshold(...)` | L809-L847 | 50×50 网格逐点检测，含早退优化 |
| `normalizedWindowBounds(_:screens:desktopFrame:)` | L849-L867 | 提升为 static，翻转 Quartz 坐标以匹配屏幕坐标 |

#### 网格采样算法

```
屏幕划分 50×50 = 2500 个采样点（每个点位于网格单元中心）

for 每行:
  for 每列:
    采样点 = (screenFrame.minX + (col + 0.5) * stepX,
              screenFrame.minY + (row + 0.5) * stepY)

    if 任意窗口矩形 contains 采样点:
      coveredSamples += 1

    if coveredSamples >= thresholdSamples:
      return true                    // 达标，提前返回

    if coveredSamples + 剩余点数 < thresholdSamples:
      return false                   // 早退优化

return false
```

#### 替换的方法

| 方法 | 改动 |
|------|------|
| `getWindowCoverageCoveredScreens(threshold:)` (L1199-L1210) | 从面积交集法替换为快照 + 网格采样 + 屏幕 ID 过滤 |

### 3. Debouncer 工具类

```swift
final class Debouncer: @unchecked Sendable {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let _workItem = OSAllocatedUnfairLock<DispatchWorkItem?>(initialState: nil)

    /// 每次调用取消之前的 action，只执行最后一次
    func debounce(action: @escaping @Sendable () -> Void) { ... }

    /// 取消待执行的 action
    func cancel() { ... }
}
```

---

## 性能对比

| 指标 | 移植前 | 移植后 |
|------|--------|--------|
| 遮挡响应延迟 | ≤3s (定时轮询) | ≤0.5s (事件驱动) |
| `CGWindowListCopyWindowInfo` 日均调用 | ~28800 (每3秒) | 典型场景数百次 |
| 多窗口累积覆盖检测 | ❌ 只检测单窗口 | ✅ 网格采样感知累积 |
| 窗口重叠去重 | ❌ | ✅ |
| CPU 空闲开销 | 恒定轮询 | 零（事件驱动） |
| 无 AX 权限降级 | N/A | 自动回退 3s 轮询 |

---

## 验证记录

### 静态检查

```bash
# Debouncer.swift 类型检查
$ swiftc -typecheck Utilities/Debouncer.swift
→ 通过

# DynamicWallpaperAutoPauseManager.swift 语法检查
$ swiftc -parse Services/DynamicWallpaperAutoPauseManager.swift
→ 通过

# Git diff 格式检查
$ git diff --check
→ 通过
```

### 完整构建

```bash
$ DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" \
  xcodebuild -project WaifuX.xcodeproj \
  -scheme WaifuX -configuration Debug build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

→ BUILD SUCCEEDED
→ Xcode 27.0 (27A5209h)
→ 零错误零警告
```

### 构建环境

| 项 | 值 |
|----|-----|
| Xcode | 27.0-beta (27A5209h) |
| macOS SDK | 27.0 |
| 架构 | arm64-apple-macos14.4 |
| Deployment Target | 14.4 |

---

## 已知限制

1. **Space 切换边缘情况**：仅开启窗口覆盖暂停且关闭前台/全屏暂停时，有 AX 权限下 Space 切换不会立即重检窗口覆盖。会在下次 AX 事件或手动触发时恢复。触发概率极低。
2. **`checkForegroundCoverage(pid:)` 未使用参数**：方法内部调用 `reevaluateForegroundCoverage()` 使用 `frontmostApplication`，pid 参数未被传递。实际行为正确（AXObserver 总是监听前台 app）。
3. **需要辅助功能权限**：首次使用会弹出系统权限请求。无权限时保持原有 3s 轮询。

---

## TODO

### 后续优化

| # | 内容 | 优先级 |
|---|------|--------|
| 1 | **AX 权限提示 UI** — 当用户开启窗口覆盖暂停但没有 AX 权限时，在 SettingsView 对应开关下方显示提示条，引导用户前往「系统设置 → 隐私与安全性 → 辅助功能」授权，从而启用事件驱动模式（~0.5s 响应）。参考 stors_wallpaper 的 `AccessibilityPermissionStatus` + `AXIsProcessTrustedWithOptions` 实现。 | 高 |
| 2 | 修复 Space 切换边缘情况 — `handleActiveSpaceChange` 中窗口覆盖路径不依赖 `pauseWhenOtherAppForeground` / `pauseWhenFullscreenCovers` 为 true 才触发 | 中 |
| 3 | `checkForegroundCoverage(pid:)` 参数传递 — 让 `getForegroundAppCoveredScreens()` 接受可选 pid 参数，或删除闲置参数 | 低 |

---

## 相关 PR

- [jipika/WaifuX#50](https://github.com/jipika/WaifuX/pull/50) — perf: 遮挡检测迁移到 AXObserver 事件驱动 + 网格采样

---

## 参考

- stors_wallpaper `AutoPauseManager.swift` — AXObserver 事件驱动 + 网格采样的原始实现
- Apple Developer Documentation: [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/1455135-cgwindowlistcopywindowinfo)
- Apple Developer Documentation: [AXObserver](https://developer.apple.com/documentation/applicationservices/axobserver)
