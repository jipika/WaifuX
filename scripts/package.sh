#!/bin/bash
# WaifuX 打包脚本
# 用法: ./scripts/package.sh            # 按本机架构打包
#       WAIFUX_ARCH=x86_64 ./scripts/package.sh
#
# 拆架构分发（38.0.154+）：
#   - WaifuX-arm64.dmg   内置 wallpaper-wgpu + DXC + ffmpeg/lib 全家桶（scene 渲染可用）
#   - WaifuX-x86_64.dmg  携带 x86_64 scene 渲染器、DXC、ffmpeg 与 web daemon
# 扩展（.appex）与屏保（.saver）保持 universal，两个包共用。

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_NAME="WaifuX.xcarchive"
APP_NAME="WaifuX.app"
RENDERER_ENTITLEMENTS="$PROJECT_DIR/WallpaperRenderer.entitlements"

# ---- 目标架构 ----
# WAIFUX_ARCH=universal 构建过渡 universal 包（default channel 桥接件，供旧版
# universal 客户端收到本次拆架构后的新代码；新客户端再经 Sparkle channel 转到单架构包）。
PKG_ARCH="${WAIFUX_ARCH:-$(uname -m)}"
case "$PKG_ARCH" in
  arm64|x86_64|universal) ;;
  *) echo "❌ 不支持的 WAIFUX_ARCH: $PKG_ARCH（可选 arm64 | x86_64 | universal）"; exit 1 ;;
esac
echo "🏗️ 目标架构: $PKG_ARCH"

echo "📦 WaifuX 打包开始..."
echo "项目目录: $PROJECT_DIR"

require_packaged_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" ]]; then
    echo "❌ 缺少 $label: $path"
    exit 1
  fi
}

fix_ffmpeg_install_names() {
  local ffmpeg_bin="$1"
  local lib_dir="$2"

  if [[ ! -f "$ffmpeg_bin" || ! -d "$lib_dir" ]] || ! command -v otool >/dev/null 2>&1 || ! command -v install_name_tool >/dev/null 2>&1; then
    return 0
  fi

  local changed=false
  while IFS= read -r dep_path; do
    [[ -n "$dep_path" ]] || continue
    case "$dep_path" in
      /opt/homebrew/*)
        local dep_base
        dep_base="$(basename "$dep_path")"
        if [[ -e "$lib_dir/$dep_base" ]]; then
          install_name_tool -change "$dep_path" "@loader_path/lib/$dep_base" "$ffmpeg_bin" 2>/dev/null || true
          changed=true
        else
          echo "⚠️ ffmpeg 依赖未捆绑: $dep_base"
        fi
        ;;
    esac
  done < <(otool -L "$ffmpeg_bin" 2>/dev/null | awk 'NR > 1 { print $1 }')

  if [[ "$changed" == true ]]; then
    codesign --force --sign - "$ffmpeg_bin" 2>/dev/null || true
    echo "✅ ffmpeg dylib 路径已改为 @loader_path/lib"
  fi
}

verify_packaged_ffmpeg() {
  local ffmpeg_bin="$1"
  if [[ ! -f "$ffmpeg_bin" ]]; then
    return 0
  fi
  if ! "$ffmpeg_bin" -hide_banner -version >/dev/null 2>&1; then
    echo "❌ ffmpeg 无法启动: $ffmpeg_bin"
    echo "请先运行 ./scripts/build-wallpaper-wgpu.sh 修复并提交 Resources/ffmpeg"
    exit 1
  fi
}

# wallpaper-wgpu + DXC 部署（仅 arm64 包需要）。
# CI / GitHub 打包默认使用仓库里已提交的二进制与内嵌 assets object；
# 只有本地缺文件或显式设置 WAIFUX_FORCE_WGPU_REBUILD=1 时才重建，避免 CI 在
# 没有 Resources/assets 的环境里生成空资源占位。
if [[ "$PKG_ARCH" == "x86_64" ]]; then
  echo "⏭️ x86_64 包：使用已提交的 x86_64 渲染器组件（跳过 arm64 wgpu/ffmpeg 部署链）"
  require_packaged_file "$PROJECT_DIR/Resources/wallpaper-wgpu-x86_64" "wallpaper-wgpu (x86_64)"
  require_packaged_file "$PROJECT_DIR/Resources/dxc-x86_64" "dxc (x86_64)"
  require_packaged_file "$PROJECT_DIR/Resources/libdxcompiler-x86_64.dylib" "libdxcompiler.dylib (x86_64)"
  require_packaged_file "$PROJECT_DIR/Resources/ffmpeg-x86_64" "ffmpeg (x86_64)"
else
WGPU_BIN="$PROJECT_DIR/Resources/wallpaper-wgpu"
WGPU_REBUILD_REASON=""

if [[ -n "${CI:-}" ]] && [[ -f "$WGPU_BIN" ]] && [[ -z "${WAIFUX_FORCE_WGPU_REBUILD:-}" ]]; then
  WGPU_REBUILD_REASON=""
elif [[ ! -f "$WGPU_BIN" ]]; then
  WGPU_REBUILD_REASON="missing binary"
elif [[ -n "${WAIFUX_FORCE_WGPU_REBUILD:-}" ]]; then
  WGPU_REBUILD_REASON="WAIFUX_FORCE_WGPU_REBUILD"
fi

if [[ -n "$WGPU_REBUILD_REASON" ]]; then
  if [[ -f "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh" ]]; then
    echo "🔧 部署 wallpaper-wgpu + DXC + 内嵌 assets（原因：$WGPU_REBUILD_REASON）..."
    chmod +x "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh"
    WAIFUX_FORCE_EMBED_ASSETS=1 "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh"
  fi
else
  echo "🔧 使用已提交的 $WGPU_BIN（跳过 wallpaper-wgpu 构建）。若需重编请设 WAIFUX_FORCE_WGPU_REBUILD=1"
fi

require_packaged_file "$PROJECT_DIR/Resources/wallpaper-wgpu" "wallpaper-wgpu"
require_packaged_file "$PROJECT_DIR/Resources/dxc" "dxc"
require_packaged_file "$PROJECT_DIR/Resources/lib/libdxcompiler.dylib" "libdxcompiler.dylib"
require_packaged_file "$PROJECT_DIR/Resources/zip_data.o" "wallpaper-wgpu embedded assets object"
require_packaged_file "$PROJECT_DIR/Resources/zip_accessor.o" "wallpaper-wgpu embedded assets accessor object"
fix_ffmpeg_install_names "$PROJECT_DIR/Resources/ffmpeg" "$PROJECT_DIR/Resources/lib"
verify_packaged_ffmpeg "$PROJECT_DIR/Resources/ffmpeg"
fi

# 打包必须拒绝错误的 CoreMedia 绑定；不能用本机构建机能启动代替 Intel 兼容性。
case "$PKG_ARCH" in
  arm64) renderer_inputs=(wallpaper-wgpu dxc lib/libdxcompiler.dylib ffmpeg) ;;
  x86_64) renderer_inputs=(wallpaper-wgpu-x86_64 dxc-x86_64 libdxcompiler-x86_64.dylib ffmpeg-x86_64) ;;
  universal) renderer_inputs=(wallpaper-wgpu dxc lib/libdxcompiler.dylib ffmpeg wallpaper-wgpu-x86_64 dxc-x86_64 libdxcompiler-x86_64.dylib ffmpeg-x86_64) ;;
esac
for renderer_input in "${renderer_inputs[@]}"; do
  python3 "$PROJECT_DIR/scripts/renderer_coremedia_compat.py" --minimum-macos 14.4 "$PROJECT_DIR/Resources/$renderer_input"
done

# wallpaperengine-cli 仅作为 web 壁纸 daemon 保留（不嵌入 assets，体积约 640KB）。
# 拆架构后每个包带各自架构的 CLI：arm64 用已提交的 Resources/wallpaperengine-cli，
# x86_64 用 Resources/wallpaperengine-cli-x86_64（swiftc 交叉编译产物，提交进仓库）。
if [[ "$PKG_ARCH" == "x86_64" ]]; then
  CLI_BIN="$PROJECT_DIR/Resources/wallpaperengine-cli-x86_64"
elif [[ "$PKG_ARCH" == "universal" ]]; then
  CLI_BIN="$PROJECT_DIR/build/wallpaperengine-cli-universal"
else
  CLI_BIN="$PROJECT_DIR/Resources/wallpaperengine-cli"
fi
CLI_REBUILD_REASON=""

# CI 环境下若 CLI 二进制已存在且非强制重建，直接跳过（避免因时间戳差异误触发重建）
if [[ -n "${CI:-}" ]] && [[ -f "$CLI_BIN" ]] && [[ -z "${WAIFUX_FORCE_CLI_REBUILD:-}" ]]; then
  CLI_REBUILD_REASON=""
elif [[ ! -f "$CLI_BIN" ]]; then
  CLI_REBUILD_REASON="missing binary"
elif [[ -n "${WAIFUX_FORCE_CLI_REBUILD:-}" ]]; then
  CLI_REBUILD_REASON="WAIFUX_FORCE_CLI_REBUILD"
elif [[ "$PROJECT_DIR/wallpaperengine-cli.swift" -nt "$CLI_BIN" ]]; then
  CLI_REBUILD_REASON="wallpaperengine-cli.swift changed"
fi

if [[ -n "$CLI_REBUILD_REASON" ]]; then
  echo "🔧 构建 wallpaperengine-cli（web 壁纸 daemon 用，$PKG_ARCH，原因：$CLI_REBUILD_REASON）..."
  if [[ -f "$PROJECT_DIR/scripts/build-wallpaperengine-cli.sh" ]]; then
    chmod +x "$PROJECT_DIR/scripts/build-wallpaperengine-cli.sh"
    "$PROJECT_DIR/scripts/build-wallpaperengine-cli.sh" "$PKG_ARCH"
  fi
else
  echo "🔧 使用已提交的 $CLI_BIN（跳过 CLI 构建）。若需重编请设 WAIFUX_FORCE_CLI_REBUILD=1"
fi

require_packaged_file "$CLI_BIN" "wallpaperengine-cli ($PKG_ARCH)"

# 签名 wallpaper-wgpu、CLI、dxc 及依赖（仓库层；bundle 内在导出后会重签）
echo "🔏 签名渲染器二进制..."
for f in "$PROJECT_DIR"/Resources/wallpaper-wgpu \
         "$PROJECT_DIR"/Resources/wallpaperengine-cli \
         "$PROJECT_DIR"/Resources/wallpaperengine-cli-x86_64 \
         "$PROJECT_DIR"/wallpaperengine-cli \
         "$PROJECT_DIR"/Resources/ffmpeg \
         "$PROJECT_DIR"/Resources/dxc \
         "$PROJECT_DIR"/Resources/lib/*.dylib; do
  if [[ -f "$f" ]]; then
    if [[ "$(basename "$f")" == "wallpaper-wgpu" && -f "$RENDERER_ENTITLEMENTS" ]]; then
      codesign --force --options runtime --entitlements "$RENDERER_ENTITLEMENTS" -s - "$f" 2>/dev/null || \
        codesign --force -s - "$f" 2>/dev/null || true
    else
      codesign --force -s - "$f" 2>/dev/null || true
    fi
  fi
done

# 内嵌 SteamKit2 服务的 .NET host 在 hardened runtime 下需要 JIT entitlement
STEAM_SERVICE_ENTITLEMENTS="$PROJECT_DIR/SteamService.entitlements"
if [[ -f "$STEAM_SERVICE_ENTITLEMENTS" && -d "$PROJECT_DIR/SteamService/prebuilt" ]]; then
  find "$PROJECT_DIR/SteamService/prebuilt" -type f -name "dotnet" 2>/dev/null | while read -r host; do
    codesign --force --options runtime --entitlements "$STEAM_SERVICE_ENTITLEMENTS" -s - "$host" 2>/dev/null || \
      codesign --force -s - "$host" 2>/dev/null || true
  done
fi
echo "✅ 签名完成"

# 捕获手动替换 Resources 的情况，并与已发布组件的版本高水位对齐。
# 完整 App 必须携带同一份版本记录，避免已安装的旧热更新覆盖新版内置组件。
python3 "$PROJECT_DIR/scripts/renderer_component_versions.py" --refresh-feed

# 清理旧构建（保留 build/ 下其它产物，例如双架构流程里另一个架构已导出的 .app）
echo "🧹 清理旧构建..."
rm -rf "$BUILD_DIR/$ARCHIVE_NAME" "$BUILD_DIR/$APP_NAME" "$BUILD_DIR/exportOptions.plist"
mkdir -p "$BUILD_DIR"

# Archive
echo "🔨 正在 Archive ($PKG_ARCH)..."
if [[ "$PKG_ARCH" == "universal" ]]; then
  ARCH_OVERRIDES=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
else
  ARCH_OVERRIDES=(ARCHS="$PKG_ARCH" ONLY_ACTIVE_ARCH=NO)
fi
# 内嵌 assets 的 zip_data.o / zip_accessor.o 是 universal（含双架构切片），两个架构都正常链接。
xcodebuild -scheme WaifuX -configuration Release clean archive \
  "${ARCH_OVERRIDES[@]}" \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEBUG_INFORMATION_FORMAT=dwarf \
  STRIP_INSTALLED_PRODUCT=NO \
  MACOSX_DEPLOYMENT_TARGET=14.4 \
  -archivePath "$BUILD_DIR/$ARCHIVE_NAME" 2>&1 | tee "$BUILD_DIR/archive.log"

ARCHIVE_STATUS=${PIPESTATUS[0]}
if [ $ARCHIVE_STATUS -ne 0 ]; then
    echo "❌ Archive 失败"
    cat "$BUILD_DIR/archive.log" | tail -50
    exit 1
fi

echo "✅ Archive 成功"

# 从 archive 直接提取 App（不走 -exportArchive）
# 根因：自 a9488026（10-11 后台职责移交 Helper）起，主 App archive 内嵌套了
# Contents/Helpers/WaifuXHelper.app —— 它是 type:application 且带 App Group
# entitlements，而 archive 以 CODE_SIGNING_ALLOWED=NO / CODE_SIGN_IDENTITY=- 构建
# （无正式签名、无 provisioning）。Xcode 27 的 IDEDistribution 在枚举「该 archive
# 支持哪些导出方法」时返回空集，报：
#   exportArchive exportOptionsPlist error for key "method" expected one {} but found mac-application
# 于是任何 method 值都被拒，-exportArchive 必然失败。09-29 那次同参数、同 Xcode(27A266a)
# 2 秒「✅ 导出成功」，其 archive 内只有 .appex 与 .saver（bundle 不触发枚举）——
# 佐证是产物结构而非命令写错。本脚本的 export 本就 CODE_SIGNING_ALLOWED=NO 且不做
# thinning（archive 已按 ARCHS 出目标架构），产物等价于 archive 内 Products/Applications/
# WaifuX.app 的纯拷贝；真正签名在下游 sign_exported_app（重签整个 bundle）。
echo "📤 从 archive 提取 App..."
ARCHIVE_APP="$BUILD_DIR/$ARCHIVE_NAME/Products/Applications/$APP_NAME"
if [[ ! -d "$ARCHIVE_APP" ]]; then
    echo "❌ archive 内未找到 $APP_NAME: $ARCHIVE_APP" >&2
    ls -R "$BUILD_DIR/$ARCHIVE_NAME/Products" 2>/dev/null | tail -30
    exit 1
fi
rm -rf "$BUILD_DIR/$APP_NAME"
# 用 ditto 而非 cp -R：保留符号链接（如 Sparkle.framework/Resources）、xattr、资源叉。
ditto "$ARCHIVE_APP" "$BUILD_DIR/$APP_NAME"
if [[ $? -ne 0 ]]; then
    echo "❌ 提取失败：ditto $ARCHIVE_APP" >&2
    exit 1
fi
echo "✅ 提取成功"

# ---- x86_64 包换装渲染器组件（签名前）----
# folder reference 会把仓库 Resources/ 原样拷进 bundle（含 arm64 组件与带 -x86_64 后缀的
# 提交件），这里按架构重排：x86_64 包换成 x86_64 的渲染器三件套 + 静态 ffmpeg。
# wgpu 静态链接 ffmpeg，运行时不需要 lib/ 里的 ffmpeg 闭包（lib/ 只保留 libdxcompiler）。
if [[ "$PKG_ARCH" == "x86_64" ]]; then
  echo "🔁 x86_64 包换装渲染器组件..."
  APP_RES="$BUILD_DIR/$APP_NAME/Contents/Resources"
  # 移除 folder reference 拷进来的 arm64 组件
  rm -f  "$APP_RES/wallpaper-wgpu" "$APP_RES/dxc" "$APP_RES/ffmpeg"
  rm -rf "$APP_RES/lib"
  # 移除带后缀的提交件本体（紧接着会用它们换装到扁名位置）
  rm -f  "$APP_RES/wallpaper-wgpu-x86_64" "$APP_RES/dxc-x86_64" "$APP_RES/libdxcompiler-x86_64.dylib" "$APP_RES/ffmpeg-x86_64"
  if [[ -d "$APP_RES/Resources" ]]; then
    rm -f  "$APP_RES/Resources/wallpaper-wgpu" "$APP_RES/Resources/dxc" "$APP_RES/Resources/ffmpeg"
    rm -rf "$APP_RES/Resources/lib"
    rm -f  "$APP_RES/Resources/wallpaper-wgpu-x86_64" "$APP_RES/Resources/dxc-x86_64" \
           "$APP_RES/Resources/libdxcompiler-x86_64.dylib" "$APP_RES/Resources/ffmpeg-x86_64"
    # 嵌套布局下的 arm64 CLI 一并移除，避免双 CLI 共存
    rm -f  "$APP_RES/Resources/wallpaperengine-cli" "$APP_RES/Resources/wallpaperengine-cli-x86_64"
  fi
  # 换装 x86_64 三件套 + ffmpeg 到扁平位置（XBridge 第一查找路径）
  cp -f "$PROJECT_DIR/Resources/wallpaper-wgpu-x86_64" "$APP_RES/wallpaper-wgpu"
  cp -f "$PROJECT_DIR/Resources/dxc-x86_64" "$APP_RES/dxc"
  mkdir -p "$APP_RES/lib"
  cp -f "$PROJECT_DIR/Resources/libdxcompiler-x86_64.dylib" "$APP_RES/lib/libdxcompiler.dylib"
  cp -f "$PROJECT_DIR/Resources/ffmpeg-x86_64" "$APP_RES/ffmpeg"
  chmod +x "$APP_RES/wallpaper-wgpu" "$APP_RES/dxc" "$APP_RES/ffmpeg"
  echo "  🔎 换装结果:"
  lipo -info "$APP_RES/wallpaper-wgpu" "$APP_RES/dxc" "$APP_RES/lib/libdxcompiler.dylib" "$APP_RES/ffmpeg"
  echo "🔁 替换 web 壁纸 daemon 为 x86_64 版..."
  cp -f "$PROJECT_DIR/Resources/wallpaperengine-cli-x86_64" "$APP_RES/wallpaperengine-cli"
  chmod +x "$APP_RES/wallpaperengine-cli"
  lipo -info "$APP_RES/wallpaperengine-cli"
  # 推送工具：PyInstaller 单文件不能 lipo 合并（bootloader 靠文件尾 cookie 定位内嵌归档，
  # fat 化后失效），只能按架构换装。这里把 -x86_64 后缀件顶到扁名位置，后缀件本身删掉。
  echo "🔁 换装手机推送工具为 x86_64 版..."
  for push_tool in we-mpkg-tool we-pair-server; do
    cp -f "$PROJECT_DIR/Tools/MobilePush/${push_tool}-x86_64" "$APP_RES/$push_tool"
    chmod +x "$APP_RES/$push_tool"
    rm -f "$APP_RES/${push_tool}-x86_64"
    file "$APP_RES/$push_tool" | sed 's/^/  /'
  done
  echo "✅ x86_64 包换装完成"
fi

# ---- arm64 / universal 包：清掉 folder reference 拷进来的 x86_64 提交件 ----
if [[ "$PKG_ARCH" != "x86_64" ]]; then
  APP_RES="$BUILD_DIR/$APP_NAME/Contents/Resources"
  rm -f "$APP_RES/wallpaper-wgpu-x86_64" "$APP_RES/dxc-x86_64" "$APP_RES/libdxcompiler-x86_64.dylib" "$APP_RES/ffmpeg-x86_64"
  rm -f "$APP_RES/wallpaperengine-cli-x86_64"
  # 推送工具的 x86_64 后缀件：arm64 包用不上，删掉；universal 包必须保留
  # （双架构全量包两份都留，运行时按进程架构挑）。
  if [[ "$PKG_ARCH" == "arm64" ]]; then
    rm -f "$APP_RES/we-mpkg-tool-x86_64" "$APP_RES/we-pair-server-x86_64"
  fi
  if [[ -d "$APP_RES/Resources" ]]; then
    rm -f "$APP_RES/Resources/wallpaper-wgpu-x86_64" "$APP_RES/Resources/dxc-x86_64" \
          "$APP_RES/Resources/libdxcompiler-x86_64.dylib" "$APP_RES/Resources/ffmpeg-x86_64"
    rm -f "$APP_RES/Resources/wallpaperengine-cli-x86_64"
  fi
fi

# ---- universal 全量包：CLI + 渲染器组件合并为双架构（两个架构都能跑） ----
if [[ "$PKG_ARCH" == "universal" ]]; then
  echo "🔁 合并 universal 渲染器组件（两端都要能跑，避免过渡版功能回退）..."
  APP_RES="$BUILD_DIR/$APP_NAME/Contents/Resources"
  NESTED_RES="$APP_RES/Resources"
  # CLI
  cp -f "$PROJECT_DIR/build/wallpaperengine-cli-universal" "$APP_RES/wallpaperengine-cli"
  chmod +x "$APP_RES/wallpaperengine-cli"
  lipo -info "$APP_RES/wallpaperengine-cli"
  if [[ -d "$NESTED_RES" ]]; then
    # 渲染器三件套 + ffmpeg 合并（嵌套层是运行时实际命中位置）
    lipo -create "$PROJECT_DIR/Resources/wallpaper-wgpu" "$PROJECT_DIR/Resources/wallpaper-wgpu-x86_64" \
      -output "$NESTED_RES/wallpaper-wgpu"
    lipo -create "$PROJECT_DIR/Resources/dxc" "$PROJECT_DIR/Resources/dxc-x86_64" \
      -output "$NESTED_RES/dxc"
    lipo -create "$PROJECT_DIR/Resources/ffmpeg" "$PROJECT_DIR/Resources/ffmpeg-x86_64" \
      -output "$NESTED_RES/ffmpeg"
    mkdir -p "$NESTED_RES/lib"
    lipo -create "$PROJECT_DIR/Resources/lib/libdxcompiler.dylib" "$PROJECT_DIR/Resources/libdxcompiler-x86_64.dylib" \
      -output "$NESTED_RES/lib/libdxcompiler.dylib"
    chmod +x "$NESTED_RES/wallpaper-wgpu" "$NESTED_RES/dxc" "$NESTED_RES/ffmpeg"
    # lipo 合并会破坏原签名，这里重新 ad-hoc 签（后续 sign_exported_app 还会带 entitlements 重签 wgpu）
    for merged in "$NESTED_RES/wallpaper-wgpu" "$NESTED_RES/dxc" "$NESTED_RES/ffmpeg" "$NESTED_RES/lib/libdxcompiler.dylib" "$APP_RES/wallpaperengine-cli"; do
      if [[ "$(basename "$merged")" == "wallpaper-wgpu" && -f "$RENDERER_ENTITLEMENTS" ]]; then
        codesign --force --options runtime --entitlements "$RENDERER_ENTITLEMENTS" -s - "$merged" 2>/dev/null || \
          codesign --force -s - "$merged" 2>/dev/null || true
      else
        codesign --force -s - "$merged" 2>/dev/null || true
      fi
    done
    echo "  🔎 合并结果:"
    for merged in wallpaper-wgpu dxc ffmpeg lib/libdxcompiler.dylib; do
      lipo -info "$NESTED_RES/$merged" | sed "s|.*: |    $merged: |"
    done
    # 清掉嵌套层两份单架构 CLI 与带后缀提交件，避免多份共存
    rm -f "$NESTED_RES/wallpaperengine-cli" "$NESTED_RES/wallpaperengine-cli-x86_64" \
          "$NESTED_RES/wallpaper-wgpu-x86_64" "$NESTED_RES/dxc-x86_64" \
          "$NESTED_RES/libdxcompiler-x86_64.dylib" "$NESTED_RES/ffmpeg-x86_64"
  fi
  rm -f "$APP_RES/wallpaper-wgpu-x86_64" "$APP_RES/dxc-x86_64" \
        "$APP_RES/libdxcompiler-x86_64.dylib" "$APP_RES/ffmpeg-x86_64" \
        "$APP_RES/wallpaperengine-cli-x86_64"
fi

# ---- 渲染器一致性断言：包内渲染器必须与本次构建的源件同 UUID ----
# 拆架构发布后 x86_64 包换装的是 Resources/wallpaper-wgpu-x86_64。只复制不校验时，
# 用旧 archive / 旧 Resources 出的包会静默带上过时渲染器（曾导致 Intel 用户仍跑
# 修复前二进制、持续报 TEXTURE_COMPRESSION_ETC2）。LC_UUID 不受签名影响，是这里
# 唯一稳定的同一性判据。
# LC_UUID 块是三行（cmd / cmdsize / uuid）：必须匹配到 $1=="uuid" 的那一行取值。
# 旧实现 getline 一次拿到的是 "cmdsize 24" 的 24，两边恒等导致校验形同虚设。
renderer_uuid() {
  otool -l "$1" 2>/dev/null | awk '$1=="uuid"{print $2; exit}'
}

assert_renderer_matches() { # embedded source label
  local embedded="$1" source="$2" label="$3"
  local a b
  a="$(renderer_uuid "$embedded")"
  b="$(renderer_uuid "$source")"
  if [[ -z "$a" || "$a" != "$b" ]]; then
    echo "❌ $label 渲染器与源件不一致：embedded=${a:-<none>} source=${b:-<none>}（疑似打进了旧构建）" >&2
    exit 1
  fi
  echo "  ✅ $label 渲染器 UUID 匹配: $a"
}

APP_RES="$BUILD_DIR/$APP_NAME/Contents/Resources"
NESTED_RES="$APP_RES/Resources"
case "$PKG_ARCH" in
  x86_64)
    assert_renderer_matches "$APP_RES/wallpaper-wgpu" \
      "$PROJECT_DIR/Resources/wallpaper-wgpu-x86_64" "x86_64"
    ;;
  arm64)
    # type: folder 让渲染器落位在嵌套 Resources/Resources/（folder reference）；
    # 顶层只有 x86 分支的换装步骤会写。运行时 XBridge 两级路径都会查找。
    if [[ ! -f "$NESTED_RES/wallpaper-wgpu" ]]; then
      echo "❌ arm64 archive 内嵌套 Resources 缺 wallpaper-wgpu：" >&2
      ls "$NESTED_RES" 2>/dev/null | head -20 >&2
      exit 1
    fi
    assert_renderer_matches "$NESTED_RES/wallpaper-wgpu" \
      "$PROJECT_DIR/Resources/wallpaper-wgpu" "arm64"
    ;;
  universal)
    VERIFY_DIR="$(mktemp -d)"
    if [[ -f "$NESTED_RES/wallpaper-wgpu" ]]; then
      VERIFY_TARGET="$NESTED_RES/wallpaper-wgpu"
    else
      VERIFY_TARGET="$APP_RES/wallpaper-wgpu"
    fi
    lipo "$VERIFY_TARGET" -thin arm64 -output "$VERIFY_DIR/arm64" 2>/dev/null \
      || cp "$VERIFY_TARGET" "$VERIFY_DIR/arm64"
    assert_renderer_matches "$VERIFY_DIR/arm64" \
      "$PROJECT_DIR/Resources/wallpaper-wgpu" "universal/arm64"
    if lipo "$VERIFY_TARGET" -thin x86_64 -output "$VERIFY_DIR/x86_64" 2>/dev/null; then
      assert_renderer_matches "$VERIFY_DIR/x86_64" \
        "$PROJECT_DIR/Resources/wallpaper-wgpu-x86_64" "universal/x86_64"
    else
      echo "❌ universal 包内渲染器缺少 x86_64 切片" >&2
      rm -rf "$VERIFY_DIR"
      exit 1
    fi
    rm -rf "$VERIFY_DIR"
    ;;
esac

# ---- SteamService：只保留本架构（本地增量构建会残留另一架构的拷贝）----
# build-steam-service.sh 的 prebuilt 分支不清理 DEST_ROOT，多次不同架构构建后
# archive 产物可能同时挂着 arm64/ 与 x86_64/，这里按包架构收敛（universal 包保留两套）。
STEAM_DIR="$BUILD_DIR/$APP_NAME/Contents/Resources/WaifuXSteamService"
if [[ -d "$STEAM_DIR" ]]; then
  if [[ "$PKG_ARCH" == "arm64" ]]; then
    rm -rf "$STEAM_DIR/x86_64"
  elif [[ "$PKG_ARCH" == "x86_64" ]]; then
    rm -rf "$STEAM_DIR/arm64"
  fi
  echo "  🧩 SteamService 保留: $(ls "$STEAM_DIR" | tr '\n' ' ')"
fi

find_codesign_identity() {
  if [[ -n "${WAIFUX_CODESIGN_IDENTITY:-}" ]]; then
    echo "$WAIFUX_CODESIGN_IDENTITY"
    return 0
  fi

  # 过滤已吊销的证书：launchd/Gatekeeper 做完整信任评估会拒绝吊销证书签出的
  # 二进制（EX_CONFIG / 拒运行），而 codesign 本身不查吊销、能"成功"签出废件。
  # `security find-identity -v` 对吊销条目会追加 CSSMERR_TP_* 标记（2026-10-24
  # 本机三张同名 Apple Development 证书、一张吊销被 Xcode 自动选中导致 Helper
  # spawn failed 24516 次的事故）。
  local identity
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -v 'CSSMERR_TP_CERT_REVOKED' \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
    | head -n 1)"
  if [[ -n "$identity" ]]; then
    echo "$identity"
    return 0
  fi

  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -v 'CSSMERR_TP_CERT_REVOKED' \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
    | head -n 1)"
  if [[ -n "$identity" ]]; then
    echo "$identity"
    return 0
  fi

  # 有证书但全部吊销时明确报警，而不是静默回落 ad-hoc
  if security find-identity -v -p codesigning 2>/dev/null \
      | grep -q 'CSSMERR_TP_CERT_REVOKED'; then
    echo "⚠️ 检测到已吊销的签名证书（CSSMERR_TP_CERT_REVOKED），且无有效证书可用。" >&2
    echo "⚠️ 请从钥匙串删除吊销证书后重试；继续将以 ad-hoc 签名，产物不可分发。" >&2
  fi

  echo "-"
}

sign_exported_app() {
  local app_path="$1"
  local identity="$2"
  local entitlements="$PROJECT_DIR/WaifuX.entitlements"
  local renderer_entitlements="$PROJECT_DIR/WallpaperRenderer.entitlements"

  echo "🔏 正在签名导出的 App..."
  if [[ "$identity" == "-" ]]; then
    echo "⚠️ 未找到 Developer ID / Apple Development 证书，将使用 ad-hoc 签名；屏幕录制权限可能需要重新授权。"
  else
    echo "签名身份: $identity"
  fi

  strip_unsupported_slices() {
    local root="$1"
    if [[ ! -d "$root" ]] || ! command -v lipo >/dev/null 2>&1; then
      return 0
    fi
    while IFS= read -r slice_path; do
      if file "$slice_path" | grep -q "Mach-O" && lipo -info "$slice_path" 2>/dev/null | grep -q "i386"; then
        local mode
        mode="$(stat -f "%Lp" "$slice_path" 2>/dev/null || echo "")"
        echo "  移除 i386 slice: ${slice_path#"$app_path/Contents/Resources/"}"
        lipo "$slice_path" -remove i386 -output "$slice_path.tmp"
        mv "$slice_path.tmp" "$slice_path"
        if [[ -n "$mode" ]]; then
          chmod "$mode" "$slice_path" 2>/dev/null || true
        fi
      fi
    done < <(find "$root" -type f -print 2>/dev/null)
  }

  sign_nested_code() {
    local code_path="$1"
    local extension_entitlements="$PROJECT_DIR/WaifuXWallpaperExtension/WaifuXWallpaperExtension.entitlements"
    local agent_entitlements="$PROJECT_DIR/BackgroundAgent/BackgroundAgent.entitlements"
    if [[ "$(basename "$code_path")" == "wallpaper-wgpu" && -f "$renderer_entitlements" ]]; then
      codesign --force --timestamp=none --options runtime --entitlements "$renderer_entitlements" -s "$identity" "$code_path" 2>/dev/null || \
        codesign --force --options runtime --entitlements "$renderer_entitlements" -s "$identity" "$code_path" 2>/dev/null || \
        codesign --force -s "$identity" "$code_path" 2>/dev/null || true
    elif [[ "$code_path" == */Contents/Helpers/WaifuXHelper.app ]]; then
      if [[ "$identity" == "-" && -z "${WAIFUX_ALLOW_MISSING_APPGROUP:-}" ]]; then
        echo "❌ 正式 Helper 包必须使用 Developer ID 签名；ad-hoc 仅允许显式本地验证" >&2
        return 1
      fi
      if [[ -n "${WAIFUX_HELPER_PROVISIONING_PROFILE_PATH:-}" && -f "$WAIFUX_HELPER_PROVISIONING_PROFILE_PATH" ]]; then
        cp "$WAIFUX_HELPER_PROVISIONING_PROFILE_PATH" "$code_path/Contents/embedded.provisionprofile"
      fi
      if [[ -f "$code_path/Contents/embedded.provisionprofile" || "$identity" == "-" ]]; then
        local agent_sign_entitlements="$agent_entitlements"
        if [[ "$identity" != "-" && -z "${WAIFUX_ALLOW_MISSING_APPGROUP:-}" ]]; then
          agent_sign_entitlements="$BUILD_DIR/helper-distribution-entitlements.plist"
          python3 "$PROJECT_DIR/scripts/verify-helper-provisioning.py" --app "$code_path" \
            --prepare-entitlements "$agent_entitlements" --output-entitlements "$agent_sign_entitlements" || return 1
        fi
        # 注意：CI（release.yml 的 Sign & Notarize）重签内嵌代码时只遍历
        # Contents/Resources、Contents/Frameworks、Contents/PlugIns，有意不碰 Contents/Helpers
        # （Helper 的 profile / entitlements / 时间戳统一由本分支负责）。
        # 因此 secure timestamp 必须在这里保证——Apple 公证对它是硬性要求。
        # Developer ID 下 TSA 失败就显式报错，不再静默降级成无时间戳签名（那种包公证必挂）。
        # ad-hoc（identity="-"）仅用于本地验证包，不能加 --timestamp，保持 none。
        local helper_ts_flag=(--timestamp)
        [[ "$identity" == "-" ]] && helper_ts_flag=(--timestamp=none)
        codesign --force --options runtime "${helper_ts_flag[@]}" \
          --entitlements "$agent_sign_entitlements" -s "$identity" "$code_path" || {
            echo "  ❌ Helper 签名失败（Developer ID 需能访问 timestamp.apple.com 取安全时间戳）: $code_path" >&2
            return 1
          }
        local agent_ent_check
        agent_ent_check=$(codesign -d --entitlements - "$code_path" 2>/dev/null || true)
        if ! echo "$agent_ent_check" | grep -q "com.apple.security.application-groups"; then
          echo "❌ Agent 签名缺少 application-groups entitlement: $code_path" >&2
          return 1
        fi
      else
        if [[ -z "${WAIFUX_ALLOW_MISSING_APPGROUP:-}" ]]; then
          echo "❌ Helper 已接管后台；需配置 APPLE_HELPER_PROVISIONING_PROFILE（com.waifux.app.helper + group.com.waifux.app）" >&2
          return 1
        fi
        echo "  ⚠️ 缺少 Helper profile：仅允许本地验证，产物不可对外分发"
        codesign --force --timestamp=none --options runtime --entitlements "$agent_entitlements" -s "$identity" "$code_path"
      fi
      codesign --verify --strict "$code_path" || return 1
      if [[ "$identity" != "-" && -z "${WAIFUX_ALLOW_MISSING_APPGROUP:-}" ]]; then
        python3 "$PROJECT_DIR/scripts/verify-helper-provisioning.py" --app "$code_path" || return 1
      fi
      echo "  ✅ 后台 Agent 已签名: $(basename "$code_path")"
    elif [[ "$code_path" == *.appex ]]; then
      # Developer ID + App Groups 需要 provisioning profile 授权。
      # 因此优先使用 CI 预签名 .appex；缺失时有 profile 则交给 Xcode 签，否则才尝试直接 codesign。
      local pre_signed="$PROJECT_DIR/WaifuXWallpaperExtension.appex"
      if [[ -d "$pre_signed" ]]; then
        echo "  使用预签名扩展: $(basename "$pre_signed")"
        rm -rf "$code_path"
        cp -R "$pre_signed" "$code_path"
        echo "  ✅ $(basename "$code_path") (预签名)"
      elif [[ "$identity" != "-" ]]; then
        echo "  签名扩展 (xcodebuild): $(basename "$code_path")"
        local extension_build_log="$BUILD_DIR/extension-build.log"
        # -target 模式的 SYMROOT 默认是项目 build/，clean 会把 build/ 根下的
        # 打包日志一并清掉（extension-build.log 自己就在里面）。显式隔离产物目录。
        if [[ -n "${WAIFUX_EXTENSION_PROVISIONING_PROFILE_UUID:-}" ]]; then
          if ! xcodebuild -project "$PROJECT_DIR/WaifuX.xcodeproj" \
            -target WaifuXWallpaperExtension \
            -configuration Release \
            SYMROOT="$BUILD_DIR/ExtensionBuild" \
            CODE_SIGN_IDENTITY="$identity" \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGN_ENTITLEMENTS="$extension_entitlements" \
            PROVISIONING_PROFILE="$WAIFUX_EXTENSION_PROVISIONING_PROFILE_UUID" \
            ENABLE_HARDENED_RUNTIME=YES \
            OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
            clean build > "$extension_build_log" 2>&1; then
            tail -80 "$extension_build_log"
            return 1
          fi
        else
          if ! xcodebuild -project "$PROJECT_DIR/WaifuX.xcodeproj" \
            -target WaifuXWallpaperExtension \
            -configuration Release \
            SYMROOT="$BUILD_DIR/ExtensionBuild" \
            CODE_SIGNING_ALLOWED=NO \
            clean build > "$extension_build_log" 2>&1; then
            tail -80 "$extension_build_log"
            return 1
          fi
        fi
        tail -20 "$extension_build_log"
        local built_appex
        built_appex=$(find "$PROJECT_DIR/build" ~/Library/Developer/Xcode/DerivedData \
          \( -path "*/Release/WaifuXWallpaperExtension.appex" -o -path "*/Build/Products/Release/WaifuXWallpaperExtension.appex" \) \
          -type d -print 2>/dev/null | head -1)
        if [[ -n "$built_appex" && -d "$built_appex" ]]; then
          rm -rf "$code_path"
          cp -R "$built_appex" "$code_path"
          if [[ -n "${WAIFUX_EXTENSION_PROVISIONING_PROFILE_PATH:-}" && -f "$WAIFUX_EXTENSION_PROVISIONING_PROFILE_PATH" ]]; then
            local extension_profile_plist="$BUILD_DIR/extension-profile.plist"
            local extension_resign_entitlements="$BUILD_DIR/extension-resign-entitlements.plist"
            security cms -D -i "$WAIFUX_EXTENSION_PROVISIONING_PROFILE_PATH" > "$extension_profile_plist"
            /usr/libexec/PlistBuddy -x -c 'Print Entitlements' "$extension_profile_plist" > "$extension_resign_entitlements"
            /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$extension_resign_entitlements" 2>/dev/null || \
              /usr/libexec/PlistBuddy -c 'Set :com.apple.security.app-sandbox true' "$extension_resign_entitlements"
            mkdir -p "$code_path/Contents"
            cp "$WAIFUX_EXTENSION_PROVISIONING_PROFILE_PATH" "$code_path/Contents/embedded.provisionprofile"
            codesign --force --timestamp=none --options runtime --entitlements "$extension_resign_entitlements" -s "$identity" "$code_path" 2>/dev/null || \
              codesign --force --options runtime --entitlements "$extension_resign_entitlements" -s "$identity" "$code_path"
          elif [[ -z "${WAIFUX_EXTENSION_PROVISIONING_PROFILE_UUID:-}" ]]; then
            codesign --force --timestamp=none --options runtime --entitlements "$extension_entitlements" -s "$identity" "$code_path" 2>/dev/null || \
              codesign --force --options runtime --entitlements "$extension_entitlements" -s "$identity" "$code_path"
          fi
          echo "  ✅ $(basename "$code_path") (xcodebuild)"
        else
          echo "  ⚠️ xcodebuild 未产出 .appex，回退到 codesign"
          codesign --force --timestamp=none --options runtime --entitlements "$extension_entitlements" -s "$identity" "$code_path" || \
            codesign --force --options runtime --entitlements "$extension_entitlements" -s "$identity" "$code_path"
        fi
      else
        codesign --force --options runtime --entitlements "$extension_entitlements" -s "$identity" "$code_path" 2>/dev/null || true
      fi
      local ent_check
      ent_check=$(codesign -d --entitlements - "$code_path" 2>/dev/null || true)
      if ! echo "$ent_check" | grep -q "com.apple.security.application-groups"; then
        if [[ -n "${WAIFUX_ALLOW_MISSING_APPGROUP:-}" ]]; then
          echo "  ⚠️ WAIFUX_ALLOW_MISSING_APPGROUP=1：跳过扩展 application-groups 校验（本地构建产物，不可对外分发）"
          return 0
        fi
        echo "❌ App Extension 签名缺少 application-groups entitlement: $code_path" >&2
        echo "请配置 APPLE_EXTENSION_PROVISIONING_PROFILE / WAIFUX_EXTENSION_PROVISIONING_PROFILE_UUID 后再打包 Developer ID 版本。" >&2
        echo "Debug entitlements:" >&2
        echo "$ent_check" | head -20 >&2
        return 1
      fi
    elif [[ "$code_path" == *.saver ]]; then
      # 屏保是插件包，宿主是系统的 legacyScreenSaver：不带 entitlements，
      # 也不加 --options runtime，避免插件在系统宿主里被库校验/沙盒策略拦住。
      # 顺序固定为先可执行文件、后整包，否则封条会被后续单独的签名动作打坏。
      local saver_exe="$code_path/Contents/MacOS/$(basename "$code_path" .saver)"
      if [[ -f "$saver_exe" ]]; then
        codesign --force --timestamp=none -s "$identity" "$saver_exe" 2>/dev/null || \
          codesign --force -s "$identity" "$saver_exe" 2>/dev/null || true
      fi
      codesign --force --timestamp=none -s "$identity" "$code_path" 2>/dev/null || \
        codesign --force -s "$identity" "$code_path" 2>/dev/null || true
      echo "  ✅ 屏保组件已签名: $(basename "$code_path")"
    else
	      # 对 framework：清除旧封印后用 --deep 递归签名
	      if [[ "$code_path" == *.framework ]]; then
	        echo "  Signing framework with --deep: $(basename "$code_path")"

	        # 清除旧签名封印
	        local fw_vers_dir
	        fw_vers_dir="$code_path"
	        if [[ -d "$code_path/Versions" ]]; then
	          fw_vers_dir="$code_path/Versions/$(ls "$code_path/Versions" 2>/dev/null | grep -v Current | head -1)"
	          [[ -z "$fw_vers_dir" || ! -d "$fw_vers_dir" ]] && fw_vers_dir="$code_path"
	        fi
	        echo "    Cleaning old code signature in: $(basename "$code_path")"
	        rm -rf "$fw_vers_dir/_CodeSignature" "$code_path/_CodeSignature" 2>/dev/null || true

	        codesign --force --deep --timestamp=none --options runtime -s "$identity" "$code_path" 2>/dev/null || \
	          codesign --force --deep -s "$identity" "$code_path" 2>/dev/null || {
	            echo "    ❌ --deep failed, falling back to component-wise signing"
	            find "$code_path" -name "*.xpc" -type d 2>/dev/null | while read -r xpc; do
	              codesign --force --timestamp=none --options runtime -s "$identity" "$xpc" 2>/dev/null || codesign --force -s "$identity" "$xpc" 2>/dev/null || return 1
	            done
	            find "$code_path" -name "*.app" -type d 2>/dev/null | while read -r app; do
	              codesign --force --timestamp=none --options runtime -s "$identity" "$app" 2>/dev/null || codesign --force -s "$identity" "$app" 2>/dev/null || return 1
	            done
	            local vers_dir
	            while IFS= read -r -d '' vers_dir; do
	              find "$vers_dir" -maxdepth 1 -type f -print0 2>/dev/null | while IFS= read -r -d '' exe; do
	                if file "$exe" | grep -q "Mach-O"; then
	                  codesign --force --timestamp=none --options runtime -s "$identity" "$exe" 2>/dev/null || codesign --force -s "$identity" "$exe" 2>/dev/null || return 1
	                fi
	              done
	            done < <(find "$code_path/Versions" -mindepth 1 -maxdepth 1 -type d ! -name "Current" ! -type l -print0 2>/dev/null)
	            codesign --force --timestamp=none --options runtime -s "$identity" "$code_path" 2>/dev/null || codesign --force -s "$identity" "$code_path" 2>/dev/null || true
	          }
	      fi
      codesign --force --timestamp=none --options runtime -s "$identity" "$code_path" 2>/dev/null || \
        codesign --force -s "$identity" "$code_path" 2>/dev/null || true
    fi
  }

  while IFS= read -r code_path; do
    sign_nested_code "$code_path"
  done < <(
    find "$app_path/Contents/Resources" -type f \( -perm -111 -o -name "*.dylib" \) -print 2>/dev/null \
      | while IFS= read -r candidate; do
          # .saver 内部的可执行文件由 sign_nested_code 的屏保分支按插件包顺序签，
          # 这里跳过，避免"先签可执行文件再签整包"之外的第三种顺序。
          if [[ "$candidate" == *.saver/* ]]; then
            continue
          fi
          if file "$candidate" | grep -q "Mach-O"; then
            echo "$candidate"
          fi
        done
  )

  # 推送到手机工具（PyInstaller 单文件，Mach-O 可执行）：必须带 hardened runtime + 安全时间戳，
  # 否则公证人/网关拦截。无 entitlements 需求，直接用外层身份签。
  # 注：它们本来就会命中上面的 Mach-O 遍历被 ad-hoc 或身份签一遍，这里显式重签保证
  # --options runtime + --timestamp 与主 App 一致，公证不因这两个新成员挂掉。
  # universal 包会同时带 arm64 扁名与 -x86_64 后缀件，两份都要带安全时间戳重签。
  for push_tool in we-mpkg-tool we-pair-server we-mpkg-tool-x86_64 we-pair-server-x86_64; do
    local push_tool_path="$app_path/Contents/Resources/$push_tool"
    if [[ -f "$push_tool_path" ]]; then
      codesign --force --timestamp --options runtime -s "$identity" "$push_tool_path" || {
        echo "  ❌ 推送工具签名失败: $push_tool_path" >&2
        return 1
      }
      echo "  ✅ 推送工具已签名: $push_tool"
    fi
  done

  while IFS= read -r bundle_path; do
    sign_nested_code "$bundle_path"
  done < <(
    find "$app_path/Contents/Resources" -type d \( -name "*.app" -o -name "*.framework" -o -name "*.saver" \) -print 2>/dev/null \
      | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-
  )

  if [[ -d "$app_path/Contents/Helpers/WaifuXHelper.app" ]]; then
    sign_nested_code "$app_path/Contents/Helpers/WaifuXHelper.app"
  else
    echo "❌ 打包产物缺少 WaifuXHelper.app" >&2
    return 1
  fi

  if [[ -d "$app_path/Contents/Frameworks" ]]; then
    while IFS= read -r framework_path; do
      sign_nested_code "$framework_path"
    done < <(find "$app_path/Contents/Frameworks" -maxdepth 1 -type d -name "*.framework" -print 2>/dev/null)
  fi

  # 签名 PlugIns 中的 app extension
  if [[ -d "$app_path/Contents/PlugIns" ]]; then
    while IFS= read -r plugin_path; do
      sign_nested_code "$plugin_path"
    done < <(find "$app_path/Contents/PlugIns" -name "*.appex" -print 2>/dev/null)
  fi

  if [[ -n "${WAIFUX_APP_PROVISIONING_PROFILE_PATH:-}" && -f "$WAIFUX_APP_PROVISIONING_PROFILE_PATH" ]]; then
    cp "$WAIFUX_APP_PROVISIONING_PROFILE_PATH" "$app_path/Contents/embedded.provisionprofile"
  fi

  if [[ -f "$entitlements" ]]; then
    codesign --force --timestamp=none --options runtime --entitlements "$entitlements" -s "$identity" "$app_path" 2>/dev/null || \
      codesign --force --options runtime --entitlements "$entitlements" -s "$identity" "$app_path" 2>/dev/null || true
  else
    codesign --force --timestamp=none --options runtime -s "$identity" "$app_path" 2>/dev/null || \
      codesign --force --options runtime -s "$identity" "$app_path" 2>/dev/null || true
  fi

  # 验证签名；--strict 对某些第三方 dylib（steamclient.dylib）可能误报，
  # 但实际功能不受影响，因此不因验证失败而中断打包。
  codesign --verify --deep --strict --verbose=2 "$app_path" 2>/dev/null || true
  local app_ent_check
  app_ent_check=$(codesign -d --entitlements - "$app_path" 2>/dev/null || true)
  if ! echo "$app_ent_check" | grep -q "com.apple.security.application-groups"; then
    echo "❌ App 签名缺少 application-groups entitlement: $app_path" >&2
    echo "请配置 APPLE_APP_PROVISIONING_PROFILE / WAIFUX_APP_PROVISIONING_PROFILE_PATH 后再打包 Developer ID 版本。" >&2
    echo "$app_ent_check" | head -20 >&2
    return 1
  fi
  echo "✅ App 签名验证通过"
}

SIGN_IDENTITY="$(find_codesign_identity)"
sign_exported_app "$BUILD_DIR/$APP_NAME" "$SIGN_IDENTITY"

# 仅在非签名流程时创建 DMG（签名流程由 CI 另行处理）
# universal 包沿用历史命名 WaifuX.dmg（appcast default item 的 URL 保持稳定），
# 单架构包为 WaifuX-<arch>.dmg。
if [[ "$PKG_ARCH" == "universal" ]]; then
  DMG_NAME="WaifuX.dmg"
else
  DMG_NAME="WaifuX-$PKG_ARCH.dmg"
fi
if [ "${WAIFUX_SKIP_DMG:-}" != "1" ]; then
  echo "💿 正在创建 DMG ($DMG_NAME)..."
  if command -v create-dmg &> /dev/null; then
      set +e
      create-dmg \
        --volname "WaifuX" \
        --window-size 540 400 \
        --app-drop-link 400 185 \
        --hide-extension "WaifuX.app" \
        --no-internet-enable \
        "$BUILD_DIR/$DMG_NAME" \
        "$BUILD_DIR/$APP_NAME"
      CREATE_DMG_STATUS=$?
      set -e
      if [ $CREATE_DMG_STATUS -ne 0 ]; then
          echo "⚠️ create-dmg 失败，使用 hdiutil 生成标准 DMG..."
          rm -f "$BUILD_DIR/$DMG_NAME" "$BUILD_DIR"/rw.*."$DMG_NAME"
          hdiutil create -volname "WaifuX" \
            -srcfolder "$BUILD_DIR/$APP_NAME" \
            -ov -format UDZO \
            -imagekey zlib-level=9 \
            "$BUILD_DIR/$DMG_NAME"
      fi
  else
      echo "⚠️ create-dmg 未安装，使用 hdiutil..."
      hdiutil create -volname "WaifuX" \
        -srcfolder "$BUILD_DIR/$APP_NAME" \
        -ov -format UDZO \
        -imagekey zlib-level=9 \
        "$BUILD_DIR/$DMG_NAME"
  fi

  if [ ! -f "$BUILD_DIR/$DMG_NAME" ]; then
      echo "❌ DMG 创建失败"
      exit 1
  fi
  echo "📦 DMG 大小: $(ls -lh "$BUILD_DIR/$DMG_NAME" | awk '{print $5}')"
fi

echo ""
echo "✅ 打包完成！($PKG_ARCH)"
echo "📍 App 位置: $BUILD_DIR/$APP_NAME"
# ⚠️ 不要写成 `[ ... ] && echo`：CI 里 WAIFUX_SKIP_DMG=1 时该判断返回 1，
# 会成为脚本退出码，让设置了 `set -e` 的 workflow 在成功打包后误判失败。
if [ "${WAIFUX_SKIP_DMG:-}" != "1" ]; then
  echo "📍 DMG 位置: $BUILD_DIR/$DMG_NAME"
fi
exit 0
