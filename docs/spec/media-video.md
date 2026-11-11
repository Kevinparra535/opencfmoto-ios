# PXC Media Plane (ports 10921 / 10920) and H.264 Video Pipeline — Implementation Spec

Audience: Swift/iOS engineers re-implementing the OpenCfMoto dash-video path **without reading the Kotlin**.
Source of truth: the Android app "OpenCfMoto" (Kotlin, AGPL-3.0), tree at commit `0abbe2a` (2.0.18 era).

The iOS app will render its **own** dash UI (CoreGraphics), encode it with **VideoToolbox**, and stream it to
Carbit/EasyConnect dashes over the PXC media plane described here. Android-Auto-only machinery is covered only
where it carries protocol knowledge (timing, keyframes, geometry, touch semantics).

---

## Conventions

**Citations.** `File.kt:N` means `app/src/main/java/dev/zanderp/opencfmoto/File.kt` line N (or range `N-M`).
`aa/File.kt:N` is the `aa/` sub-package. `test:File.kt:N` is `app/src/test/java/dev/zanderp/opencfmoto/File.kt`.
Docs are cited by file name, e.g. `01-REVERSE-ENGINEERING.md:150` (= `docs/01-REVERSE-ENGINEERING.md`).

**Evidence tags** (every non-trivial fact carries one):

| Tag | Meaning |
|---|---|
| **[V-HW]** | Verified on real hardware: the docs say confirmed on a real bike, or decisive bike logs are quoted in the docs. |
| **[V-CODE]** | What the shipping Android code path does. The app works in the field with it, but this specific detail was never isolated in a bike test. |
| **[I]** | Inferred (code comments, partial decompile notes, log narrative). Not confirmed. |
| **[X]** | Experimental / unobserved on hardware / behind a toggle / explicitly flagged as unverified. |

**Byte order.** Everything on the media plane is **little-endian**. Hex dumps are byte-by-byte in wire order.

**Conflicts.** Where docs and code disagree, the **code is treated as current truth**; every conflict is listed in §13.

---

## 0. TL;DR for the architect

1. The **phone is the TCP server**. It listens on 10922 (PXC control), **10921 (media control)** and **10920 (media data)**; the bike connects back to all of them after a probe. Framing is chosen by the **local port**: 10922 = 16-byte CmdBaseHead, 10921 and 10920 = **8-byte ReqBase** `cmdType:i16 | cmdLen:u16 | token:i32` (LE) + body. [V-HW] `01-REVERSE-ENGINEERING.md:50-54,98-107`
2. Every media reply is a ReqBase frame with **token = 0** (the request token is read and ignored) and `cmdLen = body length`. [V-CODE] `EasyConnProber.kt:717-728`
3. Media commands: `16→17` config-capture, `48→49` version `(3,1)`, `64→65` heartbeat, `96→97` `{"state":0}`, `112→113` data-start, `114→raw frame` data-next, `128→129` start-H264 (unobserved), `32` touch (no reply). Unknown cmdTypes are logged and **not answered**. [V-HW/V-CODE] `EasyConnProber.kt:730-825`
4. **Canvas negotiation:** the bike asks for `deviceWidth×deviceHeight` in REQ 16; the phone replies RLY 17 with `w & ~15` × `h & ~15` (round **down** to a multiple of 16) and **must encode exactly that size**. CFDL16 800×386 → **800×384**; CFDL26 800×951 → **800×944**; 800MT → **1280×576**. [V-HW] `01-REVERSE-ENGINEERING.md:141-148,239-244`, `05-DEBUG-KNOWLEDGE.md:293`
5. **Pull model, lock-step:** on :10920 the bike sends `114` (empty body) and waits for **exactly one** H.264 access unit, written **raw** (no ReqBase header): `[size:i32 LE][Annex-B access unit]`. No terminator, no timestamp. [V-HW, provenance I] `01-REVERSE-ENGINEERING.md:150-162`, `EasyConnProber.kt:708-715`
6. If no frame is ready within **1500 ms**, Android sends **nothing** for that 114 (just logs). Treat an unanswered 114 as fatal-in-waiting: the bike drops the media link after **~9 s** without a frame (`socketTimeoutPeriodWifi = 9`). [V-CODE / V-HW] `EasyConnProber.kt:806-818`, `01-REVERSE-ENGINEERING.md:19-20`
7. **The first frame after `112` must be SPS+PPS+IDR.** Android flushes its queue, gates output until the next keyframe and forces an IDR on every `112`. This was the root cause of the "black dash" bug. [V-HW] `05-DEBUG-KNOWLEDGE.md:153-189`, `VideoPipeline.kt:670-681`
8. **SPS+PPS are prepended to every IDR** (not only the first), Annex-B exactly as the encoder emits it (MediaCodec: 4-byte `00 00 00 01` start codes [I]), no AUD insertion, no SEI stripping. IDR every **1 s** (30 frames at 30 fps). [V-CODE; cadence V-HW] `VideoPipeline.kt:559-570`, `05-DEBUG-KNOWLEDGE.md:159-162`
9. Encoder: H.264 **Baseline @ Level 3.1**, **no B-frames / no reordering** (the wire carries no PTS), **2.5 Mbit/s** (`×0.7 / ×1.0 / ×1.6` user quality), **30 fps** target, CBR, I-frame interval 1 s. [V-HW] `VideoPipeline.kt:168-251`, `BikeProfile.kt:105-131`
10. **Static screens must keep producing frames.** Android: encoder repeats the last frame after **0.9 s** of no input; the GL compositor re-emits the last frame every **2 s** when idle. Phone-side watchdog: no frame for **8 s** while streaming → drop all sockets and re-probe. [V-CODE] `VideoPipeline.kt:792`, `AaCompositor.kt:105-106`, `AndroidAutoService.kt:696`
11. Frame queue: **8** access units, FIFO, **drop-oldest** on overflow (which can corrupt decoding until the next IDR — avoid this on iOS). [V-CODE] `VideoPipeline.kt:99,575-579`
12. Power modes are a **frame-rate cap** on what is pushed into the encoder: Auto 30 (adaptive), Smooth 30, **Balanced 24 (default)**, Saver 20. Auto adapts bitrate/fps from **thermal status** and **queue-overflow drops (≥ 8 per 5 s tick)**; bitrate floor 600 kbit/s. [V-CODE] `VideoPrefs.kt:48-53,155-159`, `AdaptiveVideoController.kt:26-78`
13. Dash touch arrives as media `cmdType 32` on :10921, coordinates in **canvas pixels, top-left origin**; Android's own-UI path forwards them 1:1 to its UI. (Touch details are covered by another spec.) [V-HW] `05-DEBUG-KNOWLEDGE.md:196`, `GpxSession.kt:114-134`

---

## 1. Mental model

```
 iPhone (TCP server on bike Wi-Fi IP)                         Dash (TCP client)
 ─────────────────────────────────────                         ─────────────────
  listen :10922 :10921 :10920      ── probe :10930 ──▶          (control plane: other spec)
                                   ◀══ connects back to :10922 (×2: CAR_CTRL, CAR_DATA)
                                   ◀══ connects back to :10921  (media control)
  [16] REQ_RV_CONFIG_CAPTURE  ◀─────  w,h,fps,encoder,…,ext,encryptedHUID
  [17] RLY  ───────────────────────▶  encoder=2, w&~15, h&~15, ext
  [48]/[96]/[64] ◀────▶ [49]/[97]/[65]   (version / extend / heartbeat; order not pinned)
  [112] REQ_RV_DATA_START  ◀────────
        (start/attach encoder, flush queue, gate until IDR, force IDR)
  [113] ───────────────────────────▶
                                   ◀══ connects back to :10920  (media data; ~70 ms after 112 on the 800MT log)
  [114] REQ_RV_DATA_NEXT   ◀────────  (empty body)
  RAW  ───────────────────────────▶  [size i32 LE][00 00 00 01 SPS 00 00 00 01 PPS 00 00 00 01 IDR…]
  [114] ◀───   RAW [size][P-frame] ───▶   [114] ◀─── RAW [size][P-frame] ───▶ … (~30 pulls/s observed)
  [64] heartbeat ◀── ──▶ [65]         [32] touch ◀── (no reply)
```

- The bike, not the phone, sets the cadence: one `114` → one access unit → next `114`. [V-HW] `01-REVERSE-ENGINEERING.md:150-157`
- The bike decodes a **timestamp-less** stream; display order must equal decode order. [V-HW reasoning, `05-DEBUG-KNOWLEDGE.md:116-120`; `VideoPipeline.kt:205-210`]
- The bike drops the media connection if it gets **no frame within ~9 s** (`socketTimeoutPeriodWifi = 9` in the bike's CLIENT_INFO, both CFDL16 and CFDL26). **The first frame must arrive fast.** [V-HW] `01-REVERSE-ENGINEERING.md:19-20`. Android never parses this field; the 9 s is hard-won knowledge. [V-CODE] (no reader of `socketTimeoutPeriodWifi` exists in the tree)
- On CFDL26-class dashes the media ports are only opened **after** every post-CHECK_SN control notify frame has been acked (`cmd+1`). That gate belongs to the control-plane spec, but it is the #1 reason "media never starts". [V-HW] `01-REVERSE-ENGINEERING.md:213-233`

---

## 2. Transport: the media sockets

### 2.1 Ports and roles

| Port | Role | Framing | Opened by | Status |
|---:|---|---|---|---|
| 10922 | PXC control (CAR_CTRL + CAR_DATA channels) | CmdBaseHead 16 B | bike → phone | [V-HW] |
| **10921** | **Media control** (config, version, heartbeat, extend, data-start, touch) | **ReqBase 8 B** | bike → phone | [V-HW] |
| **10920** | **Media data** (114 pulls in; raw frames out) | ReqBase 8 B in / raw out | bike → phone | [V-HW] |
| 10930 | Bike probe endpoint (phone connects out once) | CmdBaseHead | phone → bike | [V-HW] |

Constants: `PORT_MEDIA_DATA = 10920`, `PORT_MEDIA_CTRL = 10921`, `PORT_PXC_CTRL = 10922`, `BIKE_PROBE_PORT = 10930` (`EasyConnProber.kt:40-43`).

### 2.2 Listening [V-CODE]

- All three servers are opened **before** probing the bike, bound to the phone's IPv4 on the bike network: `ServerSocket(); reuseAddress = true; bind(InetSocketAddress(myIp, port), backlog = 50)` (`EasyConnProber.kt:194-206`).
- `SO_REUSEADDR` is set **before** bind on purpose: after Stop→Connect the bike's just-closed call-back sockets leave the ports in TIME_WAIT; without reuse the rebind fails, no media server exists, and the dash shows an empty screen (`EasyConnProber.kt:190-193`).
- If any bind fails, another EasyConnect client (normally the official CFMoto app) owns the ports; Android fails fast with an actionable error instead of probing (`EasyConnProber.kt:209-219`).
- The accept loops run for the **whole session**, so the bike can (re)open media sockets any number of times (`EasyConnProber.kt:593-612`).

### 2.3 Per-connection handling [V-CODE]

For every accepted socket (`EasyConnProber.kt:593-612,662-688`):

1. `everConnected = true`, `reconnectAttempts = 0` (any fresh connection resets the retry budget), `liveConns++`, add to `activeClients`.
2. One dedicated thread runs `readLoop(port, socket)`:
   - `soTimeout = 0` (**no read timeout**), `tcpNoDelay = true`, input wrapped in a `BufferedInputStream` (`EasyConnProber.kt:664-667`).
   - Framing by **local port**: `10922` → CmdBaseHead loop; **any other port (10921, 10920)** → `mediaLoop` (ReqBase) (`EasyConnProber.kt:670-682`).
3. On exit (EOF, error, or `running=false`) the socket is closed; `liveConns--`; when it reaches **0** (all bike sockets, control included, are gone) `onAllConnectionsClosed()` re-probes (§9.4).

**Port-agnostic media dispatch.** 10921 and 10920 run the **identical** `mediaLoop` → `handleMediaReq` code; nothing checks which port a cmdType arrived on, and every reply is written to the **same socket the request came in on** (`EasyConnProber.kt:681,692-704`). Writes are `synchronized(out)` per socket; only the socket's own reader thread writes media replies (touch writes nothing). [V-CODE]

**Blocking.** `114` is handled inline on the reader thread and may block it for up to 1500 ms (`EasyConnProber.kt:807`); while blocked, nothing else on that socket is read. Harmless on 10920 because the bike is lock-step. [V-CODE]

### 2.4 Stale sockets [V-CODE]

There is **no per-port stale-socket logic**. A lingering half-open media socket just keeps its reader thread blocked. Recovery is global: the watchdog (`forceReconnect`, §9.5) or `stop()` closes **every** socket in `activeClients` (`EasyConnProber.kt:346-364,314-317`).

---

## 3. ReqBase framing (media plane)

### 3.1 Header (8 bytes, little-endian)

| Offset | Size | Field | Type as parsed by Android | Notes |
|---:|---:|---|---|---|
| 0 | 2 | `cmdType` | **signed** 16-bit (`getShort(0).toInt()`) | all known values < 256 [V-CODE] `EasyConnProber.kt:697` |
| 2 | 2 | `cmdLen` | **unsigned** 16-bit (`& 0xFFFF`) | body length in bytes, excludes the 8-byte header `EasyConnProber.kt:698` |
| 4 | 4 | `token` | signed 32-bit | read, passed along, **never used** `EasyConnProber.kt:699,730` |
| 8 | cmdLen | body | bytes | read fully; short read ⇒ log "media body short" and close the socket `EasyConnProber.kt:700-701` |

Source: `01-REVERSE-ENGINEERING.md:98-107` [V-HW], parse code `EasyConnProber.kt:692-704` [V-CODE].

Read loop semantics: read exactly 8 bytes (EOF/short ⇒ "media closed", close socket), then exactly `cmdLen` bytes (only if `cmdLen > 0`), then dispatch. `PxcFrame.readFully` loops until all bytes arrive; `read() <= 0` is treated as EOF (`PxcFrame.kt:137-145`). [V-CODE]

### 3.2 Replies

`sendReqBase(out, cmdType, body?)` (`EasyConnProber.kt:717-728`) [V-CODE, works on all tested dashes ⇒ V-HW in effect]:

```
i16 LE cmdType | u16 LE len(body) (0 if none) | i32 LE token = 0 (ALWAYS) | body
```

- **Token is always 0** in replies, regardless of the request's token (`EasyConnProber.kt:722`). What tokens the bike sends is unknown (never logged) — see §16.
- One `write(header)`, optional `write(body)`, then `flush()`, all under `synchronized(out)`.

### 3.3 Worked header examples

```
REQ_HEARTBEAT (64) from bike, empty, token 0 : 40 00 00 00 00 00 00 00
RLY_HEARTBEAT (65) from phone                : 41 00 00 00 00 00 00 00
REQ_RV_DATA_NEXT (114), empty                : 72 00 00 00 00 00 00 00
REQ_RV_CONFIG_CAPTURE (16) header, CFDL26 len 204 (0xCC): 10 00 cc 00 tt tt tt tt   (tt = bike token, unknown)
```

---

## 4. Media command catalogue

### 4.1 Summary

| cmdType | Name | Dir | Socket (observed / expected) | Request body | Reply | Android action | Status |
|---:|---|---|---|---|---|---|---|
| 16 | REQ_RV_CONFIG_CAPTURE | bike→phone | **:10921** | ≥32 B struct (§4.2) | **17**, 9-B body | learn + round canvas; AA: size encoder now | [V-HW] |
| 32 | touch event | bike→phone | **:10921** | 18 B (§11) | **none** | ghost-filter, forward to AA or own UI | [V-HW] |
| 48 | REQ_GET_VERSION | bike→phone | :10921 [I] | (ignored) | **49**: `i32 3, i32 1` | — | [V-HW] |
| 64 | REQ_HEARTBEAT | bike→phone | :10921 [I] | (ignored) | **65**, empty | — | [V-HW] |
| 96 | REQ_CONFIGCAPTUREREXTEND | bike→phone | :10921 [I] | JSON (logged, ≤120 chars) | **97**: `{"state":0}` | — | [V-HW] |
| 112 | REQ_RV_DATA_START | bike→phone | :10921 [I] | (ignored) | **113**, empty | **start/attach encoder, flush, force IDR** | [V-HW] |
| 114 | REQ_RV_DATA_NEXT | bike→phone | **:10920** | empty | **raw frame** (no header) | pull 1 AU (≤1500 ms wait) | [V-HW] |
| 128 | REQ_START_H264 | bike→phone | ? | (ignored) | **129**, empty | **nothing else** ("video stage TODO") | [X] |
| other | — | — | — | — | **none** | log `cmdType`, `len`, ≤32 B hex | [V-CODE] |

Table sources: `01-REVERSE-ENGINEERING.md:109-118`, `EasyConnProber.kt:730-825`. The socket for 48/64/96/112 is not recorded in the docs; the code is port-agnostic (§2.3). `05-DEBUG-KNOWLEDGE.md:174-176` places 112 **before** the data socket opens (mirror: "the bike opens the data socket ~70 ms later"), so 112 arrives on :10921 [I].

### 4.2 `16` REQ_RV_CONFIG_CAPTURE → `17` RLY_RV_CONFIG_CAPTURE

#### Request body (LE) — `01-REVERSE-ENGINEERING.md:120-139` [V-HW layout]

| Offset | Size | Field | Parsed by Android? | Android parse | Known values |
|---:|---:|---|---|---|---|
| 0 | 2 | `deviceWidth` (doc: s16) | **yes** | `u16`, 0 if body < 2 B | 800 (CFDL16, CFDL26), 1280 (800MT) [V-HW] |
| 2 | 2 | `deviceHeight` (doc: s16) | **yes** | `u16`, 0 if body < 4 B | 386 (CFDL16), 951 (CFDL26), 576 (800MT) [V-HW] |
| 4 | 4 | `wantFps` | logged only | `i32`, 0 if body < 8 B | not documented |
| 8 | 4 | `wantEncoder` | **yes** | `i32`, **2 if body < 12 B** | 2 = H.264 [V-HW] |
| 12 | 4 | `supportCodec` | no | — | unknown |
| 16 | 2 | `minQuality` | no | — | unknown |
| 18 | 2 | `maxQuality` | no | — | unknown |
| 20 | 4 | `bitRate` | no | — | unknown |
| 24 | 1 | `capScreenMode` | no | — | unknown |
| 25 | 1 | `touchMode` | no | — | unknown |
| 26 | 1 | `orientation` | no | — | unknown |
| 27 | 1 | `displayId` | no | — | unknown |
| 28 | 1 | `videoType` | no | — | unknown |
| 29 | 1 | `supportExtendProtocol` | **yes** | raw byte, **0 if body < 30 B** | echoed |
| 30 | 2 | reserved | no | — | — |
| 32 | rest | `encryptedHUID` (UTF-8) | no | — | CFDL26 total body = **204 B** ⇒ 172 B here [V-HW]; 172 = base64 of 128 B (RSA-1024-sized) [I] |

Parse code: `EasyConnProber.kt:733-738`. **What the app does with `wantFps`, `bitRate`, `minQuality`, `maxQuality`, `orientation`, `capScreenMode`, `touchMode`, `displayId`, `videoType`, `supportCodec`, `encryptedHUID`: nothing** — only `fps` appears in the log line `REQ_CONFIG_CAPTURE w=… h=… fps=… wantEncoder=… ext=… len=…` (`EasyConnProber.kt:739`). Encoder fps/bitrate always come from the bike profile + user prefs (§7). [V-CODE]

#### Processing order (`EasyConnProber.kt:732-765`) [V-CODE]

1. Log the parsed values.
2. If `w > 0 && h > 0`: `DashMemory.observe(lastQr.ssid, w, h)` — persists the **raw (unrounded)** request per bike SSID (§10.2); log an AA-orientation mismatch hint (AA only).
3. `(negW, negH) = handshake.profile.roundCaptureDimensions(w, h)` = `(w & 0xFFF0, h & 0xFFF0)` — **no profile overrides this default** (`BikeProfile.kt:105`). `negW/negH` default to **800×384** before any REQ 16 (`EasyConnProber.kt:88-89`) and are **not** reset by `stop()`/`start()`.
4. AA source only: `AaVideoBridge.pipeline?.configureBikeCanvas(negW, negH)` **synchronously creates the encoder** at the canvas size before replying (`EasyConnProber.kt:756`, `VideoPipeline.kt:262-308`). For own-UI/mirror sources nothing happens here (the encoder is created at 112).
5. Send RLY 17.

#### Reply body — 9 bytes, LE (`EasyConnProber.kt:758-764`) [V-HW]

| Offset | Size | Field | Value |
|---:|---:|---|---|
| 0 | 4 | `encoder` (i32) | `wantEncoder == 0 ? 2 : wantEncoder` (echo; default 2 = H.264) |
| 4 | 2 | `captureWidth` (i16) | `negW = deviceWidth & ~15` |
| 6 | 2 | `captureHeight` (i16) | `negH = deviceHeight & ~15` |
| 8 | 1 | `supportExtendProtocol` | echo of request byte 29 (0 if body < 30) |

Header: `cmdType = 17`, `cmdLen = 9`, `token = 0` ⇒ **17 bytes on the wire**. The `& ~15` rounding "exactly as the official app does" (`01-REVERSE-ENGINEERING.md:141-148`).

Worked examples (generated from the Kotlin semantics; ext assumed 0 unless stated):

```
CFDL16  req 800×386 → RLY: 11 00 09 00 00 00 00 00 | 02 00 00 00 | 20 03 | 80 01 | 00     (800×384)
CFDL16  same, ext=1 → RLY: 11 00 09 00 00 00 00 00 | 02 00 00 00 | 20 03 | 80 01 | 01
CFDL26  req 800×951 → RLY: 11 00 09 00 00 00 00 00 | 02 00 00 00 | 20 03 | b0 03 | 00     (800×944)
800MT   req 1280×576 → RLY: 11 00 09 00 00 00 00 00 | 02 00 00 00 | 00 05 | 40 02 | 00    (1280×576)
wantEncoder=0 → encoder field forced to 02 00 00 00
```

Synthetic requests for reference (32-byte fixed part only, so the synthetic `cmdLen` is 0x20; real bodies append `encryptedHUID`, e.g. CFDL26 `cmdLen` = 204):

```
CFDL16-like: 10 00 20 00 00 00 00 00 | 20 03 82 01 1e 00 00 00 02 00 00 00 00 00 00 00
             00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00      (w=800 h=386 fps=30 enc=2, rest 0)
CFDL26-like body[0..32]: 20 03 b7 03 1e 00 00 00 02 00 00 00 00 … 00   (w=800 h=951)
```

Edge cases [V-CODE]: `w` or `h` = 0 (short body) ⇒ RLY carries 0 for that dimension and an own-UI encoder would be created at 0×0 at 112 (fails). Never observed. A canvas that changes on a later REQ 16 while an encoder already exists is **not** applied live (§9.2).

### 4.3 `48` REQ_GET_VERSION → `49` [V-HW]

Reply body 8 bytes: `i32 version = 3`, `i32 subVersion = 1` (`EasyConnProber.kt:766-771`; doc: "two int32: version, 1", `01-REVERSE-ENGINEERING.md:114`).
`BikeProfile.versionReply()` also returns `3 to 1` but is **dead code** — the media loop hard-codes 3/1 (`BikeProfile.kt:119`). [V-CODE]

```
49 reply: 31 00 08 00 00 00 00 00 03 00 00 00 01 00 00 00
```

### 4.4 `64` REQ_HEARTBEAT → `65` [V-HW]

Empty reply (`EasyConnProber.kt:772-774`). The phone never initiates media heartbeats; the bike's interval is undocumented. Reply: `41 00 00 00 00 00 00 00`.

### 4.5 `96` REQ_CONFIGCAPTUREREXTEND → `97` [V-HW]

Request body is logged as UTF-8 (first 120 chars); its content is **not** parsed or documented. Reply body is the 11-byte ASCII JSON, **verbatim**:

```json
{"state":0}
```

Built as `"{\"state\":0}".toByteArray(UTF_8)` (`EasyConnProber.kt:775-778`). Wire:

```
97 reply: 61 00 0b 00 00 00 00 00 7b 22 73 74 61 74 65 22 3a 30 7d
```

### 4.6 `112` REQ_RV_DATA_START → `113` [V-HW]

"**Starts the encoder**" (`01-REVERSE-ENGINEERING.md:117`). Android (`EasyConnProber.kt:783-805`):

1. If no video source is attached yet:
   - if an Android Auto pipeline is published (`AaVideoBridge.pipeline != null`): use it (shared, not owned);
   - else create and start an owned `VideoPipeline(negW, negH)` — own UI / Map / mirror depending on state (§9.1).
   If a source is already attached (e.g. after a link re-probe), it is **reused**.
2. `video.onBikeDataStart()` (`VideoPipeline.kt:670-681`): **(a)** clear the frame queue, **(b)** set `awaitKeyframe = true` (drain loop discards non-key output), **(c)** `PARAMETER_KEY_REQUEST_SYNC_FRAME` (force IDR). So the **first AU the bike pulls is always SPS+PPS+IDR**. [V-HW — this is the fix that made AA visible on the 800MT; `05-DEBUG-KNOWLEDGE.md:153-189`]
3. Reply `113`, empty body: `71 00 00 00 00 00 00 00`.

Note the ordering: encoder start + IDR request happen **before** the 113 reply.

### 4.7 `114` REQ_RV_DATA_NEXT → one raw frame [V-HW]

Request: header only, `cmdLen = 0` (`01-REVERSE-ENGINEERING.md:152`); any body would be read and ignored.
Android (`EasyConnProber.kt:806-818`):

```
frame = video?.pollFrame(1500)          // FIFO head; waits ≤ 1500 ms; null immediately if no source
if frame == null:  log "REQ_RV_DATA_NEXT(114): no frame ready"   → NOTHING is written
else:              write [i32 LE frame.size][frame bytes]; framesSent++; lastFrameAt = now
                   framesSent == 1 → ConnectionState STREAMING
                   log "sent frame #N (Sb)" for N ≤ 5 and every 60th
```

See §5 for the byte format and the consequences of an unanswered 114.

### 4.8 `128` REQ_START_H264 → `129` [X]

Reply `129` empty: `81 00 00 00 00 00 00 00`. Comment: "then bike expects frames on data socket … (no encoder yet — video stage TODO)" (`EasyConnProber.kt:779-782`). Never mentioned in any bike log/doc; known only from the SDK decompile. Android does **not** start an encoder or force an IDR here.

### 4.9 `32` touch

Covered by the touch/input spec; byte layout summarised in §11. No reply.

### 4.10 Unknown cmdTypes [V-CODE]

Logged as `media cmdType=<n> len=<len> <hex of first ≤32 bytes>` and **not answered** (`EasyConnProber.kt:820-823`).

### 4.11 Observed ordering [V-HW]

`REQ_CONFIG_CAPTURE → RLY 17 → REQ_RV_DATA_START → RLY 113 → frame pulls` — identical for mirror and AA sessions on the same bike (`05-DEBUG-KNOWLEDGE.md:109-113`). `02-CURRENT-APP.md:14` lists the negotiation as "config capture → … version, heartbeat, configcaptureextend" (relative order of 48/64/96 not pinned). Mirror mode created its encoder at 112 and "the bike opens the data socket ~70 ms later" (`05-DEBUG-KNOWLEDGE.md:174`). On CFDL26 the bike "opens :10921 (media ctrl) and :10920 (media data)" after the control burst (`01-REVERSE-ENGINEERING.md:232-233`). **Implement order- and port-agnostically.**

---

## 5. Frame wire format on :10920

### 5.1 Layout [V-HW in practice; provenance I]

```
offset 0 : size  : 4 bytes, little-endian, = number of AU bytes that follow (prefix not included)
offset 4 : AU    : one H.264 access unit, Annex-B (start-code delimited NAL units)
(no ReqBase header, no trailer/terminator, no timestamp)
```

`sendFrameRaw` (`EasyConnProber.kt:706-715`): `ByteBuffer.allocate(4).order(LITTLE_ENDIAN).putInt(0, frame.size)`, then `write(size)`, `write(frame)`, `flush()` under `synchronized(out)`.

Doc caveat (`01-REVERSE-ENGINEERING.md:159-162`): "This exact wire format is inferred, not 100% confirmed … whether an INT_ZERO terminator is needed may need re-verification". In practice this format streams on CFDL16, CFDL26, 800MT and the community-confirmed brands (`SUPPORTED-BIKES.md:36-81`), so treat it as the working format; the open point is only whether the official app adds anything (§16). The code comment says it was inferred from the partially decompiled `MediaProjectServerDataExecuteThread.reply*Data()` (`EasyConnProber.kt:706-707`).

### 5.2 What one "frame" contains [V-CODE]

| AU kind | Bytes sent | Source |
|---|---|---|
| Keyframe (IDR) | `codecConfig` (SPS+PPS exactly as MediaCodec emitted them, Annex-B) **+** the IDR output buffer | `VideoPipeline.kt:563,570` |
| P-frame | the encoder output buffer as-is | `VideoPipeline.kt:570` |
| Codec config alone | **never sent** as its own frame; only cached | `VideoPipeline.kt:559-561` |

- **SPS/PPS go in front of every keyframe** for as long as a codec config is cached — not just the first one (the docs' "first keyframe" wording is outdated; §13). [V-CODE]
- **Start codes:** whatever MediaCodec emits (Android AVC encoders emit 4-byte `00 00 00 01`). The Android helpers that parse these streams accept both 3- and 4-byte codes (`YunmoFrame.kt:41-61`). [I]
- **AUD / SEI:** no insertion, no stripping — pure pass-through of encoder output. [V-CODE]
- **Slices:** pass-through (one output buffer = one AU, however many slices). [V-CODE]

### 5.3 Example (toy AU; real frames are KB-sized)

```
size=30 → 1e 00 00 00
          00 00 00 01 67 42 00 1f da 01 40 12 69 a8      SPS (prefix of the real 800MT SPS, truncated)
          00 00 00 01 68 ce 0d 88                        PPS (real 800MT PPS)
          00 00 00 01 65 88 84 00                        IDR slice (toy)
P-frame (toy, 8 B): 08 00 00 00 00 00 00 01 41 9a 00 21
Size prefixes of real frames from the 800MT log: 23040 B IDR → 00 5a 00 00, 33445 B → a5 82 00 00, 9722 B P → fa 25 00 00
```

### 5.4 Lock-step and the "no frame" case

- **One 114 ⇒ at most one AU.** The bike sends the next 114 only after receiving a frame. [V-HW] `01-REVERSE-ENGINEERING.md:152-153`
- Android waits ≤ **1500 ms** in `pollFrame` (`EasyConnProber.kt:807`, `VideoPipeline.kt:655-656`). On timeout it sends **nothing** — no empty frame, no zero size, no resend of the last frame. If no source is attached (`video == null`, e.g. during a source swap) `pollFrame` is not even waited on: it returns null at once. [V-CODE]
- Because the bike is waiting for that frame and Android does not answer, the 114 is effectively lost. There is no evidence the bike retries; the field history points the other way: a starved encoder → "`[:10920] REQ_RV_DATA_NEXT: no frame ready`" → the bike's 9 s timeout → "media closed / bike closed" → projection dropped (`05-DEBUG-KNOWLEDGE.md:222-235`); and a delayed source attach "often lost the media plane until a full Stop/Start" (`AndroidAutoService.kt:599-600`). [I]
- `07-IDEAS-AND-ISSUES.md:69-77` (A4) notes that with the 0.9 s idle repeat a still screen makes the bike wait ~0.9–1.5 s per frame; it "still works", but asks for on-bike measurement.

### 5.5 The 9 s budget, end to end

| Mechanism | Value | Purpose | Source |
|---|---|---|---|
| Bike media timeout | ~9 s (`socketTimeoutPeriodWifi = 9`) | bike drops media link without frames | `01-REVERSE-ENGINEERING.md:19-20` [V-HW] |
| Encoder repeat-last-frame | 0.9 s | static source still yields ≈1 fps | `VideoPipeline.kt:204,792` [V-CODE] |
| Compositor idle re-emit (AA/mirror) | 2 s, checked every 150 ms | keep-alive when the source is paused | `AaCompositor.kt:105-106,385-399` [V-CODE] |
| `pollFrame` wait per 114 | 1.5 s | then give up silently | `EasyConnProber.kt:807` [V-CODE] |
| Phone watchdog (stall) | 8 s with no frame while STREAMING, 5 s tick, 20 s cooldown | close every socket ⇒ re-probe | `AndroidAutoService.kt:134-154,695-697` [V-CODE] |
| Soft-switch grace | 8 s | suppress the stall watchdog during an encoder swap | `AndroidAutoService.kt:591` [V-CODE] |

### 5.6 Observed frame sizes and rates (800MT, 1280×576, 2.5 Mbit/s target) [V-HW]

- Bike pulled frames #1..#540+ at **~30 fps**, 9–17 KB each, with no disconnect (`05-DEBUG-KNOWLEDGE.md:80-83`).
- Other AA sessions: 3–14 KB and 5–20 KB per frame (`05-DEBUG-KNOWLEDGE.md:105-106,131`).
- Keyframes: AA IDR **23040 B**, mirror first keyframe **33445 B**; a mid-GOP P-frame **9722 B** (`05-DEBUG-KNOWLEDGE.md:167-171`).
- Rule of thumb from the docs: **tiny frames (tens of bytes) ⇒ the source is drawing black**; KB-sized ⇒ real content (`05-DEBUG-KNOWLEDGE.md:264-266`).

---

## 6. Keyframe and SPS/PPS policy

### 6.1 When an IDR happens

| Trigger | Mechanism | Where | Status |
|---|---|---|---|
| Encoder start | MediaCodec's first output is an IDR (after the codec-config buffer) | — | [V-CODE] |
| Periodic | `KEY_I_FRAME_INTERVAL = profile.videoIFrameIntervalSec` → **1 s** (Morini profile **2 s**) | `VideoPipeline.kt:176-180,194`; `BikeProfile.kt:116,723` | [V-HW] keyframe "every 30 frames" in both AA and mirror dumps (`05-DEBUG-KNOWLEDGE.md:161-162`) |
| **REQ_RV_DATA_START (112)** — every time, including after reconnects | `onBikeDataStart()`: flush queue → gate (`awaitKeyframe`) → `REQUEST_SYNC_FRAME` | `EasyConnProber.kt:802`; `VideoPipeline.kt:670-681` | [V-HW] |
| Soft switch AA → own Map video (no new 112) | `onBikeDataStart()` immediately **and again 200 ms later** ("second IDR after the Presentation has painted") | `EasyConnProber.kt:284-291` | [V-CODE] |
| On-demand | `requestKeyframe(reason)` = sync-frame request **without** flush/gate | `VideoPipeline.kt:109-118` (used only by the Yunmo path) | [V-CODE] |
| Queue overflow / dropped frames | **none** (no IDR is requested after a drop) | `VideoPipeline.kt:575-579` | [V-CODE] gap — see §7.4 |
| Touch gesture | none (proposed only, `06-OPTIMIZATION-IDEAS.md:143`) | — | [X] |
| Canvas change | none — encoder is not re-created live (§9.2) | `VideoPipeline.kt:264-272` | [V-CODE] |

The keyframe gate (`awaitKeyframe`) drops every non-key output buffer, without counting it as a drop, until the first keyframe, which clears the gate (`VideoPipeline.kt:564-569`).

### 6.2 SPS/PPS caching [V-CODE]

- Captured from the output buffer flagged `BUFFER_FLAG_CODEC_CONFIG` into `codecConfig` (`VideoPipeline.kt:559-561`); replaced if the encoder emits a new one; cleared on `stop()` (`VideoPipeline.kt:774`) and on forced re-creation (`VideoPipeline.kt:287`).
- Prepended to **every** keyframe while non-null (`VideoPipeline.kt:570`).
- Exposed via `codecConfigBytes()` (`VideoPipeline.kt:106`).
- The phone also advertises `"supportH264IFrame": true` in its control-plane CLIENT_INFO reply (`BikeProfile.kt:302`); its exact meaning to the bike is unknown, but it is what the working app sends. [V-HW that it works / I on meaning]

---

## 7. Encoder configuration (Android reference)

### 7.1 MediaCodec format (`VideoPipeline.kt:168-251`)

| Setting | Value | Lines | Status |
|---|---|---|---|
| MIME | `video/avc` | 183 | [V-HW] |
| Size | the **canvas** `negW×negH` from RLY 17 (own/mirror: at 112; AA: at 16) | 794; 290 | [V-HW] |
| Color format | `COLOR_FormatSurface` (0x7F000789) — Android surface input | 182-184 | Android-only |
| `KEY_BIT_RATE` | `profile.videoBitrate × VideoQuality.multiplier × (1.35 if mapBoost)` (§7.3) | 175 | [V-HW] 2.5 Mbit/s |
| `KEY_BITRATE_MODE` | `BITRATE_MODE_CBR` (2); silently skipped if it throws | 186-192 | [V-CODE] |
| `KEY_FRAME_RATE` | `profile.videoFrameRate` (30; Morini 10) | 193 | [V-CODE] |
| `KEY_I_FRAME_INTERVAL` | `profile.videoIFrameIntervalSec` (1; Morini 2); if mapBoost `max(1, x/2)` (integer ⇒ still 1) | 176-180, 194 | [V-HW] |
| `KEY_REPEAT_PREVIOUS_FRAME_AFTER` | **900 000 µs** (`IDLE_ENCODER_REPEAT_US`) | 204, 792 | [V-CODE] (was 100 000 µs; §13) |
| `KEY_LATENCY` | 1 (no reordering hint) | 210 | [V-CODE] |
| `KEY_PROFILE` / `KEY_LEVEL` | `AVCProfileBaseline` / `AVCLevel31` **when `profile.forceBaseline`** (true for every profile except Morini) | 213-221 | [V-HW] |
| Fallback | if `configure` throws: `reset()` and configure **without** profile/level | 227-231 | [V-CODE] |
| Output drain | `dequeueOutputBuffer` with 100 ms timeout in a dedicated thread | 245, 548 | [V-CODE] |

Why Baseline: embedded decoders "often only handle Baseline — no CABAC/B-frame reordering, which the PTS-less bike wire format can't support anyway" (`BikeProfile.kt:799-805`). Note the nuance: the 800MT accepted and decoded a Main/High stream at 1280×576 (540+ frames, and mirror mode rendered with it), and switching AA to Baseline did **not** fix that black screen (the real cause was the keyframe eviction) (`05-DEBUG-KNOWLEDGE.md:76-83,130-136`). Baseline is the proven-safe default, not proven-necessary on every dash. [V-HW]

### 7.2 Per-profile video specs (`BikeProfile.kt`)

All profiles use the default `roundCaptureDimensions` (`& 0xFFF0`, `BikeProfile.kt:105`) and the default `versionReply` (3, 1).

| Profile (selection is control-plane) | `forceBaseline` | `videoBitrate` | `videoFrameRate` | IDR interval | `panelSize` (measured/typical) | `defaultMargins` T,B,L,R | Lines | Status |
|---|---|---|---|---|---|---|---|---|
| LegacyCfdl16 (675 SR-R, fallback) | true | 2 500 000 | 30 | 1 s | — | 0,0,0,0 | 406-441 | [V-HW] |
| Nk800 (US 800NK CRCP, sdk 0.9.23.x) | true | 2 500 000 | 30 | 1 s | — (landscape 800×400 seen; portrait ~460×750 variant) | 0,0,0,0 | 444-498 | [V-HW]/[I] sizes |
| Cfdl26Portrait (1000 MT-X) | true | 2 500 000 | 30 | 1 s | 800×951 | 0,0,0,0 | 514-581 | [V-HW] |
| Cfdl26NkTouch (800NK Advanced) | true | 2 500 000 | 30 | 1 s | 720×712 | **22**,0,0,0 | 591-629 | [V-CODE] |
| Cfdl16MotoPlayLandscape (modelId 66660742) | true | 2 500 000 | 30 | 1 s | 800×400 | 0,0,0,0 | 632-657 | [V-CODE] |
| ClC450 (CL-C450) | true | 2 500 000 | 30 | 1 s | 544×512 | 0,0,0,0 | 660-685 | [V-CODE] |
| MoriniMlSoftAp (Moto Morini SoftAP / MLN) | **false** | **2 000 000** | **10** | **2 s** | 1024×464 (X-Cape 1200 Yunmo figure) | 0,0,0,0 | 703-749 | [X] values copied from the OEM "Ride MO" map path |
| Cfdl26Landscape (800MT) | true | 2 500 000 | 30 | 1 s | 1280×576 | 0,0,0,0 | 751-812 | [V-HW] |
| LearnedGeometry (wrapper) | inherits | inherits | inherits | inherits | measured | inherits | 688-696 | [V-CODE] |

The encoder reads `BikeProfileHolder.active`, which `PxcHandshake` sets to the CLIENT_INFO-selected profile before any media socket exists (`PxcHandshake.kt:149,166`; `VideoPipeline.kt:170,213`).

### 7.3 Bitrate computation [V-CODE]

```
bitrate = int( int(profile.videoBitrate × quality.multiplier) × (mapBoost ? 1.35 : 1.0) )   // Float32 math
quality.multiplier: SMOOTH 0.7 | BALANCED 1.0 (default) | SHARP 1.6        VideoPrefs.kt:16-20,133-136,143-144
mapBoost = (own Map/GPX session active) && profile.videoFrameRate >= 30    VideoPipeline.kt:174-175
```

| Profile base | SMOOTH | BALANCED | SHARP | BALANCED + mapBoost |
|---|---:|---:|---:|---:|
| 2 500 000 (default) | 1 750 000 | **2 500 000** | 4 000 000 | 3 375 000 |
| 2 000 000 (Morini) | 1 400 000 | 2 000 000 | 3 200 000 | n/a (10 fps < 30) |

Live changes: `setEncoderBitrate(bps)` clamps to `[1, baseBitrate]` and applies `PARAMETER_KEY_VIDEO_BITRATE` without re-creating the codec; no-op if unchanged or no encoder yet (`VideoPipeline.kt:610-624`).

### 7.4 Frame queue, drain and drop policy [V-CODE]

- `frameQueue = LinkedBlockingDeque<ByteArray>(8)` — capacity **8 AUs**, FIFO (`VideoPipeline.kt:99`).
- Producer: the drain thread appends each AU (keyframes already carrying SPS/PPS).
- Consumer: each 114 takes the **oldest** AU (`pollFirst(timeout)`) (`VideoPipeline.kt:655-656`).
- Overflow: `pollFirst()` (**drop the oldest**) then `offerLast(new)`; `droppedFrames++` (`VideoPipeline.kt:575-579`). The counter feeds Auto mode (§8.2).
- Flushes: `onBikeDataStart()` (`VideoPipeline.kt:671`), forced canvas re-create (`VideoPipeline.kt:288`), `stop()` (`VideoPipeline.kt:773`).

**How decode corruption is (not) avoided.** Dropping the oldest queued AU breaks the P-frame reference chain: the next P-frame the bike decodes references a frame it never received. Android does not mitigate this (no IDR request, no gate after a drop); the damage lasts until the next periodic IDR (≤ 1 s, Morini ≤ 2 s). The only corruption guard is the 112 gate (§6.1). Latency side effect: a full queue holds up to 8 frames (≈330 ms at 24 fps) of staleness (`06-OPTIMIZATION-IDEAS.md:119-150`, proposal to cut the capacity to 2–3, not implemented). [V-CODE]

**Race to avoid** (present in Android): `onBikeDataStart` clears the queue **before** setting `awaitKeyframe` (`VideoPipeline.kt:671-672`); a P-frame dequeued by the drain thread between those two statements can still land in the fresh queue and be served first. [I — narrow window, never reported]

### 7.5 Static-screen keep-alive layers

| Layer | Behaviour | Value | Lines | Status |
|---|---|---|---|---|
| Encoder repeat | surface-input encoder re-emits the last frame when no new input arrives | 0.9 s (≈1 fps floor) | `VideoPipeline.kt:195-204,785-792` | [V-CODE]; on-bike check requested (`06-OPTIMIZATION-IDEAS.md:253-258`) |
| Compositor idle redraw (AA + mirror only) | GL thread ticks every 150 ms; flushes a coalesced frame once the cap interval has passed; otherwise re-draws the last frame after 2 s idle | 150 ms tick / 2000 ms idle | `AaCompositor.kt:101-106,385-399` | [V-CODE] |
| Monotonic PTS on re-draws | `eglPresentationTimeANDROID(System.nanoTime())` so repeats are not dropped as duplicate timestamps | — | `AaCompositor.kt:454-455` | [V-CODE] |
| Own placeholder UI | text ticker repaints every 100 ms | 100 ms | `VideoPipeline.kt:466-474` | [V-CODE] |

History (why this matters): a static source produced **zero** frames and the bike timed out at 9 s; the 100 ms repeat was the original fix (a UI ticker had masked the problem) (`01-REVERSE-ENGINEERING.md:171-173`). The encoder-side repeat did **not** keep frames flowing once the input surface received zero buffers during AA pauses, which is why the compositor-side re-emit exists (`05-DEBUG-KNOWLEDGE.md:230-243`).

### 7.6 Known-good bitstream (decoded) [V-HW]

From the 800MT dumps, identical for AA and mirror and accepted by the dash (`05-DEBUG-KNOWLEDGE.md:159-162`). Decoded here:

```
SPS 67 42 00 1f da 01 40 12 69 a8 …
  nal_ref_idc=3 type=7 | profile_idc=66 (Baseline) | constraint_set flags=0x00 | level_idc=31 (3.1)
  sps_id=0, log2_max_frame_num_minus4=0, pic_order_cnt_type=2, max_num_ref_frames=1, gaps=0
  pic_width_in_mbs_minus1=79 → 1280, pic_height_in_map_units_minus1=35 → 576
  frame_mbs_only=1, direct_8x8_inference=1, frame_cropping=0, vui_parameters_present=1
PPS 68 ce 0d 88
  pps_id=0 sps_id=0 entropy_coding_mode=0 (CAVLC) slice_groups=1 num_ref_idx_l0/l1_default=1
  weighted_pred=0 bipred_idc=0 pic_init_qp=29 (minus26=3) qs=26 chroma_qp_offset=0
  deblocking_filter_control_present=0 constrained_intra_pred=0 redundant_pic_cnt_present=0
GOP: IDR every 30 frames.
```

Because the canvas is always a multiple of 16, **frame cropping is never needed** (in 16×16 macroblocks: 800×384 = 50×24 = 1200, 800×944 = 50×59 = 2950, 1280×576 = 80×36 = 2880). Level 3.1 limits (MaxFS 3600 macroblocks/frame, MaxMBPS 108 000 macroblocks/s) cover all three at 30 fps; a 1280×720 canvas (3600 MBs) sits exactly at MaxFS. [I — arithmetic]

### 7.7 Diagnostics worth porting [V-CODE]

- `DUMP_H264` (default `false`) records the exact wire AUs to `<externalFiles>/video/opencfmoto-video-<aa|mirror|own>.h264`, capped at `DUMP_CAP = 600` AUs (~20 s at 30 fps) (`VideoPipeline.kt:120-126,683-718,794-798`). This dump is what cracked the black-screen bug (compare `sent frame #1` size with the dump's first AU).
- Log lines: `sent frame #N (S b)` for N ≤ 5 and every 60th (`EasyConnProber.kt:815-816`); 5 s health line `hb#i probed= video= framesSent= openServers=` (`EasyConnProber.kt:1081-1095`); `[VIDEO] bike attached → flushed queue + requested IDR …` (`VideoPipeline.kt:677`).

### 7.8 Field history — what broke dashes

| Symptom on the dash | Root cause | Fix in Android | Status |
|---|---|---|---|
| Black screen while the bike keeps pulling KB-sized frames and heartbeating | first served AU was a mid-GOP P-frame without SPS/PPS (encoder started ~1 s before the data socket; 8-deep queue evicted the IDR) | flush + gate + forced IDR on every 112 (§6.1) | [V-HW] `05-DEBUG-KNOWLEDGE.md:153-189` |
| Link drops ~9 s after the picture stops changing | surface-input encoder emits nothing for a static source | encoder repeat (now 0.9 s) + compositor 2 s re-emit (§7.5) | [V-HW] `01-REVERSE-ENGINEERING.md:171-173` |
| Projection drops when opening All Apps or taking a call (AA) | AA paused video → encoder starved → bike 9 s timeout | compositor keep-alive re-emits the last frame; now a brief freeze instead (`README.md:661-663`) | [V-HW] `05-DEBUG-KNOWLEDGE.md:222-250` |
| Black screen suspected from Main/High (CABAC, reordering) | not the cause on the 800MT, but Baseline@3.1 + `KEY_LATENCY=1` adopted as the safe default | `forceBaseline = true` | [V-HW] `05-DEBUG-KNOWLEDGE.md:102-136` |
| "HD can black-screen on some dashes" (AA 1280×720 / 1080×1920 input) | the encoded canvas never changes; the documented 800MT case was a start-up lifecycle race made worse by HD's slower steady-video | hand-off made to survive activity recreation (`BikeLink` + foreground service); HD left as a user option | [V-HW] `README.md:309-310`, `05-DEBUG-KNOWLEDGE.md:55-98` |
| ~7 s connect/drop flap | AA source scaled with the wrong assumed size/orientation ("a picture the dash rejects") | pin the AA spec; landscape-first profile tie-break | [I] `PxcHandshake.kt:167-172`, `BikeProfile.kt:138-145` |
| Empty dash after Stop → Connect | media ports stuck in TIME_WAIT, rebind failed | `SO_REUSEADDR` before bind | [V-CODE] `EasyConnProber.kt:189-199` |
| Blank dash, bike talks to someone else | official CFMoto app holds 10920–10922 | fail fast with an actionable error | [V-CODE] `EasyConnProber.kt:209-219` |
| Media plane lost on AA → Map switch ("until a full Stop/Start") | delayed source attach: a multi-second gap with no source, so pulls went unanswered [I] | attach immediately, double IDR, 8 s watchdog grace | [V-CODE] `AndroidAutoService.kt:591-610` |

---

## 8. Power modes, quality and adaptive "Auto"

### 8.1 User settings (per bike, `VideoPrefs.kt`)

| Setting | Values (enum name → effect) | Default | Lines |
|---|---|---|---|
| `VideoQuality` | `SMOOTH` ×0.7, `BALANCED` ×1.0, `SHARP` ×1.6 (bitrate multiplier) | **BALANCED** | 16-20, 133-136 |
| `PowerMode` (frame cap) | `AUTO` 30 (start, adaptive), `SMOOTH` 30, `BALANCED` 24, `SAVER` 20 | **BALANCED** (code) | 48-53, 155-159 |
| `ScreenFit` | `FILL` (cover/crop), `FIT` (letterbox), `STRETCH` | **FILL** | 30-34, 146-149 |
| `MirrorOrientation` | `MATCH_DASH`, `FOLLOW`, `LANDSCAPE`, `PORTRAIT` | **MATCH_DASH** | 97-102, 174-177 |
| `ResolutionMode` (AA input only) | AUTO, 800×480, 1280×720, 720×1280, 1080×1920 | AUTO | 67-73 |

Preference store (Android): SharedPreferences `opencfmoto_bike`, keys `video_quality`, `screen_fit`, `power_mode`, `resolution_mode`, `mirror_orientation`, `aa_dpi_override`, `match_aspect_mode`, `match_aspect_on`, `match_aspect_w`, `match_aspect_h`, scoped per bike via `BikeScope` (`VideoPrefs.kt:114-128`). Screen margins live in SharedPreferences `screen_margins` (keys `customised`, `top`, `bottom`, `left`, `right`) and are **global**, not per bike (`ScreenMargins.kt:18,36-65`). [V-CODE]

**What the power mode actually controls** [V-CODE]: the compositor's maximum rate of frames pushed into the encoder, `minFrameIntervalMs = 1000 / clamp(fps, 10, 60)` → 30→33 ms, 24→41 ms, 20→50 ms, 15→66 ms, 12→83 ms (`AaCompositor.kt:358-362`; initial value 42 ms, `AaCompositor.kt:99`). It applies to the **AA compositor and the mirror scaler only** (`VideoPipeline.kt:301,363`); the own-UI/Map path has no frame cap. The encoder's `KEY_FRAME_RATE` stays at the profile value (30) regardless, and fixed modes never touch the bitrate. A too-early frame is not dropped: it stays latched and is drawn by the next keep-alive tick once the interval has passed (`AaCompositor.kt:364-375,389-391`).

### 8.2 Auto mode — inputs, thresholds, outputs [V-CODE; thresholds await on-bike tuning, `06-OPTIMIZATION-IDEAS.md:253-263`]

Runs only when `PowerMode == AUTO`, once per **5 s** watchdog tick, only on the Android Auto pipeline (`AndroidAutoService.kt:119,695`; `AdaptiveVideoController.kt:110-151`). If the rider switches to a fixed mode mid-session, it restores the base bitrate and the mode's fps once, then stays out (`AdaptiveVideoController.kt:113-117,154-160`). Skipped while the encoder doesn't exist (`targetBitrate() <= 0`).

Inputs:
- **Thermal:** `PowerManager.currentThermalStatus` (0 NONE … 6 SHUTDOWN); read failure ⇒ NONE.
- **Link ("Wi-Fi quality")**: there is **no RSSI input**. The only link signal is `dropsThisTick = droppedFramesTotal() − lastDropTotal` (queue-overflow drops, §7.4).

Constants (`AdaptiveVideoController.kt:28-37`):

| Name | Value |
|---|---|
| `LINK_MIN` | 0.4 |
| `LINK_MAX` | 1.0 |
| `LINK_DECREASE` | 0.8 (multiplicative) |
| `LINK_INCREASE_STEP` | 0.05 (additive) |
| `DROP_CONGESTION_THRESHOLD` | **8 drops per tick (5 s)** |
| `MIN_BITRATE` | **600 000 bit/s** |

Math (`AdaptiveVideoController.kt:40-78`):

```
thermalBitrateFactor(s) = s ≤ LIGHT(1) ? 1.0 : s == MODERATE(2) ? 0.8 : s == SEVERE(3) ? 0.6 : 0.5
thermalFpsCap(s, base)  = s ≤ LIGHT ? base : s == MODERATE ? min(base,20) : s == SEVERE ? min(base,15) : min(base,12)
nextLink(prev, drops)   = drops ≥ 8 ? max(prev × 0.8, 0.4) : min(prev + 0.05, 1.0)
decide(base, baseFps=30, s, prevLink, drops):
    link    = nextLink(prevLink, drops)
    factor  = min(thermalBitrateFactor(s), link)                 // the harsher pressure wins; NOT a product
    bitrate = clamp(int(base × factor), min(600_000, base), base)
    fps     = thermalFpsCap(s, baseFps)                          // fps follows thermal only
```

Application: bitrate via `setEncoderBitrate` (live), fps via `setFrameCap` (compositor), each only when it changed (`AdaptiveVideoController.kt:139-150`). `base` is the bitrate the encoder was created with (quality multiplier included). `reset()` at each new AA session (`AndroidAutoService.kt:526`).

---

## 9. Media-plane lifecycle

### 9.1 Who creates / starts / stops the encoder

| Source mode (Android) | Encoder created | Encoder input | Stopped by | iOS analogue |
|---|---|---|---|---|
| **Own UI / Map ("GPX Presentation")** — `ProjectionHolder.projection == null && GpxSession.active` | at **112**, size `negW×negH` (`EasyConnProber.kt:793-795`) | private VirtualDisplay (exactly canvas size) rendering the Map UI (`VideoPipeline.kt:154-159,481-521`) | `prober.stop()` / `detachVideoSource()` (owned) | **Main path:** CoreGraphics dash UI → VideoToolbox |
| Own placeholder (no map, no mirror) | at 112 | VirtualDisplay with a blue `#0D47A1` card, "OpenCfMoto" (28 sp white) + "frame tick N" ticker (20 sp `#80D8FF`, 100 ms) (`VideoPipeline.kt:439-478`) | same | idle/standby screen |
| **Mirror** (`ProjectionHolder.projection != null`) | at 112 | MediaProjection → compositor (fit) → encoder (`VideoPipeline.kt:150-153,321-437`) | same | ReplayKit broadcast |
| Android Auto | at **16** via `configureBikeCanvas` (compositor exists from AA start) (`VideoPipeline.kt:262-308`) | AA decoder → GL compositor → encoder | AA service park/stop (`AndroidAutoService.kt:204-226,561-574,667-688`) | n/a |

`VideoPipeline.start()` picks the mode at construction time: compositor ⇒ wait for canvas; else create the encoder, then mirror if a projection exists, else Map if a map session is active, else the placeholder (`VideoPipeline.kt:128-165`). [V-CODE]
UI mode, mirror mode, and AA mode are all confirmed streaming on hardware (`02-CURRENT-APP.md:14-24`). [V-HW]

### 9.2 Canvas changes

- AA compositor: a later `configureBikeCanvas` with a different size is ignored ("live resize unsupported") unless `force = true` (Yunmo path only) (`VideoPipeline.kt:262-273`).
- Own/mirror: the encoder created at the first 112 is **reused** across link re-probes (the prober's `video` survives `onAllConnectionsClosed`), so a new REQ 16 with a different size would leave a mismatched encoder. Same dash ⇒ same size in practice. [V-CODE]
- iOS rule: the encoded size must equal the latest RLY 17 values; re-create the session before answering 113 if they differ.

### 9.3 REQ_RV_DATA_START (112) semantics

"A bike video client is (re)attaching and about to pull frames" (`VideoPipeline.kt:658-669`). Required phone behaviour: have a source running at the canvas size, discard anything queued, guarantee the next served AU is SPS+PPS+IDR, then reply 113. Applies to the first attach **and** every re-attach.

### 9.4 Session drop and re-open (`EasyConnProber.kt:615-660`) [V-CODE]

When the **last** bike socket closes (`liveConns == 0`), the session was connected at least once, and no re-probe loop is running:

```
if reconnectAttempts ≥ 20 → Phase.ERROR "lost bike link" (watchdog re-arms later)
else Phase.RECONNECTING, then loop while running && liveConns == 0 && attempts < 20:
    attempts++; backoff = min(500 + 500·attempts, 4000) ms   (1000, 1500, 2000, …, capped 4000 from attempt 7)
    sleep(backoff); framesSent = 0; probe :10930 (2 tries) → NSD (2 tries) → Yunmo fallback
    sleep(2500 ms) to let the dash connect back
```

The servers keep listening throughout; the bike reconnects every socket (control and media) and repeats 16 → 17 → 112 → 113 → 114… An owned encoder survives this path (only the 112 IDR sequence runs again). If instead the bike **Wi-Fi network** is lost and re-acquired, the whole prober is stopped and restarted on the new network (servers rebound, owned encoder discarded) (`BikeLink.kt:117-141`). The attempt counter resets on any accepted connection (`EasyConnProber.kt:601`). `framesSent = 0` makes the first new frame re-signal STREAMING (`EasyConnProber.kt:641`).

### 9.5 Phone-side watchdog (`AndroidAutoService.kt:105-154,695-700`) [V-CODE]

Every **5 s** (if Auto-recovery is enabled — default **on**, `AppSettings.kt:45`):
- `phase == STREAMING && msSinceLastFrame() > 8000 && now − lastRecoveryAt > 20 000` ⇒ `forceReconnect()`: close every socket in `activeClients`, which leads to §9.4.
- `phase == ERROR && now − lastRecoveryAt > 20 000` ⇒ `rearmFromError()` (reset attempts, re-probe).
- Suppressed during the 8 s soft-switch grace.

`msSinceLastFrame()` = now − `lastFrameAt` (`Long.MAX_VALUE` if no frame yet) (`EasyConnProber.kt:335-339`); `isStreaming` = running && framesSent > 0 (`EasyConnProber.kt:331-332`).

### 9.6 Mode switches [V-CODE]

- Hard switch (AA ↔ Map ↔ Mirror from the UI): stop the AA service and the prober, keep Wi-Fi, start a fresh prober ⇒ the bike re-handshakes and re-sends 16/112 (`MainActivity.kt:155-180`; `EasyConnProber.kt:136-141`: a second `start()` always forces a clean restart).
- Soft switch AA → own Map (keeps PXC sockets): `detachVideoSource()` then `attachOwnedGpxVideo()`: new `VideoPipeline(max(negW,16), max(negH,16))`, one retry if it fails to start, `lastFrameAt = now`, `framesSent = 0`, `onBikeDataStart()` now and +200 ms, phase STREAMING (`EasyConnProber.kt:231-294`). During the swap `video == null`, so any 114 that arrives gets **no reply** (§5.4). The service gives the watchdog an 8 s grace (`AndroidAutoService.kt:591`).

### 9.7 Connection phases relevant to video (`ConnectionState.kt:15-27`)

`PXC_CONNECTING` (prober started) → `STREAMING` (first frame sent, or Map attached) / `MIRRORING` (set by the UI for mirror/Map hard switches) → `RECONNECTING` (re-probe) → `ERROR` (budget spent) / `STOPPED`.

---

## 10. Geometry

### 10.1 Canvas negotiation and known dashes

The **canvas** is the size in RLY 17 (= request rounded down to multiples of 16, §4.2). The phone never proposes its own size. Coordinates in the canvas (touch, margins) are **pixels with a top-left origin, y down** (§10.4).

| Dash | Requested (REQ 16) | Canvas (RLY 17) | Orientation | Status |
|---|---|---|---|---|
| CFDL16 (675 SR-R, ~5") | 800×386 | **800×384** | landscape | [V-HW] `01-REVERSE-ENGINEERING.md:11-14,123-124,144-145` |
| CFDL26 (1000 MT-X, 8") | 800×951 (body 204 B) | **800×944** | portrait | [V-HW] `01-REVERSE-ENGINEERING.md:239-244` |
| CFDL26 800MT (landscape touch) | 1280×576 (the "measured panel", `PxcHandshake.kt:152-153`) | **1280×576** | landscape | [V-HW] `05-DEBUG-KNOWLEDGE.md:290-293` |
| US 800NK (CRCP, sdk 0.9.23.4) | ~800×400 | 800×400 | landscape | [I] `BikeProfile.kt:446-448` |
| US 800NK (CRCP, sdk 0.9.23.9, V1.0.18) | ~460×750 | 448×736 | portrait | [I] `BikeProfile.kt:447-448` |
| 800NK Advanced (CFDL26 touch) | 720×712 (measured) | 720×704 | near-square | [I] `BikeProfile.kt:587-598` |
| CL-C450 | 544×512 | 544×512 | near-square | [I] `BikeProfile.kt:659-666` |
| MotoPlay landscape (modelId 66660742) | 800×400 | 800×400 | landscape | [I] `BikeProfile.kt:637` |

The iOS dash UI must lay out for wide (≈2.1–2.2:1), tall (≈0.85:1 and ≈0.6:1) and near-square canvases.

### 10.2 Learned geometry — `DashMemory` [V-CODE]

- Every REQ 16 with `w>0 && h>0` stores the **raw** requested size as the string `"<w>x<h>"` under key `dash_geo_<ssid>` (SSID from the last scanned QR) in prefs `opencfmoto_bike` (`DashMemory.kt:14-43`; call site `EasyConnProber.kt:741-743`).
- Read back (1..8192 per axis) for: picking the Android Auto resolution next connect (`DashMemory.bestFit/specFor`, `BikeProfiles.selectByQr` → `LearnedGeometryProfile`), AA aspect margins, and the mirror orientation `MATCH_DASH` (`DashMemory.kt:45-81`; `BikeProfile.kt:174-186,688-696`; `VideoPrefs.kt:199-211,243-249`).
- It **never** alters RLY 17 — the reply always mirrors the live request.
- `bestFit(w,h)`: round both to `& 0xFFF0`, keep AA sizes that match one axis exactly and cover the other, pick the minimum of `(rw−cw)(rh−ch) + (rw−cw) + (rh−ch)`, else null (`DashMemory.kt:58-65`). AA-only.

iOS relevance: the canvas is always known from REQ 16 before the first 114, so learned geometry is only an optimisation — pre-sizing the renderer/encoder and the phone-side preview before the bike connects (the "pre-warm the encoder" idea, `06-OPTIMIZATION-IDEAS.md:226-228`).

### 10.3 Fit math (FIT / FILL / STRETCH + margins) — `AaCompositor.computeViewport` (`AaCompositor.kt:298-330`) [V-CODE]

Used for the AA compositor **and** the mirror scaler. The own-UI path renders straight at canvas size and uses none of this.

```
inputs: canvas (W,H), source (sw,sh), margins (T,B,L,R) from ScreenMargins, mode
T' = clamp(T, 0, H);  B' = clamp(B, 0, H − T');  L' = clamp(L, 0, W);  R' = clamp(R, 0, W − L')
areaW = max(W − L' − R', 1);  areaH = max(H − T' − B', 1)
srcAspect = Float(sw)/Float(sh);  areaAspect = Float(areaW)/Float(areaH)          // Float32
STRETCH: vw = areaW; vh = areaH
FIT    : srcAspect < areaAspect ? (vh = areaH, vw = round(areaH·srcAspect)) : (vw = areaW, vh = round(areaW/srcAspect))
FILL   : srcAspect < areaAspect ? (vw = areaW, vh = round(areaW/srcAspect)) : (vh = areaH, vw = round(areaH·srcAspect))
vx = L' + (areaW − vw)/2;  vy = T' + (areaH − vh)/2       // Int division truncates toward zero (Swift `/` does too)
round(x) = Java Math.round(Float) = floor(x + 0.5f)
draw: clear the whole target to opaque black (0,0,0,1); scissor to (0,0,W,H); draw the source into the viewport
```

FILL can produce a rect larger than the canvas (negative offsets); the scissor clips it (`AaCompositor.kt:423-430`).

Inverse map for touch (`AaCompositor.kt:281-289`): `rx = cx − vx; ry = cy − vy`; return null (touch in a black bar) unless `0 ≤ rx < vw && 0 ≤ ry < vh`; `sx = clamp(rx·sw / vw, 0, sw−1)`, `sy = clamp(ry·sh / vh, 0, sh−1)` (64-bit integer math, truncating).

Worked examples (computed with the exact Kotlin semantics; viewport = x, y, w, h):

| Case | FIT | FILL | STRETCH |
|---|---|---|---|
| AA 800×480 → CFDL16 800×384 | 80, 0, 640, 384 | 0, −48, 800, 480 | 0, 0, 800, 384 |
| AA 720×1280 → CFDL26 800×944 | **134, 0, 531, 944** [V-HW `02-CURRENT-APP.md:115`] | 0, −239, 800, 1422 | 0, 0, 800, 944 |
| AA 800×480 → 800MT 1280×576 | **160, 0, 960, 576** [V-HW `05-DEBUG-KNOWLEDGE.md:206-208`] | 0, −96, 1280, 768 | 0, 0, 1280, 576 |
| 720×712 usable → NK Adv 720×704, margins T=22 | 15, 22, 690, 682 | 0, 7, 720, 712 | 0, 22, 720, 682 |
| Mirror portrait 1080×2400 → 800×384 | 313, 0, 173, 384 (the "~170 px strip") | 0, −697, 800, 1778 | 0, 0, 800, 384 |
| Mirror landscape 2400×1080 → 800×384 | 0, 12, 800, 360 | −26, 0, 853, 384 | 0, 0, 800, 384 |
| Mirror portrait 1080×2400 → 800×944 | 187, 0, 425, 944 | 0, −417, 800, 1778 | 0, 0, 800, 944 |

Inverse-map vectors (800MT FIT, viewport 160,0,960,576, source 800×480): (0,0) → null (bar); (160,0) → (0,0); (640,288) → (400,240); (1119,575) → (799,479); (1200,10) → null.

### 10.4 Screen margins (insets)

- Per-edge black borders "held back from the edges of the dash, in dash pixels" (`ScreenMargins.kt:9-16`), each `0…200` (`MAX = 200`, `ScreenMargins.kt:19,54-57`).
- Until the rider customises them, the active profile's `defaultMargins` `[top, bottom, left, right]` apply (`ScreenMargins.kt:29-32`): all zero except **800NK Advanced: top 22** (to blank MotoPlay's pull-down handle) (`BikeProfile.kt:128-131,598`; `SUPPORTED-BIKES.md:47`). Reset returns to profile defaults (`ScreenMargins.kt:68-73`).
- Applied only inside the compositor (AA + mirror): the fit rect is computed inside the inset area, everything else is black; changes are applied live (`AaCompositor.kt:300-306,347-355`; `ScreenMargins.kt:64,72`). **Not** applied to the own-UI/Map path. [V-CODE]
- **Y-origin caveat [I, likely latent bug]:** `vy` is computed as a top-left offset (`T' + …`) but passed straight to `glViewport`, whose origin is bottom-left on an EGL window surface. With asymmetric vertical margins the black band is drawn at the opposite edge and the drawn picture sits `(T − B)` px higher than `mapCanvasToSource` assumes (NK Advanced default T=22, B=0: band drawn at the bottom; touch is 22 px off vertically). Symmetric margins and left/right margins are unaffected. A code comment already notes unexplained "~+Y" touch issues on NK Advanced with FILL (`AaCompositor.kt:277-280`). Not confirmed on hardware — but iOS must define **one** top-left canvas coordinate system for drawing, margins, and touch.

### 10.5 Own-UI geometry (the iOS main path)

- Android renders its own dash UI (Map/GPX) into a private VirtualDisplay of **exactly** `negW×negH` pixels whose surface **is** the encoder input (`VideoPipeline.kt:523-542`). No fit/letterbox step. [V-HW: UI mode + Map on the dash]
- Density rule: `densityDpi = clamp(round(160 × W / 900), 160, 640)` (`TARGET_DASH_WIDTH_DP = 900`, `VideoPipeline.kt:529-533,783`). In iOS terms: lay out in "dash points" with `scale = max(1, W/900)`, so the logical width is `min(W, ~900)`: 800 px wide → 800 pt (scale 1.0); 1024 → 182 dpi ≈ 900 pt; 1280 → 228 dpi ≈ 898 pt.
- VirtualDisplay flags `OWN_CONTENT_ONLY | PRESENTATION` (private) (`VideoPipeline.kt:527-528`).
- Dash touch → own UI: canvas coordinates go **unchanged** into the UI root view as DOWN/UP/MOVE events (`EasyConnProber.kt:922-929`; `GpxSession.kt:114-134`), i.e. canvas px == UI px, top-left origin. [V-CODE]

### 10.6 Mirror-mode geometry (reference for the ReplayKit mode)

- Capture buffer starts at `W0 = even(max(displayWidthPx, canvasW))`, `H0 = even(max(displayHeightPx, canvasH))` (`x − x%2`), swapped if the mirror shape lock wants the other orientation (`VideoPipeline.kt:331-346`).
- Shape lock (`VideoPrefs.mirrorShape`, `VideoPrefs.kt:199-211`): FOLLOW → none; LANDSCAPE/PORTRAIT → forced; **MATCH_DASH (default)** → landscape iff `canvasW ≥ canvasH` (canvas, else the learned/profile panel, else 800×480). Android also locks the phone UI orientation (`SCREEN_ORIENTATION_SENSOR_LANDSCAPE/PORTRAIT`) and restores it afterwards (`MirrorOrientationLock.kt:18-40`; applied in `MainActivity.kt:100,1511,1701`).
- The capture goes into a compositor whose output is the encoder at the canvas size, fit per `ScreenFit` (default **FILL** — the user is advised to use FIT for mirror, but the code reads the shared preference) (`VideoPipeline.kt:353-363`).
- Content resize (single-app capture, rotation, folding): the new size is rounded **up** to even (`x + x%2`, min 2), the VirtualDisplay is resized (one VirtualDisplay per consent token), and the fit is recomputed (`VideoPipeline.kt:368-382,384-429`).
- A single shared app that goes to the background produces no frames (black dash); entire-screen capture holds a dim wake lock for up to 4 h (`ProjectionService.kt:63-84`; `VideoPipeline.kt:390-402`). Mirror mode does **not** forward dash touch ("Bike touch does not drive mirrored apps", `MainActivity.kt:384`).

### 10.7 Android-Auto-only geometry (reference)

AA renders at fixed sizes (800×480, 1280×720, 720×1280, 1080×1920; `BikeProfile.kt:19-24`). Optional AAP margins make AA draw an aspect-matched sub-rect: `AaMargins.forAspect` trims only the too-long axis, `usable = round(coded_other × target_ratio)`, clamped to `[16, coded]` (`BikeProfile.kt:49-64`); e.g. 720×1280 for an 800×951 panel → margins (0, 424). The compositor samples the **centered** usable region (`AaCompositor.kt:513-518`). Not needed for iOS.

---

## 11. Input-ish media commands

| Item | Where | Notes |
|---|---|---|
| **Media cmdType 32 — dash touch** | :10921, 18-byte body, no reply | `action u16@0` (2=DOWN, 3=MOVE, 1=UP) · `x u16@2` · `y u16@4` · `pointerId u16@6` · `timestamp u32@8` · bytes 12–17 unknown. Bodies < 8 B are dropped. Normalised to 0=DOWN, 1=UP, 2=MOVE; unknown actions dropped (`EasyConnProber.kt:827-847`). Coordinates in canvas px. Ghost-merge 48 px, stale pointer 300 ms, max 2 pointers, UP stitching 80 ms / 150 px (`EasyConnProber.kt:52-66`). **Full semantics: touch spec.** [V-HW] |
| Example 32 frame (DOWN at 400,200, pointer 0, ts 0x12345678) | — | `20 00 12 00 00 00 00 00 02 00 90 01 c8 00 00 00 78 56 34 12 00 00 00 00 00 00` |
| Control-plane `CMD_SCREEN_TOUCH` 0x30040, `CMD_MIRROR_START` 0x30020, `CMD_MIRROR_STOP` 0x30030 | :10922 constants from the SDK decompile (`PxcFrame.kt:96-98`) | Never observed. If one arrives it is acked `cmd+1` and logged (SCREEN_TOUCH is tagged `*** SCREEN_TOUCH ***`) (`BikeProfile.kt:574-578`). [X] |
| No other media-plane input commands | — | No "request IDR" command from the bike is known; unknown cmdTypes are only logged (§4.10). |

Handlebar buttons are Bluetooth AVRCP, not PXC (out of scope here).

---

## 12. Android Auto path — how its frames reach the bike (reference only)

`AaVideoBridge` is a process-global holder; `pipeline` is the AA `VideoPipeline` (compositor mode) that the prober adopts at 112 instead of creating its own (`AaVideoBridge.kt:11-12`; `EasyConnProber.kt:784-791`). Flow: Google AA (loopback :5288) → AAP video reassembly → MediaCodec decoder → `SurfaceTexture` → GL compositor (fit, margins, frame cap, keep-alive) → encoder input surface → drain → frame queue → 114 (`05-DEBUG-KNOWLEDGE.md:22-51`). The bike hand-off starts when AA decode reaches ≥ 25 fps (`aa/AaReceiver.kt:72-79`). Upstream, the AA side asks Gearhead for a keyframe on corrupted fragments at most once per 1 s (`aa/AapVideo.kt:17-27`), and restarts its decoder only on a real stall (no output > 3 s while input < 1 s ago) (`aa/VideoDecoder.kt:344-356`). The prober never owns or stops the AA pipeline (`EasyConnProber.kt:303-306`). None of this exists on iOS.

---

## 13. Docs vs code discrepancies (code wins)

| # | Docs say | Code does | Refs |
|---|---|---|---|
| 1 | `KEY_REPEAT_PREVIOUS_FRAME_AFTER = 100 000 µs` (≈10 fps floor) | **900 000 µs** (idea 5 shipped) | `01-REVERSE-ENGINEERING.md:171`, `04-APP-KNOWLEDGE-BASE.md:154-157` vs `VideoPipeline.kt:792`, `06-OPTIMIZATION-IDEAS.md:181-187` |
| 2 | SPS/PPS prepended to the **first** keyframe | prepended to **every** keyframe | `01-REVERSE-ENGINEERING.md:159,174-175` vs `VideoPipeline.kt:570` |
| 3 | Touch: `y u32@4`, single pointer | `y u16@4`, `pointerId u16@6`, multi-touch | `05-DEBUG-KNOWLEDGE.md:201-204` vs `EasyConnProber.kt:828-841` |
| 4 | Compositor keep-alive re-emits at ~15 fps | idle re-emit every **2 s**, 150 ms tick | `05-DEBUG-KNOWLEDGE.md:239-243` vs `AaCompositor.kt:105-106` |
| 5 | `PowerMode.AUTO` "now the default" | default is **BALANCED** (README agrees) | `06-OPTIMIZATION-IDEAS.md:42` vs `VideoPrefs.kt:155-158`, `README.md:332-333` |
| 6 | 800MT profile `forceBaseline=false` (Main/High) | Baseline (interface default true) | `05-DEBUG-KNOWLEDGE.md:261-263` vs `BikeProfile.kt:799-805` |
| 7 | Fixed 800×384 encoder | encoder size = live negotiated canvas | `04-APP-KNOWLEDGE-BASE.md:147-153` vs `EasyConnProber.kt:751-756,793-794` |
| 8 | Placeholder draws "Hacked by Coletz :P" | draws "OpenCfMoto" + "frame tick N" | `07-IDEAS-AND-ISSUES.md:46-53` vs `VideoPipeline.kt:448-470` |
| 9 | Morini profile described as a "dedicated Baseline landscape profile" | `forceBaseline = false` | `BikeProfile.kt:698-716` (same file, comment vs override) |

---

## 14. Test vectors

### 14.1 From the repository's unit tests

`test:AdaptivePolicyTest.kt` (thermal ints are `PowerManager.THERMAL_STATUS_*`: 0 NONE, 1 LIGHT, 2 MODERATE, 3 SEVERE, 4 CRITICAL, 5 EMERGENCY, 6 SHUTDOWN; `base = 2 500 000`, `baseFps = 30`):

| Call | Expected | Test line |
|---|---|---|
| `thermalBitrateFactor(0)`, `(1)` | 1.0, 1.0 | 19-22 |
| `thermalBitrateFactor(2)`, `(3)`, `(4)`, `(6)` | 0.8, 0.6, 0.5, 0.5 | 24-29 |
| `thermalFpsCap(0..1, 30)` / `(2,30)` / `(3,30)` / `(5,30)` | 30 / 20 / 15 / 12 | 33-39 |
| `thermalFpsCap(0, 20)` / `(3, 20)` | 20 / 15 | 41-45 |
| `nextLinkFactor(1.0, 8)` | 0.8 (±1e-4) | 49-52 |
| `nextLinkFactor(0.8, 0)` | 0.85 | 54-57 |
| 50 × `nextLinkFactor(f, 100)` from 1.0, then 200 × `(f, 0)` | 0.4, then 1.0 | 59-65 |
| `nextLinkFactor(1.0, 7)` | 1.0 | 67-70 |
| `decide(2.5M, 30, 0, 1.0, 0)` | bitrate 2 500 000, fps 30, link 1.0 | 74-79 |
| `decide(2.5M, 30, 3, 1.0, 0)` | bitrate `(2.5M×0.6f).toInt()` = 1 500 000, fps 15 | 81-85 |
| `decide(2.5M, 30, 2, 0.5, 100)` | link 0.4, bitrate 1 000 000, fps 20 | 87-94 |
| `decide(1 000 000, 30, 6, 0.4, 100)` | bitrate ≥ 600 000 (exactly 600 000) | 96-102 |
| `decide(400 000, 30, 6, 0.4, 100)` | bitrate ≤ 400 000 (exactly 400 000) | 104-109 |

`test:YunmoFrameTest.kt` — Annex-B helper vectors usable for an iOS NAL parser (the Yunmo transport itself is out of scope):

| Input | Expected | Lines |
|---|---|---|
| `00 00 00 01 67 42 00 1f` | first NAL type 7 (SPS) | 85-94 |
| `00 00 00 01 65 00 01` | first NAL type 5 (IDR) | 85-94 |
| `00 00 01 41 00` (3-byte start code) | first NAL type 1 (P) | 85-94 |
| SPS `00 00 00 01 67 42 00` + PPS `00 00 00 01 68 ce` + IDR `00 00 00 01 65 88` | split into 3 NALs; stripping SPS/PPS leaves `00 00 00 01 65 88` | 116-128 |

(`YunmoFrameTest.kt:102-114` asserts `encodeSizeFrom` returns 2048×928 while the current code returns the reported 1024×464 — a stale Yunmo test, irrelevant to PXC.)

No unit tests exist in the repository for ReqBase framing, RLY 17, frame writes, `computeViewport`, or `mapCanvasToSource`.

### 14.2 Derived vectors (computed from the Kotlin semantics)

ReqBase replies (token always 0):

```
65  : 41 00 00 00 00 00 00 00
49  : 31 00 08 00 00 00 00 00 03 00 00 00 01 00 00 00
97  : 61 00 0b 00 00 00 00 00 7b 22 73 74 61 74 65 22 3a 30 7d
113 : 71 00 00 00 00 00 00 00
129 : 81 00 00 00 00 00 00 00
17 (800×386 → 800×384, ext 0) : 11 00 09 00 00 00 00 00 02 00 00 00 20 03 80 01 00
17 (800×951 → 800×944, ext 0) : 11 00 09 00 00 00 00 00 02 00 00 00 20 03 b0 03 00
17 (1280×576, ext 0)          : 11 00 09 00 00 00 00 00 02 00 00 00 00 05 40 02 00
```

Requests:

```
114 : 72 00 00 00 00 00 00 00      112 : 70 00 00 00 00 00 00 00      64 : 40 00 00 00 00 00 00 00
48  : 30 00 00 00 00 00 00 00      128 : 80 00 00 00 00 00 00 00
```

Rounding (`x & 0xFFF0`): 386→384, 951→944, 576→576, 400→400, 460→448, 750→736, 712→704, 544→544, 512→512, 1024→1024, 464→464, 720→720, 480→480.

Frame write (toy AU of 30 bytes):

```
1e 00 00 00 00 00 00 01 67 42 00 1f da 01 40 12 69 a8 00 00 00 01 68 ce 0d 88 00 00 00 01 65 88 84 00
```

Frame cap (`AaCompositor.setFrameCap`): 30→33 ms, 24→41 ms, 20→50 ms, 15→66 ms, 12→83 ms, 10→100 ms, 5→clamped 10→100 ms, 100→clamped 60→16 ms.

Own-UI density (`clamp(round(160·W/900),160,640)`): W=544→160, 720→160, 800→160, 1024→182, 1280→228, 1920→341.

Viewports and inverse map: see §10.3.

---

## 15. iOS implementation notes

### 15.1 Media sockets (Network.framework)

- Three `NWListener`s (10922, 10921, 10920) on the bike-Wi-Fi interface, created **before** the probe, `allowLocalEndpointReuse = true` (the SO_REUSEADDR lesson, §2.2), TCP `noDelay = true`, **no read/idle timeouts**. Keep them listening for the whole session.
- Choose framing by the listener's port; make 10921/10920 **port-agnostic**: one ReqBase codec, one dispatcher, reply on the connection the request came from (§2.3).
- Read exactly 8 bytes, then exactly `cmdLen` bytes (`receive(minimumIncompleteLength: n, maximumLength: n)`); EOF or short read ⇒ close that connection.
- Track live connections; when the count reaches 0 after a successful session, run the re-probe loop with the same backoff (§9.4). The shared `ByteReader`/`ByteWriter` in `OpenCfMotoCore/Util/ByteIO.swift` already provide the LE primitives.

```swift
// ReqBase reply. Token is ALWAYS 0 (EasyConnProber.kt:722).
func reqBase(_ cmd: Int16, _ body: [UInt8] = []) -> Data {
    var w = ByteWriter(capacity: 8 + body.count)
    w.i16le(cmd); w.u16le(UInt16(body.count)); w.i32le(0); w.append(body)
    return w.data
}
// RLY 17 for a REQ 16 body (EasyConnProber.kt:733-764).
func rly17(for body: [UInt8]) -> (Data, w: Int, h: Int) {
    var r = ByteReader(body)
    let w = body.count >= 2 ? Int((try? r.u16le()) ?? 0) : 0
    let h = body.count >= 4 ? Int((try? r.u16le()) ?? 0) : 0
    let enc: Int32 = body.count >= 12 ? (r.peekI32le(at: 8) ?? 2) : 2
    let ext: UInt8 = body.count >= 30 ? body[29] : 0
    let cw = w & 0xFFF0, ch = h & 0xFFF0
    var b = ByteWriter(capacity: 9)
    b.i32le(enc == 0 ? 2 : enc)
    b.i16le(Int16(truncatingIfNeeded: cw)); b.i16le(Int16(truncatingIfNeeded: ch)); b.u8(ext)
    return (reqBase(17, b.bytes), cw, ch)
}
// One pulled frame on :10920 — RAW, no ReqBase header (EasyConnProber.kt:708-715).
func rawFrame(_ au: Data) -> Data {
    var w = ByteWriter(capacity: 4 + au.count); w.i32le(Int32(au.count)); w.append(au); return w.data
}
```

Guard (not in Android): if the REQ 16 width or height is 0, log loudly and keep the previous canvas rather than replying 0.

### 15.2 Answer every 114 (stricter than Android)

- Hold the 114 until a frame exists; do **not** give up after 1.5 s (Android's silent give-up very likely costs the session, §5.4). Wait up to roughly 5 s (comfortably under the bike's ~9 s), and if the queue is empty when the 114 arrives, **immediately re-encode the last rendered pixel buffer** so the reply goes out within one encode latency.
- Never send a zero-length or placeholder frame and never re-send the previous P-frame (re-applying a P-frame corrupts the picture). Re-sending the last IDR is decodable but unnecessary if you re-encode.
- Send `[size][AU]` as **one** `send` (one `Data`), and update `framesSent` / `lastFrameAt` in the `.contentProcessed` completion. One frame in flight per 114.
- Keep a phone-side watchdog: STREAMING and no frame sent for > 8 s ⇒ cancel every bike connection to force the re-probe path (20 s cooldown), as `AndroidAutoService.kt:134-154` does.

### 15.3 Encoder (VideoToolbox)

Create the `VTCompressionSession` at **exactly** the RLY 17 canvas (always a multiple of 16 ⇒ no SPS cropping). Recommended properties, mapped from the Android values:

| Android | VideoToolbox |
|---|---|
| Baseline @ 3.1 | `kVTCompressionPropertyKey_ProfileLevel = kVTProfileLevel_H264_Baseline_3_1` (use `…Baseline_AutoLevel` for canvases above 3600 macroblocks/frame or 108 000 macroblocks/s; untested on dashes) |
| `KEY_LATENCY = 1`, no B-frames | `kVTCompressionPropertyKey_AllowFrameReordering = false` (**mandatory**: no PTS on the wire); `kVTCompressionPropertyKey_RealTime = true`; consider `MaxFrameDelayCount = 0` |
| CAVLC (Baseline) | `kVTCompressionPropertyKey_H264EntropyMode = kVTH264EntropyMode_CAVLC` |
| 2.5 Mbit/s × quality, CBR | `AverageBitRate = bitrate`; `DataRateLimits = [bitrate·1.5/8 bytes, 1 s]` for CBR-like peaks; `ConstantBitRate` where supported (iOS 16+, may return `kVTPropertyNotSupportedErr`) |
| 30 fps target, I-frame every 1 s | `ExpectedFrameRate = fps cap`; `MaxKeyFrameInterval = fps × 1`; `MaxKeyFrameIntervalDuration = 1.0` (Morini profile: 2.0) |
| `REQUEST_SYNC_FRAME` | `kVTEncodeFrameOptionKey_ForceKeyFrame: true` in the next frame's properties |
| `KEY_REPEAT_PREVIOUS_FRAME_AFTER = 0.9 s` | **No VT equivalent** — run your own timer: if nothing was encoded for ≥ 0.9 s, re-submit the last `CVPixelBuffer` |
| Monotonic PTS on repeats | strictly increasing `presentationTimeStamp` (host clock), including repeats |

Output conversion (VT emits AVCC: 4-byte big-endian NAL lengths; SPS/PPS live in the format description):

```swift
// In the VTCompressionOutputCallback, serialized on one queue:
let notSync = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?
    .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
let isKey = !notSync
var au = Data()
let sc: [UInt8] = [0, 0, 0, 1]
if isKey, let fd = CMSampleBufferGetFormatDescription(sb) {
    for i in 0..<2 {   // 0 = SPS, 1 = PPS (read the count/nalUnitHeaderLength from the first call)
        var p: UnsafePointer<UInt8>?; var n = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i,
            parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil)
        if let p { au.append(contentsOf: sc); au.append(p, count: n) }
    }
}
// Walk the block buffer: [4-byte BE length][NAL]… → start code + NAL.
// Recommended (conservative, not Android behaviour): skip NAL types 6 (SEI), 9 (AUD), 12 (filler).
```

- Prepend SPS+PPS to **every** IDR, exactly as Android does, and never emit them as a standalone pull response.
- Compare the first iOS SPS/PPS against the known-good Android pair (§7.6). VideoToolbox Baseline output usually differs (constraint flags, POC type, VUI); that is expected to be fine but is **untested** on dashes — capture it on the first bike test.
- `kVTInvalidSessionErr` (e.g. after backgrounding or a media-services reset): recreate the session with the same canvas and properties, then apply the **112 sequence** (gate, flush, forced IDR) before serving frames again.

### 15.3a Background encoder ladder (locked phone; Phase 0 diagnostics build)

iOS takes the hardware encoder away in the background (ios-platform-facts.md §d), so the engine
(`DashProjectionEngine`) feeds the dash through `DashVideoEncoder` (`OpenCfMotoApple/DashVideoEncoder.swift`;
`H264Encoder` conforms) and a **ladder of background encoders**, with pure rules in Core
(`OpenCfMotoCore/Video/BackgroundEncoding.swift`, `H264StreamCheck.swift`):

- **Foreground:** VideoToolbox hardware (`own`), unchanged.
- **Background** (`.background` scene phase): the rungs of `LockedStreamPolicy` — `auto`: vt-sw, cpu,
  hold; `vtsw`: vt-sw, hold (**the Phase 0 build**); `cpu`: cpu, hold; `hold`: hold; unavailable rungs are
  skipped (no CPU encoder is bundled in Phase 0). vt-sw tries, in order: the session pre-warmed at
  `.inactive` (`own-sw-pre`, created in the foreground and probed into a sink that never reaches the frame
  queue), a fresh `EnableHardwareAcceleratedVideoEncoder = false` session, then one per `avc1` `EncoderID`
  not marked hardware. Each try is **probed** before anything of it is served: a forced IDR of the last
  picture within 500 ms, accepted only if the session was created, `UsingHardware…` is not `true` (an
  unanswered one is accepted only with a probe IDR), and `H264StreamCheck` finds nothing wrong (4-byte start
  codes; NAL types 1, 5, 7, 8; `[7, 8, 5…]` IDRs; Baseline, the level the canvas needs, exactly the canvas,
  no cropping, frame MBs only, POC 0 or 2, ≤ 2 references, no reorder, ids 0, CAVLC, one slice group, I/P
  slices). The last rung is the pre-encoded **hold picture** ("Map paused").
- **Demotion:** 3 encode failures within 10 s, or 3 s without output after an accepted submission, moves to
  the next rung with the full acceptance again; a hold reached by a demotion is retried 60 s later, at most
  3 times per background period.
- **Fallback order (P0-5).** A pull that times out is answered with: in `backgroundSoftware`, the live
  background encoder's last IDR, then the hold picture, then any live IDR of this canvas; in `hold`, the
  hold picture, then the live IDR; in the foreground, the last live IDR only (unchanged). Before Phase 0
  the hold picture came first in `backgroundSoftware`: the "Phone locked" card while the map is live was
  wrong, and every extra encoder change on the wire is a risk.
- **Switches only at an IDR.** Every encoder change closes the frame-queue gate (`resynchronize()`), so the
  next frame on the wire is the new encoder's IDR with its SPS + PPS; the probe IDR of an accepted encoder is
  its first frame. Each encoder instance stamps its frames (`EncodedFrame.encoderTag`: 1 hold, 2, 3, …
  live encoders; never on the wire), and a change of tag on the wire always falls on an IDR (tested). The
  dash has never been shown an SPS change mid-session before: the E2E scenario `locked`
  (tools/ci/e2e/README.md) records every SPS/PPS variant and decodes strictly.
- **Frame rate.** With a background encoder the render timer at `backgroundFrameRate` (8 fps) alone paces
  the stream: a pull that finds the queue empty does not render at once as in the foreground (§15.4), so the
  stream stays at the cap even when the dash pulls faster (about 24/s while the map moves; the E2E fake dash
  pulls about 9/s).
- **Phase 0 only:** in hold the engine also runs a background CPU **dry run** for the first 10 minutes
  (render, vImage BGRA→I420, 10 ms of synthetic load, at 8 fps, all discarded) to measure what iOS tolerates.

**Diagnostics lines** (format `HH:mm:ss.SSS L/TAG: message`; the texts are pure functions —
`BackgroundLog` in Core for L1–L13, `LockDiagnostics` in the app model for L14–L18 — pinned by Linux tests;
field values below are examples):

| ID | Level/tag | When | Form |
|---|---|---|---|
| L1 | I/VIDEO | first IDR of every encoder (`own`, `own-sw-pre`, `own-sw`, `own-sw-id`, `hold`, `mirror`) | `[own] first IDR 23410b SPS 27 42 e0 1f … PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- \| pps cavlc deblock_ctrl=1 qp=28` (full hex) |
| L2 | I/VIDEO | first foreground prepare of the run | `[vt-list] avc1 encoders: <id> name=<name> hw=<true\|false\|?>; …` |
| L3 | I/VIDEO | pre-warm at `.inactive` | `[bg] pre-warm vt-sw at inactive: create=noErr hw=? probe=IDR 20112b in 45ms` |
| L4 | I/VIDEO | ladder run | `[bg] enter: canvas 800x384 policy=vtsw rungs=vt-sw,hold last-live-idr=23410b hold-idrs=2` |
| L5 | I/VIDEO | each try | `[bg] try vt-sw (fresh): create=noErr hw=? probe=IDR 20112b in 45ms sps=ok → accepted` / `… → rejected: hw=true` / `… probe=none in 500ms sps=- → rejected: probe=none` |
| L6 | I/VIDEO | ladder outcome | `background → backgroundSoftware @8fps (encoder vt-sw, 3375kbps)` / `background → hold (2 hold IDR(s); reason: all rungs rejected)` |
| L7 | I/VIDEO | every encoder change | `[switch] vt-hw → vt-sw: gate closed; next frame on the wire is an IDR (dump frame #133)` |
| L8 | I/VIDEO | first IDR of a new encoder on the wire | `[switch] first vt-sw IDR on the wire: 19876b, 0.21s after the switch (dump frame #133)` |
| L9 | I/VIDEO | every 10 s while backgrounded | `[bg] +1m00s mode=backgroundSoftware enc=vt-sw cap=8fps out=5.2fps pulls=5.1/s served=312 (hold 0, fallback 2, none 0) errs=0 render=6.1ms enc=7.8ms cpu=14% thermal=none lowPower=false q=0` |
| L10 | I/VIDEO | dry run (Phase 0), every 60 s | `[bg-probe] render=6.3ms convert=0.9ms load=10ms n=480 cpu=13%` / `[bg-probe] dry run ended after 10m00s` |
| L11 | I/VIDEO | budget (Phase 1; none in Phase 0) | `[bg-budget] fps cap 8→5: cpu 27% (15s) thermal=none lowPower=false batt=64% unplugged` |
| L12 | W/VIDEO, I/VIDEO | demotion, retry | `[bg] vt-sw demoted: 3 encode errors in 10s (last …) → hold` / `[bg] retry ladder (60s after the demotion, attempt 1/3)` |
| L13 | I/VIDEO | unlock | `foreground → hardware encoder, IDR forced (background 12m03s: vt-sw 3412 frames 812 IDR 0 errors enc 8.1ms; hold served 4)` |
| L14 | I/APP | every scene change | `scene inactive → background (own UI session, streaming)` / `scene background → inactive after 12m03s (…)` |
| L15 | I/APP | every 30 s while locked with an own-UI session | `[lock] 5m00s locked link=streaming wifi=up pulls=5.1/s dash=backgroundSoftware vt-sw 5.2fps gps=1s heading=2s batt=63% charging thermal=none lowPower=false` |
| L16 | W/APP | next launch after the app ended in the background during a session | `previous run ended in the background during a dash session (backgrounded 14:03:12): iOS stopped the app, or it was swiped away` |
| L17 | I/RIDE | GPS that ran for the preview restarted with background updates (foreground only) | `GPS restarted with background updates (it was running for the preview)` |
| L18 | W/CRASH, I/APP | MetricKit | `[metrickit] CPU exception: 54s CPU in 60s (build 12, iOS 27.0.1)`, `[metrickit] hang: 3.2s (…)`, `[metrickit] disk writes: 1024 MB (…)`; `[metrickit] background exits (24h): cpu-limit=1 memory=0 memory-pressure=0 watchdog=0 locked-file=0 task-timeout=0 abnormal=0 normal=3` |

Reading one locked test, in time order: L14 (locked while streaming) → L3 / L4 / L5 / L6 (which rung iOS
allowed, and why the others were refused: the OSStatus, `hw=true`, `probe=none` or an SPS issue code) →
L7 / L8 (the first new IDR on the wire within about 1 s) → L9 every 10 s, L15 every 30 s and the link's
`hb#` every 5 s without gaps (the process, the Wi-Fi and the link alive) → L13 + L1 `[own]` at the unlock.
L16 (+ L18) on the next launch means iOS ended the app. No line carries `sn=`, `key=`, `token=`, `pwd=`, an
SSID, a MAC, a serial, a password or coordinates.

### 15.4 Keyframe gate and queue (fixing the Android gaps)

```swift
// All on the encoder's serial queue.
func onBikeDataStart() {              // on every 112, after (re)creating the session if the canvas changed
    awaitKeyframe = true              // set the gate BEFORE flushing (Android does it the other way round, §7.4)
    queue.removeAll()
    forceKeyFrameOnNextEncode = true
    encodeLastPixelBufferNow()        // do not wait for the next UI change
}
func onEncoded(_ au: Data, isKey: Bool) {
    if awaitKeyframe && !isKey { return }          // not counted as a drop
    if isKey { awaitKeyframe = false }
    if queue.count >= capacity {                   // GOP-safe overflow instead of drop-oldest
        queue.removeAll(); awaitKeyframe = !isKey; forceKeyFrameOnNextEncode = !isKey
        overflowCount += 1                         // link-congestion signal for Auto mode
        if !isKey { return }
    }
    queue.append(au)
}
```

- Keep capacity small (2–3, `06-OPTIMIZATION-IDEAS.md:137`) and, better, **pace rendering by pulls**: do not render a new UI frame while one encoded frame is already waiting. The bike's pull rate (~30/s observed at 1280×576) then sets the frame rate, and drops (and their reference-chain damage) disappear.
- Reply 113 only after the encoder exists and the forced IDR has been requested (Android order, §4.6).

### 15.5 Rendering the dash UI (CoreGraphics)

- Render **straight at canvas size** into BGRA `CVPixelBuffer`s from the session's pixel-buffer pool (`kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little`). There is no letterbox step for your own UI.
- Use a **top-left origin** (flip the CTM: `translateBy(x: 0, y: H)`, `scaleBy(x: 1, y: -1)`) so drawing, margins and dash touch (canvas px, top-left) share one coordinate system and you avoid Android's margin y-flip (§10.4). Touch maps 1:1 to UI pixels.
- Layout scale: `scale = max(1, W/900)` dash points (§10.5). Support wide (800×384, 1280×576, 800×400), tall (800×944, 448×736) and near-square (720×704, 544×512) canvases.
- Treat the profile's `defaultMargins` (800NK Advanced: top 22) plus user margins (0…200 per edge) as the UI's unsafe area: paint it black and ignore touches there.
- Frame-rate cap = power mode (Auto 30 → adaptive, Smooth 30, **Balanced 24 default**, Saver 20); render only on change, coalesce invalidations, plus the ≤ 0.9 s keep-alive re-encode. A clock that shows seconds forces at least 1 fps anyway.
- Opaque black is `(0,0,0,255)` in BGRA. If you ever fill NV12 buffers directly, black is `Y = 16, Cb = Cr = 128` (video range) or `Y = 0, Cb = Cr = 128` (full range) — zeros give green.

### 15.6 Auto power mode

Port `AdaptivePolicy` verbatim (pure, testable; use the §14.1 vectors) and tick every 5 s. Inputs on iOS:
- Thermal: `ProcessInfo.processInfo.thermalState`. Suggested mapping (design choice, not from Android): `.nominal → NONE(0)`, `.fair → MODERATE(2)`, `.serious → SEVERE(3)`, `.critical → CRITICAL(4)`. A looser alternative is `.fair → LIGHT(1)` (no throttle). Mapping `.fair` to MODERATE is the cautious choice for a phone sitting in the sun on a handlebar.
- Link: overflow events per tick (≥ 8 ⇒ congested). If you adopt pull-paced rendering (no overflows), use "render ticks skipped because a frame was still waiting" or a falling pull rate instead.
- Apply bitrate live with `VTSessionSetProperty(…AverageBitRate…)` (clamp to `[min(600 000, base), base]`), and fps as the render cap plus `ExpectedFrameRate`.

### 15.7 ReplayKit mirror mode

- The broadcast extension gets full-screen `CMSampleBuffer`s (often 420f/420v at native or scaled size; honour `RPVideoSampleOrientationKey`, whose quarter turns are the opposite of EXIF: ios-platform-facts.md §f). Fit into the canvas with §10.3: `VTPixelTransferSession` scaling modes map neatly — FIT → `kVTScalingMode_Letterbox`, FILL → `kVTScalingMode_Trim`, STRETCH → `kVTScalingMode_Normal`. Margins need a destination sub-rect (vImage/Core Image).
- Default to **FIT** for mirror: iOS cannot rotate other apps the way Android's `MATCH_DASH` lock does, and FILL on a portrait phone shows only a horizontal slice (§10.3 table).
- ReplayKit stops delivering frames on a static screen, just like Android's surface input: the 0.9 s keep-alive re-encode is mandatory. Recompute the fit whenever the buffer size or orientation changes (Android's `onCapturedContentResize` equivalent). Keep chroma-aligned (even) destination rects for 4:2:0.
- No touch back: dash touches are dropped or used only for an overlay (Android does the same).
- The extension has a tight memory budget (about 50 MB): tiny queues, one VT session, and an IPC path for the encoded AUs to whatever process owns the :10920 connection (design decision for the architecture spec).

### 15.8 Diagnostics to build in from day one

- An Annex-B dump of exactly what goes on the wire (Android `DUMP_H264`, 600-AU cap), shareable from the app — it is how the black-screen bug was solved.
- Log: full REQ 16 body hex (to finally learn `wantFps`, `bitRate`, `min/maxQuality`, `orientation`), request tokens, every unknown cmdType with hex, `sent frame #N (S b)` for the first 5 and every 60th, every 114 that waited longer than 1 s, overflow counts, SPS/PPS hex on session creation (the **full** SPS and PPS with a parsed summary at the first IDR of every encoder since the locked-phone Phase 0 build: L1 of §15.3a).

---

## 16. Open questions / risks

1. **Unanswered 114.** Does the bike ever retry a 114, and what does the official app send when it has no frame (the doc mentions a possible `INT_ZERO` terminator, `01-REVERSE-ENGINEERING.md:159-162`)? Android sends nothing. iOS should avoid the situation entirely (§15.2); a zero-size reply must not be used until it is verified.
2. **Socket and order of 48/64/96/112.** Not recorded; Android is port-agnostic. The heartbeat interval on :10921 is unknown.
3. **Token semantics.** The bike's request tokens were never logged; Android always replies with 0 and that works. Log them.
4. **Unparsed REQ 16 fields** (`wantFps`, `supportCodec`, `min/maxQuality`, `bitRate`, `capScreenMode`, `touchMode`, `orientation`, `displayId`, `videoType`, `encryptedHUID`) — values and meaning unknown; Android ignores them. Could the dash ask for a lower bitrate/fps that we should honour?
5. **`supportExtendProtocol` and 96/97.** Echoed byte and `{"state":0}` work, but the content of the 96 JSON and the meaning of `state` are undocumented.
6. **`128` REQ_START_H264** has never been seen on a bike; if a dash used it instead of 112, Android would never start an encoder or force an IDR. Recommended iOS behaviour: reply 129 and also run the 112 sequence (harmless if unused). Unverified.
7. **VideoToolbox bitstream acceptance** (constraint flags, POC type, VUI, possible SEI, slice layout) on CFDL16/CFDL26 decoders is untested. The Android SPS/PPS in §7.6 is the reference that is known to decode.
8. **iOS background execution** is the biggest platform risk: hardware encoding with the screen locked or the app in the background (VT session invalidation, `kVTInvalidSessionErr`; an Apple Media Engineer confirms the resources are given up), Metal/GPU being unavailable in the background (CoreGraphics on the CPU is safer), and no Wi-Fi power-save control (Android holds `WIFI_MODE_FULL_HIGH_PERF` + `WIFI_MODE_FULL_LOW_LATENCY` locks, `AndroidAutoService.kt:353-372`, `07-IDEAS-AND-ISSUES.md:16-23`). The spike is the Phase 0 diagnostics build (§15.3a): it tries the VideoToolbox software encoder in the background, measures the background CPU cost and logs whether the process and the Wi-Fi survive. Open: whether the dash decodes an SPS change at an IDR mid-session (never shown before).
9. **Large canvases** (above Level 3.1, e.g. ≥ 1280×720 at 30 fps) and the dash's maximum accepted frame/bitrate size are unknown; known-good keyframes are 23–33 KB at 2.5 Mbit/s. "Sharp" (4 Mbit/s) and the Map boost (3.375 Mbit/s) ship on Android but their per-dash limits are untested.
10. **Asymmetric margins y-flip** (§10.4): if real, Android's NK Advanced default (top 22) blanks the bottom instead of the MotoPlay pull-down. Verify on hardware before copying that default's intent.
11. **Drop-oldest corruption** (§7.4) is real on Android and is avoided on iOS only if the overflow handling or pull pacing of §15.4 is implemented.
12. **Mid-session canvas change** is not supported by Android (needs reconnect); unknown whether any dash re-sends REQ 16 with a new size during a session.
13. **Bike pull-rate ceiling** at 800×944 (CFDL26) or on older CFDL16 hardware is not measured; ~30 pulls/s is known only for the 800MT at 1280×576.
14. **Morini profile values** (10 fps, 2 s GOP, no forced Baseline) come from the OEM Yunmo/"Ride MO" app and are experimental on the PXC path.
15. **Touch coordinate space** = canvas px (top-left) is consistent with the code and docs; edge cases (dashes reporting physical-panel coordinates) are for the touch spec.
16. **Out of scope:** the Yunmo SoftAP transport (Moto Morini X-Cape 1200, :8200, `YunmoFrame.kt`/`YunmoLink.kt`) is a different protocol, not PXC. It shares the H.264 lessons (SPS+PPS on every IDR, forced sync frames) but needs its own spec if it is ever ported.
