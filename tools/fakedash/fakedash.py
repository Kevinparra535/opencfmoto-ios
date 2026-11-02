#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""fakedash: an independent PXC dash simulator (Carbit / EasyConnect, CFMoto MotoPlay family).

It plays the DASH side of the reverse-engineered PXC protocol over real TCP sockets, so a phone
implementation (the iOS EasyConnLink, the Android EasyConnProber, or the real iPhone app on the
same Wi-Fi) can be exercised without a motorcycle:

  * listens for the phone probe on :10930 (CmdBaseHead 0x70000010), validates it byte by byte,
    answers 0x70000011 {"status":true} and closes the probe socket;
  * connects BACK to the probe's source IP: :10922 twice (CAR_CTRL 0x10000 then CAR_DATA 0x20000),
    then :10921 (media control) and :10920 (media data), and drives the handshake of the selected
    dash family (classic CFDL16, CFDL26 1000 MT-X portrait with the notify burst, 800MT landscape);
  * pulls H.264 access units with REQ_RV_DATA_NEXT (114) at ~20 fps, lock-step like a real dash;
  * VALIDATES everything the phone sends against docs/spec/*.md and reports violations.

Written from docs/spec/control-plane.md, media-video.md, session-network.md and
input-controls.md (section numbers are cited next to each rule). Python 3.8+, standard library
only. See README.md (Spanish first, then English) for usage.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
import collections
import datetime
import hashlib
import json
import os
import queue
import re
import shutil
import signal
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import threading
import time

VERSION = "1.0"

# =============================================================================================
# 1. Ports and command constants (control-plane.md §1, §3; media-video.md §2.1, §4.1)
# =============================================================================================

PROBE_PORT = 10930
PHONE_CTRL_PORT = 10922
PHONE_MCTRL_PORT = 10921
PHONE_MDATA_PORT = 10920

HEARTBEAT = 0x70000000
HEARTBEAT_ACK = 0x70000001
MDNS_RESPOND = 0x70000010
MDNS_RESPOND_ACK = 0x70000011
CAR_CTRL = 0x10000
CAR_DATA = 0x20000
CLIENT_INFO = 0x10010
CLIENT_INFO_RLY = 0x10011
QUERY_SPEED = 0x10690
CHECK_SN = 0x103E0
CHECK_SN_ACK = 0x103E1
CHECK_SN_RESULT = 0x201C0
CHECK_SN_RESULT_ACK = 0x201C1
HU_TIME_SYNC = 0x10600
HU_TIME_SYNC_ACK = 0x10601
HU_QUERY_TIME = 0x10450
HU_QUERY_TIME_ACK = 0x10451
LOG_REPORT = 0x10780
OTA_FTP_INFO = 0x103A0
MEDIA_FEATURE_CFG = 0x10020
NOTIFY_NAVI_ICON = 0x10040
NOTIFY_10750 = 0x10750
NOTIFY_10430 = 0x10430
NOTIFY_BLUETOOTH = 0x10460

CTRL_NAMES = {
    HEARTBEAT: "HEARTBEAT", HEARTBEAT_ACK: "HEARTBEAT_ACK",
    MDNS_RESPOND: "MDNS_RESPOND(probe)", MDNS_RESPOND_ACK: "MDNS_RESPOND_ACK",
    CAR_CTRL: "CHANNEL_CAR_CTRL", CAR_CTRL + 1: "CAR_CTRL_ACK",
    CAR_DATA: "CHANNEL_CAR_DATA", CAR_DATA + 1: "CAR_DATA_ACK",
    CLIENT_INFO: "CLIENT_INFO", CLIENT_INFO_RLY: "CLIENT_INFO_RLY",
    QUERY_SPEED: "QUERY_SPEED", QUERY_SPEED + 1: "QUERY_SPEED_RLY",
    CHECK_SN: "CHECK_SN", CHECK_SN_ACK: "CHECK_SN_ACK",
    CHECK_SN_RESULT: "CHECK_SN_RESULT", CHECK_SN_RESULT_ACK: "CHECK_SN_RESULT_ACK",
    HU_TIME_SYNC: "HU_TIME_SYNC", HU_TIME_SYNC_ACK: "HU_TIME_SYNC_ACK",
    HU_QUERY_TIME: "HU_QUERY_TIME", HU_QUERY_TIME_ACK: "HU_QUERY_TIME_ACK",
    LOG_REPORT: "LOG_REPORT", LOG_REPORT + 1: "LOG_REPORT_ACK",
    OTA_FTP_INFO: "OTA_FTP_INFO", OTA_FTP_INFO + 1: "OTA_FTP_INFO_ACK",
    MEDIA_FEATURE_CFG: "MEDIA_FEATURE_CFG", MEDIA_FEATURE_CFG + 1: "MEDIA_FEATURE_CFG_ACK",
    NOTIFY_NAVI_ICON: "NOTIFY_0x10040(maxNaviIcon)", NOTIFY_NAVI_ICON + 1: "ACK_0x10041",
    NOTIFY_10750: "NOTIFY_0x10750", NOTIFY_10750 + 1: "ACK_0x10751",
    NOTIFY_10430: "NOTIFY_0x10430", NOTIFY_10430 + 1: "ACK_0x10431",
    NOTIFY_BLUETOOTH: "NOTIFY_0x10460(bluetooth)", NOTIFY_BLUETOOTH + 1: "ACK_0x10461",
    0x104A0: "SOCK_SERVER_INFO", 0x10470: "VOICE_GRAMMAR", 0x30040: "SCREEN_TOUCH(R2A)",
}

# Media plane ReqBase cmdTypes (media-video.md §4.1).
M_CONFIG_CAPTURE = 16
M_TOUCH = 32
M_GET_VERSION = 48
M_HEARTBEAT = 64
M_CONFIG_EXTEND = 96
M_DATA_START = 112
M_DATA_NEXT = 114
M_START_H264 = 128

MEDIA_NAMES = {
    16: "REQ_RV_CONFIG_CAPTURE", 17: "RLY_RV_CONFIG_CAPTURE", 32: "TOUCH", 33: "TOUCH_REPLY(!)",
    48: "REQ_GET_VERSION", 49: "RLY_GET_VERSION", 64: "REQ_HEARTBEAT", 65: "RLY_HEARTBEAT",
    96: "REQ_CONFIGCAPTUREREXTEND", 97: "RLY_CONFIGCAPTUREREXTEND", 112: "REQ_RV_DATA_START",
    113: "RLY_RV_DATA_START", 114: "REQ_RV_DATA_NEXT", 128: "REQ_START_H264", 129: "RLY_START_H264",
}

PROBE_PAYLOAD = b'{"phoneType":"Android","packageName":"com.cfmoto.cfmotointernational"}'
PROBE_ACK_PAYLOAD = b'{"status":true}'
PROBE_REJECT_PAYLOAD = b'{"status":false}'
SPOOFED_PACKAGE = "com.cfmoto.cfmotointernational"

MAX_CTRL_PAYLOAD = 1 << 20      # control-plane.md §18.2 (Android has no cap; we never expect > 2 KB)
MAX_FRAME_BYTES = 16 << 20      # sanity cap for one access unit

P2D = "phone->dash"
D2P = "dash->phone"

# =============================================================================================
# 2. Framing codecs
# =============================================================================================


def _u32(x):
    return x & 0xFFFFFFFF


def _s32(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x & 0x80000000 else x


def encode_cmdbase(cmd, payload=b"", total_len=None, magic=None, reserved=0):
    """CmdBaseHead frame (control-plane.md §2): cmd, totalLen=16+n, magic=cmd^totalLen, 0, payload."""
    payload = bytes(payload)
    total = 16 + len(payload) if total_len is None else total_len
    if magic is None:
        magic = _u32(cmd) ^ _u32(total)
    return struct.pack("<IIII", _u32(cmd), _u32(total), _u32(magic), _u32(reserved)) + payload


class CmdBaseHeader(object):
    """Decoded 16-byte CmdBaseHead (all int32 little-endian)."""

    __slots__ = ("cmd", "total_len", "magic", "reserved", "raw")

    def __init__(self, raw16):
        if len(raw16) != 16:
            raise ValueError("CmdBaseHead needs 16 bytes")
        cmd, total, magic, reserved = struct.unpack("<IIII", raw16)
        self.cmd = cmd
        self.total_len = _s32(total)
        self.magic = magic
        self.reserved = reserved
        self.raw = bytes(raw16)

    @property
    def expected_magic(self):
        return self.cmd ^ _u32(self.total_len)

    @property
    def magic_ok(self):
        return self.expected_magic == self.magic

    @property
    def payload_len(self):
        # Android parity: max(totalLen - 16, 0) (control-plane.md §2.2 step 4).
        return max(self.total_len - 16, 0)


def decode_cmdbase(buf):
    """Decodes one whole frame from bytes: returns (header, payload, rest). Raises on bad magic."""
    hdr = CmdBaseHeader(buf[:16])
    if not hdr.magic_ok:
        raise ValueError("bad magic: cmd=0x%x len=%d magic=0x%x" % (hdr.cmd, hdr.total_len, hdr.magic))
    n = hdr.payload_len
    if len(buf) < 16 + n:
        raise ValueError("short payload, expected=%d" % n)
    return hdr, bytes(buf[16:16 + n]), bytes(buf[16 + n:])


def encode_reqbase(cmd_type, body=b"", token=0):
    """ReqBase frame (media-video.md §3): cmdType i16 | cmdLen u16 | token i32 | body."""
    body = bytes(body)
    return struct.pack("<hHi", cmd_type, len(body), token) + body


def parse_reqbase_header(raw8):
    return struct.unpack("<hHi", raw8)


def encode_raw_frame(au):
    """One pulled frame on :10920 (media-video.md §5.1): [size i32 LE][Annex-B access unit]."""
    return struct.pack("<i", len(au)) + bytes(au)


# Exact expected media replies (media-video.md §14.2; token always 0).
RLY49 = encode_reqbase(49, struct.pack("<ii", 3, 1))
RLY65 = encode_reqbase(65)
RLY97 = encode_reqbase(97, b'{"state":0}')
RLY113 = encode_reqbase(113)
RLY129 = encode_reqbase(129)


def build_config_capture(width, height, fps=30, encoder=2, touch_mode=0, orientation=0, ext=1,
                         huid_text=b""):
    """REQ_RV_CONFIG_CAPTURE (16) body (media-video.md §4.2): 32-byte fixed part + encryptedHUID."""
    fixed = struct.pack("<HHiiiHHiBBBBBBH", width & 0xFFFF, height & 0xFFFF, fps, encoder, 0, 0, 0, 0,
                        0, touch_mode, orientation, 0, 0, ext, 0)
    assert len(fixed) == 32
    return fixed + bytes(huid_text)


def expected_rly17(body):
    """RLY 17 the phone must send for a REQ 16 body (media-video.md §4.2, EasyConnProber.kt:733-764)."""
    w = struct.unpack_from("<H", body, 0)[0] if len(body) >= 2 else 0
    h = struct.unpack_from("<H", body, 2)[0] if len(body) >= 4 else 0
    enc = struct.unpack_from("<i", body, 8)[0] if len(body) >= 12 else 2
    ext = body[29] if len(body) >= 30 else 0
    reply = struct.pack("<iHHB", 2 if enc == 0 else enc, (w & 0xFFF0) & 0xFFFF, (h & 0xFFF0) & 0xFFFF, ext)
    return encode_reqbase(17, reply, 0)


def build_touch_body(action, x, y, pointer, timestamp):
    """cmd 32 body (input-controls.md §2.2): action u16, x u16, y u16, pointerId u16, ts u32, 6 B."""
    return struct.pack("<HHHHI", action & 0xFFFF, x & 0xFFFF, y & 0xFFFF, pointer & 0xFFFF,
                       timestamp & 0xFFFFFFFF) + b"\x00" * 6


TOUCH_ACTIONS = {2: "DOWN", 3: "MOVE", 1: "UP"}

# =============================================================================================
# 3. JSON helpers (Android org.json byte format, ordered parsing)
# =============================================================================================


class JsonObject(list):
    """An ordered JSON object: a list of (key, value) pairs (keeps order and duplicates)."""

    def get(self, key, default=None):
        for k, v in self:
            if k == key:
                return v
        return default

    def keys(self):
        return [k for k, _ in self]


def parse_json_ordered(text):
    return json.loads(text, object_pairs_hook=JsonObject)


def android_json_string(s):
    """AOSP org.json JSONStringer.string(): escapes " \\ / and control chars (\\/ for slashes)."""
    out = ['"']
    for ch in s:
        if ch in '"\\/':
            out.append("\\" + ch)
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\b":
            out.append("\\b")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\f":
            out.append("\\f")
        elif ord(ch) <= 0x1F:
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def android_json(pairs):
    """Serializes ordered pairs exactly like Android's JSONObject.toString() (no whitespace)."""
    parts = []
    for k, v in pairs:
        parts.append(android_json_string(k) + ":" + _android_json_value(v))
    return "{" + ",".join(parts) + "}"


def _android_json_value(v):
    if v is True:
        return "true"
    if v is False:
        return "false"
    if v is None:
        return "null"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        return android_json_string(v)
    if isinstance(v, JsonObject) or (isinstance(v, list) and all(isinstance(p, tuple) for p in v)):
        return android_json(v)
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(_android_json_value(x) for x in v) + "]"
    if isinstance(v, dict):
        return android_json(list(v.items()))
    raise TypeError("unsupported JSON value %r" % (v,))


def printable_text(payload):
    """UTF-8 text of a payload if it is printable (for transcripts), else None."""
    if not payload:
        return ""
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        return None
    for ch in text:
        if not (ch.isprintable() or ch in "\t\r\n"):
            return None
    return text


# =============================================================================================
# 4. RSA identity checks (control-plane.md §9)
# =============================================================================================

SPKI_RSA1024_PREFIX = bytes.fromhex("30819f300d06092a864886f70d010101050003818d00")
RSA_OID = bytes.fromhex("2a864886f70d010101")


def der_next(buf, pos):
    """Reads one DER TLV at pos: returns (tag, value_bytes, next_pos)."""
    if pos + 2 > len(buf):
        raise ValueError("DER truncated")
    tag = buf[pos]
    length = buf[pos + 1]
    pos += 2
    if length & 0x80:
        nb = length & 0x7F
        if nb == 0 or nb > 4 or pos + nb > len(buf):
            raise ValueError("DER bad length")
        length = int.from_bytes(buf[pos:pos + nb], "big")
        pos += nb
    if pos + length > len(buf):
        raise ValueError("DER length overflow")
    return tag, bytes(buf[pos:pos + length]), pos + length


def parse_rsa_public_pkcs1(der):
    tag, seq, end = der_next(der, 0)
    if tag != 0x30 or end != len(der):
        raise ValueError("RSAPublicKey is not one SEQUENCE")
    t1, n_bytes, p = der_next(seq, 0)
    t2, e_bytes, p = der_next(seq, p)
    if t1 != 0x02 or t2 != 0x02 or p != len(seq):
        raise ValueError("RSAPublicKey must be SEQUENCE { INTEGER n, INTEGER e }")
    return int.from_bytes(n_bytes, "big"), int.from_bytes(e_bytes, "big")


def parse_spki_rsa(der):
    """X.509 SubjectPublicKeyInfo (rsaEncryption) → (n, e)."""
    tag, seq, end = der_next(der, 0)
    if tag != 0x30 or end != len(der):
        raise ValueError("SPKI is not one SEQUENCE")
    tag, algo, p = der_next(seq, 0)
    if tag != 0x30:
        raise ValueError("SPKI algorithm is not a SEQUENCE")
    t_oid, oid, q = der_next(algo, 0)
    if t_oid != 0x06 or oid != RSA_OID:
        raise ValueError("SPKI algorithm is not rsaEncryption")
    tag, bits, p = der_next(seq, p)
    if tag != 0x03 or not bits or bits[0] != 0 or p != len(seq):
        raise ValueError("SPKI subjectPublicKey is not a BIT STRING")
    return parse_rsa_public_pkcs1(bits[1:])


def parse_rsa_private_pkcs1(der):
    """PKCS#1 RSAPrivateKey → (n, e, d)."""
    tag, seq, end = der_next(der, 0)
    if tag != 0x30:
        raise ValueError("RSAPrivateKey is not a SEQUENCE")
    vals = []
    p = 0
    while p < len(seq) and len(vals) < 9:
        t, v, p = der_next(seq, p)
        if t != 0x02:
            raise ValueError("RSAPrivateKey field is not an INTEGER")
        vals.append(int.from_bytes(v, "big"))
    if len(vals) < 4:
        raise ValueError("RSAPrivateKey too short")
    return vals[1], vals[2], vals[3]


def pkcs1_v15_type1(message, k):
    """EM = 00 01 FF..FF 00 || message (PKCS#1 v1.5 block type 1, no DigestInfo)."""
    if len(message) > k - 11:
        raise ValueError("message too long for PKCS#1 v1.5")
    return b"\x00\x01" + b"\xff" * (k - 3 - len(message)) + b"\x00" + bytes(message)


def modexp(base, exponent, modulus):
    """base^exponent mod modulus by left-to-right binary square-and-multiply (own implementation,
    cross-checked against the built-in pow() in test_fakedash.py)."""
    if modulus == 1:
        return 0
    result = 1
    base %= modulus
    for bit in bin(exponent)[2:]:
        result = (result * result) % modulus
        if bit == "1":
            result = (result * base) % modulus
    return result


def rsa_sign_type1(message, n, d):
    k = (n.bit_length() + 7) // 8
    m = int.from_bytes(pkcs1_v15_type1(message, k), "big")
    return modexp(m, d, n).to_bytes(k, "big")


def rsa_public_op(signature, n, e):
    """RSAVP1: s^e mod n, as k bytes (k = modulus length)."""
    k = (n.bit_length() + 7) // 8
    s = int.from_bytes(signature, "big")
    if s >= n:
        raise ValueError("signature representative out of range (s >= n)")
    return modexp(s, e, n).to_bytes(k, "big")


def check_pubkey_b64(value):
    """Validates the CLIENT_INFO `pubkey`. Returns (n, e, findings) with findings [(sev, rule, msg)]."""
    findings = []
    if not isinstance(value, str):
        return None, None, [("violation", "CLIENT_INFO_PUBKEY", "pubkey is not a string: %r" % (value,))]
    if re.search(r"\s", value):
        findings.append(("violation", "CLIENT_INFO_PUBKEY", "pubkey base64 contains whitespace/line breaks (must be NO_WRAP)"))
    try:
        der = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as e:
        return None, None, findings + [("violation", "CLIENT_INFO_PUBKEY", "pubkey is not strict standard base64: %s" % e)]
    if len(value) != 216:
        findings.append(("violation", "CLIENT_INFO_PUBKEY", "pubkey is %d base64 chars (RSA-1024 SPKI is 216)" % len(value)))
    if der[:22] != SPKI_RSA1024_PREFIX:
        findings.append(("violation", "CLIENT_INFO_PUBKEY",
                         "pubkey DER does not start with the fixed 22-byte RSA-1024 SPKI prefix (got %s; PKCS#1 instead of SPKI?)" % der[:22].hex()))
    try:
        n, e = parse_spki_rsa(der)
    except ValueError as ex:
        return None, None, findings + [("violation", "CLIENT_INFO_PUBKEY", "pubkey is not an RSA SubjectPublicKeyInfo: %s" % ex)]
    if n.bit_length() != 1024:
        findings.append(("violation", "CLIENT_INFO_PUBKEY", "RSA modulus is %d bits (spec: 1024)" % n.bit_length()))
    if e != 65537:
        findings.append(("warning", "CLIENT_INFO_PUBKEY", "RSA public exponent is %d (Android default 65537)" % e))
    return n, e, findings


def check_encrypted_huid(value, n, e, huid):
    """Verifies `encryptedHUID` = PKCS#1 v1.5 type-1 private-key op of the HUID (control-plane.md §9.2)."""
    if not huid:
        if value != "":
            return [("violation", "CLIENT_INFO_SIGNATURE", "dash sent no HUID, so encryptedHUID must be \"\" (got %r)" % (value,))]
        return []
    if not isinstance(value, str):
        return [("violation", "CLIENT_INFO_SIGNATURE", "encryptedHUID is not a string")]
    findings = []
    if len(value) != 172:
        findings.append(("violation", "CLIENT_INFO_SIGNATURE", "encryptedHUID is %d base64 chars (RSA-1024 is 172)" % len(value)))
    try:
        sig = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as ex:
        return findings + [("violation", "CLIENT_INFO_SIGNATURE", "encryptedHUID is not strict base64: %s" % ex)]
    if n is None:
        return findings + [("violation", "CLIENT_INFO_SIGNATURE", "cannot verify encryptedHUID: pubkey unusable")]
    k = (n.bit_length() + 7) // 8
    if len(sig) != k:
        return findings + [("violation", "CLIENT_INFO_SIGNATURE", "encryptedHUID is %d bytes (modulus is %d)" % (len(sig), k))]
    try:
        em = rsa_public_op(sig, n, e)
    except ValueError as ex:
        return findings + [("violation", "CLIENT_INFO_SIGNATURE", str(ex))]
    expected = pkcs1_v15_type1(huid.encode("utf-8"), k)
    if em != expected:
        hint = ""
        if em[:2] == b"\x00\x02":
            hint = " (block type 2 = public-key ENCRYPTION, not the private-key signature)"
        elif em[:2] == b"\x00\x01":
            sep = em.find(b"\x00", 2)
            hint = " (type-1 padding but recovered message %r)" % (em[sep + 1:] if sep > 0 else b"?",)
        findings.append(("violation", "CLIENT_INFO_SIGNATURE",
                         "encryptedHUID does not verify with pubkey as PKCS#1 v1.5 type-1 of HUID %r; recovered EM starts %s%s"
                         % (huid, em[:4].hex(), hint)))
    return findings


# =============================================================================================
# 5. H.264 Annex-B analysis (media-video.md §5-§7)
# =============================================================================================

NAL_NAMES = {1: "P/B slice", 5: "IDR", 6: "SEI", 7: "SPS", 8: "PPS", 9: "AUD", 12: "filler"}
_HIGH_PROFILES = {100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135}


def find_start_codes(data):
    """[(start_code_offset, nal_offset)] for every 00 00 01 / 00 00 00 01 start code."""
    res = []
    i = 0
    while True:
        p = data.find(b"\x00\x00\x01", i)
        if p < 0:
            break
        sc = p - 1 if p > 0 and data[p - 1] == 0 else p
        res.append((sc, p + 3))
        i = p + 3
    return res


def split_nals(data):
    """NAL unit payloads (header byte first) of an Annex-B buffer."""
    scs = find_start_codes(data)
    out = []
    for k, (_, start) in enumerate(scs):
        end = scs[k + 1][0] if k + 1 < len(scs) else len(data)
        out.append(bytes(data[start:end]))
    return out


def rbsp_unescape(data):
    out = bytearray()
    zeros = 0
    for b in data:
        if zeros >= 2 and b == 3:
            zeros = 0
            continue
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


class BitReader(object):
    def __init__(self, data):
        self.data = data
        self.pos = 0
        self.nbits = len(data) * 8

    def u(self, n):
        v = 0
        for _ in range(n):
            if self.pos >= self.nbits:
                raise ValueError("bitstream exhausted")
            v = (v << 1) | ((self.data[self.pos >> 3] >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return v

    def ue(self):
        zeros = 0
        while self.u(1) == 0:
            zeros += 1
            if zeros > 31:
                raise ValueError("bad exp-Golomb code")
        return (1 << zeros) - 1 + (self.u(zeros) if zeros else 0)

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k & 1 else -(k // 2)


def _skip_scaling_list(br, size):
    last = nxt = 8
    for _ in range(size):
        if nxt != 0:
            nxt = (last + br.se() + 256) % 256
        last = last if nxt == 0 else nxt


def _skip_hrd(br):
    cnt = br.ue() + 1
    br.u(4)
    br.u(4)
    for _ in range(cnt):
        br.ue()
        br.ue()
        br.u(1)
    br.u(20)


def parse_sps(nal):
    """Parses an SPS NAL (header byte included). Returns a dict, or None if it is not parseable."""
    try:
        if len(nal) < 4 or (nal[0] & 0x1F) != 7:
            return None
        br = BitReader(rbsp_unescape(nal[1:]))
        profile = br.u(8)
        constraints = br.u(8)
        level = br.u(8)
        sps_id = br.ue()
        chroma = 1
        if profile in _HIGH_PROFILES:
            chroma = br.ue()
            if chroma == 3:
                br.u(1)
            br.ue()
            br.ue()
            br.u(1)
            if br.u(1):
                for i in range(8 if chroma != 3 else 12):
                    if br.u(1):
                        _skip_scaling_list(br, 16 if i < 6 else 64)
        log2_max_frame_num = br.ue() + 4
        poc_type = br.ue()
        if poc_type == 0:
            br.ue()
        elif poc_type == 1:
            br.u(1)
            br.se()
            br.se()
            for _ in range(br.ue()):
                br.se()
        max_ref = br.ue()
        br.u(1)
        w_mbs = br.ue() + 1
        h_units = br.ue() + 1
        frame_mbs_only = br.u(1)
        if not frame_mbs_only:
            br.u(1)
        br.u(1)
        crop = br.u(1)
        cl = cr = ct = cb = 0
        if crop:
            cl, cr, ct, cb = br.ue(), br.ue(), br.ue(), br.ue()
        if chroma == 0:
            cux, cuy = 1, 2 - frame_mbs_only
        else:
            cux = 2 if chroma in (1, 2) else 1
            cuy = (2 if chroma == 1 else 1) * (2 - frame_mbs_only)
        info = {
            "profile_idc": profile, "constraint_flags": constraints, "level_idc": level, "sps_id": sps_id,
            "chroma_format_idc": chroma, "log2_max_frame_num": log2_max_frame_num, "poc_type": poc_type,
            "max_num_ref_frames": max_ref, "frame_mbs_only": frame_mbs_only,
            "width": w_mbs * 16 - cux * (cl + cr),
            "height": (2 - frame_mbs_only) * h_units * 16 - cuy * (ct + cb),
            "coded_width": w_mbs * 16, "coded_height": (2 - frame_mbs_only) * h_units * 16,
            "frame_cropping": bool(crop), "vui": False,
        }
        if br.u(1):
            info["vui"] = True
            try:
                if br.u(1):
                    if br.u(8) == 255:
                        br.u(32)
                if br.u(1):
                    br.u(1)
                if br.u(1):
                    br.u(3)
                    info["full_range"] = br.u(1)
                    if br.u(1):
                        br.u(24)
                if br.u(1):
                    br.ue()
                    br.ue()
                if br.u(1):
                    nut = br.u(32)
                    ts = br.u(32)
                    br.u(1)
                    if nut:
                        info["vui_fps"] = round(ts / (2.0 * nut), 3)
                nal_hrd = br.u(1)
                if nal_hrd:
                    _skip_hrd(br)
                vcl_hrd = br.u(1)
                if vcl_hrd:
                    _skip_hrd(br)
                if nal_hrd or vcl_hrd:
                    br.u(1)
                br.u(1)
                if br.u(1):
                    br.u(1)
                    br.ue()
                    br.ue()
                    br.ue()
                    br.ue()
                    info["max_num_reorder_frames"] = br.ue()
                    info["max_dec_frame_buffering"] = br.ue()
            except ValueError:
                info["vui_error"] = True
        return info
    except (ValueError, IndexError):
        return None


def parse_slice_type(nal):
    """slice_type of a slice NAL (0 P, 1 B, 2 I, 3 SP, 4 SI; +5 variants), or None."""
    try:
        br = BitReader(rbsp_unescape(nal[1:16]))
        br.ue()
        return br.ue()
    except (ValueError, IndexError):
        return None


def looks_avcc(au):
    """True if the buffer parses as AVCC (4-byte big-endian NAL lengths) — VideoToolbox output."""
    pos = 0
    count = 0
    while pos + 4 <= len(au):
        ln = int.from_bytes(au[pos:pos + 4], "big")
        if ln == 0 or pos + 4 + ln > len(au):
            return False
        hdr = au[pos + 4]
        if hdr & 0x80 or not (1 <= (hdr & 0x1F) <= 23):
            return False
        pos += 4 + ln
        count += 1
    return pos == len(au) and count > 0


class AuInfo(object):
    """What one access unit contains."""

    def __init__(self):
        self.nal_types = []
        self.leading = 0
        self.vcl = 0
        self.has_idr = False
        self.has_non_idr = False
        self.sps_before_vcl = False
        self.pps_before_vcl = False
        self.pps_before_sps = False
        self.slice_types = []
        self.sps = None
        self.sps_hex = None
        self.pps_hex = None
        self.avcc = False

    @property
    def kind(self):
        if self.has_idr:
            return "IDR"
        if self.vcl:
            return "P"
        return "no-VCL"

    def describe(self):
        return "[" + ",".join(str(t) for t in self.nal_types) + "]"


def analyze_au(au):
    info = AuInfo()
    scs = find_start_codes(au)
    if not scs:
        info.leading = len(au)
        info.avcc = looks_avcc(au)
        return info
    info.leading = scs[0][0]
    if info.leading:
        info.avcc = looks_avcc(au)
    seen_sps = False
    for k, (_, start) in enumerate(scs):
        end = scs[k + 1][0] if k + 1 < len(scs) else len(au)
        nal = au[start:end]
        if not nal:
            continue
        t = nal[0] & 0x1F
        info.nal_types.append(t)
        if 1 <= t <= 5:
            if info.vcl == 0 or len(info.slice_types) < 4:
                st = parse_slice_type(nal)
                if st is not None:
                    info.slice_types.append(st)
            info.vcl += 1
            if t == 5:
                info.has_idr = True
            else:
                info.has_non_idr = True
        elif t == 7 and info.vcl == 0:
            info.sps_before_vcl = True
            seen_sps = True
            if info.sps is None:
                info.sps = parse_sps(nal)
                info.sps_hex = nal[:24].hex()
        elif t == 8 and info.vcl == 0:
            info.pps_before_vcl = True
            if not seen_sps:
                info.pps_before_sps = True
            if info.pps_hex is None:
                info.pps_hex = nal[:24].hex()
    return info


# =============================================================================================
# 6. Dash clock (control-plane.md §13)
# =============================================================================================

_STAMP_RE = re.compile(r"^(\d{4})-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}")
_PHONE_STAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}000000$")


def time_sync_payload(kind, model_id, seq, now=None):
    """A 0x10600 request as a dash sends it (45 bytes: 16-byte LE header + 29 ASCII chars)."""
    now = now or datetime.datetime.now()
    ms = now.microsecond // 1000
    header = struct.pack("<iiii", -2, model_id, seq, 0)
    if kind == "empty":
        return b""
    if kind == "nul":
        return header + b"\x00" * 29
    if kind == "short":
        stamp = now.strftime("%Y-%m-%d %H:%M:%S") + ".%03d" % ms
    elif kind == "tsep":
        stamp = now.strftime("%Y-%m-%dT%H:%M:%S") + ".%03d000000" % ms
    elif kind == "epoch":
        stamp = "1970-01-01 00:00:%02d.000000000" % (seq % 60)
    else:
        stamp = now.strftime("%Y-%m-%d %H:%M:%S") + ".%03d000000" % ms
    return header + stamp.encode("ascii")


def ts_extract_stamp(buf):
    if len(buf) < 16:
        return ""
    n = min(29, len(buf) - 16)
    return bytes(buf[16:16 + n]).decode("ascii", "replace").rstrip("\x00 ")


def ts_should_echo(stamp, request):
    if len(request) < 16:
        return False
    if stamp.strip() == "" or all(c in "\x00 " for c in stamp):
        return False
    m = _STAMP_RE.match(stamp)
    if m and 1969 <= int(m.group(1)) <= 1971:
        return False
    return True


def ts_expected_base(request):
    """The 0x10601 body before any phone stamp is written: request copied into max(45, n) zeros."""
    n = max(45, len(request))
    out = bytearray(n)
    out[:len(request)] = request
    if len(request) < 16:
        out[0:16] = struct.pack("<iiii", -2, 0, 1, 0)
    return bytes(out)


def check_time_sync_reply(request, reply, now=None, tolerance_s=120.0):
    """Validates a 0x10601 body (control-plane.md §13.2). Returns (mode, findings)."""
    findings = []
    base = ts_expected_base(request)
    stamp = ts_extract_stamp(request)
    if ts_should_echo(stamp, request):
        mode = "echo"
        if reply != base:
            if len(reply) != len(base):
                why = "length %d (expected %d)" % (len(reply), len(base))
            else:
                diff = next(i for i in range(len(base)) if base[i] != reply[i])
                why = "first difference at byte %d" % diff
            findings.append(("violation", "CLOCK_REPLY",
                             "0x10601 must echo the request zero-padded to %d bytes (stamp %r); %s; got %s"
                             % (len(base), stamp, why, reply[:48].hex())))
        return mode, findings
    mode = "phone"
    if len(reply) != len(base):
        findings.append(("violation", "CLOCK_REPLY", "0x10601 (phone mode for stamp %r) is %d bytes, expected %d"
                         % (stamp, len(reply), len(base))))
        return mode, findings
    if reply[:16] != base[:16]:
        findings.append(("violation", "CLOCK_REPLY", "0x10601 header bytes 0..15 must be %s, got %s"
                         % (base[:16].hex(), reply[:16].hex())))
    if reply[45:] != base[45:]:
        findings.append(("violation", "CLOCK_REPLY", "0x10601 bytes after 45 must be copied from the request"))
    text = reply[16:45].decode("ascii", "replace")
    if not _PHONE_STAMP_RE.match(text):
        findings.append(("violation", "CLOCK_REPLY",
                         "0x10601 phone stamp %r is not 'yyyy-MM-dd HH:mm:ss.SSS000000' (request stamp %r was epoch/blank)"
                         % (text, stamp)))
    else:
        try:
            phone_t = datetime.datetime.strptime(text[:23], "%Y-%m-%d %H:%M:%S.%f")
            ref = now or datetime.datetime.now()
            if abs((phone_t - ref).total_seconds()) > tolerance_s:
                findings.append(("warning", "CLOCK_REPLY",
                                 "0x10601 phone stamp %s differs from this computer's local time %s by %.0f s (time zone?)"
                                 % (text[:19], ref.strftime("%Y-%m-%d %H:%M:%S"), (phone_t - ref).total_seconds())))
        except ValueError:
            findings.append(("violation", "CLOCK_REPLY", "0x10601 phone stamp %r is not a valid date" % text))
    return mode, findings


# =============================================================================================
# 7. Profile scoring (control-plane.md §12.4) — what the Android app would advertise by default
# =============================================================================================


def _opt_string(info, key):
    v = info.get(key)
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return v
    return json.dumps(v)


def _opt_int(info, key, default=0):
    v = info.get(key)
    if isinstance(v, bool) or v is None:
        return default
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v)
    if isinstance(v, str):
        try:
            return int(float(v.strip()))
        except ValueError:
            return default
    return default


def _opt_bool(info, key):
    v = info.get(key)
    return v is True or (isinstance(v, str) and v.lower() == "true")


def _looks26(info):
    vn = _opt_string(info, "version_name")
    pkg = _opt_string(info, "package_name").lower()
    return vn.startswith("CFDL26") or "cfmoto" in pkg or "cfdash" in pkg


def _score_nk800(i):
    crcp = _opt_string(i, "HUID").startswith("CRCP")
    sdk = _opt_string(i, "sdkVersion").startswith("0.9.23")
    lp = _opt_string(i, "package_name") == "linux_no_package"
    if not crcp and not (sdk and lp):
        return 0
    return 4 * crcp + 3 * sdk + 2 * lp


def _score_nktouch(i):
    s = 0
    if _opt_string(i, "version_name").startswith("CFDL26"):
        s += 4
    if _opt_string(i, "package_name") == "com.cfmoto.easyconnect":
        s += 3
    if _opt_bool(i, "enableSockServerAuth"):
        s += 2
    sdk = _opt_string(i, "sdkVersion")
    if sdk and not sdk.startswith("0."):
        s += 2
    if s > 0 and _opt_int(i, "supportFunction") == 128:
        s += 1
    if _opt_string(i, "HUID").startswith("6KWV"):
        s += 4
    if _opt_bool(i, "supportLandscapeAdaptive"):
        s -= 4
    if _opt_bool(i, "supportMirrorOverlayTouch"):
        s += 1
    if _opt_bool(i, "supportScreenTouch"):
        s += 1
    return s


def _score_morini(i):
    s = 0
    if _opt_string(i, "channel") in ("21333", "21322"):
        s += 12
    if _opt_string(i, "HUID").upper().startswith("CARB"):
        s += 8
    if _opt_int(i, "flavor") == 51:
        s += 6
    if _opt_string(i, "package_name") == "" and s > 0:
        s += 1
    if _opt_string(i, "sdkVersion").startswith("1.0.13"):
        s += 2
    if not _opt_bool(i, "supportScreenTouch"):
        s += 1
    return s


def _score_mp66(i):
    s = 0
    if _opt_string(i, "channel") == "66660742":
        s += 10
    if _opt_string(i, "sdkVersion").startswith("0.9"):
        s += 2
    if _opt_bool(i, "supportLandscapeAdaptive"):
        s += 1
    if not _opt_bool(i, "supportScreenTouch"):
        s += 1
    return s


def _score_clc450(i):
    s = 0
    if _opt_string(i, "channel") == "66660736":
        s += 8
    if "48FB4C" in _opt_string(i, "HUName").upper():
        s += 4
    if _opt_string(i, "sdkVersion").startswith("0.9.23"):
        s += 1
    return s


def _score_landscape(i):
    s = 0
    l26 = _looks26(i)
    if _opt_string(i, "version_name").startswith("CFDL26"):
        s += 4
    sdk = _opt_string(i, "sdkVersion")
    if l26 and sdk and not sdk.startswith("0."):
        s += 2
    if _opt_bool(i, "enableSockServerAuth"):
        s += 2
    if _opt_string(i, "package_name") == "com.cfmoto.easyconnect":
        s += 3
    if s > 0 and _opt_int(i, "supportFunction") == 128:
        s += 1
    if l26 and _opt_bool(i, "supportLandscapeAdaptive"):
        s += 4
    if _opt_string(i, "HUID").startswith("6WWV"):
        s += 3
    if not _opt_bool(i, "supportScreenTouch"):
        s -= 1
    if _opt_string(i, "HUID").upper().startswith("CARB"):
        s = 0
    return s


def _score_portrait(i):
    if _opt_string(i, "HUID").upper().startswith("CARB"):
        return 0
    s = 0
    if _opt_string(i, "version_name").startswith("CFDL26"):
        s += 4
    sdk = _opt_string(i, "sdkVersion")
    if _looks26(i) and sdk and not sdk.startswith("0."):
        s += 2
    if _opt_bool(i, "enableSockServerAuth"):
        s += 2
    if _opt_string(i, "package_name") == "com.cfmoto.cfdashmotoplay":
        s += 3
    if s > 0 and _opt_int(i, "supportFunction") == 128:
        s += 1
    return s


def _score_legacy(i):
    s = 1
    if _opt_string(i, "HUName").startswith("CFDL16"):
        s += 4
    if _opt_string(i, "sdkVersion").startswith("0.9.29"):
        s += 3
    if _opt_string(i, "channel").strip() == "37416":
        s += 2
    return s


# (name, scorer, advertised supportFunction, supportsScreenTouch, reply may add supportScreenTouch)
PROFILE_REGISTRY = [
    ("Nk800", _score_nk800, 128, False, False),
    ("Cfdl26NkTouch", _score_nktouch, 128, True, True),
    ("MoriniMlSoftAp", _score_morini, 128, False, False),
    ("Cfdl16MotoPlayLandscape", _score_mp66, 128, False, False),
    ("ClC450", _score_clc450, 0, False, False),
    ("Cfdl26Landscape", _score_landscape, 128, True, True),
    ("Cfdl26Portrait", _score_portrait, 128, False, True),
    ("LegacyCfdl16", _score_legacy, 0, False, False),
]


def expected_profile(info):
    """Android BikeProfiles.select(json) (no override): returns a dict with name, supportFunction,
    supportScreenTouch (default advertising) and all scores."""
    if not isinstance(info, (dict, JsonObject)):
        info = JsonObject(info)
    scores = [(name, fn(info)) for name, fn, _, _, _ in PROFILE_REGISTRY]
    best = None
    for idx, (name, sc) in enumerate(scores):
        if sc > 0 and (best is None or sc > scores[best][1]):
            best = idx
    if best is None:
        best = len(PROFILE_REGISTRY) - 1
    name, _, sf, touch, can_add = PROFILE_REGISTRY[best]
    return {"name": name, "supportFunction": sf, "supportScreenTouch": bool(touch and can_add),
            "scores": dict(scores)}


# =============================================================================================
# 8. Validators for phone replies
# =============================================================================================

CLIENT_INFO_KEYS = ["pxcVersion", "phoneUUID", "phoneBrand", "phoneModel", "phoneOsVersion", "phoneOs",
                    "package", "versionCode", "token", "pubkey", "encryptedHUID", "bluetoothName",
                    "supportH264IFrame", "supportFunction", "supportSyncCorrectTime", "appVersionFingerPrint"]
_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def validate_probe(header, payload):
    """Byte-exact probe check (control-plane.md §2.3, §4.1). Returns findings."""
    f = []
    if header.cmd != MDNS_RESPOND:
        f.append(("violation", "PROBE_FORMAT", "probe cmd is 0x%x, expected 0x70000010" % header.cmd))
    if not header.magic_ok:
        f.append(("violation", "PROBE_FORMAT", "probe magic 0x%x != cmd^totalLen 0x%x" % (header.magic, header.expected_magic)))
    if header.total_len != 16 + len(payload) or header.total_len != 86:
        f.append(("violation", "PROBE_FORMAT", "probe totalLen %d (expected 86 = 16 + 70)" % header.total_len))
    if header.reserved != 0:
        f.append(("violation", "PROBE_FORMAT", "probe reserved bytes 12..15 are 0x%08x (must be 0)" % header.reserved))
    if payload != PROBE_PAYLOAD:
        f.append(("violation", "PROBE_PAYLOAD", "probe payload must be exactly %s, got %r"
                  % (PROBE_PAYLOAD.decode(), payload[:200])))
    return f


def validate_client_info_reply(payload, dash_info, expected=None):
    """Checks the phone's 0x10011 body against control-plane.md §8. Returns (parsed_pairs, findings)."""
    f = []
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        return None, [("violation", "CLIENT_INFO_JSON", "CLIENT_INFO reply is not UTF-8")]
    try:
        obj = parse_json_ordered(text)
    except ValueError as e:
        return None, [("violation", "CLIENT_INFO_JSON", "CLIENT_INFO reply is not JSON: %s" % e)]
    if not isinstance(obj, JsonObject):
        return None, [("violation", "CLIENT_INFO_JSON", "CLIENT_INFO reply is not a JSON object")]
    keys = obj.keys()
    dups = sorted(set(k for k in keys if keys.count(k) > 1))
    if dups:
        f.append(("violation", "CLIENT_INFO_KEYS", "duplicate keys %s" % dups))
    exp = list(CLIENT_INFO_KEYS)
    if keys != exp and keys != exp + ["supportScreenTouch"]:
        missing = [k for k in exp if k not in keys]
        extra = [k for k in keys if k not in exp and k != "supportScreenTouch"]
        detail = []
        if missing:
            detail.append("missing %s" % missing)
        if extra:
            detail.append("unexpected %s" % extra)
        if not missing and not extra:
            detail.append("wrong ORDER (if this is Android code run on a desktop JVM: JSON-java's JSONObject is a "
                          "HashMap and loses insertion order, Android's AOSP org.json keeps it — harness artifact)")
        f.append(("violation", "CLIENT_INFO_KEYS", "CLIENT_INFO reply keys %s; expected order %s[, supportScreenTouch]; got %s"
                  % ("; ".join(detail), exp, keys)))
    v = obj.get

    def need(key, cond, msg, sev="violation", rule="CLIENT_INFO_VALUE"):
        if key in keys and not cond(v(key)):
            f.append((sev, rule, "%s: %s (got %r)" % (key, msg, v(key))))

    need("pxcVersion", lambda x: x == "1.0.2", 'must be "1.0.2"')
    need("phoneUUID", lambda x: isinstance(x, str), "must be a string")
    need("phoneUUID", lambda x: isinstance(x, str) and bool(_UUID_RE.match(x)),
         "should be a lowercase 36-char UUID like Android's UUID.randomUUID()", "warning")
    need("phoneUUID", lambda x: not (isinstance(x, str) and _UUID_RE.match(x)) or x[14] == "4",
         "should be a random (version 4) UUID", "warning")
    need("phoneBrand", lambda x: isinstance(x, str) and x != "", "must be a non-empty string")
    need("phoneModel", lambda x: isinstance(x, str) and x != "", "must be a non-empty string")
    need("phoneOsVersion", lambda x: isinstance(x, str), "must be a JSON STRING (Android sends the API level as text)")
    need("phoneOsVersion", lambda x: not isinstance(x, str) or x.isdigit(),
         'should be an Android-API-like string such as "35" (§18.7)', "warning")
    need("phoneOs", lambda x: x == "Android", 'must be "Android" (spoof, §18.7)')
    need("package", lambda x: x == SPOOFED_PACKAGE, 'must be "%s"' % SPOOFED_PACKAGE)
    need("versionCode", lambda x: _is_int(x) and x == 126, "must be the integer 126")
    need("token", lambda x: _is_int(x) and x == 0, "must be the integer 0")
    need("bluetoothName", lambda x: x == "OpenCfMoto", 'must be "OpenCfMoto"')
    need("supportH264IFrame", lambda x: x is True, "must be true")
    need("supportFunction", lambda x: _is_int(x) and x in (0, 128), "must be the integer 0 or 128")
    need("supportSyncCorrectTime", lambda x: x is False,
         "must be false (true made Zontes/Voge clocks go to 00:00, §13.3)", "violation", "CLIENT_INFO_SYNC_TIME")
    need("appVersionFingerPrint", lambda x: x == "opencfmoto-poc", 'must be "opencfmoto-poc"')
    if "supportScreenTouch" in keys and v("supportScreenTouch") is not True:
        f.append(("violation", "CLIENT_INFO_VALUE", "supportScreenTouch is present but not true (%r); the key must be absent instead"
                  % (v("supportScreenTouch"),)))
    huid = _opt_string(dash_info, "HUID") or _opt_string(dash_info, "huid")
    n = e = None
    if "pubkey" in keys:
        n, e, pf = check_pubkey_b64(v("pubkey"))
        f.extend(pf)
    if "encryptedHUID" in keys:
        f.extend(check_encrypted_huid(v("encryptedHUID"), n, e, huid))
    exp_prof = expected or expected_profile(dash_info)
    sf = v("supportFunction")
    if _is_int(sf) and sf != exp_prof["supportFunction"]:
        f.append(("warning", "CLIENT_INFO_PROFILE",
                  "supportFunction %d but Android's default profile for this CLIENT_INFO is %s (supportFunction %d); "
                  "profile override / QR guess?" % (sf, exp_prof["name"], exp_prof["supportFunction"])))
    has_touch = "supportScreenTouch" in keys
    if has_touch != exp_prof["supportScreenTouch"]:
        f.append(("warning", "CLIENT_INFO_PROFILE",
                  "supportScreenTouch %s but Android's default for profile %s is %s (Force/Disable touchscreen setting?)"
                  % ("present" if has_touch else "absent", exp_prof["name"], "present" if exp_prof["supportScreenTouch"] else "absent")))
    canonical = android_json(obj).encode("utf-8")
    if canonical != payload:
        diff = next((i for i in range(min(len(canonical), len(payload))) if canonical[i] != payload[i]),
                    min(len(canonical), len(payload)))
        f.append(("warning", "CLIENT_INFO_BYTES",
                  "reply is not byte-identical to Android's org.json serialization of the same values "
                  "(first difference at byte %d: got %r, Android would write %r) — e.g. '/' must be escaped as '\\/', no "
                  "spaces (JSON-java on a desktop JVM does not escape '/': harness artifact there)"
                  % (diff, payload[max(0, diff - 12):diff + 12], canonical[max(0, diff - 12):diff + 12])))
    return obj, f


def validate_sn_result(payload, sn):
    """0x201c0 body (control-plane.md §10.2)."""
    expected = android_json([("isOk", True), ("errCode", 0), ("errMsg", ""), ("id", sn),
                             ("client_set", "easy_conn")]).encode("utf-8")
    if payload == expected:
        return []
    try:
        obj = parse_json_ordered(payload.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        return [("violation", "CHECK_SN_RESULT", "0x201c0 is not JSON: %s (%r)" % (e, payload[:120]))]
    want = [("isOk", True), ("errCode", 0), ("errMsg", ""), ("id", sn), ("client_set", "easy_conn")]
    if not isinstance(obj, JsonObject):
        return [("violation", "CHECK_SN_RESULT", "0x201c0 is not a JSON object")]
    if list(obj) != want:
        if sorted(obj, key=lambda p: p[0]) == sorted(want, key=lambda p: p[0]):
            return [("violation", "CHECK_SN_RESULT", "0x201c0 key ORDER must be isOk, errCode, errMsg, id, client_set; got %s "
                     "(desktop-JVM JSON-java loses insertion order: harness artifact if this is Android code on a JVM)" % obj.keys())]
        return [("violation", "CHECK_SN_RESULT", "0x201c0 must be %s, got %s" % (expected.decode(), payload[:200]))]
    return [("warning", "CHECK_SN_RESULT", "0x201c0 not byte-identical to Android (%r vs %r)" % (payload, expected))]


# =============================================================================================
# 9. Dash models (control-plane.md §6, §7; media-video.md §10.1)
# =============================================================================================


class DashModel(object):
    def __init__(self, key, title, client_info, device, model_id, burst, ext, touch_mode, orientation,
                 sn="DSXXZMHNFV3DEXEBB3PZ2"):
        self.key = key
        self.title = title
        self.client_info = client_info          # ordered (key, value) pairs
        self.device_w, self.device_h = device   # what REQ 16 asks for
        self.model_id = model_id                # 0x10600 header field
        self.burst = burst                      # CFDL26-family notify burst on CAR_DATA
        self.ext = ext                          # supportExtendProtocol byte @29 of REQ 16
        self.touch_mode = touch_mode
        self.orientation = orientation
        self.sn = sn

    @property
    def info(self):
        return JsonObject(self.client_info)

    @property
    def huid(self):
        return self.info.get("HUID", "")

    @property
    def huname(self):
        return self.info.get("HUName", "fakedash")

    @property
    def canvas(self):
        return self.device_w & 0xFFF0, self.device_h & 0xFFF0

    @property
    def timeout_period(self):
        return _opt_int(self.info, "socketTimeoutPeriodWifi", 9) or 9

    def client_info_bytes(self):
        return android_json(self.client_info).encode("utf-8")


DASH_MODELS = {
    # BIKE A, docs/01 §0: CFMoto 675 SR-R, 800x386 landscape, non-touch, sdk 0.9.29.1. The classic
    # CFDL16 does not document clock frames; this model adds supportSyncCorrectTime:true so that it
    # sends 0x10600 like the dashes of control-plane.md §6.5 (exercises the phone's clock replies).
    "cfdl16": DashModel(
        "cfdl16", "CFDL16 (CFMoto 675 SR-R) 800x386 landscape, non-touch, sdk 0.9.29.1",
        [("HUID", "6GUVA2C00100055"), ("HUName", "CFDL16-6GUV"), ("channel", "37416"), ("flavor", 65540),
         ("sdkVersion", "0.9.29.1"), ("pxcVersion", "1.0.2"), ("screenType", 1), ("productType", 3),
         ("mirrorMode", 1), ("supportScreenMirroring", True), ("socketTimeoutPeriodWifi", 9),
         ("supportFunction", 0), ("supportSyncCorrectTime", True)],
        (800, 386), 37416, burst=False, ext=1, touch_mode=0, orientation=0),
    # BIKE B, docs/01 §7: CFMoto 1000 MT-X, CFDL26 portrait 800x951 touch panel, sdk 1.1.4
    # (CLIENT_INFO = control-plane.md §7 reconstruction + supportSyncCorrectTime).
    "cfdl26": DashModel(
        "cfdl26", "CFDL26 (CFMoto 1000 MT-X) 800x951 portrait, sdk 1.1.4, notify burst",
        [("HUID", "6WX0AT231300200"), ("HUName", "CFMOTO-805120"), ("package_name", "com.cfmoto.cfdashmotoplay"),
         ("version_name", "CFDL26.2.3.5.0.6"), ("sdkVersion", "1.1.4"), ("flavor", 65540), ("productType", 3),
         ("screenType", 1), ("mirrorMode", 1), ("pxcVersion", "1.0.2"), ("enableSockServerAuth", True),
         ("dpi", 240), ("enableDPI", True), ("supportScreenTouch", True), ("supportHID", True),
         ("supportMirrorOverlayTouch", True), ("supportFunction", 128), ("supportConnect", 776),
         ("socketTimeoutPeriodWifi", 9), ("supportScreenMirroring", True), ("supportSyncCorrectTime", True)],
        (800, 951), 37426, burst=True, ext=1, touch_mode=1, orientation=1),
    # 800MT AP (CFDL26 landscape touch), control-plane.md §12.6 case C, media-video.md §10.1 1280x576.
    "mt800": DashModel(
        "mt800", "CFDL26 800MT 1280x576 wide landscape touch, sdk 1.1.2, notify burst",
        [("HUID", "6WWVA2C00300088"), ("HUName", "CFMOTO1565"), ("package_name", "com.cfmoto.easyconnect"),
         ("version_name", "CFDL26.2.3.0.5"), ("sdkVersion", "1.1.2"), ("flavor", 65540), ("productType", 3),
         ("screenType", 1), ("mirrorMode", 1), ("pxcVersion", "1.0.2"), ("enableSockServerAuth", True),
         ("dpi", 160), ("enableDPI", True), ("supportScreenTouch", True), ("supportHID", True),
         ("supportLandscapeAdaptive", True), ("supportFunction", 128), ("supportConnect", 776),
         ("socketTimeoutPeriodWifi", 9), ("supportScreenMirroring", True), ("supportSyncCorrectTime", True)],
        (1280, 576), 37426, burst=True, ext=1, touch_mode=1, orientation=0),
}

SCENARIOS = {
    # scenario: (default dash, default --seconds)
    "cfdl16": ("cfdl16", 10.0),
    "cfdl26": ("cfdl26", 10.0),
    "mt800": ("mt800", 10.0),
    "reconnect": ("cfdl16", 5.0),
    "stall": ("cfdl16", 4.0),
    "touch": ("mt800", 6.0),
    # Apple Music on the dash (iOS app run with -e2eMusic): a plain cfdl16 stream long enough for the
    # app's music script (sheet open +9 s, next song +15 s, pause +21 s, close +27 s after the first frame).
    "music": ("cfdl16", 30.0),
}


def burst_frames(model, seq):
    """Post-CHECK_SN notify burst of CFDL26-class dashes (control-plane.md §6.2), after 0x10780/CHECK_SN.
    The OTA password is a placeholder: never put a real credential here."""
    return [
        (OTA_FTP_INFO, b'{"port":11021,"userName":"carbit_ec_ftp_ota","pwd":"PLACEHOLDER-not-a-real-password"}'),
        (MEDIA_FEATURE_CFG, b'{"music":1,"talkie":0,"tts":1,"vr":0,"autoChangeToBT":0}'),
        (NOTIFY_NAVI_ICON, b'{"maxNaviIcon":161,"supportFunction":0}'),
        (HU_TIME_SYNC, time_sync_payload("normal", model.model_id, seq)),
        (NOTIFY_10750, b""),
        (NOTIFY_10430, b""),
        (HU_QUERY_TIME, b""),
        (NOTIFY_BLUETOOTH, b'{"bluetooth":4129}'),
    ]


# =============================================================================================
# 10. Report, transcript, sinks
# =============================================================================================


class Report(object):
    """Findings (violation / warning / info) with de-duplication by key."""

    def __init__(self, run):
        self.run = run
        self.items = []
        self._by_key = {}

    def add(self, severity, rule, message, conn=None, cycle=None, key=None):
        t = self.run.now()
        if key is not None and key in self._by_key:
            item = self._by_key[key]
            item["count"] += 1
            item["last_t"] = round(t, 3)
            return item
        item = {"t": round(t, 3), "severity": severity, "rule": rule, "message": message, "conn": conn,
                "cycle": cycle, "count": 1}
        self.items.append(item)
        if key is not None:
            self._by_key[key] = item
        tag = {"violation": "VIOLATION", "warning": "WARNING", "info": "note"}[severity]
        level = 0 if severity == "violation" else (1 if severity == "warning" else 2)
        where = ("[%s] " % conn) if conn else ""
        self.run.log("%s %s[%s] %s" % (tag, where, rule, message), level=level)
        self.run.transcript.event(cycle, conn or "-", "%s [%s] %s" % (tag, rule, message), kind="finding")
        return item

    def violation(self, rule, message, **kw):
        return self.add("violation", rule, message, **kw)

    def warning(self, rule, message, **kw):
        return self.add("warning", rule, message, **kw)

    def info(self, rule, message, **kw):
        return self.add("info", rule, message, **kw)

    def findings(self, findings, conn=None, cycle=None, key_prefix=None):
        for sev, rule, msg in findings:
            key = (key_prefix + rule + msg[:40]) if key_prefix else None
            self.add(sev, rule, msg, conn=conn, cycle=cycle, key=key)

    def count(self, severity):
        return sum(1 for i in self.items if i["severity"] == severity)


class Transcript(object):
    """JSON lines for every frame (both directions) + events; also counts frames per command."""

    def __init__(self, run, path, full_frames=False):
        self.run = run
        self.full_frames = full_frames
        self.counts = collections.Counter()
        self.f = open(path, "w", encoding="utf-8") if path else None
        self.lock = threading.Lock()

    def _write(self, obj):
        if self.f is None:
            return
        with self.lock:
            self.f.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
            self.f.flush()

    def frame(self, cycle, conn, direction, kind, cmd, payload, note=None, token=None, extra=None):
        if kind == "cmdbase":
            name = CTRL_NAMES.get(cmd, "?")
            cmd_hex = "0x%x" % cmd
        elif kind == "reqbase":
            name = MEDIA_NAMES.get(cmd, "?")
            cmd_hex = "0x%x" % cmd
        else:
            name = "frame"
            cmd_hex = None
        self.counts["%s %s %s %s" % (conn, direction, cmd_hex or "raw", name)] += 1
        if self.f is None:
            return
        limit = None if (kind != "raw" or self.full_frames) else 64
        shown = payload if limit is None else payload[:limit]
        obj = collections.OrderedDict()
        obj["t"] = round(self.run.now(), 6)
        obj["cycle"] = cycle
        obj["conn"] = conn
        obj["dir"] = direction
        obj["kind"] = kind
        obj["cmd"] = cmd_hex
        obj["name"] = name
        if kind == "reqbase":
            obj["cmd_dec"] = cmd
            obj["token"] = token
        obj["len"] = len(payload)
        obj["payload_hex"] = bytes(shown).hex()
        if limit is not None and len(payload) > limit:
            obj["payload_truncated"] = True
        obj["payload_text"] = printable_text(bytes(payload)) if kind != "raw" else None
        obj["note"] = note
        if extra:
            obj.update(extra)
        self._write(obj)

    def event(self, cycle, conn, note, kind="event", extra=None):
        obj = collections.OrderedDict([("t", round(self.run.now(), 6)), ("cycle", cycle), ("conn", conn),
                                       ("dir", None), ("kind", kind), ("note", note)])
        if extra:
            obj.update(extra)
        self._write(obj)

    def close(self, summary=None):
        if self.f is not None:
            if summary is not None:
                self._write(collections.OrderedDict([("kind", "summary"), ("summary", summary)]))
            self.f.close()
            self.f = None


class H264Sink(object):
    """Writes received access units to a file and/or pipes them to ffplay (writer thread)."""

    def __init__(self, run, path, ffplay, title):
        self.run = run
        self.path = path
        self.file = open(path, "wb") if path else None
        self.proc = None
        self.q = None
        self.thread = None
        if ffplay:
            exe = shutil.which("ffplay")
            if not exe:
                run.log("WARNING: --ffplay requested but ffplay is not installed (brew install ffmpeg)", level=0)
            else:
                cmd = [exe, "-hide_banner", "-loglevel", "warning", "-fflags", "nobuffer", "-flags", "low_delay",
                       "-framedrop", "-probesize", "32", "-analyzeduration", "0", "-sync", "ext", "-autoexit",
                       "-window_title", title, "-f", "h264", "-i", "-"]
                try:
                    self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
                    self.q = queue.Queue()
                    self.thread = threading.Thread(target=self._pump, name="ffplay-pipe", daemon=True)
                    self.thread.start()
                except OSError as e:
                    run.log("WARNING: cannot start ffplay: %s" % e, level=0)
                    self.proc = None

    def _pump(self):
        while True:
            au = self.q.get()
            if au is None:
                break
            try:
                self.proc.stdin.write(au)
                self.proc.stdin.flush()
            except (BrokenPipeError, OSError, ValueError):
                break

    def write(self, au):
        if self.file is not None:
            self.file.write(au)
        if self.q is not None:
            if not self.thread.is_alive():
                # ffplay exited (window closed / no display): stop queueing frames for it.
                self.run.log("ffplay is gone; no longer piping video to it", level=1)
                self.q = None
                return
            self.q.put(bytes(au))

    def close(self):
        if self.file is not None:
            self.file.close()
            self.file = None
        if self.proc is not None:
            if self.q is not None:
                self.q.put(None)
            self.thread.join(timeout=3)
            try:
                self.proc.stdin.close()
            except OSError:
                pass
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=2)
            self.q = None
            self.proc = None


def guess_lan_ip(bind):
    """IPv4 that other hosts on the LAN can reach (for the Bonjour TXT `ip`)."""
    if bind and bind not in ("0.0.0.0", "::", ""):
        return bind
    for target in (("224.0.0.251", 5353), ("192.0.2.1", 9)):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(target)
            ip = s.getsockname()[0]
            if ip and not ip.startswith("0."):
                return ip
        except OSError:
            pass
        finally:
            s.close()
    return "127.0.0.1"


class BonjourAdvertiser(object):
    """_EasyConn._tcp advertisement with the dash TXT keys huid, huname, channel, flavor, port, ip
    (session-network.md §5.2, docs/01 §2) via `dns-sd -R` (macOS) or `avahi-publish-service` (Linux)."""

    SERVICE_TYPE = "_EasyConn._tcp"

    def __init__(self, run, name, port, txt):
        self.run = run
        self.name = name
        self.port = port
        self.txt = txt
        self.proc = None

    def start(self):
        txt = ["%s=%s" % (k, v) for k, v in self.txt]
        if shutil.which("dns-sd"):
            cmd = ["dns-sd", "-R", self.name, self.SERVICE_TYPE, "local", str(self.port)] + txt
        elif shutil.which("avahi-publish-service"):
            cmd = ["avahi-publish-service", self.name, self.SERVICE_TYPE, str(self.port)] + txt
        else:
            self.run.log("WARNING: --bonjour: neither `dns-sd` (macOS) nor `avahi-publish-service` (Linux) is "
                         "available; not advertising %s (the phone must find the dash another way)" % self.SERVICE_TYPE, level=0)
            return False
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except OSError as e:
            self.run.log("WARNING: --bonjour: cannot run %s: %s" % (cmd[0], e), level=0)
            return False
        time.sleep(0.5)
        if self.proc.poll() is not None:
            err = (self.proc.stderr.read() or b"").decode("utf-8", "replace").strip()
            self.proc.stderr.close()
            self.run.log("WARNING: --bonjour: %s exited (%s): %s" % (cmd[0], self.proc.returncode, err[:300]), level=0)
            self.proc = None
            return False
        self.run.log("Bonjour: advertising %r %s port %d TXT %s (via %s)"
                     % (self.name, self.SERVICE_TYPE, self.port, " ".join(txt), cmd[0]), level=0)
        return True

    def stop(self):
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=2)
            if self.proc.stderr is not None:
                self.proc.stderr.close()
            self.proc = None


def decode_check(path, expected_size, frames_received):
    """Runs ffprobe/ffmpeg on the received elementary stream."""
    res = {"file": path}
    probe = shutil.which("ffprobe")
    ff = shutil.which("ffmpeg")
    if not probe or not ff:
        res["error"] = "ffprobe/ffmpeg not installed"
        return res
    try:
        out = subprocess.run([probe, "-v", "error", "-f", "h264", "-select_streams", "v:0", "-count_frames",
                              "-show_entries", "stream=codec_name,profile,level,width,height,pix_fmt,nb_read_frames",
                              "-of", "json", path], capture_output=True, timeout=120)
        data = json.loads(out.stdout.decode("utf-8", "replace") or "{}")
        streams = data.get("streams") or []
        if streams:
            s = streams[0]
            res.update({"codec": s.get("codec_name"), "profile": s.get("profile"), "level": s.get("level"),
                        "width": s.get("width"), "height": s.get("height"), "pix_fmt": s.get("pix_fmt"),
                        "decoded_frames": int(s.get("nb_read_frames") or 0)})
        res["ffprobe_errors"] = out.stderr.decode("utf-8", "replace").strip().splitlines()[:20]
        dec = subprocess.run([ff, "-hide_banner", "-v", "error", "-f", "h264", "-i", path, "-f", "null", "-"],
                             capture_output=True, timeout=300)
        errs = [l for l in dec.stderr.decode("utf-8", "replace").splitlines() if l.strip()]
        res["decode_returncode"] = dec.returncode
        res["decode_error_lines"] = len(errs)
        res["decode_errors"] = errs[:20]
    except (OSError, subprocess.TimeoutExpired, ValueError) as e:
        res["error"] = "decode check failed: %s" % e
        return res
    res["frames_received"] = frames_received
    res["expected_size"] = "%dx%d" % expected_size if expected_size else None
    res["decodable"] = bool(res.get("codec") == "h264" and res.get("decode_returncode") == 0
                            and res.get("decode_error_lines", 1) == 0 and res.get("decoded_frames", 0) > 0)
    return res


# =============================================================================================
# 11. The dash session engine (asyncio)
# =============================================================================================


class SessionAbort(Exception):
    """End the session now."""


class DashStall(Exception):
    """A gate request was not answered: a real dash goes silent and drops the link after its timeout."""


class Waiter(object):
    __slots__ = ("reply", "label", "sent_at", "future", "timed_out", "expect_empty", "validator", "expect_bytes")

    def __init__(self, reply, label, sent_at, future):
        self.reply = reply
        self.label = label
        self.sent_at = sent_at
        self.future = future
        self.timed_out = False
        self.expect_empty = False
        self.validator = None
        self.expect_bytes = None


class Conn(object):
    def __init__(self, session, name, kind, reader, writer, port):
        self.session = session
        self.name = name
        self.kind = kind
        self.reader = reader
        self.writer = writer
        self.port = port
        self.waiters = collections.defaultdict(collections.deque)
        self.closed = False
        self.closed_by = None
        self.closed_at = None
        self.opened_at = session.run.now()
        self.select_acked_at = None
        self.phone_hb = []
        self.last_phone_frame_at = None
        self.token = 0
        self.reply_order = []
        self.reader_task = None

    @property
    def run(self):
        return self.session.run

    def alive(self):
        return not self.closed and not self.writer.is_closing()

    def add_waiter(self, reply, label, expect_empty=False, validator=None, expect_bytes=None):
        fut = asyncio.get_event_loop().create_future()
        w = Waiter(reply, label, self.run.now(), fut)
        w.expect_empty = expect_empty
        w.validator = validator
        w.expect_bytes = expect_bytes
        self.waiters[reply].append(w)
        return w

    def send_cmdbase(self, cmd, payload=b"", note=None):
        if not self.alive():
            return False
        self.writer.write(encode_cmdbase(cmd, payload))
        self.run.transcript.frame(self.session.cycle, self.name, D2P, "cmdbase", cmd, payload, note=note)
        self.session.log_frame(self, D2P, "0x%x %s%s" % (cmd, CTRL_NAMES.get(cmd, "?"),
                                                         (" " + _short(payload)) if payload else ""), cmd)
        return True

    def send_reqbase(self, cmd_type, body=b"", note=None, quiet=False):
        if not self.alive():
            return None
        if self.run.args.media_token == "seq":
            self.token += 1
            token = self.token
        else:
            token = int(self.run.args.media_token)
        self.writer.write(encode_reqbase(cmd_type, body, token))
        self.run.transcript.frame(self.session.cycle, self.name, D2P, "reqbase", cmd_type, body, note=note, token=token)
        if not quiet:
            self.session.log_frame(self, D2P, "%d %s%s" % (cmd_type, MEDIA_NAMES.get(cmd_type, "?"),
                                                           (" (%d B)" % len(body)) if body else ""), cmd_type)
        return token


def _short(payload, n=90):
    t = printable_text(payload)
    if t is None:
        return "<%d B %s>" % (len(payload), payload[:16].hex())
    return t if len(t) <= n else t[:n] + "…"


class Plan(object):
    def __init__(self, stream_seconds, stall_seconds=0.0, resume_seconds=0.0, touch=False, label="stream"):
        self.stream_seconds = stream_seconds
        self.stall_seconds = stall_seconds
        self.resume_seconds = resume_seconds
        self.touch = touch
        self.label = label


class Session(object):
    """One dash connect-back session: control handshake, media setup, frame pulls."""

    def __init__(self, run, cycle, phone_ip, probe_t, plan):
        self.run = run
        self.args = run.args
        self.model = run.model
        self.cycle = cycle
        self.phone_ip = phone_ip
        self.probe_t = probe_t
        self.plan = plan
        self.conns = {}
        self.tasks = set()
        self.script_task = None
        self.abort_reason = None
        self.abort_at = None
        self.tearing_down = False
        self.silent = False
        self.phone_gone = None
        self.end_reason = None
        self.started_at = run.now()
        self.ended_at = None
        self.canvas = None
        self.client_info_obj = None
        self.expect_idr = False
        self.prev_au = None
        self.frames = []            # (t, size, kind, latency)
        self.idr_times = []
        self.first_frame_event = None
        self.first_pull_at = None
        self.media_ready_at = None
        self.handshake_done_at = None
        self.callback_at = None
        self.stall_started_at = None
        self.stall_drop_after = None
        self.stall_completed = False
        self.pull_phases = []       # (label, start, end, frames)
        self.touch_frames = 0
        self.ts_seq = 0
        self.sps_info = None
        self.sps_hex = None
        self.pps_hex = None
        self.identical_idr = 0
        self.clock_modes = collections.Counter()
        self.completed = False
        self._log_counts = collections.Counter()

    # ---------------------------------------------------------------- helpers
    def now(self):
        return self.run.now()

    def log(self, msg, level=1):
        self.run.log("[s%d] %s" % (self.cycle, msg), level)

    def log_frame(self, conn, direction, text, cmd=None):
        key = (conn.name, direction, cmd)
        self._log_counts[key] += 1
        n = self._log_counts[key]
        periodic = cmd in (HEARTBEAT, HEARTBEAT_ACK, HU_TIME_SYNC, HU_TIME_SYNC_ACK, NOTIFY_10750, NOTIFY_10750 + 1,
                           M_HEARTBEAT, M_HEARTBEAT + 1)
        level = 1 if (not periodic or n <= 2) else 2
        arrow = "→" if direction == D2P else "←"
        self.run.log("[s%d][%s] %s %s" % (self.cycle, conn.name, arrow, text), level)

    def spawn(self, coro):
        t = asyncio.ensure_future(coro)
        self.tasks.add(t)
        t.add_done_callback(self._task_done)
        return t

    def _task_done(self, t):
        self.tasks.discard(t)
        if not t.cancelled() and t.exception() is not None:
            exc = t.exception()
            if isinstance(exc, SessionAbort):
                self.abort(str(exc), kind="dash")
            else:
                self.run.log("internal error in session task: %r" % (exc,), level=0)

    @property
    def ending(self):
        return self.abort_reason is not None or self.tearing_down or self.completed

    def abort(self, reason, kind="dash"):
        if self.abort_reason is not None or self.tearing_down:
            return
        self.abort_reason = reason
        self.abort_kind = kind
        self.abort_at = self.now()
        if self.script_task is not None and not self.script_task.done():
            self.script_task.cancel()

    def phone_closed(self, conn, why):
        if conn.closed:
            return
        conn.closed = True
        conn.closed_by = "phone"
        conn.closed_at = self.now()
        self.run.transcript.event(self.cycle, conn.name, "phone closed the connection (%s)" % why)
        if self.tearing_down:
            return
        self.log("[%s] phone closed the connection (%s)" % (conn.name, why), level=1)
        if self.phone_gone is not None:
            self.phone_gone.set()
        if self.stall_started_at is not None and self.stall_drop_after is None and not self.stall_completed:
            self.stall_drop_after = self.now() - self.stall_started_at
            since_frame = self.now() - (self.frames[-1][0] if self.frames else self.stall_started_at)
            if since_frame < 7.5:
                self.run.report.warning("WATCHDOG_EARLY", "the phone dropped the link %.2f s after the last frame (Android's "
                                        "watchdog waits > 8 s without a frame)" % since_frame, conn=conn.name, cycle=self.cycle)
            else:
                self.run.report.info("WATCHDOG", "the phone dropped every socket %.2f s after the last frame (watchdog > 8 s, "
                                     "5 s tick)" % since_frame, conn=conn.name, cycle=self.cycle)
        self.abort("phone closed %s (%s)" % (conn.name, why), kind="phone")

    # ---------------------------------------------------------------- connections
    async def connect(self, name, port, kind):
        last = None
        for attempt in range(3):
            try:
                reader, writer = await asyncio.wait_for(asyncio.open_connection(self.phone_ip, port), 3.0)
            except (OSError, asyncio.TimeoutError) as e:
                last = e
                if attempt == 0:
                    self.run.report.violation(
                        "CONNECT_BACK", "connect-back to %s:%d failed (%s): the phone's listeners must be up BEFORE "
                        "the probe, on the probe's source address" % (self.phone_ip, port, e or type(e).__name__),
                        conn=name, cycle=self.cycle)
                await asyncio.sleep(0.3)
                continue
            sock = writer.get_extra_info("socket")
            if sock is not None:
                try:
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                except OSError:
                    pass
            conn = Conn(self, name, kind, reader, writer, port)
            self.conns[name] = conn
            self.run.transcript.event(self.cycle, name, "dash connected to %s:%d" % (self.phone_ip, port))
            self.log("[%s] connected to %s:%d" % (name, self.phone_ip, port))
            return conn
        raise SessionAbort("connect-back to %s:%d failed: %s" % (self.phone_ip, port, last))

    # ---------------------------------------------------------------- readers
    async def ctrl_reader(self, conn):
        try:
            while True:
                raw = await conn.reader.readexactly(16)
                hdr = CmdBaseHeader(raw)
                if not hdr.magic_ok:
                    self.run.transcript.frame(self.cycle, conn.name, P2D, "cmdbase", hdr.cmd, b"",
                                              note="BAD MAGIC header=%s" % raw.hex())
                    self.run.report.violation(
                        "FRAME_MAGIC", "bad CmdBaseHead magic: cmd=0x%x totalLen=%d magic=0x%x (expected 0x%x); "
                        "a dash closes the socket" % (hdr.cmd, hdr.total_len, hdr.magic, hdr.expected_magic),
                        conn=conn.name, cycle=self.cycle)
                    raise SessionAbort("protocol error on %s (bad magic)" % conn.name)
                if hdr.total_len < 16:
                    self.run.report.violation("FRAME_LENGTH", "CmdBaseHead totalLen %d < 16 (cmd 0x%x)" % (hdr.total_len, hdr.cmd),
                                              conn=conn.name, cycle=self.cycle, key="len<16" + conn.name)
                if hdr.payload_len > MAX_CTRL_PAYLOAD:
                    self.run.report.violation("FRAME_LENGTH", "CmdBaseHead payload of %d bytes (cmd 0x%x)" % (hdr.payload_len, hdr.cmd),
                                              conn=conn.name, cycle=self.cycle)
                    raise SessionAbort("protocol error on %s (huge frame)" % conn.name)
                if hdr.reserved != 0:
                    self.run.report.warning("FRAME_RESERVED", "CmdBaseHead reserved bytes are 0x%08x (written as 0 by Android)"
                                            % hdr.reserved, conn=conn.name, cycle=self.cycle, key="rsv" + conn.name)
                payload = await conn.reader.readexactly(hdr.payload_len) if hdr.payload_len else b""
                conn.last_phone_frame_at = self.now()
                self.on_ctrl_frame(conn, hdr.cmd, payload)
        except asyncio.IncompleteReadError as e:
            self.phone_closed(conn, "EOF" + (" mid-frame after %d bytes" % len(e.partial) if e.partial else ""))
        except (ConnectionError, OSError) as e:
            self.phone_closed(conn, "%s: %s" % (type(e).__name__, e))
        except SessionAbort as e:
            self.abort(str(e))

    def on_ctrl_frame(self, conn, cmd, payload):
        t = self.now()
        if cmd == HEARTBEAT:
            conn.phone_hb.append(t)
            self.run.transcript.frame(self.cycle, conn.name, P2D, "cmdbase", cmd, payload, note="phone heartbeat")
            self.log_frame(conn, P2D, "0x70000000 HEARTBEAT (phone)", cmd)
            if payload:
                self.run.report.violation("REPLY_PAYLOAD", "phone heartbeat 0x70000000 must be empty (%d B)" % len(payload),
                                          conn=conn.name, cycle=self.cycle, key="hbpayload" + conn.name)
            if conn.select_acked_at is None:
                self.run.report.warning("HEARTBEAT_EARLY", "phone heartbeat before the channel select was acked",
                                        conn=conn.name, cycle=self.cycle, key="hbearly" + conn.name)
            if not self.silent:
                conn.send_cmdbase(HEARTBEAT_ACK, b"", note="ack of the phone heartbeat")
            return
        queue_ = conn.waiters.get(cmd)
        if queue_:
            w = queue_.popleft()
            latency = t - w.sent_at
            conn.reply_order.append(cmd)
            self.run.transcript.frame(self.cycle, conn.name, P2D, "cmdbase", cmd, payload,
                                      note="reply to %s in %.1f ms%s" % (w.label, latency * 1000, " (LATE)" if w.timed_out else ""))
            self.log_frame(conn, P2D, "0x%x %s (%.1f ms)%s" % (cmd, CTRL_NAMES.get(cmd, "?"), latency * 1000,
                                                             (" " + _short(payload)) if payload else ""), cmd)
            if w.timed_out:
                self.run.report.warning("REPLY_LATE", "%s answered after %.2f s (after the timeout)" % (w.label, latency),
                                        conn=conn.name, cycle=self.cycle)
            if w.expect_empty and payload:
                self.run.report.violation("REPLY_PAYLOAD", "reply 0x%x to %s must be EMPTY, got %d B %r"
                                          % (cmd, w.label, len(payload), payload[:80]), conn=conn.name, cycle=self.cycle,
                                          key="nonempty%x" % cmd)
            if w.validator is not None:
                try:
                    w.validator(payload)
                except Exception as e:  # never let a validator bug kill the reader
                    self.run.log("internal validator error: %r" % (e,), level=0)
            if not w.future.done():
                w.future.set_result(payload)
            return
        self.run.transcript.frame(self.cycle, conn.name, P2D, "cmdbase", cmd, payload, note="UNSOLICITED")
        self.log_frame(conn, P2D, "0x%x %s UNSOLICITED %s" % (cmd, CTRL_NAMES.get(cmd, "?"), _short(payload)), cmd)
        if cmd == HU_TIME_SYNC_ACK:
            self.run.report.violation("UNSOLICITED_CTRL", "unsolicited 0x10601: never push the clock (§13.3, §18.9)",
                                      conn=conn.name, cycle=self.cycle, key="unsol10601")
        elif cmd == HEARTBEAT_ACK:
            self.run.report.warning("UNSOLICITED_CTRL", "0x70000001 without a pending dash heartbeat",
                                    conn=conn.name, cycle=self.cycle, key="unsolhback" + conn.name)
        else:
            self.run.report.violation("UNSOLICITED_CTRL", "unsolicited control frame 0x%x %s from the phone (%d B)"
                                      % (cmd, CTRL_NAMES.get(cmd, "?"), len(payload)), conn=conn.name,
                                      cycle=self.cycle, key="unsol%x" % cmd)

    async def media_reader(self, conn):
        try:
            while True:
                raw = await conn.reader.readexactly(8)
                ct, ln, tok = parse_reqbase_header(raw)
                body = await conn.reader.readexactly(ln) if ln else b""
                self.on_media_frame(conn, ct, tok, body)
        except asyncio.IncompleteReadError as e:
            self.phone_closed(conn, "EOF" + (" mid-frame after %d bytes" % len(e.partial) if e.partial else ""))
        except (ConnectionError, OSError) as e:
            self.phone_closed(conn, "%s: %s" % (type(e).__name__, e))

    def on_media_frame(self, conn, ct, tok, body):
        t = self.now()
        conn.last_phone_frame_at = t
        if tok != 0:
            self.run.report.violation("MEDIA_TOKEN", "media reply %d carries token %d; replies must use token 0 (§3.2)"
                                      % (ct, tok), conn=conn.name, cycle=self.cycle, key="tok%d" % ct)
        queue_ = conn.waiters.get(ct)
        if queue_:
            w = queue_.popleft()
            latency = t - w.sent_at
            self.run.transcript.frame(self.cycle, conn.name, P2D, "reqbase", ct, body, token=tok,
                                      note="reply to %s in %.1f ms%s" % (w.label, latency * 1000, " (LATE)" if w.timed_out else ""))
            self.log_frame(conn, P2D, "%d %s (%.1f ms)%s" % (ct, MEDIA_NAMES.get(ct, "?"), latency * 1000,
                                                           (" " + body.hex()) if body and ct != 97 else (" " + _short(body) if body else "")), ct)
            if w.timed_out:
                self.run.report.warning("REPLY_LATE", "%s answered after %.2f s" % (w.label, latency), conn=conn.name, cycle=self.cycle)
            wire = encode_reqbase(ct, body, 0)
            if w.expect_bytes is not None and wire != w.expect_bytes:
                self.run.report.violation(
                    "MEDIA_RLY%d" % ct, "reply to %s must be %s (token aside), got %s" % (w.label, w.expect_bytes.hex(" "), wire.hex(" ")),
                    conn=conn.name, cycle=self.cycle, key="rly%d" % ct)
            if w.validator is not None:
                try:
                    w.validator(body)
                except Exception as e:
                    self.run.log("internal validator error: %r" % (e,), level=0)
            if not w.future.done():
                w.future.set_result(body)
            return
        self.run.transcript.frame(self.cycle, conn.name, P2D, "reqbase", ct, body, token=tok, note="UNSOLICITED")
        self.log_frame(conn, P2D, "%d %s UNSOLICITED (%d B)" % (ct, MEDIA_NAMES.get(ct, "?"), len(body)), ct)
        if ct == M_TOUCH + 1 or (self.touch_frames and ct not in (17, 49, 65, 97, 113, 129)):
            self.run.report.violation("TOUCH_REPLY", "the phone answered a touch frame (cmd %d, %d B): cmd 32 must NEVER be "
                                      "answered (input-controls.md §2.1)" % (ct, len(body)), conn=conn.name,
                                      cycle=self.cycle, key="touchreply%d" % ct)
        else:
            self.run.report.violation("UNSOLICITED_MEDIA", "unsolicited media frame cmdType %d (%d B): the phone never "
                                      "initiates media frames" % (ct, len(body)), conn=conn.name, cycle=self.cycle,
                                      key="unsolm%d" % ct)

    # ---------------------------------------------------------------- requests
    async def await_waiter(self, conn, w, timeout, gate=False, what=None):
        try:
            return await asyncio.wait_for(asyncio.shield(w.future), timeout)
        except asyncio.TimeoutError:
            w.timed_out = True
            self.run.report.violation("REPLY_TIMEOUT", "no reply 0x%x/%s to %s within %.1f s%s"
                                      % (w.reply, (CTRL_NAMES if conn.kind == "cmdbase" else MEDIA_NAMES).get(w.reply, "?"),
                                         what or w.label, timeout,
                                         " — a real dash stalls here" if gate else ""),
                                      conn=conn.name, cycle=self.cycle, key=None if gate else "timeout%s%x" % (conn.name, w.reply))
            if gate and not self.args.lenient:
                raise DashStall("%s unanswered" % (what or w.label))
            return None

    async def ctrl_request(self, conn, cmd, payload=b"", label=None, gate=False, expect_empty=False,
                           validator=None, reply=None, timeout=None):
        label = label or "0x%x %s" % (cmd, CTRL_NAMES.get(cmd, "?"))
        w = conn.add_waiter(reply or cmd + 1, label, expect_empty=expect_empty, validator=validator)
        conn.send_cmdbase(cmd, payload)
        return await self.await_waiter(conn, w, timeout or self.args.reply_timeout, gate=gate)

    async def media_request(self, conn, cmd_type, body=b"", label=None, gate=False, expect_bytes=None,
                            validator=None, timeout=None):
        label = label or "%d %s" % (cmd_type, MEDIA_NAMES.get(cmd_type, "?"))
        w = conn.add_waiter(cmd_type + 1, label, validator=validator, expect_bytes=expect_bytes)
        conn.send_reqbase(cmd_type, body)
        return await self.await_waiter(conn, w, timeout or self.args.reply_timeout, gate=gate)

    # ---------------------------------------------------------------- the script
    async def run_session(self):
        self.phone_gone = asyncio.Event()
        self.first_frame_event = asyncio.Event()
        self.log("connect-back session to %s (%s)" % (self.phone_ip, self.model.title), level=1)
        self.run.transcript.event(self.cycle, "-", "session %d start: phone %s" % (self.cycle, self.phone_ip))
        self.script_task = asyncio.ensure_future(self.script())
        try:
            await self.script_task
            self.completed = True
            self.end_reason = "completed"
        except asyncio.CancelledError:
            if self.abort_reason is None:
                raise
            self.end_reason = self.abort_reason
        except SessionAbort as e:
            self.end_reason = self.abort_reason or str(e)
        except DashStall as e:
            self.end_reason = await self.emulate_dash_timeout(str(e))
        finally:
            await self.teardown()
            self.ended_at = self.now()
        self.log("session ended: %s" % self.end_reason, level=1)
        self.run.transcript.event(self.cycle, "-", "session %d end: %s" % (self.cycle, self.end_reason))
        return self.end_reason

    async def emulate_dash_timeout(self, reason):
        period = self.model.timeout_period
        self.log("!! %s — like a real dash: going silent, closing everything after %d s" % (reason, period), level=0)
        self.silent = True
        for t in list(self.tasks):
            t.cancel()
        try:
            await asyncio.wait_for(self.phone_gone.wait(), period)
            return "phone closed while the dash was stalled (%s)" % reason
        except asyncio.TimeoutError:
            return "dash timeout: %s" % reason

    async def teardown(self):
        self.tearing_down = True
        for t in list(self.tasks):
            t.cancel()
        if getattr(self, "abort_kind", None) == "phone":
            # Give the phone a moment to close the remaining sockets itself (watchdog/stop closes all).
            deadline = self.now() + 1.5
            while self.now() < deadline and any(not c.closed for c in self.conns.values() if c.reader_task is not None):
                await asyncio.sleep(0.05)
        for c in self.conns.values():
            if not c.closed and c.reader_task is None and c.reader.at_eof():
                # Not being read (data socket during a stall): the phone's EOF is already queued.
                self.phone_closed(c, "EOF (seen at teardown)")
            if not c.closed:
                c.closed = True
                c.closed_by = "dash"
                c.closed_at = self.now()
                self.run.transcript.event(self.cycle, c.name, "dash closed the connection")
            try:
                c.writer.close()
            except (OSError, RuntimeError):
                pass
        readers = [c.reader_task for c in self.conns.values() if c.reader_task is not None]
        for r in readers:
            r.cancel()
        if readers:
            await asyncio.gather(*readers, return_exceptions=True)
        if self.tasks:
            await asyncio.gather(*list(self.tasks), return_exceptions=True)
        for c in self.conns.values():
            try:
                await asyncio.wait_for(c.writer.wait_closed(), 1.0)
            except (asyncio.TimeoutError, OSError, ConnectionError, RuntimeError):
                pass
        self.check_heartbeats()

    async def script(self):
        a = self.args
        m = self.model
        await asyncio.sleep(a.callback_delay)
        self.callback_at = self.now()
        # --- :10922 #1 CAR_CTRL (control-plane.md §6.1)
        c1 = await self.connect("ctrl1", a.phone_ports[0], "cmdbase")
        c1.reader_task = asyncio.ensure_future(self.ctrl_reader(c1))
        await self.ctrl_request(c1, CAR_CTRL, b"", gate=True, expect_empty=True, label="CAR_CTRL select 0x10000")
        c1.select_acked_at = self.now()
        if not a.no_dash_heartbeat:
            self.spawn(self.dash_heartbeat_loop(c1))
        await asyncio.sleep(a.step_delay)
        await self.ctrl_request(c1, CLIENT_INFO, m.client_info_bytes(), gate=True, label="CLIENT_INFO 0x10010",
                                validator=self.validate_client_info)
        await asyncio.sleep(a.step_delay)
        await self.ctrl_request(c1, QUERY_SPEED, b'{"usbSpeed":0,"wifiSpeed":0}', gate=True, expect_empty=True,
                                label="QUERY_SPEED 0x10690")
        # --- :10922 #2 CAR_DATA
        await asyncio.sleep(a.step_delay)
        c2 = await self.connect("ctrl2", a.phone_ports[0], "cmdbase")
        c2.reader_task = asyncio.ensure_future(self.ctrl_reader(c2))
        await self.ctrl_request(c2, CAR_DATA, b"", gate=True, expect_empty=True, label="CAR_DATA select 0x20000")
        c2.select_acked_at = self.now()
        if not a.no_dash_heartbeat:
            self.spawn(self.dash_heartbeat_loop(c2))
        if a.silence_teardown:
            self.spawn(self.silence_monitor([c1, c2]))
        await asyncio.sleep(a.step_delay)
        if m.burst:
            # CFDL26: LOG_REPORT is "the first gate" (control-plane.md §6.2).
            await self.ctrl_request(c2, LOG_REPORT, b'{"log":"EasyConn mdns success (fakedash simulated log)"}',
                                    gate=True, expect_empty=True, label="LOG_REPORT 0x10780")
        await self.check_sn(c2)
        if m.burst:
            await self.notify_burst(c2)
        else:
            self.ts_seq += 1
            req = time_sync_payload("normal", m.model_id, self.ts_seq)
            await self.ctrl_request(c2, HU_TIME_SYNC, req, label="HU_TIME_SYNC 0x10600 (normal)",
                                    validator=lambda p, r=req: self.validate_time_sync(r, p, "normal"))
            await self.ctrl_request(c2, HU_QUERY_TIME, b"", expect_empty=True, label="HU_QUERY_TIME 0x10450")
        self.spawn(self.clock_loop(c2))
        if m.burst:
            self.spawn(self.notify_10750_loop(c2))
        self.handshake_done_at = self.now()
        # --- media plane (media-video.md §4.11)
        await asyncio.sleep(a.step_delay)
        mc = await self.connect("mctrl", a.phone_ports[1], "reqbase")
        mc.reader_task = asyncio.ensure_future(self.media_reader(mc))
        huid_text = b""
        if self.client_info_obj is not None and isinstance(self.client_info_obj.get("encryptedHUID"), str):
            huid_text = self.client_info_obj.get("encryptedHUID").encode("ascii", "replace")
        if len(huid_text) != 172:
            huid_text = base64.b64encode(b"\x00" * 128)
        body16 = build_config_capture(m.device_w, m.device_h, fps=30, encoder=2, touch_mode=m.touch_mode,
                                      orientation=m.orientation, ext=m.ext, huid_text=huid_text)
        exp17 = expected_rly17(body16)
        reply17 = await self.media_request(mc, M_CONFIG_CAPTURE, body16, gate=True, expect_bytes=exp17,
                                           label="REQ_RV_CONFIG_CAPTURE %dx%d" % (m.device_w, m.device_h))
        self.canvas = m.canvas
        if reply17 is not None and len(reply17) >= 8:
            rw, rh = struct.unpack_from("<HH", reply17, 4)
            if (rw, rh) != m.canvas:
                self.canvas = (rw, rh)
        self.log("canvas %dx%d (requested %dx%d)" % (self.canvas[0], self.canvas[1], m.device_w, m.device_h))
        await self.media_request(mc, M_GET_VERSION, b"", expect_bytes=RLY49)
        await self.media_request(mc, M_HEARTBEAT, b"", expect_bytes=RLY65)
        await self.media_request(mc, M_CONFIG_EXTEND, b'{"version":1,"fakedash":true}', expect_bytes=RLY97)
        self.expect_idr = True
        await self.media_request(mc, M_DATA_START, b"", gate=True, expect_bytes=RLY113)
        if a.start_h264:
            self.expect_idr = True
            await self.media_request(mc, M_START_H264, b"", expect_bytes=RLY129)
        self.media_ready_at = self.now()
        self.spawn(self.media_heartbeat_loop(mc))
        await asyncio.sleep(0.07)       # "the bike opens the data socket ~70 ms later" (media-video.md §4.11)
        md = await self.connect("mdata", a.phone_ports[2], "reqbase")
        # --- streaming
        if self.plan.touch:
            self.spawn(self.touch_script(mc))
        await self.pull_for(md, self.plan.stream_seconds, self.plan.label)
        if self.plan.stall_seconds:
            self.stall_started_at = self.now()
            self.log("STALL: keeping every socket open but not pulling for %.1f s (the phone watchdog should drop the "
                     "link after > 8 s without a frame)" % self.plan.stall_seconds, level=0)
            self.run.transcript.event(self.cycle, "mdata", "stall start (%.1f s)" % self.plan.stall_seconds)
            await asyncio.sleep(self.plan.stall_seconds)
            self.stall_completed = True
            self.log("STALL over after %.1f s: the phone kept the link; resuming pulls" % self.plan.stall_seconds, level=0)
            if self.plan.stall_seconds >= 13.5:
                self.run.report.warning("WATCHDOG_MISSING", "no frame for %.1f s and the phone kept every socket: its watchdog "
                                        "(> 8 s, 5 s tick) should have re-probed" % self.plan.stall_seconds,
                                        conn="mdata", cycle=self.cycle)
            else:
                self.run.report.info("WATCHDOG", "the phone kept the link through a %.1f s stall (Android's 5 s-tick watchdog "
                                     "fires between 8 and 13 s; --stall-seconds 14 makes a drop mandatory)"
                                     % self.plan.stall_seconds, conn="mdata", cycle=self.cycle)
            self.run.transcript.event(self.cycle, "mdata", "stall end, resuming pulls")
            await self.pull_for(md, self.plan.resume_seconds, "resume")

    async def check_sn(self, c2):
        sn = self.model.sn
        w_res = c2.add_waiter(CHECK_SN_RESULT, "CHECK_SN_RESULT 0x201c0",
                              validator=lambda p: self.run.report.findings(validate_sn_result(p, sn), conn="ctrl2", cycle=self.cycle))
        payload = ('{"client_set":"easy_conn","sn":"%s"}' % sn).encode("utf-8")
        await self.ctrl_request(c2, CHECK_SN, payload, gate=True, expect_empty=True, label="CHECK_SN 0x103e0")
        got = await self.await_waiter(c2, w_res, self.args.reply_timeout, gate=True, what="CHECK_SN (expects 0x201c0 result)")
        if got is not None:
            order = [c for c in c2.reply_order if c in (CHECK_SN_ACK, CHECK_SN_RESULT)]
            if order[:2] == [CHECK_SN_RESULT, CHECK_SN_ACK]:
                self.run.report.warning("CHECK_SN_RESULT", "0x201c0 arrived before the 0x103e1 ack (Android: ack first)",
                                        conn="ctrl2", cycle=self.cycle)
            c2.send_cmdbase(CHECK_SN_RESULT_ACK, b"", note="dash ack of CHECK_SN_RESULT")

    async def notify_burst(self, c2):
        """CFDL26: the rest of the burst back to back; media opens only after EVERY frame is acked."""
        self.ts_seq += 1
        frames = burst_frames(self.model, self.ts_seq)
        waiters = []
        for cmd, payload in frames:
            label = "burst 0x%x %s" % (cmd, CTRL_NAMES.get(cmd, "?"))
            if cmd == HU_TIME_SYNC:
                w = c2.add_waiter(cmd + 1, label, validator=lambda p, r=payload: self.validate_time_sync(r, p, "normal"))
            else:
                w = c2.add_waiter(cmd + 1, label, expect_empty=True)
            c2.send_cmdbase(cmd, payload, note="notify burst")
            waiters.append(w)
            if self.args.burst_mode == "sequential":
                await self.await_waiter(c2, w, self.args.reply_timeout, gate=True)
            else:
                await asyncio.sleep(0.005)
        missing = []
        for w in waiters:
            if w.future.done():
                continue
            got = await self.await_waiter(c2, w, self.args.reply_timeout, gate=False)
            if got is None:
                missing.append(w.label)
        if missing and not self.args.lenient:
            raise DashStall("notify burst not fully acked (%s): CFDL26 never opens :10921/:10920" % ", ".join(missing))

    # ---------------------------------------------------------------- periodic dash traffic
    async def dash_heartbeat_loop(self, conn):
        while True:
            await asyncio.sleep(self.args.hb_interval)
            if not conn.alive() or self.silent:
                return
            w = conn.add_waiter(HEARTBEAT_ACK, "dash heartbeat 0x70000000", expect_empty=True)
            conn.send_cmdbase(HEARTBEAT, b"", note="dash heartbeat")
            self.spawn(self.await_waiter(conn, w, self.args.reply_timeout))

    async def clock_loop(self, conn):
        # The handshake / burst already sent a normal stamp; the periodic loop starts with the variants.
        variants = {"none": [], "field": ["short", "tsep", "epoch"],
                    "all": ["short", "tsep", "epoch", "empty", "nul"]}[self.args.clock_variants]
        i = 0
        while True:
            await asyncio.sleep(self.args.clock_interval)
            if not conn.alive() or self.silent:
                return
            kind = variants[i] if i < len(variants) else "normal"
            i += 1
            self.ts_seq += 1
            req = time_sync_payload(kind, self.model.model_id, self.ts_seq)
            w = conn.add_waiter(HU_TIME_SYNC_ACK, "HU_TIME_SYNC 0x10600 (%s)" % kind,
                                validator=lambda p, r=req, k=kind: self.validate_time_sync(r, p, k))
            conn.send_cmdbase(HU_TIME_SYNC, req, note="dash clock (%s) seq=%d" % (kind, self.ts_seq))
            self.spawn(self.await_waiter(conn, w, self.args.reply_timeout))

    async def notify_10750_loop(self, conn):
        while True:
            await asyncio.sleep(6.0)
            if not conn.alive() or self.silent:
                return
            w = conn.add_waiter(NOTIFY_10750 + 1, "periodic 0x10750", expect_empty=True)
            conn.send_cmdbase(NOTIFY_10750, b"", note="periodic notify")
            self.spawn(self.await_waiter(conn, w, self.args.reply_timeout))

    async def media_heartbeat_loop(self, conn):
        while True:
            await asyncio.sleep(self.args.media_hb_interval)
            if not conn.alive() or self.silent:
                return
            w = conn.add_waiter(M_HEARTBEAT + 1, "media heartbeat 64", expect_bytes=RLY65)
            conn.send_reqbase(M_HEARTBEAT, b"", quiet=True)
            self.spawn(self.await_waiter(conn, w, self.args.reply_timeout))

    async def silence_monitor(self, conns):
        """US 800NK rule (control-plane.md §6.3): tear down after ~N s of silence on either :10922 socket."""
        limit = self.args.silence_teardown
        while True:
            await asyncio.sleep(0.25)
            for c in conns:
                last = c.last_phone_frame_at or c.select_acked_at or c.opened_at
                if c.alive() and self.now() - last > limit:
                    self.run.report.violation("HEARTBEAT_SILENCE", "no phone frame on %s for %.1f s: a US 800NK tears the "
                                              "session down here (phone must heartbeat EVERY :10922 socket)" % (c.name, limit),
                                              conn=c.name, cycle=self.cycle)
                    raise SessionAbort("dash teardown: %.1f s of silence on %s (800NK rule)" % (limit, c.name))

    # ---------------------------------------------------------------- touch (input-controls.md §2, §4.5)
    async def touch_script(self, mc):
        await self.first_frame_event.wait()
        await asyncio.sleep(1.0)
        w, h = self.canvas
        seqs = [
            ("tap top-left corner", [(0, 2, 0, 0, 0), (60, 1, 0, 0, 0)]),
            ("tap bottom-right corner", [(0, 2, w - 1, h - 1, 0), (60, 1, w - 1, h - 1, 0)]),
            ("tap centre", [(0, 2, w // 2, h // 2, 0), (60, 1, w // 2, h // 2, 0)]),
            ("S2 drag, contact re-acquired with the same id", [(0, 2, 100, 100, 0), (16, 3, 140, 100, 0), (32, 1, 160, 100, 0),
                                                                (40, 2, 175, 100, 0), (56, 3, 200, 100, 0), (200, 1, 300, 100, 0)]),
            ("S4 ghost second contact", [(0, 2, 300, 200, 0), (5, 2, 320, 210, 1), (20, 3, 325, 212, 1),
                                         (40, 1, 325, 212, 1), (60, 1, 300, 200, 0)]),
            ("S5 two-finger pinch", [(0, 2, 200, 200, 0), (10, 2, 400, 200, 1), (30, 3, 190, 200, 0), (31, 3, 410, 200, 1),
                                     (60, 3, 180, 200, 0), (61, 3, 420, 200, 1), (100, 1, 180, 200, 0), (140, 1, 420, 200, 1)]),
        ]
        if self.args.touch_fuzz:
            seqs.append(("fuzz: unknown action 9", [(0, 9, 10, 10, 0)]))
        loop = asyncio.get_event_loop()
        t0 = loop.time()
        for label, events in seqs:
            base = loop.time()
            for ms, action, x, y, pid in events:
                delay = base + ms / 1000.0 - loop.time()
                if delay > 0:
                    await asyncio.sleep(delay)
                ts = int((loop.time() - t0) * 1000)
                body = build_touch_body(action, x, y, pid, ts)
                mc.send_reqbase(M_TOUCH, body, note="touch %s: %s ptr%d (%d,%d)" % (label, TOUCH_ACTIONS.get(action, action), pid, x, y))
                self.touch_frames += 1
            await asyncio.sleep(0.5)
        if self.args.touch_fuzz:
            mc.writer.write(encode_reqbase(M_TOUCH, b"\x02\x00\x10\x00\x10\x00\x00", 0))
            self.run.transcript.frame(self.cycle, mc.name, D2P, "reqbase", M_TOUCH, b"\x02\x00\x10\x00\x10\x00\x00", note="fuzz: 7-byte touch body", token=0)
            self.touch_frames += 1
        self.log("touch: sent %d cmd-32 frames (no reply expected)" % self.touch_frames, level=1)

    # ---------------------------------------------------------------- frame pulls
    async def pull_for(self, md, seconds, label):
        start = self.now()
        frames_before = len(self.frames)
        interval = 1.0 / self.args.fps
        loop = asyncio.get_event_loop()
        end = loop.time() + seconds
        nxt = loop.time()
        while loop.time() < end:
            await self.pull_one(md)
            nxt += interval
            delay = nxt - loop.time()
            if delay > 0:
                await asyncio.sleep(delay)
            else:
                nxt = loop.time()
        self.pull_phases.append((label, start, self.now(), len(self.frames) - frames_before))

    async def pull_one(self, md):
        a = self.args
        buffered = getattr(md.reader, "_buffer", None)
        if buffered:
            extra = await md.reader.read(len(buffered))
            self.run.transcript.frame(self.cycle, md.name, P2D, "raw", None, extra, note="UNSOLICITED bytes on :10920")
            self.run.report.violation("FRAME_EXTRA_BYTES", "%d unsolicited bytes on the data socket before the next 114 "
                                      "(exactly ONE [size][AU] per 114)" % len(extra), conn=md.name, cycle=self.cycle,
                                      key="extra" + md.name)
        if self.first_pull_at is None:
            self.first_pull_at = self.now()
        md.send_reqbase(M_DATA_NEXT, b"", quiet=True)
        t0 = self.now()
        timeout = a.pull_timeout or self.model.timeout_period
        try:
            size_b = await asyncio.wait_for(md.reader.readexactly(4), timeout)
            size = struct.unpack("<i", size_b)[0]
            if size <= 0:
                self.run.transcript.frame(self.cycle, md.name, P2D, "raw", None, b"", note="ZERO/NEGATIVE size %d" % size)
                self.run.report.violation("FRAME_SIZE", "frame size %d: never send a zero-size/placeholder frame (§15.2)" % size,
                                          conn=md.name, cycle=self.cycle, key="zerosize")
                if size < 0:
                    raise SessionAbort("negative frame size: data stream desynchronised")
                return
            if size > MAX_FRAME_BYTES:
                self.run.report.violation("FRAME_SIZE", "frame size %d bytes is absurd: stream desynchronised" % size,
                                          conn=md.name, cycle=self.cycle)
                raise SessionAbort("data stream desynchronised")
            au = await asyncio.wait_for(md.reader.readexactly(size), timeout)
        except asyncio.TimeoutError:
            self.run.report.violation("PULL_TIMEOUT", "REQ_RV_DATA_NEXT (114) unanswered for %.1f s: the dash drops the media "
                                      "link (socketTimeoutPeriodWifi=%d)" % (timeout, self.model.timeout_period),
                                      conn=md.name, cycle=self.cycle)
            raise SessionAbort("dash media timeout: 114 unanswered for %.1f s" % timeout)
        except asyncio.IncompleteReadError as e:
            self.phone_closed(md, "EOF" + (" mid-frame" if e.partial else ""))
            raise SessionAbort("phone closed mdata")
        except (ConnectionError, OSError) as e:
            self.phone_closed(md, "%s: %s" % (type(e).__name__, e))
            raise SessionAbort("phone closed mdata")
        t1 = self.now()
        self.on_frame(md, au, t1, t1 - t0)

    def on_frame(self, md, au, t, latency):
        rep = self.run.report
        n = len(self.frames) + 1
        info = analyze_au(au)
        first_after_start = self.expect_idr
        self.expect_idr = False
        self.frames.append((t, len(au), info.kind, latency))
        self.run.frames_total += 1
        note = "frame #%d %s %d B nal=%s latency=%.1f ms" % (n, info.kind, len(au), info.describe(), latency * 1000)
        self.run.transcript.frame(self.cycle, md.name, P2D, "raw", None, au, note=note,
                                  extra={"frame": n, "keyframe": info.has_idr, "nal_types": info.nal_types,
                                         "latency_ms": round(latency * 1000, 2)})
        if n <= 5 or n % 100 == 0:
            self.log("[mdata] ← frame #%d %s %d B nal=%s (%.1f ms)" % (n, info.kind, len(au), info.describe(), latency * 1000))
        if n == 1:
            self.first_frame_event.set()
            if self.media_ready_at is not None:
                self.log("first frame %.3f s after RLY 113" % (t - self.media_ready_at))
        c = self.cycle
        if info.leading or not info.nal_types:
            rep.violation("FRAME_ANNEXB", "access unit does not start with an Annex-B start code (%d leading bytes%s): first "
                          "bytes %s" % (info.leading, "; looks like AVCC length-prefixed NALs (VideoToolbox output not "
                                                         "converted)" if info.avcc else "", au[:12].hex(" ")),
                          conn=md.name, cycle=c, key="annexb")
        if info.nal_types and info.vcl == 0:
            rep.violation("FRAME_ANNEXB", "access unit without any slice (NAL types %s): SPS/PPS/SEI must never be sent as "
                          "their own pull response" % info.nal_types, conn=md.name, cycle=c, key="novcl")
        if first_after_start and not info.has_idr:
            rep.violation("FRAME_FIRST_NOT_IDR", "first frame after REQ_RV_DATA_START (112) is %s (NAL %s): it must be "
                          "SPS+PPS+IDR (the 'black dash' bug, media-video.md §6.1)" % (info.kind, info.nal_types),
                          conn=md.name, cycle=c)
        if info.has_idr:
            self.idr_times.append(t)
            if not (info.sps_before_vcl and info.pps_before_vcl):
                rep.violation("FRAME_IDR_NO_PARAMS", "IDR frame #%d without %s before the slice (NAL %s): SPS+PPS go in front "
                              "of EVERY IDR" % (n, " and ".join(x for x, ok in (("SPS", info.sps_before_vcl), ("PPS", info.pps_before_vcl)) if not ok),
                                                info.nal_types), conn=md.name, cycle=c, key="idrnoparams")
            elif info.pps_before_sps:
                rep.warning("FRAME_PARAM_ORDER", "PPS before SPS in IDR frame #%d (NAL %s)" % (n, info.nal_types),
                            conn=md.name, cycle=c, key="ppsorder")
            if info.has_non_idr:
                rep.warning("FRAME_MIXED", "frame #%d mixes IDR and non-IDR slices (NAL %s)" % (n, info.nal_types),
                            conn=md.name, cycle=c, key="mixed")
        if info.sps is not None:
            self.check_sps(info, n)
        elif info.sps_before_vcl:
            rep.warning("SPS_PARSE", "could not parse the SPS of frame #%d (synthetic stream?) %s" % (n, info.sps_hex),
                        conn=md.name, cycle=c, key="spsparse")
        bslices = [s for s in info.slice_types if s % 5 == 1]
        if bslices:
            rep.violation("FRAME_B_SLICE", "B slice in frame #%d: no reordering allowed on the PTS-less wire (Baseline, "
                          "AllowFrameReordering=false)" % n, conn=md.name, cycle=c, key="bslice")
        if self.prev_au is not None and au == self.prev_au:
            if info.has_idr:
                self.identical_idr += 1
            else:
                rep.violation("FRAME_REPEATED_P", "frame #%d is a byte-identical repeat of the previous P-frame (re-applying a "
                              "P-frame corrupts the picture, §15.2)" % n, conn=md.name, cycle=c, key="repeatp")
        self.prev_au = au
        if latency > 1.5:
            rep.warning("PULL_SLOW", "114 answered after %.2f s (Android gives up at 1.5 s; dash drops at ~9 s)" % latency,
                        conn=md.name, cycle=c, key="slow")
        self.run.h264.write(au)

    def check_sps(self, info, n):
        sps = info.sps
        rep = self.run.report
        if self.sps_info is None:
            self.sps_info = sps
            self.sps_hex = info.sps_hex
            self.pps_hex = info.pps_hex
            self.log("SPS: profile %d level %d %dx%d poc_type %d refs %d vui %s %s"
                     % (sps["profile_idc"], sps["level_idc"], sps["width"], sps["height"], sps["poc_type"],
                        sps["max_num_ref_frames"], sps["vui"], info.sps_hex))
        if self.canvas and (sps["width"], sps["height"]) != tuple(self.canvas):
            rep.violation("FRAME_SIZE_MISMATCH", "SPS says %dx%d but the negotiated canvas (RLY 17) is %dx%d: encode EXACTLY the "
                          "canvas" % (sps["width"], sps["height"], self.canvas[0], self.canvas[1]), conn="mdata",
                          cycle=self.cycle, key="sizemismatch")
        if sps["profile_idc"] != 66:
            rep.warning("SPS_PROFILE", "H.264 profile_idc %d (Baseline = 66 is the proven-safe default for every profile "
                        "but Morini)" % sps["profile_idc"], conn="mdata", cycle=self.cycle, key="profile")
        if sps["level_idc"] != 31:
            rep.warning("SPS_PROFILE", "H.264 level_idc %d (Android forces 3.1)" % sps["level_idc"], conn="mdata",
                        cycle=self.cycle, key="level")
        if sps.get("max_num_reorder_frames"):
            rep.violation("FRAME_B_SLICE", "SPS VUI max_num_reorder_frames=%d: frame reordering is not allowed (no PTS on "
                          "the wire)" % sps["max_num_reorder_frames"], conn="mdata", cycle=self.cycle, key="reorder")
        if sps["frame_cropping"]:
            rep.warning("SPS_CROP", "SPS uses frame cropping (coded %dx%d): the canvas is a multiple of 16, none expected"
                        % (sps["coded_width"], sps["coded_height"]), conn="mdata", cycle=self.cycle, key="crop")

    # ---------------------------------------------------------------- per-reply validators
    def validate_client_info(self, payload):
        obj, findings = validate_client_info_reply(payload, self.model.info)
        self.client_info_obj = obj
        self.run.report.findings(findings, conn="ctrl1", cycle=self.cycle)
        if obj is not None:
            self.run.note_identity(obj, self.cycle)

    def validate_time_sync(self, request, reply, kind):
        mode, findings = check_time_sync_reply(request, reply)
        self.clock_modes["%s→%s" % (kind, mode)] += 1
        self.run.report.findings(findings, conn="ctrl2", cycle=self.cycle, key_prefix="ts%s" % kind)

    def check_heartbeats(self):
        """Phone heartbeat cadence per :10922 socket (control-plane.md §10.3: first beat 2 s after the
        select, then every 2 s, on EVERY channel-selected socket)."""
        rep = self.run.report
        for name in ("ctrl1", "ctrl2"):
            c = self.conns.get(name)
            if c is None or c.select_acked_at is None:
                continue
            end = c.closed_at or self.now()
            life = end - c.select_acked_at
            beats = [t for t in c.phone_hb if t >= c.select_acked_at - 0.05]
            stats = {"beats": len(beats), "life_s": round(life, 2)}
            if beats:
                stats["first_after_select_s"] = round(beats[0] - c.select_acked_at, 3)
                gaps = [b - a for a, b in zip(beats, beats[1:])]
                tail = end - beats[-1]
                stats["max_gap_s"] = round(max(gaps + [beats[0] - c.select_acked_at, tail if c.closed_by != "phone" else 0]), 3)
                if gaps:
                    stats["mean_interval_s"] = round(statistics.mean(gaps), 3)
            c.hb_stats = stats
            if life < 4.0 or self.silent:
                continue
            if not beats:
                rep.violation("HEARTBEAT_MISSING", "the phone sent NO 0x70000000 heartbeat on %s in %.1f s (rule: every 2 s on "
                              "EVERY channel-selected :10922 socket; the US 800NK drops after ~7 s)" % (name, life),
                              conn=name, cycle=self.cycle)
                continue
            first = beats[0] - c.select_acked_at
            if first > 3.5:
                rep.warning("HEARTBEAT_FIRST", "first phone heartbeat on %s %.2f s after the select (expected ~2 s)" % (name, first),
                            conn=name, cycle=self.cycle)
            mg = stats["max_gap_s"]
            if mg > 6.5:
                rep.violation("HEARTBEAT_GAP", "phone heartbeat gap of %.2f s on %s (> 6.5 s; the US 800NK drops after ~7 s)" % (mg, name),
                              conn=name, cycle=self.cycle)
            elif mg > 3.5:
                rep.warning("HEARTBEAT_GAP", "phone heartbeat gap of %.2f s on %s (expected every 2 s)" % (mg, name),
                            conn=name, cycle=self.cycle)

    # ---------------------------------------------------------------- summary
    def summary(self):
        s = collections.OrderedDict()
        s["cycle"] = self.cycle
        s["phone_ip"] = self.phone_ip
        s["plan"] = {"stream_s": self.plan.stream_seconds, "stall_s": self.plan.stall_seconds,
                     "resume_s": self.plan.resume_seconds, "touch": self.plan.touch}
        s["probe_t"] = round(self.probe_t, 3)
        s["start_t"] = round(self.started_at, 3)
        s["end_t"] = round(self.ended_at or self.now(), 3)
        s["end_reason"] = self.end_reason
        if self.handshake_done_at:
            s["handshake_s"] = round(self.handshake_done_at - (self.callback_at or self.started_at), 3)
        if self.canvas:
            s["canvas"] = "%dx%d" % tuple(self.canvas)
        n = len(self.frames)
        s["frames"] = n
        if n:
            sizes = [f[1] for f in self.frames]
            lats = sorted(f[3] for f in self.frames)
            s["keyframes"] = sum(1 for f in self.frames if f[2] == "IDR")
            s["bytes"] = sum(sizes)
            s["avg_frame_bytes"] = int(statistics.mean(sizes))
            s["first_frame_after_113_s"] = round(self.frames[0][0] - self.media_ready_at, 3) if self.media_ready_at else None
            s["pull_latency_ms"] = {"p50": round(lats[len(lats) // 2] * 1000, 2),
                                    "p95": round(lats[min(len(lats) - 1, int(len(lats) * 0.95))] * 1000, 2),
                                    "max": round(lats[-1] * 1000, 2)}
            phases = []
            for label, a, b, cnt in self.pull_phases:
                phases.append({"label": label, "seconds": round(b - a, 2), "frames": cnt,
                               "fps": round(cnt / (b - a), 2) if b > a else None})
            s["pull_phases"] = phases
            if len(self.idr_times) >= 2:
                gaps = [b - a for a, b in zip(self.idr_times, self.idr_times[1:])]
                if self.stall_started_at is not None:
                    gaps = [g for g in gaps if g < self.plan.stall_seconds]
                if gaps:
                    s["idr_interval_s"] = {"mean": round(statistics.mean(gaps), 3), "max": round(max(gaps), 3)}
            if self.identical_idr:
                s["repeated_identical_idr"] = self.identical_idr
        if self.sps_info:
            s["sps"] = dict(self.sps_info, hex=self.sps_hex)
            s["pps_hex"] = self.pps_hex
        s["heartbeats"] = {name: getattr(c, "hb_stats", None) for name, c in self.conns.items() if c.kind == "cmdbase"}
        s["closed"] = {name: {"by": c.closed_by, "t": round(c.closed_at, 3) if c.closed_at else None}
                       for name, c in self.conns.items()}
        if self.clock_modes:
            s["clock_replies"] = dict(self.clock_modes)
        if self.plan.stall_seconds:
            s["stall"] = {"started_t": round(self.stall_started_at, 3) if self.stall_started_at else None,
                          "phone_dropped_after_s": round(self.stall_drop_after, 2) if self.stall_drop_after is not None else None,
                          "completed_without_drop": self.stall_completed}
        if self.touch_frames:
            s["touch_frames_sent"] = self.touch_frames
        return s


# =============================================================================================
# 12. The runner: probe server, scenario goals, summary
# =============================================================================================


class Runner(object):
    def __init__(self, args):
        self.args = args
        self.t0 = time.monotonic()
        self.wall0 = datetime.datetime.now()
        self.model = DASH_MODELS[args.dash]
        self.verbosity = args.verbosity
        self.transcript = Transcript(self, args.transcript, args.transcript_full_frames)
        self.report = Report(self)
        self.probes = []
        self.sessions = []
        self.session = None
        self.frames_total = 0
        self.identity = collections.OrderedDict()
        self.probe_queue = None
        self.stop_requested = False
        self.decode = None
        self.rejected = 0
        h264_path = args.out_h264
        self._tmp_h264 = None
        if not h264_path and args.decode:
            fd, h264_path = tempfile.mkstemp(prefix="fakedash-", suffix=".h264")
            os.close(fd)
            self._tmp_h264 = h264_path
        self.h264_path = h264_path
        self.h264 = H264Sink(self, h264_path, args.ffplay, "fakedash %s %dx%d" % (self.model.key, *self.model.canvas))

    def now(self):
        return time.monotonic() - self.t0

    def log(self, msg, level=1):
        if level <= self.verbosity:
            sys.stdout.write("[%8.3f] %s\n" % (self.now(), msg))
            sys.stdout.flush()

    # ------------------------------------------------------------------ identity across sessions
    def note_identity(self, obj, cycle):
        for key in ("phoneUUID", "pubkey", "phoneBrand", "phoneModel", "phoneOsVersion", "supportFunction"):
            val = obj.get(key)
            if key == "pubkey" and isinstance(val, str):
                val = "sha256:" + hashlib.sha256(val.encode()).hexdigest()[:16]
            if key in self.identity and self.identity[key] != val and key in ("phoneUUID", "pubkey"):
                self.report.warning("IDENTITY_CHANGED", "%s changed between sessions (%r → %r): Android keeps it for the "
                                    "whole process (§8.2, §9.2)" % (key, self.identity[key], val), cycle=cycle)
            self.identity[key] = val
        self.identity["supportScreenTouch"] = "supportScreenTouch" in obj.keys()

    # ------------------------------------------------------------------ probe server
    async def on_probe(self, reader, writer):
        peer = writer.get_extra_info("peername") or ("?", 0)
        ip = peer[0]
        t = self.now()
        rec = collections.OrderedDict([("t", round(t, 3)), ("ip", ip), ("port", peer[1])])
        self.probes.append(rec)
        try:
            try:
                raw = await asyncio.wait_for(reader.readexactly(16), 5.0)
            except asyncio.IncompleteReadError as e:
                if not e.partial:
                    rec["result"] = "closed without data (port scan?)"
                    self.log("[probe] %s:%d connected and closed without data (port scan?)" % (ip, peer[1]), level=1)
                    self.transcript.event(None, "probe", "connection from %s:%d closed without data" % (ip, peer[1]))
                    return
                rec["result"] = "truncated header"
                self.report.violation("PROBE_FORMAT", "probe from %s closed after %d header bytes" % (ip, len(e.partial)), conn="probe")
                return
            except asyncio.TimeoutError:
                rec["result"] = "no frame within 5 s"
                self.report.violation("PROBE_FORMAT", "probe connection from %s sent no frame within 5 s" % ip, conn="probe")
                return
            hdr = CmdBaseHeader(raw)
            if not hdr.magic_ok:
                self.transcript.frame(None, "probe", P2D, "cmdbase", hdr.cmd, b"", note="BAD MAGIC %s" % raw.hex())
                self.report.violation("PROBE_FORMAT", "probe header has a bad magic (%s); a dash drops it" % raw.hex(" "), conn="probe")
                rec["result"] = "bad magic"
                return
            n = min(hdr.payload_len, 4096)
            try:
                payload = await asyncio.wait_for(reader.readexactly(n), 5.0) if n else b""
            except (asyncio.IncompleteReadError, asyncio.TimeoutError):
                self.report.violation("PROBE_FORMAT", "probe payload truncated (expected %d bytes)" % n, conn="probe")
                rec["result"] = "truncated payload"
                return
            self.transcript.frame(None, "probe", P2D, "cmdbase", hdr.cmd, payload, note="probe from %s:%d" % (ip, peer[1]))
            findings = validate_probe(hdr, payload)
            self.report.findings(findings, conn="probe")
            if hdr.cmd != MDNS_RESPOND:
                rec["result"] = "not a probe"
                return
            accept = self.rejected >= self.args.reject_probes
            body = PROBE_ACK_PAYLOAD if accept else PROBE_REJECT_PAYLOAD
            if not accept:
                self.rejected += 1
            writer.write(encode_cmdbase(MDNS_RESPOND_ACK, body))
            self.transcript.frame(None, "probe", D2P, "cmdbase", MDNS_RESPOND_ACK, body,
                                  note="probe %s" % ("accepted" if accept else "rejected (--reject-probes)"))
            try:
                await asyncio.wait_for(writer.drain(), 2.0)
            except (asyncio.TimeoutError, OSError, ConnectionError):
                pass
            rec["result"] = "accepted" if accept else "rejected"
            rec["valid"] = not findings
            self.log("[probe] %s from %s:%d%s → 0x70000011 %s" % ("PROBE" if not findings else "probe (INVALID)", ip, peer[1],
                                                                   "" if not findings else " (%d findings)" % len(findings),
                                                                   body.decode()), level=0)
            if accept:
                self.queue_probe(ip, t, rec)
        finally:
            try:
                writer.close()
            except (OSError, RuntimeError):
                pass

    def queue_probe(self, ip, t, rec):
        s = self.session
        if s is not None and not s.ending:
            rec["during_session"] = s.cycle
            self.report.warning("PROBE_DURING_SESSION", "probe received while session %d is alive (never send a second "
                                "probe after one was accepted, §18.5); ignored" % s.cycle, conn="probe")
            return
        self.probe_queue.put_nowait((ip, t, rec))

    # ------------------------------------------------------------------ scenario goals
    def plan_for(self, cycle):
        a = self.args
        sc = a.scenario
        if sc == "stall":
            if not any(s.stall_started_at is not None for s in self.sessions):
                return Plan(a.seconds, stall_seconds=a.stall_seconds, resume_seconds=a.seconds, label="stream")
            return Plan(a.seconds, label="after-watchdog")
        return Plan(a.seconds, touch=(sc == "touch"), label="stream")

    def goal_reached(self):
        sc = self.args.scenario
        done = [s for s in self.sessions if s.completed]
        if sc == "reconnect":
            return len(done) >= self.args.cycles
        if sc == "stall":
            if not done:
                return False
            # either the stall completed without a drop, or a session completed after the watchdog drop
            return any(s.stall_completed for s in done) or any(s.plan.stall_seconds == 0 for s in done)
        return len(done) >= 1

    # ------------------------------------------------------------------ main
    async def main(self):
        a = self.args
        self.probe_queue = asyncio.Queue()
        try:
            server = await asyncio.start_server(self.on_probe, host=a.bind, port=a.probe_port, reuse_address=True)
        except OSError as e:
            self.log("ERROR: cannot listen on %s:%d: %s (another fakedash/dash running? run under the port lock)"
                     % (a.bind, a.probe_port, e), level=0)
            return 2
        self.log("fakedash %s — scenario %s, dash %s: %s" % (VERSION, a.scenario, self.model.key, self.model.title), level=0)
        self.log("waiting for the phone probe on %s:%d (connect-back to the probe source on ports %s)"
                 % (a.bind, a.probe_port, "/".join(str(p) for p in a.phone_ports)), level=0)
        bonjour = None
        if a.bonjour:
            ip = a.advertise_ip or guess_lan_ip(a.bind)
            m = self.model
            txt = [("huid", m.huid), ("huname", m.huname), ("channel", _opt_string(m.info, "channel") or str(m.model_id)),
                   ("flavor", _opt_string(m.info, "flavor") or "65540"), ("port", str(a.probe_port)), ("ip", ip)]
            bonjour = BonjourAdvertiser(self, a.advertise_name or m.huname, a.probe_port, txt)
            await asyncio.get_event_loop().run_in_executor(None, bonjour.start)
        deadline = self.t0 + a.max_runtime
        cycle = 0
        exit_code = 0
        try:
            while not self.goal_reached() and not self.stop_requested:
                if len(self.sessions) >= a.max_sessions:
                    self.report.violation("SESSIONS_EXHAUSTED", "%d sessions ended without reaching the scenario goal"
                                          % len(self.sessions))
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.report.violation("MAX_RUNTIME", "max runtime %.0f s reached before the scenario goal" % a.max_runtime)
                    break
                wait = min(a.probe_wait, remaining)
                last_end = self.sessions[-1].ended_at if self.sessions else None
                try:
                    ip, t, rec = await asyncio.wait_for(self.probe_queue.get(), wait)
                except asyncio.TimeoutError:
                    if last_end is None:
                        self.report.violation("NO_PROBE", "no valid probe from the phone within %.0f s" % wait)
                        exit_code = 3
                    else:
                        self.report.violation("NO_REPROBE", "the phone did not re-probe within %.0f s after session %d ended "
                                              "(reconnect loop: backoff 1 s, then :10930)" % (wait, len(self.sessions)))
                    break
                extra = 0
                while not self.probe_queue.empty():
                    ip, t, rec = self.probe_queue.get_nowait()
                    extra += 1
                if extra:
                    self.report.warning("PROBE_DUPLICATE", "%d extra accepted probes queued before the call-back" % extra, conn="probe")
                cycle += 1
                if last_end is not None:
                    rec["after_previous_session_s"] = round(t - last_end, 3)
                    self.log("re-probe %.2f s after session %d ended" % (t - last_end, cycle - 1), level=0)
                plan = self.plan_for(cycle)
                self.session = Session(self, cycle, a.connect_back_ip or ip, t, plan)
                try:
                    await self.session.run_session()
                finally:
                    self.sessions.append(self.session)
                    self.session = None
        except asyncio.CancelledError:
            self.stop_requested = True
            if self.session is not None and self.session not in self.sessions:
                self.sessions.append(self.session)
        finally:
            server.close()
            try:
                await asyncio.wait_for(server.wait_closed(), 2.0)
            except (asyncio.TimeoutError, OSError):
                pass
            if bonjour is not None:
                bonjour.stop()
            self.h264.close()
        return exit_code

    # ------------------------------------------------------------------ summary
    def finish(self, exit_code):
        a = self.args
        if a.decode and self.h264_path and self.frames_total:
            canvas = None
            for s in self.sessions:
                if s.canvas:
                    canvas = tuple(s.canvas)
            self.decode = decode_check(self.h264_path, canvas, self.frames_total)
            d = self.decode
            if "error" in d:
                self.report.warning("DECODE", d["error"])
            else:
                looks_real = any(s.sps_info for s in self.sessions)
                if not d.get("decodable"):
                    (self.report.violation if looks_real else self.report.warning)(
                        "DECODE", "the received stream does not decode cleanly: %d error lines, ffmpeg rc=%s; %s"
                        % (d.get("decode_error_lines", -1), d.get("decode_returncode"), "; ".join(d.get("decode_errors", [])[:3])))
                if canvas and d.get("width") and (d.get("width"), d.get("height")) != canvas:
                    self.report.violation("DECODE", "decoded size %sx%s != canvas %dx%d" % (d.get("width"), d.get("height"), *canvas))
                if d.get("decoded_frames") is not None and d.get("decoded_frames") != self.frames_total:
                    self.report.warning("DECODE", "ffprobe counted %s frames, %d received" % (d.get("decoded_frames"), self.frames_total))
        if self._tmp_h264 and not a.decode_keep:
            try:
                os.unlink(self._tmp_h264)
            except OSError:
                pass
        violations = self.report.count("violation")
        warnings = self.report.count("warning")
        summary = collections.OrderedDict()
        summary["tool"] = "fakedash %s" % VERSION
        summary["scenario"] = a.scenario
        summary["dash"] = self.model.key
        summary["dash_title"] = self.model.title
        summary["started"] = self.wall0.isoformat(timespec="seconds")
        summary["duration_s"] = round(self.now(), 3)
        summary["goal_reached"] = self.goal_reached()
        summary["result"] = "FAIL" if (violations or not self.goal_reached()) else "PASS"
        summary["violations"] = violations
        summary["warnings"] = warnings
        summary["expected_profile_android_default"] = expected_profile(self.model.info)
        summary["identity"] = self.identity
        summary["probes"] = self.probes
        summary["sessions"] = [s.summary() for s in self.sessions]
        summary["frames_total"] = self.frames_total
        if self.decode:
            summary["decode"] = self.decode
        summary["counts"] = collections.OrderedDict(sorted(self.transcript.counts.items()))
        summary["findings"] = self.report.items
        self.print_summary(summary)
        self.transcript.close(summary)
        if a.summary_json:
            with open(a.summary_json, "w", encoding="utf-8") as f:
                json.dump(summary, f, indent=2, ensure_ascii=False)
        if exit_code:
            return exit_code
        if a.strict and summary["result"] != "PASS":
            return 1
        return 0

    def print_summary(self, s):
        out = []
        w = out.append
        w("")
        w("=" * 100)
        w("fakedash summary — scenario %s, dash %s (%s)" % (s["scenario"], s["dash"], s["dash_title"]))
        w("duration %.1f s, %d probe connection(s), %d session(s), %d frame(s) received"
          % (s["duration_s"], len(s["probes"]), len(s["sessions"]), s["frames_total"]))
        ep = s["expected_profile_android_default"]
        w("Android default profile for this CLIENT_INFO: %s (supportFunction %d, supportScreenTouch %s)"
          % (ep["name"], ep["supportFunction"], "present" if ep["supportScreenTouch"] else "absent"))
        if s["identity"]:
            w("phone identity: " + ", ".join("%s=%s" % (k, v) for k, v in s["identity"].items()))
        for p in s["probes"]:
            w("probe t=%.3f from %s:%s → %s%s" % (p["t"], p["ip"], p["port"], p.get("result"),
                                                   (" (%.2f s after the previous session)" % p["after_previous_session_s"])
                                                   if "after_previous_session_s" in p else ""))
        for ss in s["sessions"]:
            w("-" * 100)
            w("session %d: phone %s, end: %s" % (ss["cycle"], ss["phone_ip"], ss["end_reason"]))
            line = []
            if "handshake_s" in ss:
                line.append("handshake %.3f s" % ss["handshake_s"])
            if "canvas" in ss:
                line.append("canvas %s" % ss["canvas"])
            line.append("frames %d" % ss["frames"])
            if ss["frames"]:
                line.append("keyframes %d" % ss["keyframes"])
                line.append("avg %d B" % ss["avg_frame_bytes"])
                if ss.get("first_frame_after_113_s") is not None:
                    line.append("first frame %.3f s after 113" % ss["first_frame_after_113_s"])
            w("  " + ", ".join(line))
            for ph in ss.get("pull_phases", []):
                w("  pulls [%s]: %d frames in %.2f s = %s fps" % (ph["label"], ph["frames"], ph["seconds"], ph["fps"]))
            if ss.get("pull_latency_ms"):
                pl = ss["pull_latency_ms"]
                w("  114→frame latency: p50 %.1f ms, p95 %.1f ms, max %.1f ms" % (pl["p50"], pl["p95"], pl["max"]))
            if ss.get("idr_interval_s"):
                w("  IDR interval: mean %.2f s, max %.2f s" % (ss["idr_interval_s"]["mean"], ss["idr_interval_s"]["max"]))
            if ss.get("sps"):
                sp = ss["sps"]
                w("  SPS: profile_idc %d, level %d, %dx%d, poc_type %d, refs %d, vui %s"
                  % (sp["profile_idc"], sp["level_idc"], sp["width"], sp["height"], sp["poc_type"], sp["max_num_ref_frames"], sp["vui"]))
            for name, hb in (ss.get("heartbeats") or {}).items():
                if hb:
                    w("  phone heartbeats %s: %d beats in %s s, first %s s after the select, mean interval %s s, max gap %s s"
                      % (name, hb["beats"], hb.get("life_s"), hb.get("first_after_select_s", "-"),
                         hb.get("mean_interval_s", "-"), hb.get("max_gap_s", "-")))
            if ss.get("clock_replies"):
                w("  0x10600→0x10601: " + ", ".join("%s ×%d" % kv for kv in ss["clock_replies"].items()))
            if ss.get("stall"):
                st = ss["stall"]
                if st["phone_dropped_after_s"] is not None:
                    w("  stall: the phone dropped the link %.2f s into the stall (watchdog)" % st["phone_dropped_after_s"])
                elif st["completed_without_drop"]:
                    w("  stall: the phone kept the link through the whole stall")
            if ss.get("touch_frames_sent"):
                w("  touch: %d cmd-32 frames sent" % ss["touch_frames_sent"])
            w("  closed: " + ", ".join("%s by %s" % (k, v["by"]) for k, v in ss["closed"].items()))
        if s.get("decode"):
            d = s["decode"]
            if "error" in d:
                w("decode: %s" % d["error"])
            else:
                w("decode: %s, %s %s level %s, %sx%s, %s/%s frames decoded, %s decoder error line(s)"
                  % ("DECODABLE" if d.get("decodable") else "NOT CLEAN", d.get("codec"), d.get("profile"), d.get("level"),
                     d.get("width"), d.get("height"), d.get("decoded_frames"), d.get("frames_received"), d.get("decode_error_lines")))
        w("-" * 100)
        w("frames per command (conn direction cmd name: count):")
        for k, v in s["counts"].items():
            w("  %-70s %d" % (k, v))
        w("-" * 100)
        for item in s["findings"]:
            if item["severity"] == "info":
                continue
            w("%-9s t=%-8s %s%s[%s] %s" % (item["severity"].upper(), item["t"], ("s%s " % item["cycle"]) if item["cycle"] else "",
                                          ("%s " % item["conn"]) if item["conn"] else "", item["rule"], item["message"])
              + (" (×%d)" % item["count"] if item["count"] > 1 else ""))
        w("RESULT: %s — %d violation(s), %d warning(s)%s" % (s["result"], s["violations"], s["warnings"],
                                                             "" if s["goal_reached"] else ", scenario goal NOT reached"))
        w("=" * 100)
        sys.stdout.write("\n".join(out) + "\n")
        sys.stdout.flush()


# =============================================================================================
# 13. CLI
# =============================================================================================


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        prog="fakedash.py",
        description="Independent PXC dash simulator: validates what a phone (OpenCfMoto iOS/Android) sends.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Scenarios: cfdl16, cfdl26, mt800 (handshake + streaming), reconnect (dash closes everything after "
               "--seconds, waits for a new probe, --cycles times), stall (stops pulling for --stall-seconds), touch "
               "(injects cmd 32 frames). Exit codes: 0 done, 1 violations with --strict, 2 setup error, 3 no probe.")
    p.add_argument("--scenario", choices=sorted(SCENARIOS), default="cfdl16")
    p.add_argument("--dash", choices=sorted(DASH_MODELS), default=None,
                   help="dash model (default per scenario: cfdl16; touch → mt800)")
    p.add_argument("--seconds", type=float, default=None, help="streaming seconds per session (default per scenario)")
    p.add_argument("--fps", type=float, default=20.0, help="114 pull rate (default 20)")
    p.add_argument("--cycles", type=int, default=2, help="reconnect scenario: sessions to complete (default 2)")
    p.add_argument("--stall-seconds", type=float, default=12.0, help="stall scenario: seconds without pulls (default 12)")
    p.add_argument("--bind", default="0.0.0.0", help="probe server address (default 0.0.0.0)")
    p.add_argument("--probe-port", type=int, default=PROBE_PORT)
    p.add_argument("--phone-ports", default="%d,%d,%d" % (PHONE_CTRL_PORT, PHONE_MCTRL_PORT, PHONE_MDATA_PORT),
                   help="phone ports to connect back to: ctrl,mediactrl,mediadata (default 10922,10921,10920)")
    p.add_argument("--connect-back-ip", default=None, help="connect back to this IP instead of the probe source")
    p.add_argument("--probe-wait", type=float, default=90.0, help="max seconds to wait for each (re)probe (default 90)")
    p.add_argument("--max-runtime", type=float, default=300.0, help="hard stop after this many seconds (default 300)")
    p.add_argument("--max-sessions", type=int, default=None, help="give up after this many sessions (default cycles+3)")
    p.add_argument("--reject-probes", type=int, default=0, help='answer the first N probes {"status":false}')
    p.add_argument("--callback-delay", type=float, default=0.2, help="seconds between probe ack and connect-back")
    p.add_argument("--step-delay", type=float, default=0.05, help="seconds between handshake steps")
    p.add_argument("--reply-timeout", type=float, default=3.0, help="seconds to wait for each reply (default 3)")
    p.add_argument("--pull-timeout", type=float, default=None, help="seconds to wait for a frame (default: the dash's 9 s)")
    p.add_argument("--hb-interval", type=float, default=2.0, help="dash heartbeat period on each :10922 socket")
    p.add_argument("--clock-interval", type=float, default=2.0, help="0x10600 period (default 2 s)")
    p.add_argument("--media-hb-interval", type=float, default=3.0, help="media heartbeat (64) period")
    p.add_argument("--clock-variants", choices=["none", "field", "all"], default="field",
                   help="0x10600 stamp variants sent first by the 2 s clock loop: field = short (39 B), T separator, "
                        "1970 (default); all = + empty, all-NUL")
    p.add_argument("--burst-mode", choices=["pipelined", "sequential"], default="pipelined",
                   help="CFDL26 notify burst: back-to-back (default) or wait for each ack")
    p.add_argument("--media-token", default="seq", help="token in dash media requests: 'seq' (1,2,3…) or an integer")
    p.add_argument("--no-dash-heartbeat", action="store_true", help="dash sends no 0x70000000 (US 800NK behaviour)")
    p.add_argument("--silence-teardown", type=float, default=0.0,
                   help="tear down after N s without any phone frame on a :10922 socket (800NK: 7)")
    p.add_argument("--start-h264", action="store_true", help="also send REQ_START_H264 (128) after 112 (never seen on bikes)")
    p.add_argument("--touch-fuzz", action="store_true", help="touch scenario: add an unknown action and a 7-byte body")
    p.add_argument("--lenient", action="store_true", help="continue after an unanswered gate (real dashes stall)")
    p.add_argument("--out-h264", default=None, help="write the received elementary stream to FILE")
    p.add_argument("--decode", action="store_true", help="check the received stream with ffprobe/ffmpeg at the end")
    p.add_argument("--decode-keep", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--ffplay", action="store_true", help="pipe the stream live to ffplay")
    p.add_argument("--transcript", default=None, help="write a JSON-lines transcript of every frame to FILE")
    p.add_argument("--transcript-full-frames", action="store_true", help="full hex of video frames in the transcript")
    p.add_argument("--summary-json", default=None, help="write the summary as JSON to FILE")
    p.add_argument("--bonjour", action="store_true", help="advertise _EasyConn._tcp (dns-sd / avahi-publish-service)")
    p.add_argument("--advertise-name", default=None, help="Bonjour service name (default: the dash HUName)")
    p.add_argument("--advertise-ip", default=None,
                   help="IPv4 for the Bonjour TXT `ip` key (default: this computer's LAN address, auto-detected)")
    p.add_argument("--strict", action="store_true", help="exit 1 if any violation (or the goal was not reached)")
    p.add_argument("-v", "--verbose", action="count", default=0)
    p.add_argument("-q", "--quiet", action="store_true")
    a = p.parse_args(argv)
    default_dash, default_seconds = SCENARIOS[a.scenario]
    a.dash = a.dash or default_dash
    a.seconds = default_seconds if a.seconds is None else a.seconds
    a.phone_ports = [int(x) for x in a.phone_ports.split(",")]
    if len(a.phone_ports) != 3:
        p.error("--phone-ports needs ctrl,mediactrl,mediadata")
    if a.max_sessions is None:
        a.max_sessions = (a.cycles if a.scenario == "reconnect" else 1) + 3
    a.verbosity = 0 if a.quiet else 1 + a.verbose
    if a.fps <= 0:
        p.error("--fps must be > 0")
    if a.media_token != "seq":
        try:
            int(a.media_token)
        except ValueError:
            p.error("--media-token must be 'seq' or an integer")
    return a


def main(argv=None):
    args = parse_args(argv)
    runner = Runner(args)
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    main_task = loop.create_task(runner.main())

    def _stop(*_):
        runner.log("interrupted — finishing", level=0)
        runner.stop_requested = True
        main_task.cancel()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _stop)
        except (NotImplementedError, RuntimeError, ValueError):
            pass
    try:
        code = loop.run_until_complete(main_task)
    except asyncio.CancelledError:
        code = 0
    finally:
        pending = [t for t in asyncio.all_tasks(loop) if not t.done()]
        for t in pending:
            t.cancel()
        if pending:
            loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
        loop.close()
    return runner.finish(code or 0)


if __name__ == "__main__":
    sys.exit(main())
