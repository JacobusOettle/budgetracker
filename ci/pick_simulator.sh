#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest iOS runtime.
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def version(key):
    m = re.search(r"iOS-(\d+)-(\d+)", key)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
for runtime in sorted(devices, key=version, reverse=True):
    if "iOS" not in runtime:
        continue
    for d in devices[runtime]:
        if d["name"].startswith("iPhone"):
            print(d["udid"]); sys.exit(0)
sys.exit("No iPhone simulator found")
'
