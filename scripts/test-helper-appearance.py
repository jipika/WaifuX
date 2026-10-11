#!/usr/bin/env python3
"""Exercise the production theme manager and an AppKit hosted material in both roles."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    'BackgroundAgent/BackgroundAgentWire.swift', 'BackgroundAgent/BackgroundRuntimeRole.swift',
    'BackgroundAgent/WaifuXPreferences.swift', 'DesignSystem/ThemeManager.swift',
    'Tests/HelperAppearanceRegression.swift',
]
with tempfile.TemporaryDirectory(prefix='waifux-appearance-regression-') as directory:
    for role in ('ui', 'helper'):
        binary = Path(directory) / role
        command = ['swiftc', '-swift-version', '6']
        if role == 'helper':
            command += ['-D', 'WAIFUX_HELPER']
        subprocess.run([*command, *[str(ROOT / name) for name in SOURCES], '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)
print('HELPER_APPEARANCE_BOTH_ROLES_PASSED')
