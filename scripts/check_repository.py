#!/usr/bin/env python3
"""Validate project metadata and source membership without extra packages."""
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
project = (root / "SumiPaint.xcodeproj/project.pbxproj").read_text()
assert re.search(r"dependencies:\s*\[\s*\]", (root / "Package.swift").read_text()), "Package inventory must be updated when dependencies change"
for platform in ("macOS", "iOS"):
    ET.parse(root / f"SumiPaint.xcodeproj/xcshareddata/xcschemes/SumiPaint-{platform}.xcscheme")
    with (root / f"App/Info-{platform}.plist").open("rb") as file:
        info = plistlib.load(file)
    assert info["CFBundleExecutable"] == "$(EXECUTABLE_NAME)"
    assert info["UTExportedTypeDeclarations"][0]["UTTypeTagSpecification"]["public.filename-extension"] == ["sumipaint"]
    assert f'SumiPaint-{platform}' in project
for folder in ("App", "Sources/DrawingCore"):
    for path in (root / folder).iterdir():
        if path.suffix in (".swift", ".metal"):
            assert path.relative_to(root).as_posix() in project, f"Missing project source: {path}"
assert 'TARGETED_DEVICE_FAMILY = "1,2"' in project, "Both iPhone and iPad must be supported"
assert "MIT License" in (root / "LICENSE.md").read_text()
assert (root / "THIRD_PARTY_NOTICES.md").exists()
with (root / "App/macOS.entitlements").open("rb") as file:
    assert plistlib.load(file)["com.apple.security.app-sandbox"]
print("Repository metadata, platform targets, source membership, and dependency inventory are consistent.")
