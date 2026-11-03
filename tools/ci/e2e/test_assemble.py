#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for assemble.py's scenario `locked` report (unittest, standard library only).

    python3 tools/ci/e2e/test_assemble.py

The scenario passes only with at least two SPS/PPS variants on the wire, a
`background → backgroundSoftware … (encoder vt-sw` line and a `[switch] first vt-sw IDR on the wire`
line in the app log; RUN.md shows the variants table (one picture per variant) and the lock lines.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))

VARIANTS = [
    {"hex": "2742e01fa918190636", "pps_hex": "28de09c8", "first_frame": 1, "frames": 300, "profile": 66, "level": 31,
     "constraints": 0xE0, "poc_type": 0, "refs": 2, "log2_max_frame_num": 5, "vui": True, "reorder": None,
     "width": 800, "height": 384},
    {"hex": "6742c01fda0320c680", "pps_hex": "68ce3c80", "first_frame": 301, "frames": 250, "profile": 66, "level": 31,
     "constraints": 0xC0, "poc_type": 2, "refs": 1, "log2_max_frame_num": 4, "vui": True, "reorder": 0,
     "width": 800, "height": 384},
]

LOCK_LOG = [
    "18:00:00.900 I/LINK: hb#3 probed=true video=true framesSent=300 openServers=3 state=streaming pulls/s=20.0",
    "18:00:01.000 I/E2E: simulated lock at +15.0s",
    "18:00:01.001 I/APP: scene active → inactive (own UI session, streaming)",
    "18:00:01.600 I/VIDEO: [bg] enter: canvas 800x384 policy=vtsw rungs=vt-sw,hold last-live-idr=23410b hold-idrs=2",
    "18:00:01.650 I/VIDEO: [bg] try vt-sw (pre-warmed): create=noErr hw=false probe=IDR 20112b in 45ms sps=ok → accepted",
    "18:00:01.700 I/VIDEO: background → backgroundSoftware @8fps (encoder vt-sw, 3375kbps)",
    "18:00:01.900 I/VIDEO: [switch] first vt-sw IDR on the wire: 19876b, 0.21s after the switch (dump frame #301)",
]


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


class LockedReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="assemble-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.out = os.path.join(self.tmp, "out")
        self.art = os.path.join(self.tmp, "art")

    def scenario(self, name, variants, log_lines):
        d = os.path.join(self.out, "e2e-" + name)
        summary = {"result": "PASS", "goal_reached": True, "violations": 0, "warnings": 0, "frames_total": 550,
                   "probes": [{"t": 1.0}], "findings": [],
                   "decode": {"decodable": True, "strict": name == "locked", "lenient_decodable": True, "codec": "h264",
                              "strict_flags": "-xerror -err_detect +crccheck+bitstream+buffer+explode",
                              "width": 800, "height": 384, "decoded_frames": 550, "frames_received": 550,
                              "decode_error_lines": 0},
                   "sessions": [{"cycle": 1, "end_reason": "completed", "canvas": "800x384", "frames": 550,
                                 "keyframes": 40, "sps_variants": variants}]}
        write(os.path.join(d, "summary.json"), json.dumps(summary))
        write(os.path.join(d, "result.env"), "scenario=%s\ndash=cfdl16\nseconds=60\n" % name)
        write(os.path.join(d, "app-status.json"), json.dumps({"phase": "streaming", "engine": {"encoder": "vt-hw"}}))
        write(os.path.join(d, "app-log.txt"), "\n".join(log_lines) + "\n")
        for pic in ["dash_first.png"] + ["dash_variant_%d.png" % (i + 1) for i in range(len(variants))]:
            write(os.path.join(d, "frames", pic), "png")
        write(os.path.join(d, "frames", "headers.txt"), "[trace_headers @ 0x1] Sequence Parameter Set\n")

    def assemble(self):
        res = subprocess.run([sys.executable, os.path.join(HERE, "assemble.py"), self.out, self.art,
                              "--require=cfdl16"], capture_output=True, text=True, timeout=60)
        self.assertEqual(res.returncode, 0, res.stderr)
        with open(os.path.join(self.art, "RUN.md"), encoding="utf-8") as f:
            return f.read(), res.stdout

    def test_two_variants_and_the_vt_sw_lines_pass(self):
        self.scenario("locked", VARIANTS, LOCK_LOG)
        md, notes = self.assemble()
        self.assertIn("**PASS**", md)
        self.assertIn("::notice title=E2E locked PASS::", notes)
        self.assertIn("| 1 | 1 | 300 | 66 | 0xE0 | 31 | 800x384 | 0 | 2 | 5 | True | - | "
                      "[dash_variant_1.png](e2e-locked/frames/dash_variant_1.png) |", md)
        self.assertIn("| 2 | 301 | 250 | 66 | 0xC0 | 31 | 800x384 | 2 | 1 | 4 | True | 0 | "
                      "[dash_variant_2.png](e2e-locked/frames/dash_variant_2.png) |", md)
        self.assertIn("SPS #2 `6742c01fda0320c680` PPS `68ce3c80`", md)
        self.assertIn("strict: `-xerror -err_detect +crccheck+bitstream+buffer+explode`", md)
        # The lock lines, in log order, without the unrelated hb# line.
        self.assertIn("Lock lines of the app log (6)", md)
        self.assertNotIn("hb#3", md.split("Lock lines of the app log")[1].split("</details>")[0])
        self.assertTrue(os.path.isfile(os.path.join(self.art, "e2e-locked", "frames", "headers.txt")))

    def test_each_missing_piece_is_a_failure_reason(self):
        cases = [
            (VARIANTS[:1], LOCK_LOG, "fewer than 2 SPS/PPS variants (1): no second encoder reached the dash"),
            (VARIANTS, [l for l in LOCK_LOG if "backgroundSoftware" not in l],
             "no `background → backgroundSoftware … (encoder vt-sw` line in app-log.txt"),
            (VARIANTS, [l for l in LOCK_LOG if "[switch]" not in l],
             "no `[switch] first vt-sw IDR on the wire` line in app-log.txt"),
        ]
        for variants, log, reason in cases:
            with self.subTest(reason=reason):
                shutil.rmtree(self.out, True)
                self.scenario("locked", variants, log)
                md, notes = self.assemble()
                self.assertIn("**FAIL** — ", md)
                self.assertIn(reason, md)
                self.assertIn("::error title=E2E locked FAIL::", notes)
                self.assertEqual(md.count("fewer than 2 SPS/PPS variants"), 1 if len(variants) < 2 else 0,
                                 "only the missing piece is reported")

    def test_a_hold_only_lock_lists_all_three_reasons(self):
        hold = LOCK_LOG[:4] + ["18:00:01.700 I/VIDEO: background → hold (2 hold IDR(s); reason: all rungs rejected)"]
        self.scenario("locked", VARIANTS[:1], hold)
        md, _ = self.assemble()
        line = [l for l in md.splitlines() if l.startswith("**FAIL**")][0]
        self.assertEqual(line.count(";"), 2, line)

    def test_other_scenarios_never_get_the_locked_rules(self):
        self.scenario("cfdl16", VARIANTS[:1], ["18:00:00.000 I/APP: Ready."])
        md, _ = self.assemble()
        self.assertIn("**PASS**", md)
        self.assertNotIn("SPS/PPS variants on the wire", md)
        self.assertNotIn("strict:", md)


if __name__ == "__main__":
    unittest.main(verbosity=2)
