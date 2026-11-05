#!/bin/bash
# 构建闸门（pre-build gate）：唯一 DerivedData 校验 + 构建锁等待。
#
# 规则来源：AGENTS.md「并发构建纪律」（用户 2026-11-02 立为永久规则——只允许
# 这一种构建方式，不允许任何方式绕过）。本仓库所有构建（Xcode 与命令行、
# Debug 与 Release）的 DerivedData 唯一位置=build/WaifuX-<hash>/。
# 任何独立 -derivedDataPath、任何位置的 WaifuX DerivedData 副本都是绕过，
# 闸门拒绝放行，直到清除。
#
# 用法：scripts/wait-for-build-lock.sh [超时秒，默认 1800]
#   退出 0 = 通过闸门，可以构建
#   退出 3 = 检测到绕过的 DerivedData 副本（先按提示清除）
#   退出 1 = 等待超时，锁仍被占用
#
# 全局构建锁（唯一 DerivedData 内）：
#   build/WaifuX-<hash>/Build/Intermediates.noindex/XCBuildData/build.db
# 撞锁报错形态：unable to attach DB: ... database is locked

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMEOUT_SECONDS="${1:-1800}"
POLL_INTERVAL=5

canonical_dd="$REPO_ROOT/build"
SETTINGS_FILE="$REPO_ROOT/WaifuX.xcodeproj/project.xcworkspace/xcuserdata/$(id -un).xcuserdatad/WorkspaceSettings.xcsettings"

# ── 第 1 关：项目级 DerivedData 设置防漂移（被改/被删即自动还原）───────────
canonical_settings() {
cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DerivedDataLocationStyle</key>
	<string>AbsolutePath</string>
	<key>DerivedDataCustomLocation</key>
	<string>${canonical_dd}</string>
</dict>
</plist>
PLIST
}

repair_reason=""
if [[ ! -f "$SETTINGS_FILE" ]]; then
  repair_reason="设置文件缺失"
else
  observed=$(plutil -extract DerivedDataCustomLocation raw -o - "$SETTINGS_FILE" 2>/dev/null)
  observed_style=$(plutil -extract DerivedDataLocationStyle raw -o - "$SETTINGS_FILE" 2>/dev/null)
  if [[ "$observed" != "$canonical_dd" || "$observed_style" != "AbsolutePath" ]]; then
    repair_reason="设置被改动（DerivedDataCustomLocation=${observed:-缺失} / style=${observed_style:-缺失}）"
  fi
fi
if [[ -n "$repair_reason" ]]; then
  mkdir -p "$(dirname "$SETTINGS_FILE")"
  tmp_settings="$(mktemp)"
  canonical_settings > "$tmp_settings"
  mv -f "$tmp_settings" "$SETTINGS_FILE"
  echo "[wait-build-lock] 已自动还原项目级 DerivedData 设置（${repair_reason}）——唯一允许值：AbsolutePath + $canonical_dd"
fi

# ── 第 2 关：扫描绕过的 DerivedData 副本（存在即拒绝，不自动删除）─────────
shopt -s nullglob
stray_candidates=()
for d in /Volumes/mac/Developer/WaifuX-* \
         "$HOME"/Library/Developer/Xcode/DerivedData/WaifuX* \
         /tmp/WaifuX-* /tmp/waifux-* \
         "$REPO_ROOT"/WaifuX-*; do
  if [[ -d "$d" && -e "$d/info.plist" ]]; then
    stray_candidates+=("$d")
  fi
done
shopt -u nullglob

if (( ${#stray_candidates[@]} )); then
  echo "[wait-build-lock] 检测到绕过唯一 DerivedData 的副本（唯一位置=build/WaifuX-<hash>/），拒绝放行：" >&2
  for d in "${stray_candidates[@]}"; do
    echo "  - $d" >&2
  done
  echo "先确认没有构建进程在使用它们（pgrep -f XCBBuildService；ps aux | grep xcodebuild），然后删除并重跑本脚本。" >&2
  exit 3
fi

# ── 第 3 关：等待唯一 DerivedData 的构建锁释放 ───────────────────────────
DB=""
for candidate in \
  "$(ls -td "$REPO_ROOT"/build/WaifuX-*/Build/Intermediates.noindex/XCBuildData/build.db 2>/dev/null | head -1)" \
  "$REPO_ROOT/build/Build/Intermediates.noindex/XCBuildData/build.db"; do
  if [[ -n "$candidate" && -f "$candidate" ]]; then DB="$candidate"; break; fi
done

if [[ -z "$DB" ]]; then
  echo "[wait-build-lock] build.db 不存在（本仓库还没构建过），无需等待"
  exit 0
fi

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
started=$(date +%s)

while :; do
  db_busy=0
  if ! sqlite3 "$DB" "PRAGMA quick_check;" >/dev/null 2>&1; then
    db_busy=1
  fi
  if [[ "$db_busy" -eq 0 ]]; then
    # 双保险：sqlite 能附加但仍有构建进程活着且刚写过库 → 视为忙
    if pgrep -f "XCBBuildService" >/dev/null 2>&1 || pgrep -x xcodebuild >/dev/null 2>&1; then
      now=$(date +%s)
      mtime=$(stat -f %m "$DB" 2>/dev/null || echo 0)
      if (( now - mtime < 90 )); then
        db_busy=1
      fi
    fi
  fi

  if [[ "$db_busy" -eq 0 ]]; then
    echo "[wait-build-lock] 锁已释放（等待 $(( $(date +%s) - started ))s），可以构建：$DB"
    exit 0
  fi

  if (( $(date +%s) >= deadline )); then
    echo "[wait-build-lock] 等待超时（${TIMEOUT_SECONDS}s），锁仍被占用；请稍后重试或联系占用方" >&2
    exit 1
  fi

  sleep "$POLL_INTERVAL"
done
