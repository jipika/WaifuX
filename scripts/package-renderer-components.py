#!/usr/bin/env python3
"""Prepare signed/notarized renderer updates from prebuilt Resources; never builds or publishes.

The companion workflow publishes immutable assets first and updates the feed last.
Only run when packaging/signing has been explicitly authorized; local builds/tests are paused.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from renderer_component_versions import FILES, fingerprints, read_feed, source_path, sync_versions, version
from renderer_coremedia_compat import verify as verify_renderer_coremedia

ROOT = Path(__file__).resolve().parents[1]
TEAM = "SRHKTRJ83W"


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def prepare_dependencies(binary: Path, component: str, relative_path: str) -> None:
    """Make DXC relocatable and refuse dependencies absent from the component payload."""
    if component == "wgpu" and relative_path == "wallpaper-wgpu":
        verify_renderer_coremedia(binary)
    dependencies = [line.strip().split(" (compatibility version", 1)[0]
                    for line in run("otool", "-L", str(binary)).splitlines()[1:]]
    if relative_path.endswith(".dylib"):
        dependencies = dependencies[1:]  # LC_ID_DYLIB is not a dependency.
        run("install_name_tool", "-id", "@rpath/libdxcompiler.dylib", str(binary))
    for dependency in dependencies:
        if component == "wgpu" and Path(dependency).name == "libdxcompiler.dylib":
            replacement = "@loader_path/lib/libdxcompiler.dylib"
            if dependency != replacement:
                run("install_name_tool", "-change", dependency, replacement, str(binary))
        elif dependency.startswith(("/usr/lib/", "/System/Library/")):
            continue
        elif dependency.startswith("@rpath/libswift") and dependency.endswith(".dylib"):
            continue  # Swift's OS-provided runtime, resolved by the existing binary's rpaths.
        else:
            raise ValueError(f"{binary.name}: unbundled dependency {dependency}; rebuild a self-contained binary")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", choices=[*FILES, "all"], required=True)
    parser.add_argument("--minimum-app-version", required=True)
    parser.add_argument("--maximum-app-version", required=True)
    parser.add_argument("--minimum-system-version", default="14.4")
    parser.add_argument("--notes-file", type=Path, help="Optional release notes; no changelog is required")
    parser.add_argument("--previous-feed", type=Path, required=True)
    parser.add_argument("--resources", type=Path, default=ROOT / "Resources")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--release-id", default="", help="Optional CI run-attempt suffix for publication retries")
    parser.add_argument("--notary-profile", required=True)
    args = parser.parse_args()
    if args.release_id and not re.fullmatch(r"[0-9]+-[0-9]+", args.release_id):
        raise ValueError("release-id must have the form runID-attempt")
    if version(args.minimum_app_version) > version(args.maximum_app_version):
        raise ValueError("minimum-app-version must not exceed maximum-app-version")
    version(args.minimum_system_version)
    notes = args.notes_file.read_text(encoding="utf-8").strip() if args.notes_file else ""
    if len(notes) > 16000:
        raise ValueError("Release notes must not exceed 16000 characters")
    previous = read_feed(args.previous_feed)
    components = list(FILES) if args.component == "all" else [args.component]
    # Never overwrite an earlier output folder or mutate source binaries.
    args.output.mkdir(parents=True, exist_ok=False)
    compatibility = {"minimumAppVersion": args.minimum_app_version,
                     "maximumAppVersion": args.maximum_app_version,
                     "minimumSystemVersion": args.minimum_system_version,
                     "protocolVersion": 1}
    records = sync_versions(args.resources, components, previous, compatibility)
    pending = []
    for component in components:
        expected = {"component": component, **records[component], **compatibility}
        already_published = all(any(
            item.get("architecture") == arch and all(item.get(key) == value for key, value in expected.items())
            for item in previous["releases"]
        ) for arch in ("arm64", "x86_64"))
        if not already_published:
            pending.append(component)
    if not pending:
        # No tag file: the workflow skips publication and does not re-sign/re-notarize unchanged inputs.
        return
    components = pending
    tag_identity = {"components": {component: records[component] for component in components},
                    **compatibility}
    tag_suffix = hashlib.sha256(json.dumps(tag_identity, sort_keys=True).encode()).hexdigest()[:12]
    tag_versions = "-".join(f"{component}-{records[component]['version']}-r{records[component]['revision']}"
                            for component in components)
    tag = f"renderer-{tag_versions}-{tag_suffix}"
    if args.release_id:
        tag += f"-{args.release_id}"
    base_url = f"https://github.com/jipika/WaifuX/releases/download/{tag}"
    identity = os.environ["APPLE_SIGNING_IDENTITY"]
    if not identity.startswith("Developer ID Application:"):
        raise ValueError("APPLE_SIGNING_IDENTITY must be a Developer ID Application identity")
    releases = []
    with tempfile.TemporaryDirectory(prefix="waifux-components-") as scratch_name:
        scratch = Path(scratch_name)
        notarize = scratch / "payload"
        notarize.mkdir()
        for component in components:
            record = records[component]
            for arch in ("arm64", "x86_64"):
                file_entries = []
                payload = notarize / f"{component}-{arch}"
                for path in FILES[component]:
                    source = source_path(args.resources, path, arch)
                    destination = payload / path
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    arches = run("lipo", "-archs", str(source)).split()
                    if arch not in arches:
                        raise ValueError(f"{source} does not contain {arch}")
                    if len(arches) > 1:
                        run("lipo", str(source), "-thin", arch, "-output", str(destination))
                    else:
                        shutil.copyfile(source, destination)
                    destination.chmod(0o755)
                    prepare_dependencies(destination, component, path)
                    load_commands = run("otool", "-l", str(destination))
                    deployment_targets = []
                    for block in load_commands.split("Load command ")[1:]:
                        field = "minos" if re.search(r"^\s*cmd LC_BUILD_VERSION\s*$", block, re.M) else (
                            "version" if re.search(r"^\s*cmd LC_VERSION_MIN_MACOSX\s*$", block, re.M) else None)
                        if field:
                            match = re.search(rf"^\s*{field}\s+([0-9]+(?:\.[0-9]+){{0,3}})\s*$", block, re.M)
                            if match:
                                deployment_targets.append(match.group(1))
                    if not deployment_targets:
                        raise ValueError(f"{source}: missing macOS deployment target")
                    if any(version(target) > version(args.minimum_system_version) for target in deployment_targets):
                        raise ValueError(f"{source}: deployment target exceeds --minimum-system-version")
                    if not 0 < destination.stat().st_size <= 512 * 1024 * 1024:
                        raise ValueError(f"{source}: exceeds client file size limit")
                    signing_id = f"com.waifux.component.{component}.{Path(path).name}"
                    command = ["codesign", "--force", "--timestamp", "--options", "runtime",
                               "--identifier", signing_id, "--sign", identity]
                    if component == "wgpu" and path == "wallpaper-wgpu":
                        command += ["--entitlements", str(ROOT / "WallpaperRenderer.entitlements")]
                    run(*command, str(destination))
                    requirement = (f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
                                   'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
                                   f'and identifier "{signing_id}"')
                    run("codesign", "--verify", "--strict", "--all-architectures",
                        "-R", requirement, str(destination))
                    asset_name = f"{component}-{record['revision']}-{arch}-{Path(path).name}"
                    asset = args.output / asset_name
                    shutil.copyfile(destination, asset)
                    with asset.open("rb") as stream:
                        checksum = hashlib.file_digest(stream, "sha256").hexdigest()
                    file_entries.append({"path": path, "url": f"{base_url}/{asset_name}",
                                         "size": asset.stat().st_size,
                                         "sha256": checksum})
                releases.append({"component": component, "version": record["version"], "revision": record["revision"],
                                 "architecture": arch, "protocolVersion": 1,
                                 "minimumAppVersion": args.minimum_app_version,
                                 "maximumAppVersion": args.maximum_app_version,
                                 "minimumSystemVersion": args.minimum_system_version,
                                 "notes": notes, "files": file_entries,
                                 "sourceSHA256": record["sourceSHA256"]})
        for component in components:
            if fingerprints(args.resources.resolve(), component) != records[component]["sourceSHA256"]:
                raise ValueError(f"{component}: source files changed during packaging")
        archive = scratch / "components.zip"
        run("ditto", "-c", "-k", "--keepParent", str(notarize), str(archive))
        result = json.loads(run("xcrun", "notarytool", "submit", str(archive),
                                "--keychain-profile", args.notary_profile, "--wait", "--output-format", "json"))
        if result.get("status") != "Accepted":
            raise ValueError(f"Notarization failed: {result.get('id')} {result.get('status')}")
    # Preserve older compatibility ranges for clients that cannot use the newest component.
    superseded = {(r["component"], r["architecture"], r["minimumAppVersion"], r["maximumAppVersion"], r["minimumSystemVersion"])
                  for r in releases}
    retained = [r for r in previous["releases"]
                if (r["component"], r["architecture"], r["minimumAppVersion"], r["maximumAppVersion"], r["minimumSystemVersion"])
                not in superseded]
    feed = {"schemaVersion": 1, "releases": retained + releases}
    identities = {(item["component"], item["architecture"], item["revision"]) for item in feed["releases"]}
    if len(identities) != len(feed["releases"]):
        raise ValueError("Duplicate component release identity")
    if len(feed["releases"]) > 60:
        raise ValueError("Feed exceeds 60 entries; retire obsolete compatibility ranges explicitly")
    encoded = json.dumps(feed, ensure_ascii=False, indent=2) + "\n"
    if len(encoded.encode()) > 256 * 1024:
        raise ValueError("Feed exceeds client size limit")
    (args.output / "components.json").write_text(encoded)
    (args.output / "release-tag.txt").write_text(tag + "\n")
    title = "Renderer components: " + ", ".join(
        f"{component} {records[component]['version']} (r{records[component]['revision']})"
        for component in components)
    (args.output / "release-title.txt").write_text(title + "\n")


if __name__ == "__main__":
    main()
