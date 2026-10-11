#!/usr/bin/env python3
"""Record versions for changed prebuilt components. No builds, signing, Git, or log files."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
FEED_URL = "https://github.com/jipika/WaifuX/releases/download/renderer-components/components.json"
FILES = {
    "wgpu": ["wallpaper-wgpu", "dxc", "lib/libdxcompiler.dylib"],
    "web": ["wallpaperengine-cli", "ffmpeg"],
    "video": ["wallpaper-video-renderer"],
}


def version(value: str) -> tuple[int, ...]:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,9}(?:\.[0-9]{1,9}){0,3}", value):
        raise ValueError(f"Invalid numeric component version: {value}")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (4 - len(parts))


def next_version(value: str) -> str:
    parts = [int(part) for part in value.split(".")]
    parts += [0] * max(0, 3 - len(parts))
    parts[-1] += 1
    result = ".".join(map(str, parts))
    version(result)
    return result


def source_path(resources: Path, path: str, arch: str) -> Path:
    if arch == "arm64" or path == "wallpaper-video-renderer":
        return resources / path
    if path == "lib/libdxcompiler.dylib":
        return resources / "libdxcompiler-x86_64.dylib"
    return resources / f"{path}-x86_64"


def fingerprints(resources: Path, component: str) -> dict[str, str]:
    paths = {source_path(resources, path, arch)
             for path in FILES[component] for arch in ("arm64", "x86_64")}
    result = {}
    for path in sorted(paths):
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            before = os.fstat(stream.fileno())
            if before.st_size <= 0:
                raise ValueError(f"Empty component file: {path}")
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
            after = os.fstat(stream.fileno())
        current = path.stat()
        identity = lambda stat: (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(current):
            raise ValueError(f"Component changed while recording its version: {path}")
        result[path.relative_to(resources).as_posix()] = digest.hexdigest()
    return result


def read_feed(path: Path | None = None, refresh: bool = False) -> dict:
    if refresh:
        try:
            with urlopen(FEED_URL, timeout=60) as response:
                if urlsplit(response.geturl()).scheme != "https":
                    raise ValueError("Component feed redirect must use HTTPS")
                data = response.read(256 * 1024 + 1)
        except HTTPError as error:
            if error.code != 404:
                raise
            data = b'{"schemaVersion":1,"releases":[]}'
        if len(data) > 256 * 1024:
            raise ValueError("Component feed exceeds size limit")
        feed = json.loads(data)
    elif path:
        feed = json.loads(path.read_text(encoding="utf-8"))
    else:
        feed = {"schemaVersion": 1, "releases": []}
    if not isinstance(feed, dict) or feed.get("schemaVersion") != 1 or not isinstance(feed.get("releases"), list):
        raise ValueError("Invalid component feed")
    if len(feed["releases"]) > 60 or any(not isinstance(entry, dict) for entry in feed["releases"]):
        raise ValueError("Invalid component release list")
    return feed


def validate_record(record: dict) -> None:
    if not isinstance(record, dict):
        raise ValueError("Invalid component version record")
    version(record.get("version"))
    revision = record.get("revision")
    if type(revision) is not int or not 0 < revision <= 1_000_000_000:
        raise ValueError("Invalid component revision")


def sync_versions(resources: Path, components: list[str], feed: dict,
                  publication_compatibility: dict | None = None) -> dict:
    resources = resources.resolve()
    manifest = resources / "renderer-components.json"
    lock_id = hashlib.sha256(str(manifest).encode()).hexdigest()[:24]
    lock_path = Path(tempfile.gettempdir()) / f"waifux-component-versions-{lock_id}.lock"
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        records = json.loads(manifest.read_text(encoding="utf-8"))
        for component in components:
            current_hashes = fingerprints(resources, component)
            candidates = [records[component]] + [entry for entry in feed["releases"]
                                                 if entry.get("component") == component]
            for entry in candidates:
                validate_record(entry)
            highest = max(entry["revision"] for entry in candidates)
            latest = [entry for entry in candidates if entry["revision"] == highest]
            # Equal numbers with different payloads are a conflict, even if one matches locally.
            if all(entry.get("sourceSHA256") == current_hashes for entry in latest):
                selected = max(latest, key=lambda entry: version(entry["version"]))
                display_version, revision = selected["version"], highest
            else:
                newest_version = max((entry["version"] for entry in candidates), key=version)
                display_version, revision = next_version(newest_version), highest + 1
            # Client identities are component + architecture + revision. A new compatibility
            # range cannot reuse a published identity while retaining the older range.
            if publication_compatibility is not None and any(
                entry.get("component") == component and entry["revision"] == revision
                and any(entry.get(key) != value for key, value in publication_compatibility.items())
                for entry in feed["releases"]
            ):
                revision = highest + 1
            record = {"version": display_version, "revision": revision, "sourceSHA256": current_hashes}
            validate_record(record)
            records[component] = record
        # No partial manifest if a later component is missing, or the inputs change during hashing.
        for component in components:
            if fingerprints(resources, component) != records[component]["sourceSHA256"]:
                raise ValueError(f"{component}: inputs changed before saving the version")
        encoded = json.dumps(records, ensure_ascii=False, indent=2) + "\n"
        if manifest.read_text(encoding="utf-8") != encoded:
            temporary_path = None
            try:
                with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=resources,
                                                 prefix=".renderer-components-", delete=False) as output:
                    temporary_path = Path(output.name)
                    output.write(encoded)
                    output.flush()
                    os.fsync(output.fileno())
                temporary_path.chmod(0o644)
                os.replace(temporary_path, manifest)
            finally:
                if temporary_path and temporary_path.exists():
                    temporary_path.unlink()
        return records


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", nargs="+", choices=[*FILES, "all"], default=["all"])
    parser.add_argument("--resources", type=Path, default=ROOT / "Resources")
    feed_options = parser.add_mutually_exclusive_group()
    feed_options.add_argument("--previous-feed", type=Path)
    feed_options.add_argument("--refresh-feed", action="store_true",
                              help="Reconcile published revisions before preparing an App release")
    args = parser.parse_args()
    components = list(FILES) if "all" in args.component else list(dict.fromkeys(args.component))
    try:
        sync_versions(args.resources, components, read_feed(args.previous_feed, args.refresh_feed))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
