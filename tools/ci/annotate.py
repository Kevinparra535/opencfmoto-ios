#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Turn compiler / test errors in a CI log into GitHub annotations.

Annotations are readable through the public check-runs API even when raw job logs are not, so
every error line is reported:
  * one aggregated annotation per log (all unique error lines, newline separated), then
  * individual file/line annotations for the first few errors (GitHub shows at most 10 error
    annotations per step).

usage: annotate.py <log file> <title>
"""
import os
import re
import sys

MAX_AGGREGATE_BYTES = 60_000
MAX_INDIVIDUAL = 8

ERROR_RE = re.compile(r"^(?P<file>/[^:\n]+):(?P<line>\d+):(?:(?P<col>\d+):)? (?P<kind>error|fatal error): (?P<msg>.*)$")
TEST_FAIL_RE = re.compile(r"(error: -\[|Test Case .* failed|XCTAssert|failed \(|\*\* BUILD FAILED \*\*|The following build commands failed)")


def esc_data(s: str) -> str:
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def esc_prop(s: str) -> str:
    return esc_data(s).replace(":", "%3A").replace(",", "%2C")


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: annotate.py <log> <title>")
        return 2
    path, title = sys.argv[1], sys.argv[2]
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError as exc:
        print(f"::error title={esc_prop(title)}::cannot read {esc_data(path)}: {esc_data(str(exc))}")
        return 0
    workspace = os.environ.get("GITHUB_WORKSPACE", "")
    seen, structured, other = set(), [], []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = ERROR_RE.match(line)
        if m:
            rel = m.group("file")
            if workspace and rel.startswith(workspace + "/"):
                rel = rel[len(workspace) + 1:]
            key = (rel, m.group("line"), m.group("msg"))
            if key in seen:
                continue
            seen.add(key)
            structured.append((rel, m.group("line"), m.group("col") or "1", m.group("msg")))
        elif TEST_FAIL_RE.search(line) or " error: " in line or line.startswith("error:"):
            if line not in seen:
                seen.add(line)
                other.append(line)
    lines = [f"{f}:{l}:{c}: {msg}" for f, l, c, msg in structured] + other
    if not lines:
        print(f"::notice title={esc_prop(title)}::no error lines found in {esc_data(os.path.basename(path))}")
        return 0
    body, size = [], 0
    for item in lines:
        if size + len(item) + 1 > MAX_AGGREGATE_BYTES:
            body.append(f"... {len(lines) - len(body)} more")
            break
        body.append(item)
        size += len(item) + 1
    print(f"::error title={esc_prop(f'{title} ({len(lines)} lines)')}::{esc_data(chr(10).join(body))}")
    for f, l, c, msg in structured[:MAX_INDIVIDUAL]:
        print(f"::error file={esc_prop(f)},line={l},col={c}::{esc_data(msg)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
