#!/bin/bash
# WaifuX 打包脚本
# 用法: ./scripts/package.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_NAME="WaifuX.xcarchive"
DMG_NAME="WaifuX.dmg"
APP_NAME="WaifuX.app"

echo "📦 WaifuX 打包开始..."
echo "项目目录: $PROJECT_DIR"

# CLI 默认使用仓库里已提交的 Resources/wallpaperengine-cli（本地构建后提交）。
# 若该文件不存在，或设置 WAIFUX_FORCE_CLI_REBUILD=1，则尝试 ensure assets 并执行 build 脚本。
CLI_BIN="$PROJECT_DIR/Resources/wallpaperengine-cli"
if [[ ! -f "$CLI_BIN" ]] || [[ -n "${WAIFUX_FORCE_CLI_REBUILD:-}" ]]; then
  if [[ -f "$PROJECT_DIR/scripts/ensure-wallpaperengine-assets.sh" ]]; then
    chmod +x "$PROJECT_DIR/scripts/ensure-wallpaperengine-assets.sh"
    "$PROJECT_DIR/scripts/ensure-wallpaperengine-assets.sh"
  fi
  if [[ -f "$PROJECT_DIR/scripts/build-wallpaperengine-cli.sh" ]]; then
    echo "🔧 构建 wallpaperengine-cli（内嵌 assets）..."
    chmod +x "$PROJECT_DIR/scripts/build-wallpaperengine-cli.sh"
    "$PROJECT_DIR/scripts/build-wallpaperengine-cli.sh"
  fi
else
  echo "🔧 使用已提交的 $CLI_BIN（跳过 CLI 构建）。若需重编请设 WAIFUX_FORCE_CLI_REBUILD=1"
fi

# 捆绑 Homebrew dylib 依赖（无论 CLI 是否重建都需要确保依赖路径正确）
echo "📚 捆绑 dylib 依赖..."
if [[ -f "$PROJECT_DIR/scripts/bundle-dylibs.py" && -f "$PROJECT_DIR/Resources/lib/liblinux-wallpaperengine-renderer.dylib" ]]; then
  python3 "$PROJECT_DIR/scripts/bundle-dylibs.py" \
    "$PROJECT_DIR/Resources/lib/liblinux-wallpaperengine-renderer.dylib" \
    "$PROJECT_DIR/Resources/lib"
  # 重新签名
  for f in "$PROJECT_DIR"/Resources/lib/*.dylib; do
    codesign --force -s - "$f" 2>/dev/null || true
  done
  install_name_tool -id "@rpath/liblinux-wallpaperengine-renderer.dylib" \
    "$PROJECT_DIR/Resources/lib/liblinux-wallpaperengine-renderer.dylib" 2>/dev/null || true
  codesign --force -s - \
    "$PROJECT_DIR/Resources/lib/liblinux-wallpaperengine-renderer.dylib" 2>/dev/null || true
  echo "✅ dylib 依赖捆绑完成"
else
  echo "⚠️ 跳过 dylib 捆绑（bundle-dylibs.py 或渲染器 dylib 不存在）"
fi

# 清理旧构建
echo "🧹 清理旧构建..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Archive
echo "🔨 正在 Archive..."
xcodebuild -scheme WaifuX -configuration Release clean archive \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  -archivePath "$BUILD_DIR/$ARCHIVE_NAME" 2>&1 | tee "$BUILD_DIR/archive.log"

ARCHIVE_STATUS=${PIPESTATUS[0]}
if [ $ARCHIVE_STATUS -ne 0 ]; then
    echo "❌ Archive 失败"
    cat "$BUILD_DIR/archive.log" | tail -50
    exit 1
fi

echo "✅ Archive 成功"

# 创建 exportOptions.plist
cat > "$BUILD_DIR/exportOptions.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
</dict>
</plist>
EOF

# 导出 App
echo "📤 正在导出 App..."
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/$ARCHIVE_NAME" \
  -exportPath "$BUILD_DIR" \
  -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$BUILD_DIR/export.log"

EXPORT_STATUS=${PIPESTATUS[0]}
if [ $EXPORT_STATUS -ne 0 ]; then
    echo "❌ 导出失败"
    cat "$BUILD_DIR/export.log" | tail -50
    exit 1
fi

echo "✅ 导出成功"

# 仅在非签名流程时创建 DMG（签名流程由 CI 另行处理）
if [ "${WAIFUX_SKIP_DMG:-}" != "1" ]; then
  echo "💿 正在创建 DMG..."
  if command -v create-dmg &> /dev/null; then
      create-dmg \
        --volname "WaifuX" \
        --window-size 540 400 \
        --app-drop-link 400 185 \
        --hide-extension "WaifuX.app" \
        --no-internet-enable \
        "$BUILD_DIR/$DMG_NAME" \
        "$BUILD_DIR/$APP_NAME"
  else
      echo "⚠️ create-dmg 未安装，使用 hdiutil..."
      hdiutil create -volname "WaifuX" \
        -srcfolder "$BUILD_DIR/$APP_NAME" \
        -ov -format UDZO \
        -imagekey zlib-level=9 \
        "$BUILD_DIR/$DMG_NAME"
  fi

  if [ ! -f "$BUILD_DIR/$DMG_NAME" ]; then
      echo "❌ DMG 创建失败"
      exit 1
  fi
  echo "📦 DMG 大小: $(ls -lh "$BUILD_DIR/$DMG_NAME" | awk '{print $5}')"
fi

echo ""
echo "✅ 打包完成！"
echo "📍 App 位置: $BUILD_DIR/$APP_NAME"
