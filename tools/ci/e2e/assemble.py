#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Assemble the e2e job's evidence into a small artifacts tree + RUN.md, and emit annotations.

Input (<out>, written by the CI steps):
  env.txt            key=value: sha, ref, run_url, xcode, macos, sim_name, sim_runtime, sim_udid
  timings.tsv        step<TAB>seconds<TAB>status
  build.log          xcodebuild output (only error lines are kept)
  screens/           screenshots.sh output
  e2e-<scenario>/    run-fakedash.sh output
  crash/             *.ips crash reports copied from ~/Library/Logs/DiagnosticReports (optional)

Output (<artifacts>): RUN.md, screens/*.png (+ status, launch log tails), e2e-<scenario>/ with
summary.json, transcript-digest.txt, fakedash.log, app-log.txt (trimmed), app-status.json,
screenshots and decoded frames. Annotations go to stdout (GitHub workflow commands).
Exit code: 0 (the workflow decides what fails), 3 when a scenario did not pass and --strict.

usage: assemble.py <out dir> <artifacts dir> [--strict]
"""
import glob
import re
import json
import os
import shutil
import subprocess
import sys

MAX_APP_LOG_LINES = 2500
BUDGET_BYTES = 14 * 1024 * 1024


def esc(s):
    return str(s).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def esc_prop(s):
    return esc(s).replace(":", "%3A").replace(",", "%2C")


def annotate(level, title, message):
    print("::%s title=%s::%s" % (level, esc_prop(title), esc(message)))


def read_kv(path):
    out = {}
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def tail_lines(path, n):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    return lines[-n:]


def copy(src, dst):
    if os.path.isfile(src):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        return True
    return False


def write_trimmed(src, dst, max_lines, head=300):
    try:
        with open(src, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return 0
    if len(lines) > max_lines:
        lines = lines[:head] + ["… %d lines omitted …" % (len(lines) - max_lines)] + lines[-(max_lines - head):]
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return len(lines)


def tree_size(root):
    total = 0
    for dirpath, _, files in os.walk(root):
        for name in files:
            total += os.path.getsize(os.path.join(dirpath, name))
    return total


def fmt_findings(findings, limit=40):
    rows = []
    for f in findings[:limit]:
        rows.append("| %s | %s | %s | %s |" % (f.get("severity"), f.get("rule"), f.get("count", 1),
                                              str(f.get("message", "")).replace("|", "\\|")[:300]))
    return rows


# Scenario `locked` (locked iPhone, Phase 0): the app lines that tell the lock story, in log order.
LOCK_LINE_MARKERS = ("E2E: simulated lock", "E2E: simulated unlock", "APP: scene ", "APP: [lock]", "VIDEO: [bg]",
                     "VIDEO: [bg-probe]", "VIDEO: [vt-list]", "VIDEO: [switch]", "VIDEO: background \u2192",
                     "VIDEO: foreground \u2192", "first IDR")
LOCK_SOFTWARE_LINE = ("background \u2192 backgroundSoftware", "(encoder vt-sw")
LOCK_FIRST_IDR_LINE = "[switch] first vt-sw IDR on the wire"
# L8 (`BackgroundLog.switchFirstIDR`) with the wire-dump frame it names, and the engine's warning when an
# encoder tag changed on a P-frame (`DashProjectionEngine.served`).
LOCK_L8_RE = re.compile(r"\[switch\] first (\S+) IDR on the wire: (\d+)b.*\(dump frame #(\d+)\)")
LOCK_NON_IDR_SWITCH = ("[switch] encoder tag", "on a non-IDR frame")


def wire_frames(d):
    """The frames fakedash received, in wire order over all sessions (1-based index = the app's dump frame
    #k), from transcript.jsonl; None without a transcript."""
    frames = []
    try:
        with open(os.path.join(d, "transcript.jsonl"), encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("name") == "frame" and e.get("dir") == "phone->dash" and "frame" in e:
                    frames.append(e)
    except OSError:
        return None
    return frames


def check_switch_frames(log, frames):
    """Every L8 `[switch] first <enc> IDR on the wire: <n>b \u2026 (dump frame #k)` of the app against what the
    dash received: frame #k must be an SPS+PPS+IDR access unit of n bytes. Returns (verified [(enc, k)],
    problems)."""
    verified, problems = [], []
    for l in log:
        if all(m in l for m in LOCK_NON_IDR_SWITCH):
            problems.append("SWITCH_NOT_AT_IDR (app log): `%s`" % l.strip()[-120:])
        m = LOCK_L8_RE.search(l)
        if not m:
            continue
        enc, size, k = m.group(1), int(m.group(2)), int(m.group(3))
        if frames is None:      # no transcript: nothing to check against (a single variant then fails below)
            continue
        f = frames[k - 1] if 1 <= k <= len(frames) else None
        nal = (f or {}).get("nal_types") or []
        if f is None or not (f.get("keyframe") and nal[:2] == [7, 8] and 5 in nal and 1 not in nal
                             and f.get("len") == size):
            problems.append("SWITCH_NOT_AT_IDR (wire): L8 says frame #%d is the first %s IDR (%d B); the dash received %s"
                            % (k, enc, size, "no such frame (%d frames)" % len(frames) if f is None else
                               "%s %s B nal=%s" % ("an IDR" if f.get("keyframe") else "a P-frame", f.get("len"), nal)))
            continue
        verified.append((enc, k))
    return verified, problems


def locked_section(d, summary, md):
    """RUN.md part of scenario `locked`: the SPS/PPS variants on the wire (one per encoder that fed the
    dash, with its picture) and the app's lock lines. Returns the failure reasons: fewer than 2 variants,
    no `background → backgroundSoftware … (encoder vt-sw` line, no `[switch] first vt-sw IDR on the
    wire` line (the scenario is not required: a simulator whose VideoToolbox software encoder writes the
    hardware encoder's SPS/PPS byte for byte also gives a single variant; the app log says which)."""
    reasons = []
    variants = []
    for ss in (summary or {}).get("sessions") or []:
        variants += ss.get("sps_variants") or []
    name = os.path.basename(d)
    md.append("SPS/PPS variants on the wire (one per encoder that fed the dash):")
    md.append("")
    md.append("| # | first frame | frames | profile | constraints | level | size | poc | refs | frame_num bits | vui | reorder | picture |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for i, v in enumerate(variants, 1):
        pic = "dash_variant_%d.png" % i
        link = "[%s](%s/frames/%s)" % (pic, name, pic) if os.path.isfile(os.path.join(d, "frames", pic)) else "-"
        cons = v.get("constraints")
        md.append("| %d | %s | %s | %s | %s | %s | %sx%s | %s | %s | %s | %s | %s | %s |"
                  % (i, v.get("first_frame"), v.get("frames"), v.get("profile"),
                     "0x%02X" % cons if isinstance(cons, int) else "-", v.get("level"), v.get("width"), v.get("height"),
                     v.get("poc_type"), v.get("refs"), v.get("log2_max_frame_num"), v.get("vui"),
                     "-" if v.get("reorder") is None else v.get("reorder"), link))
    for i, v in enumerate(variants, 1):
        md.append("")
        md.append("SPS #%d `%s` PPS `%s`" % (i, v.get("hex"), v.get("pps_hex")))
    md.append("")
    distinct = {(v.get("hex"), v.get("pps_hex")) for v in variants}
    try:
        with open(os.path.join(d, "app-log.txt"), encoding="utf-8", errors="replace") as f:
            log = f.read().splitlines()
    except OSError:
        log = []
    if not any(all(m in l for m in LOCK_SOFTWARE_LINE) for l in log):
        reasons.append("no `background \u2192 backgroundSoftware \u2026 (encoder vt-sw` line in app-log.txt")
    if not any(LOCK_FIRST_IDR_LINE in l for l in log):
        reasons.append("no `%s` line in app-log.txt" % LOCK_FIRST_IDR_LINE)
    verified, problems = check_switch_frames(log, wire_frames(d))
    reasons += problems
    to_bg = [k for enc, k in verified if enc == "vt-sw"]
    back = [k for enc, k in verified if enc == "vt-hw" and to_bg and k > to_bg[0]]
    if verified:
        md.append("Encoder switches checked on the wire (L8 frame = SPS+PPS+IDR of the logged size): "
                  + ", ".join("%s at #%d" % s for s in verified))
        md.append("")
    need = (summary or {}).get("min_variants", 2)
    if len(distinct) < need:
        reasons.append("fewer than %d SPS/PPS variants (%d): no second encoder reached the dash" % (need, len(distinct)))
    elif len(distinct) < 2:
        if to_bg and back:
            md.append("One SPS/PPS variant: both encoders wrote the same SPS/PPS (switches verified at #%d and #%d)."
                      % (to_bg[0], back[0]))
            md.append("")
        else:
            reasons.append("one SPS/PPS variant and no vt-sw \u2192 vt-hw switch verified on the wire")
    lines = [l for l in log if any(m in l for m in LOCK_LINE_MARKERS)]
    if lines:
        md.append("<details><summary>Lock lines of the app log (%d)</summary>" % len(lines))
        md.append("")
        md.append("```")
        md.extend(lines[:80])
        if len(lines) > 80:
            md.append("\u2026 %d more" % (len(lines) - 80))
        md.append("```")
        md.append("</details>")
        md.append("")
    return reasons


def scenario_section(out, art, d, md, annotations):
    name = os.path.basename(d)[len("e2e-"):]
    dst = os.path.join(art, os.path.basename(d))
    os.makedirs(dst, exist_ok=True)
    result = read_kv(os.path.join(d, "result.env"))
    summary = read_json(os.path.join(d, "summary.json"))
    status = read_json(os.path.join(d, "app-status.json"))
    copy(os.path.join(d, "summary.json"), os.path.join(dst, "summary.json"))
    copy(os.path.join(d, "app-status.json"), os.path.join(dst, "app-status.json"))
    copy(os.path.join(d, "result.env"), os.path.join(dst, "result.env"))
    write_trimmed(os.path.join(d, "fakedash.log"), os.path.join(dst, "fakedash.log"), 600, head=200)
    app_lines = write_trimmed(os.path.join(d, "app-log.txt"), os.path.join(dst, "app-log.txt"), MAX_APP_LOG_LINES)
    write_trimmed(os.path.join(d, "app-stderr.log"), os.path.join(dst, "app-stderr.log"), 200, head=50)
    if os.path.isfile(os.path.join(d, "transcript.jsonl")):
        subprocess.call([sys.executable, os.path.join(os.path.dirname(__file__), "transcript_digest.py"),
                         os.path.join(d, "transcript.jsonl"), os.path.join(dst, "transcript-digest.txt"), "1500"])
    shots = sorted(os.path.basename(p) for p in glob.glob(os.path.join(d, "*.png")))
    for s in shots:
        copy(os.path.join(d, s), os.path.join(dst, s))
    frames = sorted(os.path.basename(p) for p in glob.glob(os.path.join(d, "frames", "*.png"))
                    + glob.glob(os.path.join(d, "frames", "*.jpg")))
    same_first = False
    a, b = os.path.join(d, "frames", "app_first.png"), os.path.join(d, "frames", "dash_first.png")
    if os.path.isfile(a) and os.path.isfile(b) and open(a, "rb").read() == open(b, "rb").read():
        same_first = True
        frames = [fr for fr in frames if fr != "app_first.png"]
    for fr in frames:
        copy(os.path.join(d, "frames", fr), os.path.join(dst, "frames", fr))
    for extra in ("ffprobe-dash.json", "ffprobe-app.json", "ffprobe-dash.err", "ffprobe-app.err", "ffmpeg.log", "headers.txt"):
        p = os.path.join(d, "frames", extra)
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            copy(p, os.path.join(dst, "frames", extra))

    reasons = []
    md.append("## E2E `%s` (fake dash `%s`, %s s streaming)" % (name, result.get("dash", "?"), result.get("seconds", "?")))
    md.append("")
    if summary is None:
        reasons.append("no fakedash summary (fakedash rc %s)" % result.get("fakedash_rc", "?"))
        md.append("**No fakedash summary.** fakedash rc=%s. Tail of fakedash.log:" % result.get("fakedash_rc", "?"))
        md.append("```")
        md.extend(tail_lines(os.path.join(d, "fakedash.log"), 40))
        md.append("```")
    else:
        sessions = summary.get("sessions") or []
        s0 = sessions[0] if sessions else {}
        decode = summary.get("decode") or {}
        fps = ", ".join("%s %s fps" % (p.get("label"), p.get("fps")) for p in s0.get("pull_phases", []))
        lat = s0.get("pull_latency_ms") or {}
        md.append("| | |")
        md.append("|---|---|")
        md.append("| fakedash result | **%s** (goal reached: %s) — %s violation(s), %s warning(s) |"
                  % (summary.get("result"), summary.get("goal_reached"), summary.get("violations"), summary.get("warnings")))
        md.append("| probes / sessions | %d / %d |" % (len(summary.get("probes") or []), len(sessions)))
        md.append("| session 1 | end: %s, handshake %s s, canvas %s |" % (s0.get("end_reason"), s0.get("handshake_s"), s0.get("canvas")))
        kf, fr = s0.get("keyframes") or 0, s0.get("frames") or 0
        md.append("| frames | %s total, %s keyframes (%s%% of session 1), avg %s B, first frame %s s after 113 |"
                  % (summary.get("frames_total"), kf, (100 * kf // fr) if fr else "-", s0.get("avg_frame_bytes"),
                     s0.get("first_frame_after_113_s")))
        for extra in sessions[1:]:
            md.append("| session %s | end: %s, handshake %s s, canvas %s, %s frames (%s keyframes)%s |"
                      % (extra.get("cycle"), extra.get("end_reason"), extra.get("handshake_s"), extra.get("canvas"),
                         extra.get("frames"), extra.get("keyframes"),
                         "" if extra.get("probe_t") is None else ", probe at %s s" % extra.get("probe_t")))
        for p in (summary.get("probes") or [])[1:]:
            if "after_previous_session_s" in p:
                md.append("| re-probe | %s s after the previous session ended (%s) |" % (p.get("after_previous_session_s"), p.get("result")))
        md.append("| pulls | %s; 114→frame p50 %s ms, p95 %s ms, max %s ms |" % (fps or "-", lat.get("p50"), lat.get("p95"), lat.get("max")))
        sps = s0.get("sps") or {}
        if sps:
            md.append("| SPS | profile_idc %s, level_idc %s, %sx%s, reorder %s, refs %s, vui fps %s |"
                      % (sps.get("profile_idc"), sps.get("level_idc"), sps.get("width"), sps.get("height"),
                         sps.get("max_num_reorder_frames"), sps.get("max_num_ref_frames"), sps.get("vui_fps")))
        if s0.get("idr_interval_s"):
            md.append("| IDR interval | mean %s s, max %s s |" % (s0["idr_interval_s"].get("mean"), s0["idr_interval_s"].get("max")))
        if decode:
            md.append("| decode (ffprobe/ffmpeg%s) | decodable: **%s**, %s %s %sx%s, %s decoded / %s received, %s error line(s) %s%s |"
                      % (", strict: `%s`" % decode.get("strict_flags") if decode.get("strict") else "",
                         decode.get("decodable"), decode.get("codec"), decode.get("profile"), decode.get("width"),
                         decode.get("height"), decode.get("decoded_frames"), decode.get("frames_received"),
                         decode.get("decode_error_lines"), decode.get("error", ""),
                         "" if not decode.get("strict") else "; lenient decode clean: %s" % decode.get("lenient_decodable")))
        ident = summary.get("identity") or {}
        if ident:
            md.append("| phone identity | %s |" % ", ".join("%s=%s" % kv for kv in ident.items()))
        hb = s0.get("heartbeats") or {}
        if hb:
            md.append("| heartbeats | %s |" % "; ".join("%s: %s beats, max gap %s s" % (k, v.get("beats"), v.get("max_gap_s")) for k, v in hb.items()))
        md.append("")
        findings = summary.get("findings") or []
        if findings:
            md.append("Findings:")
            md.append("")
            md.append("| severity | rule | count | message |")
            md.append("|---|---|---|---|")
            md.extend(fmt_findings(findings))
            md.append("")
        if name == "locked":
            reasons += locked_section(d, summary, md)
        if summary.get("result") != "PASS":
            reasons.append("fakedash result %s (%s violations, goal reached: %s)"
                           % (summary.get("result"), summary.get("violations"), summary.get("goal_reached")))
        if not summary.get("frames_total"):
            reasons.append("no frame received")
        if decode and not decode.get("decodable"):
            reasons.append("stream not decodable (%s)" % (decode.get("error") or "; ".join(decode.get("decode_errors", [])[:2])))
        for f in findings:
            if f.get("severity") == "violation":
                annotations.append(("error", "fakedash %s [%s]" % (name, f.get("rule")), f.get("message")))
    if not frames or not any(fr.startswith("dash_") for fr in frames):
        reasons.append("no decoded dash picture")
    if status:
        md.append("App status (`app-status.json`, last write): phase **%s** (%s), link %s, ever streaming: %s, frames sent %s "
                  "(max %s), keyframes %s, missed pulls %s, profile %s, canvas %s, dash %s; projection %s; engine %s"
                  % (status.get("phase"), status.get("detail"), status.get("link_state"), status.get("ever_streaming"),
                     status.get("frames_sent"), status.get("max_frames_sent"), status.get("keyframes_sent"),
                     status.get("missed_pulls"), status.get("profile"), status.get("canvas"), status.get("dash"),
                     json.dumps(status.get("projection"), sort_keys=True), json.dumps(status.get("engine"), sort_keys=True)))
        md.append("")
    else:
        md.append("No `app-status.json` (the app never wrote its status — did it start in e2e mode?).")
        md.append("")
        reasons.append("no app status")
    md.append("App alive after the run: %s; app log: %d lines (`%s/app-log.txt`)" % (result.get("app_alive_after"), app_lines, os.path.basename(d)))
    md.append("")
    if shots:
        md.append("Screenshots: " + ", ".join("[%s](%s/%s)" % (s, os.path.basename(d), s) for s in shots))
    if frames:
        md.append("")
        md.append("Decoded frames: " + ", ".join("[%s](%s/frames/%s)" % (f, os.path.basename(d), f) for f in frames))
    if same_first:
        md.append("")
        md.append("The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.")
    md.append("")
    log_tail = tail_lines(os.path.join(d, "app-log.txt"), 25)
    if log_tail:
        md.append("<details><summary>App log tail</summary>")
        md.append("")
        md.append("```")
        md.extend(log_tail)
        md.append("```")
        md.append("</details>")
        md.append("")
    ok = not reasons
    md.insert(md.index("## E2E `%s` (fake dash `%s`, %s s streaming)" % (name, result.get("dash", "?"), result.get("seconds", "?"))) + 1,
              "\n**%s**%s\n" % ("PASS" if ok else "FAIL", "" if ok else " — " + "; ".join(reasons)))
    if ok:
        s0 = (summary.get("sessions") or [{}])[0]
        annotations.insert(0, ("notice", "E2E %s PASS" % name,
                               "%s frames from the real app, canvas %s, decodable, %s warning(s)"
                               % (summary.get("frames_total"), s0.get("canvas"), summary.get("warnings"))))
    else:
        annotations.insert(0, ("error", "E2E %s FAIL" % name, "; ".join(reasons)))
    return ok


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    required = []
    for a in sys.argv[1:]:
        if a.startswith("--require="):
            required = [x for x in a.split("=", 1)[1].split(",") if x]
    if len(args) < 2:
        print(__doc__)
        return 2
    out, art = args[0], args[1]
    if os.path.isdir(art):
        shutil.rmtree(art)
    os.makedirs(art)
    env = read_kv(os.path.join(out, "env.txt"))
    md = ["# OpenCfMoto iOS — CI e2e run", ""]
    md.append("- commit: `%s` (%s)" % (env.get("sha", "?"), env.get("ref", "?")))
    md.append("- run: %s" % env.get("run_url", "?"))
    md.append("- date: %s" % env.get("date", "?"))
    md.append("- Xcode: %s; macOS %s" % (env.get("xcode", "?"), env.get("macos", "?")))
    md.append("- simulator: %s, %s (`%s`)" % (env.get("sim_name", "?"), env.get("sim_runtime", "?"), env.get("sim_udid", "?")))
    md.append("- app: `%s` built Debug for the simulator with `CODE_SIGNING_ALLOWED=NO`" % env.get("bundle", "?"))
    md.append("")
    annotations = []

    timings = []
    try:
        for line in open(os.path.join(out, "timings.tsv"), encoding="utf-8"):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                timings.append(parts)
    except OSError:
        pass
    if timings:
        md.append("| step | seconds | status |")
        md.append("|---|---|---|")
        for t in timings:
            md.append("| %s | %s | %s |" % (t[0], t[1], t[2] if len(t) > 2 else ""))
        md.append("")

    build_status = read_kv(os.path.join(out, "build.env")).get("status", "?")
    md.append("## Build: %s" % build_status)
    md.append("")
    if build_status != "ok":
        errors = [l for l in tail_lines(os.path.join(out, "build.log"), 100000) if " error: " in l or l.startswith("error:")]
        md.append("```")
        md.extend(errors[:60] or tail_lines(os.path.join(out, "build.log"), 40))
        md.append("```")
        md.append("")

    # Screens.
    sdir = os.path.join(out, "screens")
    if os.path.isdir(sdir):
        rows = []
        try:
            rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(sdir, "status.tsv"), encoding="utf-8")][1:]
        except OSError:
            pass
        pngs = sorted(os.path.basename(p) for p in glob.glob(os.path.join(sdir, "*.png")))
        for p in pngs:
            copy(os.path.join(sdir, p), os.path.join(art, "screens", p))
        copy(os.path.join(sdir, "status.tsv"), os.path.join(art, "screens", "status.tsv"))
        for log in glob.glob(os.path.join(sdir, "logs", "*")):
            if os.path.getsize(log) > 0:
                copy(log, os.path.join(art, "screens", "logs", os.path.basename(log)))
        crashed = [r[0] for r in rows if len(r) > 2 and (r[1] != "ok" or r[2] != "yes") and not r[0].startswith("_")]
        md.append("## Screenshots (%d)%s" % (len(pngs), " — not running after launch: " + ", ".join(crashed) if crashed else ""))
        md.append("")
        md.append(" ".join("[%s](screens/%s)" % (p[:-4], p) for p in pngs))
        md.append("")
        if crashed:
            annotations.append(("error", "Screenshots", "app not running when shot: " + ", ".join(crashed)))
        else:
            annotations.append(("notice", "Screenshots", "%d screens captured" % len(pngs)))

    all_ok = True
    order = {name: i for i, name in enumerate(required)}
    scen_dirs = sorted(glob.glob(os.path.join(out, "e2e-*")),
                       key=lambda d: (order.get(os.path.basename(d)[4:], len(order)), d))
    results = {}
    for d in scen_dirs:
        if os.path.isdir(d):
            results[os.path.basename(d)[4:]] = scenario_section(out, art, d, md, annotations)
    for name in required:
        if not results.get(name):
            all_ok = False
    if not scen_dirs:
        md.append("## E2E: not run")
        md.append("")
        all_ok = False
    if results:
        summary_line = "E2E results: " + ", ".join("%s %s%s" % (k, "PASS" if v else "FAIL", " (required)" if k in required else "")
                                                   for k, v in results.items())
        md.insert(md.index("## Build: %s" % build_status), summary_line + "\n")

    crashes = sorted(glob.glob(os.path.join(out, "crash", "*")))
    if crashes:
        md.append("## Crash reports (%d)" % len(crashes))
        md.append("")
        for c in crashes[:6]:
            write_trimmed(c, os.path.join(art, "crash", os.path.basename(c) + ".txt"), 400, head=250)
            md.append("- [%s](crash/%s.txt)" % (os.path.basename(c), os.path.basename(c)))
        md.append("")
        annotations.append(("error", "Crash reports", "%d app crash report(s): %s" % (len(crashes), ", ".join(os.path.basename(c) for c in crashes[:5]))))

    # Size budget: quantize PNGs (pngquant, lossy palette, still PNG) when available, then drop
    # optional files — extra decoded pictures and screenshots of the non-required scenarios first.
    pngs = [os.path.join(dp, f) for dp, _, fs in os.walk(art) for f in fs if f.endswith(".png")]
    if pngs and shutil.which("pngquant"):
        before = tree_size(art)
        for i in range(0, len(pngs), 40):
            subprocess.call(["pngquant", "--force", "--skip-if-larger", "--strip", "--quality=60-92",
                             "--ext", ".png"] + pngs[i:i + 40], stderr=subprocess.DEVNULL)
        md.append("PNGs quantized with pngquant: %.1f MB → %.1f MB." % (before / 1048576.0, tree_size(art) / 1048576.0))
        md.append("")
    if tree_size(art) > BUDGET_BYTES:
        def frames_of(name):
            return sorted(glob.glob(os.path.join(art, "e2e-" + name, "frames", "dash_*.jpg")))
        optional = [os.path.basename(x)[4:] for x in glob.glob(os.path.join(art, "e2e-*"))
                    if os.path.basename(x)[4:] not in required]
        victims = []
        for name in optional:
            victims += frames_of(name)[4::2]          # every other picture after the first four
        for name in optional:
            victims += glob.glob(os.path.join(art, "e2e-" + name, "app_streaming_2.png"))
            victims += glob.glob(os.path.join(art, "e2e-" + name, "app_after.png"))
        for name in required:
            victims += frames_of(name)[6::2]
        for name in optional + required:
            victims += frames_of(name)[::-1]
        removed = 0
        for v in victims:
            if tree_size(art) <= BUDGET_BYTES:
                break
            if os.path.exists(v):
                os.remove(v)
                removed += 1
        md.append("(%d optional file(s) dropped to stay under %d MB)" % (removed, BUDGET_BYTES // (1024 * 1024)))
    md.append("")
    md.append("Total artifact size: %.1f MB" % (tree_size(art) / 1048576.0))
    with open(os.path.join(art, "RUN.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(md) + "\n")
    for level, title, message in annotations[:20]:
        annotate(level, title, message)
    return 3 if (strict and not all_ok) else 0


if __name__ == "__main__":
    sys.exit(main())
