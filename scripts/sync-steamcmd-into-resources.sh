#!/usr/bin/env bash
# 将 macOS 官方 SteamCMD 放进 Resources/steamcmd（打进 WaifuX.app，克隆即可构建）。
#   ./scripts/sync-steamcmd-into-resources.sh
#       从 Valve CDN 下载并解压（默认）。
#   ./scripts/sync-steamcmd-into-resources.sh /path/to/extracted-steamcmd
#       从本机已解压目录复制（离线或固定版本时用）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$ROOT/Resources/steamcmd"
URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz"

clear_dst_except_readme() {
  mkdir -p "$DST"
  if [[ -d "$DST" ]]; then
    find "$DST" -mindepth 1 -maxdepth 1 ! -name 'README.md' -exec rm -rf {} +
  fi
}

sync_from_dir() {
  local SRC="$1"
  if [[ ! -d "$SRC" || ! -f "$SRC/steamcmd.sh" ]]; then
    echo "[sync-steamcmd] 无效源目录（根目录须含 steamcmd.sh）: $SRC" >&2
    exit 1
  fi
  clear_dst_except_readme
  cp -R "$SRC"/. "$DST/"
  rm -f "$DST/steamcmd_osx.tar.gz"
  echo "[sync-steamcmd] 已从 $SRC 更新 $DST"
}

if [[ "${1:-}" != "" ]]; then
  sync_from_dir "$1"
  exit 0
fi

clear_dst_except_readme
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/steamcmd_osx.tar.gz"
tar -xzf "$TMP/steamcmd_osx.tar.gz" -C "$DST"
rm -f "$DST/steamcmd_osx.tar.gz"
echo "[sync-steamcmd] 已从官方包更新 $DST（可提交）"
