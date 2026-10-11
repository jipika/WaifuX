#!/usr/bin/env python3
"""Test production extension lifecycle/retry gates without AVFoundation or playback."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='waifux-extension-lifecycle-') as folder:
    binary = Path(folder) / 'lifecycle-regression'
    sources = [
        'WaifuXWallpaperExtension/WallpaperContextGeneration.swift',
        'WaifuXWallpaperExtension/VideoPlaybackRecoveryPolicy.swift',
        'Tests/WallpaperExtensionLifecycleRegression.swift',
    ]
    subprocess.run(['swiftc', '-swift-version', '6',
                    *[str(ROOT / source) for source in sources],
                    '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=15)
    # Keep the existing cross-connection teardown contract in the same gate.
    source_guard = Path(folder) / 'multi-display-contract'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6',
                    str(ROOT / 'Tests/ExtensionMultiDisplayConnectionRegression.swift'),
                    '-o', str(source_guard)], check=True, timeout=60)
    subprocess.run([str(source_guard)], check=True, timeout=15)
