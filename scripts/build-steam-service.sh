#!/bin/bash
#
# Build and embed the persistent SteamKit2 Workshop service.
#
# Usage:
#   ./scripts/build-steam-service.sh <app-contents-or-resources> [architectures]
#
# The destination may be an app's Contents/Resources directory or the final
# WaifuXSteamService directory. The script keeps each architecture isolated so
# an arm64/x86_64 universal archive can carry both runtimes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_ROOT="${1:?Usage: build-steam-service.sh <destination> [architectures]}"
ARCHITECTURES="${2:-$(uname -m)}"
PROJECT="$ROOT/SteamService/WaifuXSteamService.csproj"
OUTPUT="$ROOT/build/SteamService"
PREBUILT_ROOT="$ROOT/SteamService/prebuilt"

# Prebuilt runtimes ship in the repo (SteamService/prebuilt/<arch>) so a
# normal Xcode build does not need the .NET SDK. Force a fresh compile with
# WAIFUX_STEAM_SERVICE_BUILD=1 (requires the .NET SDK).
use_prebuilt() {
    [ "${WAIFUX_STEAM_SERVICE_BUILD:-0}" = "1" ] && return 1
    return 0
}

copy_prebuilt() {
    local architecture="$1"
    local architecture_destination="$DEST_ROOT/$architecture"
    local source="$PREBUILT_ROOT/$architecture"
    mkdir -p "$DEST_ROOT"
    # cp -R onto an existing directory copies *into* it (arm64/arm64) and leaves
    # the old app/ untouched, so incremental builds kept running a stale service.
    rm -rf "${architecture_destination:?}"
    cp -R "$source" "$architecture_destination"
    if [ -d "$PREBUILT_ROOT/Licenses" ]; then
        rm -rf "${DEST_ROOT:?}/Licenses"
        cp -R "$PREBUILT_ROOT/Licenses" "$DEST_ROOT/Licenses"
    fi
    echo "[steam-service] Copied prebuilt $architecture service from $source (set WAIFUX_STEAM_SERVICE_BUILD=1 to compile from source)."
}

if use_prebuilt; then
    prebuilt_missing=0
    for architecture in $ARCHITECTURES; do
        case "$architecture" in
            arm64|x86_64)
                if [ ! -d "$PREBUILT_ROOT/$architecture/app" ] || \
                   [ ! -x "$PREBUILT_ROOT/$architecture/runtime/dotnet" ] || \
                   ! ls "$PREBUILT_ROOT/$architecture/runtime/shared/Microsoft.NETCore.App"/*/libcoreclr.dylib >/dev/null 2>&1; then
                    echo "[steam-service] No complete prebuilt $architecture service in $PREBUILT_ROOT." >&2
                    echo "[steam-service] (runtime/shared/Microsoft.NETCore.App/*/libcoreclr.dylib is required — a missing shared/ usually means the .gitignore *.app rule swallowed the Microsoft.NETCore.App directory.)" >&2
                    prebuilt_missing=1
                fi
                ;;
            *)
                echo "[steam-service] Unsupported architecture: $architecture" >&2
                exit 1
                ;;
        esac
    done
    if [ "$prebuilt_missing" -eq 0 ]; then
        # Staleness guard: warn when C# sources were committed after the
        # prebuilt service, meaning the shipped binary no longer matches
        # the source tree (e.g. source edited without a local .NET SDK).
        if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            source_ts="$(git -C "$ROOT" log -1 --format=%ct -- 'SteamService/*.cs' 'SteamService/*.csproj' 2>/dev/null || echo 0)"
            prebuilt_ts="$(git -C "$ROOT" log -1 --format=%ct -- "SteamService/prebuilt/arm64/app/WaifuXSteamService.dll" "SteamService/prebuilt/x86_64/app/WaifuXSteamService.dll" 2>/dev/null || echo 0)"
            if [ "${source_ts:-0}" -gt "${prebuilt_ts:-0}" ]; then
                echo "[steam-service] WARNING: SteamService sources are newer than the prebuilt binary; the embedded service may be stale. Rebuild it with WAIFUX_STEAM_SERVICE_BUILD=1 and refresh SteamService/prebuilt/." >&2
            fi
        fi
        for architecture in $ARCHITECTURES; do
            copy_prebuilt "$architecture"
        done
        exit 0
    fi
    echo "[steam-service] Falling back to a source build (.NET SDK required)." >&2
fi

if ! command -v dotnet >/dev/null 2>&1; then
    echo "[steam-service] .NET SDK is required to build the embedded Steam service." >&2
    echo "[steam-service] Install it with: brew install dotnet" >&2
    exit 1
fi

DOTNET_EXECUTABLE="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$(command -v dotnet)")"
DOTNET_ROOT="$(dirname "$DOTNET_EXECUTABLE")"
RUNTIME_VERSION="$(dotnet --list-runtimes | awk '$1 == "Microsoft.NETCore.App" && $2 ~ /^10\./ { print $2 }' | sort -V | tail -1)"

[ -n "$RUNTIME_VERSION" ] || {
    echo "[steam-service] Microsoft.NETCore.App 10 runtime is unavailable." >&2
    exit 1
}
[ -d "$DOTNET_ROOT/host/fxr/$RUNTIME_VERSION" ] || {
    echo "[steam-service] hostfxr $RUNTIME_VERSION is unavailable." >&2
    exit 1
}
[ -d "$DOTNET_ROOT/shared/Microsoft.NETCore.App/$RUNTIME_VERSION" ] || {
    echo "[steam-service] runtime $RUNTIME_VERSION is unavailable." >&2
    exit 1
}

rm -rf "$DEST_ROOT"
mkdir -p "$DEST_ROOT"

publish_architecture() {
    local architecture="$1"
    local runtime="$2"
    local architecture_destination="$DEST_ROOT/$architecture"
    local application_destination="$architecture_destination/app"
    local runtime_destination="$architecture_destination/runtime"
    if [ "${CI:-}" = "true" ]; then
        env -u ASSEMBLY_NAME -u PRODUCT_NAME -u PROJECT_NAME -u TARGET_NAME \
            -u TARGETNAME -u EXECUTABLE_NAME -u FULL_PRODUCT_NAME -u WRAPPER_NAME \
            dotnet publish "$PROJECT" \
            -c Release \
            -f net10.0 \
            -r "$runtime" \
            --self-contained false \
            -p:RestoreLockedMode=true \
            -p:AllowMissingPrunePackageData=true \
            -p:AssemblyName=WaifuXSteamService \
            -p:TargetName=WaifuXSteamService \
            -p:UseAppHost=false \
            -p:PublishTrimmed=false \
            -p:DebugType=None \
            -p:DebugSymbols=false \
            -o "$OUTPUT/$runtime"
    else
        env -u ASSEMBLY_NAME -u PRODUCT_NAME -u PROJECT_NAME -u TARGET_NAME \
            -u TARGETNAME -u EXECUTABLE_NAME -u FULL_PRODUCT_NAME -u WRAPPER_NAME \
            dotnet publish "$PROJECT" \
            -c Release \
            -f net10.0 \
            -r "$runtime" \
            --self-contained false \
            -p:AllowMissingPrunePackageData=true \
            -p:AssemblyName=WaifuXSteamService \
            -p:TargetName=WaifuXSteamService \
            -p:UseAppHost=false \
            -p:PublishTrimmed=false \
            -p:DebugType=None \
            -p:DebugSymbols=false \
            -o "$OUTPUT/$runtime"
    fi

    mkdir -p "$application_destination" \
        "$runtime_destination/host/fxr" \
        "$runtime_destination/shared/Microsoft.NETCore.App"
    cp -R "$OUTPUT/$runtime/." "$application_destination/"
    # The runtime host, hostfxr and shared framework must match the TARGET
    # architecture, not the build machine's. Resolve a per-arch dotnet root:
    # 1. WAIFUX_DOTNET_ROOT_<ARCH> override (e.g. WAIFUX_DOTNET_ROOT_X86_64)
    # 2. a sibling RID directory under OUTPUT produced by an x64 SDK
    # 3. fallback to the running SDK root (correct when arch == host arch)
    local arch_dotnet_root=""
    case "$architecture" in
        arm64)  arch_dotnet_root="${WAIFUX_DOTNET_ROOT_ARM64:-}" ;;
        x86_64) arch_dotnet_root="${WAIFUX_DOTNET_ROOT_X86_64:-}" ;;
    esac
    local arch_hostfxr arch_shared
    if [ -n "$arch_dotnet_root" ] && [ -x "$arch_dotnet_root/dotnet" ]; then
        :
    elif [ "$architecture" = "x86_64" ] && [ -x "$DOTNET_ROOT_x64/dotnet" ] 2>/dev/null; then
        arch_dotnet_root="$DOTNET_ROOT_x64"
    else
        # Verify the running SDK root actually matches the target arch; if not
        # and no override exists, fail loudly instead of shipping a broken mix.
        local host_arch
        host_arch="$(uname -m)"
        if [ "$host_arch" != "$architecture" ]; then
            echo "[steam-service] No $architecture dotnet host available (SDK root is $host_arch). Set WAIFUX_DOTNET_ROOT_${architecture^^} to a $architecture dotnet installation." >&2
            return 1
        fi
        arch_dotnet_root="$DOTNET_ROOT"
    fi
    arch_hostfxr="$(find "$arch_dotnet_root/host/fxr" -maxdepth 1 -type d -name "$RUNTIME_VERSION" 2>/dev/null | head -1)"
    arch_shared="$(find "$arch_dotnet_root/shared/Microsoft.NETCore.App" -maxdepth 1 -type d -name "$RUNTIME_VERSION" 2>/dev/null | head -1)"
    [ -n "$arch_hostfxr" ] || {
        echo "[steam-service] hostfxr $RUNTIME_VERSION for $architecture missing in $arch_dotnet_root." >&2
        return 1
    }
    [ -n "$arch_shared" ] || {
        echo "[steam-service] shared runtime $RUNTIME_VERSION for $architecture missing in $arch_dotnet_root." >&2
        return 1
    }
    cp -f "$arch_dotnet_root/dotnet" "$runtime_destination/dotnet"
    cp -R "$arch_hostfxr" "$runtime_destination/host/fxr/$RUNTIME_VERSION"
    cp -R "$arch_shared" "$runtime_destination/shared/Microsoft.NETCore.App/$RUNTIME_VERSION"
    chmod +x "$runtime_destination/dotnet"
}

published=0
for architecture in $ARCHITECTURES; do
    case "$architecture" in
        arm64)
            publish_architecture arm64 osx-arm64
            published=1
            ;;
        x86_64)
            publish_architecture x86_64 osx-x64
            published=1
            ;;
        *)
            echo "[steam-service] Unsupported architecture: $architecture" >&2
            exit 1
            ;;
    esac
done

[ "$published" -eq 1 ] || {
    echo "[steam-service] No supported architecture was provided." >&2
    exit 1
}

mkdir -p "$DEST_ROOT/Licenses"
cp -f "$ROOT/SteamService/Licenses/LGPL-2.1.txt" "$DEST_ROOT/Licenses/"
cp -f "$ROOT/SteamService/Licenses/SteamKit2-NOTICE.txt" "$DEST_ROOT/Licenses/"
cp -f "$ROOT/SteamService/Licenses/DepotDownloader-NOTICE.txt" "$DEST_ROOT/Licenses/"

echo "[steam-service] Embedded service built at $DEST_ROOT"
