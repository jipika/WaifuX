#!/usr/bin/env bash
# 将 VERSION 的末位 patch +1，并同步到 project.yml，随后 git add（供合并提交一并纳入）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VFILE="$ROOT/VERSION"
v=$(tr -d '[:space:]' < "$VFILE")
major=$(echo "$v" | cut -d. -f1)
minor=$(echo "$v" | cut -d. -f2)
patch=$(echo "$v" | cut -d. -f3)
if [ -z "$patch" ]; then patch=0; fi
patch=$((patch + 1))
newv="$major.$minor.$patch"
printf '%s\n' "$newv" > "$VFILE"
bash "$ROOT/scripts/sync-version.sh"
cd "$ROOT" && git add VERSION project.yml
echo "githooks: 合并自动递增版本 -> $newv" >&2
