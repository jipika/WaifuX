#!/usr/bin/env python3
"""Detect changed Debug code with an unchanged launcher and keep loaded identity stable."""
from pathlib import Path
import hashlib
import json
import selectors
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
checks = 0

def check(condition, label):
    global checks
    assert condition, label
    checks += 1
    print('PASS ' + label)

with tempfile.TemporaryDirectory(prefix='waifux-helper-identity-') as directory:
    root = Path(directory)
    launcher = root / 'IdentityFixture'
    library = root / 'IdentityFixture.debug.dylib'
    source = root / 'library.c'

    def compile_library(value, output):
        source.write_text(f'int identity_fixture_value(void) {{ return {value}; }}\n')
        subprocess.run(['clang', '-dynamiclib', str(source), '-Wl,-install_name,@rpath/' + library.name,
                        '-o', str(output)], check=True)

    compile_library(1, library)
    subprocess.run(['swiftc', '-swift-version', '6', str(ROOT / 'BackgroundAgent/BackgroundAgentWire.swift'),
                    str(ROOT / 'Tests/BackgroundAgentIdentityFixture.swift'), str(library),
                    '-Xlinker', '-rpath', '-Xlinker', str(root), '-o', str(launcher)], check=True)
    launcher_hash = hashlib.sha256(launcher.read_bytes()).hexdigest()
    process = subprocess.Popen([str(launcher), '--wait'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            assert selector.select(10), 'Fixture startup timeout'
        before = json.loads(process.stdout.readline())
        check(before['running'] == before['embedded'] and ':' in before['running'], 'Debug identity includes launcher and loaded library UUIDs')
        check(before['value'] == 1, 'Original process runs the first library')
        replacement = root / 'replacement.dylib'
        compile_library(2, replacement)
        replacement.replace(library)
        process.stdin.write('\n')
        process.stdin.flush()
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stderr
        after = json.loads(stdout.strip())
        check(hashlib.sha256(launcher.read_bytes()).hexdigest() == launcher_hash, 'Rebuild leaves the launcher byte-for-byte unchanged')
        check(after['running'] == before['running'] and after['value'] == 1, 'Running identity comes from loaded memory, not the new file')
        check(after['embedded'] != before['embedded'], 'Changed Debug library changes embedded code identity')
        check(after['running'] != after['embedded'], 'Rebuilt Debug code is detected as requiring a Helper upgrade')
        fresh = json.loads(subprocess.check_output([str(launcher)], text=True))
        check(fresh['running'] == fresh['embedded'] == after['embedded'] and fresh['value'] == 2, 'Restarted process matches and runs the rebuilt library')
        library.unlink()
        # The fixture cannot launch without its linked library; inspect the host
        # with an independently compiled probe using the same production parser.
        probe_source = root / 'MissingLibrary.swift'
        probe_source.write_text('import Foundation\n@main enum Probe { static func main() { print(BackgroundAgentBuildIdentity.executable(URL(fileURLWithPath: CommandLine.arguments[1])) == nil ? "missing" : "present") } }\n')
        probe = root / 'missing-library'
        subprocess.run(['swiftc', '-swift-version', '6', str(ROOT / 'BackgroundAgent/BackgroundAgentWire.swift'),
                        str(probe_source), '-o', str(probe)], check=True)
        check(subprocess.check_output([str(probe), str(launcher)], text=True).strip() == 'missing', 'Missing linked Debug library fails identity validation')
        unrelated = root / 'missing-library.debug.dylib'
        compile_library(3, unrelated)
        check(subprocess.check_output([str(probe), str(probe)], text=True).strip() == 'present', 'Unlinked stale Debug file does not affect a normal executable')
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
print(f'HELPER_BUILD_IDENTITY_REGRESSION_PASSED checks={checks}')
