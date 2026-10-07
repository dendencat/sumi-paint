#!/usr/bin/env python3
"""Launch the built app on one iPhone and one iPad, then capture their screens."""
from pathlib import Path
import json
import re
import subprocess
import sys
import time

app = Path(sys.argv[1]).resolve()
assert app.is_dir(), f"Missing simulator app: {app}"
output = Path("build/screenshots")
output.mkdir(parents=True, exist_ok=True)
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], timeout=60))["devices"]
runtime_order = sorted(devices, key=lambda key: tuple(map(int, re.findall(r"\d+", key))), reverse=True)
sdk_version = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True, timeout=30).strip()
matching_runtime = "iOS-" + sdk_version.replace(".", "-")
runtime_order.sort(key=lambda key: matching_runtime not in key)
for family in ("iPhone", "iPad"):
    candidate = next((device for runtime in runtime_order if "iOS" in runtime
                      for device in devices[runtime] if device["name"].startswith(family) and device.get("isAvailable")), None)
    assert candidate is not None, f"No available {family} simulator"
    udid = candidate["udid"]
    print(f"Launching {candidate['name']}", flush=True)
    if candidate["state"] != "Booted":
        subprocess.run(["xcrun", "simctl", "boot", udid], check=True, timeout=60)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, timeout=240)
    print("Installing app", flush=True)
    subprocess.run(["xcrun", "simctl", "install", udid, str(app)], check=True, timeout=180)
    print("Starting app", flush=True)
    subprocess.run(["xcrun", "simctl", "launch", udid, "app.dendencat.sumipaint"], check=True, timeout=180)
    time.sleep(4)
    # A launch can initially return a PID even if the process subsequently crashes.
    print("Checking app process", flush=True)
    process_list = subprocess.check_output(["xcrun", "simctl", "spawn", udid, "launchctl", "list"], text=True, timeout=30)
    assert re.search(r"^\d+\s+[-\d]+\s+.*app\.dendencat\.sumipaint", process_list, re.MULTILINE), "App did not remain running"
    print("Capturing screenshot", flush=True)
    subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", str(output / f"{family}.png")], check=True, timeout=60)
    subprocess.run(["xcrun", "simctl", "terminate", udid, "app.dendencat.sumipaint"], check=True, timeout=30)
    subprocess.run(["xcrun", "simctl", "shutdown", udid], check=True, timeout=60)
print("Both simulator launches passed.")
