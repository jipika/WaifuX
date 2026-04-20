#!/usr/bin/env bash
# 将仓库根目录 VERSION 同步到 project.yml 中的 MARKETING_VERSION / CURRENT_PROJECT_VERSION。
# 本地改版本号：编辑 VERSION 后执行「bash scripts/sync-version.sh && xcodegen generate」，再 Cmd+R。
# CI 在 xcodegen 前会调用本脚本；Git 不会自动改版本号，需有意 bump VERSION 并提交。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
YML="$ROOT/project.yml"

VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
MAJOR_VERSION=$(echo "$VERSION" | cut -d. -f1)

sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $VERSION/" "$YML"
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $MAJOR_VERSION/" "$YML"

echo "Synced VERSION=$VERSION (CURRENT_PROJECT_VERSION=$MAJOR_VERSION) -> project.yml"
