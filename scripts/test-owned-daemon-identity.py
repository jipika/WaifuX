#!/usr/bin/env python3
"""Exercise production PID identity and signals without touching the live daemon."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='waifux-daemon-identity-') as folder:
    binary = Path(folder) / 'regression'
    subprocess.run([
        'swiftc', '-swift-version', '6',
        str(ROOT / 'Utilities/OwnedProcessIdentity.swift'),
        str(ROOT / 'Tests/OwnedDaemonIdentityRegression.swift'),
        '-o', str(binary),
    ], check=True)
    subprocess.run([str(binary), folder], check=True, timeout=15)
