#!/bin/bash
# 将 Resources/assets 打成 zip，编译进 wallpaperengine-cli（通过汇编 .incbin 嵌入 Mach-O）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASSETS_DIR="$ROOT/Resources/assets"
SRC_MAIN="$ROOT/wallpaperengine-cli.swift"
SRC_EMBED="$ROOT/WallpaperEngineEmbeddedAssets.swift"
OUT_CLI="$ROOT/Resources/wallpaperengine-cli"
TMP_ZIP="/tmp/waifux-we-assets-$$.zip"
rm -f "$TMP_ZIP"

cleanup() { rm -f "$TMP_ZIP" "$ROOT/Resources/zip_data.s" "$ROOT/Resources/zip_data.o" "$ROOT/Resources/zip_accessor.c" "$ROOT/Resources/zip_accessor.o"; }
trap cleanup EXIT

if [[ ! -f "$SRC_MAIN" || ! -f "$SRC_EMBED" ]]; then
  echo "error: missing Swift sources" >&2
  exit 1
fi

HAS_ASSETS=false
if [[ -d "$ASSETS_DIR" ]] && [[ -n "$(ls -A "$ASSETS_DIR" 2>/dev/null)" ]]; then
  HAS_ASSETS=true
fi

if [[ "$HAS_ASSETS" == true ]]; then
  echo "[build-wallpaperengine-cli] Zipping assets..."
  ( cd "$ROOT/Resources" && zip -r -q "$TMP_ZIP" assets )
else
  echo "[build-wallpaperengine-cli] 无 assets，构建空资源占位"
  echo -n "" > "$TMP_ZIP"
fi

echo "[build-wallpaperengine-cli] 生成汇编文件嵌入 zip..."
cat > "$ROOT/Resources/zip_data.s" << EOF
	.globl _zip_data_start
	.globl _zip_data_end
_zip_data_start:
	.incbin "$TMP_ZIP"
_zip_data_end:
EOF

as -arch arm64 "$ROOT/Resources/zip_data.s" -o "$ROOT/Resources/zip_data.o"

echo "[build-wallpaperengine-cli] 生成 C bridge..."
cat > "$ROOT/Resources/zip_accessor.c" << 'EOF'
#include <stdint.h>
#include <stddef.h>

extern uint8_t zip_data_start[];
extern uint8_t zip_data_end[];

uint8_t* get_zip_data_ptr(void) { return zip_data_start; }
size_t get_zip_data_size(void) { return (size_t)(zip_data_end - zip_data_start); }
EOF

clang -c "$ROOT/Resources/zip_accessor.c" -o "$ROOT/Resources/zip_accessor.o"

echo "[build-wallpaperengine-cli] swiftc..."
swiftc -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -I Resources/CRenderer -I Resources -L Resources/lib \
  -llinux-wallpaperengine-renderer \
  -Xlinker -stack_size -Xlinker 0x2000000 \
  -Xlinker -rpath -Xlinker @loader_path \
  -Xlinker -rpath -Xlinker @loader_path/Resources \
  -Xlinker -rpath -Xlinker @loader_path/../Resources \
  -Xlinker -rpath -Xlinker @loader_path/Resources/lib \
  -Xlinker -rpath -Xlinker @loader_path/../Resources/lib \
  -Xlinker -rpath -Xlinker @loader_path/lib \
  -framework AppKit -framework AVFoundation -framework IOKit -framework WebKit -framework Combine \
  -o "$OUT_CLI" \
  "$SRC_MAIN" "$SRC_EMBED" \
  "$ROOT/Resources/zip_data.o" "$ROOT/Resources/zip_accessor.o"

if command -v codesign >/dev/null 2>&1; then
  echo "[build-wallpaperengine-cli] codesign (ad hoc)..."
  codesign --force -s - "$OUT_CLI" 2>/dev/null || true
fi

cp "$OUT_CLI" "$ROOT/wallpaperengine-cli"

# Bundle Homebrew dylibs 到 Resources/，避免用户机器上没有 Homebrew 时 dyld 报错
echo "[build-wallpaperengine-cli] Bundling Homebrew dylibs..."
if [[ -f "$ROOT/scripts/bundle-dylibs.py" ]]; then
  python3 "$ROOT/scripts/bundle-dylibs.py" "$ROOT/Resources/lib/liblinux-wallpaperengine-renderer.dylib" "$ROOT/Resources/lib"
  # 重新签名所有被修改过的 dylib
  for f in "$ROOT"/Resources/lib/*.dylib; do
    codesign --force -s - "$f" 2>/dev/null || true
  done
  # 确保 renderer dylib 的 id 是 @rpath/...，让 CLI 能跨位置解析
  install_name_tool -id "@rpath/liblinux-wallpaperengine-renderer.dylib" "$ROOT/Resources/lib/liblinux-wallpaperengine-renderer.dylib" 2>/dev/null || true
  codesign --force -s - "$ROOT/Resources/lib/liblinux-wallpaperengine-renderer.dylib" 2>/dev/null || true

  # 复制 Homebrew Python（libvapoursynth-script 需要），若不存在则尝试从 Homebrew 复制
  if [[ ! -f "$ROOT/Resources/lib/Python" ]]; then
    PYTHON_CANDIDATE="/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python"
    if [[ -f "$PYTHON_CANDIDATE" ]]; then
      cp "$PYTHON_CANDIDATE" "$ROOT/Resources/lib/Python"
      chmod +x "$ROOT/Resources/lib/Python"
      install_name_tool -id "@loader_path/Python" "$ROOT/Resources/lib/Python" 2>/dev/null || true
      codesign --force -s - "$ROOT/Resources/lib/Python" 2>/dev/null || true
      echo "[build-wallpaperengine-cli] Copied Python framework"
    fi
  fi
fi

echo "[build-wallpaperengine-cli] OK → $OUT_CLI"
