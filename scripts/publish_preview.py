#!/usr/bin/env python3
"""Publish validated artifacts from a successful main workflow as a prerelease."""
import json
import os
from pathlib import Path
import subprocess
import sys

from package_preview import checksum, PLATFORMS


def validate_packages(folder, commit, run_id):
    packages = []
    for platform in PLATFORMS:
        metadata_path = folder / f"{platform}-build.json"
        metadata = json.loads(metadata_path.read_text())
        expected_name = f"SumiPaint-{platform}-Preview.zip"
        if (metadata["platform"] != platform or metadata["commit"] != commit
                or metadata["workflow_run"] != run_id or metadata["archive"] != expected_name):
            raise ValueError("Preview source or workflow does not match this run")
        if metadata["sha256"] != checksum(folder / expected_name):
            raise ValueError("Preview archive checksum does not match its build metadata")
        packages.append(metadata)
    for name in ("iPhone.png", "iPad.png"):
        if not (folder / name).read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("Both simulator screenshots must be present")
    return packages


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True).strip()


def summary(message):
    print(message)
    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(path, "a") as stream:
            stream.write(message + "\n")


def publish(folder):
    if os.environ.get("GITHUB_REF") != "refs/heads/main" or os.environ.get("GITHUB_EVENT_NAME") not in ("push", "workflow_dispatch"):
        raise ValueError("Only a main push or manual main workflow can publish previews")
    repo, commit = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"]
    run_id, run_number = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_NUMBER"]
    packages = validate_packages(folder, commit, run_id)
    current_main = gh("api", f"repos/{repo}/git/ref/heads/main", "--jq", ".object.sha")
    if current_main != commit:
        summary("Preview publication skipped: a newer main commit is already being built.")
        return
    tag = f"preview-{run_id}"
    existing = json.loads(gh("api", f"repos/{repo}/releases", "--paginate", "--slurp"))
    release = next((item for page in existing for item in page if item["tag_name"] == tag), None)
    if release and release["target_commitish"] != commit:
        raise ValueError("The existing preview release belongs to another commit")
    if release and not release["draft"]:
        required = {package["archive"] for package in packages} | {"manifest.json", "SHA256SUMS", "iPhone.png", "iPad.png"}
        if not required.issubset({asset["name"] for asset in release["assets"]}):
            raise ValueError("The published preview is incomplete")
        summary(f"Preview already published: {release['html_url']}")
        return
    assets = [folder / package["archive"] for package in packages]
    assets += [folder / f"{platform}-build.json" for platform in PLATFORMS]
    assets += [folder / "iPhone.png", folder / "iPad.png"]
    manifest = {"commit": commit, "workflow_run": run_id, "packages": packages,
                "assets": {path.name: checksum(path) for path in assets}}
    manifest_path = folder / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    assets.append(manifest_path)
    checksums = folder / "SHA256SUMS"
    checksums.write_text("".join(f"{checksum(path)}  {path.name}\n" for path in sorted(assets)))
    assets.append(checksums)
    notes_path = folder / "release-notes.md"
    version = packages[0]["version"]
    notes_path.write_text(f"""mainの検証済みプレビュー: **{version} / ビルド {run_number}**

コミット: [{commit[:12]}](https://github.com/{repo}/commit/{commit})  
検証結果: [GitHub Actions](https://github.com/{repo}/actions/runs/{run_id})

- `SumiPaint-macOS-Preview.zip`: Mac用。Apple Silicon・Intel対応。アドホック署名済み、Appleの公証は未実施です。
- `SumiPaint-iOS-simulator-Preview.zip`: XcodeのiPhone・iPadシミュレーター用。実機にはインストールできません。
- `iPhone.png` / `iPad.png`: このビルドを起動して取得した画面。
- `manifest.json` / `SHA256SUMS`: 元のコミット、ビルド情報、ファイルのSHA-256。

[インストール手順](https://github.com/{repo}/blob/{commit}/docs/preview-install.md)  
筆圧や描画遅延の感触は実機での確認が必要です。
""")
    if release:
        gh("release", "upload", tag, *map(str, assets), "--clobber", "--repo", repo)
        gh("release", "edit", tag, "--notes-file", str(notes_path), "--repo", repo)
    else:
        gh("release", "create", tag, *map(str, assets), "--repo", repo, "--target", commit,
           "--title", f"Preview #{run_number} ({commit[:7]})", "--notes-file", str(notes_path), "--draft", "--prerelease")
    gh("release", "edit", tag, "--draft=false", "--prerelease", "--latest=false", "--repo", repo)
    summary(f"Preview published: https://github.com/{repo}/releases/tag/{tag}")


if __name__ == "__main__":
    publish(Path(sys.argv[1]).resolve())
