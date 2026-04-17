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

**必须带 `-rpath` 参数**，否则运行时找不到 `liblinux-wallpaperengine-renderer.dylib`：

```bash
swiftc \
  -parse-as-library \
  -I Resources/CRenderer \
  -I Resources \
  -L Resources \
  -llinux-wallpaperengine-renderer \
  -Xlinker -rpath -Xlinker @loader_path \
  -Xlinker -rpath -Xlinker @loader_path/Resources \
  -Xlinker -rpath -Xlinker @loader_path/../Resources \
  -framework AppKit \
  -framework IOKit \
  -framework WebKit \
  -framework Combine \
  -o Resources/wallpaperengine-cli \
  wallpaperengine-cli.swift

# 必须同时复制到根目录，否则开发模式会加载旧版本
cp Resources/wallpaperengine-cli wallpaperengine-cli
```

如果编译后发现 dylib 加载失败，也可以用 `install_name_tool` 补救：

```bash
install_name_tool -add_rpath "@loader_path" Resources/wallpaperengine-cli
install_name_tool -add_rpath "@loader_path/Resources" Resources/wallpaperengine-cli
install_name_tool -add_rpath "@loader_path/../Resources" Resources/wallpaperengine-cli
```
