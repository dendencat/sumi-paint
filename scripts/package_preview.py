#!/usr/bin/env python3
"""Package native previews and record the exact source and archive checksum."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PLATFORMS = ("macOS", "iOS-simulator")


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def package(platform, app):
    app = app.resolve()
    info_path = app / ("Contents/Info.plist" if platform == "macOS" else "Info.plist")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    expected_platform = "MacOSX" if platform == "macOS" else "iPhoneSimulator"
    if expected_platform not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError("The app does not match the requested preview platform")
    executable = app / ("Contents/MacOS" if platform == "macOS" else "") / info["CFBundleExecutable"]
    architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()
    if set(architectures) != {"arm64", "x86_64"}:
        raise ValueError("Both Apple Silicon and Intel builds are required")
    commit = os.environ.get("GITHUB_SHA") or subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    folder_name = f"SumiPaint-{platform}-Preview"
    stage = ROOT / "build/package-staging" / folder_name
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    subprocess.run(["ditto", str(app), str(stage / app.name)], check=True)
    for name in ("LICENSE.md", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(ROOT / name, stage / name)
    shutil.copy2(ROOT / "docs/preview-install.md", stage / "INSTALL.md")
    metadata = {
        "platform": platform, "commit": commit, "architectures": sorted(architectures),
        "bundle_identifier": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
        "build_number": info["CFBundleVersion"],
        "minimum_os": info.get("LSMinimumSystemVersion", info.get("MinimumOSVersion")),
        "signing": "ad-hoc; not notarized" if platform == "macOS" else "simulator only",
        "workflow_run": os.environ.get("GITHUB_RUN_ID"),
    }
    (stage / "build-info.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    output = ROOT / "build/preview"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"{folder_name}.zip"
    if archive.exists():
        archive.unlink()
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(archive)], check=True)
    metadata.update(archive=archive.name, sha256=checksum(archive))
    (output / f"{platform}-build.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print(f"Packaged {archive.name}: {metadata['version']} ({metadata['build_number']}), {commit[:12]}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("platform", choices=PLATFORMS)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    package(args.platform, args.app)
