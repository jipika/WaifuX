#!/usr/bin/env python3
"""Test a signed nested Helper through SMAppService in an isolated outer app."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
location = parser.add_mutually_exclusive_group(required=True)
location.add_argument('--app', type=Path)
location.add_argument('--helper', type=Path, help='Test a standalone signed Helper distribution product')
args = parser.parse_args()
source = args.helper.resolve() if args.helper else args.app.resolve() / 'Contents/Helpers/WaifuXHelper.app'
signing = subprocess.run(['codesign', '-dv', '--verbose=4', str(source)], capture_output=True, text=True, check=True).stderr
match = re.search(r'^Authority=(.+)$', signing, re.M)
if not match:
    parser.error('A certificate-signed Helper is required; ad hoc signing is insufficient')
identity = match.group(1)
label = 'com.waifux.test.registration.' + uuid.uuid4().hex
suite = label + '.preferences'
with tempfile.TemporaryDirectory(prefix='waifux-helper-registration-') as directory:
    directory = Path(directory)
    app = directory / 'RegistrationProbe.app'
    contents = app / 'Contents'
    executable = contents / 'MacOS/RegistrationProbe'
    executable.parent.mkdir(parents=True)
    (contents / 'Helpers').mkdir()
    (contents / 'Library/LaunchAgents').mkdir(parents=True)
    shutil.copytree(source, contents / 'Helpers/WaifuXHelper.app')
    (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': label, 'CFBundleExecutable': 'RegistrationProbe', 'CFBundleName': 'WaifuX Helper Registration Test', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSUIElement': True}))
    plist_name = label + '.plist'
    (contents / 'Library/LaunchAgents' / plist_name).write_bytes(plistlib.dumps({'Label': label, 'BundleProgram': 'Contents/Helpers/WaifuXHelper.app/Contents/MacOS/WaifuXHelper', 'MachServices': {label: True}, 'RunAtLoad': True, 'KeepAlive': False, 'LimitLoadToSessionType': 'Aqua', 'EnvironmentVariables': {'WAIFUX_HELPER_TEST_SERVICE': label, 'WAIFUX_HELPER_TEST_SUITE': suite, 'WAIFUX_HELPER_TEST_ROOT': str(directory)}, 'StandardOutPath': str(directory / 'helper.log'), 'StandardErrorPath': str(directory / 'helper.log')}))
    subprocess.run(['swiftc', '-swift-version', '6', str(ROOT / 'BackgroundAgent/BackgroundAgentWire.swift'), str(ROOT / 'BackgroundAgent/BackgroundAgentRegistration.swift'), str(ROOT / 'Tests/BackgroundHelperRegistrationProbe.swift'), '-o', str(executable)], check=True)
    prefix = directory / 'signer-'
    subprocess.run(['codesign', '-d', '--extract-certificates=' + str(prefix), str(source)], check=True, capture_output=True)
    identity = hashlib.sha1((directory / 'signer-0').read_bytes()).hexdigest()
    # The outer Bundle ID stays unique for LaunchServices/BTM. Its code signing
    # identifier matches the real UI so Release exercises the production trust check.
    signing_result = subprocess.run(['codesign', '--force', '--sign', identity, '--identifier', 'com.waifux.app', str(app)], text=True, capture_output=True)
    if signing_result.returncode:
        raise RuntimeError(signing_result.stderr)

    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    try:
        result = subprocess.run([str(executable), plist_name, label], timeout=30, text=True, capture_output=True)
        print(result.stdout)
        if result.returncode:
            print(result.stderr)
            log = directory / 'helper.log'
            if log.exists():
                print(log.read_text(errors='replace')[-2000:])
            raise SystemExit(result.returncode)
    finally:
        try:
            subprocess.run([str(executable), plist_name, label, '--unregister'], timeout=15, capture_output=True)
        finally:
            subprocess.run(['launchctl', 'bootout', 'gui/' + str(os.getuid()) + '/' + label], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
