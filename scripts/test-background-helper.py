#!/usr/bin/env python3
"""Exercise the built Helper over real launchd/XPC with an isolated preference suite."""
import argparse
import http.server
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--client-source', type=Path, default=ROOT / 'Tests/BackgroundHelperRegression.swift')
parser.add_argument('--scenario', help='Optional focused scenario supported by the selected client')
parser.add_argument('--serve-fixture', action='store_true', help='Serve local media over loopback for real download tests')
parser.add_argument('--allow-desktop-rendering', action='store_true',
    help='Explicitly allow this test to display wallpaper windows on the real desktop; never enable for unattended regression')
args = parser.parse_args()
# A private preference suite does not isolate WindowServer output. Most older
# scenarios display a blue video on actual NSScreens. Refuse them by default.
non_rendering_scenarios = {'startup-quit', 'reconnect-replay', 'reconnect-quit',
    'acknowledged-stop-quit', 'reset-preflight', 'reset-timeout', 'proxy', 'audio-cancel', 'recovery'}
if args.scenario not in non_rendering_scenarios and not args.allow_desktop_rendering:
    parser.error('This scenario renders on the real desktop. Rendering regression is disabled by default; use static/non-rendering checks until machine stability is established.')
# Several non-rendering clients also launch the DEBUG-only UI exit delegate.
# A Release UI ignores that switch and enters normal application startup.
# Reject the product before compiling a client or starting any process. Do not
# use assert here: python -O must not disable this boundary.
if not (args.app.resolve() / 'Contents/MacOS/WaifuX.debug.dylib').is_file():
    parser.error('Helper regression requires a Debug App with WaifuX.debug.dylib; refusing to launch a Release UI')
helper = args.app.resolve() / 'Contents/Helpers/WaifuXHelper.app/Contents/MacOS/WaifuXHelper'
if not helper.is_file():
    parser.error('Embedded Helper executable is missing')
identity = 'com.waifux.test.helper.' + uuid.uuid4().hex
suite = identity + '.preferences'
domain = 'gui/' + str(os.getuid())
with tempfile.TemporaryDirectory(prefix='waifux-helper-regression-') as folder:
    folder = Path(folder)
    client = folder / 'client'
    fixture = folder / 'fixture.mp4'
    subprocess.run(['swiftc', '-swift-version', '5', str(ROOT / 'BackgroundAgent/BackgroundAgentWire.swift'), str(args.client_source.resolve()), '-o', str(client)], check=True)
    if args.allow_desktop_rendering:
        subprocess.run([str(ROOT / 'Resources/ffmpeg'), '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=0x2a5a7a:s=640x360:r=30', '-t', '3', '-c:v', 'h264_videotoolbox', '-allow_sw', '1', '-pix_fmt', 'yuv420p', str(fixture)], check=True)
    else:
        # Non-rendering checks compare file bytes only. They need no encoder,
        # GPU session or playable blue desktop fixture.
        fixture.write_bytes(b'WaifuX non-rendering regression fixture\n')
    server = None
    if args.serve_fixture:
        fixture_bytes = fixture.read_bytes()
        request_counts = {}
        class FixtureHandler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass
            def do_GET(self):
                if self.path == '/stats':
                    payload = json.dumps(request_counts).encode()
                elif self.path == '/html.mp4':
                    payload = b'<!DOCTYPE html><html>Not a video</html>'
                else:
                    payload = fixture_bytes
                if self.path != '/stats':
                    request_counts[self.path] = request_counts.get(self.path, 0) + 1
                self.send_response(200)
                self.send_header('Content-Type', 'application/json' if self.path == '/stats' else 'video/mp4')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                try:
                    if self.path.startswith('/slow'):
                        chunk = max(1, len(payload) // 12)
                        for offset in range(0, len(payload), chunk):
                            self.wfile.write(payload[offset:offset + chunk])
                            self.wfile.flush()
                            time.sleep(0.3)
                    else:
                        self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    log = folder / 'helper.log'
    job = folder / 'job.plist'
    job.write_bytes(plistlib.dumps({'Label': identity, 'ProgramArguments': [str(helper)], 'MachServices': {identity: True}, 'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'EnvironmentVariables': {'WAIFUX_HELPER_TEST_SERVICE': identity, 'WAIFUX_HELPER_TEST_SUITE': suite, 'WAIFUX_HELPER_TEST_ROOT': str(folder), 'WAIFUX_HELPER_TEST_ALLOW_DESKTOP_RENDERING': '1' if args.allow_desktop_rendering else '0'}, 'StandardOutPath': str(log), 'StandardErrorPath': str(log)}))
    probe = subprocess.run([str(args.app.resolve() / 'Contents/MacOS/WaifuX'), '--helper-proxy-probe'], env=dict(os.environ, WAIFUX_HELPER_TEST_SUITE=suite, WAIFUX_HELPER_TEST_ROOT=str(folder)), timeout=30, text=True, capture_output=True)
    print(probe.stdout)
    assert probe.returncode == 0 and 'UI_PROXY_REGRESSION_PASSED' in probe.stdout, probe.stderr
    subprocess.run(['launchctl', 'bootstrap', domain, str(job)], check=True)
    try:
        command = [str(client), identity, str(fixture), str(helper)]
        if args.scenario:
            command.append(args.scenario)
        if server:
            command.append('http://127.0.0.1:' + str(server.server_address[1]))
        result = subprocess.run(command, timeout=180, text=True, capture_output=True,
            env=dict(os.environ, WAIFUX_HELPER_TEST_SERVICE=identity,
                WAIFUX_HELPER_TEST_SUITE=suite, WAIFUX_HELPER_TEST_ROOT=str(folder)))
        print(result.stdout)
        if result.returncode:
            print(result.stderr)
            print(log.read_text(errors='replace')[-12000:] if log.exists() else 'Helper log missing')
            raise SystemExit(result.returncode)
    finally:
        subprocess.run(['launchctl', 'bootout', domain + '/' + identity], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if server:
            server.shutdown()
            server.server_close()
