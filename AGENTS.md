# Agent Development Notes

## Wallpaper Engine CLI 二进制部署说明

项目依赖一个独立的 Swift 可执行文件 `wallpaperengine-cli`（源码为根目录下的 `wallpaperengine-cli.swift`），该文件负责通过 C++ renderer (`liblinux-wallpaperengine-renderer.dylib`) 渲染 Scene/Web 类型壁纸。

### 查找优先级（`WallpaperEngineXBridge.resolveCLIPath()`）

运行时按以下顺序查找可执行文件，**先找到的先使用**：

1. `Bundle.main.url(forResource: "wallpaperengine-cli", withExtension: nil)`
2. `Bundle.main.bundleURL/Contents/Resources/wallpaperengine-cli`（App Bundle 内）
3. `Bundle.main.resourceURL/wallpaperengine-cli`
4. `Bundle.main.bundleURL` 的同级目录下的 `wallpaperengine-cli`
5. 硬编码 fallback：
   - `/Volumes/mac/CodeLibrary/Claude/WallHaven/wallpaperengine-cli`
   - `/Volumes/mac/CodeLibrary/Claude/WallHaven/Resources/wallpaperengine-cli`

### ⚠️ 关键陷阱

**在 Xcode 运行或本地开发时，如果根目录下存在 `wallpaperengine-cli`，它会优先于 `Resources/wallpaperengine-cli` 被加载。**

因此：
- **编译后必须同时替换根目录和 `Resources/` 下的二进制**，否则旧版本仍会被执行。
- 旧 daemon 可能已在后台运行，可通过 `ps aux | grep wallpaperengine-cli` 检查；重新设置壁纸时 client 会杀掉旧 daemon 并启动新的。

### 编译命令

**`Resources/assets` 不提交 Git**（`.gitignore`）。**`Resources/wallpaperengine-cli` 由本地构建后提交**；GitHub Actions **不再**在 CI 里编 CLI，`xcodebuild` 也不会每次跑嵌入脚本。

**CI 默认分支**：仓库以 `feature/wallpaper-engine` 为集成分支（无 `main`）。推送改 `VERSION`、PR 目标分支、Pages 触发分支均以此为准；若改名需同步 `.github/workflows/*.yml`。

**WE 动态壁纸**：`scene` 与 `web` 均由 `wallpaperengine-cli` 渲染，在 App 内与本机视频壁纸一并视为动态壁纸；`WallpaperEngineXBridge.isControllingExternalEngine` 为真时，状态栏暂停/恢复/关闭必须走 CLI，不得误用 `VideoWallpaperManager`。设置 WE 壁纸前只能调用 `stopNativeVideoWallpaperOnly()`，禁止先置 `isControllingExternalEngine = true` 再调 `VideoWallpaperManager.stopWallpaper()`（否则会 `stopWallpaper` 链式停掉 CLI 并清掉标志）。

本地更新 CLI 时：

```bash
chmod +x scripts/ensure-wallpaperengine-assets.sh scripts/build-wallpaperengine-cli.sh
./scripts/ensure-wallpaperengine-assets.sh   # 已有本地 Resources/assets 则跳过；否则设 WAIFUX_WE_ASSETS_PACK_URL
./scripts/build-wallpaperengine-cli.sh      # 产出 Resources/wallpaperengine-cli 与仓库根目录 wallpaperengine-cli，再 git add 提交
```

`package.sh`：若已存在 `Resources/wallpaperengine-cli` 则跳过上述构建；需要强制重编时设 `WAIFUX_FORCE_CLI_REBUILD=1`。

如果编译后发现 dylib 加载失败，也可以用 `install_name_tool` 补救：

```bash
install_name_tool -add_rpath "@loader_path" Resources/wallpaperengine-cli
install_name_tool -add_rpath "@loader_path/Resources" Resources/wallpaperengine-cli
install_name_tool -add_rpath "@loader_path/../Resources" Resources/wallpaperengine-cli
```
