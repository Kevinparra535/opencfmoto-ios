#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for fakedash.py (unittest, standard library only).

    python3 -m unittest -v tools/fakedash/test_fakedash.py      # from the repo root
    FAKEDASH_SKIP_E2E=1 python3 tools/fakedash/test_fakedash.py  # unit tests only

Unit tests use the byte vectors of docs/spec/control-plane.md (§2.3, §8.4, §9.3, §9.5, §12.6, §13.2),
media-video.md (§4.2, §5.3, §14) and input-controls.md (§2.4). The end-to-end tests run fakedash.py
against phone_smoke.py over real TCP sockets on FREE high ports (never the PXC ports 10920-10930),
so they need no port lock. Set FAKEDASH_KEEP=1 to keep their logs/transcripts (temp dirs honour TMPDIR).
"""

from __future__ import annotations

import base64
import json
import os
import random
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fakedash as fd  # noqa: E402

H = bytes.fromhex

# control-plane.md §9.5 (DERIVED fixture; test only).
SPEC_SPKI_B64 = ("MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W"
                 "8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt/UzHJWFwIDAQAB")
SPEC_ENC_HUID_B64 = ("cfSiCV3iPlLnlyC9c70nMK+ssR6NtAo0nVB9D4IzEa6kszXDMylU7NtPTdLHMnPMqjphXhkVEjpeQ7sapLP0rniYP9fz+ZY5aS/xeGZvLzbx"
                     "jOR4iHDec2JtAXMI4rJQ4vchKpmAxvQ4yZmKKFmhW2NXmraAKZF9RrzNyFhbZS0=")
SPEC_MODULUS_HEX = ("892b6a8c9228cc7ceb291c2afd50c47e76374dbbabe7b9b1e9a9f24c69cbed8129db3a668ca6c7bd80bb0aa771ddd464cae64f56f0"
                    "99373cf53a256dddaec81d2b8dd1765a2d3a5193e4f322c3b8e6a343b27735e3b85ae37e12ec72ecfa31b34f5ced76224ae0a1558f"
                    "b1f3a9df1b24a96ae57d0b8218d96352dfd4cc725617")
SPEC_PKCS1_PUB_B64 = ("MIGJAoGBAIkraoySKMx86ykcKv1QxH52N027q+e5semp8kxpy+2BKds6Zoymx72Auwqncd3UZMrmT1bwmTc89Tolbd2uyB0rjdF2Wi06U"
                      "ZPk8yLDuOajQ7J3NeO4WuN+Euxy7Poxs09c7XYiSuChVY+x86nfGySpauV9C4IY2WNS39TMclYXAgMBAAE=")
SPEC_HUID = "6GUVA2C00100055"
# control-plane.md §8.4: 800-byte CLIENT_INFO reply (Legacy profile, fixed test key). Raw string: keeps the \/ escapes.
SPEC_CLIENT_INFO_REPLY = (
    r'{"pxcVersion":"1.0.2","phoneUUID":"3f2b8c1e-9a47-4d2e-8b6a-0c5d7e9f1a23","phoneBrand":"samsung","phoneModel":"SM-G991B",'
    r'"phoneOsVersion":"35","phoneOs":"Android","package":"com.cfmoto.cfmotointernational","versionCode":126,"token":0,'
    r'"pubkey":"MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W'
    r'8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt\/UzHJWFwIDAQAB",'
    r'"encryptedHUID":"cfSiCV3iPlLnlyC9c70nMK+ssR6NtAo0nVB9D4IzEa6kszXDMylU7NtPTdLHMnPMqjphXhkVEjpeQ7sapLP0rniYP9fz+ZY5aS\/xeG'
    r'ZvLzbxjOR4iHDec2JtAXMI4rJQ4vchKpmAxvQ4yZmKKFmhW2NXmraAKZF9RrzNyFhbZS0=","bluetoothName":"OpenCfMoto",'
    r'"supportH264IFrame":true,"supportFunction":0,"supportSyncCorrectTime":false,"appVersionFingerPrint":"opencfmoto-poc"}'
).encode("utf-8")


def _read(path):
    with open(path) as f:
        return f.read()


def _read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def rules(findings, severity=None):
    return sorted(set(r for s, r, _ in findings if severity is None or s == severity))


# =============================================================================================
# Framing
# =============================================================================================


class CmdBaseTests(unittest.TestCase):
    """control-plane.md §2.3 (byte-exact Kotlin encoder output)."""

    # Hex dumps copied verbatim from control-plane.md §2.3.
    VECTORS = [
        (fd.MDNS_RESPOND, fd.PROBE_PAYLOAD, """
            10 00 00 70 56 00 00 00 46 00 00 70 00 00 00 00
            7b 22 70 68 6f 6e 65 54 79 70 65 22 3a 22 41 6e
            64 72 6f 69 64 22 2c 22 70 61 63 6b 61 67 65 4e
            61 6d 65 22 3a 22 63 6f 6d 2e 63 66 6d 6f 74 6f
            2e 63 66 6d 6f 74 6f 69 6e 74 65 72 6e 61 74 69
            6f 6e 61 6c 22 7d"""),
        (fd.MDNS_RESPOND_ACK, b'{"status":true}', """
            11 00 00 70 1f 00 00 00 0e 00 00 70 00 00 00 00
            7b 22 73 74 61 74 75 73 22 3a 74 72 75 65 7d"""),
        (fd.CAR_CTRL, b"", "00 00 01 00 10 00 00 00 10 00 01 00 00 00 00 00"),
        (fd.CAR_CTRL + 1, b"", "01 00 01 00 10 00 00 00 11 00 01 00 00 00 00 00"),
        (fd.CAR_DATA, b"", "00 00 02 00 10 00 00 00 10 00 02 00 00 00 00 00"),
        (fd.CAR_DATA + 1, b"", "01 00 02 00 10 00 00 00 11 00 02 00 00 00 00 00"),
        (fd.HEARTBEAT, b"", "00 00 00 70 10 00 00 00 10 00 00 70 00 00 00 00"),
        (fd.HEARTBEAT_ACK, b"", "01 00 00 70 10 00 00 00 11 00 00 70 00 00 00 00"),
        (fd.QUERY_SPEED, b'{"usbSpeed":0,"wifiSpeed":0}', """
            90 06 01 00 2c 00 00 00 bc 06 01 00 00 00 00 00
            7b 22 75 73 62 53 70 65 65 64 22 3a 30 2c 22 77
            69 66 69 53 70 65 65 64 22 3a 30 7d"""),
        (fd.QUERY_SPEED + 1, b"", "91 06 01 00 10 00 00 00 81 06 01 00 00 00 00 00"),
        (fd.CHECK_SN, b'{"client_set":"easy_conn","sn":"DSXXZMHNFV3DEXEBB3PZ2"}', """
            e0 03 01 00 47 00 00 00 a7 03 01 00 00 00 00 00
            7b 22 63 6c 69 65 6e 74 5f 73 65 74 22 3a 22 65
            61 73 79 5f 63 6f 6e 6e 22 2c 22 73 6e 22 3a 22
            44 53 58 58 5a 4d 48 4e 46 56 33 44 45 58 45 42
            42 33 50 5a 32 22 7d"""),
        (fd.CHECK_SN_ACK, b"", "e1 03 01 00 10 00 00 00 f1 03 01 00 00 00 00 00"),
        (fd.CHECK_SN_RESULT, b'{"isOk":true,"errCode":0,"errMsg":"","id":"DSXXZMHNFV3DEXEBB3PZ2","client_set":"easy_conn"}', """
            c0 01 02 00 6b 00 00 00 ab 01 02 00 00 00 00 00
            7b 22 69 73 4f 6b 22 3a 74 72 75 65 2c 22 65 72
            72 43 6f 64 65 22 3a 30 2c 22 65 72 72 4d 73 67
            22 3a 22 22 2c 22 69 64 22 3a 22 44 53 58 58 5a
            4d 48 4e 46 56 33 44 45 58 45 42 42 33 50 5a 32
            22 2c 22 63 6c 69 65 6e 74 5f 73 65 74 22 3a 22
            65 61 73 79 5f 63 6f 6e 6e 22 7d"""),
        (fd.CHECK_SN_RESULT_ACK, b"", "c1 01 02 00 10 00 00 00 d1 01 02 00 00 00 00 00"),
        (fd.HU_QUERY_TIME, b"", "50 04 01 00 10 00 00 00 40 04 01 00 00 00 00 00"),
        (fd.HU_QUERY_TIME_ACK, b"", "51 04 01 00 10 00 00 00 41 04 01 00 00 00 00 00"),
        (fd.OTA_FTP_INFO + 1, b"", "a1 03 01 00 10 00 00 00 b1 03 01 00 00 00 00 00"),
        (fd.LOG_REPORT + 1, b"", "81 07 01 00 10 00 00 00 91 07 01 00 00 00 00 00"),
    ]

    def test_spec_vectors(self):
        for cmd, payload, dump in self.VECTORS:
            hexstr = "".join(dump.split())
            with self.subTest(cmd=hex(cmd)):
                self.assertEqual(fd.encode_cmdbase(cmd, payload).hex(), hexstr)
                hdr, body, rest = fd.decode_cmdbase(H(hexstr))
                self.assertEqual((hdr.cmd, body, rest), (cmd, payload, b""))
                self.assertTrue(hdr.magic_ok)

    def test_probe_vector_header(self):
        frame = fd.encode_cmdbase(fd.MDNS_RESPOND, fd.PROBE_PAYLOAD)
        self.assertEqual(frame[:16], H("10000070560000004600007000000000"))
        self.assertEqual(len(frame), 86)

    def test_negative_magic_vector(self):
        bad = H("00000100100000001100010000000000")
        self.assertFalse(fd.CmdBaseHeader(bad).magic_ok)
        with self.assertRaises(ValueError):
            fd.decode_cmdbase(bad)

    def test_round_trips(self):
        rnd = random.Random(1234)
        for _ in range(300):
            cmd = rnd.choice([rnd.getrandbits(32), rnd.getrandbits(20), 0x70000000 + rnd.getrandbits(4)])
            payload = bytes(rnd.getrandbits(8) for _ in range(rnd.randint(0, 300)))
            frame = fd.encode_cmdbase(cmd, payload)
            hdr, body, rest = fd.decode_cmdbase(frame + b"tail")
            self.assertEqual((hdr.cmd, body, rest), (cmd, payload, b"tail"))
            self.assertEqual(hdr.total_len, 16 + len(payload))
            self.assertEqual(hdr.magic, cmd ^ (16 + len(payload)))

    def test_short_total_len_is_empty_payload(self):
        # Android accepts totalLen < 16 with a matching magic as an empty payload (§2.2 step 4).
        frame = fd.encode_cmdbase(0x10600, b"", total_len=8)
        hdr, body, _ = fd.decode_cmdbase(frame)
        self.assertEqual((hdr.total_len, hdr.payload_len, body), (8, 0, b""))

    def test_reserved_not_validated_by_decoder(self):
        frame = fd.encode_cmdbase(fd.CAR_CTRL, b"", reserved=0x12345678)
        hdr, _, _ = fd.decode_cmdbase(frame)
        self.assertEqual(hdr.reserved, 0x12345678)


class ReqBaseTests(unittest.TestCase):
    """media-video.md §3.3, §4, §14.2."""

    def test_reply_vectors(self):
        self.assertEqual(fd.RLY65.hex(" "), "41 00 00 00 00 00 00 00")
        self.assertEqual(fd.RLY49.hex(" "), "31 00 08 00 00 00 00 00 03 00 00 00 01 00 00 00")
        self.assertEqual(fd.RLY97.hex(" "), "61 00 0b 00 00 00 00 00 7b 22 73 74 61 74 65 22 3a 30 7d")
        self.assertEqual(fd.RLY113.hex(" "), "71 00 00 00 00 00 00 00")
        self.assertEqual(fd.RLY129.hex(" "), "81 00 00 00 00 00 00 00")

    def test_request_vectors(self):
        for ct, hexstr in ((114, "7200000000000000"), (112, "7000000000000000"), (64, "4000000000000000"),
                           (48, "3000000000000000"), (128, "8000000000000000")):
            self.assertEqual(fd.encode_reqbase(ct).hex(), hexstr)
            self.assertEqual(fd.parse_reqbase_header(H(hexstr)), (ct, 0, 0))

    def test_rly17_vectors(self):
        cases = [((800, 386, 0, 2), "11 00 09 00 00 00 00 00 02 00 00 00 20 03 80 01 00"),
                 ((800, 386, 1, 2), "11 00 09 00 00 00 00 00 02 00 00 00 20 03 80 01 01"),
                 ((800, 951, 0, 2), "11 00 09 00 00 00 00 00 02 00 00 00 20 03 b0 03 00"),
                 ((1280, 576, 0, 2), "11 00 09 00 00 00 00 00 02 00 00 00 00 05 40 02 00"),
                 ((800, 386, 0, 0), "11 00 09 00 00 00 00 00 02 00 00 00 20 03 80 01 00")]   # wantEncoder 0 → 2
        for (w, h, ext, enc), want in cases:
            with self.subTest(w=w, h=h, ext=ext, enc=enc):
                body = fd.build_config_capture(w, h, fps=30, encoder=enc, ext=ext)
                self.assertEqual(fd.expected_rly17(body).hex(" "), want)

    def test_rly17_short_bodies(self):
        self.assertEqual(fd.expected_rly17(b"").hex(" "), "11 00 09 00 00 00 00 00 02 00 00 00 00 00 00 00 00")
        self.assertEqual(fd.expected_rly17(struct.pack("<HH", 800, 386)).hex(" "),
                         "11 00 09 00 00 00 00 00 02 00 00 00 20 03 80 01 00")

    def test_config_capture_synthetic_vector(self):
        # media-video.md §4.2 "CFDL16-like" synthetic request (32-byte fixed part, ext 0).
        body = fd.build_config_capture(800, 386, fps=30, encoder=2, ext=0)
        self.assertEqual(fd.encode_reqbase(16, body).hex(" "),
                         "10 00 20 00 00 00 00 00 20 03 82 01 1e 00 00 00 02 00 00 00 " + " ".join(["00"] * 20))
        self.assertEqual(len(fd.build_config_capture(800, 951, huid_text=b"A" * 172)), 204)
        self.assertEqual(fd.build_config_capture(800, 951)[:4].hex(" "), "20 03 b7 03")

    def test_raw_frame_vector(self):
        au = H("00000001674200 1fda01401269a8 0000000168ce0d88 0000000165888400".replace(" ", ""))
        self.assertEqual(len(au), 30)
        self.assertEqual(fd.encode_raw_frame(au).hex(),
                         "1e000000000000016742001fda01401269a80000000168ce0d880000000165888400")

    def test_touch_vectors(self):
        """input-controls.md §2.4."""
        cases = [((2, 640, 288, 0, 123456), "20 00 12 00 00 00 00 00 02 00 80 02 20 01 00 00 40 e2 01 00 00 00 00 00 00 00"),
                 ((3, 700, 300, 0, 123472), "20 00 12 00 00 00 00 00 03 00 bc 02 2c 01 00 00 50 e2 01 00 00 00 00 00 00 00"),
                 ((1, 700, 300, 0, 123488), "20 00 12 00 00 00 00 00 01 00 bc 02 2c 01 00 00 60 e2 01 00 00 00 00 00 00 00"),
                 ((2, 1000, 200, 1, 123500), "20 00 12 00 00 00 00 00 02 00 e8 03 c8 00 01 00 6c e2 01 00 00 00 00 00 00 00")]
        for args, want in cases:
            body = fd.build_touch_body(*args)
            self.assertEqual(len(body), 18)
            self.assertEqual(fd.encode_reqbase(32, body).hex(" "), want)


# =============================================================================================
# Probe, CLIENT_INFO, CHECK_SN validation
# =============================================================================================


class ProbeValidationTests(unittest.TestCase):
    def probe(self, payload=fd.PROBE_PAYLOAD, **kw):
        frame = fd.encode_cmdbase(fd.MDNS_RESPOND, payload, **kw)
        return fd.CmdBaseHeader(frame[:16]), frame[16:]

    def test_exact_probe_is_valid(self):
        self.assertEqual(fd.validate_probe(*self.probe()), [])

    def test_ios_phone_type_rejected(self):
        f = fd.validate_probe(*self.probe(b'{"phoneType":"iOS","packageName":"com.cfmoto.cfmotointernational"}'))
        self.assertEqual(rules(f), ["PROBE_FORMAT", "PROBE_PAYLOAD"])

    def test_whitespace_json_rejected(self):
        f = fd.validate_probe(*self.probe(b'{"phoneType": "Android", "packageName": "com.cfmoto.cfmotointernational"}'))
        self.assertIn("PROBE_PAYLOAD", rules(f))

    def test_reserved_and_magic(self):
        self.assertEqual(rules(fd.validate_probe(*self.probe(reserved=1))), ["PROBE_FORMAT"])
        hdr, body = self.probe(magic=0x1234)
        self.assertEqual(rules(fd.validate_probe(hdr, body)), ["PROBE_FORMAT"])

    def test_wrong_cmd(self):
        frame = fd.encode_cmdbase(fd.HEARTBEAT, fd.PROBE_PAYLOAD)
        self.assertIn("PROBE_FORMAT", rules(fd.validate_probe(fd.CmdBaseHeader(frame[:16]), frame[16:])))


class RsaTests(unittest.TestCase):
    """control-plane.md §9.3, §9.5."""

    def test_modexp_matches_pow(self):
        rnd = random.Random(7)
        for _ in range(100):
            b, e, m = rnd.getrandbits(1024), rnd.getrandbits(rnd.randint(1, 1100)), rnd.getrandbits(1024) | 1
            self.assertEqual(fd.modexp(b, e, m), pow(b, e, m))
        self.assertEqual(fd.modexp(5, 0, 7), 1)
        self.assertEqual(fd.modexp(5, 3, 1), 0)

    def test_fixture_pubkey(self):
        n, e, findings = fd.check_pubkey_b64(SPEC_SPKI_B64)
        self.assertEqual(findings, [])
        self.assertEqual(n, int(SPEC_MODULUS_HEX, 16))
        self.assertEqual(e, 65537)
        der = base64.b64decode(SPEC_SPKI_B64)
        self.assertEqual(der[:22], fd.SPKI_RSA1024_PREFIX)
        self.assertEqual(der[22:], base64.b64decode(SPEC_PKCS1_PUB_B64))
        self.assertEqual(len(der), 162)

    def test_fixture_signature_verifies(self):
        n, e, _ = fd.check_pubkey_b64(SPEC_SPKI_B64)
        self.assertEqual(fd.check_encrypted_huid(SPEC_ENC_HUID_B64, n, e, SPEC_HUID), [])
        em = fd.rsa_public_op(base64.b64decode(SPEC_ENC_HUID_B64), n, e)
        self.assertEqual(em, b"\x00\x01" + b"\xff" * 110 + b"\x00" + SPEC_HUID.encode())    # §9.3
        self.assertEqual(em.hex()[:4], "0001")
        self.assertEqual(len(em), 128)

    def test_signing_with_fixture_private_key_reproduces_spec(self):
        import phone_smoke
        n, e, d = fd.parse_rsa_private_pkcs1(base64.b64decode(phone_smoke.FIXTURE_PKCS1))
        self.assertEqual(n, int(SPEC_MODULUS_HEX, 16))
        self.assertEqual(base64.b64encode(fd.rsa_sign_type1(SPEC_HUID.encode(), n, d)).decode(), SPEC_ENC_HUID_B64)

    def test_bad_signatures(self):
        n, e, _ = fd.check_pubkey_b64(SPEC_SPKI_B64)
        sig = bytearray(base64.b64decode(SPEC_ENC_HUID_B64))
        sig[-1] ^= 1
        self.assertEqual(rules(fd.check_encrypted_huid(base64.b64encode(bytes(sig)).decode(), n, e, SPEC_HUID)),
                         ["CLIENT_INFO_SIGNATURE"])
        self.assertEqual(rules(fd.check_encrypted_huid(SPEC_ENC_HUID_B64, n, e, "6GUVA2C00100056")), ["CLIENT_INFO_SIGNATURE"])
        self.assertEqual(rules(fd.check_encrypted_huid("", n, e, SPEC_HUID)), ["CLIENT_INFO_SIGNATURE"])
        self.assertEqual(fd.check_encrypted_huid("", n, e, ""), [])          # no HUID → ""
        # Public-key ENCRYPTION (block type 2) instead of the private-key operation is reported.
        k = 128
        em2 = b"\x00\x02" + b"\x55" * (k - 3 - len(SPEC_HUID)) + b"\x00" + SPEC_HUID.encode()
        import phone_smoke
        _, _, d = fd.parse_rsa_private_pkcs1(base64.b64decode(phone_smoke.FIXTURE_PKCS1))
        fake = fd.modexp(int.from_bytes(em2, "big"), d, n).to_bytes(k, "big")
        f = fd.check_encrypted_huid(base64.b64encode(fake).decode(), n, e, SPEC_HUID)
        self.assertIn("block type 2", f[0][2])

    def test_pkcs1_instead_of_spki(self):
        n, e, f = fd.check_pubkey_b64(SPEC_PKCS1_PUB_B64)
        self.assertIn("CLIENT_INFO_PUBKEY", rules(f, "violation"))

    def test_wrapped_base64(self):
        wrapped = SPEC_SPKI_B64[:64] + "\n" + SPEC_SPKI_B64[64:]
        _, _, f = fd.check_pubkey_b64(wrapped)
        self.assertIn("CLIENT_INFO_PUBKEY", rules(f, "violation"))


class ClientInfoTests(unittest.TestCase):
    """control-plane.md §8."""

    def setUp(self):
        self.cfdl16 = fd.DASH_MODELS["cfdl16"].info

    def test_spec_worked_example_is_clean(self):
        self.assertEqual(len(SPEC_CLIENT_INFO_REPLY), 800)
        self.assertEqual(fd.encode_cmdbase(fd.CLIENT_INFO_RLY, SPEC_CLIENT_INFO_REPLY)[:16].hex(" "),
                         "11 00 01 00 30 03 00 00 21 03 01 00 00 00 00 00")
        obj, f = fd.validate_client_info_reply(SPEC_CLIENT_INFO_REPLY, self.cfdl16)
        self.assertEqual(f, [])
        self.assertEqual(obj.keys(), fd.CLIENT_INFO_KEYS)

    def mutate(self, fn, unescaped=False):
        obj = fd.parse_json_ordered(SPEC_CLIENT_INFO_REPLY.decode())
        pairs = fn(list(obj))
        text = fd.android_json(pairs)
        if unescaped:
            text = text.replace("\\/", "/")
        return fd.validate_client_info_reply(text.encode(), self.cfdl16)[1]

    def test_key_order_violation(self):
        def swap(p):
            p[2], p[3] = p[3], p[2]
            return p
        self.assertIn("CLIENT_INFO_KEYS", rules(self.mutate(swap), "violation"))

    def test_missing_and_extra_keys(self):
        self.assertIn("CLIENT_INFO_KEYS", rules(self.mutate(lambda p: [kv for kv in p if kv[0] != "token"]), "violation"))
        self.assertIn("CLIENT_INFO_KEYS", rules(self.mutate(lambda p: p + [("extra", 1)]), "violation"))

    def test_value_violations(self):
        def setv(key, value):
            return lambda p: [(k, value if k == key else v) for k, v in p]
        cases = [("versionCode", "126", "CLIENT_INFO_VALUE"), ("versionCode", 136, "CLIENT_INFO_VALUE"),
                 ("phoneOs", "iOS", "CLIENT_INFO_VALUE"), ("package", "dev.zanderp.opencfmoto", "CLIENT_INFO_VALUE"),
                 ("pxcVersion", "1.0.3", "CLIENT_INFO_VALUE"), ("token", False, "CLIENT_INFO_VALUE"),
                 ("phoneOsVersion", 35, "CLIENT_INFO_VALUE"), ("supportH264IFrame", "true", "CLIENT_INFO_VALUE"),
                 ("supportSyncCorrectTime", True, "CLIENT_INFO_SYNC_TIME"), ("bluetoothName", "iPhone", "CLIENT_INFO_VALUE"),
                 ("appVersionFingerPrint", "x", "CLIENT_INFO_VALUE"), ("supportFunction", 64, "CLIENT_INFO_VALUE")]
        for key, value, rule in cases:
            with self.subTest(key=key, value=value):
                self.assertIn(rule, rules(self.mutate(setv(key, value)), "violation"))

    def test_profile_and_parity_warnings(self):
        f = self.mutate(lambda p: p + [("supportScreenTouch", True)])
        self.assertEqual(rules(f, "violation"), [])
        self.assertEqual(rules(f, "warning"), ["CLIENT_INFO_PROFILE"])
        f = self.mutate(lambda p: [(k, 128 if k == "supportFunction" else v) for k, v in p])
        self.assertEqual(rules(f), ["CLIENT_INFO_PROFILE"])
        f = self.mutate(lambda p: p, unescaped=True)          # '/' not escaped: semantically equal
        self.assertEqual(rules(f), ["CLIENT_INFO_BYTES"])
        f = self.mutate(lambda p: [(k, "Apple" if k == "phoneBrand" else v) for k, v in p])
        self.assertEqual(f, [])
        f = self.mutate(lambda p: [(k, "3F2B8C1E-9A47-4D2E-8B6A-0C5D7E9F1A23" if k == "phoneUUID" else v) for k, v in p])
        self.assertEqual(rules(f), ["CLIENT_INFO_VALUE"])
        self.assertEqual(rules(f, "violation"), [])

    def test_supportscreentouch_false_is_violation(self):
        f = self.mutate(lambda p: p + [("supportScreenTouch", False)])
        self.assertIn("CLIENT_INFO_VALUE", rules(f, "violation"))

    def test_not_json(self):
        self.assertEqual(rules(fd.validate_client_info_reply(b"{nope", self.cfdl16)[1]), ["CLIENT_INFO_JSON"])

    def test_android_json_escaping(self):
        self.assertEqual(fd.android_json([("a/b", "x/y\"z\\\n\t\x01"), ("n", 1), ("t", True), ("f", False)]),
                         '{"a\\/b":"x\\/y\\"z\\\\\\n\\t\\u0001","n":1,"t":true,"f":false}')

    def test_sn_result(self):
        good = b'{"isOk":true,"errCode":0,"errMsg":"","id":"DSXXZMHNFV3DEXEBB3PZ2","client_set":"easy_conn"}'
        self.assertEqual(fd.validate_sn_result(good, "DSXXZMHNFV3DEXEBB3PZ2"), [])
        reordered = b'{"errCode":0,"isOk":true,"errMsg":"","id":"DSXXZMHNFV3DEXEBB3PZ2","client_set":"easy_conn"}'
        self.assertIn("ORDER", fd.validate_sn_result(reordered, "DSXXZMHNFV3DEXEBB3PZ2")[0][2])
        self.assertEqual(rules(fd.validate_sn_result(good, "OTHER")), ["CHECK_SN_RESULT"])
        spaced = b'{"isOk": true, "errCode": 0, "errMsg": "", "id": "X", "client_set": "easy_conn"}'
        self.assertEqual(rules(fd.validate_sn_result(spaced, "X"), "warning"), ["CHECK_SN_RESULT"])


# =============================================================================================
# Clock, profiles, Annex-B
# =============================================================================================


class ClockTests(unittest.TestCase):
    """control-plane.md §13.2 vectors."""

    REQ = H("feffffff32920000070000000000000032303236" "2d30372d32342031373a30393a32302e313930303030303030")

    def test_spec_request_and_echo_frames(self):
        self.assertEqual(len(self.REQ), 45)
        self.assertEqual(fd.encode_cmdbase(fd.HU_TIME_SYNC, self.REQ)[:16].hex(" "), "00 06 01 00 3d 00 00 00 3d 06 01 00 00 00 00 00")
        self.assertEqual(fd.encode_cmdbase(fd.HU_TIME_SYNC_ACK, self.REQ)[:16].hex(" "), "01 06 01 00 3d 00 00 00 3c 06 01 00 00 00 00 00")
        self.assertEqual(fd.check_time_sync_reply(self.REQ, self.REQ), ("echo", []))

    def test_echo_mismatch_and_empty(self):
        mode, f = fd.check_time_sync_reply(self.REQ, b"")
        self.assertEqual((mode, rules(f)), ("echo", ["CLOCK_REPLY"]))
        bad = bytearray(self.REQ)
        bad[20] ^= 1
        self.assertEqual(rules(fd.check_time_sync_reply(self.REQ, bytes(bad))[1]), ["CLOCK_REPLY"])

    def test_short_request_padded(self):
        req = struct.pack("<iiii", -2, 1, 1, 0) + b"2026-08-13 14:05:20.190"
        self.assertEqual(len(req), 39)
        want = H("feffffff010000000100000000000000") + b"2026-08-13 14:05:20.190" + b"\x00" * 6
        self.assertEqual(fd.ts_expected_base(req), want)
        self.assertEqual(fd.check_time_sync_reply(req, want), ("echo", []))

    def test_phone_mode_vectors(self):
        now = fd.datetime.datetime.now()
        stamp = (now.strftime("%Y-%m-%d %H:%M:%S") + ".%03d000000" % (now.microsecond // 1000)).encode()
        epoch = struct.pack("<iiii", -2, 37426, 7, 0) + b"1970-01-01 00:00:00.000000000"
        mode, f = fd.check_time_sync_reply(epoch, epoch[:16] + stamp)
        self.assertEqual((mode, f), ("phone", []))
        mode, f = fd.check_time_sync_reply(b"", H("feffffff000000000100000000000000") + stamp)    # synthesized header
        self.assertEqual((mode, f), ("phone", []))
        mode, f = fd.check_time_sync_reply(epoch, epoch)        # echoing 1970 is wrong
        self.assertEqual((mode, rules(f)), ("phone", ["CLOCK_REPLY"]))
        mode, f = fd.check_time_sync_reply(b"", H("feffffff000000000100000000000000") + b"2026-08-09T12:43:39.244000000")
        self.assertEqual(rules(f), ["CLOCK_REPLY"])

    def test_should_echo_rules(self):
        hdr = struct.pack("<iiii", -2, 0, 1, 0)
        self.assertTrue(fd.ts_should_echo("2026-01-01T00:00:00.000000000", hdr + b"x"))
        self.assertTrue(fd.ts_should_echo("garbage", hdr + b"x"))
        self.assertFalse(fd.ts_should_echo("1969-12-31 23:59:59", hdr + b"x"))
        self.assertFalse(fd.ts_should_echo("1971-06-01 00:00:00", hdr + b"x"))
        self.assertTrue(fd.ts_should_echo("1972-06-01 00:00:00", hdr + b"x"))
        self.assertFalse(fd.ts_should_echo("", hdr))
        self.assertFalse(fd.ts_should_echo("2026-01-01 00:00:00", b"short"))
        self.assertEqual(fd.ts_extract_stamp(hdr + b"2026-01-01 00:00:00\x00\x00  "), "2026-01-01 00:00:00")

    def test_generated_requests(self):
        t = fd.datetime.datetime(2026, 7, 24, 17, 9, 20, 190000)
        self.assertEqual(fd.time_sync_payload("normal", 37426, 7, t), self.REQ)
        self.assertEqual(len(fd.time_sync_payload("short", 1, 1, t)), 39)
        self.assertEqual(fd.time_sync_payload("tsep", 1, 1, t)[16:], b"2026-07-24T17:09:20.190000000")
        self.assertFalse(fd.ts_should_echo(fd.ts_extract_stamp(fd.time_sync_payload("epoch", 1, 3, t)),
                                           fd.time_sync_payload("epoch", 1, 3, t)))


class ProfileTests(unittest.TestCase):
    """control-plane.md §12.6 scoring table (order: Nk800, NkTouch, Morini, MP-66, ClC450, Land, Port, Legacy)."""

    ORDER = ["Nk800", "Cfdl26NkTouch", "MoriniMlSoftAp", "Cfdl16MotoPlayLandscape", "ClC450", "Cfdl26Landscape",
             "Cfdl26Portrait", "LegacyCfdl16"]
    CASES = [
        ("A", {"HUID": "6GUVA2C00100055", "HUName": "CFDL16-6GUV", "sdkVersion": "0.9.29.1", "supportFunction": 0},
         [0, 0, 1, 3, 0, -1, 0, 8], "LegacyCfdl16"),
        ("B", {"HUID": "6WX0AT231300200", "package_name": "com.cfmoto.cfdashmotoplay", "version_name": "CFDL26.2.3.5.0.6",
               "sdkVersion": "1.1.4", "enableSockServerAuth": True, "supportScreenTouch": True,
               "supportMirrorOverlayTouch": True, "supportFunction": 128}, [0, 11, 0, 0, 0, 9, 12, 1], "Cfdl26Portrait"),
        ("C", {"HUID": "6WWVA2C00300088", "package_name": "com.cfmoto.easyconnect", "version_name": "CFDL26.2.3.0.5",
               "sdkVersion": "1.1.2", "enableSockServerAuth": True, "supportScreenTouch": True,
               "supportLandscapeAdaptive": True, "supportFunction": 128}, [0, 9, 0, 1, 0, 19, 9, 1], "Cfdl26Landscape"),
        ("D", {"HUID": "6KWV00000000001", "package_name": "com.cfmoto.easyconnect", "version_name": "CFDL26.2.3.0.5",
               "sdkVersion": "1.1.2", "enableSockServerAuth": True, "supportScreenTouch": True,
               "supportMirrorOverlayTouch": True, "supportFunction": 128}, [0, 18, 0, 0, 0, 12, 9, 1], "Cfdl26NkTouch"),
        ("E", {"HUID": "CRCP230501740", "package_name": "linux_no_package", "sdkVersion": "0.9.23.4", "supportFunction": 128},
         [9, 0, 1, 3, 1, -1, 0, 1], "Nk800"),
        ("F", {"HUID": "CARB0000001", "channel": "21333", "flavor": 51, "package_name": "", "sdkVersion": "1.0.13.1"},
         [0, 2, 30, 1, 0, 0, 0, 1], "MoriniMlSoftAp"),
        ("G", {"HUName": "CL-C450-48FB4C", "channel": "66660736", "sdkVersion": "0.9.23.4"}, [0, 0, 1, 3, 13, -1, 0, 1], "ClC450"),
        ("H", {"channel": "66660742", "sdkVersion": "0.9.25.1", "supportLandscapeAdaptive": True},
         [0, -4, 1, 14, 0, -1, 0, 1], "Cfdl16MotoPlayLandscape"),
        ("I", {"sdkVersion": "1.2.0"}, [0, 2, 1, 1, 0, -1, 0, 1], "Cfdl26NkTouch"),
        ("J", {"sdkVersion": "0.9.30"}, [0, 0, 1, 3, 0, -1, 0, 1], "Cfdl16MotoPlayLandscape"),
        ("K", {"sdkVersion": "1.2.0", "supportScreenTouch": True}, [0, 3, 0, 0, 0, 0, 0, 1], "Cfdl26NkTouch"),
        ("L", {"version_name": "CFDL06.6.10", "package_name": "net.easyconn", "sdkVersion": "0.9.25.1", "supportFunction": 128},
         [0, 0, 1, 3, 0, -1, 0, 1], "Cfdl16MotoPlayLandscape"),
    ]

    def test_scoring_table(self):
        for label, info, scores, selected in self.CASES:
            with self.subTest(case=label):
                p = fd.expected_profile(info)
                self.assertEqual([p["scores"][n] for n in self.ORDER], scores)
                self.assertEqual(p["name"], selected)

    def test_models_expected_replies(self):
        exp = {k: fd.expected_profile(m.info) for k, m in fd.DASH_MODELS.items()}
        self.assertEqual((exp["cfdl16"]["name"], exp["cfdl16"]["supportFunction"], exp["cfdl16"]["supportScreenTouch"]),
                         ("LegacyCfdl16", 0, False))
        self.assertEqual((exp["cfdl26"]["name"], exp["cfdl26"]["supportFunction"], exp["cfdl26"]["supportScreenTouch"]),
                         ("Cfdl26Portrait", 128, False))
        self.assertEqual((exp["mt800"]["name"], exp["mt800"]["supportFunction"], exp["mt800"]["supportScreenTouch"]),
                         ("Cfdl26Landscape", 128, True))
        self.assertEqual([m.canvas for m in (fd.DASH_MODELS["cfdl16"], fd.DASH_MODELS["cfdl26"], fd.DASH_MODELS["mt800"])],
                         [(800, 384), (800, 944), (1280, 576)])

    def test_opt_coercions(self):
        info = {"a": 12, "b": "37", "c": "true", "d": True, "e": "x"}
        self.assertEqual(fd._opt_string(info, "a"), "12")
        self.assertEqual(fd._opt_int(info, "b"), 37)
        self.assertTrue(fd._opt_bool(info, "c"))
        self.assertEqual(fd._opt_int(info, "d"), 0)
        self.assertEqual(fd._opt_int(info, "e", 5), 5)
        self.assertEqual(fd._opt_string(info, "missing"), "")

    def test_burst_never_carries_a_real_password(self):
        payloads = b"".join(p for _, p in fd.burst_frames(fd.DASH_MODELS["cfdl26"], 1))
        self.assertIn(b"PLACEHOLDER", payloads)
        self.assertNotIn(b"Siwei", payloads)


class AnnexBTests(unittest.TestCase):
    """media-video.md §5, §6, §14.1 (YunmoFrameTest vectors)."""

    SPS = H("6742001fda01401269a8")
    TOY_IDR = H("00000001674200 1fda01401269a8 0000000168ce0d88 0000000165888400".replace(" ", ""))

    def test_first_nal_types(self):
        self.assertEqual(fd.analyze_au(H("0000000167420 01f".replace(" ", ""))).nal_types, [7])
        self.assertEqual(fd.analyze_au(H("00000001650001")).nal_types, [5])
        self.assertEqual(fd.analyze_au(H("0000014100")).nal_types, [1])

    def test_split_three_nals(self):
        buf = H("00000001674200") + H("0000000168ce") + H("000000016588")
        self.assertEqual(fd.split_nals(buf), [H("674200"), H("68ce"), H("6588")])

    def test_toy_idr(self):
        info = fd.analyze_au(self.TOY_IDR)
        self.assertEqual(info.nal_types, [7, 8, 5])
        self.assertTrue(info.has_idr and info.sps_before_vcl and info.pps_before_vcl)
        self.assertEqual(info.leading, 0)
        self.assertEqual(info.kind, "IDR")

    def test_idr_without_params_and_p(self):
        info = fd.analyze_au(H("0000000165888400"))
        self.assertTrue(info.has_idr)
        self.assertFalse(info.sps_before_vcl)
        p = fd.analyze_au(H("00000001419a0021"))
        self.assertEqual((p.kind, p.vcl, p.has_idr), ("P", 1, False))
        self.assertEqual(fd.analyze_au(H("00000001674200000000000168ce")).kind, "no-VCL")

    def test_avcc_detection(self):
        avcc = struct.pack(">I", 3) + H("674200") + struct.pack(">I", 2) + H("68ce") + struct.pack(">I", 3) + H("658884")
        info = fd.analyze_au(avcc)
        self.assertTrue(info.leading > 0 or not info.nal_types)
        self.assertTrue(info.avcc)
        self.assertFalse(fd.looks_avcc(self.TOY_IDR))

    def test_exp_golomb(self):
        br = fd.BitReader(bytes([0b10100110, 0b01000000]))   # ue: 0, 1, 2, then se of '00100' = 3 → +2
        self.assertEqual([br.ue(), br.ue(), br.ue()], [0, 1, 2])
        br = fd.BitReader(bytes([0b00100000]))
        self.assertEqual(br.se(), 2)
        self.assertEqual(fd.rbsp_unescape(H("0000030100000300")), H("000001000000"))

    def test_spec_sps_prefix(self):
        """media-video.md §7.6: the 800MT SPS prefix decodes to Baseline (66), level 31, 1280x576."""
        sps = fd.parse_sps(self.SPS + b"\x00" * 8)
        self.assertIsNotNone(sps)
        self.assertEqual((sps["profile_idc"], sps["level_idc"], sps["width"], sps["height"], sps["poc_type"],
                          sps["max_num_ref_frames"]), (66, 31, 1280, 576, 2, 1))

    def test_clips(self):
        for name, size in (("clip_800x384.h264", (800, 384)), ("clip_800x944.h264", (800, 944)),
                           ("clip_1280x576.h264", (1280, 576))):
            path = os.path.join(HERE, "clips", name)
            if not os.path.exists(path):
                self.skipTest("clips not generated")
            with self.subTest(clip=name):
                with open(path, "rb") as f:
                    data = f.read()
                self.assertLess(len(data), 300 * 1024)
                info = fd.analyze_au(data)
                self.assertEqual(info.nal_types[:2], [7, 8])
                self.assertEqual((info.sps["width"], info.sps["height"]), size)
                self.assertEqual(info.sps["profile_idc"], 66)
                self.assertEqual(info.sps["level_idc"], 31)
                self.assertNotIn(1, [st % 5 for st in info.slice_types])        # no B slices
                self.assertFalse(info.sps.get("max_num_reorder_frames"))


class SpsVariantTests(unittest.TestCase):
    """Locked iPhone, Phase 0: every distinct SPS/PPS of a stream (the `locked` scenario), with the
    vectors of the contract (CI simulator VideoToolbox SPS, the reference SPS, PPS 28 de 09 c8)."""

    VT_SPS = H("2742e01fa918190636 02d4080808c2b5ef7c04".replace(" ", ""))
    REF_SPS = H("6742c01fda0320c680784423 50".replace(" ", ""))
    PPS = H("28de09c8")
    PPS2 = H("68ce3c80")

    @staticmethod
    def au(*nals):
        return b"".join(b"\x00\x00\x00\x01" + n for n in nals)

    def idr(self, sps, pps=None):
        return fd.analyze_au(self.au(sps, pps or self.PPS, H("658884aa")))

    def p(self):
        return fd.analyze_au(self.au(H("419a11")))

    def test_two_encoders_give_two_variants_with_their_fields(self):
        v = fd.SpsVariants()
        self.assertEqual(v.observe(self.idr(self.VT_SPS), 1), (None, 0, True, True))
        self.assertIsNone(v.observe(self.p(), 2))
        self.assertEqual(v.observe(self.idr(self.REF_SPS), 3), (0, 1, True, True))
        self.assertIsNone(v.observe(self.p(), 4))
        self.assertIsNone(v.observe(self.p(), 5))
        a, b = v.summary()
        self.assertEqual(a, {"hex": self.VT_SPS.hex(), "pps_hex": self.PPS.hex(), "first_frame": 1, "frames": 2,
                             "profile": 66, "level": 31, "constraints": 0xE0, "poc_type": 0, "refs": 2,
                             "log2_max_frame_num": 5, "vui": True, "reorder": None, "width": 800, "height": 384})
        self.assertEqual(b, {"hex": self.REF_SPS.hex(), "pps_hex": self.PPS.hex(), "first_frame": 3, "frames": 3,
                             "profile": 66, "level": 31, "constraints": 0xC0, "poc_type": 2, "refs": 1,
                             "log2_max_frame_num": 4, "vui": True, "reorder": 0, "width": 800, "height": 384})
        self.assertEqual(v.changes, [(1, None, 0, True), (3, 0, 1, True)])
        self.assertEqual(fd.variant_text(a), "profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 "
                                             "vui=yes reorder=- | SPS %s PPS %s" % (self.VT_SPS.hex(), self.PPS.hex()))
        json.dumps(v.summary())  # JSON-ready (summary.json)

    def test_switching_back_reuses_the_first_variant(self):
        v = fd.SpsVariants()
        v.observe(self.idr(self.VT_SPS), 1)
        v.observe(self.idr(self.REF_SPS), 2)
        self.assertEqual(v.observe(self.idr(self.VT_SPS), 3), (1, 0, True, False))
        self.assertEqual(v.observe(self.idr(self.VT_SPS), 4), None, "same variant: no change")
        self.assertEqual([x["frames"] for x in v.summary()], [3, 1])
        self.assertEqual(len(v.summary()), 2)

    def test_a_new_pps_alone_is_a_new_variant(self):
        v = fd.SpsVariants()
        v.observe(self.idr(self.VT_SPS), 1)
        self.assertEqual(v.observe(self.idr(self.VT_SPS, self.PPS2), 2), (0, 1, True, True))
        self.assertEqual(v.summary()[1]["pps_hex"], self.PPS2.hex())

    def test_a_switch_on_a_p_frame_is_reported_as_not_at_an_idr(self):
        v = fd.SpsVariants()
        v.observe(self.idr(self.VT_SPS), 1)
        info = fd.analyze_au(self.au(self.REF_SPS, self.PPS, H("419a11")))
        self.assertEqual(v.observe(info, 2), (0, 1, False, True))

    def test_locked_switch_findings(self):
        one = [{"hex": "aa", "pps_hex": "bb"}]
        two = one + [{"hex": "cc", "pps_hex": "bb"}]
        self.assertEqual(fd.locked_switch_findings([two]), [])
        self.assertEqual(fd.locked_switch_findings([one, [{"hex": "cc", "pps_hex": "bb"}]]), [], "across sessions")
        for lists in ([one], [one, one], [], [[]]):
            found = fd.locked_switch_findings(lists)
            self.assertEqual([(sev, rule) for sev, rule, _ in found], [("violation", "LOCKED_NO_SWITCH")], lists)

    @staticmethod
    def slice_nal(idr, frame_num, log2=5, ref=True):
        """A Baseline slice NAL: first_mb 0, slice type I (IDR) or P, PPS 0, `frame_num` in `log2` bits (an IDR
        then idr_pic_id 0), the RBSP stop bit and zero padding."""
        def ue(v):
            v += 1
            return "0" * (v.bit_length() - 1) + format(v, "b")
        bits = ue(0) + ue(7 if idr else 5) + ue(0) + format(frame_num, "0%db" % log2)
        if idr:
            bits += ue(0)
        bits += "1"
        bits += "0" * (-len(bits) % 8)
        header = 0x65 if idr else (0x41 if ref else 0x01)   # nal_ref_idc 3 / 2 / 0
        return bytes([header]) + int(bits, 2).to_bytes(len(bits) // 8, "big")

    def test_frame_num_check_catches_a_p_frame_whose_idr_never_arrived(self):
        """Phase 0 review E2E-IDR-UNPROVEN: byte-identical SPS/PPS of both encoders hide a switch from the
        variant rule; frame_num continuity (gaps_in_frame_num_allowed = 0) still shows a P-frame of a second
        encoder whose IDR the dash never got."""
        c = fd.FrameNumCheck()
        def feed(idr, fn, ref=True, params=False):
            nals = ([self.VT_SPS, self.PPS] if params else []) + [self.slice_nal(idr, fn, ref=ref)]
            a = self.au(*nals)
            return c.observe(fd.analyze_au(a), a)
        self.assertIsNone(feed(True, 0, params=True), "an IDR starts the sequence")
        self.assertIsNone(feed(False, 1))
        self.assertIsNone(feed(False, 2))
        self.assertIsNone(feed(False, 3, ref=False), "a non-reference frame: frame_num 3 is due")
        self.assertIsNone(feed(False, 3), "it did not advance PrevRefFrameNum")
        self.assertEqual(feed(False, 9), (9, 4), "the other encoder's P-frame: 9 where 4 was due")
        self.assertIsNone(feed(True, 0, params=True), "its IDR resets the sequence")
        self.assertIsNone(feed(False, 1))
        self.assertEqual(feed(False, 31), (31, 2))
        self.assertIsNone(feed(False, 0), "after a break the check goes on from the frame it saw (31 + 1 wraps to 0)")
        c2 = fd.FrameNumCheck()
        a = self.au(self.VT_SPS, self.PPS, self.slice_nal(True, 0))
        self.assertIsNone(c2.observe(fd.analyze_au(a), a))
        for fn in range(1, 32):
            a = self.au(self.slice_nal(False, fn))
            self.assertIsNone(c2.observe(fd.analyze_au(a), a), fn)
        a = self.au(self.slice_nal(False, 0))
        self.assertIsNone(c2.observe(fd.analyze_au(a), a), "MaxFrameNum 32 wraps 31 to 0")

    def test_locked_switch_findings_with_one_variant_allowed(self):
        one = [{"hex": "aa", "pps_hex": "bb"}]
        found = fd.locked_switch_findings([one], min_variants=1)
        self.assertEqual([(sev, rule) for sev, rule, _ in found], [("info", "LOCKED_ONE_VARIANT")])
        self.assertEqual(fd.locked_switch_findings([one + [{"hex": "cc", "pps_hex": "bb"}]], min_variants=1), [])
        for lists in ([], [[]]):
            found = fd.locked_switch_findings(lists, min_variants=1)
            self.assertEqual([(sev, rule) for sev, rule, _ in found], [("violation", "LOCKED_NO_SWITCH")], lists)
        self.assertEqual(fd.parse_args(["--scenario", "locked"]).min_variants, 2)
        self.assertEqual(fd.parse_args(["--scenario", "locked", "--min-variants", "1"]).min_variants, 1)

    def test_locked_scenario_defaults(self):
        self.assertEqual(fd.SCENARIOS["locked"], ("cfdl16", 60.0))
        a = fd.parse_args(["--scenario", "locked"])
        self.assertEqual((a.dash, a.seconds, a.trace_headers), ("cfdl16", 60.0, None))
        self.assertEqual(fd.STRICT_DECODE_FLAGS, ["-xerror", "-err_detect", "+crccheck+bitstream+buffer+explode"])

    TRACE = "\n".join([
        "Input #0, h264, from 'in.h264':",
        "[trace_headers @ 0x1] Sequence Parameter Set",
        "[trace_headers @ 0x1] 8           profile_idc                                          01000010 = 66",
        "[trace_headers @ 0x1] 18          constraint_set2_flag                                        0 = 0",
        "[trace_headers @ 0x1] Picture Parameter Set",
        "[trace_headers @ 0x1] 0           forbidden_zero_bit                                          0 = 0",
        "[trace_headers @ 0x1] Packet: 1200 bytes, key frame, pts 0, dts 0.",
        "[trace_headers @ 0x1] Sequence Parameter Set",
        "[trace_headers @ 0x1] 8           profile_idc                                          01000010 = 66",
        "[trace_headers @ 0x1] 18          constraint_set2_flag                                        0 = 0",
        "[trace_headers @ 0x1] Picture Parameter Set",
        "[trace_headers @ 0x1] 0           forbidden_zero_bit                                          0 = 0",
        "[trace_headers @ 0x1] Supplemental Enhancement Information",
        "[trace_headers @ 0x1] 0           forbidden_zero_bit                                          0 = 0",
        "[trace_headers @ 0x1] Slice Header",
        "[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0",
        "[trace_headers @ 0x1] 9           slice_type                                              0001000 = 7",
        "[trace_headers @ 0x1] Packet: 300 bytes, pts 1, dts 1.",
        "[trace_headers @ 0x1] Slice Header",
        "[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0",
        "[trace_headers @ 0x2] Packet: 1210 bytes, key frame, pts 2, dts 2.",
        "[trace_headers @ 0x2] Sequence Parameter Set",
        "[trace_headers @ 0x2] 8           profile_idc                                          01000010 = 66",
        "[trace_headers @ 0x2] 18          constraint_set2_flag                                        0 = 0",
        "[trace_headers @ 0x2] Picture Parameter Set",
        "[trace_headers @ 0x2] 0           forbidden_zero_bit                                          0 = 0",
        "[trace_headers @ 0x2] Slice Header",
        "[trace_headers @ 0x2] 8           first_mb_in_slice                                           1 = 0",
        "[trace_headers @ 0x1] Packet: 1300 bytes, key frame, pts 3, dts 3.",
        "[trace_headers @ 0x1] Sequence Parameter Set",
        "[trace_headers @ 0x1] 8           profile_idc                                          01000010 = 66",
        "[trace_headers @ 0x1] 18          constraint_set2_flag                                        1 = 1",
        "[trace_headers @ 0x1] Picture Parameter Set",
        "[trace_headers @ 0x1] 0           forbidden_zero_bit                                          0 = 0",
        "[trace_headers @ 0x1] Slice Header",
        "[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0",
        "[trace_headers @ 0x1] 9           slice_type                                              0001000 = 7",
    ]) + "\n"

    def test_trace_headers_keep_the_first_and_each_changed_parameter_set_with_its_slice_header(self):
        out = fd.filter_trace_headers(self.TRACE).splitlines()
        lines = self.TRACE.splitlines()
        self.assertEqual(out, lines[1:6]                    # the extradata's SPS / PPS
                         + ["#1 " + lines[6]] + lines[7:12] + lines[14:17]  # packet 1: SPS, PPS, its slice header
                         + ["#4 " + lines[28]] + lines[29:])                 # packet 4: the switch
        self.assertNotIn("#2 ", "\n".join(out), "a P-frame without parameter sets")
        self.assertNotIn("#3 ", "\n".join(out), "the same SPS/PPS again (another trace prefix does not count)")
        self.assertNotIn("Supplemental Enhancement Information", "\n".join(out))
        self.assertEqual(len(fd.filter_trace_headers(self.TRACE, slice_lines=1).splitlines()), len(out) - 2)
        other = "\n".join("line %d" % i for i in range(5000))
        self.assertEqual(fd.filter_trace_headers(other).splitlines(), ["line %d" % i for i in range(2000)],
                         "no parameter-set block: the head of the dump")


class StrictDecodeTests(unittest.TestCase):
    """`decode_check(strict=True)` (scenario `locked`): the strict ffmpeg flags, the lenient run kept apart,
    and the filtered trace_headers dump — with stub ffprobe / ffmpeg on PATH that record their arguments."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="fakedash-strict-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        with open(os.path.join(self.tmp, "trace.txt"), "w") as f:
            f.write(SpsVariantTests.TRACE)
        self.stub("ffprobe", "echo '{\"streams\":[{\"codec_name\":\"h264\",\"profile\":\"Constrained Baseline\",\"level\":31,"
                             "\"width\":800,\"height\":384,\"pix_fmt\":\"yuv420p\",\"nb_read_frames\":\"3\"}]}'")
        old = os.environ["PATH"]
        os.environ["PATH"] = self.tmp + os.pathsep + old
        self.addCleanup(os.environ.__setitem__, "PATH", old)
        self.h264 = os.path.join(self.tmp, "in.h264")
        with open(self.h264, "wb") as f:
            f.write(b"\x00\x00\x00\x01\x65\x88")

    def stub(self, name, body):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            f.write("#!/bin/sh\n" + body + "\n")
        os.chmod(path, 0o755)

    def ffmpeg(self, strict_rc=0, strict_err=""):
        # Records every call; the strict run (it has -xerror) answers strict_rc / strict_err; the
        # trace_headers run prints the synthetic trace on stderr.
        self.stub("ffmpeg", 'D=$(dirname "$0"); echo "$*" >> "$D/ffmpeg-args.txt"\n'
                            'case "$*" in *trace_headers*) cat "$D/trace.txt" >&2;; '
                            '*-xerror*) [ -n "%s" ] && echo "%s" >&2; exit %d;; esac\nexit 0' % (strict_err, strict_err, strict_rc))

    def calls(self):
        with open(os.path.join(self.tmp, "ffmpeg-args.txt")) as f:
            return f.read().splitlines()

    def test_strict_decode_runs_the_strict_flags_before_the_input(self):
        self.ffmpeg()
        headers = os.path.join(self.tmp, "frames", "headers.txt")
        res = fd.decode_check(self.h264, (800, 384), 3, strict=True, headers_path=headers)
        calls = self.calls()
        self.assertEqual(len(calls), 3, calls)
        self.assertEqual(calls[0], "-hide_banner -v error -f h264 -i %s -f null -" % self.h264, "the lenient run")
        self.assertEqual(calls[1], "-hide_banner -v error -xerror -err_detect +crccheck+bitstream+buffer+explode -f h264 "
                                   "-i %s -f null -" % self.h264)
        self.assertEqual(calls[2], "-hide_banner -f h264 -i %s -c:v copy -bsf:v trace_headers -f null -" % self.h264)
        self.assertTrue(res["strict"])
        self.assertEqual(res["strict_flags"], "-xerror -err_detect +crccheck+bitstream+buffer+explode")
        self.assertTrue(res["decodable"])
        self.assertTrue(res["lenient_decodable"])
        with open(headers) as f:
            text = f.read()
        self.assertEqual(text, fd.filter_trace_headers(SpsVariantTests.TRACE))
        self.assertEqual(res["headers_file"], headers)
        self.assertEqual(res["headers_lines"], len(fd.filter_trace_headers(SpsVariantTests.TRACE).splitlines()))

    def test_a_strict_only_failure_is_not_decodable_but_lenient_clean(self):
        self.ffmpeg(strict_rc=1, strict_err="[h264 @ 0x1] error while decoding MB 3 7")
        res = fd.decode_check(self.h264, (800, 384), 3, strict=True)
        self.assertFalse(res["decodable"])
        self.assertTrue(res["lenient_decodable"])
        self.assertEqual(res["decode_returncode"], 1)
        self.assertEqual(res["decode_errors"], ["[h264 @ 0x1] error while decoding MB 3 7"])
        self.assertEqual(len(self.calls()), 2, "no trace_headers run without a headers path")

    def test_the_other_scenarios_decode_as_before(self):
        self.ffmpeg()
        res = fd.decode_check(self.h264, (800, 384), 3)
        self.assertEqual(self.calls(), ["-hide_banner -v error -f h264 -i %s -f null -" % self.h264])
        self.assertNotIn("strict", res)
        self.assertNotIn("lenient_decodable", res)
        self.assertTrue(res["decodable"])


class SinkTests(unittest.TestCase):
    class _Run(object):
        def __init__(self):
            self.lines = []

        def log(self, msg, level=1):
            self.lines.append(msg)

    def _stub(self, name, body):
        tmp = tempfile.mkdtemp(prefix="fakedash-stub-")
        self.addCleanup(shutil.rmtree, tmp, True)
        path = os.path.join(tmp, name)
        with open(path, "w") as f:
            f.write("#!/bin/sh\n" + body + "\n")
        os.chmod(path, 0o755)
        old = os.environ["PATH"]
        os.environ["PATH"] = tmp + os.pathsep + old
        self.addCleanup(os.environ.__setitem__, "PATH", old)
        return tmp

    def test_ffplay_pipe_and_file(self):
        tmp = self._stub("ffplay", 'cat > "$(dirname "$0")/piped.h264"')
        out = os.path.join(tmp, "out.h264")
        run = self._Run()
        sink = fd.H264Sink(run, out, True, "test")
        aus = [b"\x00\x00\x00\x01\x65" + bytes([i]) * 1000 for i in range(30)]
        for au in aus:
            sink.write(au)
        sink.close()
        self.assertEqual(_read_bytes(out), b"".join(aus))
        self.assertEqual(_read_bytes(os.path.join(tmp, "piped.h264")), b"".join(aus))

    def test_ffplay_exiting_early_stops_queueing(self):
        self._stub("ffplay", "head -c 10 > /dev/null")
        run = self._Run()
        sink = fd.H264Sink(run, None, True, "test")
        for _ in range(200):
            sink.write(b"\x00\x00\x00\x01\x41" + b"\x55" * 20000)
            if sink.q is None:
                break
            time.sleep(0.01)
        self.assertIsNone(sink.q)
        t0 = time.monotonic()
        sink.close()
        self.assertLess(time.monotonic() - t0, 5)

    def test_bonjour_command_line(self):
        """--bonjour builds `dns-sd -R <name> _EasyConn._tcp local <port> huid=… huname=… channel=… flavor=… port=… ip=…`."""
        tmp = tempfile.mkdtemp(prefix="fakedash-bonjour-")
        log = os.path.join(tmp, "args.txt")
        stub = os.path.join(tmp, "dns-sd")
        with open(stub, "w") as f:
            f.write("#!/bin/sh\nprintf '%%s\\n' \"$@\" > %s\nexec sleep 30\n" % log)
        os.chmod(stub, 0o755)

        class R(object):
            def log(self, msg, level=1):
                pass

        old = os.environ["PATH"]
        os.environ["PATH"] = tmp + os.pathsep + old
        try:
            adv = fd.BonjourAdvertiser(R(), "CFDL16-6GUV", 10930, [("huid", "6GUVA2C00100055"), ("huname", "CFDL16-6GUV"),
                                                                    ("channel", "37416"), ("flavor", "65540"),
                                                                    ("port", "10930"), ("ip", "192.168.1.23")])
            self.assertTrue(adv.start())
            for _ in range(50):
                if os.path.exists(log) and _read(log).count("\n") >= 11:
                    break
                time.sleep(0.05)
            adv.stop()
        finally:
            os.environ["PATH"] = old
            self.addCleanup(shutil.rmtree, tmp, True)
        self.assertEqual(_read(log).split("\n")[:11],
                         ["-R", "CFDL16-6GUV", "_EasyConn._tcp", "local", "10930", "huid=6GUVA2C00100055",
                          "huname=CFDL16-6GUV", "channel=37416", "flavor=65540", "port=10930", "ip=192.168.1.23"])


# =============================================================================================
# End to end: fakedash.py ⇄ phone_smoke.py over TCP on free ports (no PXC ports, no lock needed)
# =============================================================================================


def free_ports(n):
    socks, ports = [], []
    for _ in range(n):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        socks.append(s)
        ports.append(s.getsockname()[1])
    for s in socks:
        s.close()
    return ports


CLIPS = {"cfdl16": "clip_800x384.h264", "cfdl26": "clip_800x944.h264", "mt800": "clip_1280x576.h264"}


@unittest.skipIf(os.environ.get("FAKEDASH_SKIP_E2E"), "FAKEDASH_SKIP_E2E set")
class EndToEndTests(unittest.TestCase):
    def run_pair(self, scenario, dash="cfdl16", seconds=2.5, dash_args=(), bugs=(), phone_args=(), timeout=120):
        clip = os.path.join(HERE, "clips", CLIPS[dash])
        if not os.path.exists(clip):
            self.skipTest("clips not generated")
        probe, ctrl, mctrl, mdata = free_ports(4)
        tmp = tempfile.mkdtemp(prefix="fakedash-e2e-")
        if not os.environ.get("FAKEDASH_KEEP"):
            self.addCleanup(shutil.rmtree, tmp, True)
        summary = os.path.join(tmp, "summary.json")
        transcript = os.path.join(tmp, "transcript.jsonl")
        dash_cmd = [sys.executable, os.path.join(HERE, "fakedash.py"), "--scenario", scenario, "--dash", dash,
                    "--bind", "127.0.0.1", "--probe-port", str(probe), "--phone-ports", "%d,%d,%d" % (ctrl, mctrl, mdata),
                    "--seconds", str(seconds), "--summary-json", summary, "--transcript", transcript,
                    "--probe-wait", "40", "--max-runtime", str(timeout - 10), "-q"] + list(dash_args)
        phone_cmd = [sys.executable, os.path.join(HERE, "phone_smoke.py"), "--dash", "127.0.0.1", "--probe-port", str(probe),
                     "--bind", "127.0.0.1", "--ports", "%d,%d,%d" % (ctrl, mctrl, mdata), "--clip", clip,
                     "--duration", str(timeout), "-q"] + list(phone_args)
        for b in bugs:
            phone_cmd += ["--bug", b]
        with open(os.path.join(tmp, "dash.log"), "w") as dlog, open(os.path.join(tmp, "phone.log"), "w") as plog:
            dproc = subprocess.Popen(dash_cmd, stdout=dlog, stderr=subprocess.STDOUT)
            time.sleep(0.4)
            pproc = subprocess.Popen(phone_cmd, stdout=plog, stderr=subprocess.STDOUT)
            try:
                dproc.wait(timeout=timeout)
            finally:
                for p in (dproc, pproc):
                    if p.poll() is None:
                        p.terminate()
                        try:
                            p.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            p.kill()
        self.assertTrue(os.path.exists(summary), "no summary; see %s" % tmp)
        with open(summary) as f:
            s = json.load(f)
        s["_tmp"] = tmp
        s["_transcript"] = transcript
        return s

    def violations(self, s):
        return sorted(set(i["rule"] for i in s["findings"] if i["severity"] == "violation"))

    def assert_clean(self, s):
        bad = [i for i in s["findings"] if i["severity"] in ("violation", "warning")]
        self.assertEqual(bad, [], "findings in %s" % s["_tmp"])
        self.assertEqual(s["result"], "PASS")

    def test_cfdl16_clean_and_transcript(self):
        s = self.run_pair("cfdl16", "cfdl16", seconds=3, dash_args=["--decode"])
        self.assert_clean(s)
        ss = s["sessions"][0]
        self.assertEqual(ss["canvas"], "800x384")
        self.assertGreaterEqual(ss["frames"], 50)
        self.assertTrue(s["decode"]["decodable"])
        self.assertEqual((s["decode"]["width"], s["decode"]["height"]), (800, 384))
        self.assertEqual(s["identity"]["supportFunction"], 0)
        keys = {"t", "conn", "dir", "kind", "cmd", "len", "payload_hex", "payload_text", "note"}
        conns = set()
        with open(s["_transcript"]) as f:
            lines = [json.loads(l) for l in f]
        for o in lines:
            if o.get("kind") in ("cmdbase", "reqbase", "raw"):
                self.assertTrue(keys <= set(o), o)
                conns.add(o["conn"])
        self.assertEqual(conns, {"probe", "ctrl1", "ctrl2", "mctrl", "mdata"})
        self.assertEqual(lines[-1]["kind"], "summary")
        probe = [o for o in lines if o.get("conn") == "probe" and o.get("dir") == "phone->dash"][0]
        self.assertEqual(probe["payload_text"], fd.PROBE_PAYLOAD.decode())

    def test_cfdl26_burst_clean(self):
        s = self.run_pair("cfdl26", "cfdl26", seconds=7)
        self.assert_clean(s)
        ss = s["sessions"][0]
        self.assertEqual(ss["canvas"], "800x944")
        self.assertEqual(s["identity"]["supportFunction"], 128)
        self.assertIn("epoch→phone", ss["clock_replies"])
        for cmd in ("0x10781", "0x103a1", "0x10021", "0x10041", "0x10601", "0x10751", "0x10431", "0x10451", "0x10461"):
            self.assertTrue(any(k.startswith("ctrl2 phone->dash %s " % cmd) for k in s["counts"]), cmd)

    def test_touch_mt800(self):
        s = self.run_pair("touch", "mt800", seconds=6)
        self.assert_clean(s)
        self.assertEqual(s["sessions"][0]["canvas"], "1280x576")
        self.assertGreaterEqual(s["sessions"][0]["touch_frames_sent"], 25)
        self.assertTrue(s["identity"]["supportScreenTouch"])
        s = self.run_pair("touch", "mt800", seconds=6, bugs=["touch-reply"])
        self.assertEqual(self.violations(s), ["TOUCH_REPLY"])

    def test_reconnect(self):
        s = self.run_pair("reconnect", "cfdl16", seconds=2, dash_args=["--cycles", "2"])
        self.assert_clean(s)
        self.assertEqual(len(s["sessions"]), 2)
        self.assertTrue(all(ss["end_reason"] == "completed" for ss in s["sessions"]))
        self.assertGreater(s["probes"][1]["after_previous_session_s"], 0.9)    # backoff 1000 ms

    def test_stall_watchdog(self):
        s = self.run_pair("stall", "cfdl16", seconds=2, dash_args=["--stall-seconds", "11"],
                          phone_args=["--watchdog-tick", "1"])
        self.assert_clean(s)
        st = s["sessions"][0]["stall"]
        self.assertIsNotNone(st["phone_dropped_after_s"])
        self.assertGreater(st["phone_dropped_after_s"], 7.9)
        self.assertEqual(s["sessions"][1]["end_reason"], "completed")

    def test_bug_detection_combined(self):
        bugs = ["key-order", "bad-signature", "sync-true", "token", "repeat-p", "zero-frame", "clock-empty",
                "probe-ios", "unsolicited-10601", "no-sps", "no-slash-escape"]
        s = self.run_pair("cfdl16", "cfdl16", seconds=3, bugs=bugs, dash_args=["--decode"])
        want = {"PROBE_FORMAT", "PROBE_PAYLOAD", "CLIENT_INFO_KEYS", "CLIENT_INFO_SIGNATURE", "CLIENT_INFO_SYNC_TIME",
                "UNSOLICITED_CTRL", "CLOCK_REPLY", "MEDIA_TOKEN", "FRAME_SIZE", "FRAME_IDR_NO_PARAMS", "FRAME_REPEATED_P"}
        self.assertTrue(want <= set(self.violations(s)), self.violations(s))
        warnings = set(i["rule"] for i in s["findings"] if i["severity"] == "warning")
        self.assertIn("CLIENT_INFO_BYTES", warnings)
        self.assertEqual(s["result"], "FAIL")

    def test_bug_detection_stream_level(self):
        for bug, rule in (("p-first", "FRAME_FIRST_NOT_IDR"), ("avcc", "FRAME_ANNEXB"), ("rly17-raw", "MEDIA_RLY17"),
                          ("pkcs1-pubkey", "CLIENT_INFO_PUBKEY")):
            with self.subTest(bug=bug):
                s = self.run_pair("cfdl16", "cfdl16", seconds=1.5, bugs=[bug])
                self.assertIn(rule, self.violations(s))
        s = self.run_pair("cfdl16", "cfdl16", seconds=1.5, bugs=["rly17-raw"])
        self.assertIn("FRAME_SIZE_MISMATCH", self.violations(s))

    def test_bad_magic_and_missing_heartbeat(self):
        s = self.run_pair("cfdl16", "cfdl16", seconds=1.5, bugs=["bad-magic"], dash_args=["--max-sessions", "1"])
        self.assertIn("FRAME_MAGIC", self.violations(s))
        s = self.run_pair("cfdl16", "cfdl16", seconds=5, bugs=["no-heartbeat"])
        self.assertIn("HEARTBEAT_MISSING", self.violations(s))

    def test_locked_switch_at_an_idr_is_clean(self):
        s = self.run_pair("locked", "cfdl16", seconds=3, phone_args=["--sps-switch-at", "15"])
        self.assert_clean(s)
        ss = s["sessions"][0]
        vs = ss["sps_variants"]
        self.assertEqual(len(vs), 2, vs)
        self.assertEqual(vs[0]["first_frame"], 1)
        self.assertGreaterEqual(vs[1]["first_frame"], 15)
        self.assertEqual(vs[0]["constraints"] ^ vs[1]["constraints"], 0x20)
        self.assertEqual(vs[0]["frames"] + vs[1]["frames"], ss["frames"])
        self.assertEqual((vs[1]["width"], vs[1]["height"]), (800, 384))

    def test_locked_without_a_switch_is_a_violation(self):
        s = self.run_pair("locked", "cfdl16", seconds=1.5)
        self.assertEqual(self.violations(s), ["LOCKED_NO_SWITCH"])
        self.assertEqual(len(s["sessions"][0]["sps_variants"]), 1)
        self.assertEqual(s["result"], "FAIL")
        # The other scenarios record the variants but never require a switch.
        s = self.run_pair("cfdl16", "cfdl16", seconds=1.5)
        self.assert_clean(s)
        self.assertEqual(len(s["sessions"][0]["sps_variants"]), 1)

    def test_locked_switch_on_a_p_frame_is_a_violation(self):
        s = self.run_pair("locked", "cfdl16", seconds=2.5, phone_args=["--sps-switch-at", "15"], bugs=["sps-on-p"])
        self.assertIn("SWITCH_NOT_AT_IDR", self.violations(s))
        self.assertNotIn("LOCKED_NO_SWITCH", self.violations(s))
        # Not a locked run: the same stream is no violation of that rule.
        s = self.run_pair("cfdl16", "cfdl16", seconds=2.5, phone_args=["--sps-switch-at", "15"], bugs=["sps-on-p"])
        self.assertNotIn("SWITCH_NOT_AT_IDR", self.violations(s))

    def test_locked_decodes_strictly_and_writes_the_headers(self):
        if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
            self.skipTest("ffmpeg not installed")
        headers = os.path.join(tempfile.mkdtemp(prefix="fakedash-headers-"), "frames", "headers.txt")
        self.addCleanup(shutil.rmtree, os.path.dirname(os.path.dirname(headers)), True)
        s = self.run_pair("locked", "cfdl16", seconds=3, phone_args=["--sps-switch-at", "15"],
                          dash_args=["--decode", "--trace-headers", headers])
        self.assert_clean(s)
        d = s["decode"]
        self.assertTrue(d["strict"])
        self.assertTrue(d["decodable"], d)
        self.assertTrue(d["lenient_decodable"], d)
        with open(headers) as f:
            text = f.read()
        self.assertIn("Parameter Set", text)

    def test_burst_unacked_stalls_like_a_cfdl26(self):
        s = self.run_pair("cfdl26", "cfdl26", seconds=1, bugs=["no-burst-ack"],
                          dash_args=["--max-sessions", "1", "--reply-timeout", "1"])
        self.assertIn("REPLY_TIMEOUT", self.violations(s))
        self.assertIn("dash timeout", s["sessions"][0]["end_reason"])
        self.assertNotIn("canvas", s["sessions"][0])           # media never opened


if __name__ == "__main__":
    unittest.main(verbosity=2)
