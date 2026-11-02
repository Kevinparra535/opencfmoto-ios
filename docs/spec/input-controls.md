# Spec: Dash touch input, handlebar buttons and controls

Area: **dash touchscreen input** (PXC media `cmdType 32`), the **ghost-touch / contact re-acquisition
filter**, how dash touches drive the **built-in dash map UI**, and the **handlebar buttons** (Bluetooth
AVRCP) with their gesture engine, cluster presets, presence auto-detection, and on-phone controls.

Source of truth: the Android app "OpenCfMoto" (Kotlin, AGPL-3.0) at `/home/user/open-cfmoto`. This spec is
written so the iOS (Swift) port can be built **without reading the Kotlin**. The iOS app does not run
Android Auto. It renders its own dash UI (map + HUD), encodes H.264 with VideoToolbox, and streams it to the
dash over PXC. It can optionally mirror the whole screen with ReplayKit (no touch-back in that mode). So the
Android Auto parts below are kept only where they carry protocol knowledge: touch semantics, coordinate
geometry, and timing.

---

## 0. Legend and conventions

**Fact tags** (every non-trivial fact carries one):

| Tag | Meaning |
| --- | --- |
| **[HW]** | VERIFIED on real hardware: a doc, the README, or a code comment says it was confirmed on a bike or seen in field logs. |
| **[CODE]** | VERIFIED as the shipping Android code path. Behavior is exactly what the code does; it has not necessarily been confirmed on hardware separately. |
| **[INF]** | INFERRED. An assumption flagged as such in the code or docs, or a derivation made in this spec. |
| **[EXP]** | EXPERIMENTAL. Behind a toggle, unreachable/dead in practice, or explicitly unverified. |
| **[PLAT]** | A platform (Android or iOS) framework or library default that the app does not set itself. Verify it on device. |
| **[PROP]** | A proposal for the iOS port. It is not in the Android code. |

**Citations**: `File.kt:line` is relative to `app/src/main/java/dev/zanderp/opencfmoto/` unless a path is
given. `docs/…` → `/home/user/open-cfmoto/docs/…`, `README.md:line` → repo README, tests →
`app/src/test/java/dev/zanderp/opencfmoto/…`, layouts → `app/src/main/res/…`.

**Conventions**:
- All multi-byte wire fields are **little-endian**. `u16` = unsigned 16-bit, `s16` = signed 16-bit,
  `u32`/`i32` likewise.
- Times are milliseconds on a **monotonic** clock unless stated otherwise. Android uses
  `SystemClock.elapsedRealtime()` for the touch filter and button engine.
- **Normalized touch actions** (used downstream of the wire decoder everywhere): `0 = DOWN`, `1 = UP`,
  `2 = MOVE` (`aa/AaInput.kt:27-29`).
- "Canvas" means the negotiated bike video size `negW × negH`, i.e. the `captureWidth × captureHeight`
  we return in `RLY_RV_CONFIG_CAPTURE (17)`.

**Related specs** (sibling files in `docs/spec/`). This file is authoritative for input semantics.
- `media-video.md`: the ReqBase media framing, `REQ_RV_CONFIG_CAPTURE` / RLY 17, and the canvas
  negotiation.
- `control-plane.md`: the CLIENT_INFO reply template and the `cmd+1` acks for unknown control frames.
- `navigation-dash.md`: the built-in dash map UI itself (layout, camera, routing). Its focus lists must
  match §6.6.
- `app-features.md`: the settings inventory.

---

## 1. Big picture

There are two independent physical input channels, plus phone-side helpers:

```
 (A) DASH TOUCHSCREEN  ── Wi-Fi / TCP, PXC media plane (:10921) ────────────────────────────────┐
     dash ──ReqBase cmdType 32 (18-byte body)──▶ EasyConnProber.handleTouch                      │
            decode ▶ normalize action ▶ ghost filter ▶ UP hold/stitch (80 ms) ▶ emit()          │
                                                    ├─▶ AaVideoBridge.touchSink (Android Auto)   │
                                                    │     letterbox-inverse ▶ AaInput (multi-touch)
                                                    └─▶ GpxSession.dispatchTouch (built-in map)  │
                                                          single-pointer MotionEvent ▶ View tree │
 (B) HANDLEBAR BUTTONS ── Bluetooth Classic AVRCP (NOT PXC) ─────────────────────────────────────┤
     ◀ ▶ ★  (passthrough keys) ─▶ MediaSession.onMediaButtonEvent ─▶ tap/×2/hold engine          │
     ▲ ▼    (absolute volume)   ─▶ STREAM_MUSIC ContentObserver   ─▶ direction (+jump size)      │
                                   ─▶ ButtonGesture ─ButtonMap─▶ ButtonAction                    │
                                        ├─▶ MapInputBridge (built-in map focus engine)  [wins]   │
                                        └─▶ AaVideoBridge.keySink / scrollSink (Android Auto)    │
 (C) PHONE SIDE: Controls pad, HID "remote pad", Dash-view preview, "type on phone" search ──────┘
```

- The handlebar buttons **never** travel over the PXC/Wi-Fi link. They are Bluetooth AVRCP and HFP
  commands from the dash's Bluetooth module to whatever phone is paired with the bike **[HW]**
  (`MediaButtonBridge.kt:30-32`, `BluetoothHelper.kt:15-19`). On one surveyed 450NK (no T-Box), the dash's
  BT module was identified as a Feasycom FSC-BT1026C dual-mode audio module, i.e. "the hands-free /
  media-button path" (`docs/RE-VEHICLE-TELEMETRY.md:19-35`) **[HW]**.
- The PXC plane carries only screen and touch, plus control frames
  (`docs/RE-VEHICLE-TELEMETRY.md:39-45`) **[HW]**.

**What the iOS port keeps**:
- (A) in full, because we own the PXC sockets. Its sink becomes our own dash UI, which is the analogue of
  the "built-in map" path, but with real multi-touch.
- (B) only partially, through `MPRemoteCommandCenter` and volume observation. See §8–§9.
- (C) as on-phone UI, a lock-screen Live Activity, and game-controller input.
- The AA-only parts are dropped: AAP `InputReport`, the `AaCompositor` touch letterbox, and `NavLauncher` to
  Google Maps.

---

## 2. Dash touch: wire format (PXC media `cmdType 32`)

### 2.1 Transport and framing

| Fact | Value | Tag / source |
| --- | --- | --- |
| Plane / port | PXC **media plane**. Touch frames arrive on the **media-control socket :10921**. Logs show `[:10921] TOUCH …`. | [HW] `docs/05-DEBUG-KNOWLEDGE.md:196` |
| Port tolerance | The phone runs the same `mediaLoop` on **both** :10921 and :10920, so a `cmdType 32` on either socket is handled. | [CODE] `EasyConnProber.kt:679-681`, `:819` |
| Framing | ReqBase, **8-byte LE header** then body: `cmdType s16 @0`, `cmdLen u16 @2`, `token i32 @4`, then `body[cmdLen]`. | [HW] `docs/01-REVERSE-ENGINEERING.md` §4; [CODE] `EasyConnProber.kt:692-704` (`cmdType=getShort(0)`, `cmdLen=getShort(2) and 0xFFFF`, `token=getInt(4)`) |
| `token` | Read but **ignored** for touch. | [CODE] `EasyConnProber.kt:699`, `:819` |
| Dispatch | `cmdType == 32` → `handleTouch(tag, body)`. | [CODE] `EasyConnProber.kt:819` |
| Reply | **None**. The phone never answers a touch frame, and the dash keeps sending them. | [CODE] `EasyConnProber.kt:835-889` (no write); [HW] dash "fully alive and interactive" with this behavior, `docs/05-DEBUG-KNOWLEDGE.md:132-133` |
| Observed body length | **18 bytes** ("decoded from logs"). | [HW] `docs/05-DEBUG-KNOWLEDGE.md:201` |
| Minimum accepted | `body.size < 8` → drop with log `"[$tag] touch frame too short (${body.size}b)"`. | [CODE] `EasyConnProber.kt:836` |

### 2.2 Body layout (18 bytes, little-endian)

| Offset | Size | Type | Field | Meaning | Tag / source |
| ---: | ---: | --- | --- | --- | --- |
| 0 | 2 | u16 LE | `action` | Raw action: **2 = DOWN, 3 = MOVE, 1 = UP**. | [HW] `docs/05-DEBUG-KNOWLEDGE.md:132-133`, `:202`; [CODE] `EasyConnProber.kt:838`, `:842-847` |
| 2 | 2 | u16 LE | `x` | Horizontal position, canvas pixels (see §3). | [HW]+[CODE] `EasyConnProber.kt:839` |
| 4 | 2 | u16 LE | `y` | Vertical position, canvas pixels. | [CODE] `EasyConnProber.kt:840`, comment `:830-831` ("Y is u16 at @4") |
| 6 | 2 | u16 LE | `pointerId` | Finger index. Observed values are **0 and 1**: the CFDL26 dash reports two-finger multi-touch. | [CODE] `EasyConnProber.kt:841`, `:830-831`; `AaVideoBridge.kt:50-53`; [HW] README.md:71 (pinch-to-zoom from the dash is a shipped feature) |
| 8 | 4 | u32 LE | `timestamp` | Dash-side timestamp. **Unit and epoch unknown**, and the code does not read it. | [INF] `docs/05-DEBUG-KNOWLEDGE.md:202`; `EasyConnProber.kt:829` |
| 12 | 6 | ? | (unknown) | "(rest unknown)". | [INF] `docs/05-DEBUG-KNOWLEDGE.md:202` |

**Documentation discrepancy (resolved in favor of the code).** `docs/05-DEBUG-KNOWLEDGE.md:202` still says
`y u32@4`. The shipping code reads `y` as **u16 @4** and `pointerId` as **u16 @6**
(`EasyConnProber.kt:829-831`, `:840-841`). With a single finger the two readings agree, because bytes 6–7
are 0. With the second finger (`pointerId = 1`) a u32 read would give `y + 65536`. Example: y = 200 on
pointer 1 → `65736`. Implement the code's layout. **[CODE]**

### 2.3 Action normalization

| Raw `action` (u16 @0) | Normalized | Downstream name |
| ---: | ---: | --- |
| 2 | 0 | DOWN |
| 1 | 1 | UP |
| 3 | 2 | MOVE |
| anything else | — | dropped, log `"[$tag] touch: unknown action=$rawAction x=$x y=$y"` |

Source: `EasyConnProber.kt:842-847` **[CODE]**.

### 2.4 Worked hex examples (synthetic)

Header: `cmdType=32 (20 00)`, `cmdLen=18 (12 00)`, `token=0 (00 00 00 00)`. Real dashes put their own
token value here, and we ignore it. The 6 unknown trailing bytes are zeroed in these synthetic frames.
Everything below was computed with a byte-exact script.

| Event | Full frame (26 bytes = 8 header + 18 body) |
| --- | --- |
| DOWN ptr 0 at (640,288), ts=123456 | `20 00 12 00 00 00 00 00` `02 00 80 02 20 01 00 00 40 E2 01 00 00 00 00 00 00 00` |
| MOVE ptr 0 at (700,300), ts=123472 | `20 00 12 00 00 00 00 00` `03 00 BC 02 2C 01 00 00 50 E2 01 00 00 00 00 00 00 00` |
| UP ptr 0 at (700,300), ts=123488 | `20 00 12 00 00 00 00 00` `01 00 BC 02 2C 01 00 00 60 E2 01 00 00 00 00 00 00 00` |
| DOWN ptr 1 at (1000,200), ts=123500 | `20 00 12 00 00 00 00 00` `02 00 E8 03 C8 00 01 00 6C E2 01 00 00 00 00 00 00 00` |

Decoder test vectors for iOS. Input: the body bytes. Expected output: `(rawAction, x, y, pointerId)`.
- `02 00 80 02 20 01 00 00 …` → `(2, 640, 288, 0)` → normalized DOWN.
- `03 00 BC 02 2C 01 00 00 …` → `(3, 700, 300, 0)` → MOVE.
- `01 00 BC 02 2C 01 00 00 …` → `(1, 700, 300, 0)` → UP.
- `02 00 E8 03 C8 00 01 00 …` → `(2, 1000, 200, 1)` → DOWN pointer 1.
- 7-byte body → reject ("too short"). A body of `09 00 …` → reject ("unknown action").

### 2.5 Related PXC facts

- **Control-plane SCREEN_TOUCH.** `CMD_SCREEN_TOUCH = 196672 (0x30040)` is a constant decoded from the SDK
  (`PxcFrame.kt:98`) and has **never been observed**. If it ever arrives on :10922, the profile's
  unknown-control handler logs `" *** SCREEN_TOUCH ***"` and acks `cmd+1` (`0x30041`) with an empty
  payload (`BikeProfile.kt:574-579`, reached from `PxcHandshake.kt:76-77`) **[CODE]**. iOS should do the
  same and log the payload hex for research **[PROP]**.
- **`touchMode byte @25`** in the dash's `REQ_RV_CONFIG_CAPTURE (16)` body is documented
  (`docs/01-REVERSE-ENGINEERING.md` §4) but **not parsed** by the Android code **[CODE]**. iOS should log it
  **[PROP]**.

### 2.6 Touch capability advertisement (per bike profile)

The phone's CLIENT_INFO reply (`0x10011`, built per profile) gets the key `"supportScreenTouch": true`
**appended** only when the profile's builder supports it **and**
`BikeProfileHolder.advertisesScreenTouch` is true:

```
advertisesScreenTouch = forceNonTouch ? false : (forceTouch ? true : activeProfile.supportsScreenTouch)
```

Source: `BikeProfile.kt:278-283`, **[CODE]**. `forceNonTouch` and `forceTouch` are the Setup toggles
"Disable touchscreen" and "Force touchscreen". They are mutually exclusive: setting one clears the other
(`AppSettings.kt:53-69`).

| Profile (name string) | `supportsScreenTouch` | Reply adds `supportScreenTouch` when advertised? | Default screen margins `[T,B,L,R]` px | Source |
| --- | --- | --- | --- | --- |
| `CFDL16 / legacy (BIKE A)` | false | **never** (base reply only) | 0,0,0,0 | `BikeProfile.kt:406-413` |
| `CFMoto 800NK (CRCP / sdk 0.9.23.x)` | false | never ("deliberately NO supportScreenTouch") | 0,0,0,0 | `BikeProfile.kt:460-468`, `:491-495` |
| `CFDL26 / MotoPlay Portrait (1000 MT-X)` | **false**: touch is locked by default on the bike, and AA is put in focus/knob mode | **yes** | 0,0,0,0 | `BikeProfile.kt:501-517`, `:552` |
| `CFDL26 / 800NK Advanced (touch, 720×712)` | **true** | yes | **22,0,0,0** (blanks the MotoPlay pull-down handle) | `BikeProfile.kt:591-598`, `:623` |
| `CFDL16 / MotoPlay Landscape (modelId 66660742)` | false | never | 0,0,0,0 | `BikeProfile.kt:632-638` |
| `CL‑C450 (544×512)` | false | never | 0,0,0,0 | `BikeProfile.kt:660-666` |
| `Morini SoftAP / Alltrhike (MLN)` | false | never | 0,0,0,0 | `BikeProfile.kt:703-714` |
| `CFDL26 / MotoPlay Landscape (800MT)` | **true** | yes | 0,0,0,0 | `BikeProfile.kt:751-763`, `:796` |

Facts about the bike's own CLIENT_INFO (CFDL26): `supportScreenTouch=true`, `supportHID=true`,
`supportMirrorOverlayTouch=true` (`docs/01-REVERSE-ENGINEERING.md` §7.0) **[HW]**.

Unknown: whether a dash **withholds** `cmdType 32` when the phone does not advertise touch. The 1000 MT-X
comment says "Dash touch events are still forwarded when the panel sends them" (`BikeProfile.kt:510-511`)
**[INF]**. For iOS **[PROP]**: advertise `"supportScreenTouch": true` on touch-capable profiles (800MT,
800NK Advanced), and when "Force touchscreen" is on. Log every touch frame regardless of the profile.

Unit-test vectors (`BikeProfileSelectTest.kt:33-37`):
`Cfdl26PortraitProfile.supportsScreenTouch == false`,
`Cfdl26LandscapeProfile.supportsScreenTouch == true`, `Nk800Profile.supportsScreenTouch == false`.

---

## 3. Coordinate spaces and transforms

### 3.1 Device size, capture size and canvas

| Space | Definition | Example | Source |
| --- | --- | --- | --- |
| **Device size** (requested) | `deviceWidth s16 @0`, `deviceHeight s16 @2` of the dash's `REQ_RV_CONFIG_CAPTURE (16)`. The phone reads both as `getShort() & 0xFFFF`. | 800×386 (CFDL16), 800×951 (1000 MT-X), 1280×576 (800MT) | `EasyConnProber.kt:733-735`; `docs/01-REVERSE-ENGINEERING.md` §4, §7.3 |
| **Capture / canvas** (negotiated) | `(w & 0xFFF0, h & 0xFFF0)`, i.e. rounded **down** to multiples of 16, for every profile. Returned in RLY 17 and stored as `negW × negH`. | 800×386→800×384; 800×951→800×944; 720×712→720×704; 1280×576 unchanged; 1024×464 unchanged | `BikeProfile.kt:105`; `EasyConnProber.kt:751-764` |
| Canvas default before any config capture | `negW = 800`, `negH = 384` | — | `EasyConnProber.kt:88-89` |
| **Touch coordinates** | Assumed to be in the **canvas** (`negW × negH`). The code passes the raw `x,y` straight to consumers that are sized to the canvas. | — | **[INF]** `docs/05-DEBUG-KNOWLEDGE.md:203-204`, `:216-220`; [CODE] `EasyConnProber.kt:830` |

Notes:
- The device/canvas difference is under 16 px and only at the right and bottom edges. On the
  hardware-verified touch dash (800MT, 1280×576) the two are identical, so the assumption could not be
  falsified there **[INF]**.
- Clamp incoming touches to `[0, negW-1] × [0, negH-1]` **[PROP]**.
- If a dash ever reports in device or panel space, add a pre-scale `canvas = raw × (negW/deviceW)` and so
  on. The verification recipe is to tap the corners: the top-left should map near (0,0) and the
  bottom-right near (negW-1, negH-1) (`docs/05-DEBUG-KNOWLEDGE.md:216-220`) **[INF]**.

### 3.2 Built-in map path: 1:1, no transform

When the built-in map (the "GPX/Map Presentation") is the video source, it is rendered on a private
`VirtualDisplay` of exactly `negW × negH` (`EasyConnProber.kt:263-266`, `:793-795`;
`VideoPipeline.kt:150-159`, where a live MediaProjection mirror takes precedence over the map, and
`:523-534`). Dash
coordinates are therefore **view pixels**. They are injected as-is (`GpxSession.kt:114-134`) **[CODE]**.
This is the model for iOS: render the dash UI at canvas resolution, and a dash touch equals a UI point (or
`point = px / renderScale`) **[PROP]**.

**Density → dp scale on the dash** (needed to translate the Android layout sizes in §6.3):
`densityDpi = clamp(round(160 × negW / 900.0), 160, 640)` and `scale = densityDpi / 160`
(`VideoPipeline.kt:532-533`, `TARGET_DASH_WIDTH_DP = 900.0` at `:783`) **[CODE]**. The Morini/Yunmo path
overrides this with 187 dpi (`VideoPipeline.kt:64-68`).

| `negW` | densityDpi | px per dp |
| ---: | ---: | ---: |
| 544, 720, 800 | 160 | 1.0 |
| 1024 | 182 | 1.1375 |
| 1280 | 228 | 1.425 |

### 3.3 Android Auto path (reference only): letterbox inverse

`AaVideoBridge.touchSink` (installed by `aa/AaReceiver.kt:225-234`) calls
`VideoPipeline.mapBikeTouchToSource` → `AaCompositor.mapCanvasToSource` (`AaCompositor.kt:281-289`).
Touches that land in a black bar are **dropped** (null) **[CODE]**.

Viewport (`AaCompositor.computeViewport`, `AaCompositor.kt:298-330`) **[CODE]**:

```
mT = clamp(ScreenMargins.top, 0, canvasH);  mB = clamp(ScreenMargins.bottom, 0, canvasH - mT)
mL = clamp(ScreenMargins.left, 0, canvasW); mR = clamp(ScreenMargins.right, 0, canvasW - mL)
areaW = max(canvasW - mL - mR, 1); areaH = max(canvasH - mT - mB, 1)
srcAspect = srcW/srcH (float); areaAspect = areaW/areaH (float)
STRETCH: vpW = areaW; vpH = areaH
FIT    : if srcAspect < areaAspect { vpH = areaH; vpW = round(areaH*srcAspect) } else { vpW = areaW; vpH = round(areaW/srcAspect) }
FILL   : if srcAspect < areaAspect { vpW = areaW; vpH = round(areaW/srcAspect) } else { vpH = areaH; vpW = round(areaH*srcAspect) }
vpX = mL + (areaW - vpW)/2      // integer division, truncates toward zero (can be negative for FILL)
vpY = mT + (areaH - vpH)/2
```

Inverse map:

```
rx = cx - vpX; ry = cy - vpY
if rx < 0 || ry < 0 || rx >= vpW || ry >= vpH → null (drop)
sx = clamp(rx*srcW/vpW, 0, srcW-1); sy = clamp(ry*srcH/vpH, 0, srcH-1)   // 64-bit multiply, integer divide
```

`srcW × srcH` is the **usable** AA area, i.e. the coded size minus the match-aspect margins
(`VideoPipeline.kt:296-302`). The default `ScreenFit` is **FILL** (`VideoPrefs.kt:146-149`). The code
comments note that a centre-offset correction for match-aspect panels "broke NK Adv touch" and was
reverted (`AaCompositor.kt:277-280`) **[CODE]**.

Worked vectors (computed with the exact integer semantics above):

| Case | Viewport `(vpX,vpY,vpW,vpH)` | Touch → source |
| --- | --- | --- |
| 800MT, canvas 1280×576, src 800×480, FILL | (0, −96, 1280, 768) | (640,288)→(400,240); (0,0)→(0,60); (1279,575)→(799,419) |
| same, FIT | (160, 0, 960, 576) — matches `docs/05-DEBUG-KNOWLEDGE.md:206-207` | (100,300)→**drop**; (160,0)→(0,0); (1119,575)→(799,479) |
| same, STRETCH | (0, 0, 1280, 576) | (640,288)→(400,240); (1279,575)→(799,479) |
| 800NK Adv, canvas 720×704, src 720×712, FILL, margins T=22 | (0, 7, 720, 712) | (360,352)→(360,345); (0,0)→**drop**; (0,10)→(0,3) |
| 1000 MT-X, canvas 800×944, src 720×1280, FIT | (134, 0, 531, 944) — matches `docs/02-CURRENT-APP.md:115` | (400,472)→(360,640); (100,10)→**drop** |

**iOS relevance**: none for the own-UI path. The same math is needed only if iOS ever letterboxes a
different-sized source (for example a ReplayKit capture) into the canvas **and** wants to interpret
touches over it. Mirror mode has no touch-back on Android either (§6.1) **[PROP]**.

### 3.4 Phone preview inverse aspect-fit ("Dash view")

`HudViewActivity.mapToSource` (`HudViewActivity.kt:330-355`) maps a phone-view touch `(vx,vy)` in a view
of `vw × vh` showing a source of `sw × sh` (aspect-fit, centred). This mapping is **[CODE]**:

```
srcAspect = sw/sh; viewAspect = vw/vh
if srcAspect < viewAspect { rectH = vh; rectW = round(vh*srcAspect) } else { rectW = vw; rectH = round(vw/srcAspect) }
rectX = (vw-rectW)/2; rectY = (vh-rectH)/2
rx = vx-rectX; ry = vy-rectY; outside → null
sx = clamp(Int(rx*sw/rectW), 0, sw-1); sy = clamp(Int(ry*sh/rectH), 0, sh-1)
```

Multi-touch forwarding from the preview (`HudViewActivity.kt:297-328`) **[CODE]**:
- `ACTION_DOWN` and `ACTION_POINTER_DOWN` send DOWN for `actionIndex`.
- `ACTION_MOVE` sends MOVE for **every** pointer.
- `ACTION_UP` and `ACTION_POINTER_UP` send UP for `actionIndex`.
- `ACTION_CANCEL` sends UP for every pointer.

The pointer id is `getPointerId(index)`.

For iOS, use this to build an on-phone "Dash view". Map phone touches to canvas coordinates and inject
them into the **same** touch pipeline as dash touches, after the ghost filter. This gives one code path
for both **[PROP]**.

### 3.5 Screen margins

`ScreenMargins` holds per-edge black borders in **dash pixels**, `MAX = 200`, clamped to `[0,200]`
(`ScreenMargins.kt:17-19`, `:53-57`). Until the rider customises them, the active profile's
`defaultMargins` apply (`ScreenMargins.kt:29-32`). On Android the margins affect only the AA and mirror
compositor. The built-in map ignores them **[CODE]** (all uses are in `AaCompositor.kt:301-304`).

For iOS **[PROP]**: apply the margins as an inset of the dash UI's layout and of its hit-testing. Treat
touches inside the margins as "chrome" and ignore them. This is the 800NK Advanced pull-down area: 22 px
at the top.

---

## 4. Ghost-touch filter and contact re-acquisition ("stitch")

Motivation, from field data: the **800NK** digitizer can report one finger as two contacts during a press
or drag. The touch-capable 800NK is presumably the 800NK Advanced (720×712), since the US CRCP 800NK is
non-touch **[INF]**. It also **drops a finger mid-drag and re-acquires it within about 0–14 ms and under 150 px**.
Committing that UP would turn a drag into a string of taps (`EasyConnProber.kt:52-66`) **[HW]**. The
phenomenon was observed in the field; the thresholds are tuned constants in shipping code **[CODE]**.

### 4.1 Constants (`EasyConnProber.kt:52-66`) [CODE]

| Name | Value | Meaning |
| --- | ---: | --- |
| `GHOST_MERGE_PX` | **48 px** | A contact within this distance (per axis) of **another** tracked pointer is the same finger ghosting. |
| `POINTER_STALE_MS` | **300 ms** | A pointer not updated for this long is evicted, which covers a lost UP. |
| `MAX_POINTERS` | **2** | Android Auto only needs two fingers (for pinch); extra contacts are noise. |
| `STITCH_MS` | **80 ms** | Every UP is held for this long in case the same finger comes back. |
| `STITCH_PX` | **150 px** | A re-acquired contact must land within this distance (per axis) of where the finger left. |

`near(ax, ay, bx, by, tol = 48) = |ax-bx| <= tol && |ay-by| <= tol`. This is a **Chebyshev / axis-aligned
square** test and is **inclusive** (`EasyConnProber.kt:69-70`) **[CODE]**.

### 4.2 State

| State | Type | Notes |
| --- | --- | --- |
| `pointers` | insertion-ordered map `dashId → (x, y, lastSeenMs)` | Updating an existing key keeps its position (Java `LinkedHashMap`). `EasyConnProber.kt:96` |
| `pendingUpId` | Int, `-1` = none | Plus `pendingUpX`, `pendingUpY`, `pendingUpAt`, and a cancellable timer (`:101-105`). |
| `aaIdOf` | map `dashId → downstreamId` | Used when a dropped contact came back under a **new** dash id (`:109`). |
| executor | a single-thread scheduler named `"ec-touch-stitch"` | Created on `start()`; shut down on `stop()`, which also clears all state (`:226-228`, `:308-309`). |

All of `handleTouch`, `emit` and the timer callback run under one lock (`synchronized(pointers)`).

### 4.3 Algorithm (exact reference behavior)

```
on frame(rawAction, x, y, id):                           // EasyConnProber.kt:835-889
  action = {2:DOWN, 1:UP, 3:MOVE}[rawAction] else { log unknown; return }
  now = monotonicMs()
  // (1) Stale eviction — SILENT (no UP is sent downstream)
  remove every pointers[k] where k != id && now - lastSeen(k) > 300
  switch action:
    UP:
      if pointers[id] == nil { return }                  // UP of a filtered ghost
      holdUp(id, x, y, now); return
    DOWN:
      if pendingUpId >= 0 && now - pendingUpAt <= 80 && near(pendingUpX, pendingUpY, x, y, 150):
        orig = aaIdOf[pendingUpId] ?? pendingUpId
        cancelPendingUp()                                // the held UP is discarded
        if id != orig { aaIdOf[id] = orig }
        log every 10th stitch: "touch: contact came back ${now - pendingUpAt}ms later, keeping the drag alive instead of ending it (#n)"
        emit(MOVE, id, x, y, now); return                // the re-acquired DOWN becomes a MOVE
      commitPendingUp()                                  // a held UP of another touch is emitted NOW
      if isGhost(id, x, y) { log every 20th "touch: ignoring ghost contact at ($x,$y) near an existing finger"; return }
    MOVE:
      if isGhost(id, x, y) { return }                    // silently dropped
  emit(action, id, x, y, now)

isGhost(id, x, y) = pointers.any { (k, p) in k != id && near(p.x, p.y, x, y, 48) }   // :892-893

emit(action, dashId, x, y, now):                         // :898-931
  pointers[dashId] = (x, y, now)
  if pointers.count > 2:                                 // keep the current pointer + the most recently seen other
     keep = distinct([dashId] + pointers.keys sorted by lastSeen DESC).prefix(2)
     drop all others (SILENT — no UP downstream)
  outId = aaIdOf[dashId] ?? dashId
  deliver(action, outId, x, y)                           // see 4.4
  if action == UP { pointers.remove(dashId); aaIdOf.remove(dashId) }

holdUp(id, x, y, now):                                   // :934-949
  cancelPendingUp()                                      // NB: a previously held UP is DISCARDED
  pendingUp = (id, x, y, at: now)
  schedule after 80 ms: lock { if pendingUpId == id { pendingUpId = -1; emit(UP, id, x, y, fireTime) } }
  if scheduling throws: emit(UP, id, x, y, now); pendingUpId = -1

commitPendingUp():                                       // :952-958
  if pendingUpId < 0 return
  (id, x, y) = pending; cancelPendingUp(); emit(UP, id, x, y, now())

cancelPendingUp(): cancel timer (no interrupt); pendingUpId = -1          // :960-964
```

### 4.4 Output contract (delivery)

`deliver(action, id, x, y)` runs in priority order (`EasyConnProber.kt:922-929`) **[CODE]**:
1. If `AaVideoBridge.touchSink` is set (an Android Auto session is live), call
   `touchSink(action, outId, x, y)`. It letterbox-maps (§3.3) and then calls `AaInput.sendTouch` (§5).
2. Otherwise, if `GpxSession.active && GpxSession.dispatchTouch(action, x, y)` (the built-in map has a
   touch target), log `"[$tag] touch → GPX viewer"` for non-MOVE events (§6.1). **The pointer id is not
   passed.**
3. Otherwise drop, with log `"[$tag] touch dropped (no AA / GPX sink)"` for non-MOVE events. This is the
   case in **mirror mode** **[CODE]**.

Log formats (`:910-920`): non-MOVE events log
`"[$tag] TOUCH DOWN|UP bike=($x,$y) ptr=$dashId of ${pointers.size} canvas=${negW}x$negH"`. MOVE logs are
throttled to one per **400 ms** per socket tag (`LogBus.logThrottled`, `minIntervalMs = 400L`).

Timing consequences:
- **Every UP reaches consumers ≥ 80 ms after the dash sent it**, unless a DOWN commits it earlier.
- A DOWN that comes more than 80 ms after the UP, or more than 150 px away, produces a normal
  UP-then-DOWN pair.

### 4.5 Test vectors

**(a) `GhostTouchTest.kt`, copied in full** (`near` with the default tol = 48 unless noted):

| Test | Call | Expected |
| --- | --- | --- |
| `near_samePoint` | `near(100, 200, 100, 200)` | `true` |
| `near_withinDefaultTolerance` | `near(100, 200, 130, 230)` | `true` |
| | `near(100, 200, 52, 200)` | `true` (dx = 48, inclusive) |
| `near_outsideDefaultTolerance` | `near(100, 200, 149, 200)` | `false` (dx = 49) |
| | `near(100, 200, 100, 249)` | `false` (dy = 49) |
| `near_customTolerance` | `near(0, 0, 150, 150, tol = 150)` | `true` |
| | `near(0, 0, 151, 0, tol = 150)` | `false` |

**(b) Scenario traces.** These were derived by a byte-faithful port of `handleTouch`/`emit`/`holdUp`
(`EasyConnProber.kt:835-964`) running on a simulated clock. Input tuples are
`t(ms) raw(2=DOWN,3=MOVE,1=UP) (x,y) dashId`. Output tuples are `t action outId (x,y)`. Use these as
golden vectors for an iOS port in "Android-compat" mode **[CODE-derived]**.

| # | Scenario | Input | Expected output (Android reference) | Dropped / notes |
| --- | --- | --- | --- | --- |
| S1 | tap | `0 2 (100,100) 0`; `60 1 (100,100) 0` | `0 DOWN 0 (100,100)`; `140 UP 0 (100,100)` | UP delayed 80 ms |
| S2 | drag, contact re-acquired with the same id | `0 2 (100,100) 0`; `16 3 (140,100) 0`; `32 1 (160,100) 0`; `40 2 (175,100) 0`; `56 3 (200,100) 0`; `200 1 (300,100) 0` | `0 DOWN 0 (100,100)`; `16 MOVE 0 (140,100)`; `40 MOVE 0 (175,100)`; `56 MOVE 0 (200,100)`; `280 UP 0 (300,100)` | The UP at 32 plus the DOWN at 40 (8 ms later, dx = 15) are stitched into a MOVE |
| S3 | re-acquired with a **new** id | `0 2 (100,100) 0`; `30 3 (118,100) 0`; `34 1 (120,100) 0`; `40 2 (125,100) 1`; `56 3 (130,100) 1`; `72 3 (150,100) 1`; `88 3 (170,100) 1`; `400 3 (200,100) 1`; `420 1 (210,100) 1` | `0 DOWN 0`; `30 MOVE 0 (118,100)`; `40 MOVE 0 (125,100)`; `88 MOVE 0 (170,100)`; `400 MOVE 0 (200,100)`; `500 UP 0 (210,100)` | The MOVEs at 56 and 72 are dropped as "ghosts" of the stale id-0 entry (the self-ghosting quirk, §4.6 Q3). Id 0 is evicted at 400. |
| S4 | ghost second contact | `0 2 (300,200) 0`; `5 2 (320,210) 1`; `20 3 (325,212) 1`; `40 1 (325,212) 1`; `60 1 (300,200) 0` | `0 DOWN 0 (300,200)`; `140 UP 0 (300,200)` | DOWN 1 is a ghost, MOVE 1 is a ghost, UP 1 is untracked |
| S5 | real two-finger pinch | `0 2 (200,200) 0`; `10 2 (400,200) 1`; `30 3 (190,200) 0`; `31 3 (410,200) 1`; `60 3 (180,200) 0`; `61 3 (420,200) 1`; `100 1 (180,200) 0`; `140 1 (420,200) 1` | `0 DOWN 0`; `10 DOWN 1`; `30 MOVE 0 (190,200)`; `31 MOVE 1 (410,200)`; `60 MOVE 0 (180,200)`; `61 MOVE 1 (420,200)`; `220 UP 1 (420,200)` | **No UP for pointer 0**: its held UP is discarded when pointer 1's UP is held (§4.6 Q1) |
| S6 | re-acquire after more than 80 ms = two taps | `0 2 (100,100) 0`; `50 1 (100,100) 0`; `190 2 (105,100) 0`; `240 1 (105,100) 0` | `0 DOWN`; `130 UP`; `190 DOWN 0 (105,100)`; `320 UP` | — |
| S7 | re-acquire more than 150 px away | `0 2 (100,100) 0`; `50 1 (100,100) 0`; `70 2 (400,100) 0`; `120 1 (400,100) 0` | `0 DOWN`; `70 UP 0 (100,100)`; `70 DOWN 0 (400,100)`; `200 UP` | The held UP is committed at the next DOWN |
| S8 | two fingers lift within 80 ms | `0 2 (200,200) 0`; `5 2 (400,200) 1`; `100 1 (200,200) 0`; `130 1 (400,200) 1` | `0 DOWN 0`; `5 DOWN 1`; `210 UP 1 (400,200)` | Pointer 0's UP is lost (Q1) |
| S9 | unknown action | `0 9 (1,1) 0` | — | dropped (unknown) |

Expected outputs with the recommended iOS fixes F1–F3 (§4.6) differ only in S3, S5 and S8:
- **S3 + F3**: `0 DOWN`, `30 MOVE (118,100)`, `40 MOVE (125,100)`, `56 MOVE (130,100)`,
  `72 MOVE (150,100)`, `88 MOVE (170,100)`, `400 MOVE (200,100)`, `500 UP (210,100)`. All have outId 0.
- **S5 + F1**: the same as the reference, plus `140 UP 0 (180,200)` emitted just before pointer 1's UP is
  held.
- **S8 + F1**: `0 DOWN 0`, `5 DOWN 1`, `130 UP 0 (200,200)`, `210 UP 1 (400,200)`.

### 4.6 Quirks in the Android filter and recommended iOS fixes

| # | Quirk (shipping Android behavior) | Effect | iOS recommendation |
| --- | --- | --- | --- |
| Q1 | `holdUp` calls `cancelPendingUp()` and **discards** a held UP of a *different* pointer (`EasyConnProber.kt:934-936`) | When both fingers lift within 80 ms, typically at the end of a pinch, the first finger never gets an UP. `AaInput` then keeps a stuck pointer, and the next touch becomes `POINTER_DOWN`. | **F1 [PROP]**: in `holdUp`, if `pendingUpId >= 0 && pendingUpId != id`, run `commitPendingUp()` first. Better still, keep **one pending UP per pointer**. |
| Q2 | Stale eviction (`:853`) and the `MAX_POINTERS` trim (`:901-906`) remove pointers **without** sending an UP downstream | A stuck pointer remains in downstream multi-touch state | **F2 [PROP]**: emit `UP`/`CANCEL` downstream for every evicted or trimmed pointer that had been delivered. |
| Q3 | On a stitch with a **new** dash id, the old id's entry stays in `pointers` | The re-acquired finger's MOVEs within 48 px of its own old entry are dropped as ghosts for up to 300 ms (S3) | **F3 [PROP]**: on a stitch, remove the old dash id from `pointers` (transfer the identity). |
| Q4 | Every UP is held for 80 ms, and a DOWN within 80 ms and 150 px is merged into the previous touch | A very fast double-tap (gap under 80 ms) becomes one long touch. Taps are acknowledged 80 ms late. | Keep this behavior. Measure double-tap windows on the **filtered** stream (§6.2). |
| Q5 | A stationary finger that sends no MOVEs is evicted after 300 ms whenever **another** finger sends events | During a pinch with one still finger, its UP is later dropped as "untracked" | Unknown whether dashes repeat MOVEs for still fingers [INF]. With F2, the eviction is at least delivered. Log it. |
| Q6 | A ghost DOWN is dropped, but if that contact later MOVEs more than 48 px away from the other pointer, its MOVE is accepted and it becomes a pointer (AA promotes it to `POINTER_DOWN`) | This is how two fingers that start close together can still pinch | Keep this behavior (intended). |

Ship an `androidCompat` switch so that the vectors in §4.5(b) can be asserted exactly, with F1–F3 on by
default **[PROP]**.

### 4.7 Thread and lifecycle facts

- The scheduler is created in `start()` and shut down in `stop()`. `stop()` also clears `pointers`,
  `aaIdOf` and the pending UP (`EasyConnProber.kt:226-228`, `:308-309`) **[CODE]**.
- If scheduling fails (executor gone), the UP is emitted immediately (`:946-948`) **[CODE]**.
- iOS **[PROP]**: run the filter on a serial queue or an actor. Use `DispatchWorkItem` (cancellable) for the
  80 ms hold, with an injectable clock and scheduler so that §4.5 runs in unit tests under virtual time.

---

## 5. Multi-touch pointer semantics (`AaInput`), the reference model

Even though iOS will not send AAP, `AaInput.sendTouch` (`aa/AaInput.kt:123-174`) is the canonical
**touch-set state machine** fed by the filtered stream. Reuse it for the iOS dash UI's multi-touch
recognizer **[PROP]**.

| Incoming (normalized) | Condition | Resulting action | Pointer set after |
| --- | --- | --- | --- |
| DOWN id | set was empty | `TOUCH_ACTION_DOWN (0)` | +id |
| DOWN id | set non-empty | `TOUCH_ACTION_POINTER_DOWN (5)` | +id |
| MOVE id | id tracked | `TOUCH_ACTION_MOVE (2)` | id position updated |
| MOVE id | id **not** tracked (lost DOWN) | **promote**: `DOWN` if it is now the only pointer, else `POINTER_DOWN` | +id |
| UP id | id not tracked | **ignored** | unchanged |
| UP id | it is the only pointer | `TOUCH_ACTION_UP (1)` | −id **after** sending |
| UP id | other pointers remain | `TOUCH_ACTION_POINTER_UP (6)` | −id after sending |

- Every event carries **all** currently-down pointers in insertion order (id, x, y). `actionIndex` is the
  index of the changed pointer in that order (`AaInput.kt:152-161`).
- Timestamps are a monotonic microsecond clock: `elapsedRealtimeNanos/1000` (`:162-165`).
- AAP enum values for reference: `DOWN=0, UP=1, MOVE=2, CANCEL=3, OUTSIDE=4, POINTER_DOWN=5, POINTER_UP=6`
  (`aa/proto/Input.java:1830-1892`).
- The ids are the downstream ids from §4 (`outId`, i.e. the dash id or the stitched original). In
  practice they are 0/1 (`AaVideoBridge.kt:50-53`) **[CODE]**.
- AA keycodes, for reference, since the same values are reused as the "keycodes" of the built-in map focus
  engine (§6.6) (`AaInput.kt:33-57`) **[CODE]**:
  `KEY_UP=19, KEY_DOWN=20, KEY_LEFT=21, KEY_RIGHT=22, KEY_ENTER=23 (DPAD_CENTER), KEY_BACK=4, KEY_HOME=3,
  KEY_ASSISTANT=84 (KEYCODE_SEARCH), KEY_SCROLL_WHEEL=65536` (rotary; advertised, never sent as a key).
  On AA, a "knob" click is a `RelativeEvent` with keycode 65536 and delta ±1 (`AaInput.kt:85-102`).

---

## 6. How dash touches drive the built-in dash map UI (the closest analogue to iOS)

### 6.1 Dispatch into the view tree (`GpxSession.dispatchTouch`)

- `GpxDashUi.bind()` registers the Presentation's root view as the touch target
  (`GpxDashUi.kt:1919`, `GpxSession.kt:106-112`). `release()` and pipeline stop clear it
  (`GpxDashUi.kt:2797`, `VideoPipeline.kt:752`) **[CODE]**.
- `dispatchTouch(action, x, y)` (`GpxSession.kt:114-134`) **[CODE]** does the following:
  - Maps `0/1/2` to `MotionEvent.ACTION_DOWN/UP/MOVE`. Anything else returns `false`.
  - **Posts** to the target's UI thread. At delivery time it builds
    `MotionEvent.obtain(downTime = eventTime = uptimeMillis(), action, x.toFloat(), y.toFloat(), metaState 0)`,
    so **each event gets a fresh `downTime`**.
  - Calls `root.dispatchTouchEvent(ev)` and recycles the event.
  - Returns `true` whenever a target exists, even before the post runs.
- Consequences **[CODE]/[INF]**:
  - **Single-pointer only.** The pointer id is dropped, and there is no `ACTION_POINTER_DOWN`/`_UP`.
  - A second finger's DOWN arrives as a fresh `ACTION_DOWN`. That resets Android's touch state and starts
    a new gesture at the second finger. Afterwards, MOVEs from both fingers interleave as one pointer that
    jumps between positions.
  - **Pinch-to-zoom from the dash does not work on the built-in map.** Only the zoom FABs and the map's
    double-tap work. Pinch works only in the phone preview (MapLibre).
  - The iOS port should implement real multi-touch (§5) **[PROP]**.
- **Mirror mode** has no touch sink, so dash touches are dropped (§4.4) **[CODE]**.

### 6.2 Gesture recognition and thresholds

The app sets **no custom thresholds** for dash touches. Recognition comes from Android `View` click
handling and from the osmdroid `MapView` (osmdroid 6.1.20, `gradle/libs.versions.toml:16`). The bike
Presentation always uses osmdroid because MapLibre GL produced encode artifacts
(`DashMapEngine.kt:13-25`, `:49-54`) **[CODE]**. Platform defaults involved **[PLAT]** (AOSP
`ViewConfiguration`, verify):

| Parameter | Android default | Notes |
| --- | --- | --- |
| Touch slop | 8 dp | Movement before a press becomes a drag. In dash px: `8 × scale` (§3.2), e.g. 8 px on 800-wide and 11.4 px on 1280-wide. |
| Tap timeout | 100 ms | Pressed-state feedback delay. |
| Long-press timeout | 400 ms (Android 12+; 500 ms before) | Used by osmdroid's GestureDetector for long-press. |
| Double-tap timeout | 300 ms (min 40 ms) | Measured from the first UP to the second DOWN. |
| Double-tap slop | 100 dp | Maximum distance between the two DOWNs. |
| Fling velocity | min 50 dp/s, max 8000 dp/s | osmdroid kinetic pan. |

Behavior on the **map surface** (`DashMapController.kt`):
- `setMultiTouchControls(true)` (`:48`); zoom range **5.0–20.0**, initial zoom 16.0 (`:51-53`) **[CODE]**.
- One-finger drag pans **[PLAT]**.
- **Long-press** returns the `GeoPoint` from `MapEventsOverlay.longPressHelper` → drop-pin flow (§6.5)
  (`:114-123`) **[CODE]**.
- Single tap on the map does nothing: `singleTapConfirmedHelper` returns `false` (`:117`) **[CODE]**.
- **Double-tap** zooms in one level around the tap (osmdroid default) **[PLAT]**.
- Fling performs a kinetic pan **[PLAT]**.
- osmdroid's default on-map zoom buttons (`CustomZoomButtonsController`, which shows and fades after a
  touch) are not disabled by the app **[PLAT]/[INF]**.

**Timing interplay with the filter**: an UP is delivered 80 ms late, and a second DOWN within 80 ms and
150 px of the raw UP is merged into the first touch. Measured on **raw** dash timing, a double-tap
therefore registers only when the gap between the first UP and the second DOWN is **in (80, 380] ms**,
i.e. 80 ms hold plus 300 ms double-tap timeout **[INF]** (derived).

Behavior on **controls** (Buttons, ImageButtons, clickable TextViews and rows) **[PLAT]**:
- The target is chosen at DOWN by hit-testing.
- A click fires at UP if the finger stayed within the view bounds expanded by the touch slop.
- Touches on a control never reach the map underneath.

Recommended iOS recognizer for the dash UI **[PROP]**. It works in canvas px with `s = scale` from §3.2.

| Gesture | Rule |
| --- | --- |
| Tap (control) | DOWN on a control, then UP within the control rect expanded by `8·s`, without becoming a pan or long-press. Fire on UP. |
| Tap (map) | No action, to match Android. Optionally use it to dismiss sheets. |
| Long-press (map) | One pointer held ≥ **450 ms** (Android 400/500) with movement ≤ `8·s`. Drop-pin flow. |
| Double-tap (map) | Second DOWN within **300 ms** of the *filtered* UP, within `100·s` of the first DOWN. Zoom +1 at that point. |
| Pan (map) | Movement > `8·s` with one pointer. Start free-pan (follow off, auto-recenter 12 s; see §6.4). |
| Pinch (map, iOS only) | Two pointers: `zoomDelta = log2(dist/dist0)`, focal point = midpoint. Start free-pan as for Pan. |
| Fling | Optional. Velocity ≥ `50·s` px/s. |

### 6.3 Hit-target catalogue (bike Presentation, landscape `layout-land/presentation_gpx.xml`)

`layout-land` is used when the canvas is wider than tall (Android resource qualifier) **[PLAT]**. Sizes
below are in **dp**; multiply by `scale` (§3.2) for dash px. "proj" means changes that `adaptChromeLayout`
makes when `projected = true` (`GpxDashUi.kt:2483-2771`).

| Element (id) | Geometry | Action on tap | Source |
| --- | --- | --- | --- |
| Map (`gpx_map_host`) | Full canvas, beneath everything | Pan / long-press → pin / double-tap → zoom (§6.2) | `DashMapController.kt` |
| **FAB column** (`gpx_quick_bar`) | `top\|end`; proj: topMargin = 8 dp + insetT, marginEnd = **6 dp** + insetR. Vertical stack of **46×46 dp** circles with 6 dp gaps (11 dp padding). | — | layout-land `:704-792`; `GpxDashUi.kt:2614-2625` |
| ↳ Recenter (`gpx_btn_recenter`, `ic_fab_gps`) | 1st | Follow = on; cancel the pending auto-recenter; camera follows at `followZoom(speed)` and heading per north mode. Status "Centered on GPS", or "No GPS yet — wait for a fix" | `GpxDashUi.kt:1245-1265` |
| ↳ Zoom in (`gpx_btn_zoom_in`, +) | 2nd | `bumpFreePan()`; `speedZoom = false`; `zoomBy(+1.0)` clamped to [5,20] | `GpxDashUi.kt:1292-1296`; `DashMapController.kt:374-377` |
| ↳ Zoom out (`gpx_btn_zoom_out`, −) | 3rd | Same, with `zoomBy(-1.0)` | `GpxDashUi.kt:1297-1301` |
| ↳ Compass / north (`gpx_btn_north`) | 4th; the needle rotates by `-mapBearing` when heading-up | Toggle heading-up / north-up | `GpxDashUi.kt:1308-1330` |
| ↳ Menu (`gpx_open_menu`) | 5th | `showMenu()` | `GpxDashUi.kt:1126`, `:563-571` |
| ↳ Overview (`gpx_btn_overview`), Mute (`gpx_btn_mute`) | **gone** in the layout (kept for handlers) | Overview: free-pan, north-up, fit the remaining route. Mute: toggle voice. | layout-land `:768-791`; `GpxDashUi.kt:1266-1291`, `:1302-1307` |
| **Search pill** (`gpx_search_pill`) | `top\|start`, height **48 dp**, marginStart 12 dp, marginTop 8 dp (+insets); **visible only when not navigating** | `showSearch()` (full-screen search sheet) | layout-land `:14-90`; `GpxDashUi.kt:1127`, `:442-465` |
| ↳ Back arrow (`gpx_pill_close`, 44×44 dp) | Inside the pill | Hidden on the bike (phone only) | `GpxDashUi.kt:1231-1237` |
| ↳ "Circuit" (`gpx_pill_circuit`) | 36 dp tall, 8 dp horizontal padding | `startCircuit()` | `GpxDashUi.kt:1796` |
| ↳ "Lap" (`gpx_pill_lap`) | 36 dp tall | Toggle the lap timer | `GpxDashUi.kt:1824-1846` |
| ↳ Hub pill | Hidden on the bike | — | `GpxDashUi.kt:1235` |
| **End** (`gpx_end_bar`) | In the bottom-left metrics card, shown while navigating; minHeight **48 dp**, 22 dp horizontal padding, 17 sp | `endRouteNow()`: cancel the preview, or finish to free ride ("Navigation finished") | layout-land `:392-406`; `GpxDashUi.kt:1484-1501` |
| Speed gauge / limit (`gpx_speed_chip`) | `bottom\|end`, gauge 88 dp (84 dp proj), limit sign 56 dp | Not interactive | `GpxDashUi.kt:2626-2657` |
| **Preview card** (`gpx_preview_card`) | `bottom\|start`, marginEnd 96 dp | — | layout-land `:474-630` |
| ↳ **Go** (`gpx_preview_go`) | **44 dp** tall, min **110 dp** wide | `startNavigationTo(place)` | `GpxDashUi.kt:1376-1379` |
| ↳ Route chips (`gpx_preview_alts` children) | Dynamic TextViews, padding 28/14 **px** | `selectRoute(i)` | `GpxDashUi.kt:738-760` |
| ↳ Actions row (40 dp tall): "★ Save", "Home"*, "＋ Marker"*, "Circuit", "Cancel"/"Done" | *pin mode only | Save favourite / set home / add marker / circuit / cancel | `GpxDashUi.kt:1380-1411`, `:417-441` |
| **Arrive card** | "Park here" and "Find parking" (44 dp, min 120 dp), "Done" (44 dp) | Mark parking / search parking / dismiss | layout-land `:632-700`; `GpxDashUi.kt:1412-1439` |
| **Dimmer** (`gpx_dimmer`) | Full screen, `#66000000`, clickable (shown with the menu) | `hideSheets()`. Blocks the map. | layout-land `:794-802`; `GpxDashUi.kt:1333` |
| **Menu panel** (`gpx_menu_panel`) | `end`, **280 dp** wide, full height; rows with minHeight **48 dp** | End navigation · Park here · Go home · Set home here · Recenter/Recalc · Record ride · Circuit · Follow · Heading/North up · Voice · Zoom − / + · Close | layout-land `:911-1070`; handlers `GpxDashUi.kt:1442-1593` |
| **Search panel** | **Full screen**, so it blocks the map. Header 64 dp: back 44×44 dp, input 48 dp (not focusable on the bike), go 40×40 dp. POI chips (padding 36/18 px). Result rows (padding 48/36 px) with "★ Save" / "＋ Marker" / "Delete" chips. | Search, POI, preview place | layout-land `:804-909`; `GpxDashUi.kt:572-609`, `:863-980`, `:1105-1124` |

Portrait differences (`layout/presentation_gpx.xml`): the FAB column is `end|center_vertical` with
marginEnd 8 dp (`:700-705`), the End button is 40 dp tall (`:412-416`), and the HUD becomes full-width
top and bottom bars (`GpxDashUi.kt:2658-2766`) **[CODE]**.

Note: several dynamic rows use **raw px** paddings (`setPadding(48, 36, …)`), so they do not scale with
density **[CODE]**.

### 6.4 Camera behavior driven by input

- `bumpFreePan()` sets `follow = false` and schedules an **auto-recenter after 12 000 ms**. The
  auto-recenter sets `follow = true` again (`GpxDashUi.kt:610-625`) **[CODE]**.
- Only the zoom buttons and the Overview action call `bumpFreePan()`. **A map drag or pan does NOT turn
  follow off**: with follow on, the next GPS fix re-centres the camera **[CODE]** (GPS updates use 800 ms
  / 1.5 m, `GpxDashUi.kt:2418-2420`; follow at `:2389-2398`). iOS should treat pan, pinch and double-tap
  as `bumpFreePan()` **[PROP]**.
- After a manual zoom, `speedZoom = false`, so the follow camera uses a **fixed zoom of 17.2** on the bike
  (16.0 on the phone) until navigation restarts (`GpxDashUi.kt:2390`). Otherwise it uses
  `followZoom = min(zoomForSpeedKmh(v) + 1.1, 18.6)` on the bike (`:221-224`) **[CODE]**.
- The follow camera applies a zoom change only if `|current − target| ≥ 0.35` (`DashMapController.kt:319-321`)
  **[CODE]**.
- Moving means `speed > 1.2 m/s`. Bearing is taken from GPS while moving, otherwise from the compass
  (`GpxDashUi.kt:1138-1146`) **[CODE]**.

### 6.5 Long-press → drop pin

`DashMapController` long-press → `GpxDashUi.kt:1906-1917` **[CODE]**:
1. `hideSheets()`.
2. Create `MapPlace("Dropped pin", lat, lon, "pin", "%.5f, %.5f")`.
3. Voice "Pin dropped" (if voice is on).
4. `showPinSetup(place)`: the preview card in pin mode (Save / Home / Marker / Done; Go and Circuit
   hidden). Centre at zoom 16.0, status "Save this pin — open it later to navigate", handlebar focus
   prefers "go" (`GpxDashUi.kt:764-789`).

### 6.6 Handlebar and pad focus navigation on the built-in map

This is armed **only when projected** (`GpxDashUi.kt:1922-2136`), and it is **the model for iOS**: the iOS
dash UI is driven by handlebar actions exactly like this **[PROP]**.

- **Sinks**: `MapInputBridge.keySink = { code -> handleMapKey(code) }` and
  `MapInputBridge.scrollSink = { delta -> moveFocus(delta) }`, both posted to the main thread
  (`GpxDashUi.kt:2116-2127`; `MapInputBridge.kt:14-25`). Map sinks **take priority** over Android Auto
  sinks (`MediaButtonBridge.kt:747-774`, `ControlsActivity.kt:262-288`) **[CODE]**.
- **Focus ring**: a foreground `GradientDrawable` with fill `0x66FF9800`, a **5 dp** stroke in
  `0xFFFF9800`, and a **12 dp** corner radius. Elevation 12 and translationZ 8. Scale is always 1 ("never
  scale focus — 1.18× dragged place names / chips outside the panel"). Calls `requestRectangleOnScreen` to
  scroll into view (`GpxDashUi.kt:1925-1967`) **[CODE]**.
- **Focusable list per state**. The first state that matches wins. Only views that are
  `VISIBLE && isShown && isEnabled && (isClickable || isFocusable)` are included
  (`GpxDashUi.kt:1968-2033`) **[CODE]**:

| State | Ordered focus list |
| --- | --- |
| Arrive card visible | `gpx_arrive_park`, `gpx_arrive_find`, `gpx_arrive_done` |
| Preview card visible | `gpx_preview_go`, `gpx_preview_circuit`, `gpx_preview_cancel`, `gpx_preview_save`, `gpx_preview_home`, `gpx_preview_marker`, then the children of `gpx_preview_alts` (route chips) |
| Search panel visible | Children of `gpx_search_chips` (POI chips), children of `gpx_search_results` (result rows; their inner Save/Marker/Delete chips are *not* reachable), `gpx_search_go`, `gpx_search_close` |
| Menu panel visible | `gpx_end`, `gpx_park`, `gpx_go_home`, `gpx_set_home`, `gpx_recalc`, `gpx_record`, `gpx_create_circuit`, `gpx_follow`, `gpx_north`, `gpx_mute`, `gpx_zoom_out`, `gpx_zoom_in`, `gpx_menu_close` |
| Otherwise (map) | `gpx_end_bar` (if the bottom HUD is visible); `gpx_search_pill` + `gpx_pill_circuit` (if the pill is visible); `gpx_btn_recenter`, `gpx_btn_overview`, `gpx_btn_zoom_in`, `gpx_btn_zoom_out`, `gpx_btn_mute`, `gpx_btn_north`, `gpx_open_menu` (gone ones are skipped). `gpx_pill_lap` is in **no** list, so the lap timer cannot be reached from the handlebar. iOS should add it **[PROP]**. |

- `ensureFocus(prefer)` (`:2035-2055`):
  - If the list is empty, clear the ring.
  - `"go"` focuses `gpx_preview_go` if it is in the list; `"end"` focuses `gpx_end_bar` if present.
  - Otherwise, if the focused view is no longer in the list, use index 0.
  - Clamp the index, then paint.
- `moveFocus(delta)` (`:2056-2066`): `idx = cur >= 0 ? (cur + delta) mod n : 0`. It **wraps around**, and
  Kotlin `mod` is non-negative.
- `defaultPrefer()` (`:2067-2071`): `"go"` if the preview card is visible; `"end"` while navigating
  (`liveMode != FREE_RIDE && !inPreview`); otherwise `"default"`. The comment explains this ordering:
  "Navigating: End first so Select stops the route without hunting".
- **Key handling** (`handleMapKey`, `:2090-2115`) **[CODE]**:

| Keycode | Effect |
| --- | --- |
| `23` ENTER (Select) | `ensureFocus()`, then `performClick()` on the focused view. Logs "[GPX] Select — nothing focused" if there is none. |
| `4` BACK | Arrive card → hide it; else preview → `cancelPreview()`; else search or menu open → `hideSheets()`; else log "[GPX] Back — idle". Then `ensureFocus(defaultPrefer())`. |
| `3` HOME | `toggleMenu()`: if the menu is open, `hideSheets()` + `ensureFocus(defaultPrefer())`; else `showMenu()` + `ensureFocus()`. |
| `84` ASSISTANT | `toggleSearch()`, using the same pattern for the search sheet. |
| `21` LEFT, `19` UP | `moveFocus(-1)` |
| `22` RIGHT, `20` DOWN | `moveFocus(+1)` |
| knob `scroll(±1)` | `moveFocus(±1)`. On the map, D-pad and knob are equivalent. |
| other | log "[GPX] unused key $code" |

- **Prefer hooks** that run after UI transitions: `startNavigationTo` → `"end"` (`:694`), `selectRoute` →
  `"go"` (`:762`), `showPinSetup` → `"go"` (`:787`), `previewPlace` → `"go"` (`:816`), `endRouteNow` →
  `"default"` (`:1498`). On bind, `ensureFocus(defaultPrefer())` is posted (`:2134`) **[CODE]**.
- Touch and focus are independent: a dash touch does not move or clear the ring **[CODE]**. For iOS
  **[PROP]**: when a control is touched, move focus to it, or hide the ring for 5 s.

### 6.7 "Type on the phone" dash search (`DashRemote`)

**On the bike sheet** (`GpxDashUi.kt:582-594`) **[CODE]**:
- The input is not focusable, with hint "Type on your PHONE keyboard…".
- Status reads "⌨ Type on PHONE — results show here" (16 sp, `0xFFE65100`).
- `DashRemote.requestTypeOnPhone()` is called. If no phone handler exists, the status changes to "Open
  OpenCfMoto on the phone, then type". Otherwise voice says "Type your search on the phone".

**On the phone** (`MainActivity.kt:572-614`) **[CODE]**:
- The app brings itself to the front and focuses the destination field.
- Hint "Bike dash search — type here", background `0x33FF9800` for 2500 ms, a 40 ms vibration, and a
  toast.
- While typing: debounce **350 ms**; when the trimmed query has ≥ **2** chars and the map is projected,
  call `DashRemote.submit(q)` (`MainActivity.kt:616-630`). The dash shows the sheet and runs the search
  (`GpxDashUi.kt:1335-1347`).
- The dash's own suggestions also use 350 ms and ≥ 2 chars (`GpxDashUi.kt:1356-1375`).

**iOS** **[PROP]**: an app cannot bring itself to the foreground. Post a local notification such as "Type
your search on the phone" and update a Live Activity. When the rider opens the app, focus the search
field.

---

## 7. Handlebar buttons (Bluetooth AVRCP) — Android implementation

### 7.1 What the dash actually sends

| Physical | Bluetooth form | What Android sees | Tag / source |
| --- | --- | --- | --- |
| ▲ / ▼ short press (non-touch / CFDL16-style dashes) | **AVRCP absolute volume**: no key event at all | `STREAM_MUSIC` volume changes, read through a `ContentObserver` | [HW] `MediaButtonBridge.kt:30-31`, `:39-40` |
| Hold "enter" (non-touch dashes; the bike the bridge was verified on) | AVRCP **PLAY/PAUSE** passthrough | `KEYCODE_MEDIA_PLAY_PAUSE/PLAY/PAUSE` via `MediaSession.onMediaButtonEvent` | [HW] `MediaButtonBridge.kt:32` |
| ◀ / ▶ / ★ on the 5-way Explore pod (800MT Explore) | AVRCP track keys and start | `KEYCODE_MEDIA_PREVIOUS / NEXT / PLAY_PAUSE` with real DOWN/UP; full tap / hold / ×2 | [HW] README.md:418; `ButtonClusterPreset.kt:14-18` |
| ▲▲ / ▼▼ fast double flick | Coalesced into **one** absolute-volume write; the jump size is the press count | One volume change of ≥ 3 steps | [HW] `MediaButtonBridge.kt:909-915`, `ButtonClusterPreset.kt:15-16` |
| BACK/SET pod long-press | Collapsed by the firmware into one short tap (~30–100 ms); no discrete double | Taps only | [HW] README.md:457-459, `ButtonClusterPreset.kt:15` |
| MODE / Fn / + on the MODE/ENT pod | Usually bike-native (dash menus); not AVRCP unless the firmware emits it | — | [HW] README.md:505 |
| 800NK Adventure | Never emits ▲/▼; still sends track keys | — | [HW] `ButtonPresencePrefs.kt:8-11`, README.md:512-515 |

Preconditions:
- The phone must be paired with the bike over Bluetooth (A2DP or HFP) (`strings.xml:99`,
  `BluetoothHelper.kt:15-19`).
- The dash emits transport keys only once the phone "looks like a real player" (`MediaButtonBridge.kt:33-34`)
  **[HW]**.
- The dash reads the player's capabilities when its AVRCP link forms and never re-reads them. That is why
  the session is re-announced after the bike link is up (§7.8) (`MediaButtonBridge.kt:136-141`). The
  behavior is **[CODE]**; the stated cause is **[INF]**.

### 7.2 Event sources → gesture channels

There are three **channels**, each with a single / double / long gesture (`MediaButtonBridge.kt:797-845`)
**[CODE]**:

| Source event | Android keycode(s) | Channel | Press/release timing? |
| --- | --- | --- | --- |
| Play/pause key | `KEYCODE_MEDIA_PLAY_PAUSE (85)`, `KEYCODE_MEDIA_PLAY (126)`, `KEYCODE_MEDIA_PAUSE (127)` | **Select** | Yes (DOWN/UP and repeats) |
| Next / fast-forward | `KEYCODE_MEDIA_NEXT (87)`, `KEYCODE_MEDIA_FAST_FORWARD (90)` | **Forward** | Yes |
| Previous / rewind | `KEYCODE_MEDIA_PREVIOUS (88)`, `KEYCODE_MEDIA_REWIND (89)` | **Backward** | Yes |
| Volume ▲ (STREAM_MUSIC increase) | — | **Backward** ("▲ = backward, previous item") | No: tap and ×2 only (no hold) |
| Volume ▼ (decrease) | — | **Forward** | No |
| `MediaSession.Callback.onPlay()` / `onPause()` (transport controls, not raw keys) | — | **Select** | No: tap and ×2 only |
| Any other media key (`STOP 86`, …) | — | ignored, but still consumed (the callback returns `true`) | — |

Sources: `MediaButtonBridge.kt:807-845` (raw key path); `:821-828` (onPlay/onPause fallbacks); `:632-635`
(volume direction semantics: "Volume UP = backward, DOWN = forward — same semantics as the 800MT's ◀/▶").

### 7.3 Gestures (9), ids and labels verbatim (`ButtonMap.kt:58-74`) [CODE]

| enum | `id` | `label` | `hint` | `default` action |
| --- | --- | --- | --- | --- |
| `NAV_BACK` | `navBack` | `Backward  ◀ / ▲` | `◀ left, or the ▲ volume press on non-touch dashes` | `KNOB_BACK` |
| `NAV_FWD` | `navFwd` | `Forward  ▶ / ▼` | `▶ right, or the ▼ volume press on non-touch dashes` | `KNOB_FORWARD` |
| `SELECT_PRESS` | `selectPress` | `Select  Enter / ★` | `a quick tap of the OK / ★ start button` | `SELECT` |
| `NAV_BACK_LONG` | `navBackLong` | `Backward (hold)  ◀` | `press and hold ◀ (track-key dashes only)` | `NONE` |
| `NAV_FWD_LONG` | `navFwdLong` | `Forward (hold)  ▶` | `press and hold ▶ (track-key dashes only)` | `NONE` |
| `SELECT_LONG` | `selectLong` | `Select (hold)  Enter / ★` | `press and hold the OK / ★ button` | `HOME` |
| `NAV_BACK_DOUBLE` | `navBackDouble` | `Backward ×2` | `double-tap backward within a short window` | `DPAD_LEFT` |
| `NAV_FWD_DOUBLE` | `navFwdDouble` | `Forward ×2` | `double-tap forward within a short window` | `DPAD_RIGHT` |
| `SELECT_DOUBLE` | `selectDouble` | `Select ×2` | `double-tap the OK / ★ button` | `BACK` |

(The labels contain **two spaces** before the glyphs.)

### 7.4 Assignable actions (14), ids and labels verbatim (`ButtonMap.kt:13-28`) [CODE]

| enum | `id` | `label` | Effect (`MediaButtonBridge.perform`, `:728-745`) |
| --- | --- | --- | --- |
| `NONE` | `none` | `Do nothing` | — |
| `KNOB_FORWARD` | `knobFwd` | `Knob forward (next item)` | `scroll(+1)` |
| `KNOB_BACK` | `knobBack` | `Knob back (previous item)` | `scroll(-1)` |
| `SELECT` | `select` | `Select / OK` | `key(23)` |
| `BACK` | `back` | `Back` | `key(4)` |
| `HOME` | `home` | `Home (app list)` | `key(3)` |
| `ASSISTANT` | `assistant` | `Assistant (voice)` | `key(84)` |
| `DPAD_UP` | `up` | `D-pad up` | `key(19)` |
| `DPAD_DOWN` | `down` | `D-pad down` | `key(20)` |
| `DPAD_LEFT` | `left` | `D-pad left` | `key(21)` |
| `DPAD_RIGHT` | `right` | `D-pad right` | `key(22)` |
| `NAV_1` | `nav1` | `Navigate to saved place 1` | `NavLauncher.navigate(SavedPlaces.query(0))` |
| `NAV_2` | `nav2` | `Navigate to saved place 2` | slot 1 |
| `NAV_3` | `nav3` | `Navigate to saved place 3` | slot 2 |

Routing rules:
- `key(code)` and `scroll(delta)` go to `MapInputBridge` if it is set, else to `AaVideoBridge`, else they
  are dropped with `"[BTN] no Map/AA session — key $code dropped"` / `"… scroll $delta dropped"`
  (`MediaButtonBridge.kt:748-774`) **[CODE]**.
- Display label for `NAV_n`: `"Navigate to saved place N (not set yet)"` if the slot is empty, else
  `"Navigate: <name or query>"` (`ButtonMap.kt:30-35`, `SavedPlaces.kt:34-38`).
- Saved places: `COUNT = 3` slots with keys `name<slot>` and `query<slot>` in prefs `saved_places`
  (`SavedPlaces.kt:15-29`).
- `NavLauncher` tries, in order:
  1. `https://www.google.com/maps/dir/?api=1&destination=<enc>&travelmode=driving&dir_action=navigate`
  2. `google.navigation:q=<enc>&mode=d`
  3. `geo:0,0?q=<enc>`
  4. a bare `google.navigation:q=<enc>`

  (`NavLauncher.kt:37-62`). On iOS this becomes "start navigation in our own dash UI to saved place N"
  **[PROP]**.

### 7.5 Tap / double-tap / hold detection (exact)

**Timing settings** (`ButtonTimingPrefs.kt`). They are **global, not per bike** **[CODE]**:

| Setting | Values | Default | Key |
| --- | --- | --- | --- |
| Double-tap window `doubleTapMs` | `FAST 200`, `NORMAL 300`, `SLOW 450`, `VERY_SLOW 1000` ms | **300 ms** | `double_tap_ms` (Long) — `:13-19`, `:36`, `:55-58` |
| Hold threshold `longPressMs` | `SHORT 500`, `NORMAL 600`, `LONG 800` ms | **600 ms** | `long_press_ms` — `:25-29`, `:37`, `:64-67` |
| Hold detection | on / off | **on** | `holds_enabled` — `:38`, `:78` |
| Snappy singles | on / off (no UI exposes it) | **on** | `snappy_singles` — `:39`, `:49` |

Prefs file: `opencfmoto_btn_timing` (`:35`). An unknown stored value falls back to NORMAL.

**Per-channel double-tap state** `Tap(pending: Runnable?, lastAt: Long)` is keyed by the **single**
gesture, so ▲ then ▼ inside the window stays two singles (`MediaButtonBridge.kt:655-658`).

```
detectDoubleTap(single, double, forceDouble):             // MediaButtonBridge.kt:671-711
  ch = taps[single]; now = monotonic; gap = now - ch.lastAt; ch.lastAt = now; window = doubleTapMs
  if forceDouble: cancel ch.pending; run(double); return
  snappy = snappySingles || ButtonClusterPreset.prefersInstantSingles   // == true in practice (see below)
  if snappy:
     if ch.pending != nil && 1 <= gap < window: cancel ch.pending; ch.pending = nil; run(double); return
     run(single)                                          // fires IMMEDIATELY
     ch.pending = postDelayed(window) { ch.pending = nil }  // only "arms" a possible ×2
     return
  // deferred path — [EXP] unreachable: prefersInstantSingles() is true with no preset and for all 3 presets
  wasPending = ch.pending != nil; cancel ch.pending
  if wasPending: run(double) else ch.pending = postDelayed(window) { ch.pending = nil; run(single) }
```

- With snappy singles, a double-tap runs **both** the single (on the first tap) **and** the double (on the
  second tap). A triple-tap runs single, double, single.
- A second tap with a gap of 0 ms counts as another single, because of `1 until window`.
- `prefersInstantSingles()` returns the active preset's `instantSingles` (all `true`), and `true` when no
  preset is active (`ButtonClusterPreset.kt:103-107`) **[CODE]**.

**Held buttons** (Select, Backward, Forward), with `HeldButton(downAt, longFromRepeat)`
(`MediaButtonBridge.kt:786-805`, `:851-903`) **[CODE]**:

```
onKeyDown(code, repeatCount):
  held = heldFor(code) ?: return; markTrackSeen(); lastKeyAt = now
  if repeatCount > 0:                                   // key-repeat while held
     if !holdsEnabled: return
     if !held.longFromRepeat && ButtonMap[held.long] != NONE:
        held.longFromRepeat = true; held.downAt = 0; cancel taps[held.single].pending; run(held.long)
     return
  if held.downAt != 0: return                           // a second DOWN while held is ignored
  held.downAt = now
onKeyUp(code):
  held = heldFor(code) ?: return; lastKeyAt = now
  if held.longFromRepeat: reset; return
  d = held.downAt; held.downAt = 0; if d == 0: return   // UP without our DOWN
  heldMs = now - d
  if holdsEnabled && heldMs >= longPressMs: cancel taps[held.single].pending; run(held.long)
  else detectDoubleTap(held.single, held.double, false)
```

Facts about this logic:
- Taps commit at **key-up**, so their latency equals the press duration.
- Holds commit at key-up, or at the first key-repeat if the long gesture is mapped.
- If the long gesture maps to `NONE`, a press of ≥ 600 ms is **swallowed** (`run(NONE)`). That is why
  "Hold detection: Off" exists: with it, every release is a tap or ×2 (`strings.xml:332`, README.md:530)
  **[CODE]**.
- Log lines:
  - `"[BTN] media key ${keyCodeToString} down (code=$code)[ repeat=N]"`
  - `"[BTN] ${name} held ${ms}ms → long press|tap|tap (hold detection off)"` (name is
    `select|backward|forward`)
  - `"[BTN] ${name} key-repeat → long press"`
  - `"[BTN] ${gesture.label} → ${action.label}"`

  Sources: `:814`, `:861`, `:888-895`, `:724`.

**Volume path** (`MediaButtonBridge.kt:600-646`) **[CODE]**:

```
ContentObserver on Settings.System.CONTENT_URI (notifyForDescendants=true):
  if ignoreVolumeChanges: return
  now = streamVolume(MUSIC); if !captureOn || pinnedVolume < 0: return; if now == pinned: return
  jump = now - pinned  (signed Android volume steps); up = jump > 0
  markVolumeSeen(); cancelAbsentProbe()
  ignoreVolumeChanges = true; setStreamVolume(MUSIC, pinned); after 80 ms: ignoreVolumeChanges = false   // re-pin FIRST
  forceDouble = |jump| >= 3            // DOUBLE_TAP_STEPS = 3 (:915)
  single = up ? NAV_BACK : NAV_FWD ; double = up ? NAV_BACK_DOUBLE : NAV_FWD_DOUBLE
  log "[BTN] volume UP|DOWN ($pinned→$now, jump=$jump)[ ×2]"
  detectDoubleTap(single, double, forceDouble)
```

Two separate 1-step writes inside the window also make a ×2, through the normal window logic.

`run(gesture)` does nothing unless capture is on (`ButtonMode.isControlAa`). The action is read
**per press**, so mapping changes apply live (`MediaButtonBridge.kt:721-726`) **[CODE]**.

### 7.6 Volume "pinning"

Because ▲/▼ arrive as **absolute** volume, the phone keeps STREAM_MUSIC at a fixed value so that the
direction of each change can be read, with headroom both ways (`MediaButtonBridge.kt:481-504`) **[CODE]**:
- `pinVolume()`:
  - `max = streamMax(MUSIC)`.
  - `userVolume` is captured once.
  - `pinned = clamp(userVolume (or max/2 if unknown), 1, max-1)`.
  - `setStreamVolume(pinned)` while ignoring observer callbacks for **150 ms**.
- `maybePinVolume(reason)`: pin only if the rocker is not `ABSENT`. When it is `ABSENT`, unpin and log
  `"skip pin … volume rocker ABSENT"` (`:468-479`).
- `unpinVolume()`: restore `userVolume` (150 ms ignore) and reset it to −1 (`:551-563`).
- The listening-volume slider (Controls) sets `userVolume = v`. While capturing,
  `pinned = clamp(v, 1, max-1)` and the stream is set to that. Otherwise the stream is set to `v`. Observer
  callbacks are ignored for 150 ms, so slider moves are never read as ▲/▼ (`:569-588`).
- Pin points: on start (if capture is on), capture-on, re-assert, reclaim, and presence refresh.
- Known limit: at the extreme ends, one direction can stop registering (`:483-487`) **[CODE]**.

### 7.7 Presence detection: auto-marking the rocker absent

Model: `ButtonPresence { UNKNOWN, PRESENT, ABSENT }`, stored per bike for two sources: `volume_rocker`
and `track_keys` in prefs `button_presence` (`ButtonPresencePrefs.kt:17-26`) **[CODE]**.

| Transition | Trigger | Source |
| --- | --- | --- |
| volume → `PRESENT` | Any ▲/▼ event | `markVolumeSeen`, `ButtonPresencePrefs.kt:46-51`; called at `MediaButtonBridge.kt:616` |
| track → `PRESENT` | Any handled key DOWN (select, next, previous family) | `markTrackSeen`, `:54-59`; `MediaButtonBridge.kt:853` |
| volume → `ABSENT` | **Auto-probe**: capture on, rocker still `UNKNOWN`, and **90 000 ms** elapsed. If the bike is not yet streaming at that moment, the probe re-checks every **30 000 ms** (`ABSENT_VOLUME_PROBE_MS / 3`). Once `BikeLink.prober.isStreaming`, it marks `ABSENT`, unpins, and logs `"[BTN] no volume ▲/▼ for 90s while streaming — marking rocker ABSENT, unpinning"`. | `MediaButtonBridge.kt:506-538`, `:931` |
| manual | "Teach my handlebar…" dialog: `▲/▼ works` → volume PRESENT; `▲/▼ absent` → volume ABSENT; `Reset to untested` → volume **and** track UNKNOWN. Track keys have no manual Present/Absent button. Then `refreshVolumePresencePolicy()`, which re-pins or unpins and re-arms the probe. | `ButtonMappingActivity.kt:259-286`; `MediaButtonBridge.kt:541-548` |

Notes:
- The 90 s timer starts when **capture starts**, not when streaming starts. If streaming began at 80 s, the
  rocker is marked absent after only 10 s of streaming **[CODE]** (quirk). README describes it as
  "~90 s of streaming" (README.md:399).
- The probe runs only while the rocker is `UNKNOWN`. `PRESENT` and `ABSENT` are sticky until re-taught or
  until an event flips them to `PRESENT` (`ButtonPresencePrefs.kt:13-15`).
- The summary string is `"▲/▼ <untested|works|absent> · ◀/▶ <untested|works|absent>"`, shown as
  `"Handlebar sources: …"` (`ButtonPresencePrefs.kt:65-72`; `ButtonMappingActivity.kt:173-174`).

### 7.8 Staying the button target: MediaSession upkeep (Android-specific, but analogues exist on iOS)

| Mechanism | Exact values | Source |
| --- | --- | --- |
| MediaSession tag | `"OpenCfMoto"` | `MediaButtonBridge.kt:107` |
| Playback state | Always `STATE_PLAYING`, position 0, speed 1.0. Actions `PLAY \| PAUSE \| PLAY_PAUSE \| SKIP_TO_NEXT \| SKIP_TO_PREVIOUS \| FAST_FORWARD \| REWIND`. | `:109-117`, `:339-359` |
| Metadata (shown by the dash's AVRCP "now playing") | TITLE `"Android Auto control"`; ARTIST `"◀ ▶ knob · ×2 ←→ · ★ OK · ★★ Back · ★hold Home"`; ALBUM `"OpenCfMoto"`; DURATION `3_600_000` ms | `:362-375`, `:907` |
| Silent track | `AudioTrack`, 8000 Hz, mono, PCM16, a 1 s buffer of zeros (`MODE_STATIC`), looped forever (`setLoopPoints(0, 8000, -1)`), volume **0.01**, attributes `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE` / `CONTENT_TYPE_SPEECH` | `:414-441`, `:60-65` |
| Audio focus | `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` with nav attributes, `acceptsDelayedFocusGain = true`, `willPauseWhenDucked = false`. Never exclusive GAIN ("killed Spotify/YT"), so music keeps playing ducked. | `:236-254`, `:56-59` |
| MediaStyle notification | Channel `"opencfmoto_media"` (name "Bike button control"), id **3**, ongoing, title "Android Auto control", text "Bike buttons drive Android Auto" | `:378-398`, `:932-933`; `strings.xml:598-600` |
| Keep-alive | Every **4000 ms**: refresh metadata, state and active, plus a quiet notification. Every 3rd tick (12 s), re-request focus, but only if no key has arrived for **2500 ms**. Re-requesting mid-tap made the BT stack re-deliver presses. | `:88-102`, `:918`, `:929` |
| Focus loss | `LOSS`/`LOSS_TRANSIENT` → reclaim after **500 ms**, or after **2000 ms** if the last reclaim was less than 2000 ms ago. `CAN_DUCK` → refresh only. `GAIN` → silence + refresh. | `:256-295`, `:926-927` |
| Reclaim | Request focus + silence, set the session inactive, then after **500 ms**: refresh, set active, re-pin | `:302-325`, `:925` |
| Re-announce after the bike is up | Poll `BikeLink.prober.isStreaming` every **1000 ms** for up to **90 000 ms**. When streaming, wait **3000 ms** to settle, set the session inactive, and after **500 ms** publish metadata, set active, re-pin, and post the notification. One-shot per bridge. | `:136-183`, `:920-925` |
| AA audio starts | Restart silence + refresh. Focus is not grabbed. | `:216-227`; `AaVideoBridge.kt:32-37` |
| Bridge lifetime | Created while the foreground service runs **AA or Map** (not plain mirror), and only if Bluetooth is enabled **and** `BLUETOOTH_CONNECT` is granted (API 31+). Otherwise logs `"[BTN] skipped — Bluetooth off or no Nearby/BLUETOOTH_CONNECT"`. | `AndroidAutoService.kt:75-88`, `:530-557` |

### 7.9 Capture mode toggle (`ButtonMode`)

- `ButtonMode.isControlAa`: prefs `button_mode`, key `controlAa`, **default `true`** (per bike)
  (`ButtonMode.kt:19-26`) **[CODE]**.
- **ON**: the bars drive the dash UI or AA; music keeps playing ducked.
- **OFF**: the bars control media normally. Focus is released, the volume unpinned, the probes cancelled,
  holds reset, and pending taps cancelled (`MediaButtonBridge.kt:190-214`).
- Toggling is live: Controls switch → `ButtonMode.set` + `setCaptureActive` (`ControlsActivity.kt:124-132`).
- Applying a cluster preset forces capture ON (`ButtonClusterPreset.kt:84-90`).

### 7.10 Cluster presets (README names them A / B / C)

Definitions (`ButtonClusterPreset.kt:20-91`) **[CODE]**. README photos and descriptions:
README.md:402-418, 455-505.

| README | Preset id | Title (verbatim) | `instantSingles` | Summary (verbatim) | What the bike can send (README.md:416-418) [HW] |
| --- | --- | --- | --- | --- | --- |
| **A** | `back_set` | `BACK / SET diamond (limited)` | true | `Snappy singles (no double-tap wait). Discrete hold / Select ×2 usually don't exist — but a hard ▲▲ / ▼▼ volume flick often coalesces into ×2 → Back / Home. On-screen pad covers anything else.` | Reliable taps. Discrete hold / Select ×2 usually missing; ▲▲/▼▼ volume ×2 often still works. (▲ ▼ BACK SET, turn signals, red horn) |
| **B** | `mode_ent` | `MODE / ENT cluster` | true | `Same AA navigation as 5-way: knob · ×2 = D-pad ←/→ · ★★ = Back. Singles are snappy; a second tap in the window still fires ×2.` | Taps + often Select ×2; holds / ◀◀ ▶▶ best-effort. (M MODE, +, Fn, center, ⌄ back, ENT, ▲ ▼) |
| **C** | `five_way` | `5-way Explore (Fn / ★ / voice)` | true | `◀/▶ = knob (move) · ◀◀/▶▶ = D-pad ←/→ (into apps) · ★ = Select · ★★ = Back · ★ hold = Home. Singles fire immediately (no lag waiting for ×2).` | Full tap / hold / ×2 on ◀ / ▶ / ★ (verified on 800MT Explore). Shipped default. |

**Full mappings** (all 9 rows are always written):

| Gesture | C `five_way` (= shipped defaults) | B `mode_ent` | A `back_set` |
| --- | --- | --- | --- |
| `navBack` | knobBack | knobBack | knobBack |
| `navFwd` | knobFwd | knobFwd | knobFwd |
| `selectPress` | select | select | select |
| `navBackLong` | none | none | none |
| `navFwdLong` | none | none | none |
| `selectLong` | home | home | none |
| `navBackDouble` | left | left | **back** |
| `navFwdDouble` | right | right | **home** |
| `selectDouble` | back | back | none |

Behavior of the preset operations:
- `apply()`:
  1. `ButtonMap.resetAll` (the selected bike only).
  2. `set` all 9 entries.
  3. Save the active preset id.
  4. If capture is off, turn it on and call `setCaptureActive(true)`.

  The touchscreen flags are **never** changed (`:76-91`).
- `clear()`: `resetAll` and remove the active tag, which restores the shipped defaults. Capture is
  unchanged (`:120-123`).
- Prefs: file `button_cluster_preset`, key `active`, per bike (`:94-95`).

### 7.11 Test vectors (handlebar)

**From the repo** (`BikeProfileSelectTest.kt:39-75`, `SettingsBackupTest.kt:16-24`):
- Shipped defaults: `NAV_BACK→KNOB_BACK`, `NAV_FWD→KNOB_FORWARD`, `SELECT_PRESS→SELECT`,
  `NAV_BACK_LONG→NONE`, `NAV_FWD_LONG→NONE`, `SELECT_LONG→HOME`, `NAV_BACK_DOUBLE→DPAD_LEFT`,
  `NAV_FWD_DOUBLE→DPAD_RIGHT`, `SELECT_DOUBLE→BACK`.
- `BACK_SET.mapping()`: `NAV_BACK→KNOB_BACK`, `NAV_FWD→KNOB_FORWARD`, `SELECT_PRESS→SELECT`,
  `SELECT_LONG→NONE`, `NAV_BACK_LONG→NONE`, `NAV_FWD_LONG→NONE`, `SELECT_DOUBLE→NONE`,
  `NAV_BACK_DOUBLE→BACK`, `NAV_FWD_DOUBLE→HOME`. Also `BACK_SET.instantSingles == true` and
  `FIVE_WAY.instantSingles == true`.
- `FIVE_WAY.mapping()[g] == g.default` for every gesture.
- Round trip: `ButtonAction.byId(a.id) == a` for every action, and `byId(g.default.id) == g.default`.

**Derived traces.** These come from a faithful port of `detectDoubleTap`/`onKeyDown`/`onKeyUp`/volume
observer with the default timing (window 300 ms, hold 600 ms, holds on, snappy on), shipped defaults, and
the pin at 7. Format: `t gesture → action` **[CODE-derived]**.

| # | Input | Output |
| --- | --- | --- |
| B1 | `PREVIOUS(88)` down@0, up@80 | `80 NAV_BACK → KNOB_BACK` |
| B2 | `NEXT(87)` down@0 up@70, down@200 up@260 | `70 NAV_FWD → KNOB_FORWARD`; `260 NAV_FWD_DOUBLE → DPAD_RIGHT` |
| B3 | `PAUSE(127)` down@0, up@700 | `700 SELECT_LONG → HOME` |
| B4 | `PLAY_PAUSE(85)` down@0 (rc=0), down@500 (rc=1), up@900 | `500 SELECT_LONG → HOME` (nothing at the UP) |
| B5 | `PREVIOUS` down@0, up@700 (`navBackLong=none`) | `700 NAV_BACK_LONG → NONE`: **the press is swallowed** |
| B6 | B5 with holds disabled | `700 NAV_BACK → KNOB_BACK` |
| B7 | volume 7→8 | `0 NAV_BACK → KNOB_BACK` (re-pinned to 7) |
| B8 | volume 7→4 (jump −3) | `0 NAV_FWD_DOUBLE → DPAD_RIGHT` (forceDouble) |
| B9 | volume 7→8 @0, 7→8 @150 | `0 NAV_BACK → KNOB_BACK`; `150 NAV_BACK_DOUBLE → DPAD_LEFT` |
| B10 | volume 7→8 @0, 7→6 @100 | `0 NAV_BACK → KNOB_BACK`; `100 NAV_FWD → KNOB_FORWARD` (separate channels) |
| B11 | `NEXT` tapped with ups @50, @200, @350 | `50 NAV_FWD`; `200 NAV_FWD_DOUBLE`; `350 NAV_FWD` |
| B12 | `NEXT` ups @50 and @50 (gap 0) | two `NAV_FWD` |
| B13 | BACK_SET preset, volume 7→10 | `0 NAV_BACK_DOUBLE → BACK` |
| B14 | **[EXP]** deferred path (snappy off): `NEXT` up@50, no second tap | `350 NAV_FWD → KNOB_FORWARD` |

### 7.12 Persistence, per-bike scoping and JSON

- **Per-bike scoping**:
  - A value is stored under the key `"<base>#b<hex(rawQr.hashCode())>"`, using Java `String.hashCode`.
  - Reads fall back to the unscoped global key, then to the default.
  - `remove` drops only the scoped key, so a reset can expose an older global value.

  (`BikeScope.kt:14-61`) **[CODE]**. iOS can use any stable bike id. Compatibility should go through the
  JSON export, not these keys **[PROP]**.
- Scoped settings: `ButtonMap` (`button_map`), `ButtonMode` (`button_mode/controlAa`), the cluster preset
  (`button_cluster_preset/active`), and presence (`button_presence/volume_rocker|track_keys`).
- Global settings: timing (`opencfmoto_btn_timing`), the remote pad (`opencfmoto_remote_pad`), and saved
  places (`saved_places`).
- `ButtonMap` migrations (`ButtonMap.kt:108-147`):
  - `defaults_ver` is an Int, default 1. `DEFAULTS_VER = 8`.
  - Stored values equal to an *old* default are cleared so that the new defaults apply.
  - A new iOS app needs no migrations. When importing Android exports, accept any ids.
- **Settings export JSON**. Copied from `SettingsBackup.kt:27-75`. `toString(2)` gives 2-space indentation,
  and keys stay in insertion order. Input-related keys are marked; the others belong to other specs.

```json
{
  "format": "opencfmoto.settings",
  "version": 1,
  "exportedAt": "<yyyy-MM-dd'T'HH:mm:ssXXX>",
  "appVersion": "<BuildConfig.VERSION_NAME>",
  "bikeHint": { "profile": "<BikeProfile.name>", "profileOverride": "<ProfileOverride.id>" },
  "settings": {
    "videoQuality": "<enum name>",
    "screenFit": "<FILL|FIT|STRETCH>",
    "mirrorOrientation": "<enum name>",
    "powerMode": "<enum name>",
    "resolutionMode": "<enum name>",
    "aaDpiOverride": 0,
    "remotePad": true,
    "profileOverride": "<id>",
    "controlAa": true,
    "forceNonTouch": false,
    "forceTouch": false,
    "wifiTransport": "<id>",
    "screenMargins": { "customised": false, "top": 0, "bottom": 0, "left": 0, "right": 0 },
    "buttons": {
      "navBack": "knobBack", "navFwd": "knobFwd", "selectPress": "select",
      "navBackLong": "none", "navFwdLong": "none", "selectLong": "home",
      "navBackDouble": "left", "navFwdDouble": "right", "selectDouble": "back"
    }
  }
}
```

  - Input-related keys: `remotePad`, `controlAa`, `forceNonTouch`, `forceTouch`, `screenMargins` (values
    only when `customised`, else zeros), and `buttons` (gesture id → action id; the values shown are the
    defaults). Timing prefs are deliberately **not** exported ("personal prefs", `SettingsBackup.kt:12-16`).
  - Import rules (`:77-107`, `:164-169`):
    - Requires `format == "opencfmoto.settings"` and `1 <= version <= 1`.
    - Unknown action ids are ignored, so an iOS-only action id is safely ignored by Android.
    - A leading BOM is stripped.
  - Test vectors: `FORMAT == "opencfmoto.settings"`, `VERSION == 1` (`SettingsBackupTest.kt:10-14`).

### 7.13 Bluetooth HID "remote pad" (`RemotePad`)

- Scope: HID gamepads, ring remotes and keypads, captured **only while one of the app's activities is in
  the foreground** (`dispatchKeyEvent` in `MainActivity.kt:40-43`, `HudViewActivity.kt:35-38`,
  `ButtonMappingActivity.kt:178-181`). AVRCP remotes use the MediaSession path instead
  (`RemotePad.kt:9-13`) **[CODE]**.
- `consume(event)` (`RemotePad.kt:30-45`):
  1. If a teach listener is active, it gets the event first and consumes it.
  2. Requires enabled (default **true**, key `remote_pad_on`) and capture ON.
  3. Requires an external pad: the device is non-virtual and the source is GAMEPAD, DPAD, JOYSTICK, or a
     KEYBOARD that is not virtual (`:88-96`).
  4. Only `ACTION_DOWN` and `ACTION_UP`. Repeats are swallowed. The action fires on **DOWN with
     repeatCount == 0**.
  5. There is **no tap / ×2 / hold detection** on this path: one key is one gesture or action.
- Direct actions: `DPAD_UP/DOWN/LEFT/RIGHT` → `DPAD_UP/DOWN/LEFT/RIGHT` (`:63-69`).
- Default gestures (`:71-86`):

| Key(s) | Gesture |
| --- | --- |
| `BUTTON_Y`, `BUTTON_L1`, `BUTTON_THUMBL` | `NAV_BACK` |
| `BUTTON_R1`, `BUTTON_THUMBR` | `NAV_FWD` |
| `DPAD_CENTER`, `BUTTON_A`, `BUTTON_START`, `ENTER` | `SELECT_PRESS` |
| `BUTTON_B`, `BACK` | `SELECT_DOUBLE` |
| `BUTTON_X`, `HOME` | `SELECT_LONG` |

- Teach: the next non-virtual `ACTION_DOWN` (repeat 0) maps that keycode to the chosen gesture. The map is
  stored as `"code=gestureId;code=gestureId"` under `remote_pad_map` (`RemotePad.kt:101-117`;
  `ButtonMappingActivity.kt:200-242`).

### 7.14 On-phone controls: Controls screen and Button mapping screen

**Controls** (`ControlsActivity.kt`, `res/layout/activity_controls.xml`) **[CODE]**:
- **Pad buttons** (key routing: map sink, then AA sink, else the toast "Start Android Auto or Map first",
  `:262-288`):

| Label | Action |
| --- | --- |
| `⟲ Prev` | `scroll(-1)` |
| `▲` | 19 |
| `Next ⟳` | `scroll(+1)` |
| `◀` | 21 |
| `OK` | 23 |
| `▶` | 22 |
| `▼` | 20 |
| `Back` | 4 |
| `Home` | 3 |
| `Voice` | 84, after requesting RECORD_AUDIO |

  Wiring: `:94-106`.
- **Fullscreen pad**: min button height **72 dp** (48 dp normal). Keeps the screen on, hides the system
  bars, and Back exits fullscreen first (`:150-220`).
- **Volume slider** (layout default max 15, progress 8): synced to `volumeLevels()`. Moves go through
  `MediaButtonBridge.setVolume`, which moves the pin (§7.6) (`:76-89`, `:222-234`).
- "Navigate to…" box → `NavLauncher` (`:65-74`). Map theme Auto/Day/Night → `nightSink` (`:138-142`).
- **Touch hint** card ("Your dash is a touchscreen — just tap the screen…", `strings.xml:97`). Shown when
  the live profile advertises touch, or, with no live profile, when the last connect did (`:108-122`).
- Handlebar switch, labelled "Handlebar buttons drive Android Auto" (`:124-132`). "Customize buttons" opens
  the mapping screen (`:134-136`).

**Button mapping** (`ButtonMappingActivity.kt`, `res/layout/activity_button_mapping.xml`) **[CODE]**:
- Header: the BT status line (tap → Bluetooth settings), the presence line, and "Teach my handlebar…".
- Remote pad On/Off and "Teach a remote button…".
- Cluster: "Apply preset…" opens a dialog listing the 3 titles, then a confirmation with the preset
  summary + `"\n\nReplace the current mapping for this bike? Saved places are kept."`. "Clear preset" is
  enabled only when a preset is active. Active line: `"Active: <title>"` or
  `"No preset — shipped defaults / your custom map"`.
- Gestures: 9 rows (label, hint, current `displayLabel`). Tapping a row opens a single-choice dialog of
  all 14 actions, which saves immediately. Choosing an unset nav slot shows the toast "Set that place's
  address below".
- "Reset to defaults" is enabled only if not all gestures are default.
- Saved places: 3 × (name, query). They are saved on pause.
- An overlay-permission card appears only if a NAV action is mapped and "Display over other apps" is off.

### 7.15 Bluetooth helpers

- `BluetoothHelper.status` **[CODE]**:
  - Bluetooth counts as connected if the A2DP **or** HEADSET profile state is CONNECTED.
  - The device name comes from the bonded devices whose hidden `isConnected()` is true. It prefers names
    containing `CFMOTO`, `CFDL`, `Bike`, `Moto`, `VOGE` or `QJ`.

  (`BluetoothHelper.kt:49-90`). Short lines: `"Bluetooth: not available"`,
  `"Bluetooth: off — tap to open settings"`, `"BT connected: <name>"`,
  `"BT: on, no audio device connected — tap to pair"` (`:41-46`).
- `openBluetoothSettings` uses `Settings.ACTION_BLUETOOTH_SETTINGS`, falling back to `ACTION_SETTINGS`
  (`:125-136`).
- **`BtConnectTrigger`** (optional) **[CODE]**:
  - Fires on `ACTION_ACL_CONNECTED` for the chosen bonded MAC (`AppSettings.btTriggerMac`).
  - It does nothing if the service is already running or no bike is saved. In that last case it logs
    "BT trigger … ignored — no saved bike".
  - Otherwise it starts `MainActivity` with the extra `bt_trigger=true`, which begins Connect.

  (`BtConnectTrigger.kt:16-42`).

### 7.16 Diagnostic log lines (README.md:533-547)

When ported, these give riders the same tuning workflow:
- `media key KEYCODE_MEDIA_PREVIOUS/NEXT/PAUSE down`
- `volume UP/DOWN (… jump=N)` / `×2`
- `… held 72ms → tap` / `… held 640ms → long press` / `… key-repeat → long press`
- `Backward ×2 → …`, `Select (hold) → …`
- `volume rocker marked PRESENT|ABSENT`
- `skip pin … volume rocker ABSENT`
- `reclaiming media buttons`

---

## 8. iOS feasibility per input

iOS facts are **[PLAT]**, from Apple documentation and platform knowledge, unless marked otherwise.
"Now Playing" means the app is the system's Now Playing app. That requires:
- an active `AVAudioSession` with a **non-mixable** category (`.playback` without `.mixWithOthers` or
  `.duckOthers`),
- audio actually playing (a silent loop is enough),
- `MPNowPlayingInfoCenter.default().nowPlayingInfo` set, and
- targets registered on the commands.

| Input | Android mechanism | iOS mechanism | Observable on iOS? | Gestures available on iOS | Notes |
| --- | --- | --- | --- | --- | --- |
| **Dash touch** (`cmdType 32`) | PXC media plane | Same: our own socket | **Yes, fully**, including in the background while the app runs | Everything: tap, long-press, drag, double-tap, **pinch** | iOS can do better than Android's built-in map (§6.1). |
| ◀ previous (AVRCP BACKWARD) | `KEYCODE_MEDIA_PREVIOUS`, DOWN/UP | `previousTrackCommand` (possibly `skipBackwardCommand` if enabled) | **Yes**, when Now Playing | tap, ×2 (timing) | Press/release are not exposed. Hold is possible only if the dash sends AVRCP REWIND, which arrives as `seekBackwardCommand` `.beginSeeking`/`.endSeeking` **[INF]**. |
| ▶ next (AVRCP FORWARD) | `KEYCODE_MEDIA_NEXT` | `nextTrackCommand` (or `skipForwardCommand`) | **Yes** | tap, ×2 | Hold only via `seekForwardCommand` begin/end **[INF]**. |
| ★ play/pause (AVRCP PLAY / PAUSE) | `PLAY_PAUSE`/`PLAY`/`PAUSE` with hold timing | `togglePlayPauseCommand` / `playCommand` / `pauseCommand` | **Yes** | tap, ×2 | **Hold is not observable**: there is no press duration. Register all three and treat them identically. |
| AVRCP FAST_FORWARD / REWIND | Same channel as next/previous | `seekForwardCommand` / `seekBackwardCommand` with `MPSeekCommandEvent.type` | **Probably** **[INF]** | hold = end − begin | Depends on what the dash emits. Unverified. |
| ▲ / ▼ volume (AVRCP absolute volume) | `STREAM_MUSIC` ContentObserver + re-pin | **Not a remote command.** Observe `AVAudioSession.outputVolume` with KVO while the session is active. | **Partially** **[INF]** | direction; ×2 via jump size or two events in the window | (1) Volume cannot be set back with public API: re-pinning needs the undocumented `MPVolumeView` slider hack, which is an App Review risk. (2) At 0 or max, further presses in that direction are lost. (3) Each press really changes the rider's volume and shows the volume HUD. |
| AVRCP STOP | ignored | `stopCommand` | Yes | — | Ignore it (parity). |
| `MediaSession.onPlay/onPause` (transport) | Select, tap/×2 | Same commands from Lock Screen, Control Center or Apple Watch | **Yes** | tap, ×2 | Free extra "phone pad". |
| HID gamepad / ring (remote pad) | `dispatchKeyEvent`, foreground only | `GameController` (`GCController`, `GCKeyboard`). `GCController.shouldMonitorBackgroundEvents = true` (iOS 14+) delivers controller input **in the background**. | **Yes** for game controllers. Keyboards in the background are **[INF]**. Consumer-control media keys arrive as `MPRemoteCommand`s; HID volume keys change system volume. | one key = one gesture (parity) | Better than Android (which is foreground only). |
| On-phone pad | ControlsActivity | SwiftUI pad (foreground) + **Live Activity buttons** via App Intents (iOS 17+) on the Lock Screen **[INF]** | Yes | all actions | — |
| BT connection status | Profile proxies + bonded list | `AVAudioSession.currentRoute.outputs` with `portType ∈ {.bluetoothA2DP, .bluetoothHFP, .bluetoothLE}` gives `portName` | Partial: only the active audio route | — | There is no bonded-device list. Opening Bluetooth settings is not allowed (only `UIApplication.openSettingsURLString`, which opens the app's own settings). |
| BtConnectTrigger (ACL connected) | Broadcast receiver, even when killed | `AVAudioSession.routeChangeNotification` (`.newDeviceAvailable`), only while the app runs. CoreBluetooth connection events cover BLE only. | **No** in general | — | Not feasible as an autostart trigger. |
| ASSISTANT action | `KEYCODE_SEARCH` → AA Assistant / map search | No API to invoke Siri | **No** (Siri) | — | Map to our own voice or search feature instead. Optionally expose App Intents to Siri. |
| NAV_1..3 | Launch Google Maps | Start navigation in our own dash UI | Yes | — | — |

Further consequences:
1. **Mutual exclusion with music**: as the Now Playing app with a non-mixable session, starting capture
   **interrupts** other audio apps such as Spotify. Android avoided this with duckable focus. If the
   rider starts Spotify, Spotify becomes Now Playing and the bars go to Spotify. Recovery: when Spotify
   pauses (for example the rider presses ★, which pauses Spotify), we receive
   `AVAudioSession.interruptionNotification` `.ended`. We then re-activate and become Now Playing again.
   This mirrors the README advice "press ★ to pause the song so OpenCfMoto can reclaim"
   (README.md:562-563) **[INF]**.
2. Being Now Playing keeps the app alive in the background (`UIBackgroundModes: audio`). The silent loop
   is an **App Review 2.5.4 risk** unless audio is otherwise legitimate (nav voice prompts help) **[INF]**.
3. `MPNowPlayingInfoCenter.playbackState` is macOS/Catalyst-only. On iOS, "playing" is inferred from
   active audio plus `MPNowPlayingInfoPropertyPlaybackRate = 1.0` **[PLAT]**, verify. Keep the rate at
   1.0 at all times, matching Android's permanent `STATE_PLAYING`, so the dash's ★ consistently sends
   PAUSE or a toggle.

---

## 9. Proposed iOS default mappings for the three clusters [PROP]

Principles:
- Keep the **same 9 gesture ids and 14 action ids**, so the JSON stays compatible (§7.12).
- Change defaults only where the Android default relies on an event iOS cannot observe.
- Interpret the actions in the iOS dash UI exactly as `handleMapKey` does (§6.6):
  - knob ±1 → focus ±1 (wrap)
  - Select → click the focused element
  - Back → close the topmost sheet or card
  - Home → toggle the menu
  - Assistant → toggle search or voice
  - D-pad ←/→ → **jump to the previous / next focus group** (an iOS refinement; on Android, D-pad equals
    the knob on the map)

Engine inputs on iOS:
- `nextTrack`, `previousTrack` and play/pause-family commands are **discrete taps**. Feed them straight into
  `detectDoubleTap` (like Android's `onPlay`/`onPause` path), with snappy singles and a 300 ms window.
- `seekForward`/`seekBackward` begin → `press(channel)`; end → `release(channel)` (hold if ≥ 600 ms).
- Optional volume KVO (experimental): Δ in steps = `round(|ΔoutputVolume| / 0.0625)`, where iOS has 16
  steps **[INF]**. Use `forceDouble` if steps ≥ 3, then reset via `MPVolumeView` and stop when the rocker
  is ABSENT.

### 9.1 Cluster C — 5-way Explore (`five_way`)

| Gesture | Physical | Android signal [HW] | iOS event | iOS observable | Android preset | **iOS default** |
| --- | --- | --- | --- | --- | --- | --- |
| `navBack` | ◀ tap | `MEDIA_PREVIOUS` | `previousTrack` | yes | knobBack | **knobBack** |
| `navFwd` | ▶ tap | `MEDIA_NEXT` | `nextTrack` | yes | knobFwd | **knobFwd** |
| `selectPress` | ★ tap | `PLAY_PAUSE`/`PAUSE` | toggle / play / pause | yes | select | **select** |
| `selectDouble` | ★★ | 2 × play/pause in 300 ms | 2 × command | yes | back | **back** |
| `navBackDouble` | ◀◀ | 2 × previous | 2 × `previousTrack` | yes | left | **left** (previous focus group) |
| `navFwdDouble` | ▶▶ | 2 × next | 2 × `nextTrack` | yes | right | **home** (menu): replaces the unobservable ★-hold |
| `selectLong` | ★ hold | DOWN…UP ≥ 600 ms / repeat | — | **no** | home | **none** (stored value kept; never fires) |
| `navBackLong` | ◀ hold | DOWN…UP ≥ 600 ms | `seekBackward` begin/end (if the dash sends REWIND) | unverified | none | **none** |
| `navFwdLong` | ▶ hold | DOWN…UP ≥ 600 ms | `seekForward` begin/end | unverified | none | **none** |

Now Playing metadata, for the dash's own "now playing" widget. Printable ASCII only: the 450MT dash
drew ◀ ▶ as empty boxes in its media pill (second field test; ★ and · were not caught on camera). The
pill scrolls the title and artist, so the most-used keys come first:
- title `"OpenCfMoto"`
- artist `"< > move  * OK  ** Back  >> Menu  << Group"`
- album `"OpenCfMoto"`
- duration 3600 s

### 9.2 Cluster B — MODE / ENT (`mode_ent`)

Same table as C. ENT is play/pause, and ★★ = ENT×2 → back, as on Android ("try two firm taps inside
~300–450 ms", README.md:498). Differences:
- On some firmwares ▲/▼ may arrive as **volume** rather than track keys **[INF]**. Then `navBack`/`navFwd`
  work only through the experimental volume path. The Teach screen (§10.9) should detect which source
  arrives.
- MODE, Fn and + stay bike-native.

### 9.3 Cluster A — BACK / SET diamond (`back_set`)

| Gesture | Physical | Android signal [HW] | iOS event | iOS observable | Android preset | **iOS default** |
| --- | --- | --- | --- | --- | --- | --- |
| `selectPress` | SET / enter (a held enter sends PLAY/PAUSE on the verified non-touch bike; SET = that enter is **[INF]**) | `PLAY/PAUSE` | toggle / play / pause | yes | select | **select** |
| `navBack` | ▲ | absolute volume ↑ | `outputVolume` KVO ↑ | partial, experimental | knobBack | knobBack **only if** "Volume buttons navigate (experimental)" is on, else unreachable |
| `navFwd` | ▼ | absolute volume ↓ | KVO ↓ | partial, experimental | knobFwd | knobFwd (experimental) |
| `navBackDouble` | ▲▲ flick | coalesced jump ≥ 3 | KVO jump | partial, experimental | back | back (experimental) |
| `navFwdDouble` | ▼▼ flick | coalesced jump ≥ 3 | KVO jump | partial, experimental | home | home (experimental) |
| `selectDouble` | SET ×2 | rarely sent | 2 × command | yes, if sent | none | none |
| holds | — | collapse to a tap | — | no | none | none |

With the volume path **off** (the App-Store-safe default), only ★ is observable, so cluster A on iOS is
"**touch / phone first**":
- **Option A1**: offer an **iOS-only single-button preset**: `selectPress → knobFwd` (cycles focus with
  wrap) and `selectDouble → select`. This is usable only if the bike delivers discrete doubles; Android
  logs say it "almost never" does.
- **Option A2**: add iOS-only actions (new ids, safely ignored by Android import):
  - `recenter`
  - `zoomIn` / `zoomOut`
  - `toggleOverview`
  - `cycleQuick`, which cycles recenter → zoom in → zoom out → overview

  Then default `selectPress → recenter` for cluster A.

In both options, rely on the on-phone pad, Lock Screen controls and a Live Activity for the rest.

---

## 10. iOS implementation notes

1. **Package layout.** Keep the deterministic logic in `OpenCfMotoCore` (pure Swift, Linux-testable):
   - touch frame decoder
   - `TouchFilter` (§4)
   - touch-set state machine (§5)
   - dash gesture recognizer (§6.2)
   - focus engine (§6.6)
   - button gesture engine (§7.5)
   - `ButtonMap` / presets / presence model (§7.3–§7.10)
   - JSON import and export (§7.12)

   Put the adapters in `OpenCfMotoApple`: `MPRemoteCommandCenter`, `AVAudioSession` (KVO, interruption,
   route), `MPNowPlayingInfoCenter`, `GameController`, Live Activity / App Intents.
2. **Decoding.** Read `cmdType` as `Int16` and `cmdLen` as `UInt16` from the 8-byte header. Body: reject
   `< 8` bytes. Read u16 LE at 0, 2, 4 and 6; read the u32 LE at 8 if `≥ 12` bytes; keep the raw bytes in
   debug logs. Accept touches on **both** media sockets. **Never reply.** Use the existing
   `ByteReader.u16le()` / `u32le()` in `OpenCfMotoCore/Util/ByteIO.swift`.
3. **TouchFilter.** Port §4.3 exactly, with an `androidCompat` flag. Default to F1–F3 enabled (§4.6).
   - Use a serial executor or actor with an injectable `Clock` and `Scheduler`. The 80 ms hold should be a
     cancellable work item.
   - Unit tests: §4.5(a) and (b), both compat and fixed variants.
   - Keep `MAX_POINTERS = 2` unless dashes are found to report more.
   - Keep the thresholds in canvas px. Consider scaling them by `negW/1280` for very different panels
     (open question).
4. **One touch pipeline.** Dash touches and phone "Dash view" touches (mapped with §3.4) both enter the
   recognizer **after** the filter, with distinct pointer-id namespaces (for example phone ids + 1000).
5. **Gestures.** Implement §6.2: slop `8·s`, long-press 450 ms, double-tap 300 ms after the *filtered* UP,
   double-tap slop `100·s`, and pinch.
   - Every map pan, pinch or zoom is a free-pan: follow off, auto-recenter after 12 s (§6.4). This fixes
     the Android quirk where a drag does not stop follow.
   - Hit-test against the same retained layout tree used for rendering and for focus order. Keep
     hit-target sizes ≥ 46–48 dp × `s` (§6.3), with ≥ 56 dp preferred for gloves.
6. **Canvas mapping.** Render the dash UI at exactly `negW × negH`.
   - If VideoToolbox forces a different coded size (alignment or cropping), apply the inverse of that
     transform to touches.
   - Clamp to canvas bounds, and ignore touches inside the screen margins (§3.5).
   - **ReplayKit mirror mode drops dash touches** (parity with Android). Also disable handlebar capture in
     mirror mode so that the bars control the rider's music normally.
7. **Focus engine.**
   - Keep ordered focus lists per UI state, with wrap-around.
   - Support prefer hints (`go`, `end`, `default`) and re-focus after every state change (§6.6).
   - Style the ring like Android: orange `#FF9800`, 5 dp stroke, 40% fill, 12 dp radius, no scaling.
   - Decide whether touch moves focus (recommended: yes).
8. **Button engine.** Port §7.5 exactly, with snappy singles on, a 300 ms window and a 600 ms hold. Add an
   entry point `discreteTap(channel)` for iOS commands, which have no DOWN/UP. Read `ButtonMap` on every
   press (live remapping). Log in the §7.16 formats.
9. **Teach / diagnostics screen.** iOS events per dash are unknown, so ship a screen that lists every raw
   remote-command event, seek begin/end, and `outputVolume` change, with millisecond timestamps. Let the
   rider mark ▲/▼ and ◀/▶ presence (`UNKNOWN`/`PRESENT`/`ABSENT`, per bike) and pick a cluster preset.
   Implement the 90 s ABSENT auto-probe for the volume path only. Start the timer when streaming starts,
   which fixes §7.7's quirk.
10. **Now Playing upkeep** (the iOS analogue of §7.8):
    - Category `.playback`, non-mixable.
    - Silent loop: an `AVAudioEngine` player node scheduling a 1 s zero buffer, looped.
    - `nowPlayingInfo` with rate 1.0.
    - Register handlers on `play`, `pause`, `togglePlayPause`, `nextTrack`, `previousTrack`,
      `seekForward`, `seekBackward`. Optionally also `skipForward`/`skipBackward`, mapped to the same
      channels; verify which ones fire.
    - Disable `changePlaybackPosition`.
    - On interruption `.began`, stop claiming. On `.ended`, re-activate and refresh `nowPlayingInfo` if
      capture is on.
    - **Do not auto-reclaim while `AVAudioSession.isOtherAudioPlaying`.** That would pause the rider's
      music; Android only got away with it through ducking.
    - Consider a one-shot "re-announce" after the PXC link streams: rate 0 → 1, or a title change, after a
      3 s settle. This mirrors §7.8 **[INF]**.
11. **Volume path (experimental, off by default).**
    - KVO on `outputVolume` (requires an active session).
    - Re-pin via `MPVolumeView` slider manipulation (private-ish; may break; App Review risk).
    - Hide the HUD with an offscreen `MPVolumeView`.
    - Pin at the listening level clamped to `[1/16, 15/16]`.
    - Ignore KVO echoes for 80–150 ms after our own sets.
12. **Background input.**
    - Remote commands arrive in the background while we are Now Playing.
    - Set `GCController.shouldMonitorBackgroundEvents = true` for HID remotes.
    - A Live Activity with interactive buttons (App Intents running in the app process) can serve as a
      lock-screen pad.
13. **Per-bike state.** Scope `ButtonMap`, capture mode, the preset and presence per bike. Keep timing
    global. Exchange settings using the §7.12 JSON (`"buttons"`, `"controlAa"`, `"forceTouch"`,
    `"forceNonTouch"`, `"screenMargins"`, `"remotePad"`).
14. **CLIENT_INFO.** Append `"supportScreenTouch": true` for touch-capable profiles, or when "Force
    touchscreen" is on (§2.6). Log the bike's own `supportScreenTouch`, `supportHID` and
    `supportMirrorOverlayTouch`.

---

## 11. Open questions / risks

1. **Touch body bytes 8–17**: the timestamp unit and epoch, and the meaning of the 6 trailing bytes, are
   unknown. Capture raw frames on several dashes.
2. **Touch coordinate space**: the canvas is assumed (§3.1). This is unverified on dashes whose requested
   size is not a multiple of 16, or where the panel differs from the canvas. Use the corner-tap test.
3. **Touch enablement**: does the dash send `cmdType 32` only when the phone advertises
   `supportScreenTouch`? The 1000 MT-X panel is touch-locked by default (bike setting).
4. **Pointer ids > 1 / more than 2 contacts**: never observed. `MAX_POINTERS = 2` silently trims.
5. **Stationary fingers**: do dashes repeat MOVEs for a still finger? This affects the 300 ms eviction
   during pinch (Q5).
6. **Filter defects** Q1–Q3: decide between bug-for-bug parity and the fixes. The vectors cover both.
7. **Double-tap on the dash** requires a raw gap in (80, 380] ms because of the stitch hold. Fast
   double-taps merge into one touch.
8. **AVRCP → MPRemoteCommand mapping** is unverified per dash:
   - whether ★ arrives as `play`, `pause` or `togglePlayPause`
   - whether next/previous fire on press or release
   - whether quick double presses arrive as two events or are coalesced
   - whether holds produce seek begin/end
9. **"Re-announce" requirement**: Android found that the dash reads the player capabilities only once per
   AVRCP link. How to force a re-read from iOS is unknown.
10. **Now Playing exclusivity on iOS**: capture interrupts the rider's music. This is a product decision
    (Android ducks instead).
11. **App Review**: background audio via a silent loop (2.5.4), and the `MPVolumeView` volume reset for the
    ▲/▼ path.
12. **Absolute-volume observation**: `outputVolume` KVO under AVRCP absolute volume, and its step size
    (Android uses `streamMax` steps, typically 15; iOS has 16 steps), are unverified. The ≥ 3-step
    double threshold may need recalibration.
13. **iOS-mode dashes**: some dashes have a separate "iOS (CarPlay) QR" mode (README troubleshooting).
    Whether their AVRCP behavior differs when an iPhone is paired is unknown.
14. **Cluster ↔ bike mapping** is documented only by README photos. Which CFDL16 models carry BACK/SET
    versus MODE/ENT is not in the code.
15. **Thresholds** (48 px ghost, 150 px stitch) were tuned for the "800NK digitizer". The touch-capable
    800NK is presumably the Advanced (720×712) **[INF]**. Their suitability for other panel sizes and
    densities, such as the 800MT at 1280×576, is unknown.
16. **Built-in map pinch** was never possible from the dash on Android. Real dash pinch on the iOS UI is
    new and untested against digitizer ghosting. The 48 px merge and Q6 promotion logic should mitigate
    it.
17. **Snappy singles**: a double-tap always fires the single action first. On iOS, where ▶▶ maps to Home,
    that means "focus next, then open the menu". This is harmless but visible. Consider "deferred
    singles" for channels whose ×2 is mapped (Android doc 06 idea 4, the inverse case).
