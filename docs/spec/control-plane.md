# PXC Control Plane, Bike Profiles, RSA Identity and Dash Clock: iOS implementation spec

Source of truth: OpenCfMoto Android **2.0.18** (`versionCode 77`, `app/build.gradle.kts:22-23`), repo
HEAD `0abbe2a` (2026-09-15). This spec is written so that a Swift engineer never has to read the
Kotlin. Everything needed to re-implement the control plane (TCP :10922 + the :10930 probe), the
bike-profile selection, the RSA identity, and the dash-clock frames is here, with exact constants,
byte layouts, JSON templates and test vectors.

Out of scope here (covered by other specs): the media plane on :10921/:10920 (ReqBase framing,
config-capture, frame pull, dash touch cmdType 32), H.264 encoding, Wi-Fi joining/QR parsing,
Android Auto (`aa/`), handlebar buttons (Bluetooth AVRCP).

---

## 0. Conventions

**Citations.** `File.kt:line` means `app/src/main/java/dev/zanderp/opencfmoto/File.kt` in the
Android repo. Tests are cited as `test/File.kt:line` (= `app/src/test/java/dev/zanderp/opencfmoto/`).
Docs are cited as `docs/01 §n` (`docs/01-REVERSE-ENGINEERING.md`) etc., or `01-REVERSE-ENGINEERING.md:line`.

**Status tags** (every non-trivial fact carries one):

| Tag | Meaning |
|---|---|
| **VERIFIED-HW** | `docs/01` (declared "verified ground truth") or a field log quoted in code/docs says this was confirmed on a real dash. |
| **VERIFIED-CODE** | The shipping 2.0.18 code path with default settings. Field-proven only to the extent that the app works on the bikes listed in `docs/SUPPORTED-BIKES.md`. |
| **INFERRED** | Naming/semantics derived from decompiled SDK names, comments, or analysis in this spec; never explicitly confirmed. |
| **EXPERIMENTAL** | Behind a tester toggle (Clock lab, BT clock), flagged experimental in code/docs, or only used for "in progress" dashes. |
| **DERIVED** | Test vector or example computed for this spec by re-running the exact Kotlin algorithm (Java/Python re-implementation, cross-checked). Not a field capture. |

**Endianness.** Every integer in a PXC control frame is **little-endian**. JSON payloads are UTF-8.

**Directions.** B→P = bike (dash/head unit, "HU") to phone; P→B = phone to bike.

---

## 1. Topology and ports

The **phone is the TCP server**. It opens three listeners, sends one short probe to the bike, and
the bike then **connects back** and drives the whole handshake. **VERIFIED-HW** (`docs/01 §2`,
`EasyConnProber.kt:24-34`).

| Port | Owner | Framing | Role | Source |
|---:|---|---|---|---|
| 10922 | phone listens | CmdBaseHead (16-byte header) | PXC control: channel selects, CLIENT_INFO, CHECK_SN, heartbeats, notify frames, clock | `EasyConnProber.kt:42`, `docs/01 §2` |
| 10921 | phone listens | ReqBase (8-byte) | media control (other spec) | `EasyConnProber.kt:41` |
| 10920 | phone listens | ReqBase / raw | media data (other spec) | `EasyConnProber.kt:40` |
| 10930 | bike listens | CmdBaseHead | probe ("mDNS respond") endpoint; phone connects out once per (re)probe | `EasyConnProber.kt:43` |

Listener details (**VERIFIED-CODE**, `EasyConnProber.kt:189-219`):

- Order of creation: `[10922, 10921, 10920]` (`EasyConnProber.kt:45`).
- `SO_REUSEADDR` is set **before** `bind` (`EasyConnProber.kt:198`). Reason given: after Stop→Connect
  the bike's just-closed call-back sockets leave the ports in TIME_WAIT; without reuse the rebind fails
  with EADDRINUSE and the dash stays blank (`EasyConnProber.kt:190-193`).
- Bound to the phone's **bike-network IPv4 address**, not the wildcard, backlog **50**
  (`EasyConnProber.kt:199`).
- Listeners are opened **before** the probe is sent (`EasyConnProber.kt:189`).
- If **any** of the three binds fails, the session aborts with
  `Phase.ERROR "close the official CFMoto app, then reconnect"` (the official CFMoto/EasyConnect app
  binds the same ports and the bike would call it back instead) (`EasyConnProber.kt:209-219`).
- Listeners stay open for the whole session; reconnects only re-send the probe
  (`EasyConnProber.kt:115-118`).
- Framing is chosen by the **local port** the bike connected to: 10922 → CmdBaseHead loop, anything
  else → media loop (`EasyConnProber.kt:668-682`).
- Accepted sockets: read timeout **none** (`soTimeout = 0`), `TCP_NODELAY = true`
  (`EasyConnProber.kt:664-665`).

Typical addresses (**VERIFIED-HW**):

| Transport | Bike (gateway) | Phone | Source |
|---|---|---|---|
| Wi-Fi AP (CFDL16, 800MT AP) | `192.168.0.1` | `192.168.0.50/24` | `docs/01 §2` (`01-REVERSE-ENGINEERING.md:42-43`) |
| Wi-Fi Direct group owner (CFDL26 1000 MT-X, SSID `DIRECT-CF-CFMOTO-805120`, pwd `12345678`): joined like a normal AP via `WifiNetworkSpecifier`, no code change needed | `192.168.49.1` | `192.168.49.132/24` | `docs/01 §7.1` |
| Wi-Fi Direct GO that refuses a normal join (e.g. CL-C450; QR `action` bit 3): Android uses the Wi-Fi P2P API and binds sockets to its `p2p-*` interface IP | `192.168.49.1` | `192.168.49.x` | `BikeWifiP2p.kt:7-24` |
| Yunmo SoftAP (Morini X-Cape 1200) | `192.168.4.1` | DHCP | `YunmoFrame.kt:26` |

How Android finds the two addresses (**VERIFIED-CODE**):

- Phone IP: first IPv4 address of the bike `Network`'s link addresses, else the first non-loopback
  IPv4 address of any up interface (`EasyConnProber.kt:1019-1035`).
- Bike IP (`EasyConnProber.kt:966-995`), in order:
  1. the default-route gateway of the bike network;
  2. if there is none (seen on Samsung/Android 16 Wi-Fi Direct), the **`.1` host of our own subnet**
     (`(ip & mask) | 1`; skipped if we already are `.1`) (`EasyConnProber.kt:998-1017`);
  3. the first IPv4 DNS server.
- On the Wi-Fi Direct path the caller can force both (`gatewayOverride`, `bindIpOverride`)
  (`EasyConnProber.kt:126-135`, `BikeLink.kt:80-88`).

The probe JSON carries **no** phone IP or port, so the bike must call back the **source address of
the probe connection** on the fixed ports. **INFERRED** (consistent with every log, never stated
explicitly). Consequence: the probe must leave from the same interface/IP the listeners are bound to.

---

## 2. CmdBaseHead frame codec

Mirrors `net.easyconn.carman.sdk_communication.CmdBaseHead` from the decompiled SDK
(`PxcFrame.kt:8-17`). **VERIFIED-HW** both directions (`docs/01 §3`, `01-REVERSE-ENGINEERING.md:56-68`).

```
offset  size  type        field
0       4     int32 LE    cmd
4       4     int32 LE    totalLen   = 16 + payload.count
8       4     int32 LE    magic      = cmd XOR totalLen
12      4     -           reserved   = 0 (written as zero, ignored on read)
16      n     bytes       payload    n = totalLen - 16 (JSON UTF-8, binary, or empty)
```

### 2.1 Encode (`PxcFrame.kt:22-34`)

```kotlin
val totalLen = 16 + payload.size
header.putInt(0, cmd); header.putInt(4, totalLen); header.putInt(8, cmd xor totalLen)  // LE
synchronized(out) { out.write(header); if (payload.isNotEmpty()) out.write(payload); out.flush() }
```

Header and payload are written under one lock on the socket's output stream and flushed, so the
heartbeat thread and the reply path can never interleave half frames (`PxcFrame.kt:29-33`,
`EasyConnProber.kt:1053-1055`). **VERIFIED-CODE**

### 2.2 Decode (`PxcFrame.kt:147-164`)

1. Read exactly 16 bytes. EOF before 16 bytes returns `null` (no exception) and the reader treats it
   as "bike closed" (`PxcFrame.kt:150`, `EasyConnProber.kt:675`). A `read()` returning `<= 0` is EOF
   (`PxcFrame.kt:137-145`).
2. `cmd`, `totalLen`, `magic` are read as **signed** Int32 LE (`PxcFrame.kt:151-154`).
3. **Magic check:** if `(cmd XOR totalLen) != magic`, throw `"bad magic: cmd=… len=… magic=…"`
   (`PxcFrame.kt:155-157`). The control reader logs `frame error` and **closes that socket**
   (`EasyConnProber.kt:673-674`). In the probe path the exception counts as a failed attempt
   (`EasyConnProber.kt:532-534`).
4. `payloadLen = max(totalLen - 16, 0)` (`PxcFrame.kt:158`). So a frame with `totalLen < 16`
   (even negative) and a matching magic is **accepted** with an empty payload.
5. Read `payloadLen` bytes; EOF first → throw `"short payload, expected=N"` → socket closed
   (`PxcFrame.kt:160-162`).
6. Reserved bytes 12..15 are not validated.

**There is no maximum-length guard.** A `totalLen` near `2^31-1` makes the reader allocate ~2 GiB;
the resulting `OutOfMemoryError` is not an `Exception`, so it would kill the reader thread.
**VERIFIED-CODE** (absence). iOS must add a cap (§18.2).

Payload text is decoded as UTF-8 (malformed bytes become U+FFFD; the `catch` is dead code)
(`PxcHandshake.kt:204-205`).

Error handling around the dispatcher (`EasyConnProber.kt:670-678`): a frame-level error (bad magic /
short payload) closes the socket; an exception thrown **inside a handler** (e.g. a write failure) is
logged as `handler error` and the read loop **continues** with the next frame.

### 2.3 Frame vectors (DERIVED, byte-exact output of the Kotlin encoder)

```
Probe 0x70000010, payload {"phoneType":"Android","packageName":"com.cfmoto.cfmotointernational"} (70 B)
totalLen=86 (0x56) magic=0x70000046
10 00 00 70 56 00 00 00 46 00 00 70 00 00 00 00
7b 22 70 68 6f 6e 65 54 79 70 65 22 3a 22 41 6e
64 72 6f 69 64 22 2c 22 70 61 63 6b 61 67 65 4e
61 6d 65 22 3a 22 63 6f 6d 2e 63 66 6d 6f 74 6f
2e 63 66 6d 6f 74 6f 69 6e 74 65 72 6e 61 74 69
6f 6e 61 6c 22 7d

Probe ack 0x70000011, payload {"status":true} (15 B), totalLen=31 (0x1f) magic=0x7000000e
11 00 00 70 1f 00 00 00 0e 00 00 70 00 00 00 00
7b 22 73 74 61 74 75 73 22 3a 74 72 75 65 7d

CAR_CTRL select 0x10000 (empty):   00 00 01 00 10 00 00 00 10 00 01 00 00 00 00 00
CAR_CTRL ack    0x10001 (empty):   01 00 01 00 10 00 00 00 11 00 01 00 00 00 00 00
CAR_DATA select 0x20000 (empty):   00 00 02 00 10 00 00 00 10 00 02 00 00 00 00 00
CAR_DATA ack    0x20001 (empty):   01 00 02 00 10 00 00 00 11 00 02 00 00 00 00 00
Heartbeat     0x70000000 (empty):  00 00 00 70 10 00 00 00 10 00 00 70 00 00 00 00
Heartbeat ack 0x70000001 (empty):  01 00 00 70 10 00 00 00 11 00 00 70 00 00 00 00

QUERY_SPEED 0x10690 {"usbSpeed":0,"wifiSpeed":0} (28 B), totalLen=44 (0x2c) magic=0x106bc
90 06 01 00 2c 00 00 00 bc 06 01 00 00 00 00 00
7b 22 75 73 62 53 70 65 65 64 22 3a 30 2c 22 77
69 66 69 53 70 65 65 64 22 3a 30 7d
QUERY_SPEED reply 0x10691 (empty): 91 06 01 00 10 00 00 00 81 06 01 00 00 00 00 00

CHECK_SN 0x103e0 {"client_set":"easy_conn","sn":"DSXXZMHNFV3DEXEBB3PZ2"} (55 B), totalLen=71 magic=0x103a7
e0 03 01 00 47 00 00 00 a7 03 01 00 00 00 00 00
7b 22 63 6c 69 65 6e 74 5f 73 65 74 22 3a 22 65
61 73 79 5f 63 6f 6e 6e 22 2c 22 73 6e 22 3a 22
44 53 58 58 5a 4d 48 4e 46 56 33 44 45 58 45 42
42 33 50 5a 32 22 7d
CHECK_SN ack 0x103e1 (empty):      e1 03 01 00 10 00 00 00 f1 03 01 00 00 00 00 00

CHECK_SN_RESULT 0x201c0 (91 B), totalLen=107 (0x6b) magic=0x201ab
payload {"isOk":true,"errCode":0,"errMsg":"","id":"DSXXZMHNFV3DEXEBB3PZ2","client_set":"easy_conn"}
c0 01 02 00 6b 00 00 00 ab 01 02 00 00 00 00 00
7b 22 69 73 4f 6b 22 3a 74 72 75 65 2c 22 65 72
72 43 6f 64 65 22 3a 30 2c 22 65 72 72 4d 73 67
22 3a 22 22 2c 22 69 64 22 3a 22 44 53 58 58 5a
4d 48 4e 46 56 33 44 45 58 45 42 42 33 50 5a 32
22 2c 22 63 6c 69 65 6e 74 5f 73 65 74 22 3a 22
65 61 73 79 5f 63 6f 6e 6e 22 7d
CHECK_SN_RESULT ack 0x201c1 (B→P): c1 01 02 00 10 00 00 00 d1 01 02 00 00 00 00 00

HU_QUERY_TIME 0x10450 (empty):     50 04 01 00 10 00 00 00 40 04 01 00 00 00 00 00
HU_QUERY_TIME_ACK 0x10451 (empty): 51 04 01 00 10 00 00 00 41 04 01 00 00 00 00 00
generic ack 0x103a1 (empty):       a1 03 01 00 10 00 00 00 b1 03 01 00 00 00 00 00
generic ack 0x10781 (empty):       81 07 01 00 10 00 00 00 91 07 01 00 00 00 00 00

NEGATIVE (must be rejected, magic byte flipped):
00 00 01 00 10 00 00 00 11 00 01 00 00 00 00 00   -> 0x10000 ^ 0x10 = 0x10010, magic says 0x10011
```

The sample `sn` and payloads come from `docs/01 §3` (`01-REVERSE-ENGINEERING.md:89-93`); the HU_TIME_SYNC
vectors are in §13.

---

## 3. Command catalogue

Naming pattern (**INFERRED** from the constants): `0x1xxxx` = car-initiated requests ("C2P", e.g.
`ECP_C2P_QUERY_TIME`), `0x2xxxx` = phone-initiated ("P2C", e.g. `ECP_P2C_CHECK_SN_RESULT`), `0x3xxxx`
= "R2A", `0x4xxxx` = "A2R", `0x7000000x` = transport level. **A reply is the request cmd + 1**, usually
with an empty payload. **VERIFIED-HW** for every pair actually exercised (`docs/01 §7.2`).

### 3.1 Commands with explicit handling in the shipping code

| cmd | Name (code) | Dir | Payload | Phone action | Status | Source |
|---|---|---|---|---|---|---|
| `0x70000010` | MDNS_RESPOND | P→B on :10930 | probe JSON (§4) | sent by phone | VERIFIED-HW | `PxcFrame.kt:60`, `EasyConnProber.kt:504-507` |
| `0x70000011` | MDNS_RESPOND_ACK | B→P | `{"status":true}` / `{"status":false}` | accept if body contains `true`, then close | VERIFIED-HW | `PxcFrame.kt:61`, `EasyConnProber.kt:515` |
| `0x10000` (65536) | CHANNEL_CAR_CTRL | B→P, first frame of a :10922 conn | empty | reply `0x10001` empty, start heartbeat on this socket | VERIFIED-HW | `PxcFrame.kt:40`, `PxcHandshake.kt:49-53` |
| `0x20000` (131072) | CHANNEL_CAR_DATA | B→P, first frame of 2nd :10922 conn | empty | reply `0x20001` empty, start heartbeat | VERIFIED-HW | `PxcFrame.kt:41`, `PxcHandshake.kt:54-58` |
| `0x10010` (65552) | CLIENT_INFO | B→P | bike JSON (§7) | reply `0x10011` with phone JSON (§8) | VERIFIED-HW | `PxcFrame.kt:93`, `PxcHandshake.kt:138-183` |
| `0x10011` | CLIENT_INFO_RLY | P→B | phone JSON | — | VERIFIED-HW | `PxcFrame.kt:64` |
| `0x10690` | QUERY_SPEED | B→P | `{"usbSpeed":0,"wifiSpeed":0}` | reply `0x10691` **empty** | VERIFIED-HW | `PxcFrame.kt:65-66`, `PxcHandshake.kt:60-63` |
| `0x103e0` | CHECK_SN | B→P | `{"client_set":"easy_conn","sn":"…"}` | reply `0x103e1` empty, then send `0x201c0` | VERIFIED-HW | `PxcFrame.kt:67-69`, `PxcHandshake.kt:185-201` |
| `0x201c0` | CHECK_SN_RESULT | P→B | result JSON (§10.2) | — | VERIFIED-HW | `PxcFrame.kt:69` |
| `0x201c1` | (CHECK_SN_RESULT ack) | B→P | empty | consume silently | VERIFIED-CODE | `PxcHandshake.kt:68-71` |
| `0x70000000` | HEARTBEAT | both | empty | on receive: reply `0x70000001`; also sent by phone every 2 s per :10922 socket | VERIFIED-HW | `PxcFrame.kt:62`, `PxcHandshake.kt:65-67`, `EasyConnProber.kt:1057-1079` |
| `0x70000001` | HEARTBEAT_ACK | both | empty | consume silently | VERIFIED-CODE | `PxcFrame.kt:63`, `PxcHandshake.kt:68` |
| `0x10600` | HU_TIME_SYNC | B→P, about every 2 s | 16-byte LE header + time string (§13.1) | reply `0x10601` **with a body** (echo/phone) | VERIFIED-CODE (field-tuned) | `PxcFrame.kt:86-87`, `PxcHandshake.kt:92-104` |
| `0x10450` | HU_QUERY_TIME (`ECP_C2P_QUERY_TIME`) | B→P | usually empty | reply `0x10451` **empty** by default (§13.4) | VERIFIED-CODE default; JSON modes EXPERIMENTAL | `PxcFrame.kt:88-90`, `PxcHandshake.kt:106-136` |

### 3.2 Named but handled only by the generic "cmd + 1" ack (§11)

| cmd | Name (code) | Dir | Payload seen | Phone reply | Status | Source |
|---|---|---|---|---|---|---|
| `0x10780` | LOG_REPORT (CFDL26) | B→P on CAR_DATA | `{"log":"…mdns success…"}` | `0x10781` empty | VERIFIED-HW (code comment still calls the ack "experimental", `PxcFrame.kt:70-72`) | `PxcFrame.kt:73-74`, `docs/01 §7.2` |
| `0x103a0` | OTA_FTP_INFO | B→P | `{port:11021,userName:"carbit_ec_ftp_ota",pwd:"…"}` (doc shorthand; password redacted in this spec) | `0x103a1` empty | VERIFIED-HW | `PxcFrame.kt:77`, `docs/01 §7.2, §7.4` |
| `0x10020` | MEDIA_FEATURE_CFG | B→P | `{music,talkie,tts,vr,autoChangeToBT}` feature flags | `0x10021` empty | VERIFIED-HW | `PxcFrame.kt:78`, `docs/01 §7.2` |
| `0x104a0` | SOCK_SERVER_INFO | B→P on CAR_DATA | `{ "ctrlPort": 11026, "dataPort": 11025, "userName": "carbit_ota_user", "pwd": "<redacted>" }` | `0x104a1` empty | VERIFIED-HW | `PxcFrame.kt:79-82`, `docs/RE-VEHICLE-TELEMETRY.md:58-62` |
| `0x30040` (196672) | SCREEN_TOUCH ("R2A") | ? | ? | `0x30041` (generic) | INFERRED, never seen on control | `PxcFrame.kt:98`, `BikeProfile.kt:574` |
| `0x20010` | REMOTE_AUTH_RESULT (P2C) | — | — | never sent | INFERRED | `PxcFrame.kt:94` |
| `0x30010` | AUTH_HUID (R2A) | — | — | generic ack if received | INFERRED | `PxcFrame.kt:95` |
| `0x30020` | MIRROR_START (R2A) | — | — | generic ack if received | INFERRED | `PxcFrame.kt:96` |
| `0x30030` | MIRROR_STOP (R2A) | — | — | generic ack if received | INFERRED | `PxcFrame.kt:97` |
| `0x60004110` | RVINFO (R2A) | — | a screen event (`sendRvInfo(ECPAppScreenEvent*)` in `librvserver.so`), not vehicle info | generic ack if received | INFERRED | `PxcFrame.kt:99`, `docs/RE-VEHICLE-TELEMETRY.md:43-44` |
| `0x40010` | SCREEN_EVENT (A2R) | — | — | never sent | INFERRED | `PxcFrame.kt:100` |
| `0x40020` | START_OVERLAY (A2R) | — | — | never sent | INFERRED | `PxcFrame.kt:101` |
| `0x30000` / `0x40000` | CHANNEL_RV_CTRL / RV_DATA ("Carbit RV, regular bike") | B→P | empty | generic ack `0x30001`/`0x40001` (no heartbeat started) | INFERRED, never seen | `PxcFrame.kt:42-43` |

### 3.3 Unnamed notify frames observed on real dashes (all acked cmd + 1, empty)

From `docs/01 §7.2` (CFDL26, CAR_DATA connection) and field notes. **VERIFIED-HW**

| cmd | Payload | Notes |
|---|---|---|
| `0x10040` | `{maxNaviIcon:161,supportFunction:0}` | hints at a native turn-icon feature (§14) |
| `0x10750` | empty | repeats periodically |
| `0x10430` | empty | |
| `0x10460` | `{bluetooth:4129}` | 4129 = `0x1021`; meaning unknown (INFERRED: BT capability bits) |
| `0x10470` | JSON voice-command grammar (Chinese regexes for music control, `"cnt":9`) | US 800NK, 450NK (`BikeProfile.kt:457`, `docs/RE-VEHICLE-TELEMETRY.md:41-43`) |

### 3.4 MCULite / ECTinyPlus constants (not used by any supported dash)

The SDK uses Android resource IDs as opaque cmd literals (`PxcFrame.kt:44-56`). The handoff doc says the
CFMoto dashes speak standard Car PXC with JSON CLIENT_INFO, **not** this protobuf variant
(`docs/00-README-HANDOFF.md:43-44`). Values below are the public `android.R` constants these names
resolve to: **INFERRED** (resolved from the platform constants, not printed anywhere in the repo).

| Name | android.R symbol | Value |
|---|---|---|
| CHANNEL_MCULITE_CTRL | `drawable.alert_dark_frame` | `0x01080000` |
| CHANNEL_MCULITE_DATA | `layout.activity_list_item` | `0x01090000` |
| CHANNEL_MCU_CTRL | `color.darker_gray` | `0x01060000` |
| CHANNEL_MCU_DATA | `array.emailAddressTypes` | `0x01070000` |
| MCU_CLIENT_INFO | `drawable.checkbox_on_background` | `0x01080010` |
| MCU_START_MIRROR | `drawable.ic_lock_idle_low_battery` | `0x01080020` |
| MCU_CHECK_OTA | `drawable.ic_lock_power_off` | `0x01080030` |
| MCU_START_OTA | `drawable.ic_menu_help` | `0x01080040` |

If any of these arrives it simply gets the generic cmd+1 ack. iOS: define them for logging only.

---

## 4. Discovery and the :10930 probe

### 4.1 Probe payload

Exactly one payload for **every** brand and profile (no variants; the profile is not known yet).
Built by string concatenation, no JSON library (`EasyConnProber.kt:590-591`, `SPOOFED_PACKAGE` at
`EasyConnProber.kt:44`). **VERIFIED-HW** (`docs/01 §3`, `01-REVERSE-ENGINEERING.md:72-74`).

```json
{"phoneType":"Android","packageName":"com.cfmoto.cfmotointernational"}
```

### 4.2 One probe attempt (`probeTarget`, `EasyConnProber.kt:485-537`) — VERIFIED-CODE

1. Open a TCP socket pinned to the bike network (Android: `Network.socketFactory` →
   `Network.bindSocket` → process-bound socket; do **not** `bind()` locally first)
   (`EasyConnProber.kt:498-500, 547-588`).
2. `connect(host:port)` with a **3000 ms** timeout (`EasyConnProber.kt:501`).
3. Read timeout **5000 ms** (`EasyConnProber.kt:502`).
4. Write `0x70000010` + probe JSON (`EasyConnProber.kt:504-507`).
5. Read **one** CmdBaseHead frame (`EasyConnProber.kt:509`).
   - `null` (bike closed first) → not accepted.
   - **Accepted iff `cmd == 0x70000011` AND the UTF-8 body contains the substring `true`**
     (`EasyConnProber.kt:515`). `{"status":false}` → not accepted.
6. Close the probe socket in all cases (`EasyConnProber.kt:522`).
7. If not accepted (or any exception), sleep **750 ms × attempt number** (750, 1500, 2250, 3000,
   3750 ms…), also after the last attempt (`EasyConnProber.kt:535`).

### 4.3 Initial discovery order (`discoverAndProbe`, `EasyConnProber.kt:381-448`) — VERIFIED-CODE

| Step | Action | Attempts | Source |
|---|---|---|---|
| 1 | NSD/Bonjour browse `_EasyConn._tcp.` for up to **12 000 ms**; take the first service that resolves to a usable IPv4 + port | — | `EasyConnDiscovery.kt:30-31, 55-114` |
| 1a | If found: probe that host:port | 3 | `EasyConnProber.kt:386-388` |
| 1b | If that fails: browse again (≤ 12 s) and probe the new result | 3 | `EasyConnProber.kt:389-397` |
| 2 | Probe `bikeIp:10930` (gateway) | 5 | `EasyConnProber.kt:401` |
| 3 | TCP connect-scan `bikeIp` ports **10915–10935**, sequential, **350 ms** connect timeout per port; then probe each open port, 10930 first | 2 each | `EasyConnDiscovery.kt:32-34, 160-174`; `EasyConnProber.kt:405-413` |
| 4 | Only if no bike socket ever connected this session: Yunmo fallback on `:8200` (§15), then a log-only "thinkerride" scan, then an error state | — | `EasyConnProber.kt:416-447` |

NSD details: usable host = first IPv4 (`hostAddresses` on API 34+, else `host`), not loopback/any/
multicast; port 1..65535; the TXT package value is read from `packagename` / `packageName` / `package`
(case-insensitive fallback) for logging only (`EasyConnDiscovery.kt:116-154`). The bike's TXT record
carries `huid, huname, channel, flavor, port, ip` (`docs/01 §2`, **VERIFIED-HW**). Some dashes advertise
no mDNS at all (450NK: `docs/RE-VEHICLE-TELEMETRY.md:53-54`), and some SoftAP dashes (Morini `ML*`)
refuse `:10930` but advertise `_EasyConn._tcp.` or listen on a nearby port (`EasyConnDiscovery.kt:21-23`).

Error messages that matter to UX (`EasyConnProber.kt:427-446`): VPN kill-switch (EPERM on bind) →
`"VPN kill-switch blocking bike Wi‑Fi"`; otherwise `R.string.conn_detail_easyconn_offline` =
"Bike Wi‑Fi is up but EasyConn is offline — keep the pairing QR open on the dash"
(`res/values/strings.xml:550`).

**Gap:** after a probe is accepted on the *first* connection there is **no timeout** waiting for
the bike to call back; the phase just stays `PXC_CONNECTING`. (The reconnect loop does re-probe.)
**VERIFIED-CODE** (absence).

### 4.4 When the probe is (re)sent

| Trigger | Path | Source |
|---|---|---|
| Session start | full discovery (§4.3) | `EasyConnProber.kt:221-224` |
| All bike sockets closed after ≥ 1 call-back this session | reconnect loop (§5.3) | `EasyConnProber.kt:604-610, 620-660` |
| Watchdog: streaming but no frame for > 8 s | close all sockets → reconnect loop | `AndroidAutoService.kt:134-148`, `EasyConnProber.kt:346-364` |
| Watchdog: phase ERROR (retry budget spent), every ≥ 20 s | reset attempts, reconnect loop | `AndroidAutoService.kt:149-152`, `EasyConnProber.kt:370-375` |
| Bike Wi-Fi re-acquired | prober `stop()` + `start()` (full discovery) | `BikeLink.kt:118-141` |
| `start()` while running (mode switch) | `stop()` then fresh start | `EasyConnProber.kt:136-141` |

---

## 5. Session lifecycle and the control-connection loop

### 5.1 Accept loop (`spawnAccept`, `EasyConnProber.kt:593-612`) — VERIFIED-CODE

One accept loop per listener. For every accepted socket: `everConnected = true`,
`reconnectAttempts = 0`, `liveConns += 1`, remember the socket in `activeClients`, start a reader
thread. When a reader ends: remove the socket, `liveConns -= 1`, and if it reaches **0** call
`onAllConnectionsClosed()`. `liveConns` counts **all** bike sockets (control and media), so the
reconnect loop starts only when every socket is gone; a stall with half-open sockets is caught by
the watchdog instead.

### 5.2 Control reader (`readLoop`, `EasyConnProber.kt:662-688`)

```
loop while running:
    frame = PxcFrame.read(input)        // §2.2
        on exception  -> log "frame error", close socket, exit
        on null (EOF) -> log "bike closed", close socket, exit
    try handshake.handle(":10922", frame, socket)
        on exception  -> log "handler error", continue
```

All :10922 sockets share **one** `PxcHandshake` (one profile, one HUID, one phone UUID). Replies
are always written to the socket the request came in on. The code does **not** enforce that the
first frame is a channel select and does not track which socket is CAR_CTRL vs CAR_DATA (the label
is only used for heartbeat log lines). **VERIFIED-CODE**

### 5.3 Reconnect loop (`onAllConnectionsClosed`, `EasyConnProber.kt:620-660`) — VERIFIED-CODE

Preconditions: running, `everConnected`, not already re-probing. Budget **20** attempts
(`MAX_RECONNECT_ATTEMPTS`, `EasyConnProber.kt:48`); exhausted → `Phase.ERROR "lost bike link"`.

```
phase = RECONNECTING
while running && liveConns == 0 && attempts < 20:
    attempts += 1
    sleep min(500 + 500*attempts, 4000) ms        // 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4000...
    abort if a bike socket appeared meanwhile
    probed = false; framesSent = 0; stop Yunmo
    probe bikeIp:10930, 2 attempts
    if not accepted: NSD browse (<=12 s) -> probe result, 2 attempts
    if not accepted: Yunmo :8200 fallback
    sleep 2500 ms   // give the dash time to call back
```

A new accepted socket resets `reconnectAttempts` to 0 (`EasyConnProber.kt:601`).

### 5.4 Watchdog (Android Auto service; behaviour the iOS app should copy) — VERIFIED-CODE

| Constant | Value | Source |
|---|---|---|
| tick | 5000 ms | `AndroidAutoService.kt:695` |
| stall threshold (phase STREAMING, no frame sent to dash) | 8000 ms | `AndroidAutoService.kt:696` |
| min gap between forced reconnects | 20 000 ms | `AndroidAutoService.kt:697` |
| min gap between re-arms after ERROR | 20 000 ms | `AndroidAutoService.kt:698` |
| bike transport gone (no AP **and** no P2P link) before parking the session | 180 000 ms | `AndroidAutoService.kt:699`, `AndroidAutoService.kt:176-196` |

`bikeTransportConnected(ap, p2p) = ap || p2p` (`AndroidAutoService.kt:702-703`; test vector in §16.8).
The dash's own media timeout is `socketTimeoutPeriodWifi = 9` s from its CLIENT_INFO
(`docs/01 §0`, `01-REVERSE-ENGINEERING.md:19-20`). The US 800NK tears the whole session down after
**~7 s** of silence on either :10922 socket (`BikeProfile.kt:451-454`).

### 5.5 Session state machine (phone side)

| # | State | Entered by | Phone actions / exit |
|---|---|---|---|
| S0 | IDLE | — | user Connect |
| S1 | NET_READY | joined bike Wi-Fi, know `myIp` + `bikeIp` | bind 10922/10921/10920 (§1) → S2; bind fails → ERROR |
| S2 | DISCOVER_PROBE | listeners up | §4.3. Accepted → S3. Nothing works → ERROR (or Yunmo, §15) |
| S3 | AWAIT_CALLBACK | probe accepted | bike opens :10922 #1 → S4. (Recommended for iOS: time out after ~10 s → back to S2; Android has no timeout here.) |
| S4 | CTRL_SELECTED | `0x10000` on a :10922 socket | reply `0x10001`; start 2 s heartbeat on that socket |
| S5 | IDENTIFIED | `0x10010` CLIENT_INFO | select profile (§12.5); reply `0x10011` (§8) |
| S6 | SPEED_OK | `0x10690` | reply `0x10691` empty |
| S7 | DATA_SELECTED | `0x20000` on the 2nd :10922 socket | reply `0x20001`; start heartbeat on that socket |
| S8 | SN_CHECKED | `0x103e0` | reply `0x103e1`, send `0x201c0` result; bike answers `0x201c1` |
| S9 | NOTIFY_BURST (CFDL26, newer CFDL16, CRCP...) | frames of §3.2/§3.3, `0x10600`, `0x10450` | ack each (cmd+1 / clock replies). The dash will not open media until each is acked. |
| S10 | MEDIA | bike connects :10921 and :10920 | media plane (other spec); first frame delivered → STREAMING |
| S11 | STREAMING (steady) | — | keep heartbeating; answer heartbeats, `0x10600` (~2 s), periodic `0x10750`, any notify (cmd+1) |
| S12 | RECONNECTING | `liveConns` hits 0 after ≥ 1 call-back, or watchdog stall | §5.3 → S3/S4, or ERROR after 20 attempts |
| S13 | ERROR | — | watchdog re-arms every ≥ 20 s; user Stop/Connect |

Transitions S5–S9 are bike-driven and their order differs by dash family (§6). The phone is purely
reactive except for (a) the probe, (b) the 2 s heartbeats, (c) `0x201c0` after `0x103e1`.

---

## 6. Handshake sequences per dash family

### 6.1 CFDL16 (BIKE A: CFMoto 675 SR-R "CFDL16-6GUV", sdk 0.9.29.1, Wi-Fi AP) — VERIFIED-HW (`docs/01 §3`)

```
P->B  :10930  0x70000010 {"phoneType":"Android","packageName":"com.cfmoto.cfmotointernational"}
B->P          0x70000011 {"status":true}                       (phone closes the probe socket)
B connects :10922 #1
B->P  0x10000            P->B 0x10001          [phone starts 2 s heartbeat on #1]
B->P  0x10010 {CLIENT_INFO}   P->B 0x10011 {phone CLIENT_INFO}
B->P  0x10690 {"usbSpeed":0,"wifiSpeed":0}   P->B 0x10691 (empty)
B connects :10922 #2
B->P  0x20000            P->B 0x20001          [phone starts 2 s heartbeat on #2]
B->P  0x103e0 {"client_set":"easy_conn","sn":"…"}   P->B 0x103e1 (empty)
                                                    P->B 0x201c0 {"isOk":true,…}
B->P  0x201c1
B<->P 0x70000000 / 0x70000001 (heartbeats, both directions)
B connects :10921 (media ctrl) and :10920 (media data)  -> media plane
```

### 6.2 CFDL26 (BIKE B: 1000 MT-X, also 800MT / 800NK Advanced; sdk 1.1.x) — VERIFIED-HW (`docs/01 §7.2`)

Identical through the CAR_DATA select. Then, on the **CAR_DATA** socket, a burst the CFDL16 never
sends; the dash **will not open :10921/:10920 until every frame is acked** (otherwise it goes silent
and closes after ~9 s). Order observed:

```
B->P 0x10780 {"log":"…mdns success…"}            P->B 0x10781      (the first gate)
B->P 0x103e0 {client_set,sn}                     P->B 0x103e1 + 0x201c0
B->P 0x103a0 {port:11021,userName,pwd}           P->B 0x103a1
B->P 0x10020 {music,talkie,tts,vr,autoChangeToBT} P->B 0x10021
B->P 0x10040 {maxNaviIcon:161,supportFunction:0} P->B 0x10041
B->P 0x10600 <45-byte time frame>  (~every 2 s)  P->B 0x10601 <body, §13.2>
B->P 0x10750 (empty, periodic)                   P->B 0x10751
B->P 0x10430 (empty)                             P->B 0x10431
B->P 0x10450 (empty)                             P->B 0x10451 (empty by default)
B->P 0x10460 {bluetooth:4129}                    P->B 0x10461
then: B connects :10921 + :10920
```

`enableSockServerAuth=true` is a **red herring**: no extra auth exchange beyond `pubkey` +
`encryptedHUID` in the CLIENT_INFO reply was ever needed (`docs/01 §7.2`, `01-REVERSE-ENGINEERING.md:235-237`).

### 6.3 US 800NK "CRCP" (sdk 0.9.23.x, `linux_no_package`, Wi-Fi Direct) — VERIFIED-HW (field, per code comments)

- Sends **no heartbeats of its own**; an idle :10922 socket (CAR_CTRL **or** CAR_DATA) tears the whole
  session down after **~7 s**. The phone must heartbeat **both** sockets; heartbeating only CAR_CTRL
  produced the "7 s after 0x104a0" flap (`BikeProfile.kt:450-454`, `EasyConnProber.kt:1045-1052`).
- Extra notify frames `0x10450`, `0x10470` (voice grammar), `0x104a0` (SOCK_SERVER_INFO, on CAR_DATA
  together with CHECK_SN) → cmd+1 (`BikeProfile.kt:457-458`, `PxcFrame.kt:79-80`).
- Non-touch, no sock-server auth (`BikeProfile.kt:455-456`).

### 6.4 Newer CFDL16-family (sdk 0.9.25.1, `version_name` `CFDL06.6.10`, package `net.easyconn`, e.g. CFMOTO9805)

Sends the same post-handshake burst (notably `0x103a0`) and will not open media until each is acked
cmd+1 (`BikeProfile.kt:431-436`). **VERIFIED-HW** (field, per code comment).

### 6.5 Other Carbit brands (Morini, Voge, QJ, Zontes, Benelli, Rieju, Morbidelli, UM, Wmoto Griffin…)

Same PXC flow; community-confirmed with the identical phone behaviour (`docs/SUPPORTED-BIKES.md:23-81`).
Brand-specific observations:

- Dashes whose CLIENT_INFO has `supportSyncCorrectTime:true` send `0x10600` about every 2 s
  (`docs/01 §7.2`). X-Cape / Voge / Griffin were noted as **never** sending `0x10600`
  (removed code comment, git `104b47b`). **INFERRED** (field note).
- Morini SoftAP `ML*` units may not accept the :10930 probe; NSD or the port scan finds them
  (`EasyConnDiscovery.kt:21-23`).
- Morini X-Cape 1200 speaks Yunmo, not EasyConn (§15). **EXPERIMENTAL**
- Clock behaviour differs per brand (§13.7).

---

## 7. CLIENT_INFO from the bike (0x10010)

Parsed with Android `org.json.JSONObject` (lenient parser). On parse failure the phone **logs and
does not reply** (`PxcHandshake.kt:141-143`), which presumably stalls the dash. After a successful
parse: `lastClientInfo = json`; `carHuid = json.optString("HUID")`, falling back to
`json.optString("huid")`, empty → null (`PxcHandshake.kt:144-145`).

`opt*` semantics the scoring relies on (Android org.json): missing key → `""` / `false` / default;
`optString` of a number returns its decimal text; `optInt` parses numeric strings; `optBoolean`
accepts the string `"true"` (case-insensitive). iOS should coerce the same way.

Fields seen in code and docs (no complete verbatim capture is in the repo):

| Key | Type | Example values | Used for | Source / status |
|---|---|---|---|---|
| `HUID` | string | `6GUVA2C00100055` (CFDL16), `6WX0AT231300200` (1000 MT-X), `CRCP…` (US 800NK, e.g. `CRCP230501740`), `6KWV…` (800NK Adv), `6WWV…` (800MT Explore/MT-X AP), `CARB…` (generic Carbit, Morini) | `encryptedHUID`, scoring | `docs/01:11, 199`; `BikeProfile.kt:480, 530, 613, 733, 785`; `test/LogRedactorTest.kt:19` VERIFIED-HW |
| `huid` | string | fallback spelling | `carHuid` fallback | `PxcHandshake.kt:145` VERIFIED-CODE |
| `HUName` | string | `CFDL16-6GUV`, `CFMOTO-805120`, `…48FB4C…` (CL-C450) | scoring | `docs/01:11, 199`; `BikeProfile.kt:422, 674` |
| `channel` | string (maybe numeric) | `37416` (675), `66660742`, `66660736`, `21333`, `21322` (Morini), `21340` (Zontes 125X) | scoring, clock-lab log banner | `BikeProfile.kt:424, 644, 673, 731`; `HuQueryTime.kt:20` |
| `flavor` | int | `65540` (CFMoto), `51` (Morini) | scoring | `docs/01:13, 201`; `BikeProfile.kt:734` |
| `sdkVersion` | string | `0.9.29.1`, `1.1.4`, `1.1.2`, `0.9.23.4`, `0.9.23.9`, `0.9.25.1`, `1.0.13.1` | scoring | `docs/01:13, 200`; `BikeProfile.kt:423, 481, 538, 645, 675, 737` |
| `package_name` | string | `com.cfmoto.cfdashmotoplay`, `com.cfmoto.easyconnect`, `linux_no_package`, `net.easyconn`, empty (Morini) | scoring | `docs/01:199`; `BikeProfile.kt:482, 542, 605, 735, 780` |
| `version_name` | string | `CFDL26.2.3.5.0.6`, `CFDL26.2.3.0.5`, `V1.0.18`, `CFDL06.6.10` | scoring | `docs/01:200`; `BikeProfile.kt:433, 447-448, 611-612` |
| `pxcVersion` | string | `1.0.2` | — | `docs/01:201` |
| `screenType`, `productType`, `mirrorMode` | int | `1`, `3`, `1` | — | `docs/01:13, 201` |
| `supportScreenMirroring` | bool | `true` | — | `docs/01:14, 78` |
| `socketTimeoutPeriodWifi` | int (seconds) | `9` | not read by code (should drive iOS watchdogs) | `docs/01:19-20, 78` |
| `enableSockServerAuth` | bool | `true` on CFDL26 | scoring | `docs/01:17, 202`; `BikeProfile.kt:541, 606, 779` |
| `dpi`, `enableDPI` | int, bool | `240`, `true` | — | `docs/01:202` |
| `supportScreenTouch` | bool | `true` on CFDL26 | scoring | `docs/01:202-203`; `BikeProfile.kt:617, 647, 739, 786` |
| `supportHID` | bool | `true` | — | `docs/01:203` |
| `supportMirrorOverlayTouch` | bool | `true` | scoring | `docs/01:203`; `BikeProfile.kt:616` |
| `supportFunction` | int | `0` (CFDL16), `128` (CFDL26 and many CFDL16) | scoring | `docs/01:203`; `BikeProfile.kt:543-545` |
| `supportConnect` | int | `776` | — | `docs/01:203` |
| `supportLandscapeAdaptive` | bool | `true` on 800MT AP | scoring | `BikeProfile.kt:614-615, 783` |
| `supportSyncCorrectTime` | bool | — | dash then sends `0x10600` about every 2 s | `docs/01:227`; `PxcFrame.kt:83-85` |
| `supportBTCall`, `btPin`, `bluetoothPolicy` | bool, string (secret), int | `true`, —, `2` | — | `docs/RE-VEHICLE-TELEMETRY.md:34-35`; `LogRedactor.kt:18` |
| `currentHUTime` | number | "often ms since its own midnight (1970 00:xx)" | — | removed code comment, git `104b47b`; INFERRED |

Illustrative (**RECONSTRUCTED**, not a capture) 1000 MT-X CLIENT_INFO assembled from the documented values:

```json
{"HUID":"6WX0AT231300200","HUName":"CFMOTO-805120","package_name":"com.cfmoto.cfdashmotoplay",
 "version_name":"CFDL26.2.3.5.0.6","sdkVersion":"1.1.4","flavor":65540,"productType":3,"screenType":1,
 "mirrorMode":1,"pxcVersion":"1.0.2","enableSockServerAuth":true,"dpi":240,"enableDPI":true,
 "supportScreenTouch":true,"supportHID":true,"supportMirrorOverlayTouch":true,"supportFunction":128,
 "supportConnect":776,"socketTimeoutPeriodWifi":9,"supportScreenMirroring":true}
```

---

## 8. Phone CLIENT_INFO reply (0x10011)

Built by `basePhoneClientInfo` (`BikeProfile.kt:288-309`) plus a per-profile tail, serialized with
`JSONObject.toString()` and sent as UTF-8 on the socket the CLIENT_INFO came in on
(`PxcHandshake.kt:180-182`). Key order below is the insertion order, which Android's `JSONObject`
preserves. **VERIFIED-HW** for the key set and values (matches the official app's reply,
`docs/01 §3`, `01-REVERSE-ENGINEERING.md:79-88`).

### 8.1 Builder code, verbatim

```kotlin
private fun basePhoneClientInfo(huid: String?, phoneUuid: String, supportFunction: Int): JSONObject =
    JSONObject().apply {
        put("pxcVersion", "1.0.2")
        put("phoneUUID", phoneUuid)
        put("phoneBrand", Build.BRAND)
        put("phoneModel", Build.MODEL)
        put("phoneOsVersion", Build.VERSION.SDK_INT.toString())
        put("phoneOs", "Android")
        put("package", EasyConnProber.SPOOFED_PACKAGE)
        put("versionCode", 126)
        put("token", 0)
        put("pubkey", RsaKeys.publicKeyBase64)
        put("encryptedHUID", huid?.let { RsaKeys.signHuid(it) } ?: "")
        put("bluetoothName", "OpenCfMoto")
        put("supportH264IFrame", true)
        put("supportFunction", supportFunction)
        put("supportSyncCorrectTime", false)
        put("appVersionFingerPrint", "opencfmoto-poc")
    }
// CFDL26 profiles (Portrait, NkTouch, Landscape) append:
//     if (BikeProfileHolder.advertisesScreenTouch) put("supportScreenTouch", true)
```

### 8.2 Field table

| # | Key | JSON type | Value | Dynamic? | Source |
|---|---|---|---|---|---|
| 1 | `pxcVersion` | string | `"1.0.2"` | const | `BikeProfile.kt:290` |
| 2 | `phoneUUID` | string | random UUID v4, lowercase 36 chars (`8-4-4-4-12`) | per **process**: created with `PxcHandshake` (`PxcHandshake.kt:23`), which lives as long as the single `EasyConnProber` (`EasyConnProber.kt:73`, cached in `BikeLink.prober`, `MainActivity.kt:513`). Stable across reconnects, regenerated on app restart, **never persisted** | VERIFIED-CODE |
| 3 | `phoneBrand` | string | `Build.BRAND` (e.g. `samsung`) | device | `BikeProfile.kt:292` |
| 4 | `phoneModel` | string | `Build.MODEL` (e.g. `SM-G991B`) | device | `BikeProfile.kt:293` |
| 5 | `phoneOsVersion` | **string** | Android API level as text (e.g. `"35"`), not the marketing version | device | `BikeProfile.kt:294`, `docs/01:82` |
| 6 | `phoneOs` | string | `"Android"` | const | `BikeProfile.kt:295` |
| 7 | `package` | string | `"com.cfmoto.cfmotointernational"` (spoofed official app) | const | `BikeProfile.kt:296`, `EasyConnProber.kt:44` |
| 8 | `versionCode` | int | `126` (official app v2.2.5 was verified at versionCode 126/136, `docs/01:3-5`) | const | `BikeProfile.kt:297` |
| 9 | `token` | int | `0` | const | `BikeProfile.kt:298` |
| 10 | `pubkey` | string | base64 (standard alphabet, padded, no line breaks) of the X.509 SubjectPublicKeyInfo DER of the RSA-1024 public key (216 chars) | per process | `BikeProfile.kt:299`, `RsaKeys.kt:32` |
| 11 | `encryptedHUID` | string | base64 (no wrap) of RSA-1024 PKCS#1 v1.5 private-key "encryption" of the UTF-8 bytes of the bike's HUID (172 chars, ends `=`); `""` if the bike sent no HUID | per HUID (deterministic) | `BikeProfile.kt:300`, `RsaKeys.kt:35-41` |
| 12 | `bluetoothName` | string | `"OpenCfMoto"` (not the phone's real BT name) | const | `BikeProfile.kt:301` |
| 13 | `supportH264IFrame` | bool | `true` | const | `BikeProfile.kt:302` |
| 14 | `supportFunction` | int | `0` (Legacy, ClC450) or `128` (all others) | per profile | `BikeProfile.kt:303`, §12.3 |
| 15 | `supportSyncCorrectTime` | bool | `false` (see §13.3: `true` made Zontes/Voge go to 00:00) | const | `BikeProfile.kt:304-307` |
| 16 | `appVersionFingerPrint` | string | `"opencfmoto-poc"` | const | `BikeProfile.kt:308` |
| 17 | `supportScreenTouch` | bool | `true`, **present only** for Cfdl26Portrait / Cfdl26NkTouch / Cfdl26Landscape when `advertisesScreenTouch` (below); otherwise the key is absent | per profile + user setting | `BikeProfile.kt:550-553, 621-624, 792-797` |

`advertisesScreenTouch` (`BikeProfile.kt:278-283`): "Disable touchscreen" setting → `false`; else
"Force touchscreen" → `true`; else `active.supportsScreenTouch`. `active` is already the newly
selected profile when the reply is built (`PxcHandshake.kt:166, 180`). So by default:
Cfdl26Landscape and Cfdl26NkTouch include `"supportScreenTouch":true`; Cfdl26Portrait includes it
only with Force touchscreen; the five other profiles never include it (even with Force touchscreen).

Serialization details that affect bytes (**INFERRED** from Android's `org.json` implementation, the
repo's host tests cannot exercise it, `test/BikeProfileSelectTest.kt:10-11`): no whitespace; keys in
insertion order; booleans/ints as bare literals; **`/` inside strings is escaped as `\/`** (base64
`pubkey`/`encryptedHUID` usually contain `/`). Any JSON parser treats `\/` and `/` identically.

### 8.3 Template

```
{"pxcVersion":"1.0.2","phoneUUID":"<uuid>","phoneBrand":"<brand>","phoneModel":"<model>","phoneOsVersion":"<api>","phoneOs":"Android","package":"com.cfmoto.cfmotointernational","versionCode":126,"token":0,"pubkey":"<spki-b64>","encryptedHUID":"<sig-b64 or empty>","bluetoothName":"OpenCfMoto","supportH264IFrame":true,"supportFunction":<0|128>,"supportSyncCorrectTime":false,"appVersionFingerPrint":"opencfmoto-poc"[,"supportScreenTouch":true]}
```

### 8.4 Worked example (DERIVED, using the fixed test key of §9.5, HUID `6GUVA2C00100055`, Legacy profile)

800 bytes of UTF-8 payload; frame header `11 00 01 00 30 03 00 00 21 03 01 00 00 00 00 00`
(totalLen 816 = 0x330, magic 0x10011 ^ 0x330 = 0x10321):

```
{"pxcVersion":"1.0.2","phoneUUID":"3f2b8c1e-9a47-4d2e-8b6a-0c5d7e9f1a23","phoneBrand":"samsung","phoneModel":"SM-G991B","phoneOsVersion":"35","phoneOs":"Android","package":"com.cfmoto.cfmotointernational","versionCode":126,"token":0,"pubkey":"MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt\/UzHJWFwIDAQAB","encryptedHUID":"cfSiCV3iPlLnlyC9c70nMK+ssR6NtAo0nVB9D4IzEa6kszXDMylU7NtPTdLHMnPMqjphXhkVEjpeQ7sapLP0rniYP9fz+ZY5aS\/xeGZvLzbxjOR4iHDec2JtAXMI4rJQ4vchKpmAxvQ4yZmKKFmhW2NXmraAKZF9RrzNyFhbZS0=","bluetoothName":"OpenCfMoto","supportH264IFrame":true,"supportFunction":0,"supportSyncCorrectTime":false,"appVersionFingerPrint":"opencfmoto-poc"}
```

For Cfdl26Landscape the same object would carry `"supportFunction":128` and end with
`,"supportScreenTouch":true}`.

---

## 9. RSA identity

### 9.1 Code, verbatim (`RsaKeys.kt:23-50`)

```kotlin
object RsaKeys {
    private val keypair: KeyPair = KeyPairGenerator.getInstance("RSA")
        .apply { initialize(1024) }
        .generateKeyPair()
    val publicKey: PublicKey = keypair.public
    val privateKey: PrivateKey = keypair.private
    val publicKeyBase64: String = Base64.encodeToString(publicKey.encoded, Base64.NO_WRAP)

    fun signHuid(huid: String): String {
        val priv = KeyFactory.getInstance("RSA")
            .generatePrivate(PKCS8EncodedKeySpec(privateKey.encoded))
        val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
        cipher.init(Cipher.ENCRYPT_MODE, priv)
        return Base64.encodeToString(cipher.doFinal(huid.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }

    fun decryptWithPrivateKey(encrypted: ByteArray): ByteArray { /* RSA/ECB/PKCS1Padding DECRYPT, unused */ }
}
```

### 9.2 Facts

| Item | Value | Status / source |
|---|---|---|
| Algorithm / size | RSA, **1024-bit**, default public exponent **65537** | VERIFIED-CODE `RsaKeys.kt:24-26`; exponent DERIVED (provider default) |
| Lifetime | generated lazily on first access of the `RsaKeys` object (in practice while building the first CLIENT_INFO reply), kept in memory for the process, **never persisted** ("single in-memory keypair, enough for a PoC") | VERIFIED-CODE `RsaKeys.kt:21-26` |
| `pubkey` encoding | `PublicKey.encoded` = X.509 **SubjectPublicKeyInfo** DER (162 bytes for RSA-1024) → base64 **NO_WRAP** (standard alphabet `+/`, `=` padding, no line breaks) → 216 chars, always starts `MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQ` | VERIFIED-CODE `RsaKeys.kt:31-32`; lengths DERIVED |
| SPKI prefix | `30 81 9f 30 0d 06 09 2a 86 48 86 f7 0d 01 01 01 05 00 03 81 8d 00` (22 bytes) followed by the 140-byte PKCS#1 `RSAPublicKey` | DERIVED (Java + Python agree) |
| `encryptedHUID` | `Cipher("RSA/ECB/PKCS1Padding")`, **ENCRYPT_MODE with the PRIVATE key**, input = `huid.toByteArray(UTF_8)` → 128 bytes → base64 NO_WRAP (172 chars) | VERIFIED-CODE `RsaKeys.kt:35-41` |
| What that operation is | PKCS#1 v1.5 **block type 1** padding `00 01 FF…FF 00 ‖ HUID` then `m^d mod n` = an RSA signature **without** hash and without DigestInfo ("NONEwithRSA"). Deterministic: same key + HUID → same bytes. The bike recovers the HUID with the public key. | DERIVED: Java `Cipher` output equals Java `Signature("NONEwithRSA")`, equals raw Python `pow(EM, d, n)`, and the public operation recovers `00 01 FF… 00 ‖ "6GUVA2C00100055"` |
| Max HUID length | 128 − 11 = 117 bytes (real HUIDs are ~13–15 ASCII chars) | DERIVED |
| Does the bike check it? | Unknown. Treat as required; `enableSockServerAuth` needed nothing more (`docs/01 §7.2`) | INFERRED |
| `decryptWithPrivateKey` | exists for "bike encrypts something with our pubkey" (`RsaKeys.kt:16-18, 43-50`) but is **never called**; the media config-capture request carries an `encryptedHUID` string at offset 32 that the app ignores (`docs/01 §4`, `01-REVERSE-ENGINEERING.md:138`) | VERIFIED-CODE (unused) |

### 9.3 Recovered encoded message (DERIVED, fixed key of §9.5)

Public-key operation applied to the `encryptedHUID` of §8.4 gives exactly:

```
00 01 ff ff ff ff ff ff ff ff ff ff ff ff ff ff
ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff
ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff
ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff
ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff
ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff
ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff
00 36 47 55 56 41 32 43 30 30 31 30 30 30 35 35      ("6GUVA2C00100055")
```

### 9.4 iOS mapping (INFERRED, verify with §9.5)

- Generate: `SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024])`.
- Public key: `SecKeyCopyExternalRepresentation(pub)` returns **PKCS#1** `RSAPublicKey` DER (140
  bytes for 1024-bit) → prepend the 22-byte SPKI prefix above → `base64EncodedString()` (no options =
  no line breaks). Assert the PKCS#1 blob is exactly 140 bytes before using the fixed prefix.
- `encryptedHUID`: `SecKeyCreateSignature(priv, .rsaSignatureDigestPKCS1v15Raw, Data(huid.utf8))`
  ("PKCS#1 v1.5 padding, input not wrapped in DigestInfo") should equal the Java private-key
  encryption byte for byte. Fallback: build `00 01 FF… 00 ‖ HUID` yourself and use
  `.rsaSignatureRaw`, or a pure-Swift modexp.

### 9.5 Fixed test key and expected outputs (DERIVED, cross-checked Java ↔ Python)

PKCS#1 `RSAPrivateKey` DER, base64 (directly importable with `SecKeyCreateWithData`,
`kSecAttrKeyClassPrivate`):

```
MIICWwIBAAKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt/UzHJWFwIDAQABAoGAHOSYxnBZCK29aQTmZ0JWiV7ESmrgDGj4eUQTZhYY3vfIhcWY6UKOKzQM8fMQUI4XBwgZKTJ3y4NbEjrlF/9jZjaP+DySrn+U5HnVkIr4Hye3I2tOqeJaWL4LGFr0fV4qaiJVl4XxL2JMI2RlMt+S9Cw3bPkim4hIJKySXLLbjQkCQQDCzsFwYRj0ddspxVD1hVUQRaB10YTCBYoCMMKyxmWHLQqNukzWTc8EYctsz4T1u4MQnDTc3t6iWdS1of3QKKoPAkEAtEHCivoWq2bVXCViThK+BP/sHEMDyXqTgyMuv1jNkUxpwUmCoptcMNrZMBdfBowrxSe4LBersIMU1ixM/++7eQJARsTVgP3FEwm9lG8Z+hd1z3N711FF6TYZ7LHKCSgJuhGiw9nqD/A0RGNCg0TgCGUWN/KHQbW1K0V3AITYr8YWAQJAS3E+X/Y9qK0YXUGUPELh3qvSAR4XJqszs+30sccT+lz14hzHHRFS62uc/OC7N71Q0GpITcP2aqDiBqVx8KhAWQJAP3c2sgSFzB3rmQCvLG06zxM5wNmeNUiW5Vo6ZBHL8XnoFyJlMIft/pie0smdqoAZ/yCMxa4GVMUGEmc9T5THxA==
```

Same key as PKCS#8 (what Java `PrivateKey.encoded` gives):

```
MIICdQIBADANBgkqhkiG9w0BAQEFAASCAl8wggJbAgEAAoGBAIkraoySKMx86ykcKv1QxH52N027q+e5semp8kxpy+2BKds6Zoymx72Auwqncd3UZMrmT1bwmTc89Tolbd2uyB0rjdF2Wi06UZPk8yLDuOajQ7J3NeO4WuN+Euxy7Poxs09c7XYiSuChVY+x86nfGySpauV9C4IY2WNS39TMclYXAgMBAAECgYAc5JjGcFkIrb1pBOZnQlaJXsRKauAMaPh5RBNmFhje98iFxZjpQo4rNAzx8xBQjhcHCBkpMnfLg1sSOuUX/2NmNo/4PJKuf5TkedWQivgfJ7cja06p4lpYvgsYWvR9XipqIlWXhfEvYkwjZGUy35L0LDds+SKbiEgkrJJcstuNCQJBAMLOwXBhGPR12ynFUPWFVRBFoHXRhMIFigIwwrLGZYctCo26TNZNzwRhy2zPhPW7gxCcNNze3qJZ1LWh/dAoqg8CQQC0QcKK+harZtVcJWJOEr4E/+wcQwPJepODIy6/WM2RTGnBSYKim1ww2tkwF18GjCvFJ7gsF6uwgxTWLEz/77t5AkBGxNWA/cUTCb2Ubxn6F3XPc3vXUUXpNhnsscoJKAm6EaLD2eoP8DREY0KDROAIZRY38odBtbUrRXcAhNivxhYBAkBLcT5f9j2orRhdQZQ8QuHeq9IBHhcmqzOz7fSxxxP6XPXiHMcdEVLra5z84Ls3vVDQakhNw/ZqoOIGpXHwqEBZAkA/dzayBIXMHeuZAK8sbTrPEznA2Z41SJblWjpkEcvxeegXImUwh+3+mJ7SyZ2qgBn/IIzFrgZUxQYSZz1PlMfE
```

PKCS#1 `RSAPublicKey` DER (140 B), base64: `MIGJAoGBAIkraoySKMx86ykcKv1QxH52N027q+e5semp8kxpy+2BKds6Zoymx72Auwqncd3UZMrmT1bwmTc89Tolbd2uyB0rjdF2Wi06UZPk8yLDuOajQ7J3NeO4WuN+Euxy7Poxs09c7XYiSuChVY+x86nfGySpauV9C4IY2WNS39TMclYXAgMBAAE=`

Expected `pubkey` (SPKI, 216 chars):
`MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt/UzHJWFwIDAQAB`

Expected `encryptedHUID` for HUID `6GUVA2C00100055` (172 chars):
`cfSiCV3iPlLnlyC9c70nMK+ssR6NtAo0nVB9D4IzEa6kszXDMylU7NtPTdLHMnPMqjphXhkVEjpeQ7sapLP0rniYP9fz+ZY5aS/xeGZvLzbxjOR4iHDec2JtAXMI4rJQ4vchKpmAxvQ4yZmKKFmhW2NXmraAKZF9RrzNyFhbZS0=`

Modulus (hex): `892b6a8c9228cc7ceb291c2afd50c47e76374dbbabe7b9b1e9a9f24c69cbed8129db3a668ca6c7bd80bb0aa771ddd464cae64f56f099373cf53a256dddaec81d2b8dd1765a2d3a5193e4f322c3b8e6a343b27735e3b85ae37e12ec72ecfa31b34f5ced76224ae0a1558fb1f3a9df1b24a96ae57d0b8218d96352dfd4cc725617`, e = 65537.

This key is a **test fixture only**; production must generate its own key.

---

## 10. QUERY_SPEED, CHECK_SN and heartbeats

### 10.1 QUERY_SPEED (`PxcHandshake.kt:60-63`) — VERIFIED-HW

B→P `0x10690` `{"usbSpeed":0,"wifiSpeed":0}` → P→B `0x10691` with an **empty** payload. Same as the
official app (`docs/01 §3` step 4).

### 10.2 CHECK_SN (`PxcHandshake.kt:185-201`) — VERIFIED-HW

1. B→P `0x103e0` `{"client_set":"easy_conn","sn":"DSXXZMHNFV3DEXEBB3PZ2"}` (normally on CAR_DATA).
2. `sn = JSONObject(text).optString("sn")`; on parse failure `""` (the flow continues anyway).
3. P→B `0x103e1`, empty.
4. P→B `0x201c0` with this object, keys in this order (built with `JSONObject`):

```kotlin
put("isOk", true); put("errCode", 0); put("errMsg", ""); put("id", sn); put("client_set", "easy_conn")
```
→ `{"isOk":true,"errCode":0,"errMsg":"","id":"<sn>","client_set":"easy_conn"}`. `client_set` is the
constant `"easy_conn"`, not echoed from the request.
5. B→P `0x201c1` (ignored).

### 10.3 Heartbeats — VERIFIED-HW (CFDL16 bike-initiated; phone-initiated proven on US 800NK)

| Who | What | When | Source |
|---|---|---|---|
| Bike → phone | `0x70000000` empty | periodic on CFDL16/CFDL26 (period not documented); the US 800NK sends **none** | `docs/01 §3` step 7, `BikeProfile.kt:451` |
| Phone reply | `0x70000001` empty, on the same socket, no log | each received heartbeat | `PxcHandshake.kt:65-67` |
| Phone → bike | `0x70000000` empty | on **every** :10922 socket after its channel select (CAR_CTRL and CAR_DATA); first beat **2000 ms after** the select, then every **2000 ms** | `EasyConnProber.kt:50, 73-77, 1057-1079` |
| Phone ignores | `0x70000001` from the bike | — | `PxcHandshake.kt:68` |

Phone heartbeat thread rules (`EasyConnProber.kt:1064-1076`): loop while running and socket open:
sleep 2000 ms, re-check, send; stop on the first send failure; log beats 1–3 and every 15th. One
thread per channel-select event (a duplicated select would start a second thread). The phone has
**no** heartbeat-timeout of its own on the control plane (`soTimeout = 0`); liveness comes from socket
closure plus the media watchdog (§5.4). Sending heartbeats is harmless on bikes that ignore or ack
them (`EasyConnProber.kt:1054-1055`).

Unrelated log-only "hb" thread: every 5000 ms logs `hb#… probed=… video=… framesSent=…`
(`EasyConnProber.kt:1081-1095`). Not on the wire.

---

## 11. The notify burst and the "ack unknown with cmd + 1" policy

Any control frame that `PxcHandshake.handle` does not match explicitly (§3.1) goes to
`profile.handleUnknownControl(...)` (`PxcHandshake.kt:76-81`). **Every** profile in 2.0.18 delegates to
`Cfdl26PortraitProfile.handleUnknownControl` (`BikeProfile.kt:438-440, 495-497, 626-628, 654-656,
682-684, 746-748, 807-811`), which:

1. (dead branch: `0x10600` is already handled earlier, `BikeProfile.kt:560-566`)
2. logs `CFDL26 ctrl 0x… (NAME) len=N <utf8 body> hex=<first 48 bytes> → ack 0x… (empty)`, tagging
   `0x30040` as `*** SCREEN_TOUCH ***` (`BikeProfile.kt:571-577`);
3. writes `PxcFrame(frame.cmd + 1, empty)` on the same socket (`BikeProfile.kt:575-578`);
4. returns `true`, so the old "log only, no reply" fallback (`PxcHandshake.kt:77-80`) is unreachable.

Consequences (**VERIFIED-CODE**):

- The policy is **universal**: all profiles, and also **before** CLIENT_INFO arrives (the initial
  profile is Legacy, `PxcHandshake.kt:31`, which delegates the same way).
- It acks **any** unmatched cmd, odd or even. (`docs/04 §4.1` says "even-numbered" only; the code does
  not check parity.)
- Why: the CFDL26 burst (§6.2) and the newer CFDL16-family `0x103a0` gate the media ports until each
  frame is acked (**VERIFIED-HW**, `docs/01 §7.2`, `BikeProfile.kt:431-436, 567-570`).

Exceptions handled before the generic path (never acked cmd+1): `0x10000`, `0x20000` (acked with
cmd+1 anyway), `0x10010` (→ `0x10011` with body), `0x10690`, `0x103e0`, `0x70000000`, `0x70000001`,
`0x201c1`, `0x10600` (body), `0x10450` (clock mode, default empty = same as cmd+1).

---

## 12. Bike profiles

### 12.1 What a profile is (`BikeProfile.kt:68-132`)

A strategy object selected per dash. Members and defaults:

| Member | Default | Meaning |
|---|---|---|
| `name` | — | log label |
| `score(info)` | — | claim strength for a CLIENT_INFO; highest positive wins, 0 = no claim (`:73`) |
| `matchesModelId(id)` | `false` | early match on the QR `modelid` (`:80`) |
| `aaVideo` | — | Android Auto resolution + dpi (AA only; iOS: layout hint) (`:83`) |
| `requiresSockServerAuth` | — | **unused flag** (`:87`) |
| `supportsScreenTouch` | — | default for `advertisesScreenTouch` (`:88`) |
| `advertisedSupportFunction` | — | `supportFunction` in our reply (`:90`) |
| `buildClientInfoReply` | — | §8 (`:93`) |
| `handleUnknownControl` | — | §11 (`:99-101`) |
| `roundCaptureDimensions(w,h)` | `(w & 0xFFF0, h & 0xFFF0)` (round down to a multiple of 16); **no profile overrides it** | media config-capture reply (`:105`, used at `EasyConnProber.kt:751`) |
| `forceBaseline` | `true` | H.264 Baseline@3.1 (`:108`) |
| `videoBitrate` | `2_500_000` b/s | (`:112`) |
| `videoFrameRate` | `30` fps | (`:114`) |
| `videoIFrameIntervalSec` | `1` s | (`:116`) |
| `versionReply()` | `(3, 1)` | **unused**: the media GET_VERSION reply is hard-coded `3, 1` (`EasyConnProber.kt:766-770`) (`:119`) |
| `panelSize` | `null` | measured panel (w,h), letterbox/margin math (`:125`) |
| `defaultMargins` | `[0,0,0,0]` (top, bottom, left, right, dash px) | insets until the rider customises (`:131`) |

### 12.2 Registry and tie-break order (`BikeProfile.kt:146-155`)

`[Nk800, Cfdl26NkTouch, MoriniMlSoftAp, Cfdl16MotoPlayLandscape, ClC450, Cfdl26Landscape,
Cfdl26Portrait, LegacyCfdl16]`. Ties go to the **earlier** entry (Kotlin `maxByOrNull` keeps the first
maximum). Legacy is also the universal fallback (`BikeProfile.kt:136`).

### 12.3 Per-profile attributes (all VERIFIED-CODE)

| Profile (`name`) | QR modelIds | supportsScreenTouch | supportFunction | sockAuth flag | panelSize | aaVideo (AA only) | encoder | defaultMargins | Reply extras |
|---|---|---|---|---|---|---|---|---|---|
| `LegacyCfdl16Profile` "CFDL16 / legacy (BIKE A)" `:406-441` | `37416` | false | 0 | false | null | 800×480 @160 | defaults | 0 | — |
| `Nk800Profile` "CFMoto 800NK (CRCP / sdk 0.9.23.x)" `:460-498` | `66660703`, `66660721`, `66660732` | false | 128 | false | null | 800×480 @160 | defaults | 0 | — (deliberately no touch) |
| `Cfdl26PortraitProfile` "CFDL26 / MotoPlay Portrait (1000 MT-X)" `:514-581` | `37426` | **false** (touch locked by default on the TFT; handlebar-driven) | 128 | true | 800×951 | 720×1280 @240 | defaults | 0 | `supportScreenTouch:true` only with Force touchscreen |
| `Cfdl26NkTouchProfile` "CFDL26 / 800NK Advanced (touch, 720×712)" `:591-629` | `37426` | true | 128 | true | 720×712 | 720×1280 @160 | defaults | **[22,0,0,0]** (blanks MotoPlay pull-down) | `supportScreenTouch:true` |
| `Cfdl16MotoPlayLandscapeProfile` "CFDL16 / MotoPlay Landscape (modelId 66660742)" `:632-657` | `66660742` | false | 128 | false | 800×400 | 800×480 @160 | defaults | 0 | — |
| `ClC450Profile` "CL‑C450 (544×512)" `:660-685` | `66660736`, `CLC450` | false | 0 | false | 544×512 | 1280×720 @160 | defaults | 0 | — |
| `MoriniMlSoftApProfile` "Morini SoftAP / Alltrhike (MLN)" `:703-749` | `21333`, `21322` | false | 128 | false | 1024×464 | 800×480 @160 | **no forced Baseline; 2 000 000 b/s; 10 fps; IDR every 2 s** | 0 | — |
| `Cfdl26LandscapeProfile` "CFDL26 / MotoPlay Landscape (800MT)" `:751-812` | `37426` | true | 128 | true | 1280×576 | 800×480 @160 | defaults (Baseline; Main/High was a black-screen suspect, `:799-805`) | 0 | `supportScreenTouch:true` |
| `LearnedGeometryProfile` (wrapper) `:688-696` | — | base | base | base | measured | bestFit res @ base dpi | base | base | base; name = `"<base> + measured WxH"` |

All profiles: unknown-frame policy = cmd+1 (§11); clock handling = global (§13), no per-profile clock mode.

### 12.4 Scoring rules (exact)

Missing keys follow `opt*` semantics (§7). `startsWith` is case-sensitive unless noted.

**Nk800** (`BikeProfile.kt:479-489`): `crcp = HUID.startsWith("CRCP")`, `sdk = sdkVersion.startsWith("0.9.23")`,
`lp = package_name == "linux_no_package"`. If `!crcp && !(sdk && lp)` → **0**. Else `4·crcp + 3·sdk + 2·lp`.

**Cfdl26NkTouch** (`:602-619`), `s = 0`:
`+4` version_name starts `CFDL26`; `+3` package_name == `com.cfmoto.easyconnect`; `+2` enableSockServerAuth;
`+2` sdkVersion non-empty and not starting `0.` (**not** gated on looking like CFMoto); `+1` if `s > 0` and
supportFunction == 128; `+4` HUID starts `6KWV`; `−4` supportLandscapeAdaptive; `+1` supportMirrorOverlayTouch;
`+1` supportScreenTouch. (No `CARB` guard.)

**MoriniMlSoftAp** (`:728-741`), `s = 0`: `+12` channel ∈ {`21333`,`21322`}; `+8` HUID starts `CARB`
(ignore case); `+6` flavor == 51; `+1` package_name empty **and** `s > 0`; `+2` sdkVersion starts `1.0.13`;
`+1` **not** supportScreenTouch (applies even when everything else is 0).

**Cfdl16MotoPlayLandscape** (`:642-649`): `+10` channel == `66660742`; `+2` sdkVersion starts `0.9`;
`+1` supportLandscapeAdaptive; `+1` not supportScreenTouch.

**ClC450** (`:671-677`): `+8` channel == `66660736`; `+4` HUName contains `48FB4C` (ignore case);
`+1` sdkVersion starts `0.9.23`.

**Cfdl26Landscape** (`:767-790`): `looks26 = version_name starts CFDL26 || package_name contains "cfmoto" || contains "cfdash"` (ignore case);
`+4` version_name starts `CFDL26`; `+2` looks26 and sdk non-empty, not `0.`; `+2` enableSockServerAuth;
`+3` package_name == `com.cfmoto.easyconnect`; `+1` if `s > 0` and supportFunction == 128; `+4` looks26
and supportLandscapeAdaptive; `+3` HUID starts `6WWV`; `−1` not supportScreenTouch; finally **`s = 0`** if
HUID starts `CARB` (ignore case).

**Cfdl26Portrait** (`:528-547`): **return 0** if HUID starts `CARB` (ignore case); `+4` version_name starts
`CFDL26`; `+2` looks26 and sdk non-empty, not `0.`; `+2` enableSockServerAuth; `+3` package_name ==
`com.cfmoto.cfdashmotoplay`; `+1` if `s > 0` and supportFunction == 128.

**Legacy** (`:420-426`): `s = 1` (floor); `+4` HUName starts `CFDL16`; `+3` sdkVersion starts `0.9.29`;
`+2` channel (trimmed) == `37416`.

### 12.5 Selection algorithms

**Authoritative, from CLIENT_INFO** (`BikeProfiles.select`, `BikeProfile.kt:160-168`):
1. If the Setup override is not AUTO → return it (log `[profile] manual override → <name>`).
2. Score every profile in registry order; log `[profile] scores=<name>=<score>, …`.
3. Keep scores `> 0`; pick the highest, **first wins ties**; none → Legacy.

**Early, from the QR, before connecting** (`selectByQr` / `selectByQrGuess`, `BikeProfile.kt:174-205`):
1. Override not AUTO → return it.
2. No QR → Legacy.
3. SSID starts `MLN_` (ignore case), **or** SSID starts `ML` (ignore case) **and** modelId ∈ {`21333`, `00297`}
   → MoriniMlSoftAp. (Morini QRs put `ProductID` into modelId, e.g. `00297`, `QrData.kt:145-155`.)
4. `matches = registry.filter { matchesModelId(modelId ?: "") }`: none → Legacy; exactly one → it;
   several (only `37426`: NkTouch, Landscape, Portrait) → Portrait if `qr.supportsP2p` (QR `action`
   bit 3, `QrData.kt:39`) or SSID starts `DIRECT-`, else **Landscape** (never NkTouch from QR).
5. With a context: if `DashMemory` holds a measured canvas for this SSID (learned from a previous
   `REQ_CONFIG_CAPTURE`, `DashMemory.kt:31-52`) and it differs from `base.panelSize`, and
   `DashMemory.bestFit(w,h)` finds a resolution (`DashMemory.kt:58-65`: candidates where one axis equals
   the 16-rounded panel axis exactly and the other is ≥; minimise `(rw-cw)(rh-ch)+(rw-cw)+(rh-ch)`), wrap
   the base in `LearnedGeometryProfile`.

`selectByModelId(id)` (tests only) returns the **first** registry match (`BikeProfile.kt:208-209`).

**Refinement when CLIENT_INFO arrives** (`PxcHandshake.kt:149-178`):
1. `profile = select(json)`.
2. `early = BikeProfileHolder.active` (the QR guess). If `early.panelSize` is "wide"
   (`w >= h*3/2`, integer math) **and** `profile` is Cfdl26NkTouch → keep `early` (prevents real 800MT
   landscape units being re-routed to the near-square Advanced profile mid-session, `:152-161`).
3. `BikeProfileHolder.active = profile` (authoritative).
4. AA-only: if no explicit override and the effective AA spec changed, pin AA to what it started with
   (`:167-177`). Not relevant to iOS.
5. Build and send the reply with the new profile (§8).

**Manual override** (`ProfileOverride.kt:13-37`): ids `auto` (default), `legacy`, `nk800`, `nk_adv`
(Cfdl26NkTouch), `cfdl26_land`, `cfdl26_port`, `clc450`; unknown id → AUTO. **No override exists for
MoriniMlSoftAp or Cfdl16MotoPlayLandscape.** Stored per garage bike under key `profile_override`
(prefs `opencfmoto_bike`), scoped as `"profile_override#b<hex(qrRaw.hashCode())>"` with fallback to the
unscoped key (`ProfileOverride.kt:39-61`, `BikeScope.kt:14-31`).

### 12.6 Scoring worked examples (DERIVED by re-running the exact rules)

Inputs A and B use documented field values (`docs/01 §0, §7.0`); the others are hypothetical inputs
chosen to exercise the rules.

| Case (input) | Nk800 | NkTouch | Morini | MP-66 | ClC450 | Land | Port | Legacy | **Selected** |
|---|---|---|---|---|---|---|---|---|---|
| A 675SR CFDL16: HUID 6GUV…, HUName CFDL16-6GUV, sdk 0.9.29.1, sF 0, no touch | 0 | 0 | 1 | 3 | 0 | −1 | 0 | 8 | **Legacy** |
| B 1000 MT-X: HUID 6WX0…, pkg cfdashmotoplay, CFDL26.2.3.5.0.6, sdk 1.1.4, sockAuth, touch, overlayTouch, sF 128 | 0 | 11 | 0 | 0 | 0 | 9 | **12** | 1 | **Portrait** (beats NkTouch by 1) |
| C 800MT AP: HUID 6WWV…, pkg easyconnect, CFDL26, sdk 1.1.2, sockAuth, touch, landscapeAdaptive, sF 128 | 0 | 9 | 0 | 1 | 0 | **19** | 9 | 1 | **Landscape** |
| D 800NK Adv: HUID 6KWV…, pkg easyconnect, CFDL26, sdk 1.1.2, sockAuth, touch, overlayTouch, sF 128 | 0 | **18** | 0 | 0 | 0 | 12 | 9 | 1 | **NkTouch** |
| E US 800NK: HUID CRCP…, linux_no_package, sdk 0.9.23.4, sF 128 | **9** | 0 | 1 | 3 | 1 | −1 | 0 | 1 | **Nk800** |
| F Morini: HUID CARB…, channel 21333, flavor 51, pkg "", sdk 1.0.13.1 | 0 | 2 | **30** | 1 | 0 | 0 | 0 | 1 | **Morini** |
| G CL-C450: HUName …48FB4C, channel 66660736, sdk 0.9.23.4 | 0 | 0 | 1 | 3 | **13** | −1 | 0 | 1 | **ClC450** |
| H channel 66660742, sdk 0.9.25.1, landscapeAdaptive | 0 | −4 | 1 | **14** | 0 | −1 | 0 | 1 | **MP-66** |
| I unknown, non-touch, sdk 1.2.0, no other markers | 0 | **2** | 1 | 1 | 0 | −1 | 0 | 1 | **NkTouch** (!) |
| J unknown, non-touch, sdk 0.9.30 | 0 | 0 | 1 | **3** | 0 | −1 | 0 | 1 | **MP-66** |
| K unknown, touch, sdk 1.2.0 | 0 | **3** | 0 | 0 | 0 | 0 | 0 | 1 | **NkTouch** |
| L CFDL06.6.10 / net.easyconn / sdk 0.9.25.1, sF 128 | 0 | 0 | 1 | **3** | 0 | −1 | 0 | 1 | **MP-66** |

Notable quirks the iOS port must reproduce for parity (or fix knowingly, §19): (I/K) any sdk-1.x dash
without CFMoto markers lands on **Cfdl26NkTouch** (advertises `supportScreenTouch:true`, 22 px top
inset) unless its QR/learned profile is wide (keep-landscape rule); (J/L) any non-touch sdk-0.9.x dash
without the CFDL16/0.9.29/37416 markers lands on Cfdl16MotoPlayLandscape (reply `supportFunction:128`
instead of Legacy's 0).

### 12.7 Repo test vectors (`test/BikeProfileSelectTest.kt`)

```
Nk800.matchesModelId("66660703") == true;  ("66660721") == true;  ("66660732") == true
Nk800.matchesModelId("37426") == false;    ("37416") == false                        (:17-21)
selectByModelId("66660703") == Nk800Profile                                           (:26)
selectByModelId("37426") == Cfdl26NkTouchProfile   (first registry hit)              (:29)
Cfdl26PortraitProfile.supportsScreenTouch == false
Cfdl26LandscapeProfile.supportsScreenTouch == true
Nk800Profile.supportsScreenTouch == false                                             (:34-36)
```

(The same file's button-mapping tests belong to the handlebar spec.)

---

## 13. Dash clock

Two Wi-Fi frames (`0x10600`, `0x10450`) on the PXC control plane, plus an opt-in BLE side channel
(EC-BTP). None of them is needed for video, but answering the Wi-Fi ones is needed to keep CFDL26-class
dashes moving (burst gate) and to avoid clocks jumping to 1970/00:00.

### 13.1 HU_TIME_SYNC request `0x10600` (B→P) — VERIFIED-HW layout (`BikeProfile.kt:314-316`, `docs/01 §7.2`)

Sent about **every 2 s** by dashes whose CLIENT_INFO has `supportSyncCorrectTime:true`
(`PxcFrame.kt:83-85`). Live payload is **45 bytes**:

```
offset size type       field (names INFERRED)
0      4    int32 LE   flags        = -2  (FE FF FF FF)
4      4    int32 LE   channel / modelId (e.g. 37426 = 32 92 00 00)
8      4    int32 LE   seq
12     4    int32 LE   0
16     29   ASCII      "yyyy-MM-dd HH:mm:ss.SSS000000"   (no terminator; 9 fractional digits = ms + "000000")
```

Field variants seen: shorter fractional part (`"2026-08-13 14:05:20.190"`, 23 chars) and a `T`
separator (git `441cc41` message: "short or T-separator stamps fell through to a phone rewrite").

### 13.2 Reply `0x10601` (`HuTimeSync.ack`, `BikeProfile.kt:338-398`) — VERIFIED-CODE (default "echo")

Never empty. Algorithm, exactly:

```
len   = max(45, request.count)
out   = zeros(len); copy request[0 ..< min(request.count, len)] into out
if request.count < 16:                      // missing/short header -> synthesize
    out[0..<16] = int32LE(-2), int32LE(0), int32LE(1), int32LE(0)
bikeStamp = extractStamp(request)           // see below
if !forcePhone && shouldEcho(bikeStamp, request):
    mode = "echo"                           // out already holds the bike's bytes (zero-padded to 45)
else:
    mode = "phone"
    stamp = phoneStamp()                    // 29 ASCII chars
    out[16 ..< 16+29] = stamp               // header bytes stay as copied/synthesized
send PxcFrame(0x10601, out)

extractStamp(buf): if buf.count < 16 -> ""; else ASCII(buf[16 ..< 16+min(29, buf.count-16)])
                   with trailing NUL (0x00) and space characters trimmed
shouldEcho(stamp, req):
    req.count < 16                               -> false
    stamp blank, or only NUL/space characters    -> false
    if regex ^(\d{4})-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2} matches at the start
       and year is 1969...1971                   -> false
    otherwise                                    -> true   (any other content, even garbage, is echoed)
phoneStamp(): ms = now epoch millis
              format(ms, "yyyy-MM-dd HH:mm:ss", Locale.US, device default time zone)
              + "." + 3-digit (ms % 1000) + "000000"
```

`forcePhone` is the Clock-lab "phone" knob (default off) (`PxcHandshake.kt:94-95`). The time zone is
re-read on every call (`BikeProfile.kt:390`); no zone information is put on the wire. `isSaneStamp`
(year 2020–2099, `BikeProfile.kt:381-385`) is only used by tests now. Logging: first 3 acks, then at
most one line per 30 s (`PxcHandshake.kt:97-103`).

Vectors (DERIVED, plus repo tests in §16.1). Request = `HuTimeSyncTest.req("2026-07-24 17:09:20.190000000")`
(modelId 37426, seq 7):

```
request 0x10600, totalLen 61 (0x3d), magic 0x1063d
00 06 01 00 3d 00 00 00 3d 06 01 00 00 00 00 00
fe ff ff ff 32 92 00 00 07 00 00 00 00 00 00 00
32 30 32 36 2d 30 37 2d 32 34 20 31 37 3a 30 39
3a 32 30 2e 31 39 30 30 30 30 30 30 30
echo ack 0x10601, totalLen 61, magic 0x1063c  (payload identical to the request)
01 06 01 00 3d 00 00 00 3c 06 01 00 00 00 00 00
fe ff ff ff 32 92 00 00 07 00 00 00 00 00 00 00
32 30 32 36 2d 30 37 2d 32 34 20 31 37 3a 30 39
3a 32 30 2e 31 39 30 30 30 30 30 30 30
```

Phone-mode payloads at `now = 1786272219244` ms, zone Europe/Rome (CEST): stamp
`2026-08-09 12:43:39.244000000`.

```
forcePhone (header kept):   fe ff ff ff 32 92 00 00 07 00 00 00 00 00 00 00
                            32 30 32 36 2d 30 38 2d 30 39 20 31 32 3a 34 33 3a 33 39 2e 32 34 34 30 30 30 30 30 30
empty request (synth hdr):  fe ff ff ff 00 00 00 00 01 00 00 00 00 00 00 00  + same 29 ASCII bytes
1970 request -> phone mode, header kept: same as the forcePhone payload
short 39-byte request (stamp "2026-08-13 14:05:20.190") -> echo, ack padded to 45:
fe ff ff ff 01 00 00 00 01 00 00 00 00 00 00 00
32 30 32 36 2d 30 38 2d 31 33 20 31 34 3a 30 35 3a 32 30 2e 31 39 30 00 00 00 00 00 00
```

What the echo means: the phone acknowledges the dash's own clock without correcting it. Phone time is
only written when the dash reports epoch/blank.

### 13.3 What was tried and failed (git history + docs) — VERIFIED-HW (field reports)

| Version | Behaviour | Field result | Source |
|---|---|---|---|
| ≤ 2.0.6 | `0x10600` acked **empty** | Morini X-Cape → 1970, QJ → 00:00, Voge DS800 wrong | `docs/07 §A9` (`07-IDEAS-AND-ISSUES.md:118-122`), `PxcFrame.kt:84-85` |
| 2.0.7–2.0.8 | reply with **phone** time in the 45-byte layout; CLIENT_INFO advertised `supportSyncCorrectTime:true` | Zontes/Voge → 00:00; Voge/QJ/X-Cape jumped **hours** (minutes stayed: TZ/format applied) | `BikeProfile.kt:304-307, 318-319`; git `1282311` |
| 2.0.9 | stop advertising `supportSyncCorrectTime`; echo only strictly-formatted sane stamps, else phone time | still jumped hours (short / `T` stamps fell through to phone rewrite) | git `1282311`, `441cc41` |
| 2.0.10+ | **echo any non-epoch stamp**, phone time only for empty/blank/1969–1971 | current default | `BikeProfile.kt:320-323`; git `441cc41` |
| 2.0.11-pre / 2.0.12-pre | answer `0x10450` with Carbit JSON for every dash; 2.0.12 also pushed an **unsolicited** `0x10601` after CLIENT_INFO/QUERY_TIME and added `currentHUTime` (phone ms since local midnight) to the reply | Griffin / X-Cape / Voge / QJ jumped hours | `HuQueryTime.kt:14-17`; git `f6e09dd`, `104b47b` |
| 2.0.13 → 2.0.18 | reverted to empty `0x10451`, no push, no `currentHUTime`; JSON bodies only via the Clock lab | current default | git `26726f1`; `docs/RELEASE-2.0.18.md:20-21` |

### 13.4 HU_QUERY_TIME `0x10450` → `0x10451` (`PxcHandshake.kt:106-136`, `HuQueryTime.kt`)

The bike asks for the wall clock (`ECP_C2P_QUERY_TIME`, payload often empty). Reply depends on
`ClockLab.query`:

| Mode id | Reply | Status |
|---|---|---|
| `empty` (default) | `0x10451` with **empty** payload | VERIFIED-CODE (Latest 2.0.13+; README: QJ 550SX/600SX "Clock = Latest empty+echo", `README.md:163`) |
| `carbit` | `{"time":<epochMillis>,"dateTime":"dd.MM.yyyy HH:mm:ss:SSS"}` | EXPERIMENTAL (2.0.11/2.0.12 body; jumped hours on several brands) |
| `zontes` | `{"time":<epochMillis>,"currentTime":<epochMillis + zone offset at now, incl. DST>,"currentTimeZone":"<IANA id>","dateTime":"dd.MM.yyyy HH:mm:ss:SSS"}` | EXPERIMENTAL (official Zontes Smart app body) |
| `no_ack` | nothing sent | EXPERIMENTAL tester knob |

JSON is built by string concatenation in exactly this key order (`HuQueryTime.kt:46, 57-58`).
`dateTime` = `SimpleDateFormat("dd.MM.yyyy HH:mm:ss", Locale.US)` in the device zone + `":"` + 3-digit
`ms % 1000` (note the **colon** before the milliseconds and the day-first order)
(`HuQueryTime.kt:22, 32-38`). `time` is UTC epoch ms. A comment notes that an empty `0x10451` can also
mean 1970/00:00 on some dashes (`PxcFrame.kt:88`), which is why this is still an open trade-off.

`ackIfZontes(channel)` returns the Zontes body only for channel `21340` (Zontes 125X)
(`HuQueryTime.kt:20, 62-69`) but is **not called** by the dispatcher anymore (only by tests); the
comment at `HuQueryTime.kt:17` describes a 2.0.16-pre default that no longer exists.

Repo vectors (`test/HuQueryTimeTest.kt`), `now = 1786272219244`, zone `Europe/Madrid` (offset +7 200 000 ms):

```
carbit  -> {"time":1786272219244,"dateTime":"09.08.2026 12:43:39:244"}
zontes  -> {"time":1786272219244,"currentTime":1786279419244,"currentTimeZone":"Europe/Madrid","dateTime":"09.08.2026 12:43:39:244"}
ackIfZontes(null | "" | "21312" | "66660742") == null;  ackIfZontes(" 21340 ") == zontes body
```

### 13.5 Clock lab knobs and presets (`ClockLab.kt`, `AppSettings.kt:31-34, 88-127`) — EXPERIMENTAL

| Knob | Values (id) | Default | Pref key |
|---|---|---|---|
| query (`0x10450`) | `empty`, `carbit`, `zontes`, `no_ack` (unknown id → empty) | `empty` | `clock_lab_query` |
| timeSync (`0x10600`) | `echo`, `phone` (unknown → echo) | `echo` | `clock_lab_timesync` |
| bluetooth (EC-BTP listener) | on/off | off | `bluetooth_clock_sync` |
| keepWifi (stay on bike Wi-Fi after Stop; "some dashes drop the clock when SoftAP/P2P dies") | on/off | off | `keep_wifi_after_disconnect` |

Presets (fill query/timeSync/bluetooth only, keepWifi untouched) (`ClockLab.kt:62-70`):
`LATEST` = empty/echo/off · `V2012` = carbit/echo/off · `ZONTES` = zontes/echo/off ·
`PHONE_SYNC` = empty/phone/off · `BT_LISTEN` = empty/echo/on. Log banner, once per process:
`[CLOCK-LAB] query=<id> timeSync=<id> bt=<on|off> keepWifi=<on|off> channel=<CLIENT_INFO channel or ->`
(`ClockLab.kt:86-91`). Repo vectors: `test/ClockLabTest.kt:15-60`, e.g. defaults →
`"[CLOCK-LAB] query=empty timeSync=echo bt=off keepWifi=off channel=-"`; zontes/phone/bt=on with channel
`21340` → `"[CLOCK-LAB] query=zontes timeSync=phone bt=on keepWifi=off channel=21340"` and no matching preset.
The UI tells testers not to ride with a non-default combo (`res/values/strings.xml:386`).

### 13.6 EC-BTP: dash clock over Bluetooth LE (`EcBtpProtocol.kt`, `EcBtpTimeLink.kt`) — EXPERIMENTAL

**Transport: Bluetooth LE GATT, not PXC/TCP. Not needed for projection.** Off by default; started
right before the PXC prober when the `bluetooth_clock_sync` setting is on (`DashClockBle.kt:12-22`,
`BikeLink.kt:101, 134`). Purpose: "Some dashes ask for the time over Bluetooth, not Wi-Fi, and sit at
00:00 without it" (`res/values/strings.xml:384`).

Frame (`EcBtpProtocol.kt:11-21, 42-64`):

```
0x24 | CMD | LEN | payload... | XOR | 0x0A
LEN = payload.count + 4 (one byte)        XOR = 0x24 ^ CMD ^ LEN ^ every payload byte
parse rejects: < 5 bytes, first != 0x24, last != 0x0A, LEN-4 < 0, LEN-4+5 != buffer.count, bad XOR
```

| Cmd | Dash asks | Phone reply payload | Source |
|---|---|---|---|
| `0x01` SYNC_TIME | (request payload ignored) | 8 bytes LE of `nowMillis + zone.rawOffset` (**raw offset, no DST**) | `EcBtpProtocol.kt:25, 66-73`, `EcBtpTimeLink.kt:134-135` |
| `0x55` QUERY_TIME | (ignored) | UTF-8 `"dd.MM.yyyy HH:mm:ss:zzz"` (zone **short name**, device default Locale), truncated to 120 bytes | `EcBtpProtocol.kt:26-27, 75-80` |

Link rules (`EcBtpTimeLink.kt`): never scans; opens GATT (LE first, then AUTO) only to **already
bonded** devices whose name looks like a dash (§13.7), or that have no cached UUIDs, or that cache one
of the service UUIDs; subscribes to notifications (CCC `00002902-…`); **never writes until the peer has
sent a valid EC-BTP frame**; replies with `WRITE_TYPE_NO_RESPONSE` on the same characteristic; ignores
other commands. Services: `00001c00-d102-11e1-9b23-000efb0000b2`, `0000474d-0000-1000-8000-00805f9b34fb`,
`00001c00-d102-11e1-9b23-000efb0000c3`, `0000474e-0000-1000-8000-00805f9b34fb`,
`00001c00-d102-11e1-9b23-000efb0000c6`, `0000ffe0-…`, `0000fff0-…`. Characteristics:
`00001c0f-d102-11e1-9b23-000efb0000b2`, `00004b59-0000-1000-8000-00805f9b34fb`,
`00001c0f-d102-11e1-9b23-000efb0000c6`, `0000ffe1-…`, `0000fff1-…` (`EcBtpTimeLink.kt:190-207`).

Vectors (`test/EcBtpProtocolTest.kt` + DERIVED bytes):

```
syncTimeReply(0x0102030405060708, 0) -> 24 01 0c 08 07 06 05 04 03 02 01 21 0a   (13 B; test checks all but XOR)
syncTimeReply(0, 7_200_000) parses back to payload value 7200000                   (:28-37)
queryTimeReply(Date(1786272219244), Europe/Rome, Locale.UK) payload "09.08.2026 12:43:39:CEST"  (:40-48)
  frame: 24 55 1c 30 39 2e 30 38 2e 32 30 32 36 20 31 32 3a 34 33 3a 33 39 3a 43 45 53 54 7f 0a
build(0x01, [01 02 03 04]) -> 24 01 08 01 02 03 04 29 0a
parse([24 01 05]) == null; parse(good with byte0=0x23) == null; parse("OK+CONN") == null  (:51-56)
```

### 13.7 Dash name markers (`DashClock.kt:8-21`)

`nameLooksLikeDash(name)`: trimmed, non-empty, uppercased name **contains** any of
`MLN, ZM_, ZM-, VOGE, CFMOTO, QJ, GRIFFIN, MORINI, XCAPE, X-CAPE, CARBIT, EASYCONN, YUNMO, ALLTR, MURTAS,
RRX, ZT, P2P, SOFTAP`. Vectors (`test/DashClockTest.kt:10-19`): true for `MLN05D250`, `MLN_p2p_7017`,
`ZM_CB42`, `VOGE-006348`, `MURTAS-RRX`, `RRX-2026`, `ZT851066`; false for `WH-1000XM5`, `Galaxy Watch`, `null`.

### 13.8 Which bikes need what (summary)

| Dash | 0x10600 | 0x10450 | Notes |
|---|---|---|---|
| CFDL26 (1000 MT-X/800MT/800NK Adv) | sent when `supportSyncCorrectTime`; must be acked (part of the burst) | sent empty; ack | `docs/01 §7.2` |
| US 800NK CRCP | — | sent; ack (cmd+1 / empty) | `BikeProfile.kt:457` |
| Morini / Voge / QJ | echo (2.0.10+) fixed the 1970/00:00 and hour jumps for reporters; keep default | default empty | `docs/SUPPORTED-BIKES.md:81, 96` |
| X-Cape / Voge / Griffin | reportedly never sent | filled JSON made clocks jump hours | git `26726f1`, `HuQueryTime.kt:14-16` (INFERRED) |
| Zontes 125X (channel 21340) | — | official app sends the Zontes body; app default is still empty | `HuQueryTime.kt:14-20` (EXPERIMENTAL) |
| Dashes that only ask over BLE | — | — | EC-BTP (§13.6), EXPERIMENTAL |

If `0x10600` is left **unanswered**: not tested. On CFDL26 every burst frame gates the media ports, so
assume the session stalls. Empty reply → 1970/00:00 on several brands (§13.3).

---

## 14. Navigation, media, Bluetooth and other dash notifications

- **Turn-by-turn / navigation push over PXC: none implemented.** The phone never sends navigation data
  on the control plane. Hint of a native feature: CFDL26 sends `0x10040 {maxNaviIcon:161,supportFunction:0}`
  (`docs/01 §7.2`), i.e. the dash knows turn icons up to id 161; the command the phone would use to push
  icons is unknown. Yunmo dashes have a "SimpleNavi" compact-arrow display state (§15) whose data
  command is also unknown. For iOS: render turn-by-turn into the video stream (own dash UI). INFERRED
- **Media / voice / BT notifications** (all acked cmd+1, contents ignored): `0x10020`
  `{music,talkie,tts,vr,autoChangeToBT}`, `0x10460 {bluetooth:4129}`, `0x10470` voice-command grammar,
  CLIENT_INFO `supportBTCall`, `btPin`, `bluetoothPolicy:2`. Nav prompts play on the phone/helmet, not
  the bike speakers (`README.md`, "Normal behavior"). VERIFIED-HW (frames), INFERRED (meaning)
- **Handlebar buttons do not use PXC.** They arrive as Bluetooth AVRCP media/volume keys on the phone
  (`MediaButtonBridge.kt`; `README.md` "[BTN] media key …"). No PXC key-event frame is handled.
  VERIFIED-CODE
- **Dash touch** arrives on the media control socket (:10921, ReqBase cmdType 32), not here; the only
  control-plane touch knob is `supportScreenTouch` in our CLIENT_INFO reply (§8). The `0x30040`
  SCREEN_TOUCH control cmd exists but was never observed (`BikeProfile.kt:574`).
- **OTA**: `0x103a0` announces the dash's own Carbit FTP OTA server (`bike:11021`). It is the upload
  target for firmware; writing to it can brick the dash. **Never connect or upload; read-only LIST at
  most for recon** (`docs/01 §7.4`). `0x104a0` asks the phone to act as a SOCKS5 uplink on
  ctrl 11026 / data 11025; not required for a stable link, and the dash never dialled it in tests
  (`PxcFrame.kt:79-80`, `docs/RE-VEHICLE-TELEMETRY.md:56-69`). Log redaction must mask `pwd`/`btPin`
  (`LogRedactor.kt:17-20`).
- **Vehicle telemetry**: not available over PXC, BLE or the dash network without a T-Box
  (`docs/RE-VEHICLE-TELEMETRY.md:71-75`).
- **Must be answered to keep the link up**: channel selects, CLIENT_INFO, QUERY_SPEED, CHECK_SN
  (ack + result), heartbeats in both directions (and phone-initiated beats on both sockets), every
  notify frame (cmd+1), `0x10600` (non-empty body), `0x10450`. Media-plane keep-alives are in the media spec.

---

## 15. Yunmo (Moto Morini X-Cape 1200) — summary for scoping (EXPERIMENTAL, out of scope for v1)

**Which dashes**: MOTOMORINI X-Cape 1200 (official app "Ride MO"), whose SoftAP does not speak EasyConn
(`YunmoFrame.kt:9-16`, `YunmoLink.kt:19-31`). **Status**: "SoftAP / Yunmo joins. TFT stills only on
2.0.14-pre … Not in 2.0.13 / 2.0.18" (`README.md:160`, `docs/RELEASE-2.0.18.md:18`). The 2.0.18 code
still contains the client and tries it after EasyConn discovery fails (`EasyConnProber.kt:416-418, 451-482`).

**Transport**: phone is the **TCP client** to `gateway:8200` (default host `192.168.4.1`), connect timeout
5000 ms, `TCP_NODELAY` (`YunmoFrame.kt:26-27`, `YunmoLink.kt:107-121`). No PXC, no listeners.

**Simple frame** (both directions) (`YunmoFrame.kt:247-261, 324-350`):
```
FE FE FE FE | cmd (1) | len (u16 BIG-endian) | lenCk = (lenHi + lenLo) & 0xFF | payload | ck
ck = (sum of bytes [cmd, lenHi, lenLo, lenCk, payload...]) & 0xFF
reader: resync on FE FE FE FE + cmd != FE; reject lenCk mismatch, len > 10240, bad ck
```
**H.264 frame** (cmd 29, P→B) (`YunmoFrame.kt:263-311`): 8-byte outer header (`FE×4, 29, blocks u16 BE,
(hi+lo)&0xFF`) where `blocks = (ceil(n/32)*32 + 32) / 32`; 32-byte subheader: `[0..3]` AU length u32 LE,
`[4..5]` sum of AU bytes & 0xFFFF u16 LE, `[6]=0`, `[7]=mediaType` (2), `[8..31]` zero in the OEM map
mode the app uses (frameId u32 LE @8 and width/height u16 LE @12/@14 otherwise); then the Annex-B AU
zero-padded to a multiple of 32. No trailing checksum.

**Commands**: `160` (0xA0) display mode / per-frame ACK (`payload[0]==0`, frameId u32 LE at [1..4]);
`176` (0xB0) dim query / mirror companion; `0x32`/`0x33` OK (dimension report: width/height u16 **BE** at
payload [4..5]/[6..7], 16..4096); `0x34` error. Display sub-modes: 5 SimpleNavi (pause video),
6 MapNavi (resume, reset frame id), 7 start mirror, 3/5 exit (`YunmoFrame.kt:18-37`, `YunmoLink.kt:242-268, 306-373`).

**Session**: start recv thread → send `176 [01 00 01]` → wait ≤ 5 s for the dimension (X-Cape reports
1024×464) → map-nav start (no command) or mirror start (`176 [07]` + `160 [07]`) → stream: SPS+PPS first,
SPS+PPS prepended to every IDR, keyframe requested every 1 s, at most 3 unacked frames (2 s timeout then
send anyway) → on stop send `160 [03]`, `160 [05]` (`YunmoLink.kt:83-223, 375-473, 547-615`).

Vectors (DERIVED; plus `test/YunmoFrameTest.kt`):
```
176 [01 00 01] -> fe fe fe fe b0 00 03 03 01 00 01 b8
176 [07]       -> fe fe fe fe b0 00 01 01 07 b9
160 [07]       -> fe fe fe fe a0 00 01 01 07 a9      (test: 10 bytes, [7]=1, ck over [4..8]; :13-28)
160 [03]       -> fe fe fe fe a0 00 01 01 03 a5
160 [05]       -> fe fe fe fe a0 00 01 01 05 a7
encodeH264Ex(50 bytes 0..49, 800, 480, frameId 42): size 104, [5..7] = 00 03 03, [8]=50, [14]=0, [15]=2,
   [16]=42, [20..21]=20 03, [22]=e0, payload at 40, zero pad after 90; OEM-map variant: [16..39] all zero (:40-76)
parseOkDimension(00 00 00 00 04 00 01 d0) -> 1024 x 464 (mapsW/H 2048 x 928) (:102-109)
```
**Stale test:** `test/YunmoFrameTest.kt:110-113` expects `encodeSizeFrom(dim, 800, 480) == 2048×928`, but the
code returns the reported size **1024×464** (`YunmoFrame.kt:236-245`, "vc60: OEM VirtualDisplay =
reported size"). Trust the code comment; the test would fail.

---

## 16. Consolidated repo test vectors (copied)

### 16.1 `test/HuTimeSyncTest.kt`
Request builder: 45 bytes; LE `putInt(-2).putInt(modelId=37426).putInt(seq=7).putInt(0)`; stamp ASCII at 16.
- `"2026-07-24 17:09:20.190000000"` → mode `echo`, stamp equal, payload 45 B, int@0 == −2, bytes 16..44 == stamp (`:23-31`).
- 16-byte header (−2, 1, 1, 0) + `"2026-08-13 14:05:20.190"` → `echo`, stamp starts `2026-08-13 14:05:20` (`:34-42`).
- `"1970-01-01 00:00:00.000000000"` → `phone`, sane stamp, 45 B (`:45-50`).
- empty request → `phone`, 45 B, stamp matches `\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{9}` (`:53-58`).
- sane request with `forcePhone=true` → `phone`, stamp ≠ bike stamp (`:61-67`).
- `isSaneStamp("")`/`("1970-01-01 00:00:00.000000000")` false; `("2026-01-01 00:00:00")`/`("2026-01-01 00:00:00.000000000")` true (`:70-75`).

### 16.2 `test/HuQueryTimeTest.kt` — see §13.4.
### 16.3 `test/ClockLabTest.kt` — see §13.5 (also: `applyPreset(ZONTES)` leaves keepWifi=true untouched, `:45-50`).
### 16.4 `test/EcBtpProtocolTest.kt` — see §13.6.
### 16.5 `test/DashClockTest.kt` — see §13.7.
### 16.6 `test/BikeProfileSelectTest.kt` — see §12.7.
### 16.7 `test/YunmoFrameTest.kt` — see §15 (note the stale `encodeSizeFrom` assertion).
### 16.8 `test/AndroidAutoServiceTest.kt`
`bikeTransportConnected(false,false)=false; (true,false)=true; (false,true)=true; (true,true)=true` (`:10-13`).
### 16.9 DERIVED vectors in this spec
Frames §2.3; CLIENT_INFO reply §8.4; RSA fixture §9.5; time sync §13.2; EC-BTP bytes §13.6; Yunmo §15;
scoring table §12.6.

---

## 17. Discrepancies between docs and code (trust the code unless noted)

| Topic | Docs say | 2.0.18 code does | Source |
|---|---|---|---|
| Auto-ack parity | "unhandled **even-numbered** command → cmd+1" | acks **every** unmatched cmd | `docs/04 §4.1` (`04-APP-KNOWLEDGE-BASE.md:126`) vs `BikeProfile.kt:575-578` |
| Legacy unknown frames | "log only" | cmd+1 like all profiles | `docs/02` (`02-CURRENT-APP.md:92-93`) vs `BikeProfile.kt:431-440` |
| `Cfdl26Profile` | single profile, portrait 720×1280@240 | split into Portrait / Landscape / NkTouch | `docs/02:94-96` |
| `0x10601` | "reply with phone wall-clock" | echo bike stamp unless epoch/blank | `docs/01 §7.2` (`:227`) vs `BikeProfile.kt:320-323` |
| `supportSyncCorrectTime` in our reply | "CLIENT_INFO advertises supportSyncCorrectTime" (2.0.8) | `false` | `docs/07 §A9` (`:124`) vs `BikeProfile.kt:307` |
| Zontes 0x10451 default | "`ackIfZontes` still gates the 2.0.16-pre default" | not called; default empty for all | `HuQueryTime.kt:17` vs `PxcHandshake.kt:106-136` |
| Discovery order | "you can just use the gateway IP + 10930" | NSD first (≤12 s), then :10930, then scan; reconnect uses :10930 first | `docs/01 §2` vs `EasyConnProber.kt:381-413, 644-652` |
| Yunmo canvas | test expects reported×2 | reported size | `test/YunmoFrameTest.kt:110-113` vs `YunmoFrame.kt:236-245` |
| `LOG_REPORT` ack | code comment: "experimental" | docs: verified gate | `PxcFrame.kt:70-72` vs `docs/01 §7.2` |
| X-Cape 1200 profile | README: Setup profile "X-Cape 1200" (2.0.14-pre) | no such override in 2.0.18 | `README.md:160` vs `ProfileOverride.kt:13-21` |

---

## 18. iOS implementation notes

### 18.1 Minimum viable control plane (v1)

1. Join the bike Wi-Fi (other spec). Resolve `myIp` (Wi-Fi interface `en0` via `getifaddrs`) and
   `bikeIp` (§18.4).
2. Start three listeners (10922, 10921, 10920) **before** probing; fail fast with a clear message on
   EADDRINUSE (official CFMoto app on the same phone).
3. Probe with the exact frame of §2.3, retry/timing of §4.2–4.3 (or the faster ordering of §18.5).
4. Control dispatcher of §3.1 + universal cmd+1 fallback (§11).
5. CLIENT_INFO reply of §8 with the RSA identity of §9 and profile selection of §12.
6. 2 s heartbeats on every channel-selected :10922 connection (§10.3).
7. `0x10600` echo algorithm (§13.2) and empty `0x10451` (§13.4). Skip EC-BTP, Yunmo, Clock-lab JSON modes.
8. Reconnect loop (§5.3) and watchdog (§5.4), plus a connect-back timeout Android lacks.

### 18.2 Frame codec (put it in `OpenCfMotoCore`, pure Swift, Linux-testable)

- `struct PxcFrame { cmd: UInt32; payload: Data }`. Encode with `ByteWriter.u32le(cmd)`,
  `u32le(UInt32(16 + n))`, `u32le(cmd ^ totalLen)`, `u32le(0)`, payload. Compare against §2.3 bytes.
- Streaming decoder: `NWConnection.receive` delivers arbitrary chunks; accumulate, parse a 16-byte
  header, check magic on the raw 32-bit values, compute `payloadLen = max(Int(Int32(bitPattern: totalLen)) - 16, 0)`
  for exact Android parity, then wait for the payload.
- **Add a cap** Android lacks: reject `payloadLen > 1 MiB` (largest real control payloads are well under
  2 KB; CLIENT_INFO reply ≈ 800 B) as a protocol error → close the connection (same reaction as bad
  magic). Optionally also reject `totalLen < 16` (Android accepts it as empty); log it either way.
- On bad magic / short payload: close that connection only (matches Android). On a handler error:
  log and keep reading.
- Write each frame with **one** `send(content: header + payload)` call so heartbeat sends and replies
  cannot interleave (Network.framework keeps send order per connection).

### 18.3 Networking with Network.framework

- Listener: `NWParameters.tcp` with `(parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true`,
  `allowLocalEndpointReuse = true` (SO_REUSEADDR), and `requiredInterfaceType = .wifi`; either bind the
  listener to the Wi-Fi address (`requiredLocalEndpoint = .hostPort(host: myIp, port: 10922)`) or listen
  on the port and restrict to the Wi-Fi interface. No read timeout on accepted control connections.
- Probe: `NWConnection` to `bikeIp:10930` with `requiredInterfaceType = .wifi` so the source address is
  the Wi-Fi IP the bike will call back (§1, INFERRED). 3 s connect timeout (use
  `NWProtocolTCP.Options.connectionTimeout = 3`), 5 s read timeout via your own timer.
- **Local Network privacy** (iOS 14+): add `NSLocalNetworkUsageDescription` and
  `NSBonjourServices = ["_EasyConn._tcp"]` to Info.plist. Until the user grants access, LAN connections
  and inbound connections fail (`NWPath` unsatisfied with reason `.localNetworkDenied`). Trigger the
  prompt early (e.g. on QR scan) and surface a clear error.
- NSD equivalent: `NWBrowser(for: .bonjour(type: "_EasyConn._tcp", domain: nil), using: .tcp)`; resolve the
  endpoint (or read the TXT `ip`/`port` keys, §4.3). Some dashes advertise nothing; never wait on
  Bonjour alone.
- VPNs with `includeAllNetworks` and no `excludeLocalNetworks` behave like Android's kill-switch: detect
  and explain.
- Background: iOS suspends a backgrounded app within seconds; sockets and timers freeze, the US 800NK
  drops after ~7 s without phone heartbeats and every dash drops media after ~9 s. The app must keep
  running while projecting (foreground with the idle timer disabled, or a legitimate background mode
  such as navigation location updates/audio). This is a product decision outside this spec, but the
  control plane cannot survive suspension.

### 18.4 Finding the bike address on iOS

iOS has no public "default gateway" API. Use, in order: (1) the Bonjour result's host; (2) the
gateway from the routing table via `sysctl(CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY)`
(BSD API, struct definitions must be copied from `route.h`); (3) Android's fallback: `(myIp & netmask) | 1`
unless `myIp` already ends in `.1` (covers 192.168.0.1, 192.168.49.1, 192.168.4.1).

### 18.5 Probe ordering (optional improvement)

Android waits up to 12 s on NSD before touching :10930 on a fresh connect. On iOS, run the Bonjour
browse in parallel and probe `bikeIp:10930` immediately; the first **accepted** probe wins and cancels
the other path. Never send a second probe after one was accepted (the reconnect logic already re-probes
when needed). Keep the port scan (10915–10935, 350 ms each) as the last resort for Morini-style
SoftAPs. Add a connect-back timeout (~10 s) after an accepted probe → re-probe.

### 18.6 JSON

- Replies: write JSON with an **ordered** key list (Swift `Dictionary` has no order; `JSONEncoder` with
  `.sortedKeys` gives the wrong order). A tiny `[(String, JSONValue)]` writer is enough. Escape `/` as
  `\/` to be byte-identical to Android (Foundation's `JSONSerialization`/`JSONEncoder` escape `/` by
  default unless `.withoutEscapingSlashes`); booleans and integers bare; no whitespace.
- Probe JSON and the `0x10451` JSON bodies are fixed strings: emit them verbatim.
- Parsing bike JSON: Android's org.json is lenient. Trim trailing NUL/whitespace, try `JSONSerialization`
  normally, then with `.json5Allowed` (iOS 15+) before giving up. Implement `optString/optInt/optBoolean`
  helpers with org.json coercions (§7) and make the scoring functions use them.
- If CLIENT_INFO cannot be parsed, Android sends **nothing**; keep that for parity but log loudly
  (an alternative, unverified, is to answer with the Legacy reply and `encryptedHUID:""`).

### 18.7 Identity values to send from an iPhone

Keep the spoof identical to Android: probe `phoneType:"Android"`, reply `phoneOs:"Android"`,
`package:"com.cfmoto.cfmotointernational"`, `versionCode:126`, `pxcVersion:"1.0.2"`, `token:0`,
`bluetoothName:"OpenCfMoto"`, `appVersionFingerPrint:"opencfmoto-poc"`. These are the only verified
values. `phoneBrand`/`phoneModel` vary freely across Android phones; `"Apple"` and the `utsname`
machine id (e.g. `iPhone16,1`) are reasonable. Send `phoneOsVersion` as an Android-API-like string
(`"35"`) for consistency with `phoneOs:"Android"`. Whether `"iOS"` would be accepted is untested (§19).
`phoneUUID`: Android regenerates it per process; either do the same or persist one in the Keychain
(deviation, harmless as far as known).

### 18.8 RSA

Generate the 1024-bit key off the main thread at app start (Android generates it lazily inside the
first CLIENT_INFO handler). Implement §9.4 in `OpenCfMotoApple` (Security framework). Unit-test against
§9.5: import the fixture key, check the SPKI base64 and the `encryptedHUID` base64 byte for byte. If you
want `OpenCfMotoCore` to stay Linux-testable, put a pure-Swift implementation (BigUInt modexp + DER
SPKI builder) behind a protocol and use the fixture for both.

### 18.9 Clock formatting pitfalls

- Use `DateFormatter` with `locale = Locale(identifier: "en_US_POSIX")`, `calendar = Gregorian`,
  `timeZone = .current` (re-read per call). Otherwise 12-hour/Buddhist-calendar settings corrupt the stamp.
- Derive the seconds text and the millisecond digits from **one** integer epoch-millis value
  (`ms = Int64(Date().timeIntervalSince1970 * 1000)`; format `ms / 1000`; append `ms % 1000` padded to 3
  plus `"000000"`), like Java's `Date(ms)` + `ms % 1000`.
- `0x10600` echo must copy the **bytes** (not re-encode a parsed string); pad to 45 with zeros.
- `0x10451` stays empty by default. Never send an unsolicited `0x10601`; never advertise
  `supportSyncCorrectTime:true`.
- EC-BTP (if ever ported): CoreBluetooth cannot enumerate bonded devices; you would scan or call
  `retrieveConnectedPeripherals(withServices:)` for the UUIDs of §13.6. The `zzz` zone short name is
  locale-dependent on iOS too (`CEST` vs `GMT+2`). Low priority.

### 18.10 Profiles on iOS

- Port `score()` functions and `select()` literally, including the quirks of §12.6, as a pure function
  with the §12.6 table as unit tests. Port the QR early pick and the keep-landscape refinement because
  they change the wire reply (`supportFunction`, `supportScreenTouch`).
- Profile fields that still matter without Android Auto: `advertisedSupportFunction`,
  `supportsScreenTouch` (reply), `panelSize` and `defaultMargins` (dash-UI layout hints before the media
  canvas is known), encoder parameters (`forceBaseline`, bitrate, fps, IDR interval) for VideoToolbox,
  and capture rounding (`& 0xFFF0`). `aaVideo` is only a layout hint; there is nothing to pin.
- Store the manual override per garage bike (key derived from the QR raw string). Consider adding
  overrides for Morini and the 66660742 MotoPlay profile, which Android lacks.
- Touch advertising: Android hides touch on the 1000 MT-X because Android Auto would switch to touch UI
  and break handlebar focus. The iOS dash UI does not have that conflict, but whether the dash only
  forwards touches when `supportScreenTouch:true` is unknown. Keep Android's defaults plus a setting.

### 18.11 Concurrency model

One serial executor (actor) per connection for parsing and replies; one shared session actor holding
`profile`, `carHuid`, `lastClientInfo`, `phoneUUID`, RSA keys, clock counters. One `DispatchSourceTimer`
(2 s) per channel-selected control connection, cancelled when the connection ends; dedupe it per
connection (Android does not). Track all connections (control + media) to drive the "all closed →
reconnect" rule.

### 18.12 Logging

Mirror Android's log tags (`[PROBE]`, `[:10922]`, `[hb]`, `[profile]`, `[CLOCK-LAB]`, `[DISC]`) so logs
from both apps can be compared, and redact `pwd`, `password`, `psk`, `btPin` fully and `HUID`/`sn` to
their first 4 characters (`LogRedactor.kt:13-45`).

---

## 19. Open questions / risks

1. **iPhone identity.** Every verified session spoofed `phoneType/phoneOs:"Android"` and the CFMoto
   Android package. Whether a dash accepts `"iOS"` (or switches to a CarPlay/iOS-specific path) is
   unknown. Dashes show separate Android and iOS/CarPlay QRs; Android users report the iOS QR also works
   with this protocol (`README.md:242, 670`).
2. **Does the dash validate `encryptedHUID`/`pubkey`?** Unknown; implement exactly.
3. **Connect-back address.** Inferred that the dash calls back the probe's source IP. If the iPhone has
   several interfaces (cellular + Wi-Fi), a probe leaving the wrong one would silently fail.
4. **Background execution.** 2 s heartbeats and continuous video are incompatible with iOS suspension;
   needs a product-level answer (§18.3).
5. **Local Network permission** denial or delayed prompt blocks everything; Bonjour needs the service
   declared in Info.plist.
6. **Profile scoring quirks** (§12.6): unknown sdk-1.x dashes → NkTouch with a touch claim and a 22 px top
   inset; unknown 0.9.x non-touch → Cfdl16MotoPlayLandscape. First connect and later connects can pick
   different profiles once `DashMemory` has learned a wide canvas. Parity vs fixing is a team decision.
7. **Clock semantics.** Echo leaves the dash clock uncorrected; phone time jumped hours on several
   brands; empty `0x10451` may leave some dashes at 1970/00:00. The 16-byte header field meanings
   (−2, seq) are inferred. Unanswered `0x10600` was never tested.
8. **EC-BTP raw offset** ignores DST (summer time would be one hour off unless the dash adds DST itself).
   Experimental and untested by most riders.
9. **cmd+1 for odd/unknown commands** could, in theory, answer something that is itself a reply. No
   problem observed in the field; keep for parity.
10. **No length cap** in Android; the iOS cap value (1 MiB suggested) is a guess.
11. **Wi-Fi Direct dashes.** The 1000 MT-X group owner (`DIRECT-…`) accepted a normal Wi-Fi join on
    Android (`docs/01 §7.1`), so iOS `NEHotspotConfiguration` should work there (unverified on an
    iPhone). Other GOs (e.g. CL-C450) refuse a normal join and need Android's Wi-Fi P2P API
    (`BikeWifiP2p.kt:7-24`); iOS has no Wi-Fi Direct API, so those dashes may be **unreachable from an
    iPhone** unless they also offer a SoftAP/iOS QR mode. The control plane itself is identical once
    an IP link exists.
12. **Port conflicts** with the official CFMoto iOS app holding 10920–10922 in the background are
    possible; iOS cannot force-stop another app, only tell the user.
13. **Native turn icons** (`0x10040 maxNaviIcon:161`) suggest a Carbit nav-info push that could drive the
    dash's own HUD without video. The command is unknown; would need a capture of the official app.
14. **`socketTimeoutPeriodWifi`** (9 s on known dashes) is in CLIENT_INFO but unused by Android; other
    dashes may use other values. Consider deriving the iOS stall watchdog from it (keep ≤ 8 s by default).
15. **Stale artefacts in the Android repo**: `YunmoFrameTest` canvas assertion, `ackIfZontes` doc comment,
    unused `requiresSockServerAuth` / `versionReply()` / `decryptWithPrivateKey`. Do not port them as
    behaviour.
16. **1024-bit RSA on Apple platforms** works today via `SecKeyCreateRandomKey`, but Apple could tighten
    minimum key sizes; keep the pure-Swift fallback ready.
17. **Bike heartbeat period** (B→P) is undocumented; the phone does not depend on it.
