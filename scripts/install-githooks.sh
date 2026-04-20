#!/bin/sh
# 启用仓库内 hooks（pre-commit 会拦截误提交的 AI 本地说明文件）
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
git config core.hooksPath scripts/githooks
echo "已设置: git config core.hooksPath scripts/githooks"
