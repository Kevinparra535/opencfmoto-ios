#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Assert resolved Xcode build settings (what `xcodebuild -showBuildSettings` reports) per target.

Used by CI to prove the signing variables in project.yml / Config/*.xcconfig resolve as intended:
Automatic + Apple Development without a Local.xcconfig (a developer's Mac), Manual + Apple
Distribution + the CI profiles with the Local.xcconfig the TestFlight workflow writes.

usage:
  assert_build_settings.py --project OpenCfMoto.xcodeproj [--configuration Release] [--label TEXT]
                           TARGET:KEY=VALUE [TARGET:KEY=VALUE ...]

An empty VALUE asserts an empty (or unset) setting. Settings are resolved for the iphoneos SDK, so
conditional settings such as CODE_SIGN_IDENTITY[sdk=iphoneos*] apply. Every mismatch is reported
at once as a ::error annotation; exit status 1 if any.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys


def esc_data(s: str) -> str:
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def esc_prop(s: str) -> str:
    return esc_data(s).replace(":", "%3A").replace(",", "%2C")


def show_build_settings(project: str, target: str, configuration: str):
    cmd = ["xcodebuild", "-project", project, "-target", target, "-configuration", configuration,
           "-sdk", "iphoneos", "-showBuildSettings", "-json"]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        tail = " | ".join(proc.stderr.decode("utf-8", "replace").strip().splitlines()[-5:])
        raise RuntimeError(f"`{' '.join(cmd)}` failed ({proc.returncode}): {tail}")
    out = proc.stdout.decode("utf-8", "replace")
    match = re.search(r"^\[", out, re.M)  # xcodebuild may print notes before the JSON array
    if not match:
        raise RuntimeError(f"no JSON in the output of `{' '.join(cmd)}`: {out[:300]!r}")
    for entry in json.loads(out[match.start():]):
        if entry.get("target") == target:
            return entry.get("buildSettings", {})
    raise RuntimeError(f"xcodebuild printed no build settings for target {target}")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project", required=True)
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--label", default="build settings")
    parser.add_argument("expectations", nargs="+", metavar="TARGET:KEY=VALUE")
    args = parser.parse_args(argv)

    wanted = {}  # target -> [(key, value)]
    for item in args.expectations:
        target, sep, rest = item.partition(":")
        key, eq, value = rest.partition("=")
        if not sep or not eq or not target or not key:
            parser.error(f"bad expectation {item!r} (want TARGET:KEY=VALUE)")
        wanted.setdefault(target, []).append((key, value))

    problems, rows = [], []
    for target, pairs in wanted.items():
        try:
            settings = show_build_settings(args.project, target, args.configuration)
        except Exception as exc:
            problems.append(f"{target}: {exc}")
            continue
        for key, value in pairs:
            actual = settings.get(key, "")
            ok = actual == value
            rows.append((target, key, actual, value, "ok" if ok else "MISMATCH"))
            if not ok:
                problems.append(f"{target}: {key} = {actual!r}, expected {value!r}")

    print(f"== {args.label} ({args.configuration}, iphoneos) ==")
    for row in rows:
        print("  {:<18} {:<34} {!r:<32} expected {!r:<26} {}".format(*row))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"\n#### {args.label}\n\n| Target | Setting | Value | Expected | |\n|---|---|---|---|---|\n")
            for t, k, a, v, r in rows:
                fh.write(f"| {t} | {k} | `{a}` | `{v}` | {r} |\n")
    if problems:
        title = f"{args.label}: {len(problems)} mismatch(es)"
        print(f"::error title={esc_prop(title)}::{esc_data(chr(10).join(problems))}")
        return 1
    print(f"::notice title={esc_prop(args.label)}::{len(rows)} settings as expected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
