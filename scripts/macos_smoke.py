#!/usr/bin/env python3
"""Check that the packaged Release app stays running on the macOS runner."""
from pathlib import Path
import plistlib
import subprocess
import sys
import time

app = Path(sys.argv[1]).resolve()
with (app / "Contents/Info.plist").open("rb") as stream:
    executable = plistlib.load(stream)["CFBundleExecutable"]
process = subprocess.Popen([str(app / "Contents/MacOS" / executable)])
try:
    time.sleep(5)
    if process.poll() is not None:
        raise RuntimeError(f"The packaged app exited with status {process.returncode}")
    print("Packaged macOS Release app remained running.")
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
