#!/bin/bash
# WallHaven 打包脚本
# 用法: ./scripts/package.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_NAME="WallHaven.xcarchive"
DMG_NAME="WallHaven.dmg"
APP_NAME="WallHaven.app"

echo "📦 WallHaven 打包开始..."
echo "项目目录: $PROJECT_DIR"

# 清理旧构建
echo "🧹 清理旧构建..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Archive
echo "🔨 正在 Archive..."
xcodebuild -scheme WallHaven -configuration Release clean archive \
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

# 创建 DMG
echo "💿 正在创建 DMG..."

# 尝试使用 create-dmg（如果可用）
if command -v create-dmg &> /dev/null; then
    create-dmg \
      --volname "WallHaven" \
      --window-size 540 400 \
      --app-drop-link 400 185 \
      --hide-extension "WallHaven.app" \
      --no-internet-enable \
      "$BUILD_DIR/$DMG_NAME" \
      "$BUILD_DIR/$APP_NAME"
else
    # 使用 hdiutil 作为备选方案
    echo "⚠️ create-dmg 未安装，使用 hdiutil..."
    hdiutil create -volname "WallHaven" \
      -srcfolder "$BUILD_DIR/$APP_NAME" \
      -ov -format UDZO \
      -imagekey zlib-level=9 \
      "$BUILD_DIR/$DMG_NAME"
fi

# 验证 DMG 是否创建成功
if [ ! -f "$BUILD_DIR/$DMG_NAME" ]; then
    echo "❌ DMG 创建失败"
    exit 1
fi

# 完成
echo ""
echo "✅ 打包完成！"
echo "📍 文件位置: $BUILD_DIR/$DMG_NAME"
echo "📦 DMG 大小: $(ls -lh "$BUILD_DIR/$DMG_NAME" | awk '{print $5}')"
echo ""
echo "提示: 打开 dmg 时如提示无法验证开发者，可运行:"
echo "  xattr -d com.apple.quarantine $BUILD_DIR/$DMG_NAME"
