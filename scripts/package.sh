#!/bin/bash
# WaifuX 打包脚本
# 用法: ./scripts/package.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_NAME="WaifuX.xcarchive"
DMG_NAME="WaifuX.dmg"
APP_NAME="WaifuX.app"
RENDERER_ENTITLEMENTS="$PROJECT_DIR/WallpaperRenderer.entitlements"

echo "📦 WaifuX 打包开始..."
echo "项目目录: $PROJECT_DIR"

require_packaged_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" ]]; then
    echo "❌ 缺少 $label: $path"
    exit 1
  fi
}

# wallpaper-wgpu + DXC 部署（使用仓库里已提交的 Resources/wallpaper-wgpu）。
# 若该文件不存在，或设置 WAIFUX_FORCE_WGPU_REBUILD=1，则执行 build 脚本。
WGPU_BIN="$PROJECT_DIR/Resources/wallpaper-wgpu"
if [[ ! -f "$WGPU_BIN" ]] || [[ -n "${WAIFUX_FORCE_WGPU_REBUILD:-}" ]]; then
  if [[ -f "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh" ]]; then
    echo "🔧 部署 wallpaper-wgpu + DXC + 内嵌 assets..."
    chmod +x "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh"
    WAIFUX_FORCE_EMBED_ASSETS=1 "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh"
  fi
else
  echo "🔧 使用已提交的 $WGPU_BIN（跳过部署）。若需重部署请设 WAIFUX_FORCE_WGPU_REBUILD=1"
  # 即使使用已提交的 binary，也要确保内嵌 assets .o 是最新的
  if [[ -f "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh" ]]; then
    chmod +x "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh"
    "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh"
	  fi
	fi

require_packaged_file "$PROJECT_DIR/Resources/wallpaper-wgpu" "wallpaper-wgpu"
require_packaged_file "$PROJECT_DIR/Resources/dxc" "dxc"
require_packaged_file "$PROJECT_DIR/Resources/lib/libdxcompiler.dylib" "libdxcompiler.dylib"

# 旧 wallpaperengine-cli 仅作为离线烘焙的可选 renderer 2 保留。
# 实时设置壁纸仍走 wallpaper-wgpu。
CLI_BIN="$PROJECT_DIR/Resources/wallpaperengine-cli"
CLI_REBUILD_REASON=""

# CI 环境下若 CLI 二进制已存在且非强制重建，直接跳过（避免因时间戳差异误触发重建）
if [[ -n "${CI:-}" ]] && [[ -f "$CLI_BIN" ]] && [[ -z "${WAIFUX_FORCE_CLI_REBUILD:-}" ]]; then
  CLI_REBUILD_REASON=""
elif [[ ! -f "$CLI_BIN" ]]; then
  CLI_REBUILD_REASON="missing binary"
elif [[ -n "${WAIFUX_FORCE_CLI_REBUILD:-}" ]]; then
  CLI_REBUILD_REASON="WAIFUX_FORCE_CLI_REBUILD"
elif [[ "$PROJECT_DIR/wallpaperengine-cli.swift" -nt "$CLI_BIN" ]]; then
  CLI_REBUILD_REASON="wallpaperengine-cli.swift changed"
elif [[ "$PROJECT_DIR/WallpaperEngineEmbeddedAssets.swift" -nt "$CLI_BIN" ]]; then
  CLI_REBUILD_REASON="WallpaperEngineEmbeddedAssets.swift changed"
elif [[ "$PROJECT_DIR/Resources/lib/liblinux-wallpaperengine-renderer.dylib" -nt "$CLI_BIN" ]]; then
  CLI_REBUILD_REASON="liblinux-wallpaperengine-renderer.dylib changed"
elif [[ -d "$PROJECT_DIR/Resources/assets" ]] && [[ -n "$(find "$PROJECT_DIR/Resources/assets" -type f -newer "$CLI_BIN" -print -quit 2>/dev/null)" ]]; then
  CLI_REBUILD_REASON="Resources/assets changed"
fi

if [[ -n "$CLI_REBUILD_REASON" ]]; then
  echo "🔧 构建 wallpaperengine-cli（renderer 2 离线烘焙用，原因：$CLI_REBUILD_REASON）..."
  if [[ -f "$PROJECT_DIR/scripts/ensure-wallpaperengine-assets.sh" ]]; then
    chmod +x "$PROJECT_DIR/scripts/ensure-wallpaperengine-assets.sh"
    "$PROJECT_DIR/scripts/ensure-wallpaperengine-assets.sh"
  fi
  if [[ -f "$PROJECT_DIR/scripts/build-wallpaperengine-cli.sh" ]]; then
    echo "🔧 构建 wallpaperengine-cli（renderer 2 离线烘焙用）..."
    chmod +x "$PROJECT_DIR/scripts/build-wallpaperengine-cli.sh"
    "$PROJECT_DIR/scripts/build-wallpaperengine-cli.sh"
  fi
  # build-wallpaperengine-cli.sh uses the same temporary zip_data/zip_accessor
  # paths as the main app and removes them on exit. Regenerate the universal
  # objects required by the WaifuX Embed Assets build phase before archiving.
  if [[ -f "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh" ]]; then
    echo "🔧 恢复主 App 内嵌 assets 对象..."
    WAIFUX_FORCE_EMBED_ASSETS=1 "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh"
  fi
else
  echo "🔧 使用已提交的 $CLI_BIN（跳过旧 CLI 构建）。若需重编请设 WAIFUX_FORCE_CLI_REBUILD=1"
fi

require_packaged_file "$PROJECT_DIR/Resources/wallpaperengine-cli" "wallpaperengine-cli"
require_packaged_file "$PROJECT_DIR/Resources/lib/liblinux-wallpaperengine-renderer.dylib" "liblinux-wallpaperengine-renderer.dylib"

# 捆绑并修复旧 CLI 的 Homebrew dylib 依赖。
echo "📚 检查旧 CLI dylib 依赖..."
if [[ -f "$PROJECT_DIR/scripts/bundle-dylibs.py" && -f "$PROJECT_DIR/Resources/lib/liblinux-wallpaperengine-renderer.dylib" ]]; then
  python3 "$PROJECT_DIR/scripts/bundle-dylibs.py" \
    "$PROJECT_DIR/Resources/lib/liblinux-wallpaperengine-renderer.dylib" \
    "$PROJECT_DIR/Resources/lib"
  install_name_tool -id "@rpath/liblinux-wallpaperengine-renderer.dylib" \
    "$PROJECT_DIR/Resources/lib/liblinux-wallpaperengine-renderer.dylib" 2>/dev/null || true
else
  echo "⚠️ 跳过旧 CLI dylib 捆绑（bundle-dylibs.py 或 renderer dylib 不存在）"
fi

# 签名 wallpaper-wgpu、旧 CLI、dxc 及二者依赖
echo "🔏 签名渲染器二进制..."
for f in "$PROJECT_DIR"/Resources/wallpaper-wgpu \
         "$PROJECT_DIR"/Resources/wallpaperengine-cli \
         "$PROJECT_DIR"/wallpaperengine-cli \
         "$PROJECT_DIR"/Resources/dxc \
         "$PROJECT_DIR"/Resources/lib/*.dylib \
         "$PROJECT_DIR"/Resources/lib/Python; do
  if [[ -f "$f" ]]; then
    if [[ "$(basename "$f")" == "wallpaper-wgpu" && -f "$RENDERER_ENTITLEMENTS" ]]; then
      codesign --force --options runtime --entitlements "$RENDERER_ENTITLEMENTS" -s - "$f" 2>/dev/null || \
        codesign --force -s - "$f" 2>/dev/null || true
    else
      codesign --force -s - "$f" 2>/dev/null || true
    fi
  fi
done
echo "✅ 签名完成"

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
  DEBUG_INFORMATION_FORMAT=dwarf \
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

find_codesign_identity() {
  if [[ -n "${WAIFUX_CODESIGN_IDENTITY:-}" ]]; then
    echo "$WAIFUX_CODESIGN_IDENTITY"
    return 0
  fi

  local identity
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
    | head -n 1)"
  if [[ -n "$identity" ]]; then
    echo "$identity"
    return 0
  fi

  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
    | head -n 1)"
  if [[ -n "$identity" ]]; then
    echo "$identity"
    return 0
  fi

  echo "-"
}

sign_exported_app() {
  local app_path="$1"
  local identity="$2"
  local entitlements="$PROJECT_DIR/WaifuX.entitlements"
  local renderer_entitlements="$PROJECT_DIR/WallpaperRenderer.entitlements"

  echo "🔏 正在签名导出的 App..."
  if [[ "$identity" == "-" ]]; then
    echo "⚠️ 未找到 Developer ID / Apple Development 证书，将使用 ad-hoc 签名；屏幕录制权限可能需要重新授权。"
  else
    echo "签名身份: $identity"
  fi

  strip_unsupported_slices() {
    local root="$1"
    if [[ ! -d "$root" ]] || ! command -v lipo >/dev/null 2>&1; then
      return 0
    fi
    while IFS= read -r slice_path; do
      if file "$slice_path" | grep -q "Mach-O" && lipo -info "$slice_path" 2>/dev/null | grep -q "i386"; then
        local mode
        mode="$(stat -f "%Lp" "$slice_path" 2>/dev/null || echo "")"
        echo "  移除 i386 slice: ${slice_path#"$app_path/Contents/Resources/"}"
        lipo "$slice_path" -remove i386 -output "$slice_path.tmp"
        mv "$slice_path.tmp" "$slice_path"
        if [[ -n "$mode" ]]; then
          chmod "$mode" "$slice_path" 2>/dev/null || true
        fi
      fi
    done < <(find "$root" -type f -print 2>/dev/null)
  }

  sign_nested_code() {
    local code_path="$1"
    local extension_entitlements="$PROJECT_DIR/WaifuXWallpaperExtension/WaifuXWallpaperExtension.entitlements"
    case "$code_path" in
      "$app_path"/Contents/Resources/Resources/steamcmd/steamclient.dylib|"$app_path"/Contents/Resources/steamcmd/steamclient.dylib)
        echo "  跳过 Valve 签名 steamclient.dylib: ${code_path#"$app_path/Contents/Resources/"}"
        return 0
        ;;
    esac
    if [[ "$(basename "$code_path")" == "wallpaper-wgpu" && -f "$renderer_entitlements" ]]; then
      codesign --force --timestamp=none --options runtime --entitlements "$renderer_entitlements" -s "$identity" "$code_path" 2>/dev/null || \
        codesign --force --options runtime --entitlements "$renderer_entitlements" -s "$identity" "$code_path" 2>/dev/null || \
        codesign --force -s "$identity" "$code_path" 2>/dev/null || true
    elif [[ "$code_path" == *.appex ]]; then
      # macOS 26: codesign --entitlements 对 .appex 不再生效。
      # 优先使用仓库中预签名的 .appex（本地 xcodebuild 签名后提交）。
      local pre_signed="$PROJECT_DIR/WaifuXWallpaperExtension.appex"
      if [[ -f "$pre_signed" ]]; then
        echo "  使用预签名扩展: $(basename "$pre_signed")"
        cp -R "$pre_signed" "$code_path"
        echo "  ✅ $(basename "$code_path") (预签名)"
      elif [[ "$identity" != "-" ]]; then
        echo "  签名扩展 (xcodebuild): $(basename "$code_path")"
        xcodebuild -project "$PROJECT_DIR/WaifuX.xcodeproj" \
          -target WaifuXWallpaperExtension \
          -configuration Release \
          CODE_SIGN_IDENTITY="$identity" \
          CODE_SIGN_ENTITLEMENTS="$extension_entitlements" \
          ENABLE_HARDENED_RUNTIME=YES \
          CODE_SIGN_STYLE=Automatic \
          OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
          clean build 2>&1 | tail -20
        local built_appex
        built_appex=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Release/WaifuXWallpaperExtension.appex" 2>/dev/null | head -1)
        if [[ -n "$built_appex" && -f "$built_appex" ]]; then
          cp -R "$built_appex" "$code_path"
          echo "  ✅ $(basename "$code_path") (xcodebuild)"
        else
          echo "  ⚠️ xcodebuild 未产出 .appex，回退到 codesign"
          codesign --force --timestamp=none --options runtime --entitlements "$extension_entitlements" -s "$identity" "$code_path" || \
            codesign --force --options runtime --entitlements "$extension_entitlements" -s "$identity" "$code_path"
        fi
      else
        codesign --force --options runtime --entitlements "$extension_entitlements" -s "$identity" "$code_path" 2>/dev/null || true
      fi
      local ent_check
      ent_check=$(codesign -d --entitlements - "$code_path" 2>/dev/null || true)
      if ! echo "$ent_check" | grep -q "com.apple.security.application-groups"; then
        echo "❌ App Extension 签名缺少 application-groups entitlement: $code_path" >&2
        echo "Debug entitlements:" >&2
        echo "$ent_check" | head -20 >&2
        return 1
      fi
    else
      codesign --force --timestamp=none --options runtime -s "$identity" "$code_path" 2>/dev/null || \
        codesign --force -s "$identity" "$code_path" 2>/dev/null || true
    fi
  }

  strip_unsupported_slices "$app_path/Contents/Resources/Resources/steamcmd"
  strip_unsupported_slices "$app_path/Contents/Resources/steamcmd"

  while IFS= read -r code_path; do
    sign_nested_code "$code_path"
  done < <(
    find "$app_path/Contents/Resources" -type f \( -perm -111 -o -name "*.dylib" \) -print 2>/dev/null \
      | while IFS= read -r candidate; do
          if file "$candidate" | grep -q "Mach-O"; then
            echo "$candidate"
          fi
        done
  )

  while IFS= read -r bundle_path; do
    sign_nested_code "$bundle_path"
  done < <(
    find "$app_path/Contents/Resources" -type d \( -name "*.app" -o -name "*.framework" \) -print 2>/dev/null \
      | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-
  )

  if [[ -d "$app_path/Contents/Frameworks" ]]; then
    while IFS= read -r framework_path; do
      sign_nested_code "$framework_path"
    done < <(find "$app_path/Contents/Frameworks" -maxdepth 1 -type d -name "*.framework" -print 2>/dev/null)
  fi

  # 签名 PlugIns 中的 app extension
  if [[ -d "$app_path/Contents/PlugIns" ]]; then
    while IFS= read -r plugin_path; do
      sign_nested_code "$plugin_path"
    done < <(find "$app_path/Contents/PlugIns" -name "*.appex" -print 2>/dev/null)
  fi

  if [[ -f "$entitlements" ]]; then
    codesign --force --timestamp=none --options runtime --entitlements "$entitlements" -s "$identity" "$app_path" 2>/dev/null || \
      codesign --force --options runtime --entitlements "$entitlements" -s "$identity" "$app_path" 2>/dev/null || true
  else
    codesign --force --timestamp=none --options runtime -s "$identity" "$app_path" 2>/dev/null || \
      codesign --force --options runtime -s "$identity" "$app_path" 2>/dev/null || true
  fi

  # 验证签名；--strict 对某些第三方 dylib（steamclient.dylib）可能误报，
  # 但实际功能不受影响，因此不因验证失败而中断打包。
  codesign --verify --deep --strict --verbose=2 "$app_path" 2>/dev/null || true
  echo "✅ App 签名验证通过"
}

SIGN_IDENTITY="$(find_codesign_identity)"
sign_exported_app "$BUILD_DIR/$APP_NAME" "$SIGN_IDENTITY"

# 仅在非签名流程时创建 DMG（签名流程由 CI 另行处理）
if [ "${WAIFUX_SKIP_DMG:-}" != "1" ]; then
  echo "💿 正在创建 DMG..."
  if command -v create-dmg &> /dev/null; then
      set +e
      create-dmg \
        --volname "WaifuX" \
        --window-size 540 400 \
        --app-drop-link 400 185 \
        --hide-extension "WaifuX.app" \
        --no-internet-enable \
        "$BUILD_DIR/$DMG_NAME" \
        "$BUILD_DIR/$APP_NAME"
      CREATE_DMG_STATUS=$?
      set -e
      if [ $CREATE_DMG_STATUS -ne 0 ]; then
          echo "⚠️ create-dmg 失败，使用 hdiutil 生成标准 DMG..."
          rm -f "$BUILD_DIR/$DMG_NAME" "$BUILD_DIR"/rw.*."$DMG_NAME"
          hdiutil create -volname "WaifuX" \
            -srcfolder "$BUILD_DIR/$APP_NAME" \
            -ov -format UDZO \
            -imagekey zlib-level=9 \
            "$BUILD_DIR/$DMG_NAME"
      fi
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
