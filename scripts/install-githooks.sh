#!/bin/sh
# 启用仓库内 hooks：
# - pre-commit：禁止误提交 AGENTS.md 等 AI 本地说明
# - prepare-commit-msg：合并提交（merge commit）时自动 VERSION patch +1 并 git add
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
git config core.hooksPath scripts/githooks
echo "已设置: git config core.hooksPath scripts/githooks"
echo "提示: 合并若未产生 merge 提交（纯 fast-forward），不会触发版本递增；需要时可使用 git merge --no-ff"
