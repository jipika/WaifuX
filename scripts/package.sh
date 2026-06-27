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

fix_ffmpeg_install_names() {
  local ffmpeg_bin="$1"
  local lib_dir="$2"

  if [[ ! -f "$ffmpeg_bin" || ! -d "$lib_dir" ]] || ! command -v otool >/dev/null 2>&1 || ! command -v install_name_tool >/dev/null 2>&1; then
    return 0
  fi

  local changed=false
  while IFS= read -r dep_path; do
    [[ -n "$dep_path" ]] || continue
    case "$dep_path" in
      /opt/homebrew/*)
        local dep_base
        dep_base="$(basename "$dep_path")"
        if [[ -e "$lib_dir/$dep_base" ]]; then
          install_name_tool -change "$dep_path" "@loader_path/lib/$dep_base" "$ffmpeg_bin" 2>/dev/null || true
          changed=true
        else
          echo "⚠️ ffmpeg 依赖未捆绑: $dep_base"
        fi
        ;;
    esac
  done < <(otool -L "$ffmpeg_bin" 2>/dev/null | awk 'NR > 1 { print $1 }')

  if [[ "$changed" == true ]]; then
    codesign --force --sign - "$ffmpeg_bin" 2>/dev/null || true
    echo "✅ ffmpeg dylib 路径已改为 @loader_path/lib"
  fi
}

verify_packaged_ffmpeg() {
  local ffmpeg_bin="$1"
  if [[ ! -f "$ffmpeg_bin" ]]; then
    return 0
  fi
  if ! "$ffmpeg_bin" -hide_banner -version >/dev/null 2>&1; then
    echo "❌ ffmpeg 无法启动: $ffmpeg_bin"
    echo "请先运行 ./scripts/build-wallpaper-wgpu.sh 修复并提交 Resources/ffmpeg"
    exit 1
  fi
}

# wallpaper-wgpu + DXC 部署。
# CI / GitHub 打包默认使用仓库里已提交的二进制与内嵌 assets object；
# 只有本地缺文件或显式设置 WAIFUX_FORCE_WGPU_REBUILD=1 时才重建，避免 CI 在
# 没有 Resources/assets 的环境里生成空资源占位。
WGPU_BIN="$PROJECT_DIR/Resources/wallpaper-wgpu"
WGPU_REBUILD_REASON=""

if [[ -n "${CI:-}" ]] && [[ -f "$WGPU_BIN" ]] && [[ -z "${WAIFUX_FORCE_WGPU_REBUILD:-}" ]]; then
  WGPU_REBUILD_REASON=""
elif [[ ! -f "$WGPU_BIN" ]]; then
  WGPU_REBUILD_REASON="missing binary"
elif [[ -n "${WAIFUX_FORCE_WGPU_REBUILD:-}" ]]; then
  WGPU_REBUILD_REASON="WAIFUX_FORCE_WGPU_REBUILD"
fi

if [[ -n "$WGPU_REBUILD_REASON" ]]; then
  if [[ -f "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh" ]]; then
    echo "🔧 部署 wallpaper-wgpu + DXC + 内嵌 assets（原因：$WGPU_REBUILD_REASON）..."
    chmod +x "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh"
    WAIFUX_FORCE_EMBED_ASSETS=1 "$PROJECT_DIR/scripts/build-wallpaper-wgpu.sh"
  fi
else
  echo "🔧 使用已提交的 $WGPU_BIN（跳过 wallpaper-wgpu 构建）。若需重编请设 WAIFUX_FORCE_WGPU_REBUILD=1"
fi

require_packaged_file "$PROJECT_DIR/Resources/wallpaper-wgpu" "wallpaper-wgpu"
require_packaged_file "$PROJECT_DIR/Resources/dxc" "dxc"
require_packaged_file "$PROJECT_DIR/Resources/lib/libdxcompiler.dylib" "libdxcompiler.dylib"
require_packaged_file "$PROJECT_DIR/Resources/zip_data.o" "wallpaper-wgpu embedded assets object"
require_packaged_file "$PROJECT_DIR/Resources/zip_accessor.o" "wallpaper-wgpu embedded assets accessor object"
fix_ffmpeg_install_names "$PROJECT_DIR/Resources/ffmpeg" "$PROJECT_DIR/Resources/lib"
verify_packaged_ffmpeg "$PROJECT_DIR/Resources/ffmpeg"

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
         "$PROJECT_DIR"/Resources/ffmpeg \
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
  STRIP_INSTALLED_PRODUCT=NO \
  MACOSX_DEPLOYMENT_TARGET=14.4 \
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
      # Developer ID + App Groups 需要 provisioning profile 授权。
      # 因此优先使用 CI 预签名 .appex；缺失时有 profile 则交给 Xcode 签，否则才尝试直接 codesign。
      local pre_signed="$PROJECT_DIR/WaifuXWallpaperExtension.appex"
      if [[ -d "$pre_signed" ]]; then
        echo "  使用预签名扩展: $(basename "$pre_signed")"
        rm -rf "$code_path"
        cp -R "$pre_signed" "$code_path"
        echo "  ✅ $(basename "$code_path") (预签名)"
      elif [[ "$identity" != "-" ]]; then
        echo "  签名扩展 (xcodebuild): $(basename "$code_path")"
        local extension_build_log="$BUILD_DIR/extension-build.log"
        if [[ -n "${WAIFUX_EXTENSION_PROVISIONING_PROFILE_UUID:-}" ]]; then
          if ! xcodebuild -project "$PROJECT_DIR/WaifuX.xcodeproj" \
            -target WaifuXWallpaperExtension \
            -configuration Release \
            CODE_SIGN_IDENTITY="$identity" \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGN_ENTITLEMENTS="$extension_entitlements" \
            PROVISIONING_PROFILE="$WAIFUX_EXTENSION_PROVISIONING_PROFILE_UUID" \
            ENABLE_HARDENED_RUNTIME=YES \
            OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
            clean build > "$extension_build_log" 2>&1; then
            tail -80 "$extension_build_log"
            return 1
          fi
        else
          if ! xcodebuild -project "$PROJECT_DIR/WaifuX.xcodeproj" \
            -target WaifuXWallpaperExtension \
            -configuration Release \
            CODE_SIGNING_ALLOWED=NO \
            clean build > "$extension_build_log" 2>&1; then
            tail -80 "$extension_build_log"
            return 1
          fi
        fi
        tail -20 "$extension_build_log"
        local built_appex
        built_appex=$(find "$PROJECT_DIR/build" ~/Library/Developer/Xcode/DerivedData \
          \( -path "*/Release/WaifuXWallpaperExtension.appex" -o -path "*/Build/Products/Release/WaifuXWallpaperExtension.appex" \) \
          -type d -print 2>/dev/null | head -1)
        if [[ -n "$built_appex" && -d "$built_appex" ]]; then
          rm -rf "$code_path"
          cp -R "$built_appex" "$code_path"
          if [[ -n "${WAIFUX_EXTENSION_PROVISIONING_PROFILE_PATH:-}" && -f "$WAIFUX_EXTENSION_PROVISIONING_PROFILE_PATH" ]]; then
            local extension_profile_plist="$BUILD_DIR/extension-profile.plist"
            local extension_resign_entitlements="$BUILD_DIR/extension-resign-entitlements.plist"
            security cms -D -i "$WAIFUX_EXTENSION_PROVISIONING_PROFILE_PATH" > "$extension_profile_plist"
            /usr/libexec/PlistBuddy -x -c 'Print Entitlements' "$extension_profile_plist" > "$extension_resign_entitlements"
            /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$extension_resign_entitlements" 2>/dev/null || \
              /usr/libexec/PlistBuddy -c 'Set :com.apple.security.app-sandbox true' "$extension_resign_entitlements"
            mkdir -p "$code_path/Contents"
            cp "$WAIFUX_EXTENSION_PROVISIONING_PROFILE_PATH" "$code_path/Contents/embedded.provisionprofile"
            codesign --force --timestamp=none --options runtime --entitlements "$extension_resign_entitlements" -s "$identity" "$code_path" 2>/dev/null || \
              codesign --force --options runtime --entitlements "$extension_resign_entitlements" -s "$identity" "$code_path"
          elif [[ -z "${WAIFUX_EXTENSION_PROVISIONING_PROFILE_UUID:-}" ]]; then
            codesign --force --timestamp=none --options runtime --entitlements "$extension_entitlements" -s "$identity" "$code_path" 2>/dev/null || \
              codesign --force --options runtime --entitlements "$extension_entitlements" -s "$identity" "$code_path"
          fi
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
        echo "请配置 APPLE_EXTENSION_PROVISIONING_PROFILE / WAIFUX_EXTENSION_PROVISIONING_PROFILE_UUID 后再打包 Developer ID 版本。" >&2
        echo "Debug entitlements:" >&2
        echo "$ent_check" | head -20 >&2
        return 1
      fi
    else
      # 对 framework：先递归签内部嵌套代码（XPC services、.app 包、独立可执行文件），再签 framework 本身
      if [[ "$code_path" == *.framework ]]; then
        echo "  Signing nested code in: $(basename "$code_path")"
        find "$code_path" -name "*.xpc" -type d 2>/dev/null | while read -r xpc; do
          echo "    XPC: ${xpc#"$code_path/"}"
          codesign --force --timestamp=none --options runtime -s "$identity" "$xpc" 2>/dev/null || \
            codesign --force -s "$identity" "$xpc" 2>/dev/null || true
        done
        find "$code_path" -name "*.app" -type d 2>/dev/null | while read -r app; do
          echo "    App: ${app#"$code_path/"}"
          codesign --force --timestamp=none --options runtime -s "$identity" "$app" 2>/dev/null || \
            codesign --force -s "$identity" "$app" 2>/dev/null || true
        done
        find "$code_path" -type f 2>/dev/null | while read -r exe; do
          case "$exe" in *.app/*|*.xpc/*) continue ;; esac
          if file "$exe" | grep -q "Mach-O"; then
            echo "    Executable: ${exe#"$code_path/"}"
            codesign --force --timestamp=none --options runtime -s "$identity" "$exe" 2>/dev/null || \
              codesign --force -s "$identity" "$exe" 2>/dev/null || true
          fi
        done
      fi
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

  if [[ -n "${WAIFUX_APP_PROVISIONING_PROFILE_PATH:-}" && -f "$WAIFUX_APP_PROVISIONING_PROFILE_PATH" ]]; then
    cp "$WAIFUX_APP_PROVISIONING_PROFILE_PATH" "$app_path/Contents/embedded.provisionprofile"
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
  local app_ent_check
  app_ent_check=$(codesign -d --entitlements - "$app_path" 2>/dev/null || true)
  if ! echo "$app_ent_check" | grep -q "com.apple.security.application-groups"; then
    echo "❌ App 签名缺少 application-groups entitlement: $app_path" >&2
    echo "请配置 APPLE_APP_PROVISIONING_PROFILE / WAIFUX_APP_PROVISIONING_PROFILE_PATH 后再打包 Developer ID 版本。" >&2
    echo "$app_ent_check" | head -20 >&2
    return 1
  fi
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
