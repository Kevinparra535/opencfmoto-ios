#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Pick an available iPhone simulator for the CI e2e job.

Prints `udid=…`, `name=…`, `runtime=…` lines (append them to $GITHUB_OUTPUT). Preference: the
newest iOS runtime (≥ 17, the app's deployment target), then a plain current iPhone model.

usage: simctl_pick.py
"""
import json
import re
import subprocess
import sys

PREFERRED = ["iPhone 16", "iPhone 16 Pro", "iPhone 15", "iPhone 15 Pro", "iPhone 17", "iPhone 17 Pro",
             "iPhone 16e", "iPhone 14", "iPhone SE (3rd generation)"]


def main() -> int:
    raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
    devices = json.loads(raw).get("devices", {})
    candidates = []
    for runtime, devs in devices.items():
        m = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", runtime)
        if not m:
            continue
        version = (int(m.group(1)), int(m.group(2)))
        if version < (17, 0):
            continue
        for dev in devs:
            name = dev.get("name", "")
            if not dev.get("isAvailable", True) or not name.startswith("iPhone"):
                continue
            rank = PREFERRED.index(name) if name in PREFERRED else len(PREFERRED)
            candidates.append((version, -rank, name, dev["udid"], runtime))
    if not candidates:
        print("no available iPhone simulator with iOS >= 17", file=sys.stderr)
        return 1
    # Newest runtime first; inside it, the most preferred model.
    candidates.sort(key=lambda c: (c[0], c[1]), reverse=True)
    version, _, name, udid, runtime = candidates[0]
    print("udid=%s" % udid)
    print("name=%s" % name)
    print("runtime=iOS %d.%d" % version)
    print("candidates=%d" % len(candidates))
    return 0


if __name__ == "__main__":
    sys.exit(main())
