#!/usr/bin/env python3
"""Exercise both preference ownership roles without reading/writing real settings."""
from pathlib import Path
import os
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='waifux-preferences-regression-') as directory:
    for helper in (False, True):
        suite = 'com.waifux.test.preferences.' + uuid.uuid4().hex
        output = Path(directory) / ('helper' if helper else 'ui')
        command = ['swiftc', '-swift-version', '6'] + (['-D', 'WAIFUX_HELPER'] if helper else []) + [str(ROOT / name) for name in ['BackgroundAgent/BackgroundAgentWire.swift', 'BackgroundAgent/BackgroundRuntimeRole.swift', 'BackgroundAgent/WaifuXPreferences.swift', 'Tests/BackgroundPreferencesRegression.swift']] + ['-o', str(output)]
        subprocess.run(command, check=True)
        try:
            subprocess.run([str(output)], env=dict(os.environ, WAIFUX_HELPER_TEST_SUITE=suite), check=True)
        finally:
            subprocess.run(['defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
