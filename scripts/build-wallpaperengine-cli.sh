#!/bin/bash
# 将 Resources/assets 打成 zip，链接 wallpaperengine-cli + WallpaperEngineEmbeddedAssets.swift，
# 再把 zip 与 8 字节 little-endian 偏移追加到二进制末尾（材质不再进入 WaifuX.app Resources）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASSETS_DIR="$ROOT/Resources/assets"
SRC_MAIN="$ROOT/wallpaperengine-cli.swift"
SRC_EMBED="$ROOT/WallpaperEngineEmbeddedAssets.swift"
OUT_CLI="$ROOT/Resources/wallpaperengine-cli"
TMP_ZIP="/tmp/waifux-we-assets-$$.zip"
rm -f "$TMP_ZIP"

cleanup() { rm -f "$TMP_ZIP"; }
trap cleanup EXIT

if [[ ! -d "$ASSETS_DIR" ]]; then
  echo "error: missing $ASSETS_DIR" >&2
  exit 1
fi
if [[ ! -f "$SRC_MAIN" || ! -f "$SRC_EMBED" ]]; then
  echo "error: missing Swift sources" >&2
  exit 1
fi

echo "[build-wallpaperengine-cli] Zipping assets..."
( cd "$ROOT/Resources" && zip -r -q "$TMP_ZIP" assets )

echo "[build-wallpaperengine-cli] swiftc..."
swiftc -parse-as-library \
  -I Resources/CRenderer -I Resources -L Resources \
  -llinux-wallpaperengine-renderer \
  -Xlinker -rpath -Xlinker @loader_path \
  -Xlinker -rpath -Xlinker @loader_path/Resources \
  -Xlinker -rpath -Xlinker @loader_path/../Resources \
  -framework AppKit -framework IOKit -framework WebKit -framework Combine \
  -o "$OUT_CLI" \
  "$SRC_MAIN" "$SRC_EMBED"

ORIG_SIZE="$(stat -f%z "$OUT_CLI")"
echo "[build-wallpaperengine-cli] Appending zip (Mach-O size=$ORIG_SIZE)..."
cat "$TMP_ZIP" >> "$OUT_CLI"
python3 -c "import struct,sys; sys.stdout.buffer.write(struct.pack('<Q', $ORIG_SIZE))" >> "$OUT_CLI"

if command -v codesign >/dev/null 2>&1; then
  echo "[build-wallpaperengine-cli] codesign (ad hoc)..."
  codesign --force -s - "$OUT_CLI" 2>/dev/null || true
fi

cp "$OUT_CLI" "$ROOT/wallpaperengine-cli"
echo "[build-wallpaperengine-cli] OK → $OUT_CLI"
