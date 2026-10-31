#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Merge the per-agent Spanish translation tables into the app's String Catalog.

Inputs:  App/Resources/Localization/*.json  — {"<English key exactly as SwiftUI extracts it>": "<Spanish>"}
         Keys follow Xcode's extraction rules: Text("Connect to \\(name)") → "Connect to %@",
         Int → "%lld", Double → "%lf"; positional "%1$@" only when the order changes.
Output:  App/Resources/Localizable.xcstrings (source language en, "es" translations).

usage: tools/l10n/build_strings.py [--check]   (--check: fail if the catalog is out of date)
"""
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "App", "Resources", "Localization")
OUT = os.path.join(ROOT, "App", "Resources", "Localizable.xcstrings")


def main() -> int:
    merged, origin = {}, {}
    for path in sorted(glob.glob(os.path.join(SRC, "*.json"))):
        with open(path, encoding="utf-8") as fh:
            table = json.load(fh)
        for key, value in table.items():
            if not isinstance(value, str):
                print(f"{path}: value for {key!r} is not a string", file=sys.stderr)
                return 1
            if key in merged and merged[key] != value:
                print(f"conflict for {key!r}: {origin[key]} → {merged[key]!r} vs {path} → {value!r}",
                      file=sys.stderr)
                return 1
            merged[key] = value
            origin[key] = os.path.basename(path)
    catalog = {
        "sourceLanguage": "en",
        "strings": {
            key: {"localizations": {"es": {"stringUnit": {"state": "translated", "value": merged[key]}}}}
            for key in sorted(merged)
        },
        "version": "1.0",
    }
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    if "--check" in sys.argv:
        current = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if current != text:
            print("Localizable.xcstrings is out of date: run tools/l10n/build_strings.py", file=sys.stderr)
            return 1
        return 0
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"{len(merged)} strings → {os.path.relpath(OUT, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
