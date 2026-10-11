#!/bin/bash
# build-wallpaper-wgpu.sh — 部署 wallpaper-wgpu 渲染器 + DXC + 内嵌 assets
#
# 功能:
#   1. 将预编译的 wallpaper-wgpu 复制到 Resources/
#   2. 将 DXC (dxc + libdxcompiler.dylib) 复制到 Resources/
#   3. 将 Resources/assets/ 打包为 zip，通过汇编 .incbin 嵌入到 Resources/zip_data.o
#      供 WallpaperEngineEmbeddedAssets 在运行时解压
#   4. 签名所有二进制文件
#
# 用法: ./scripts/build-wallpaper-wgpu.sh
# 环境变量:
#   WAIFUX_WGPU_SRC       — wallpaper-wgpu 来源路径（默认 ~/Downloads/wallpaper-wgpu）
#   WAIFUX_DXC_SRC        — dxc 来源路径（默认 ~/Desktop/dxc）
#   WAIFUX_DXC_DYLIB_SRC  — libdxcompiler.dylib 来源路径（默认 ~/Desktop/libdxcompiler.dylib）
#   WAIFUX_FORCE_EMBED_ASSETS — 设为 1 时强制重新生成内嵌 assets

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEST_DIR="$ROOT/Resources"
DEST_LIB_DIR="$DEST_DIR/lib"
RENDERER_ENTITLEMENTS="$ROOT/WallpaperRenderer.entitlements"
mkdir -p "$DEST_DIR" "$DEST_LIB_DIR"

echo "🔧 wallpaper-wgpu 部署开始..."

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
          echo "  ⚠️  ffmpeg 依赖未捆绑: $dep_base"
        fi
        ;;
    esac
  done < <(otool -L "$ffmpeg_bin" 2>/dev/null | awk 'NR > 1 { print $1 }')

  if [[ "$changed" == true ]]; then
    codesign --force --sign - "$ffmpeg_bin" 2>/dev/null || true
    echo "  ✅ ffmpeg dylib 路径已改为 @loader_path/lib"
  fi
}

# ── 1. 复制 wallpaper-wgpu（arm64）──────────────────────────────
# 优先渲染器仓库的分发目录 dist-aarch64/（与 dist-x86_64/ 成套，含同批构建的 dxc/ffmpeg）；
# 其次 target/release 等历史位置。
DIST_AARCH64="${WAIFUX_WGPU_DIST_AARCH64:-/Volumes/mac/CodeLibrary/Claude/wallpaper-wgpu/dist-aarch64}"
WGUI_SRC="${WAIFUX_WGPU_SRC:-}"
if [[ -z "$WGUI_SRC" ]]; then
  for candidate in \
    "$DIST_AARCH64/wallpaper-wgpu" \
    "/Volumes/mac/CodeLibrary/Claude/wallpaper-wgpu/target/release/wallpaper-wgpu" \
    "$HOME/Downloads/wallpaper-wgpu" \
    "$ROOT/wallpaper-wgpu"; do
    if [[ -f "$candidate" ]]; then
      WGUI_SRC="$candidate"
      break
    fi
  done
fi
if [[ -n "$WGUI_SRC" && -f "$WGUI_SRC" ]]; then
  cp "$WGUI_SRC" "$DEST_DIR/wallpaper-wgpu"
  chmod +x "$DEST_DIR/wallpaper-wgpu"
  echo "  ✅ wallpaper-wgpu → $DEST_DIR/wallpaper-wgpu"
elif [[ -f "$DEST_DIR/wallpaper-wgpu" ]]; then
  echo "  ⚠️  wallpaper-wgpu 源未找到，保留已有 $DEST_DIR/wallpaper-wgpu"
else
  echo "  ⚠️  wallpaper-wgpu 未找到，跳过复制"
fi

# ── 1.1 复制 x86_64 渲染器三件套（拆架构分发：x86_64 包换装用） ──
# 来源优先渲染器仓库的 dist-x86_64/ 分发目录（wallpaper-wgpu + dxc + libdxcompiler.dylib）。
# 产出带 -x86_64 后缀的提交件，不覆盖 arm64 扁名文件；package.sh 打 x86 包时换装。
WGPU_DIST_X86="${WAIFUX_WGPU_DIST_X86:-/Volumes/mac/CodeLibrary/Claude/wallpaper-wgpu/dist-x86_64}"
if [[ -d "$WGPU_DIST_X86" ]]; then
  for pair in "wallpaper-wgpu:wallpaper-wgpu-x86_64" "dxc:dxc-x86_64" "libdxcompiler.dylib:libdxcompiler-x86_64.dylib"; do
    src_name="${pair%%:*}"
    dst_name="${pair##*:}"
    if [[ -f "$WGPU_DIST_X86/$src_name" ]]; then
      cp "$WGPU_DIST_X86/$src_name" "$DEST_DIR/$dst_name"
      chmod +x "$DEST_DIR/$dst_name"
      echo "  ✅ $src_name (x86_64) → $DEST_DIR/$dst_name"
    else
      echo "  ⚠️  $WGPU_DIST_X86/$src_name 不存在，保留已有 $dst_name"
    fi
  done
else
  echo "  ⚠️  未找到 $WGPU_DIST_X86，x86_64 渲染器组件跳过部署"
fi

# ── 1.5 复制 ffmpeg（web 壁纸离线烘焙的音频 mux 用） ────────────
# 优先使用静态单文件版（无 lib/ 闭包依赖，可随包分发）：
#   arm64  源：$WAIFUX_FFMPEG_SRC → /tmp/ff-out-arm64/ffmpeg-arm64 → homebrew 动态版兜底
#   x86_64 源：$WAIFUX_FFMPEG_X86_SRC → /tmp/ff-out-x86_64/ffmpeg-x86_64
# 静态版能力集：mp4 demux/mux + 内置音频解码 + volume/apad filter + aac 编码（视频走 -c:v copy）。
deploy_ffmpeg() {
  local arch="$1" dest="$2" src_env="$3"
  local dist_arch="x86_64"
  [[ "$arch" == "arm64" ]] && dist_arch="aarch64"
  local dist_dir="${WAIFUX_WGPU_DIST_ROOT:-/Volumes/mac/CodeLibrary/Claude/wallpaper-wgpu}/dist-$dist_arch"
  # 候选顺序：显式 env → 渲染器仓库 dist-<arch>/ffmpeg（与同批 wgpu 配套）→ 本地静态构建 → homebrew（仅 arm64 兜底）
  local candidates=("$src_env" "$dist_dir/ffmpeg")
  if [[ "$arch" == "arm64" ]]; then
    candidates+=("/tmp/ff-out-arm64/ffmpeg-arm64" "/opt/homebrew/bin/ffmpeg")
  else
    candidates+=("/tmp/ff-out-x86_64/ffmpeg-x86_64")
  fi
  local src=""
  local candidate
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -f "$candidate" ]] || continue
    src="$candidate"
    break
  done
  if [[ -z "$src" ]]; then
    echo "  ⚠️  ffmpeg ($arch) 源未找到，跳过部署"
    return 0
  fi
  # homebrew 路径是符号链接，解析真实路径
  if [[ -L "$src" ]]; then
    src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
    if [[ -L "$src" ]]; then
      src="$(stat -f%R "$src" 2>/dev/null || echo "$src")"
    fi
  fi
  cp "$src" "$dest"
  chmod +x "$dest"
  # 仅动态版需要把 /opt/homebrew 依赖改写成 @loader_path/lib
  if otool -L "$dest" 2>/dev/null | tail -n +2 | grep -q "/opt/homebrew"; then
    fix_ffmpeg_install_names "$dest" "$DEST_LIB_DIR"
    echo "  ✅ ffmpeg ($arch, 动态) → $dest（依赖 lib/）"
  else
    echo "  ✅ ffmpeg ($arch, 静态) → $dest"
  fi
}

deploy_ffmpeg arm64 "$DEST_DIR/ffmpeg" "${WAIFUX_FFMPEG_SRC:-}"
deploy_ffmpeg x86_64 "$DEST_DIR/ffmpeg-x86_64" "${WAIFUX_FFMPEG_X86_SRC:-}"

# ── 2. 复制 DXC ─────────────────────────────────────────────────
DXC_SRC="${WAIFUX_DXC_SRC:-}"
DXC_DYLIB_SRC="${WAIFUX_DXC_DYLIB_SRC:-}"

# 如果未指定源路径，尝试多个位置
if [[ -z "$DXC_SRC" ]]; then
  for candidate in \
    "$DIST_AARCH64/dxc" \
    "$HOME/Desktop/dxc" \
    "$ROOT/Resources/dxc" \
    "/opt/homebrew/bin/dxc"; do
    if [[ -f "$candidate" ]]; then
      DXC_SRC="$candidate"
      break
    fi
  done
fi

if [[ -z "$DXC_DYLIB_SRC" ]]; then
  for candidate in \
    "$DIST_AARCH64/libdxcompiler.dylib" \
    "$HOME/Desktop/libdxcompiler.dylib" \
    "$ROOT/Resources/lib/libdxcompiler.dylib" \
    "/opt/homebrew/lib/libdxcompiler.dylib"; do
    if [[ -f "$candidate" ]]; then
      DXC_DYLIB_SRC="$candidate"
      break
    fi
  done
fi

# 如果 Resources 下已存在且未指定源，跳过复制
# 分发目录（dist-aarch64）里的组件总是覆盖部署：用户更新分发版后必须同步；
# 其余来源沿用「已存在则跳过」的增量语义。
if [[ -f "$DEST_DIR/dxc" && -z "${WAIFUX_DXC_SRC:-}" && "$DXC_SRC" != "$DIST_AARCH64/dxc" ]]; then
  echo "  ✅ dxc 已存在，跳过复制"
elif [[ -n "$DXC_SRC" && -f "$DXC_SRC" ]]; then
  cp "$DXC_SRC" "$DEST_DIR/dxc"
  chmod +x "$DEST_DIR/dxc"
  # dxc 已有 @executable_path/../lib rpath，但由于 Xcode 的 folder reference
  # 会将 Resources/ 嵌套复制到 .app/Contents/Resources/Resources/ 下，
  # dxc 的 @loader_path/../lib 会指向错误的目录。
  # 添加 @loader_path/lib 以兼容嵌套结构（dxc 与 lib/ 同级）。
  install_name_tool -add_rpath "@loader_path/lib" "$DEST_DIR/dxc" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path/../lib" "$DEST_DIR/dxc" 2>/dev/null || true
  # 重新签名（install_name_tool 会失效签名）
  codesign --force --sign - "$DEST_DIR/dxc" 2>/dev/null || true
  echo "  ✅ dxc → $DEST_DIR/dxc"
else
  echo "  ⚠️  dxc 未找到，跳过复制"
fi

if [[ -f "$DEST_LIB_DIR/libdxcompiler.dylib" && -z "${WAIFUX_DXC_DYLIB_SRC:-}" && "$DXC_DYLIB_SRC" != "$DIST_AARCH64/libdxcompiler.dylib" ]]; then
  echo "  ✅ libdxcompiler.dylib 已存在，跳过复制"
elif [[ -n "$DXC_DYLIB_SRC" && -f "$DXC_DYLIB_SRC" ]]; then
  cp "$DXC_DYLIB_SRC" "$DEST_LIB_DIR/libdxcompiler.dylib"
  chmod +x "$DEST_LIB_DIR/libdxcompiler.dylib"
  echo "  ✅ libdxcompiler.dylib → $DEST_LIB_DIR/libdxcompiler.dylib"
else
  echo "  ⚠️  libdxcompiler.dylib 未找到，跳过复制"
fi

# ── 3. 生成内嵌 assets (.incbin) ─────────────────────────────────
ASSETS_DIR="$ROOT/Resources/assets"
ZIP_DATA_S="$DEST_DIR/zip_data.s"
ZIP_DATA_O="$DEST_DIR/zip_data.o"
ZIP_ACCESSOR_C="$DEST_DIR/zip_accessor.c"
ZIP_ACCESSOR_O="$DEST_DIR/zip_accessor.o"
TMP_ZIP="/tmp/waifux-embedded-assets-$$.zip"
rm -f "$TMP_ZIP"
cleanup() { rm -f "$TMP_ZIP"; }
trap cleanup EXIT

REQUIRED_EMBED_ARCHS=(arm64 x86_64)

object_has_arch() {
  local object_file="$1"
  local arch="$2"
  [[ -f "$object_file" ]] && lipo -info "$object_file" 2>/dev/null | grep -qE "(are:|architecture:) .*\\b${arch}\\b"
}

embedded_objects_are_current() {
  local object_file
  for object_file in "$ZIP_DATA_O" "$ZIP_ACCESSOR_O"; do
    [[ -f "$object_file" ]] || return 1
    local arch
    for arch in "${REQUIRED_EMBED_ARCHS[@]}"; do
      object_has_arch "$object_file" "$arch" || return 1
    done
  done
}

HAS_ASSETS=false
if [[ -d "$ASSETS_DIR" ]] && [[ -n "$(ls -A "$ASSETS_DIR" 2>/dev/null)" ]]; then
  HAS_ASSETS=true
fi

FORCE="${WAIFUX_FORCE_EMBED_ASSETS:-}"
# 如果 .o 已存在且 assets 未变化，跳过重新生成（除非 FORCE=1）
if embedded_objects_are_current && [[ -z "$FORCE" ]]; then
  echo "  🔄 内嵌 assets .o 已存在，跳过（设 WAIFUX_FORCE_EMBED_ASSETS=1 强制重编）"
else
  echo "  📦 生成内嵌 assets..."
  if [[ "$HAS_ASSETS" == true ]]; then
    ( cd "$ROOT/Resources" && zip -r -q "$TMP_ZIP" assets )
    echo "  ✅ assets 打包完成 ($(stat -f%z "$TMP_ZIP") bytes)"
  else
    echo -n > "$TMP_ZIP"
    echo "  ℹ️  无 assets，生成空占位"
  fi

  # 生成汇编 .incbin
  cat > "$ZIP_DATA_S" << EOF
	.globl _zip_data_start
	.globl _zip_data_end
_zip_data_start:
	.incbin "$TMP_ZIP"
_zip_data_end:
EOF

  # 生成 C bridge
  cat > "$ZIP_ACCESSOR_C" << 'EOF'
#include <stdint.h>
#include <stddef.h>

extern uint8_t zip_data_start[];
extern uint8_t zip_data_end[];

uint8_t* get_zip_data_ptr(void) { return zip_data_start; }
size_t get_zip_data_size(void) { return (size_t)(zip_data_end - zip_data_start); }
EOF

  data_objects=()
  accessor_objects=()
  for arch in "${REQUIRED_EMBED_ARCHS[@]}"; do
    data_object="$DEST_DIR/zip_data.${arch}.o"
    accessor_object="$DEST_DIR/zip_accessor.${arch}.o"
    as -arch "$arch" -mmacosx-version-min=14.4 "$ZIP_DATA_S" -o "$data_object"
    clang -arch "$arch" -c -mmacosx-version-min=14.4 "$ZIP_ACCESSOR_C" -o "$accessor_object"
    data_objects+=("$data_object")
    accessor_objects+=("$accessor_object")
  done

  lipo -create "${data_objects[@]}" -output "$ZIP_DATA_O"
  lipo -create "${accessor_objects[@]}" -output "$ZIP_ACCESSOR_O"
  rm -f "${data_objects[@]}" "${accessor_objects[@]}"
  echo "  ✅ zip_data.o / zip_accessor.o 生成（universal）"
fi

# ── 4. 签名 ──────────────────────────────────────────────────────
if command -v codesign >/dev/null 2>&1; then
  echo "  🔏 签名..."
  if [[ -f "$DEST_DIR/wallpaper-wgpu" ]]; then
    if [[ -f "$RENDERER_ENTITLEMENTS" ]]; then
      codesign --force --options runtime --entitlements "$RENDERER_ENTITLEMENTS" -s - "$DEST_DIR/wallpaper-wgpu" 2>/dev/null || \
        codesign --force -s - "$DEST_DIR/wallpaper-wgpu" 2>/dev/null || true
    else
      codesign --force -s - "$DEST_DIR/wallpaper-wgpu" 2>/dev/null || true
    fi
  fi
  if [[ -f "$DEST_DIR/dxc" ]]; then
    codesign --force -s - "$DEST_DIR/dxc" 2>/dev/null || true
  fi
  if [[ -f "$DEST_LIB_DIR/libdxcompiler.dylib" ]]; then
    codesign --force -s - "$DEST_LIB_DIR/libdxcompiler.dylib" 2>/dev/null || true
  fi
  if [[ -f "$DEST_DIR/ffmpeg" ]]; then
    codesign --force -s - "$DEST_DIR/ffmpeg" 2>/dev/null || true
  fi
  for x86_file in "$DEST_DIR/wallpaper-wgpu-x86_64" "$DEST_DIR/dxc-x86_64" "$DEST_DIR/libdxcompiler-x86_64.dylib" "$DEST_DIR/ffmpeg-x86_64"; do
    if [[ -f "$x86_file" ]]; then
      if [[ "$(basename "$x86_file")" == "wallpaper-wgpu-x86_64" && -f "$RENDERER_ENTITLEMENTS" ]]; then
        codesign --force --options runtime --entitlements "$RENDERER_ENTITLEMENTS" -s - "$x86_file" 2>/dev/null || \
          codesign --force -s - "$x86_file" 2>/dev/null || true
      else
        codesign --force -s - "$x86_file" 2>/dev/null || true
      fi
    fi
  done
  echo "  ✅ 签名完成"
fi

# ── 5. 同步到根目录（开发调试用） ──────────────────────────────
if [[ -f "$DEST_DIR/wallpaper-wgpu" ]]; then
  cp "$DEST_DIR/wallpaper-wgpu" "$ROOT/wallpaper-wgpu"
fi

# DXC 属于 wgpu，FFmpeg 属于 web；只为内容变化的组件递增版本。
python3 "$ROOT/scripts/renderer_component_versions.py" --component wgpu web

echo "✅ build-wallpaper-wgpu 完成"
