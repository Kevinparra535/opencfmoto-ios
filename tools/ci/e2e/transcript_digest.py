#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Trimmed, human-readable digest of a fakedash --transcript JSON-lines file.

Every control / media request and reply, event and finding is kept (one line each), except the
per-frame traffic: REQ_RV_DATA_NEXT (114) pulls, raw video frames and heartbeats are shown for the
first few occurrences, then only IDR frames, and finally as counts.

usage: transcript_digest.py <transcript.jsonl> <out.txt> [max lines]
"""
import collections
import json
import sys

FIRST_FRAMES = 8
FIRST_PULLS = 4
FIRST_HEARTBEATS = 3
TEXT_CHARS = 220


def fmt(entry):
    t = entry.get("t")
    head = "%9.3f" % t if isinstance(t, (int, float)) else "%9s" % "-"
    conn = entry.get("conn") or "-"
    kind = entry.get("kind")
    if kind in ("event", "finding"):
        return "%s %-6s %s: %s" % (head, conn, kind.upper(), entry.get("note"))
    direction = {"phone->dash": "P>D", "dash->phone": "D>P"}.get(entry.get("dir"), entry.get("dir") or "?")
    name = entry.get("name") or "?"
    cmd = entry.get("cmd")
    line = "%s %-6s %s %s%s len=%s" % (head, conn, direction, name, " (%s)" % cmd if cmd else "", entry.get("len"))
    if entry.get("token") is not None:
        line += " token=%s" % entry.get("token")
    text = entry.get("payload_text")
    if text:
        line += " " + (text if len(text) <= TEXT_CHARS else text[:TEXT_CHARS] + "…")
    elif entry.get("payload_hex") and kind != "raw":
        line += " hex=" + entry["payload_hex"][:96]
    if entry.get("note"):
        line += "  # " + str(entry["note"])
    return line


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    max_lines = int(sys.argv[3]) if len(sys.argv) > 3 else 1500
    counts = collections.Counter()
    out = []
    last_frames = collections.deque(maxlen=3)
    total = 0
    try:
        f = open(src, encoding="utf-8", errors="replace")
    except OSError as e:
        open(dst, "w").write("no transcript: %s\n" % e)
        return 0
    with f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            total += 1
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            kind = e.get("kind")
            if kind == "summary":
                continue
            name = e.get("name") or ""
            if kind == "raw":
                counts["frames"] += 1
                if e.get("keyframe"):
                    counts["keyframes"] += 1
                if counts["frames"] <= FIRST_FRAMES or e.get("keyframe"):
                    out.append(fmt(e))
                else:
                    last_frames.append(fmt(e))
                continue
            if name.startswith("REQ_RV_DATA_NEXT"):
                counts["pulls(114)"] += 1
                if counts["pulls(114)"] <= FIRST_PULLS:
                    out.append(fmt(e))
                continue
            if name.startswith("HEARTBEAT") or name.startswith("REQ_HEARTBEAT") or name.startswith("RLY_HEARTBEAT"):
                key = "%s %s %s" % (e.get("conn"), e.get("dir"), name)
                counts[key] += 1
                if counts[key] <= FIRST_HEARTBEATS:
                    out.append(fmt(e))
                continue
            out.append(fmt(e))
    if last_frames:
        out.append("          … last frames:")
        out.extend(last_frames)
    header = ["fakedash transcript digest: %d entries; %s" % (total, ", ".join("%s=%d" % kv for kv in sorted(counts.items())))]
    if len(out) > max_lines:
        keep_head = max_lines * 2 // 3
        keep_tail = max_lines - keep_head
        out = out[:keep_head] + ["          … %d lines omitted …" % (len(out) - max_lines)] + out[-keep_tail:]
    with open(dst, "w", encoding="utf-8") as w:
        w.write("\n".join(header + out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
