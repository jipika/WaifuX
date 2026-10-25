#!/bin/bash
# 等待仓库构建锁释放（多 AI / 用户 Xcode 并发构建时排队），再执行标准构建。
#
# 背景：build/Build/Intermediates.noindex/XCBuildData/build.db 是全局构建锁。
# 多个 AI 同时用 xcodebuild 构建本仓库会报 "unable to attach DB: database is locked"。
# 规则（见 AGENTS.md「并发构建纪律」）：有锁就等待，禁止用独立 -derivedDataPath 绕锁。
#
# 用法：scripts/wait-for-build-lock.sh [超时秒，默认 1800]
#   退出 0 = 锁已释放，可以构建
#   退出 1 = 等待超时，锁仍被占用
#
# 判定逻辑（满足任一即视为「有锁」）：
#   1. sqlite3 无法附加 build.db（与 xcodebuild 的加锁条件同源）
#   2. 存在活着的构建进程（XCBBuildService / xcodebuild）且 build.db 90 秒内被写过
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="$REPO_ROOT/build/Build/Intermediates.noindex/XCBuildData/build.db"
TIMEOUT_SECONDS="${1:-1800}"
POLL_INTERVAL=5

if [[ ! -f "$DB" ]]; then
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
    echo "[wait-build-lock] 锁已释放（等待 $(( $(date +%s) - started ))s），可以构建"
    exit 0
  fi

  if (( $(date +%s) >= deadline )); then
    echo "[wait-build-lock] 等待超时（${TIMEOUT_SECONDS}s），锁仍被占用；请稍后重试或联系占用方" >&2
    exit 1
  fi

  sleep "$POLL_INTERVAL"
done
