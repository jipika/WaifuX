#!/bin/bash
# Resources/assets 不提交到 Git。本地可保留该目录；CI 可通过 WAIFUX_WE_ASSETS_PACK_URL 下载 zip（顶层须含 assets/）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Resources/assets"

if [[ -d "$DEST" ]] && [[ -n "$(ls -A "$DEST" 2>/dev/null)" ]]; then
  echo "[ensure-assets] 使用已有 $DEST"
  exit 0
fi

URL="${WAIFUX_WE_ASSETS_PACK_URL:-}"
if [[ -z "$URL" ]]; then
  echo "error: 缺少 $DEST。请任选：" >&2
  echo "  1) 本地放入完整材质树到 Resources/assets（已被 .gitignore，不会提交）" >&2
  echo "  2) 设置 WAIFUX_WE_ASSETS_PACK_URL 指向 zip（zip 根目录含 assets/）" >&2
  exit 1
fi

echo "[ensure-assets] 下载材质包..."
mkdir -p "$ROOT/Resources"
TMP="/tmp/waifux-wh-assets-pack-$$.zip"
curl -fL "$URL" -o "$TMP"
unzip -q -o "$TMP" -d "$ROOT/Resources"
rm -f "$TMP"

if [[ ! -d "$DEST" ]] || [[ -z "$(ls -A "$DEST" 2>/dev/null)" ]]; then
  echo "error: 解压后仍未得到 $DEST" >&2
  exit 1
fi
echo "[ensure-assets] OK → $DEST"
