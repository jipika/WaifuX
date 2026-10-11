#!/usr/bin/env python3
"""Test actual descendant shutdown and process identity checks in isolation."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='waifux-child-cleanup-') as folder:
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-swift-version', '6',
        str(ROOT / 'BackgroundAgent/BackgroundChildProcessCleanup.swift'),
        str(ROOT / 'Tests/BackgroundChildCleanupRegression.swift'), '-o', str(binary)], check=True)
    unrelated = subprocess.Popen(['/bin/sleep', '60'])
    try:
        subprocess.run([str(binary), str(unrelated.pid)], check=True, timeout=15)
        assert unrelated.poll() is None, 'Unrelated process was terminated'
    finally:
        if unrelated.poll() is None:
            unrelated.terminate()
        unrelated.wait(timeout=5)
