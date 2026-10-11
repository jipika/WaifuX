#!/bin/bash
# 编译 wallpaper-video-renderer（视频壁纸独立渲染子进程）
# 产出 Resources/wallpaper-video-renderer 和仓库根 wallpaper-video-renderer 两份
# 默认产出 universal，确保 Intel 发布包也能执行可选 Beta renderer。
# 用法：./scripts/build-wallpaper-video-renderer.sh [arm64|x86_64|universal]

set -euo pipefail

cd "$(dirname "$0")/.."

renderer_arch="${1:-universal}"
case "$renderer_arch" in
  arm64|x86_64) renderer_arches=("$renderer_arch") ;;
  universal) renderer_arches=(arm64 x86_64) ;;
  *) echo "不支持的架构: $renderer_arch"; exit 1 ;;
esac
renderer_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/waifux-video-renderer.XXXXXX")"
trap 'rm -f "$renderer_build_dir"/wallpaper-video-renderer-arm64 "$renderer_build_dir"/wallpaper-video-renderer-x86_64; rmdir "$renderer_build_dir"' EXIT

echo "[1/4] swiftc 编译 wallpaper-video-renderer ($renderer_arch)..."
for renderer_slice in "${renderer_arches[@]}"; do
  swiftc -parse-as-library \
  -O -whole-module-optimization \
  -target "$renderer_slice-apple-macosx14.4" \
  -Xlinker -stack_size -Xlinker 0x2000000 \
  -Xlinker -rpath -Xlinker @loader_path \
  -Xlinker -rpath -Xlinker @loader_path/Resources \
  -Xlinker -rpath -Xlinker @loader_path/../Resources \
  -framework AppKit -framework AVFoundation -framework CoreGraphics -framework Combine -framework ExceptionHandling \
  -o "$renderer_build_dir/wallpaper-video-renderer-$renderer_slice" \
  wallpaper-video-renderer.swift VideoRendererScreenRouting.swift
done
if [[ "$renderer_arch" == "universal" ]]; then
  lipo -create "$renderer_build_dir/wallpaper-video-renderer-arm64" \
    "$renderer_build_dir/wallpaper-video-renderer-x86_64" -output Resources/wallpaper-video-renderer
else
  cp "$renderer_build_dir/wallpaper-video-renderer-$renderer_arch" Resources/wallpaper-video-renderer
fi

echo "[2/4] strip..."
strip -x -S Resources/wallpaper-video-renderer

echo "[3/4] codesign (ad-hoc)..."
codesign --force -s - Resources/wallpaper-video-renderer

echo "[4/4] 复制到仓库根（防 Xcode 开发时根目录优先加载）..."
cp Resources/wallpaper-video-renderer wallpaper-video-renderer

python3 scripts/renderer_component_versions.py --component video

echo "✅ wallpaper-video-renderer 编译完成"
ls -lh Resources/wallpaper-video-renderer wallpaper-video-renderer
