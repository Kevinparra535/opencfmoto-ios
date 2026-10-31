#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""phone_smoke: a MINIMAL spec-correct PHONE, only to self-test fakedash.py end to end.

This is NOT the app and not a reference implementation. It listens on :10922/:10921/:10920, sends
the probe to the dash's :10930, answers every control and media request the way
docs/spec/control-plane.md and media-video.md describe, serves H.264 access units from an Annex-B
file (SPS+PPS in front of every IDR, IDR first after every 112), heartbeats every 2 s on every
channel-selected :10922 socket, re-probes when every socket closed (backoff 1 s, 1.5 s, …), and
runs the 8 s no-frame watchdog. It signs the HUID with the spec's fixed TEST key (§9.5).

--bug NAME injects one known protocol bug (repeatable) so the simulator's validators can be
tested; see BUGS below. Python 3.8+, standard library only (imports the profile scoring from
fakedash.py next to it).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import signal
import socket
import struct
import sys
import threading
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fakedash  # noqa: E402  (profile scoring + ordered JSON objects only)

# control-plane.md §9.5 — TEST FIXTURE key (PKCS#1 RSAPrivateKey, base64). Never use in production.
FIXTURE_PKCS1 = (
    "MIICWwIBAAKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W8Jk3PPU6JW3drsgdK43RdlotOlGT"
    "5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt/UzHJWFwIDAQABAoGAHOSYxnBZCK29aQTmZ0JWiV7ESmrg"
    "DGj4eUQTZhYY3vfIhcWY6UKOKzQM8fMQUI4XBwgZKTJ3y4NbEjrlF/9jZjaP+DySrn+U5HnVkIr4Hye3I2tOqeJaWL4LGFr0fV4qaiJVl4XxL2JM"
    "I2RlMt+S9Cw3bPkim4hIJKySXLLbjQkCQQDCzsFwYRj0ddspxVD1hVUQRaB10YTCBYoCMMKyxmWHLQqNukzWTc8EYctsz4T1u4MQnDTc3t6iWdS1"
    "of3QKKoPAkEAtEHCivoWq2bVXCViThK+BP/sHEMDyXqTgyMuv1jNkUxpwUmCoptcMNrZMBdfBowrxSe4LBersIMU1ixM/++7eQJARsTVgP3FEwm9"
    "lG8Z+hd1z3N711FF6TYZ7LHKCSgJuhGiw9nqD/A0RGNCg0TgCGUWN/KHQbW1K0V3AITYr8YWAQJAS3E+X/Y9qK0YXUGUPELh3qvSAR4XJqszs+30"
    "sccT+lz14hzHHRFS62uc/OC7N71Q0GpITcP2aqDiBqVx8KhAWQJAP3c2sgSFzB3rmQCvLG06zxM5wNmeNUiW5Vo6ZBHL8XnoFyJlMIft/pie0smd"
    "qoAZ/yCMxa4GVMUGEmc9T5THxA==")

BUGS = {
    "bad-magic": "corrupt the magic of the CAR_CTRL ack (session-killing)",
    "no-heartbeat": "never send phone heartbeats 0x70000000",
    "key-order": "swap phoneBrand/phoneModel in the CLIENT_INFO reply",
    "bad-signature": "flip one byte of encryptedHUID",
    "pkcs1-pubkey": "send the PKCS#1 RSAPublicKey instead of the X.509 SPKI",
    "sync-true": "advertise supportSyncCorrectTime:true",
    "no-slash-escape": "serialize '/' without the \\/ escape (byte-parity warning only)",
    "token": "echo the request token in media replies",
    "touch-reply": "answer cmd 32 with a cmd 33",
    "no-sps": "strip SPS/PPS from every IDR after the first frame",
    "p-first": "start at a P-frame after 112 (no resynchronization)",
    "repeat-p": "send a P-frame twice in a row every 25 frames",
    "zero-frame": "answer one 114 with a zero-size frame",
    "clock-empty": "answer 0x10600 with an EMPTY 0x10601",
    "no-burst-ack": "never ack unknown control frames (CFDL26 burst stalls)",
    "probe-ios": 'probe with "phoneType":"iOS"',
    "rly17-raw": "reply RLY 17 with the unrounded size",
    "avcc": "send AVCC length-prefixed access units instead of Annex-B",
    "unsolicited-10601": "push an unsolicited 0x10601 after CLIENT_INFO",
}


def der_int(value):
    b = value.to_bytes((value.bit_length() + 8) // 8 or 1, "big")
    return b"\x02" + der_len(len(b)) + b


def der_len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def der_seq(body):
    return b"\x30" + der_len(len(body)) + body


def parse_private_key(b64):
    der = base64.b64decode(b64)
    pos = 0

    def tlv(buf, p):
        tag = buf[p]
        ln = buf[p + 1]
        p += 2
        if ln & 0x80:
            nb = ln & 0x7F
            ln = int.from_bytes(buf[p:p + nb], "big")
            p += nb
        return tag, buf[p:p + ln], p + ln

    _, seq, _ = tlv(der, pos)
    vals = []
    p = 0
    while p < len(seq) and len(vals) < 4:
        _, v, p = tlv(seq, p)
        vals.append(int.from_bytes(v, "big"))
    return vals[1], vals[2], vals[3]


def json_string(s, escape_slash=True):
    out = ['"']
    for ch in s:
        if ch in '"\\' or (ch == "/" and escape_slash):
            out.append("\\" + ch)
        elif ord(ch) < 0x20:
            out.append({"\t": "\\t", "\b": "\\b", "\n": "\\n", "\r": "\\r", "\f": "\\f"}.get(ch, "\\u%04x" % ord(ch)))
        else:
            out.append(ch)
    return "".join(out) + '"'


def json_obj(pairs, escape_slash=True):
    parts = []
    for k, v in pairs:
        if v is True or v is False:
            val = "true" if v else "false"
        elif isinstance(v, int):
            val = str(v)
        else:
            val = json_string(v, escape_slash)
        parts.append(json_string(k) + ":" + val)
    return "{" + ",".join(parts) + "}"


def frame(cmd, payload=b"", magic=None):
    total = 16 + len(payload)
    if magic is None:
        magic = (cmd ^ total) & 0xFFFFFFFF
    return struct.pack("<IIII", cmd & 0xFFFFFFFF, total, magic, 0) + payload


def reqbase(cmd_type, body=b"", token=0):
    return struct.pack("<hHi", cmd_type, len(body), token) + body


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("closed after %d/%d bytes" % (len(buf), n))
        buf += chunk
    return bytes(buf)


def load_access_units(path):
    """Annex-B file → [(au_bytes, is_idr)], 4-byte start codes, SPS+PPS in front of every IDR."""
    with open(path, "rb") as f:
        data = f.read()
    starts = []
    i = 0
    while True:
        p = data.find(b"\x00\x00\x01", i)
        if p < 0:
            break
        starts.append((p - 1 if p > 0 and data[p - 1] == 0 else p, p + 3))
        i = p + 3
    nals = []
    for k, (_, s) in enumerate(starts):
        e = starts[k + 1][0] if k + 1 < len(starts) else len(data)
        if e > s:
            nals.append(data[s:e])
    aus, cur, has_vcl = [], [], False
    sps = pps = None
    for nal in nals:
        t = nal[0] & 0x1F
        new_pic = t in (1, 5) and len(nal) > 1 and (nal[1] & 0x80)
        if has_vcl and (t in (6, 7, 8, 9) or new_pic):
            aus.append(cur)
            cur, has_vcl = [], False
        cur.append(nal)
        has_vcl = has_vcl or t in (1, 5)
        if t == 7:
            sps = nal
        elif t == 8:
            pps = nal
    if cur and has_vcl:
        aus.append(cur)
    out = []
    for au in aus:
        types = [n[0] & 0x1F for n in au]
        idr = 5 in types
        if idr and not (7 in types and 8 in types) and sps and pps:
            au = [sps, pps] + [n for n in au if (n[0] & 0x1F) not in (7, 8)]
        out.append((b"".join(b"\x00\x00\x00\x01" + n for n in au), idr))
    if not out or not out[0][1]:
        raise SystemExit("clip %s must start with an IDR" % path)
    return out


def to_avcc(au):
    out = bytearray()
    starts = []
    i = 0
    while True:
        p = au.find(b"\x00\x00\x01", i)
        if p < 0:
            break
        starts.append((p - 1 if p > 0 and au[p - 1] == 0 else p, p + 3))
        i = p + 3
    for k, (_, s) in enumerate(starts):
        e = starts[k + 1][0] if k + 1 < len(starts) else len(au)
        out += struct.pack(">I", e - s) + au[s:e]
    return bytes(out)


def strip_params(au):
    parts = []
    i = 0
    starts = []
    while True:
        p = au.find(b"\x00\x00\x00\x01", i)
        if p < 0:
            break
        starts.append(p)
        i = p + 4
    for k, s in enumerate(starts):
        e = starts[k + 1] if k + 1 < len(starts) else len(au)
        nal = au[s:e]
        if (nal[4] & 0x1F) not in (7, 8):
            parts.append(nal)
    return b"".join(parts)


class Phone(object):
    def __init__(self, a):
        self.a = a
        self.bugs = set(a.bug)
        self.t0 = time.monotonic()
        self.lock = threading.RLock()
        self.running = True
        self.live = set()
        self.listeners = []
        self.ever_connected = False
        self.reprobing = False
        self.frames = load_access_units(a.clip)
        self.cursor = 0
        self.served = 0
        self.frames_sent = 0
        self.last_frame_at = 0.0
        self.last_recovery = -1e9
        self.zero_sent = False
        self.prev_p = None
        self.uuid = str(uuid.uuid4())
        self.n, self.e, self.d = parse_private_key(FIXTURE_PKCS1)
        pkcs1 = der_seq(der_int(self.n) + der_int(self.e))
        self.pkcs1_b64 = base64.b64encode(pkcs1).decode()
        self.spki_b64 = base64.b64encode(fakedash.SPKI_RSA1024_PREFIX + pkcs1).decode()
        self.ports = a.ports

    def log(self, msg):
        if not self.a.quiet:
            sys.stdout.write("[phone %7.3f] %s\n" % (time.monotonic() - self.t0, msg))
            sys.stdout.flush()

    # ------------------------------------------------------------------ lifecycle
    def start(self):
        for port in self.ports:
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind((self.a.bind, port))
            srv.listen(50)
            self.listeners.append(srv)
            threading.Thread(target=self.accept_loop, args=(port, srv), daemon=True).start()
        self.log("listening on %s ports %s (BEFORE the probe)" % (self.a.bind, self.ports))
        threading.Thread(target=self.probe, args=(5,), daemon=True).start()
        threading.Thread(target=self.watchdog, daemon=True).start()

    def stop(self):
        self.running = False
        for s in self.listeners:
            try:
                s.close()
            except OSError:
                pass
        with self.lock:
            socks = list(self.live)
        for s in socks:
            self.kill(s)

    @staticmethod
    def kill(s):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            s.close()
        except OSError:
            pass

    def alive(self, s):
        with self.lock:
            return self.running and s in self.live

    def probe(self, attempts):
        payload = b'{"phoneType":"Android","packageName":"com.cfmoto.cfmotointernational"}'
        if "probe-ios" in self.bugs:
            payload = b'{"phoneType":"iOS","packageName":"com.cfmoto.cfmotointernational"}'
        for attempt in range(1, attempts + 1):
            if not self.running:
                return False
            try:
                s = socket.create_connection((self.a.dash, self.a.probe_port), timeout=3)
                s.settimeout(5)
                s.sendall(frame(0x70000010, payload))
                hdr = recv_exact(s, 16)
                cmd, total = struct.unpack_from("<Ii", hdr)
                body = recv_exact(s, max(total - 16, 0))
                s.close()
                ok = cmd == 0x70000011 and b"true" in body
                self.log("[PROBE] #%d -> %s:%d: %s %s" % (attempt, self.a.dash, self.a.probe_port, hex(cmd), body.decode("utf-8", "replace")))
                if ok:
                    return True
            except (OSError, EOFError) as e:
                self.log("[PROBE] #%d failed: %s" % (attempt, e))
            time.sleep(0.75 * attempt)
        return False

    def accept_loop(self, port, srv):
        while self.running:
            try:
                c, addr = srv.accept()
            except OSError:
                return
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with self.lock:
                self.live.add(c)
                self.ever_connected = True
            self.log("[:%d] <<< dash connected from %s:%d" % (port, addr[0], addr[1]))
            threading.Thread(target=self.conn_loop, args=(port, c), daemon=True).start()

    def conn_loop(self, port, c):
        wlock = threading.Lock()
        try:
            if port == self.ports[0]:
                self.control_loop(c, wlock)
            else:
                self.media_loop(c, wlock)
        except (OSError, EOFError) as e:
            self.log("[:%d] closed: %s" % (port, e))
        finally:
            self.kill(c)
            with self.lock:
                self.live.discard(c)
                empty = not self.live
                start = empty and self.running and self.ever_connected and not self.reprobing
                if start:
                    self.reprobing = True
            if start:
                threading.Thread(target=self.reconnect, daemon=True).start()

    def reconnect(self):
        attempts = 0
        try:
            while self.running and attempts < 20:
                with self.lock:
                    if self.live:
                        return
                attempts += 1
                backoff = min(0.5 + 0.5 * attempts, 4.0)
                self.log("[reconnect] link lost — re-probing (attempt %d) in %.1f s" % (attempts, backoff))
                time.sleep(backoff)
                with self.lock:
                    if self.live or not self.running:
                        return
                self.frames_sent = 0
                self.probe(2)
                time.sleep(2.5)
        finally:
            with self.lock:
                self.reprobing = False

    def watchdog(self):
        while self.running:
            time.sleep(self.a.watchdog_tick)
            now = time.monotonic()
            if (self.frames_sent > 0 and now - self.last_frame_at > 8.0 and now - self.last_recovery > 20.0):
                self.last_recovery = now
                self.log("[watchdog] no frame for %.1f s — dropping every bike socket" % (now - self.last_frame_at))
                with self.lock:
                    socks = list(self.live)
                for s in socks:
                    self.kill(s)

    # ------------------------------------------------------------------ control plane
    def send(self, c, wlock, data):
        with wlock:
            c.sendall(data)

    def heartbeat(self, c, wlock, label):
        while True:
            time.sleep(self.a.hb_interval)
            if not self.alive(c):
                return
            try:
                self.send(c, wlock, frame(0x70000000))
            except OSError:
                return

    def control_loop(self, c, wlock):
        while self.running:
            hdr = recv_exact(c, 16)
            cmd, total, magic, _ = struct.unpack("<IiII", hdr)
            if (cmd ^ (total & 0xFFFFFFFF)) != magic:
                raise EOFError("bad magic from the dash")
            payload = recv_exact(c, max(total - 16, 0)) if total > 16 else b""
            self.on_control(c, wlock, cmd, payload)

    def on_control(self, c, wlock, cmd, payload):
        if cmd in (0x10000, 0x20000):
            magic = 0xDEADBEEF if ("bad-magic" in self.bugs and cmd == 0x10000) else None
            self.send(c, wlock, frame(cmd + 1, b"", magic))
            if "no-heartbeat" not in self.bugs:
                threading.Thread(target=self.heartbeat, args=(c, wlock, hex(cmd)), daemon=True).start()
        elif cmd == 0x10010:
            reply = self.client_info_reply(payload)
            self.send(c, wlock, frame(0x10011, reply))
            if "unsolicited-10601" in self.bugs:
                self.send(c, wlock, frame(0x10601, b"\x00" * 45))
        elif cmd == 0x10690:
            self.send(c, wlock, frame(0x10691))
        elif cmd == 0x103E0:
            try:
                sn = json.loads(payload.decode("utf-8")).get("sn", "")
            except ValueError:
                sn = ""
            self.send(c, wlock, frame(0x103E1))
            result = json_obj([("isOk", True), ("errCode", 0), ("errMsg", ""), ("id", str(sn)), ("client_set", "easy_conn")])
            self.send(c, wlock, frame(0x201C0, result.encode("utf-8")))
        elif cmd == 0x70000000:
            self.send(c, wlock, frame(0x70000001))
        elif cmd in (0x70000001, 0x201C1):
            pass
        elif cmd == 0x10600:
            body = b"" if "clock-empty" in self.bugs else self.time_sync_ack(payload)
            self.send(c, wlock, frame(0x10601, body))
        elif cmd == 0x10450:
            self.send(c, wlock, frame(0x10451))
        else:
            if "no-burst-ack" not in self.bugs:
                self.send(c, wlock, frame(cmd + 1))

    def client_info_reply(self, payload):
        info = json.loads(payload.decode("utf-8"), object_pairs_hook=fakedash.JsonObject)
        huid = str(info.get("HUID") or info.get("huid") or "")
        prof = fakedash.expected_profile(info)
        enc = ""
        if huid:
            k = 128
            em = b"\x00\x01" + b"\xff" * (k - 3 - len(huid.encode())) + b"\x00" + huid.encode()
            sig = pow(int.from_bytes(em, "big"), self.d, self.n).to_bytes(k, "big")
            if "bad-signature" in self.bugs:
                sig = sig[:-1] + bytes([sig[-1] ^ 0x01])
            enc = base64.b64encode(sig).decode()
        brand_model = [("phoneBrand", "smoke"), ("phoneModel", "phone_smoke.py")]
        if "key-order" in self.bugs:
            brand_model.reverse()
        pairs = [("pxcVersion", "1.0.2"), ("phoneUUID", self.uuid)] + brand_model + [
            ("phoneOsVersion", "35"), ("phoneOs", "Android"), ("package", "com.cfmoto.cfmotointernational"),
            ("versionCode", 126), ("token", 0),
            ("pubkey", self.pkcs1_b64 if "pkcs1-pubkey" in self.bugs else self.spki_b64),
            ("encryptedHUID", enc), ("bluetoothName", "OpenCfMoto"), ("supportH264IFrame", True),
            ("supportFunction", prof["supportFunction"]), ("supportSyncCorrectTime", "sync-true" in self.bugs),
            ("appVersionFingerPrint", "opencfmoto-poc")]
        if prof["supportScreenTouch"]:
            pairs.append(("supportScreenTouch", True))
        return json_obj(pairs, escape_slash="no-slash-escape" not in self.bugs).encode("utf-8")

    @staticmethod
    def time_sync_ack(req):
        """control-plane.md §13.2 (echo unless blank / 1969-1971)."""
        n = max(45, len(req))
        out = bytearray(n)
        out[:len(req)] = req
        if len(req) < 16:
            out[0:16] = struct.pack("<iiii", -2, 0, 1, 0)
        stamp = req[16:16 + min(29, len(req) - 16)].decode("ascii", "replace").rstrip("\x00 ") if len(req) >= 16 else ""
        echo = len(req) >= 16 and stamp.strip() != ""
        if echo and len(stamp) >= 4 and stamp[:4].isdigit() and 1969 <= int(stamp[:4]) <= 1971 and \
                len(stamp) >= 19 and stamp[4] == "-" and stamp[10] in " T":
            echo = False
        if not echo:
            ms = int(time.time() * 1000)
            text = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ms / 1000.0)) + ".%03d000000" % (ms % 1000)
            out[16:45] = text.encode("ascii")
        return bytes(out)

    # ------------------------------------------------------------------ media plane
    def media_loop(self, c, wlock):
        while self.running:
            hdr = recv_exact(c, 8)
            ct, ln, tok = struct.unpack("<hHi", hdr)
            body = recv_exact(c, ln) if ln else b""
            self.on_media(c, wlock, ct, tok, body)

    def on_media(self, c, wlock, ct, tok, body):
        rt = tok if "token" in self.bugs else 0
        if ct == 16:
            w = struct.unpack_from("<H", body, 0)[0] if len(body) >= 2 else 0
            h = struct.unpack_from("<H", body, 2)[0] if len(body) >= 4 else 0
            enc = struct.unpack_from("<i", body, 8)[0] if len(body) >= 12 else 2
            ext = body[29] if len(body) >= 30 else 0
            if "rly17-raw" not in self.bugs:
                w, h = w & 0xFFF0, h & 0xFFF0
            self.send(c, wlock, reqbase(17, struct.pack("<iHHB", enc or 2, w, h, ext), rt))
        elif ct == 48:
            self.send(c, wlock, reqbase(49, struct.pack("<ii", 3, 1), rt))
        elif ct == 64:
            self.send(c, wlock, reqbase(65, b"", rt))
        elif ct == 96:
            self.send(c, wlock, reqbase(97, b'{"state":0}', rt))
        elif ct in (112, 128):
            with self.lock:
                if "p-first" in self.bugs:
                    self.cursor = 1
                else:
                    i = self.cursor
                    while not self.frames[i][1]:
                        i = (i + 1) % len(self.frames)
                    self.cursor = i
            self.send(c, wlock, reqbase(ct + 1, b"", rt))
        elif ct == 114:
            self.serve_frame(c, wlock)
        elif ct == 32:
            if "touch-reply" in self.bugs:
                self.send(c, wlock, reqbase(33, b"", rt))
        # anything else: logged by nobody, never answered

    def serve_frame(self, c, wlock):
        with self.lock:
            self.served += 1
            if "zero-frame" in self.bugs and not self.zero_sent and self.served == 10:
                self.zero_sent = True
                au = b""
            elif "repeat-p" in self.bugs and self.served % 25 == 0 and self.prev_p is not None:
                au = self.prev_p
            else:
                au, idr = self.frames[self.cursor]
                self.cursor = (self.cursor + 1) % len(self.frames)
                if not idr:
                    self.prev_p = au
                if "no-sps" in self.bugs and idr and self.served > 1:
                    au = strip_params(au)
            if "avcc" in self.bugs and au:
                au = to_avcc(au)
        self.send(c, wlock, struct.pack("<i", len(au)) + au)
        self.frames_sent += 1
        self.last_frame_at = time.monotonic()


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                epilog="bugs: " + "; ".join("%s = %s" % kv for kv in BUGS.items()))
    p.add_argument("--dash", default="127.0.0.1", help="dash (fakedash) address for the :10930 probe")
    p.add_argument("--probe-port", type=int, default=10930)
    p.add_argument("--bind", default="127.0.0.1", help="local address for the three listeners")
    p.add_argument("--ports", default="10922,10921,10920", help="ctrl,mediactrl,mediadata listener ports")
    p.add_argument("--clip", required=True, help="Annex-B .h264 file to serve (must start with an IDR)")
    p.add_argument("--duration", type=float, default=60.0, help="exit after N seconds")
    p.add_argument("--hb-interval", type=float, default=2.0)
    p.add_argument("--watchdog-tick", type=float, default=5.0, help="watchdog tick (Android: 5 s)")
    p.add_argument("--bug", action="append", default=[], choices=sorted(BUGS))
    p.add_argument("-q", "--quiet", action="store_true")
    a = p.parse_args(argv)
    a.ports = [int(x) for x in a.ports.split(",")]
    phone = Phone(a)

    def _term(*_):
        phone.stop()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _term)
    phone.start()
    try:
        time.sleep(a.duration)
    except KeyboardInterrupt:
        pass
    phone.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
