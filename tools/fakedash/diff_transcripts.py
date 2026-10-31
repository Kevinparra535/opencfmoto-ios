#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Diff what two phone implementations sent to tools/fakedash (e.g. the Swift EasyConnLink vs the
original Android EasyConnProber), scenario by scenario.

Only phone→dash frames are compared, per connection and in order. Per-run randomness is masked:
the RSA public key / encryptedHUID / phoneUUID in CLIENT_INFO (their validity is checked by the fake
dash itself), clock replies that carry the phone's own time, and video payloads (compared by NAL-type
structure and keyframe flag instead of bytes). Timing properties are compared separately.

usage: diff_transcripts.py A.jsonl B.jsonl [--labels swift,kotlin]
"""
import json
import re
import sys
from collections import defaultdict

MASK_KEYS = ("pubkey", "encryptedHUID", "phoneUUID")


def load(path):
    frames, summary = [], None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            o = json.loads(line)
            if o.get("kind") == "summary":
                summary = o.get("summary") or o
                continue
            if o.get("dir") != "phone->dash":
                continue
            frames.append(o)
    return frames, summary


def normalize(o):
    cmd = o.get("cmd")
    kind = o.get("kind")
    text = o.get("payload_text") or ""
    if o.get("conn") == "mdata" and kind == "raw":
        return ("frame", "key" if o.get("keyframe") else "delta", tuple(o.get("nal_types") or ()))
    if text.startswith("{"):
        try:
            obj = json.loads(text)
            if isinstance(obj, dict):
                for k in MASK_KEYS:
                    if k in obj:
                        obj[k] = "<masked>"
                # keep key ORDER: json.loads preserves it in Python 3.7+
                text = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
        except ValueError:
            pass
    if cmd == "0x10601":
        # 0x10601 echoes the dash's stamp (deterministic) unless the phone substitutes its own time.
        text = re.sub(r"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}", "<time>", text)
    return (kind, cmd, o.get("len") if cmd != "0x10601" else "len", text)


def per_conn(frames):
    seq = defaultdict(list)
    for o in frames:
        seq[o.get("conn")].append(o)
    return seq


def timing(frames):
    beats = defaultdict(list)
    for o in frames:
        if o.get("cmd") == "0x70000000":
            beats[o.get("conn")].append(o["t"])
    out = {}
    for conn, ts in beats.items():
        gaps = [b - a for a, b in zip(ts, ts[1:])]
        out[conn] = (len(ts), round(sum(gaps) / len(gaps), 3) if gaps else None)
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    labels = ["A", "B"]
    for a in sys.argv[1:]:
        if a.startswith("--labels="):
            labels = a.split("=", 1)[1].split(",")
    if len(args) != 2:
        print(__doc__)
        return 2
    (fa, sa), (fb, sb) = load(args[0]), load(args[1])
    ca, cb = per_conn(fa), per_conn(fb)
    diffs = 0
    for conn in sorted(set(ca) | set(cb), key=str):
        na = [normalize(o) for o in ca.get(conn, [])]
        nb = [normalize(o) for o in cb.get(conn, [])]
        if conn == "mdata":
            # Frames: compare the opening (first 3) and the keyframe structure, not counts.
            ka = [x for x in na[:3]]
            kb = [x for x in nb[:3]]
            if ka != kb:
                diffs += 1
                print(f"[{conn}] first frames differ:\n  {labels[0]}: {ka}\n  {labels[1]}: {kb}")
            keysa = sorted({x[2] for x in na if x[1] == "key"})
            keysb = sorted({x[2] for x in nb if x[1] == "key"})
            if keysa != keysb:
                diffs += 1
                print(f"[{conn}] keyframe NAL structures differ: {labels[0]} {keysa} vs {labels[1]} {keysb}")
            continue
        # Heartbeats are timing-driven: compare the non-heartbeat sequence exactly.
        sa_ = [x for x in na if x[1] not in ("0x70000000",)]
        sb_ = [x for x in nb if x[1] not in ("0x70000000",)]
        if sa_ != sb_:
            diffs += 1
            print(f"[{conn}] phone→dash sequence differs ({len(sa_)} vs {len(sb_)} frames, heartbeats excluded):")
            m = max(len(sa_), len(sb_))
            for i in range(m):
                x = sa_[i] if i < len(sa_) else None
                y = sb_[i] if i < len(sb_) else None
                if x != y:
                    print(f"   #{i}\n     {labels[0]}: {x}\n     {labels[1]}: {y}")
    ta, tb = timing(fa), timing(fb)
    print(f"heartbeats (count, mean interval s): {labels[0]} {ta} | {labels[1]} {tb}")
    for name, s in ((labels[0], sa), (labels[1], sb)):
        if s:
            print(f"{name}: result={s.get('result')} violations={s.get('violations')} warnings={s.get('warnings')} "
                  f"frames={s.get('frames_total')}")
    print("DIFFS:", diffs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
