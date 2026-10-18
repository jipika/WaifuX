#!/bin/bash
# 编译 wallpaperengine-cli（web 壁纸 daemon）。
# 注意：assets 嵌入（zip_data.o）由 build-wallpaper-wgpu.sh 负责，CLI 不需要。
#
# 用法: build-wallpaperengine-cli.sh [arch]
#   arch = arm64 | x86_64 | universal（默认 arm64）
#   x86_64 产物写入 Resources/wallpaperengine-cli-x86_64（不覆盖 arm64 提交件），
#   打包脚本会按包架构把它放进 .app 内并命名为 wallpaperengine-cli。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET_ARCH="${1:-arm64}"
case "$TARGET_ARCH" in
  arm64)
    OUT_CLI="$ROOT/Resources/wallpaperengine-cli"
    ;;
  x86_64)
    OUT_CLI="$ROOT/Resources/wallpaperengine-cli-x86_64"
    ;;
  universal)
    # 过渡 universal 包用：lipo 合并两个架构产物。
    # 输出到 build/ 临时目录，不覆盖仓库提交的 arm64-only Resources/wallpaperengine-cli。
    WAIFUX_DEFER_COMPONENT_VERSION=1 "$0" arm64
    WAIFUX_DEFER_COMPONENT_VERSION=1 "$0" x86_64
    mkdir -p "$ROOT/build"
    LIPO_OUT="$ROOT/build/wallpaperengine-cli-universal"
    lipo "$ROOT/Resources/wallpaperengine-cli" "$ROOT/Resources/wallpaperengine-cli-x86_64" \
      -create -output "$LIPO_OUT"
    codesign --force -s - "$LIPO_OUT" 2>/dev/null || true
    python3 "$ROOT/scripts/renderer_component_versions.py" --component web
    echo "[build-wallpaperengine-cli] universal OK → $LIPO_OUT"
    exit 0
    ;;
  *)
    echo "error: unsupported arch '$TARGET_ARCH' (arm64|x86_64|universal)" >&2
    exit 1
    ;;
esac

SRC_MAIN="$ROOT/wallpaperengine-cli.swift"
SRC_PROCESS_IDENTITY="$ROOT/Utilities/OwnedProcessIdentity.swift"

if [[ ! -f "$SRC_MAIN" ]]; then
  echo "error: missing $SRC_MAIN" >&2
  exit 1
fi

echo "[build-wallpaperengine-cli] swiftc ($TARGET_ARCH)..."
# -O -whole-module-optimization：Release 优化，避免 swiftc 默认 -Onone 产出
# 40M+ 的未优化二进制（曾导致发行版 DMG 体积异常膨胀）。
swiftc -parse-as-library \
  -O -whole-module-optimization \
  -target "$TARGET_ARCH-apple-macosx14.4" \
  -Xlinker -stack_size -Xlinker 0x2000000 \
  -Xlinker -rpath -Xlinker @loader_path \
  -Xlinker -rpath -Xlinker @loader_path/Resources \
  -Xlinker -rpath -Xlinker @loader_path/../Resources \
  -framework AppKit -framework AVFoundation -framework IOKit -framework WebKit -framework Combine \
  -o "$OUT_CLI" \
  "$SRC_MAIN" "$SRC_PROCESS_IDENTITY"

# strip 调试与本地符号，进一步减小体积（与仓库已提交的优化版对齐）
strip -x -S "$OUT_CLI" 2>/dev/null || true

# arm64 要求有效代码签名才能执行；linker-signed 的弱签名在替换 strip 后可能失效，
# 表现为进程刚启动就被 SIGKILL（Killed: 9）。这里必须显式重签并验证，
# 不能让失败被静默吞掉——否则产物看起来正常、运行时却起不来。
if command -v codesign >/dev/null 2>&1; then
  echo "[build-wallpaperengine-cli] codesign (ad hoc)..."
  if ! codesign --force -s - "$OUT_CLI"; then
    echo "error: codesign failed for $OUT_CLI" >&2
    exit 1
  fi
  if ! codesign --verify --strict "$OUT_CLI"; then
    echo "error: codesign verify failed for $OUT_CLI" >&2
    exit 1
  fi
fi

if [[ "$TARGET_ARCH" == "arm64" ]]; then
  cp "$OUT_CLI" "$ROOT/wallpaperengine-cli"
fi

if [[ "${WAIFUX_DEFER_COMPONENT_VERSION:-0}" != "1" ]]; then
  python3 "$ROOT/scripts/renderer_component_versions.py" --component web
fi

echo "[build-wallpaperengine-cli] OK ($TARGET_ARCH) → $OUT_CLI"
