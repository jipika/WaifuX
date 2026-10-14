#!/usr/bin/env python3
"""Run production registration, display and cloud-file regressions without system changes."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CASES = [
    ('helper-registration-policy', [
        'BackgroundAgent/BackgroundAgentWire.swift', 'BackgroundAgent/BackgroundAgentRegistration.swift',
        'Tests/BackgroundAgentRegistrationRegression.swift',
    ]),
    ('helper-display-control', [
        'Utilities/NSScreen+Wallpaper.swift', 'VideoRendererScreenRouting.swift',
        'Tests/HelperDisplayControlSimulation.swift',
    ]),
    ('renderer-routing-regression', [
        'VideoRendererScreenRouting.swift', 'Tests/VideoRendererScreenRoutingTests.swift',
    ]),
    ('wake-display-relink-regression', [
        'Utilities/NSScreen+Wallpaper.swift', 'Models/SchedulerConfig.swift',
        'Tests/WakeDisplayRelinkRegression.swift',
    ]),
    ('cloud-file-regression', [
        'Services/Sync/CloudSyncModels.swift', 'Services/Sync/CloudSyncError.swift',
        'Services/Sync/CloudSyncFileEngine.swift', 'Tests/CloudSyncFileEngineRegression.swift',
    ]),
]

with tempfile.TemporaryDirectory(prefix='waifux-display-simulation-') as folder:
    for name, sources in CASES:
        binary = Path(folder) / name
        subprocess.run(['swiftc', '-swift-version', '5',
                        *[str(ROOT / source) for source in sources],
                        '-o', str(binary)], check=True, cwd=ROOT)
        subprocess.run([str(binary)], check=True, cwd=ROOT)
print('HELPER_DISPLAY_SIMULATIONS_PASSED')
