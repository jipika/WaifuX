#!/usr/bin/env python3
"""Check/repair the prebuilt renderer's CoreMedia C imports without launching it.

The macOS 27 SDK redirects CoreMedia to libswiftCoreMedia for deployment targets
below 10.14.4. Rust's default x86_64 target is 10.12, so these FFmpeg C imports can
end up bound to a Swift overlay that does not export them on customers' systems.
Future renderer builds must set MACOSX_DEPLOYMENT_TARGET=14.4 before running Cargo.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
COREMEDIA = "/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia"
SWIFT_OVERLAYS = {"@rpath/libswiftCoreMedia.dylib", "/usr/lib/swift/libswiftCoreMedia.dylib"}
# Only the four observed, longstanding C exports may be rebound. Never redirect
# genuine Swift overlay symbols (or unknown future imports) to another library.
REPAIRABLE = {
    "_CMBlockBufferCreateWithMemoryBlock",
    "_CMSampleBufferCreate",
    "_CMVideoFormatDescriptionCreate",
    "_kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms",
}


def run(*args: str) -> str:
    result = subprocess.run(args, text=True, capture_output=True, check=True)
    return result.stdout


def overlay_imports(nm_output: str) -> set[str]:
    return set(re.findall(r"\(undefined\).*?external\s+(\S+)\s+\(from libswiftCoreMedia\)", nm_output))


def inspect(binary: Path) -> tuple[set[str], set[str]]:
    symbols, dependencies = set(), set()
    # Inspect every slice, including Intel when packaging on Apple Silicon.
    arches = run("lipo", "-archs", str(binary)).split()
    if not arches:
        raise ValueError(f"{binary}: no Mach-O architectures")
    for arch in arches:
        symbols.update(overlay_imports(run("nm", "-arch", arch, "-m", "-u", str(binary))))
        lines = run("otool", "-arch", arch, "-L", str(binary)).splitlines()[1:]
        dependencies.update(line.strip().split(" (compatibility version", 1)[0] for line in lines)
    return symbols, dependencies & SWIFT_OVERLAYS


def verify(binary: Path) -> None:
    symbols, overlays = inspect(binary)
    # wallpaper-wgpu is a Rust/C renderer. Any direct Swift CoreMedia dependency
    # needs review; merely starting on the build machine cannot prove compatibility.
    if symbols or overlays:
        raise ValueError(f"{binary}: incompatible libswiftCoreMedia binding: "
                         f"{', '.join(sorted(symbols or overlays))}; "
                         "rebuild with MACOSX_DEPLOYMENT_TARGET=14.4 or use --repair")


def require_repairable(symbols: set[str], overlays: set[str]) -> None:
    if not symbols or not overlays or symbols - REPAIRABLE:
        raise ValueError("Refusing CoreMedia rewrite: missing or unknown Swift overlay imports: "
                         + ", ".join(sorted(symbols)))


def deployment_targets(load_commands: str) -> list[tuple[int, int, int]]:
    targets = []
    for block in load_commands.split("Load command ")[1:]:
        field = "minos" if re.search(r"^\s*cmd LC_BUILD_VERSION\s*$", block, re.M) else (
            "version" if re.search(r"^\s*cmd LC_VERSION_MIN_MACOSX\s*$", block, re.M) else None)
        if field:
            match = re.search(rf"^\s*{field}\s+(\d+(?:\.\d+){{0,2}})\s*$", block, re.M)
            if match:
                parts = [int(value) for value in match.group(1).split(".")]
                targets.append(tuple(parts + [0] * (3 - len(parts))))
    return targets


def verify_macos_floor(binary: Path, minimum: str = "14.4") -> None:
    parts = [int(value) for value in minimum.split(".")]
    maximum_target = tuple(parts + [0] * (3 - len(parts)))
    for arch in run("lipo", "-archs", str(binary)).split():
        targets = deployment_targets(run("otool", "-arch", arch, "-l", str(binary)))
        if len(targets) != 1 or targets[0] > maximum_target:
            raise ValueError(f"{binary} ({arch}): deployment target {targets} exceeds supported macOS {minimum} "
                             "or is missing; rebuild native dependencies with that target (do not relabel the binary)")


def repair(binary: Path) -> bool:
    symbols, overlays = inspect(binary)
    if not symbols and not overlays:
        return False
    require_repairable(symbols, overlays)
    # Replace only after the new load command and ad-hoc signature are verified.
    # Failure leaves the caller's original binary intact. No compiler/GPU/App runs.
    with tempfile.TemporaryDirectory(prefix=".coremedia-", dir=binary.parent) as directory:
        staged = Path(directory) / binary.name
        shutil.copy2(binary, staged)
        for dependency in sorted(overlays):
            run("install_name_tool", "-change", dependency, COREMEDIA, str(staged))
        verify(staged)
        run("codesign", "--force", "--sign", "-", "--options", "runtime",
            "--identifier", "com.wallpaper-wgpu.renderer", "--entitlements",
            str(ROOT / "WallpaperRenderer.entitlements"), str(staged))
        run("codesign", "--verify", "--strict", "--all-architectures", str(staged))
        os.replace(staged, binary)
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repair", action="store_true", help="repair known C imports and re-sign ad hoc")
    parser.add_argument("--minimum-macos", choices=["14.4"], help="also check every native dependency's deployment target")
    parser.add_argument("binaries", nargs="+", type=Path)
    args = parser.parse_args()
    try:
        for binary in args.binaries:
            changed = repair(binary) if args.repair else False
            verify(binary)
            if args.minimum_macos:
                verify_macos_floor(binary, args.minimum_macos)
            print(f"COREMEDIA_{'REPAIRED' if changed else 'CHECK_PASSED'} {binary}")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        parser.exit(1, f"CoreMedia compatibility check failed: {detail}\n")


if __name__ == "__main__":
    main()
