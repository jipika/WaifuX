#!/usr/bin/env python3
"""Check real read access using the Helper identity, certificate and Group profile."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--helper', type=Path, required=True)
args = parser.parse_args()
source = args.helper.resolve()
subprocess.run(['python3', str(ROOT / 'scripts/verify-helper-provisioning.py'), '--app', str(source)], check=True)
with tempfile.TemporaryDirectory(prefix='waifux-helper-group-probe-') as directory:
    directory = Path(directory)
    app = directory / 'GroupProbe.app'
    contents = app / 'Contents'
    executable = contents / 'MacOS/GroupProbe'
    executable.parent.mkdir(parents=True)
    (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.waifux.app.helper', 'CFBundleExecutable': 'GroupProbe', 'CFBundleName': 'WaifuX Group Access Probe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSUIElement': True}))
    shutil.copy2(source / 'Contents/embedded.provisionprofile', contents / 'embedded.provisionprofile')
    entitlements = directory / 'entitlements.plist'
    prefix = str(directory / 'signer-')
    subprocess.run(['codesign', '-d', '--entitlements', str(entitlements), '--xml', str(source)], check=True, capture_output=True)
    subprocess.run(['codesign', '-d', '--extract-certificates=' + prefix, str(source)], check=True, capture_output=True)
    identity = hashlib.sha1(Path(prefix + '0').read_bytes()).hexdigest()
    subprocess.run(['swiftc', str(ROOT / 'Tests/BackgroundHelperGroupProbe.swift'), '-o', str(executable)], check=True)
    subprocess.run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--entitlements', str(entitlements), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    subprocess.run([str(executable)], check=True, timeout=15)
