#!/usr/bin/env python3
"""Exercise production battery ownership and Helper/main auto-pause identity."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='waifux-battery-pause-regression-') as folder:
    for name, sources in [
        ('battery-pause', ['Services/WallpaperBatteryPauseOwnership.swift',
                          'Tests/WallpaperBatteryPauseRegression.swift']),
        ('app-identity', ['Services/WallpaperAutoPauseApplicationIdentity.swift',
                          'Tests/WallpaperAutoPauseApplicationIdentityRegression.swift']),
    ]:
        binary = Path(folder) / name
        subprocess.run(['swiftc', '-swift-version', '6',
                        *[str(ROOT / source) for source in sources],
                        '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
