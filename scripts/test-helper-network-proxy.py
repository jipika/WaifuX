#!/usr/bin/env python3
"""Test the production network actor through local HTTP proxy/origin fixtures."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import subprocess
import tempfile
import threading
import uuid

ROOT = Path(__file__).resolve().parents[1]
started = threading.Event()
release = threading.Event()
requests = []


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        requests.append((self.server.fixture_kind, self.path))
        if self.server.fixture_kind == 'proxy':
            if self.path.endswith('/slow'):
                started.set()
                if not release.wait(15):
                    self.send_error(504)
                    return
                data = b'slow-proxy'
            else:
                data = b'proxy'
        elif self.path == '/started':
            data = b'1' if started.is_set() else b'0'
        elif self.path == '/release':
            release.set()
            data = b'released'
        else:
            data = b'origin'
        self.send_response(200)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


suite = 'com.waifux.test.network-proxy.' + uuid.uuid4().hex
servers = []
try:
    for kind in ('proxy', 'origin'):
        server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        server.fixture_kind = kind
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
    with tempfile.TemporaryDirectory(prefix='waifux-network-proxy-regression-') as folder:
        binary = Path(folder) / 'network-proxy'
        sources = [
            'BackgroundAgent/BackgroundAgentWire.swift',
            'BackgroundAgent/BackgroundRuntimeRole.swift',
            'BackgroundAgent/WaifuXPreferences.swift',
            'Models/NetworkError.swift', 'Models/NetworkState.swift',
            'Services/NetworkMonitor.swift', 'Services/NetworkService.swift',
            'Utilities/GitHubHosts.swift', 'Tests/NetworkProxyRegression.swift',
        ]
        subprocess.run(['swiftc', '-swift-version', '6', '-D', 'DEBUG', '-D', 'WAIFUX_HELPER',
                        *[str(ROOT / source) for source in sources],
                        '-o', str(binary)], check=True)
        subprocess.run([str(binary)], env=dict(os.environ,
                       WAIFUX_HELPER_TEST_SUITE=suite,
                       WAIFUX_PROXY_TEST_PORT=str(servers[0].server_port),
                       WAIFUX_PROXY_TEST_ORIGIN_PORT=str(servers[1].server_port)),
                       check=True, timeout=30)
        assert ('proxy', 'http://waifux-proxy-regression.invalid/initial') in requests, requests
        assert ('proxy', 'http://waifux-proxy-regression.invalid/slow') in requests, requests
        assert ('origin', '/origin') in requests, requests
        print('PASS fixture confirms the unresolvable destination reached the real local proxy')
finally:
    release.set()
    for server in servers:
        server.shutdown()
        server.server_close()
    subprocess.run(['defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
