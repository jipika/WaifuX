# Changelog

## 38.0.68 — 2026-04-20

### 版本与构建号（与 `VERSION`、`project.yml` 对齐）

| 字段 | 值 | 说明 |
|------|-----|------|
| 营销版本（`CFBundleShortVersionString` / `MARKETING_VERSION`） | **38.0.68** | 合并时以合并前 **`main`（`waifu/main`）顶端** 的营销版本为准，与 **`VERSION` 文件** 一致。 |
| 构建号（`CFBundleVersion` / `CURRENT_PROJECT_VERSION`） | **39** | 取 **`feature/wallpaper-engine`** 侧已存在的更高构建号，**避免从 39 回退到 38**。 |

相对 **`waifu/main` @ 8d03d9b** 的 Git 拓扑：

1. **`560b19e`** — `chore: release 38.0.67 (build 39)`（壁纸引擎功能分支上的发行标记；合并后工程展示版本以 **38.0.68** 为准，见上表）。
2. **`16a0f8c`** — `Merge branch 'feature/wallpaper-engine'`（将上述分支合入 **`main`**，第二父提交为 **`560b19e`**）。

### 概要

在已包含 **GitHub 更新 / `GitHubHosts` 在 VPN 与系统 HTTP(S)、SOCKS、PAC 代理下关闭固定 IP** 等网络修复的 `main` 基础上，将 **`feature/wallpaper-engine`** 的壁纸引擎与探索相关改动并入主线。

### 主要带入内容（相对 8d03d9b 的文件级范围）

- **壁纸与调度**：`VideoWallpaperManager`、`WallpaperEngineXBridge`、`WallpaperSchedulerService`、`VideoThumbnailCache` 等。
- **工坊与探索**：`WorkshopSourceManager`、`MediaExploreViewModel`、`MediaExploreContentView`；**Workshop 媒体探索内容级别固定为 `Everyone`（SFW），不提供内容级别 UI**（与既有产品策略一致）。
- **界面与体验**：`HomeContentView`、`WallpaperExploreContentView`、`AnimeExploreView`、`ContentView`、`MyLibraryContentView`、各 `DetailSheet`；`ExploreAtmosphere`、`GlassStyle` 等视觉与氛围组件。
- **工程**：`project.yml` / `WaifuX.xcodeproj` 已与上述版本号、构建号对齐。

### 升级注意

- Workshop 与 SteamCMD 相关前提条件仍以设置页与 README 为准；大资源若被忽略需按仓库说明补齐。

---

## 38.0.64 — 2026-04-20

### 概要

本版本将 **Wallpaper Engine / Steam 工坊** 相关能力合入 `main`，并完成一轮 **发行链接、Workshop 体验与设置页** 整理，属于功能面较大的升级。

### 壁纸引擎与工坊

- 集成 **wallpaperengine-cli**、**linux-wallpaperengine-renderer**（dylib）及 **WallpaperEngineXBridge**，支持在 macOS 上驱动 Workshop 场景/网页/视频等类型内容。
- **WorkshopService / WorkshopSourceManager**：Steam 创意工坊列表、搜索、标签与类型筛选；通过 **SteamCMD** 拉取订阅项；支持 Steam Guard 与凭证缓存。
- **SceneOfflineBakeService / SceneBakeEligibilityService**：场景壁纸离线烘焙、资格判断；结合 **SystemMemoryPressure** 等做内存与稳定性防护。
- **MediaExploreViewModel**：工坊分页、首页条与下载任务衔接；探索数据源可在 MotionBG 与壁纸引擎之间切换。

### 探索与内容策略

- 媒体探索中 **壁纸引擎源固定为 SFW**：请求始终携带 Steam 侧 `Everyone`（`requiredtags[]`），并 **移除「内容级别」筛选 UI**，不再展示「已选 SFW」类筛选芯片。
- Wallhaven / 其他源的既有筛选逻辑未改。

### 详情页与下载

- Workshop 下载进行中 **允许返回**（不再锁定左上角返回）；设置壁纸或场景烘焙进行中仍会阻止误触返回。
- 移除「Wallpaper Engine X 激活码」校验与设置项；设置壁纸仅依赖本机 **Wallpaper Engine X** 应用是否安装等条件。

### 设置与状态展示

- **SteamCMD 状态**：圆点、主文案与右侧标签统一依据 `checkSteamCMDStatus()`，避免「Application Support 已有 steamcmd」与「包内未内置资源」**文案自相矛盾**。
- 删除仅检查 Bundle 的 `isSteamCMDConfigured`，避免与运行时路径逻辑不一致。

### 更新检测、文档与 CI

- 应用内 **UpdateChecker / UpdateManager**、README（多语言）、落地页与部分 Workflow 产物命名中，将 **`waifuX-pro` 分发线** 与 **`jipika/WaifuX` 主线仓库** 对齐（具体以仓库实际发布位置为准）。
- 版本号递增至 **38.0.64**。

### 升级注意

- 若使用 Workshop 下载，需按设置页指引配置 **SteamCMD**（内置或随包资源以实际发行版为准）。
- **Resources/assets/** 等大资源若仍被 `.gitignore` 忽略，克隆后需按脚本或 CI 说明补齐构建依赖。

---

（更早版本未在此文件逐条追溯；若需完整历史可查阅 `git log`。）
