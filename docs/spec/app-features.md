# App features, settings, trips, garage, logs & strings — Implementation Spec (Android → iOS)

Source of truth: the Android app **OpenCfMoto 2.0.18** (`versionCode 77`, `app/build.gradle.kts:22-23`,
git `0abbe2a`), Kotlin, AGPL-3.0. This document is written for Swift engineers who will **not** read the
Kotlin. It covers everything that is *not* the wire protocol or the video pipeline: settings and their
storage, the portable settings JSON, the garage (multiple bikes), trip recording/storage/GPX, logs and
redaction, crash capture, problem reports, the update checker, telemetry, the home/setup screens and their
user-visible states, and the EN/ES strings. Sibling specs: `media-video.md` (media plane / encoder),
`control-plane.md` (PXC control plane, bike profiles, RSA, dash clock), `session-network.md` (session lifecycle,
Wi-Fi join, QR pairing, discovery, recovery) and `navigation-dash.md` (map hub, routing, dash map UI). Where this
document says "pairing spec", "protocol spec" or "map spec" it means those files respectively; "input spec"
means the touch/handlebar input specification (handlebar gesture engine `MediaButtonBridge`, dash touch), which is
not covered here beyond the persisted settings.

---

## Conventions

* **Citations.** `File.kt:N` = `app/src/main/java/dev/zanderp/opencfmoto/File.kt` line N (Kotlin source).
  `res/…` = `app/src/main/res/…`; `test/…` = `app/src/test/java/dev/zanderp/opencfmoto/…`;
  `docs/…` = repository `docs/` folder; `README.md`, `PRIVACY.md` = repository root.
* **Status tags** (every non-trivial fact carries one):
  * **[V-HW]** VERIFIED — the docs state it was confirmed on real hardware / in the field.
  * **[V-CODE]** VERIFIED — it is the shipping code path (read from the code; this is what ships).
  * **[INF]** INFERRED — derived by reading/simulating the code, or docs and code disagree and I resolved it.
  * **[EXP]** EXPERIMENTAL — flagged experimental in code/docs or only reachable behind an experimental toggle.
  * **[N/A-iOS]** Android-only machinery, documented for completeness / round-trip compatibility.
* **Units.** ms = milliseconds, s = seconds, m = metres, m/s, km/h, px = device pixels, dp/sp = Android
  density-independent units (≈ iOS points). Epoch times are **milliseconds since 1970-01-01T00:00:00Z** unless stated.
* Strings in `code font` are byte-exact (including Unicode such as `‑` U+2011 non-breaking hyphen, `…` U+2026,
  `—` U+2014, `·` U+00B7, `▸` U+25B8, `«»` U+00AB/U+00BB). Copy them, don't retype them.

---

## 0. TL;DR for the architect

1. **Settings are ~45 small key/value prefs in a handful of Android `SharedPreferences` files.** Only a subset is
   **per-bike** (namespaced as `"<key>#b<hex(javaHash(rawQr))>"` with fallback to the un-namespaced global
   key, then the default): video quality, screen fit, power mode, AA resolution/orientation, mirror orientation,
   AA DPI, match-aspect, **bike-profile override**, handlebar **Control-UI mode**, the **9-gesture button map**,
   the active **cluster preset** and **button presence**. Everything else (touch overrides, Wi-Fi transport,
   screen margins, map theme, button timing, auto-connect, …) is **global** — despite UI copy claiming otherwise
   (§2.1, §2.2). [V-CODE]
2. **Portable tuning pack** `{"format":"opencfmoto.settings","version":1,…}` (§3) is the cross-platform
   contract: the iOS app must be able to import Android packs and export packs Android accepts. Enum values are
   Kotlin enum **names** (`"BALANCED"`), most ids are lowercase (`"auto"`, `"knobBack"`). Import is lenient:
   unknown keys ignored, bad enum values skipped silently. [V-CODE]
3. **Garage** = JSON array `[{"raw":<exact QR string>,"name":…,"photo":<abs path>?}]`, most-recently-saved
   first, plus a separately stored selected raw. A bike's identity *is* its raw QR string (§4). [V-CODE]
4. **Trips**: GPS @ 1 Hz (min interval 1000 ms, min distance 0 m); "moving" ⇔ speed ≥ **0.8 m/s**; distance &
   moving time accumulate only for moving samples with **1 ≤ dt ≤ 5000 ms**; a leg auto-splits after
   **> 180 000 ms** without movement; a leg is saved only if **≥ 100 m AND ≥ 15 000 ms moving AND ≥ 2 points**.
   One JSON file per trip (`trips/<startMillis>.json`, points as `[lat,lon,timeMs,speedMs]`), GPX 1.1 export
   with lat/lon `%.6f` + UTC `<time>` (§5). [V-CODE]
5. **Auto-logging** runs while the dash is *streaming* or the *built-in map UI* is live, if
   *Log trips automatically* (default **on**) (§5.4). [V-CODE]
6. **Logs** are redacted **at write time** by four regexes (passwords → `«redacted»`, serials →
   first 4 chars + `…` + up to 8 `*`) unless *Include secrets in shared logs* is on (§6.2). [V-CODE]
7. **Home screen** = one big status card driven by an 11-value `Phase` enum, one Connect⇄Stop button, Scan /
   Map / Mirror tiles, Setup / Garage / Trip / Logs footer, a destination search field, and a tips card that
   flips to the live log (§7). On iOS drop the two Android-Auto phases and every AA setup step (§12).
8. **Telemetry** (default ON on Android, Cloudflare Worker) — recommend **not** implementing it on iOS (§6.7, §11).

---

## 1. App-level architecture & startup

### 1.1 Process-global state (Android) → iOS equivalents

| Android global | What it holds | iOS suggestion |
|---|---|---|
| `ConnectionState` (`ConnectionState.kt:29-58`) | current `Phase` + trailing `detail` string; one listener (Home) | `@Observable final class LinkStatus` (MainActor), published to SwiftUI |
| `LogBus` (`LogBus.kt:14-89`) | the in-memory log buffer + listener | existing `Log.shared` in `OpenCfMotoCore/Util/Log.swift` (see §6.1 deltas) |
| `BikeProfileHolder` (`BikeProfile.kt:219-283`) | active profile, override flags (touch, DPI, profile override) | `ActiveBikeContext` actor/struct snapshot handed to the link |
| `TripLogger` (`TripLogger.kt:10-19`) | the single shared `TripRecorder` | one `TripRecorder` owned by the app (shared by HUD, map, auto-log) |
| `BikeLink`, `AaVideoBridge`, `ProjectionHolder` | link/prober/encoder hand-off | link orchestrator (other specs) |

### 1.2 Process start sequence (`OpenCfMotoApp.kt:11-37`) [V-CODE]

1. `LogBus.includeSecrets = AppSettings.includeSecretsInLogs()` (:14).
2. `CrashGuard.install()` — uncaught-exception handler (:17).
3. `CrashGuard.hydrateLogBus()` — prepend last session log + previous crash into the log buffer (:18, §6.4).
4. `AppSettings.applyToHolder()` — copy prefs into globals (:20; `AppSettings.kt:153-167`): touch flags,
   DPI override, include-secrets, profile override, button-map migration (`ButtonMap.ensureDefaultsMigrated`),
   screen margins load, clock-lab knobs.
5. `LogBus.logSessionBanner()` (:24) — three lines (§6.1).
6. `AppHttp.init`, `AnonymousTelemetry.onAppStart` (:25-29), MapLibre init (:30-36).

### 1.3 Persistence overview (Android)

All prefs are `Context.MODE_PRIVATE` SharedPreferences (XML in the app sandbox). Files on disk live in
`filesDir` (persistent) or `cacheDir` (share staging). Android auto-backup is enabled with the default
(empty) rules (`AndroidManifest.xml:64-66`, `res/xml/backup_rules.xml`), i.e. everything — including bike
Wi-Fi passwords — may land in Google backup. [V-CODE]

| Store | Contents | Section |
|---|---|---|
| prefs `opencfmoto_bike` | app toggles, video prefs (per-bike), profile override (per-bike), garage list, learned panel sizes, map theme, `setup_seen` | §2, §4 |
| prefs `screen_margins` | `customised`, `top`, `bottom`, `left`, `right` | §2.6 |
| prefs `button_mode`, `button_map`, `button_cluster_preset`, `button_presence`, `opencfmoto_btn_timing`, `opencfmoto_remote_pad`, `saved_places` | handlebar input settings | §2.8 |
| prefs `opencfmoto_map`, `opencfmoto_map_places`, `opencfmoto_offline_areas`, `opencfmoto_map_packs` | map hub (other spec) | §2.2, §4.7 |
| prefs `updates`, `opencfmoto_telemetry`, `opencfmoto_phone_hotspot` | update check, telemetry ids, hotspot reminder | §6.6, §6.7 |
| `filesDir/trips/<id>.json` | one trip per file | §5.5 |
| `filesDir/bike_photos/<bikeId>.jpg` | garage photos | §4.4 |
| `filesDir/last_session.log`, `filesDir/last_crash.txt`, `filesDir/telemetry_queue.json` | crash/session capture, telemetry queue | §6.4, §6.7 |
| `cacheDir/{logs,settings,map-backup,trip-export}/` | staged share files (FileProvider) | `res/xml/file_paths.xml` |
| `externalFilesDir/video/*.h264` | optional H.264 dumps attached to Share Logs | §6.3 |

---

## 2. Settings

### 2.1 Per-bike scoping — `BikeScope` (`BikeScope.kt:20-62`) [V-CODE]

* **Bike id**: `"b" + Integer.toHexString(raw.hashCode())` where `raw` is the selected garage bike's exact QR
  string (`BikeScope.kt:23-26`). `hashCode` is **Java `String.hashCode`**: `h = 0; for each UTF-16 code unit c:
  h = 31*h + c` with 32-bit two's-complement wrap-around; `toHexString` prints the 32-bit value as **unsigned,
  lowercase, no leading zeros**.
* **Scoped key**: `"<baseKey>#<bikeId>"`, e.g. `video_quality#b58cde373`. No selected bike (empty garage) ⇒
  the plain `baseKey` is used (`BikeScope.kt:60-61`).
* **Read**: if a bike is selected **and** the scoped key exists → scoped value; else the **global (un-scoped)
  key**; else the call-site default (`BikeScope.kt:28-50`). So a freshly added bike inherits the global value
  (which is whatever the rider set before multi-bike support, or while no bike was selected).
* **Write**: always to the scoped key when a bike is selected (`BikeScope.kt:33-53`). **Remove** deletes only
  the scoped key, reverting to the global/default (`BikeScope.kt:56-58`).
* The selected bike = `BikeMemory.selected()` = explicitly selected raw, else the first (most recent) bike
  (`BikeMemory.kt:56-61`).

**Test vectors** (computed with Java's `String.hashCode` and cross-checked with a Swift port compiled with swiftc 6.0.3 — [INF] derived; the QR row is the doc's example QR with its line wrapping removed):

| raw | `hashCode` (signed Int32) | bike id |
|---|---|---|
| `http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457` (QR from `docs/01-REVERSE-ENGINEERING.md:27-29`) | `1489888115` | `b58cde373` |
| `http://manual.opencfmoto.local/?ssid=CFMOTO-123&pwd=pass%20word&auth=wpa2-psk&action=1&name=CFMOTO-123` | `1909166269` | `b71cb90bd` |
| `CARBIT0123456789AB` | `-1584102369` | `ba194841f` |
| `a` | `97` | `b61` |
| (empty string) | `0` | `b0` |

iOS does not need byte-identical ids (per-bike prefs never leave the device), but the **fallback semantics
(scoped → global → default)** must be reproduced. If you want parity, port the hash exactly (iterate
`raw.utf16`, `Int32` wrapping multiply/add, then `String(UInt32(bitPattern: h), radix: 16)`).

### 2.2 Master settings table [V-CODE unless tagged]

Scope: **bike** = through `BikeScope` (§2.1); **global** = plain key. "JSON" = included in the settings pack (§3).

| UI name (Setup section) | Store → key | Persisted type / allowed values | Default | Scope | What it affects | JSON | Source |
|---|---|---|---|---|---|---|---|
| Video quality (Screen & display) | `opencfmoto_bike` → `video_quality` | enum name `SMOOTH` \| `BALANCED` \| `SHARP` | `BALANCED` | bike | encoder bitrate × 0.7 / 1.0 / 1.6 of the profile's base (2 500 000 bit/s default) | `videoQuality` | `VideoPrefs.kt:16-20,115,133-144`; `BikeProfile.kt:112` |
| Screen fit | `opencfmoto_bike` → `screen_fit` | `FILL` \| `FIT` \| `STRETCH` | `FILL` | bike | placement of a fixed-size source (AA / mirror) into the dash canvas: crop / letterbox / distort | `screenFit` | `VideoPrefs.kt:30-34,116,146-153` |
| Mirror orientation | `opencfmoto_bike` → `mirror_orientation` | `MATCH_DASH` \| `FOLLOW` \| `LANDSCAPE` \| `PORTRAIT` | `MATCH_DASH` | bike | locks phone rotation while mirroring; MATCH_DASH = landscape if canvas/panel w ≥ h (fallback 800×480) | `mirrorOrientation` | `VideoPrefs.kt:97-102,119,174-211` |
| Battery & power | `opencfmoto_bike` → `power_mode` | `AUTO` \| `SMOOTH` \| `BALANCED` \| `SAVER` | `BALANCED` (code: *"Default stays BALANCED until AUTO has more on-bike soak"*) | bike | frame cap 30 / 30 / 24 / 20 fps; AUTO = adaptive fps+bitrate starting at 30 | `powerMode` | `VideoPrefs.kt:48-53,117,155-163` |
| Resolution & orientation [N/A-iOS] | `opencfmoto_bike` → `resolution_mode` | `AUTO` \| `LANDSCAPE_SD` (800×480 @160dpi) \| `LANDSCAPE_HD` (1280×720 @160) \| `PORTRAIT_SD` (720×1280 @240) \| `PORTRAIT_HD` (1080×1920 @240) | `AUTO` | bike | Android-Auto coded size | `resolutionMode` | `VideoPrefs.kt:67-73,118,165-172` |
| Android Auto text size (DPI) [N/A-iOS] | `opencfmoto_bike` → `aa_dpi_override` | Int; `0` = auto; UI offers 160/180/240/320 | `0` | bike | AA density only | `aaDpiOverride` | `VideoPrefs.kt:121,184-193`; `SetupActivity.kt:123-127` |
| Match panel aspect [N/A-iOS] | `opencfmoto_bike` → `match_aspect_mode` (+ legacy bool `match_aspect_on`) | `AUTO` \| `OFF` \| `MANUAL` | `AUTO` (legacy `match_aspect_on=true` ⇒ `MANUAL`) | bike | AAP margins | no | `VideoPrefs.kt:84-88,124-127,213-225` |
| Manual panel size [N/A-iOS] | `opencfmoto_bike` → `match_aspect_w`, `match_aspect_h` | Int, clamped 16…8192 on save | learned panel, else 800×951 | bike | AAP margins (MANUAL) | no | `VideoPrefs.kt:128,228-255` |
| Bike profile | `opencfmoto_bike` → `profile_override` | id `auto` \| `legacy` \| `nk800` \| `nk_adv` \| `cfdl26_land` \| `cfdl26_port` \| `clc450`; choosing `auto` **removes** the key | `auto` | bike | pins the dash profile (handshake, canvas, touch default, default margins) | `profileOverride` (also `bikeHint.profileOverride`) | `ProfileOverride.kt:13-61` |
| Disable touchscreen | `opencfmoto_bike` → `force_non_touch` | Boolean | `false` | **global** | advertises *no* touchscreen: AA focus/knob UI **and** omits `"supportScreenTouch":true` from the PXC CLIENT_INFO reply. Setting `true` also writes `force_touch=false` | `forceNonTouch` | `AppSettings.kt:26,53-60`; `BikeProfile.kt:278-283,552,623,796` |
| Force touchscreen | `opencfmoto_bike` → `force_touch` | Boolean | `false` | **global** | advertises a touchscreen (AA + CLIENT_INFO). Setting `true` writes `force_non_touch=false`. If both somehow true, non-touch wins at read time | `forceTouch` | `AppSettings.kt:27,62-69`; `BikeProfile.kt:278-283` |
| Map theme (Screen & display; also Controls, Dash view) | `opencfmoto_bike` → `map_theme` | `AUTO` \| `DAY` \| `NIGHT` | `AUTO` | **global** (README claims per-bike — wrong) | night flag for AA + own map: AUTO = phone dark mode **or** local hour < 7 or ≥ 19 | no (in map backup) | `NightPrefs.kt:16-69`; `README.md:288-290` |
| Screen margins… | `screen_margins` → `customised`, `top`, `bottom`, `left`, `right` | Boolean + 4 × Int 0…200 (px of the dash) | not customised ⇒ active profile's `defaultMargins` | **global** | black insets in the compositor (AA + mirror) | `screenMargins` | `ScreenMargins.kt:17-80` |
| Double-tap delay (Handlebar) | `opencfmoto_btn_timing` → `double_tap_ms` | Long ∈ {200, 300, 450, 1000} (ms) — other values read as 300 | `300` | global | window to detect ×2 | no | `ButtonTimingPrefs.kt:13-18,36,55-62` |
| Hold detection | `opencfmoto_btn_timing` → `holds_enabled` | Boolean | `true` | global | if false a press is never a hold | no | `ButtonTimingPrefs.kt:38,78-82` |
| Hold delay | `opencfmoto_btn_timing` → `long_press_ms` | Long ∈ {500, 600, 800} (ms) — other values read as 600 | `600` | global | hold threshold | no | `ButtonTimingPrefs.kt:25-28,37,64-71` |
| (no UI) snappy singles | `opencfmoto_btn_timing` → `snappy_singles` | Boolean | `true` | global | fire single immediately, ×2 still detected | no | `ButtonTimingPrefs.kt:39,49-53`; `MediaButtonBridge.kt:686-687` |
| Handlebar buttons drive the UI (Controls) | `button_mode` → `controlAa` | Boolean | `true` | bike | true = AVRCP keys drive the projected UI; false = keys control media normally | `controlAa` | `ButtonMode.kt:18-31` |
| Gesture → action map (Button mapping) | `button_map` → `<gestureId>` (9 keys) | action id (§2.8) | per-gesture default (§2.8) | bike | handlebar actions | `buttons` | `ButtonMap.kt:80-151` |
| (internal) map defaults version | `button_map` → `defaults_ver` | Int | `1` → migrated to `8` | global | one-shot default migration | no | `ButtonMap.kt:82-84,112-141` |
| Cluster preset (Button mapping) | `button_cluster_preset` → `active` | `five_way` \| `mode_ent` \| `back_set` \| absent | absent | bike | writes all 9 gestures; forces `controlAa=true` | no | `ButtonClusterPreset.kt:20-128` |
| Teach my handlebar | `button_presence` → `volume_rocker`, `track_keys` | `UNKNOWN` \| `PRESENT` \| `ABSENT` | `UNKNOWN` | bike | whether ▲/▼ volume is hijacked | no | `ButtonPresencePrefs.kt:17-86` |
| Bluetooth remote pad | `opencfmoto_remote_pad` → `remote_pad_on` | Boolean | `true` | global | HID gamepad keys stand in for gestures | `remotePad` | `RemotePad.kt:16-27` |
| Remote pad teach map | `opencfmoto_remote_pad` → `remote_pad_map` | `"<keyCode>=<gestureId>;…"` (Android KeyEvent codes) | absent | global | | no | `RemotePad.kt:18,101-117` |
| Saved places (3 slots) | `saved_places` → `name0..2`, `query0..2` | trimmed strings | `""` | global | NAV_1..NAV_3 actions | no | `SavedPlaces.kt:15-41` |
| Auto-connect on launch (Startup & recovery) | `opencfmoto_bike` → `auto_connect` | Boolean | `true` | global | §7.5.3 | no | `AppSettings.kt:23,41-43` |
| Connect when a Bluetooth device joins [N/A-iOS] | `opencfmoto_bike` → `bt_trigger_mac`, `bt_trigger_name` | String (blank/absent = off) | off | global | ACL-connect of that device ⇒ Connect | no | `AppSettings.kt:35-36,140-151`; `BtConnectTrigger.kt:17-41` |
| Auto-recovery watchdog | `opencfmoto_bike` → `auto_recovery` | Boolean | `true` | global | stall/ERROR re-arm + park/resume (§7.5.9) | no | `AppSettings.kt:24,45-47`; `AndroidAutoService.kt:134-154,165-195` |
| Log trips automatically | `opencfmoto_bike` → `log_trips` | Boolean | `true` | global | §5.4 | no | `AppSettings.kt:25,49-51` |
| Seamless auto-resume [N/A-iOS] | system "Display over other apps" permission (not a pref) | — | off | — | AA relaunch from background | no | `SetupHelper.kt:69` |
| Clock lab: QUERY_TIME [EXP] | `opencfmoto_bike` → `clock_lab_query` | `empty` \| `carbit` \| `zontes` \| `no_ack` | `empty` | global | reply to `0x10450` | no | `ClockLab.kt:11-22`; `AppSettings.kt:94-100` |
| Clock lab: TIME_SYNC [EXP] | `opencfmoto_bike` → `clock_lab_timesync` | `echo` \| `phone` | `echo` | global | reply to `0x10600` | no | `ClockLab.kt:24-33`; `AppSettings.kt:102-108` |
| Clock lab: Bluetooth listen [EXP] | `opencfmoto_bike` → `bluetooth_clock_sync` | Boolean | `false` | global | EC-BTP dash clock over BLE | no | `AppSettings.kt:87-92` |
| Clock lab: Stay on bike Wi-Fi after disconnect [EXP] | `opencfmoto_bike` → `keep_wifi_after_disconnect` | Boolean | `false` | global | keep association after Stop; never park | no | `AppSettings.kt:119-127`; `AndroidAutoService.kt:180-183` |
| Wi-Fi transport (Wi-Fi & logs) | `opencfmoto_bike` → `wifi_transport` | `auto` \| `ap` \| `p2p` (unknown → auto) | `auto` | global | AP vs Wi-Fi Direct choice (§7.5.4) | `wifiTransport` | `AppSettings.kt:29,78-81,170-181` |
| Anonymous usage & crash reports (Privacy) | `opencfmoto_bike` → `anonymous_telemetry` | Boolean | `true` | global | §6.7 | no | `AppSettings.kt:30,129-133` |
| Include secrets in shared logs | `opencfmoto_bike` → `include_secrets_in_logs` | Boolean | `false` | global | disables log redaction | no | `AppSettings.kt:28,71-76` |
| (first-run gate) | `opencfmoto_bike` → `setup_seen` | Boolean | `false` | global | first launch opens Setup | no | `SetupActivity.kt:747-755` |
| Map hub prefs (other spec) | `opencfmoto_map` → `units` (`METRIC`/`IMPERIAL`, def METRIC), `voice_prompts` (true), `show_next_stop` (true), `auto_finish_arrive` (true), `chrome` (`DARK`/`BLACK`/`SLATE`/`FOREST`, def DARK), `buildings_3d` (true), `ors_api_key` (""), `route_mode` (`FAST`/`FUN`, def FAST), `avoid_tolls` (false), `avoid_highways` (false), `fun_circuit_km` (60, clamp 20…150) | | | global | map | map backup | `MapPrefs.kt:8-166` |

Notes:
* **Units setting is ignored by trips**: the trip screens always show km and km/h (`TripActivity.kt:111-115`,
  `TripModel.kt:26-35`). [V-CODE]
* Most setters in Setup end with a toast suffixed **`" (applies next connect)"`** (`SetupActivity.kt:464-465`);
  map theme and button timing apply live (`SetupActivity.kt:337-356`). [V-CODE]

### 2.3 Enumerations (exact persisted values and labels)

Persisted values are the left column; English "label" is the in-code English used in logs; the localized UI text
comes from the `labelRes` string key (§9).

| Enum | Persisted | Numeric | Log label (EN) | UI string key | Source |
|---|---|---|---|---|---|
| VideoQuality | `SMOOTH` | ×0.7 | `Smoother — less data/latency` | `pref_vq_smooth` | `VideoPrefs.kt:17` |
| | `BALANCED` | ×1.0 | `Balanced (recommended)` | `pref_vq_balanced` | `VideoPrefs.kt:18` |
| | `SHARP` | ×1.6 | `Sharper — more data` | `pref_vq_sharp` | `VideoPrefs.kt:19` |
| ScreenFit | `FILL` | — | `Fill — edge to edge (crops a little)` | `pref_fit_fill` | `VideoPrefs.kt:31` |
| | `FIT` | — | `Fit — no cropping (black bars)` | `pref_fit_fit` | `VideoPrefs.kt:32` |
| | `STRETCH` | — | `Stretch — fills, slight distortion` | `pref_fit_stretch` | `VideoPrefs.kt:33` |
| PowerMode | `AUTO` | 30 fps start | `Auto — adapts to heat & signal` | `pref_power_auto` | `VideoPrefs.kt:49` |
| | `SMOOTH` | 30 fps | `Smooth — 30 fps (most battery)` | `pref_power_smooth` | `VideoPrefs.kt:50` |
| | `BALANCED` | 24 fps | `Balanced — 24 fps (recommended)` | `pref_power_balanced` | `VideoPrefs.kt:51` |
| | `SAVER` | 20 fps | `Battery saver — 20 fps (coolest)` | `pref_power_saver` | `VideoPrefs.kt:52` |
| ResolutionMode | `AUTO`, `LANDSCAPE_SD`, `LANDSCAPE_HD`, `PORTRAIT_SD`, `PORTRAIT_HD` | see §2.2 | `Auto — match your bike (recommended)`, `Landscape · 800×480`, `Landscape · 1280×720 (HD)`, `Portrait · 720×1280`, `Portrait · 1080×1920 (HD)` | `pref_res_*` | `VideoPrefs.kt:67-73` |
| MirrorOrientation | `MATCH_DASH`, `FOLLOW`, `LANDSCAPE`, `PORTRAIT` | — | `Match dash (recommended)`, `Follow phone`, `Landscape`, `Portrait` | `pref_mirror_orient_*` | `VideoPrefs.kt:97-102` |
| MatchAspectMode | `AUTO`, `OFF`, `MANUAL` | — | `Auto — from bike screen`, `Off`, `Manual size` | (none) | `VideoPrefs.kt:84-88` |
| MapTheme | `AUTO`, `DAY`, `NIGHT` | — | `Auto (day / night)`, `Day (light)`, `Night (dark)` | `setup_auto_day_night`, `pref_map_theme_day`, `pref_map_theme_night` | `NightPrefs.kt:16-20` |
| DoubleTapDelay | stored as ms 200/300/450/1000 (`FAST`/`NORMAL`/`SLOW`/`VERY_SLOW`) | ms | `200 ms — snappier singles`, `300 ms — balanced (recommended)`, `450 ms — forgiving doubles`, `1000 ms — slow doubles (long physical press)` | `pref_dbltap_*` | `ButtonTimingPrefs.kt:13-18` |
| LongPressDelay | stored as ms 500/600/800 (`SHORT`/`NORMAL`/`LONG`) | ms | `500 ms — quicker hold`, `600 ms — balanced (recommended)`, `800 ms — deliberate hold` | `pref_hold_*` | `ButtonTimingPrefs.kt:25-28` |
| WifiTransport | `auto`, `ap`, `p2p` | — | `Auto (from QR)`, `Force Wi‑Fi AP`, `Force Wi‑Fi Direct` | (label shown verbatim) | `AppSettings.kt:171-181` |
| ProfileOverride | `auto`, `legacy`, `nk800`, `nk_adv`, `cfdl26_land`, `cfdl26_port`, `clc450` | — | short labels `Auto`, `Legacy`, `800NK`, `800NK Adv`, `800MT`, `1000 MT-X`, `CL‑C450` | `pref_profile_*` | `ProfileOverride.kt:13-21` |
| ClockQueryMode [EXP] | `empty`, `carbit`, `zontes`, `no_ack` | — | — | `setup_clock_lab_query_*` | `ClockLab.kt:11-22` |
| ClockTimeSyncMode [EXP] | `echo`, `phone` | — | — | `setup_clock_lab_timesync_*` | `ClockLab.kt:24-33` |
| ClockLabPreset [EXP] | `LATEST`(empty+echo+BT off), `V2012`(carbit+echo), `ZONTES`(zontes+echo), `PHONE_SYNC`(empty+phone), `BT_LISTEN`(empty+echo+BT on) | — | — | `setup_clock_lab_preset_*` | `ClockLab.kt:35-84` |
| ButtonPresence | `UNKNOWN`, `PRESENT`, `ABSENT` | — | `untested` / `works` / `absent` | — | `ButtonPresencePrefs.kt:17-20,65-72` |

Profile → *ProfileOverride* resolution: `legacy`→`LegacyCfdl16Profile`, `nk800`→`Nk800Profile`,
`nk_adv`→`Cfdl26NkTouchProfile`, `cfdl26_land`→`Cfdl26LandscapeProfile`, `cfdl26_port`→`Cfdl26PortraitProfile`,
`clc450`→`ClC450Profile` (`ProfileOverride.kt:23-31`). Profile display names (used as `bikeHint.profile` in §3)
are in §3.2.

### 2.4 Coupled settings and side effects [V-CODE]

* **Touch overrides are mutually exclusive** (`AppSettings.kt:54-69`): writing `force_non_touch=true` also writes
  `force_touch=false` (and vice-versa). Writing `false` touches only its own key. Effective value:
  `forceNonTouch → false; else forceTouch → true; else profile.supportsScreenTouch` (`BikeProfile.kt:278-283`).
  Profile touch defaults: CFDL26 800NK Advanced = touch, CFDL26 800MT landscape = touch, all others non-touch
  (`BikeProfile.kt:409,463,517,594,635,663,706,754`).
* **Clock lab preset** buttons only fill the three knobs (query, timeSync, bluetooth); the highlighted preset is
  *derived* (`ClockLab.matchingPreset()`, `ClockLab.kt:72-84`) — no preset is stored.
* **Cluster preset apply** (`ButtonClusterPreset.kt:76-91`): reset the selected bike's map, write all 9 gestures,
  store the preset id, and if `controlAa` was false set it true (does not touch the touch overrides).
* **Profile override `auto`** deletes the per-bike key instead of storing `"auto"` (`ProfileOverride.kt:49-56`),
  so a bike reverts to the *global* override if one exists. [INF] (a global value only exists if set while no bike was selected)
* **Screen margins reset** sets `customised=false` (keeps old edge values on disk) → profile defaults apply
  (`ScreenMargins.kt:68-73`). Legacy files without `customised` are treated as customised iff any edge key
  exists (`ScreenMargins.kt:36-51`).
* **Button-map migration** (`ButtonMap.kt:112-141`): on first access with `defaults_ver < 8` stored values equal
  to *old* defaults are deleted so new defaults apply: navBackDouble=`home`, navFwdDouble=`back`,
  selectDouble=`assistant`, swapped back/fwd knob pair, selectLong=`assistant`, navFwdLong=`back`,
  navBackLong=`assistant`, navBack=`up`, navFwd=`down`, navBackLong=`up`, navFwdLong=`down`,
  navBackDouble=`up`, navFwdDouble=`down`. iOS starts at "version 8" — no migration needed. Note that Android's
  import writes pack values verbatim without re-running this migration (§3.4), so an old pack can re-introduce an
  old default; harmless, and iOS should behave the same (no migration on import).

### 2.5 Learned / internal state (not user settings) [V-CODE]

| Store → key | Value | Meaning | Source |
|---|---|---|---|
| `opencfmoto_bike` → `bikes_json` | JSON array (§4.1) | garage | `BikeMemory.kt:27,132-140` |
| `opencfmoto_bike` → `selected_raw` | raw QR string | active bike | `BikeMemory.kt:28,74,77-79` |
| `opencfmoto_bike` → `last_qr_raw`, `last_bike_name` | legacy single-bike keys, migrated once | | `BikeMemory.kt:31-32,143-154` |
| `opencfmoto_bike` → `transport_<ssid>` | `"AP"` \| `"P2P"` | transport that last produced a live link for that SSID (refines AUTO only) | `BikeMemory.kt:35,113-124`; `MainActivity.kt:1054-1062` |
| `opencfmoto_bike` → `dash_geo_<ssid>` | `"<w>x<h>"`, accepted if 1…8192 each | canvas size the dash requested (REQ_CONFIG_CAPTURE) | `DashMemory.kt:16,31-52` |
| `opencfmoto_bike` → `last_dash_touch` | Boolean | last advertised touch state | `DashMemory.kt:17,22-29` |
| `updates` → `lastCheckMs`, `skippedVersion` | Long ms / String | update checker | `UpdateChecker.kt:21-23` |
| `opencfmoto_telemetry` → `anon_uuid`, `last_ping_ms`, `crash_fingerprint_sent` | UUID / Long / String | telemetry | `AnonymousTelemetry.kt:26-29` |
| `opencfmoto_phone_hotspot` → `dash_hotspot_ssid`, `dash_hotspot_pwd` | Strings | reminder for phone-hotspot dashes (password **plaintext**) | `PhoneHotspotAssist.kt:27-45` |

### 2.6 Screen margins page (`ScreenMarginsActivity.kt`, `ScreenMargins.kt`) [V-CODE]

* Four sliders Top/Bottom/Left/Right, range **0…200** (`ScreenMargins.MAX = 200`, `ScreenMargins.kt:19`,
  `ScreenMarginsActivity.kt:52`). Each change (while dragging and on release) persists **all four** values and sets
  `customised=true` (`ScreenMarginsActivity.kt:55-75`, `ScreenMargins.kt:53-65`); applied live to the running
  compositor (`ScreenMargins.kt:64`).
* "Reset to profile default" → `customised=false` → shows profile defaults (`ScreenMarginsActivity.kt:41-45`).
* Profile defaults `[top, bottom, left, right]`: **800NK Advanced (CFDL26 touch 720×712): `[22,0,0,0]`**; all
  others `[0,0,0,0]` (`BikeProfile.kt:131,598`). Purpose: blank MotoPlay's pull-down handle so it doesn't steal
  swipes (`res/values/strings.xml` key `margins_inset_android_auto_from_each_edge_of_the_dash_pi`). [V-HW per
  `docs/SUPPORTED-BIKES.md:47`]
* Summary line: none → `margins_summary_none`; not customised → `margins_summary_profile_default`; else
  `margins_summary_custom` (`ScreenMarginsActivity.kt:93-111`). English-only twin for diagnostics:
  `ScreenMargins.summary()` (`ScreenMargins.kt:75-79`).
* Android applies margins only in the AA/mirror compositor, **not** to the own-UI map path (see
  `media-video.md` §10.4). On iOS treat margins as **safe-area insets for the dash UI** *and* as compositor insets
  for mirror mode (recommendation, [INF]).

### 2.7 Match-panel-aspect page (`CustomResolutionActivity.kt`) [N/A-iOS]

Android-Auto-only (AAP `marginWidth/marginHeight`). Modes Auto/Off/Manual, manual W×H fields shown only in
Manual; Save writes mode + clamped size; notes use `res_*` strings (`CustomResolutionActivity.kt:38-134`). On iOS
the dash UI is rendered natively at the negotiated canvas size, so there is nothing to reflow. Keep the keys only
if you want to round-trip them (they are **not** in the settings JSON anyway).

### 2.8 Handlebar mapping data (settings payload only; behaviour is in the input spec) [V-CODE]

Actions (`ButtonMap.kt:13-27`) — `id` (persisted) → meaning: `none` Do nothing · `knobFwd` Knob forward (next
item) · `knobBack` Knob back (previous item) · `select` Select / OK · `back` Back · `home` Home (app list) ·
`assistant` Assistant (voice) · `up`/`down`/`left`/`right` D-pad · `nav1`/`nav2`/`nav3` Navigate to saved place 1/2/3.

Gestures (`ButtonMap.kt:58-74`) — `id` → default action:

| Gesture id | Label | Default |
|---|---|---|
| `navBack` | `Backward  ◀ / ▲` | `knobBack` |
| `navFwd` | `Forward  ▶ / ▼` | `knobFwd` |
| `selectPress` | `Select  Enter / ★` | `select` |
| `navBackLong` | `Backward (hold)  ◀` | `none` |
| `navFwdLong` | `Forward (hold)  ▶` | `none` |
| `selectLong` | `Select (hold)  Enter / ★` | `home` |
| `navBackDouble` | `Backward ×2` | `left` |
| `navFwdDouble` | `Forward ×2` | `right` |
| `selectDouble` | `Select ×2` | `back` |

Cluster presets (`ButtonClusterPreset.kt:30-74`): `five_way` and `mode_ent` = all defaults; `back_set` = navBack
knobBack, navFwd knobFwd, selectPress select, all three holds `none`, selectDouble `none`, navBackDouble **`back`**,
navFwdDouble **`home`**. All presets have `instantSingles=true`.

Saved places: 3 slots, `name<slot>` + `query<slot>` (address, place name or `lat,lng`), slot is set iff query is
non-blank; picker label `Navigate to saved place N (not set yet)` / `Navigate: <name or query>`
(`SavedPlaces.kt:15-41`). On iOS the query should be resolved by our own geocoder/router (map spec).

### 2.9 iOS applicability matrix (recommendation [INF])

| Setting | iOS meaning |
|---|---|
| Video quality, Power mode | bitrate multiplier and fps cap for the VideoToolbox encoder (`media-video.md` §8) |
| Screen fit | **mirror (ReplayKit) mode only** — own dash UI is drawn at canvas size |
| Mirror orientation | not enforceable for system-wide ReplayKit capture → keep value for round-trip only |
| Resolution mode, AA DPI, match-aspect | Android-Auto only → keep for round-trip only |
| Bike profile override | yes (handshake/canvas/touch defaults) |
| Disable / Force touchscreen | yes: controls `supportScreenTouch` in CLIENT_INFO and whether dash touches drive our UI |
| Screen margins | yes (safe-area insets of the dash UI + mirror insets) |
| Map theme | yes (dash UI day/night) |
| Button timing / map / presets / presence / saved places | yes (AVRCP handlebar → our dash UI; `assistant` → Siri is not invokable by apps: map to no-op or our own voice search) |
| Remote pad | optional (GameController framework, foreground only) |
| Auto-connect, auto-recovery, log trips | yes (semantics adapted, §7.5) |
| Wi-Fi transport | iOS can only join as a Wi-Fi client (NEHotspotConfiguration). `DIRECT-*` dashes are joinable as normal WPA2 networks (Android needed no change for P2P either, `docs/01-REVERSE-ENGINEERING.md:207-211` [V-HW]). Treat `p2p` as unsupported/AP; keep value for round-trip |
| Clock lab | protocol replies → yes if the protocol spec implements them; BLE listen = CoreBluetooth (other spec) |
| Keep Wi-Fi after disconnect | maps to "don't call `removeConfiguration` on Stop" |
| Telemetry | do not implement (§6.7) |
| Include secrets | yes |
| BT trigger, seamless resume, AA setup steps | no |

### 2.10 Apple Music on the dash (iOS addition, no Android counterpart)

Settings ▸ **Apple Music on the dash** (after Map & navigation): one global toggle **Show Apple Music
on the dash** (KeyValueStore `ios.dash_music`, default **off**; not per bike and not part of the
`opencfmoto.settings` pack). Turning it on is the only place the "Media & Apple Music" permission is
asked (an explicit phone action — never from the dash or during a ride); when access is denied or
restricted the section says "Access to Media & Apple Music is off" with an **Open Settings** button,
and an access granted later in iOS Settings is picked up when the app becomes active (no relaunch).
When the toggle is on but iOS never asked (Reset Location & Privacy, the app closed while the prompt
was up), the section says "OpenCfMoto needs access to Media & Apple Music to show the song." with an
**Allow access to Media & Apple Music** button that shows the system prompt (iOS lists the switch in
its own Settings only after an app asked).
The toggle is disabled where there is no system music player. Only the system Music app (Apple Music
and the music library) can be shown: iOS gives apps no access to what other players play. The
Permissions section lists **Apple Music** (Allowed / Denied / Not asked yet / Restricted / Not
available) and the Controls ▸ Phone media remote footer says that starting Apple Music from the dash
gives the handlebar buttons to the music until it is paused. What the dash shows and the handlebar
hand-over: `navigation-dash.md` §15 and `input-controls.md` §10 item 15. Nothing is sent anywhere:
titles, artists, albums and song ids stay on the phone and never reach logs or problem reports — a
log line names a song by a token keyed per app run (`track=s1a2b3c4d`), and the report carries
`music=on/authorized/playing/art=mp`; the artwork of streamed songs is loaded by Apple's MusicKit
from Apple.

---

## 3. Portable settings pack — `opencfmoto.settings` v1 (`SettingsBackup.kt`)

Purpose: "Portable bike-tuning pack for Discord / friends" — profile, resolution, fit, margins, handlebar mapping,
transport. **Never** QR passwords, serials, SSID, bike name or photos; skips personal prefs (map theme, saved places,
auto-connect, trip logging, tap timing) (`SettingsBackup.kt:12-20`). [V-CODE]

### 3.1 Template — exact construction order (`SettingsBackup.kt:27-75`) [V-CODE]

```
root (JSONObject, keys in this insertion order)
  "format"      : "opencfmoto.settings"                       (String)  :29
  "version"     : 1                                            (Int)     :30
  "exportedAt"  : SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US) in device TZ   :31, :175-176
  "appVersion"  : "2.0.18"                                     (BuildConfig.VERSION_NAME) :32
  "bikeHint"    : {                                                                       :35-40
      "profile"         : <BikeProfileHolder.active.name>      (display name of the profile active in this process)
      "profileOverride" : <ProfilePrefs id: "auto"|"legacy"|…> }
  "settings"    : {                                                                       :42-73
      "videoQuality"      : "SMOOTH"|"BALANCED"|"SHARP"
      "screenFit"         : "FILL"|"FIT"|"STRETCH"
      "mirrorOrientation" : "MATCH_DASH"|"FOLLOW"|"LANDSCAPE"|"PORTRAIT"
      "powerMode"         : "AUTO"|"SMOOTH"|"BALANCED"|"SAVER"
      "resolutionMode"    : "AUTO"|"LANDSCAPE_SD"|"LANDSCAPE_HD"|"PORTRAIT_SD"|"PORTRAIT_HD"
      "aaDpiOverride"     : <Int, 0 = auto>
      "remotePad"         : <Boolean>
      "profileOverride"   : "auto"|"legacy"|"nk800"|"nk_adv"|"cfdl26_land"|"cfdl26_port"|"clc450"
      "controlAa"         : <Boolean>
      "forceNonTouch"     : <Boolean>
      "forceTouch"        : <Boolean>
      "wifiTransport"     : "auto"|"ap"|"p2p"
      "screenMargins"     : { "customised": <Boolean>,
                              "top": <Int>, "bottom": <Int>, "left": <Int>, "right": <Int> }   (edges are 0 when not customised)
      "buttons"           : { "navBack": <actionId>, "navFwd": …, "selectPress": …,
                              "navBackLong": …, "navFwdLong": …, "selectLong": …,
                              "navBackDouble": …, "navFwdDouble": …, "selectDouble": … }  (ButtonGesture order)
  }
serialized with JSONObject.toString(2)
```

Values are read through the per-bike accessors, i.e. **the export describes the currently selected garage bike**
(scoped value, else global, else default) — except the global ones (touch, transport, margins, remote pad).

### 3.2 Serialization details (Android's AOSP `org.json`) [V-CODE + INF for library behaviour]

* `toString(2)`: 2-space indent, `"key": value` (colon + one space), one key per line, nested objects indented,
  **no trailing newline**; key order = insertion order (AOSP `JSONObject` is a `LinkedHashMap`).
* Strings: `"` `\` and **`/` are escaped** (`/` → `\/`); control chars as `\uXXXX`; non-ASCII emitted raw (UTF-8
  file, `SetupActivity.kt:225`). Any JSON parser handles `\/`.
* Integers plain; Booleans `true`/`false`.
* `exportedAt` uses pattern `XXX` ⇒ `Z` for UTC, otherwise `+01:00` style.
* `bikeHint.profile` possible values (`BikeProfile.kt:407,461,515,592,633,661,693,704,752`):
  `CFDL16 / legacy (BIKE A)` (also the value when nothing connected yet in this process, since the holder starts on
  the legacy profile, `BikeProfile.kt:220`), `CFMoto 800NK (CRCP / sdk 0.9.23.x)`,
  `CFDL26 / MotoPlay Portrait (1000 MT-X)`, `CFDL26 / 800NK Advanced (touch, 720×712)`,
  `CFDL16 / MotoPlay Landscape (modelId 66660742)`, `CL‑C450 (544×512)`, `Morini SoftAP / Alltrhike (MLN)`,
  `CFDL26 / MotoPlay Landscape (800MT)`, or `"<base name> + measured <w>x<h>"` (learned-panel wrapper).
  **Quirk:** it reflects the profile active *in this process*, not necessarily the selected bike's. [V-CODE]

### 3.3 Example files [INF — derived from the code; formatting per §3.2]

(a) Fresh install, 800NK Advanced connected once this session, everything default:

```json
{
  "format": "opencfmoto.settings",
  "version": 1,
  "exportedAt": "2026-10-31T15:42:07+01:00",
  "appVersion": "2.0.18",
  "bikeHint": {
    "profile": "CFDL26 \/ 800NK Advanced (touch, 720×712)",
    "profileOverride": "auto"
  },
  "settings": {
    "videoQuality": "BALANCED",
    "screenFit": "FILL",
    "mirrorOrientation": "MATCH_DASH",
    "powerMode": "BALANCED",
    "resolutionMode": "AUTO",
    "aaDpiOverride": 0,
    "remotePad": true,
    "profileOverride": "auto",
    "controlAa": true,
    "forceNonTouch": false,
    "forceTouch": false,
    "wifiTransport": "auto",
    "screenMargins": {
      "customised": false,
      "top": 0,
      "bottom": 0,
      "left": 0,
      "right": 0
    },
    "buttons": {
      "navBack": "knobBack",
      "navFwd": "knobFwd",
      "selectPress": "select",
      "navBackLong": "none",
      "navFwdLong": "none",
      "selectLong": "home",
      "navBackDouble": "left",
      "navFwdDouble": "right",
      "selectDouble": "back"
    }
  }
}
```

Note `screenMargins` exports zeros when not customised even though the 800NK Advanced *effective* top margin is
22 — on import `customised:false` resets to that profile default, so the result is still 22. [V-CODE]

(b) A tuned 1000 MT-X pack (BACK/SET preset, forced portrait profile, custom margins):

```json
{
  "format": "opencfmoto.settings",
  "version": 1,
  "exportedAt": "2026-10-31T09:05:11Z",
  "appVersion": "2.0.18",
  "bikeHint": {
    "profile": "CFDL26 \/ MotoPlay Portrait (1000 MT-X)",
    "profileOverride": "cfdl26_port"
  },
  "settings": {
    "videoQuality": "SHARP",
    "screenFit": "FIT",
    "mirrorOrientation": "MATCH_DASH",
    "powerMode": "AUTO",
    "resolutionMode": "PORTRAIT_SD",
    "aaDpiOverride": 240,
    "remotePad": true,
    "profileOverride": "cfdl26_port",
    "controlAa": true,
    "forceNonTouch": false,
    "forceTouch": true,
    "wifiTransport": "ap",
    "screenMargins": {
      "customised": true,
      "top": 12,
      "bottom": 0,
      "left": 4,
      "right": 4
    },
    "buttons": {
      "navBack": "knobBack",
      "navFwd": "knobFwd",
      "selectPress": "select",
      "navBackLong": "none",
      "navFwdLong": "none",
      "selectLong": "none",
      "navBackDouble": "back",
      "navFwdDouble": "home",
      "selectDouble": "none"
    }
  }
}
```

### 3.4 Import algorithm (`SettingsBackup.kt:77-107,119-173`) [V-CODE]

1. `text.trim()`, then strip one leading U+FEFF BOM, then parse as a JSON **object** → else fail
   `Not valid JSON: <parser message>`.
2. `format = optString("format","")`; must equal `opencfmoto.settings` → else
   `Not an OpenCfMoto settings file (format=<format>)`.
3. `version = optInt("version",0)` (strings like `"1"` and doubles are coerced); must be `1 ≤ v ≤ 1` → else
   `Unsupported settings version <v> (this app reads 1…1)`.
4. `settings` must be an object → else `Missing settings object`.
5. Apply, **in this order**, each only if present (`has()` for primitives; non-blank for enums):
   1. `videoQuality`, `screenFit`, `mirrorOrientation`, `powerMode`, `resolutionMode` — `Enum.valueOf(string)`;
      **invalid names are silently skipped** (wrapped in `runCatching`), exact-case match required.
   2. `aaDpiOverride` — `optInt(…,0)`; `> 0` stored, else auto.
   3. `remotePad` — `optBoolean` (accepts `true`/`false` or the strings `"true"`/`"false"`; anything else → false).
   4. `profileOverride` — `byId(optString)`; unknown → `auto` (i.e. **an unknown id resets the override**).
   5. `controlAa`, then `forceNonTouch`, then `forceTouch` (so if both touch flags are true the **later
      `forceTouch` wins**; `forceNonTouch:true, forceTouch:false` ⇒ non-touch).
   6. `wifiTransport` — `byId`, unknown → `auto`.
   7. `screenMargins` (object): `customised` true ⇒ set top/bottom/left/right via `optInt` (missing → 0), clamped
      0…200; otherwise reset to profile default.
   8. `buttons` (object): for each of the 9 gesture ids present, `ButtonAction.byId(value)`; **unknown action ids are
      skipped** (the gesture keeps its current value).
   9. Older packs may contain personal prefs — ignored on purpose; then re-sync globals.
   Any exception during apply → `Import failed: <message>`.
6. Success message: profile = `bikeHint.profile` if non-blank and ≠ `"null"`, else `bikeHint.profileOverride`
   (same rule); `onto` = selected bike name or `selected bike`:
   `Imported bike tuning (<profile>) onto <onto>` or `Bike tuning imported onto <onto>`.

Per-bike values are written to the **currently selected garage bike**; global ones change for all bikes.

### 3.5 Share / import UX (`SetupActivity.kt:206-273`) [V-CODE]

* **Share JSON**: write `cacheDir/settings/OpenCfMoto-<slug>-settings.json` (slug = profile-override id, `auto`
  when AUTO; `SettingsBackup.kt:110-117`), UTF-8; share sheet MIME `application/json`; subject
  `OpenCfMoto bike tuning — <shortLabel>`; text
  `OpenCfMoto bike tuning (<shortLabel>) — profile / resolution / margins / buttons (no passwords, no bike name/SSID).\nImport via Setup → Wi‑Fi & logs → Import…`;
  chooser title `Share settings JSON`; failure toast `Share failed: <e>`.
* **Import…**: document picker with MIME filters `application/json`, `text/*`, `*/*`; read all bytes as UTF-8;
  blank → toast `Empty file`; confirm dialog **title** `Import settings?` **message**
  `Replace bike tuning for <onto> — profile, resolution, fit, power, margins, handlebar buttons, Control AA, non-touch, Wi‑Fi transport?\n\nPersonal prefs (map theme, saved places, auto-connect, …) are left alone. Wi‑Fi passwords are never imported.`
  (`<onto>` = bike name or `the selected bike`), buttons Cancel / `Import`; result toast = §3.4 message; read
  errors → `Import failed: <e>`.

### 3.6 Repository test vectors (`test/SettingsBackupTest.kt:10-32`) [V-CODE]

* `FORMAT == "opencfmoto.settings"`, `VERSION == 1`.
* Every `ButtonAction` round-trips through its id; every gesture's default action round-trips.
* Every `ProfileOverride` round-trips through its id; `byId("cfdl26_land") == CFDL26_LAND`.

### 3.7 iOS compatibility rules (recommendation [INF])

1. **Import**: implement §3.4 exactly (same validation, ordering, leniency, messages localized).
2. **Export**: emit the same keys with the same value domains, `format`/`version` unchanged. Write `appVersion` as the
   iOS version string; `bikeHint.profile` = the Android display name of the equivalent profile (keep a mapping) so
   Android shows a sensible message.
3. **Round-trip Android-only knobs** (`resolutionMode`, `aaDpiOverride`, `mirrorOrientation`, `screenFit` if unused):
   persist whatever was imported (or the Android default) and export it back unchanged, so iOS→Android doesn't
   destroy Android tuning.
4. Extra iOS-only keys are safe: Android ignores unknown root and `settings` keys (only named keys are read). Prefer
   adding them inside `settings` with an `ios` prefix (e.g. `"iosDashLayout"`). Do **not** bump `version` (Android
   rejects `version > 1`).
5. Serialize with `JSONSerialization` / `JSONEncoder` (`.prettyPrinted`, key order is not significant for Android);
   escaping `/` or not is irrelevant.
6. Register a document type for `.json` import via the Files app / share sheet ("Open in OpenCfMoto").

### 3.8 Sibling format — map data backup `opencfmoto.map` v1 (`MapDataBackup.kt`) [V-CODE]

Kept separate from bike tuning; exported from the Map hub (`GpxActivity.kt:566-574`), filename
`OpenCfMoto-map-<yyyyMMdd>.json`, MIME `application/json`. Template (`MapDataBackup.kt:23-50`):

```
{ "format": "opencfmoto.map", "version": 1, "exportedAt": <yyyy-MM-dd'T'HH:mm:ssXXX>, "appVersion": <String>,
  "prefs": { "units": "METRIC"|"IMPERIAL", "voicePrompts": Bool, "showNextStop": Bool, "autoFinishArrive": Bool,
             "chrome": "DARK"|"BLACK"|"SLATE"|"FOREST", "buildings3d": Bool, "mapTheme": "AUTO"|"DAY"|"NIGHT",
             "routeMode": "FAST"|"FUN", "avoidTolls": Bool, "avoidHighways": Bool, "funCircuitKm": Int },
  "favorites": [Place…], "markers": [Place…], "history": [Place…],
  "parked": Place   (only if set), "home": Place   (only if set) }
Place = { "name": String, "lat": Double, "lon": Double, "category": String, "subtitle": String }
```

Import: same BOM/trim/format/version checks (`Not an OpenCfMoto map file`, `Unsupported map backup version <v>`),
prefs applied leniently, then lists **replaced** and truncated to favorites 100, markers 50, history 30
(`MapPlaces.kt:89-102`); places without numeric `lat`/`lon` are dropped; success `Map data imported`. The ORS API
key is deliberately **not** exported. (Details belong to the map spec; listed here because it is the second
cross-platform file format.)

---

## 4. Garage (multiple bikes)

### 4.1 Data model (`BikeMemory.kt`) [V-CODE]

```kotlin
data class SavedBike(val raw: String, val name: String, val photoPath: String? = null)   // BikeMemory.kt:11
```

* `raw` — the **exact scanned QR string** (or the synthetic manual URL, §4.3). It is the bike's identity, the
  reconnect source (re-parsed on every connect so a reconnect is byte-identical to a fresh scan) and the per-bike
  settings key source (§2.1). Pairing semantics of the QR belong to the pairing spec.
* `name` — user-editable display name; on first save `qr.name` if non-blank, else `qr.ssid` (`BikeMemory.kt:156-157`).
* `photoPath` — absolute path of an app-private JPEG, or absent.

Stored as `opencfmoto_bike` → `bikes_json` (compact JSON array, most-recently-saved first):

```json
[{"raw":"http:\/\/www.carbit.com.cn\/downsdk\/657\/658\/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457","name":"CFMOTO-f46457","photo":"\/data\/user\/0\/dev.zanderp.opencfmoto\/files\/bike_photos\/b58cde373.jpg"},{"raw":"http:\/\/manual.opencfmoto.local\/?ssid=TRK702X-1A2B&pwd=12345678&auth=wpa2-psk&action=1&name=My%20TRK","name":"My TRK"}]
```

(`"photo"` omitted when null, `BikeMemory.kt:132-140`; `/` escaped by AOSP org.json.) Read rules
(`BikeMemory.kt:41-53`): entries with blank `raw` are skipped; blank `name` → `raw`; blank `photo` → none; an
unparsable array → empty garage. The **raw QR contains the Wi-Fi password in plaintext**
(`PRIVACY.md:67`). [V-CODE]

### 4.2 Operations & semantics [V-CODE]

| Operation | Behaviour | Source |
|---|---|---|
| `devices()` | migrate legacy single bike once, then parse list | `BikeMemory.kt:41-53,143-154` |
| `selected()` | bike whose raw == `selected_raw`, else **first** bike, else none | `BikeMemory.kt:56-61` |
| `save(raw, qr)` (after every successful scan / manual add / Home scan) | move-to-front (or insert at front), **keep** existing custom name & photo, set `selected_raw = raw` | `BikeMemory.kt:65-75`; `MainActivity.kt:91`; `GarageActivity.kt:53,89` |
| `select(raw)` | only writes `selected_raw` (no reordering) | `BikeMemory.kt:77-79` |
| `rename(raw, name)` | `trim()`; blank ⇒ no change | `BikeMemory.kt:82-87` |
| `setPhoto(raw, path?)` | set or clear | `BikeMemory.kt:90-92` |
| `remove(raw)` | drop from list; clear `selected_raw` if it pointed there (selection falls back to first) | `BikeMemory.kt:94-99` |
| `clear()` | remove list, selection, legacy keys | `BikeMemory.kt:101-106` |
| `winningTransport(ssid)` / `setWinningTransport` | per-SSID `"AP"`/`"P2P"` memory | `BikeMemory.kt:113-124` |

**Discrepancy:** the remove dialog says it "forgets its pairing, photo and settings", but Android leaves the
per-bike scoped settings (`*#b<id>` keys), `transport_<ssid>` and `dash_geo_<ssid>` behind (`GarageActivity.kt:231`
vs `BikeMemory.kt:94-99`). On iOS, delete them for real. [V-CODE]

### 4.3 Manual Wi-Fi pairing (no QR, e.g. Benelli TRK) [V-CODE]

Dialog (`ManualWifiPairing.kt:20-82`): title `Enter bike Wi‑Fi`, message
`For dashes that show SSID + password instead of a QR (e.g. Benelli TRK). Use the exact network name from the bike screen.`,
fields `Wi‑Fi name (SSID)`, `Password` (masked), `Bike name (optional)`; buttons `Add bike` / `Cancel`; empty
SSID or password → toast `SSID and password are required` (dialog stays open).

Synthetic raw (`QrData.kt:275-293`): SSID trimmed, password **not** trimmed (internal spaces kept), name =
trimmed display name or SSID, built with Android `Uri.Builder`:

```
http://manual.opencfmoto.local/?ssid=<enc(ssid)>&pwd=<enc(pwd)>&auth=wpa2-psk&action=1&name=<enc(name)>
```

`enc` = Android `Uri.encode`: UTF-8 percent-encoding of everything except `A–Z a–z 0–9 _ - ! . ~ ' ( ) *`
(space → `%20`). Example: SSID `CFMOTO-123`, password `pass word` →
`http://manual.opencfmoto.local/?ssid=CFMOTO-123&pwd=pass%20word&auth=wpa2-psk&action=1&name=CFMOTO-123`.
It then parses as a normal Carbit QR (action=1 ⇒ SoftAP). iOS: build with `URLComponents` but percent-encode with
the same allowed set (Foundation's `.urlQueryAllowed` leaves `&`,`=`… unescaped in values — do it manually).

### 4.4 Photos (`GarageActivity.kt:58-71,243-274`) [V-CODE]

* Picker `image/*`; decoded with power-of-two subsampling: `sample=1; mx=max(w,h); while mx > 1440 {sample*=2;
  mx/=2}` (target 720, threshold 2×720) — e.g. 4032×3024 → sample 4 → 1008×756.
* Saved as `filesDir/bike_photos/<bikeId>.jpg`, JPEG quality **85**; the **absolute path** is stored.
* Card thumbnail 56×56 dp, center-crop; no photo → `ic_ride` icon tinted brand orange with 10 dp padding.
* Remove photo / remove bike delete the file. Failure toast `Couldn't read that image`.
* **iOS pitfall:** never store absolute paths — the app container path changes across updates/reinstalls. Store the
  file name (`<bikeId>.jpg`) relative to Application Support.

### 4.5 Garage screen (`GarageActivity.kt`, `res/layout/activity_garage.xml`) [V-CODE]

* Header `Garage` + explanation (`garage_each_bike_keeps…`); empty state `garage_no_bikes_yet…`; buttons
  `Scan new bike` (QR scanner; result parsed with `QrData.parse`, failure toast `Invalid QR`, success toast
  `Added <name>`) and `Enter Wi‑Fi manually`.
* One card per bike, list order = storage order. Active card: 2 dp brand-orange stroke, subtitle
  `Active bike · tap to edit` (orange); others: subtitle = parsed SSID (or `tap to select or edit` if the raw no
  longer parses), secondary text colour. Name 17 sp bold.
* Tap card → action list titled with the bike name: `Use this bike` (only if not active; toast `Selected <name>`),
  `Rename` (dialog `Rename bike`, hint `Bike name`, `Save`/`Cancel`), `Add photo` / `Change photo`,
  `Remove photo` (only with photo), `Remove bike` (confirm title `Remove <name>?`, message
  `This forgets its pairing, photo and settings. You can re-scan the dash QR or enter Wi‑Fi again later.`,
  `Remove`/`Cancel`).
* Refreshes on resume; Home's Connect label/status re-read the active bike on resume (`MainActivity.kt:688-693`).

### 4.6 Learned per-SSID data

`transport_<ssid>` and `dash_geo_<ssid>` are keyed by **SSID**, not bike id (§2.5), so two bikes with the same SSID
share them, and renaming a bike doesn't affect them. [V-CODE]

### 4.7 Map places (favorites/markers/history/parked/home) — data model only (map spec owns behaviour)

`MapPlace(name, lat, lon, category="", subtitle="")` stored as JSON arrays of
`{"name","lat","lon","category","subtitle"}` in prefs `opencfmoto_map_places` keys `favorites` (max 100),
`markers` (max 50), `history` (max 30), `parked` (0–1, category `parking`), `home` (0–1, category `home`); newest
first; two places are "the same" if |Δlat| < 1e-5 and |Δlon| < 1e-5 (`MapPlaces.kt:10-187`). [V-CODE]

---

## 5. Trips

### 5.1 Model & units (`TripModel.kt`) [V-CODE]

```kotlin
data class TrackPoint(val lat: Double, val lon: Double, val time: Long, val speedMs: Float)   // :8
data class Trip(val id: String, val start: Long, val end: Long, val distanceMeters: Double,
                val movingTimeMs: Long, val maxSpeedMs: Float, val points: List<TrackPoint>)  // :16-24
```

* `lat`/`lon` WGS84 degrees; `time` = **wall-clock epoch ms at the moment the fix was received**
  (`System.currentTimeMillis()`, not the GPS fix time, `TripRecorder.kt:138`); `speedMs` m/s (float).
* `id` = `start` as a decimal string (`TripRecorder.kt:164`). `start` = wall-clock ms when the leg began
  (`resetLeg`), `end` = wall-clock ms when finalized. Note `end − start` includes idle time; only `movingTimeMs`
  is "riding time".
* No elevation, no accuracy, no bike association, no name are stored.

### 5.2 Derived stats & formatting (`TripModel.kt:25-48`, `TripActivity.kt:104-122`) [V-CODE]

| Value | Formula (exact, including truncation) | Format |
|---|---|---|
| distance km | `distanceMeters / 1000.0` | `String.format(Locale.US, "%.2f km", km)` → always a dot decimal |
| max km/h | `(maxSpeedMs * 3.6f).toInt()` — **float** multiply, truncate toward 0 | `"<n> km/h"` |
| avg km/h | `movingTimeMs > 0 ? ((distanceMeters / (movingTimeMs/1000.0)) * 3.6).toInt() : 0` — truncate | `"<n> km/h"` |
| live speed | `(speedMs * 3.6f).coerceAtLeast(0f).toInt()` | big integer, unit `km/h` |
| duration | `sec = max(movingTimeMs,0)/1000`; `"%02d:%02d:%02d"` of `sec/3600`, `(sec%3600)/60`, `sec%60` (hours not wrapped: 90061 s → `25:01:01`) | moving time only |
| date | `SimpleDateFormat("EEE d MMM yyyy", Locale.getDefault())` of `start` (device TZ, device language) | e.g. `Tue 14 Nov 2023` |
| time range | `"HH:mm"` of start + `" – "` (U+2013 with spaces) + `"HH:mm"` of end | e.g. `22:13 – 22:19` |
| day summary | plural `trips_day_summary`: `%1$d ride · %2$.1f km` / `%1$d rides · %2$.1f km` with Σ `distanceKm` (locale-formatted: `12,3` in Spanish) | `TripsListActivity.kt:120-127` |

Worked examples [INF, computed with the exact JVM arithmetic]:

* Repo vector trip (`test/TripGpxTest.kt:11-22`): 12 500 m, 360 000 ms, max 25 m/s → `12.50 km`, `00:06:00`,
  avg `125`, max `90` km/h.
* 12 345.6 m, 1 234 567 ms, max 33.4 m/s → `12.35 km`, `00:20:34`, avg **35** (raw 35.9998 — truncation, not
  rounding), max **120** (33.4f×3.6f = 120.240005).
* Rounding: Java `%.2f` rounds half-up on the shortest decimal (`1.005` → `1.01`, `0.125` → `0.13`); C/Swift
  `String(format:)` may give `1.00`. Irrelevant in practice; don't write tests that depend on it.

### 5.3 Recorder algorithm (`TripRecorder.kt`) [V-CODE]

Constants (`TripRecorder.kt:181-186`): `MIN_MOVING_MS = 0.8` m/s (≈2.9 km/h), `IDLE_SPLIT_MS = 180 000` ms,
`MIN_SAVE_DISTANCE_M = 100.0` m, `MIN_SAVE_TIME_MS = 15 000` ms. GPS source: `GPS_PROVIDER`, min time **1000 ms**,
min distance **0 m** (`TripRecorder.kt:70`). Single shared instance (`TripLogger.kt:13-16`).

```
state: points[], distanceMeters=0.0, movingTimeMs=0, maxSpeedMs=0, startTime, lastFix=nil,
       lastFixAt=0 (monotonic ms), lastMovingAt=0 (monotonic ms), hasFix=false, lastAccuracy=0, curSpeedKmh=0

start():  if recording → true; if no fine-location permission or GPS provider off → false   (:64-77)
          resetLeg(); recording=true; request updates (1000 ms, 0 m); on SecurityException → recording=false,false
          emit(); return true
resetLeg(): points=[], distance=0, moving=0, max=0, startTime=wallNow, lastFix=nil, lastFixAt=0, lastMovingAt=0  (:149-158)

onLocation(loc):                                                                             (:110-142)
  if !recording return
  now   = monotonic ms (SystemClock.elapsedRealtime — includes deep sleep)
  prev  = lastFix
  d     = prev ? prev.distanceTo(loc) : 0            // metres, Android WGS84 ellipsoid distance
  dt    = (prev && lastFixAt>0) ? now - lastFixAt : 0
  speed = loc.hasSpeed ? loc.speed : (1 ≤ dt ≤ 5000 ? d / (dt/1000) : 0)
  moving = speed ≥ 0.8
  if prev && moving && 1 ≤ dt ≤ 5000: distance += d; movingTime += dt
  if moving: lastMovingAt = now
  else if lastMovingAt > 0 && now - lastMovingAt > 180000 && distance > 0:
        finalizeLeg(save=true); resetLeg(); speed = 0       // stays in recording mode
  if speed > max: max = speed                                // no accuracy filter → GPS spikes count
  curSpeedKmh = Int(max(speed*3.6, 0)); hasFix = true
  lastAccuracy = loc.hasAccuracy ? Int(loc.accuracy) : 0
  points.append((lat, lon, wallNowMs, speed))                // EVERY fix, moving or not
  lastFix = loc; lastFixAt = now; emit()

finalizeLeg(save):                                                                          (:160-175)
  if distance < 100 || movingTime < 15000 || points.count < 2 → return (leg silently dropped)
  trip = Trip(id=String(startTime), start=startTime, end=wallNow, …, points=copy)
  TripStore.save(trip); log "[trip] saved ride <12.35 km> in <00:20:34>"; onTripSaved(trip)

stopAndSave(): if !recording return; remove updates; recording=false; finalizeLeg(true);
               curSpeed=0; hasFix=false; emit()                                              (:80-88)
discard():     remove updates; recording=false; resetLeg(); curSpeed=0; hasFix=false; emit()  (:91-98)
snapshot():    Stats(recording, speedKmh, distanceMeters, movingTimeMs, maxSpeedMs, hasFix, accuracyM)  (:100-108)
```

Consequences worth knowing [INF]:
* A segment counts toward distance/time only if the **current** fix is moving; its distance is the full
  prev→current distance.
* GPS gaps > 5 s are dropped from both distance and moving time (avg speed stays consistent).
* The split leaves ~3 min of stationary points and time at the end of the saved leg (`end` = split moment).
* While stationary with `lastMovingAt == 0` (never moved since reset) no split happens; points keep accumulating.
* A brand-new leg after a split begins with the stationary fix that triggered the split.

Worked walkthrough (synthetic fixes; `d` = distance from previous fix; [INF] simulated with the exact rules):

| now (ms, monotonic) | GPS speed m/s | d from prev (m) | dt (ms) | speedMs used | moving | distance (m) | movingTime (ms) | max (m/s) | points | note |
|---|---|---|---|---|---|---|---|---|---|---|
| 1000 | 0.0 | 0 | 0 | 0.00 | no | 0.0 | 0 | 0.0 | 1 | first fix |
| 2000 | 5.0 | 5.2 | 1000 | 5.00 | yes | 5.2 | 1000 | 5.0 | 2 | |
| 3000 | 12.0 | 11.8 | 1000 | 12.00 | yes | 17.0 | 2000 | 12.0 | 3 | |
| 9500 | 13.0 | 80.0 | 6500 | 13.00 | yes | 17.0 | 2000 | 13.0 | 4 | 6.5 s gap: not accumulated |
| 10500 | — (no speed) | 14.0 | 1000 | 14.00 | yes | 31.0 | 3000 | 14.0 | 5 | derived speed d/dt |
| 11500 | 0.5 | 0.4 | 1000 | 0.50 | no | 31.0 | 3000 | 14.0 | 6 | |
| 190500 | 0.0 | 0.3 | 179000 | 0.00 | no | 31.0 | 3000 | 14.0 | 7 | 180 000 ms since last move: not > → no split |
| 191500 | 0.0 | 0.2 | 1000 | 0.00 | no | 0.0 | 0 | 0.0 | 1 | split; 31 m leg **discarded** (< 100 m) |
| 192500 | 9.0 | 9.1 | 1000 | 9.00 | yes | 9.1 | 1000 | 9.0 | 2 | new leg |

### 5.4 When recording happens

**Auto-logging — `TripAutoLog.sync()`** (`TripAutoLog.kt:30-52`) [V-CODE]:

```
if !logTrips: if recorder.recording → stopAndSave();  return        // NB: also kills a *manual* recording
shouldRecord = (phase == STREAMING) || mapUiLive
if shouldRecord && !recording && recorder.start(): log "[trip] auto-logging this ride (<AA + map|map|AA>)"
else if !shouldRecord && recording: stopAndSave()
```

Call sites: the Android-Auto foreground service watchdog every **5 000 ms** (`AndroidAutoService.kt:115-131,695`),
AA park/teardown/destroy (`AndroidAutoService.kt:207,653,672`), and map-UI bind/unbind
(`GpxDashUi.kt:2446,2799` via `TripAutoLog.setMapUiLive`). `STREAMING` is set when the first video frame is pulled
by the dash in **any** mode (AA, mirror, own map) (`EasyConnProber.kt:814`). Consequence: pure mirror sessions
without the AA service never call `sync()` and are not auto-logged [INF]; own-map sessions are (map UI live).

**Manual recording** [V-CODE]:
* Trip computer screen auto-starts recording on every resume (silently, regardless of *Log trips*)
  (`TripActivity.kt:71-78`). The `Start/Pause` toggle calls `start()` / `stopAndSave()` — "Pause" actually **ends and
  saves** the leg; the next Start begins a new leg. `Reset` = `discard()` without confirmation. Leaving the screen
  ends + saves the manual recording unless the AA service is running (`TripActivity.kt:134-141`).
* Map dash "Record ride" / "Stop recording" button (`GpxDashUi.kt:547,1893-1905`): status `Ride recording saved` /
  `Recording ride…` / `Can't record — check GPS / permission`, voice `Recording saved` / `Recording started`.
* Quirk: with *Log trips* OFF and the AA service running, the 5 s `sync()` stops any manual recording [INF].

**Recommendation for iOS** [INF]: one `TripRecorder`; `shouldRecord = logTrips && (dashUILive || linkPhase ==
.streaming)` evaluated on every link-phase change and on a 5 s timer; a manual recording is a separate flag that the
auto-logic never stops; name the buttons "Start" / "Stop & save" / "Discard".

### 5.5 Storage (`TripStore.kt`) [V-CODE]

* Directory `filesDir/trips/` (created on demand); one file per trip `<id>.json`; written with
  `File.writeText(obj.toString())` (compact, UTF-8, errors swallowed) (`TripStore.kt:19-36`).
* Object (insertion order): `id` (String), `start` (Long), `end` (Long), `distanceMeters` (Double),
  `movingTimeMs` (Long), `maxSpeedMs` (Double from Float), `points`: array of `[lat, lon, timeMs, speedMs]`.
* `list()` = every `*.json` parsed, unparsable files skipped, sorted by `start` descending (`TripStore.kt:39-42`).
  Parse uses lenient getters: missing numbers → `NaN`/`0` (`optDouble`/`optLong`) (`TripStore.kt:53-77`).
* `delete(id)` unlinks the file (`TripStore.kt:49-51`).
* Number formatting (AOSP `numberToString`): integral doubles print **without** `.0` (`45.0` → `45`); others use
  Java `Double.toString` (`12.3f` stored as `12.300000190734863`, tiny values as `1.0E-4`).

Example file for the repo vector trip if recorded (id = start) [INF]:

```json
{"id":"1700000000000","start":1700000000000,"end":1700000360000,"distanceMeters":12500,"movingTimeMs":360000,"maxSpeedMs":25,"points":[[45,25,1700000000000,10],[45.01,25.01,1700000180000,12]]}
```

iOS: keep the same file format in `Application Support/trips/` (enables future cross-platform import), write
atomically (`Data.write(options: .atomic)`), and mark the folder as included in iCloud/iTunes backup or not
according to the privacy decision (§11).

### 5.6 Trip computer screen (`TripActivity.kt`, `res/layout/activity_trip.xml`) [V-CODE]

Header `Trip computer` + `Saved trips` button; speed number 88 sp with `km/h` 16 sp; GPS line 12 sp; 2×2 stats
(`Distance`, `Duration`, `Max speed`, `Avg speed`); note `trip_speed_and_distance_come…`; bottom `Start/Pause`,
`Reset`. Screen kept on (`FLAG_KEEP_SCREEN_ON`, `TripActivity.kt:51`). Render rules (`TripActivity.kt:104-117`):
GPS line `Stopped` (not recording) / `Acquiring GPS…` (no fix) / `GPS fix ±<n>m` (accuracy > 0) / `GPS fix`;
initial layout text `Waiting for GPS…`; provider off → `GPS is off` (+ toast `Turn on GPS/Location to record`
unless silent); start failure → `Couldn't start GPS`; permission denied → `Location permission is required for the
trip HUD`. Distance `%.2f km`, duration of moving time, max/avg `<n> km/h`.

### 5.7 Saved trips list (`TripsListActivity.kt`, `activity_trips.xml`) [V-CODE]

* Day pager: `‹` / `›` shift by one calendar day (`Calendar.DAY_OF_YEAR ± 1`), label `EEE d MMM yyyy` (device
  locale), `Today` button hidden when on today. First open: today, or — if today has no rides — the day of the most
  recent trip (`TripsListActivity.kt:79-91`).
* A trip belongs to a day if `dayStart ≤ trip.start < dayStart + 86 400 000 ms` (local midnight; **24 h fixed — off by
  ±1 h on DST days** [INF]) (`TripsListActivity.kt:100-104,285-294`). Cards sorted by start descending.
* Empty: `trips_no_trips_yet` (no trips at all) / `trips_no_rides_browse_days`; summary `trips_no_rides_summary`.
* Card: route thumbnail (only if ≥ 2 points; height 112 dp, width = card width but ≥ 240 dp, rounded 12 dp,
  §5.10) → title = time range (17 sp bold) → 4 stats with UPPERCASED labels `DISTANCE`/`TIME`/`AVG`/`MAX` (10 sp) and
  values `12.35 km` / `00:20:34` / `35 km/h` / `120 km/h` (15 sp bold) → outlined button `Export GPX`.
  Tap card → trip map; long-press → dialog `Delete trip?` with message `<dateText> · <distanceText>`, buttons
  `Delete` / `Cancel`.

### 5.8 Trip map (`TripMapActivity.kt`) [V-CODE]

osmdroid with OSM **MAPNIK** tiles (`tile.openstreetmap.org`), User-Agent = package name; title = date text;
stats `"<distanceText> · <durationText> · avg <avgKmh> · max <maxKmh> km/h"`; polyline brand orange `#FF6A2C`,
10 px; marker `Start` tinted green at the first point and `End` tinted red at the last (if > 1 point); frame =
bounding box scaled ×1.4 with 48 px border, no animation; fallback zoom 15 on the first point; no points → zoom 4;
missing trip → toast `Trip not found` and close (`TripMapActivity.kt:34-104`). iOS: MapKit `MKPolyline` +
annotations, `setVisibleMapRect(... edgePadding: 48pt)`; offline → MapKit still shows cached tiles; Apple Maps
avoids OSM tile-policy concerns.

### 5.9 GPX export (`TripGpx.kt`, `TripsListActivity.kt:219-241`) [V-CODE]

* File `cacheDir/trip-export/opencfmoto_trip_<yyyyMMdd_HHmm>.gpx` (device time zone, `Locale.US`), UTF-8, MIME
  `application/gpx+xml`, subject = file name, chooser `Export GPX`; no points → toast `Trip has no GPS points`;
  failure `Export failed: <e>`; log `→ Trip GPX exported: <name>`.
* Template — byte-exact (two-space indentation, `\n` line ends, trailing newline):

```
<?xml version="1.0" encoding="UTF-8"?>\n
<gpx version="1.1" creator="OpenCfMoto" xmlns="http://www.topografix.com/GPX/1/1">\n
  <metadata>\n
    <name>{NAME}</name>\n
    <time>{START_UTC}</time>\n
  </metadata>\n
  <trk>\n
    <name>{NAME}</name>\n
    <type>motorcycle</type>\n
    <trkseg>\n
    (per point)
      <trkpt lat="{LAT}" lon="{LON}">\n
        <time>{PT_UTC}</time>\n          ← only if time > 0
      </trkpt>\n
    </trkseg>\n
  </trk>\n
</gpx>\n
```

* `{NAME}` = escape(`"OpenCfMoto " + dateText + " " + timeRangeText`) (device locale/TZ); escape replaces only
  `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, `"`→`&quot;` (in that order). `{LAT}`/`{LON}` =
  `String.format(Locale.US, "%.6f")`. Times = `yyyy-MM-dd'T'HH:mm:ss'Z'` in **UTC** (seconds precision).
  No `<ele>`, no `<speed>`, no extensions (`TripGpx.kt:13-58`).
* Repo test (`test/TripGpxTest.kt:9-36`): output contains `<gpx`, `trkpt lat="45.000000"`, `<time>`; parsing it back
  with the app's `GpxParser` yields 2 points with lat 45.0 and lon 25.01 (±1e-6); the file name ends with `.gpx`.
* Full expected output for that test trip with locale en-US and time zone UTC [INF — generated with the same JVM
  formatters]:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="OpenCfMoto" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <name>OpenCfMoto Tue 14 Nov 2023 22:13 – 22:19</name>
    <time>2023-11-14T22:13:20Z</time>
  </metadata>
  <trk>
    <name>OpenCfMoto Tue 14 Nov 2023 22:13 – 22:19</name>
    <type>motorcycle</type>
    <trkseg>
      <trkpt lat="45.000000" lon="25.000000">
        <time>2023-11-14T22:13:20Z</time>
      </trkpt>
      <trkpt lat="45.010000" lon="25.010000">
        <time>2023-11-14T22:16:20Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
```

  File name in that environment: `opencfmoto_trip_20231114_2213.gpx`.
* iOS: use `DateFormatter` with `en_US_POSIX` + `UTC` for `<time>`, `String(format: "%.6f")` with a POSIX locale
  (never the user locale — a comma decimal would break GPX), and `ShareLink`/`UIActivityViewController` with a
  `.gpx` file URL (UTType `com.topografix.gpx` is already declared in `project.yml`).

### 5.10 Route thumbnail (`TripRouteThumb.kt`) [V-CODE]

```
bitmap w×h (px), fill bgColor
pts = subsample(points, 180)    // if n ≤ 180 keep all; else idx_i = clamp(int(i * (n-1)/179), 0, n-1), i=0..179
if pts.count < 2 → return background only
bbox over pts; midLat=(minLat+maxLat)/2; cosLat = max(cos(midLat°), 0.2)
spanX = max((maxLon-minLon)*cosLat, 1e-7); spanY = max(maxLat-minLat, 1e-7)
pad = min(w,h)*0.14; drawW = w-2pad; drawH = h-2pad
scale = min(drawW/spanX, drawH/spanY); usedW = spanX*scale; usedH = spanY*scale
ox = pad + (drawW-usedW)/2; oy = pad + (drawH-usedH)/2
x(lon) = ox + (lon-minLon)*cosLat*scale;  y(lat) = oy + (maxLat-lat)*scale      // y down
stroke path through pts: color strokeColor, width max(4, min(w,h)*0.035) px, round cap+join, antialias
dots radius max(5, min(w,h)*0.045): first point startColor, last point endColor (end drawn last)
```

Colours used by the list: stroke brand orange `#FF6A2C`, background `surface_high #1F242E`, start `status_live
#34C759`, end `status_error #FF5A52` (`TripsListActivity.kt:163-176`, `res/values/colors.xml`).

Worked example [INF, computed]: test trip points (45.0,25.0)→(45.01,25.01) at 240×112 px: cosLat = 0.707045072,
spanX = 0.007070451, spanY = 0.01, pad = 15.68, drawW = 208.64, drawH = 80.64, scale = 8063.99994, usedW = 57.0161,
usedH = 80.64, ox = 91.4919, oy = 15.68 → start (91.4919, 96.3200), end (148.5081, 15.6800); stroke 4.0 px;
dot radius 5.04 px. Subsample 1000→180: step 5.5810056, indices `0 5 11 16 22 … 987 993 999`.

iOS: draw with `UIGraphicsImageRenderer` (top-left origin like Android) at pixel size = points × screen scale to keep
the same proportions, or with SwiftUI `Canvas`. Cache per trip id.

---

## 6. Logs, diagnostics, crash capture, problem report, updates, telemetry

### 6.1 LogBus (`LogBus.kt`) [V-CODE]

* One process-wide text buffer. `log(msg)`: `safe = includeSecrets ? msg : LogRedactor.redact(msg)`; line =
  `"HH:mm:ss.SSS" (device TZ, Locale.US) + "  " (two spaces) + safe`; append `\n`; if buffer length > 524 288 chars,
  delete from the start leaving the **last 262 144 chars**; mirror to logcat tag `OpenCfMoto`; notify the UI listener
  (`LogBus.kt:15-38,57`).
* `logThrottled(key, msg, minIntervalMs = 500)` drops repeats per key inside the interval; prunes the key map
  when > 64 entries (`LogBus.kt:45-55`).
* Session banner on process start and after **Clear** (`LogBus.kt:67-79`):
  ```
  [BUILD] versionName=2.0.18 versionCode=77 git=<shortHash> flags=yunmo=MapNaviType-no-initial-160+1024x464@187dpi+CBR+wire-dump
  [CLOCK-LAB] query=<id> timeSync=<id> bt=<on|off> keepWifi=<on|off> channel=-
  [BUILD] --- session start ---
  ```
* Every state change logs `[state] <EN phase label>[ — <detail>]` (`ConnectionState.kt:48-58`). Log lines stay
  **English by design** (`docs/TRANSLATIONS.md:46`).
* Stage tags used across the app: `[AA]`, `[VIDEO]`, `[:10922]`, `[:10921]`, `[:10920]`, `[BTN]`, `[trip]`, `[state]`,
  `[WIFI]`, `[HOTSPOT]`, `[MAP]`, `[GPX]`, `[reconnect]`, `[watchdog]`, `[adaptive]`, `[match-aspect]`, `[panel]`,
  `[CLOCK-LAB]`, `[deps]`, `[crash]`, `[FATAL]`, `[search]`, `[DISC]`, `[YUNMO]`.
* **Delta vs the iOS scaffold** (`Packages/OpenCfMotoKit/Sources/OpenCfMotoCore/Util/Log.swift`): the scaffold keeps
  structured lines (`HH:mm:ss.SSS L/TAG: msg`) in a 5000-line ring and redacts **on export**. Android redacts **on
  ingest**, so (a) the on-screen log never shows secrets unless the toggle was on when the line was written and
  (b) turning the toggle on does not reveal old lines. Either is acceptable; if you keep redact-on-export, also redact
  the on-screen view and the problem report, and document that the toggle is retroactive.

### 6.2 LogRedactor (`LogRedactor.kt`) — regexes verbatim [V-CODE]

Applied in this order to every line (`LogRedactor.kt:34-41`); all case-insensitive; `MASK = «redacted»`
(U+00AB … U+00BB).

| # | Name | Pattern (Kotlin raw string, verbatim) | Replacement |
|---|---|---|---|
| 1 | JSON_SECRET | `("(?:password\|pwd\|passphrase\|psk\|btPin)"\s*:\s*)"[^"]*"` | group1 + `"«redacted»"` |
| 2 | URL_SECRET | `\b(pwd\|password\|psk\|passphrase)=([^&\s"]*)` | group1 + `=` + `«redacted»` |
| 3 | JSON_SERIAL | `("(?:HUID\|sn\|uuid\|carHuid)"\s*:\s*)"([^"]*)"` | group1 + `"` + maskTail(group2) + `"` |
| 4 | BARE_SERIAL | `\b(carHuid\|HUID\|sn)=([A-Za-z0-9]{6,})` | group1 + `=` + maskTail(group2) |

(The `\|` above is Markdown escaping — the real patterns use a plain `|`.)
Copy-safe Swift raw-string literals (identical pattern text):

```swift
static let jsonSecret = #"("(?:password|pwd|passphrase|psk|btPin)"\s*:\s*)"[^"]*""#   // → $1 + "\"«redacted»\""
static let urlSecret  = #"\b(pwd|password|psk|passphrase)=([^&\s"]*)"#                   // → $1 + "=«redacted»"
static let jsonSerial = #"("(?:HUID|sn|uuid|carHuid)"\s*:\s*)"([^"]*)""#               // → $1 + "\"" + maskTail($2) + "\""
static let bareSerial = #"\b(carHuid|HUID|sn)=([A-Za-z0-9]{6,})"#                        // → $1 + "=" + maskTail($2)
// all with NSRegularExpression.Options.caseInsensitive, applied in this order
```
`maskTail(v) = v.length ≤ 4 ? v : v.prefix(4) + "…" + "*" × min(v.length − 4, 8)` (`LogRedactor.kt:43-44`).
SSID and model id are deliberately kept.

Repository vectors (`test/LogRedactorTest.kt:9-29`):
* `qr ssid=CFMOTO-x&pwd=supersecret&modelid=1` → contains `pwd=«redacted»`, not `supersecret`, still contains
  `ssid=CFMOTO-x`.
* `{"HUID":"CRCP230501740"}` → contains `CRCP`, not `CRCP230501740`.

Exact outputs (derived by running the same regexes on the JVM **and** with the Swift `NSRegularExpression` port below —
all 10 rows identical; Android's `java.util.regex` is ICU-backed like `NSRegularExpression`) [INF]:

| Input | Output |
|---|---|
| `qr ssid=CFMOTO-x&pwd=supersecret&modelid=1` | `qr ssid=CFMOTO-x&pwd=«redacted»&modelid=1` |
| `{"HUID":"CRCP230501740"}` | `{"HUID":"CRCP…********"}` |
| `QR raw: http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457` | `QR raw: http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=«redacted»&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457` |
| `CLIENT_INFO {"HUID":"6GUVA2C00100055","HUName":"CFMOTO-805120","btPin":"1234"}` | `CLIENT_INFO {"HUID":"6GUV…********","HUName":"CFMOTO-805120","btPin":"«redacted»"}` |
| `{"password" : "hunter2", "psk":"abc"}` | `{"password" : "«redacted»", "psk":"«redacted»"}` |
| `OTA {"port":11021,"userName":"carbit_ec_ftp_ota","pwd":"$Example2024@"}` | `OTA {"port":11021,"userName":"carbit_ec_ftp_ota","pwd":"«redacted»"}` |
| `check sn {"client_set":"easy_conn","sn":"DSXXZMHNFV3DEXEBB3PZ2"}` | `check sn {"client_set":"easy_conn","sn":"DSXX…********"}` |
| `{"uuid":"ab12"}` | `{"uuid":"ab12"}` (≤ 4 chars kept) |
| `carHuid=6WX0AT231300200 HUID=abc sn=peTz` | `carHuid=6WX0…******** HUID=abc sn=peTz` (bare serials need ≥ 6 alnum chars) |
| `Passphrase=foo bar&PSK=x` | `Passphrase=«redacted» bar&PSK=«redacted»` |
| `mypwd=secret` | `mypwd=secret` (**not** redacted: `\b` fails after `y`) |

Swift port notes: use `NSRegularExpression(..., options: .caseInsensitive)`; rules 1–2 can use a template
(`$1"«redacted»"` / `$1=«redacted»`); rules 3–4 need per-match replacement — enumerate matches and replace ranges
**from the end** to keep indices valid. ICU `\s` also matches Unicode spaces (e.g. U+00A0); Android uses ICU too, so
this matches Android.

### 6.3 Share Logs / Clear (`MainActivity.kt:531-567,651-656`) [V-CODE]

* Share: persist session (§6.4); write `cacheDir/logs/opencfmoto-<yyyyMMdd-HHmmss>.log` = full buffer; attach
  `filesDir/last_crash.txt` if non-empty and every `externalFilesDir/video/*.h264` (sorted by name). One file →
  `ACTION_SEND` `text/plain`; several → `ACTION_SEND_MULTIPLE` `*/*`; subject `opencfmoto log <stamp>`; chooser
  `Share log`; logs `log saved: <path> (<n> bytes)`.
* Clear: empty the buffer, delete `last_session.log`, clear the view, re-log the session banner.
* iOS: `ShareLink(items:)` with file URLs; MetricKit diagnostics (§6.4) can be attached the same way.

### 6.4 CrashGuard (`CrashGuard.kt`) [V-CODE]

Files in `filesDir`: `last_crash.txt`, `last_session.log`; cap `MAX_SESSION_BYTES = 256 × 1024` (chars).
* `install`: default uncaught-exception handler → `recordFatal` then chain to the previous handler (or kill + exit
  code 10) (`CrashGuard.kt:40-64`).
* `recordFatal` (`CrashGuard.kt:148-177`): header
  ```
  === OpenCfMoto FATAL yyyy-MM-dd HH:mm:ss.SSS ===
  version=<versionName> (<versionCode>)
  thread=<thread name>
  <stack trace>
  ```
  + `\n=== LogBus snapshot ===\n` + live snapshot; written truncated to 524 288 chars; the snapshot also overwrites
  `last_session.log`; logs `[FATAL] <class>: <message>`.
* `persistSession` (on Home `onPause`, before Share, on connect errors): write the live snapshot (restore/crash banner
  blocks stripped, tail ≤ 262 144 chars) to `last_session.log` (`CrashGuard.kt:67-74,180-194`).
* `hydrateLogBus` (once per process, `CrashGuard.kt:81-118`): read + **delete** `last_session.log`, prepend it with
  banner `--- restored session log (saved before last exit/crash) ---` (unless already starting with it); if a crash
  file exists, append `--- previous fatal crash (also in files/last_crash.txt) ---`, each non-empty crash line, then
  `--- end previous crash — use Share Logs to send this ---`.
* Home shows **Recovered after a crash** dialog when `last_crash.txt` is non-empty (`MainActivity.kt:334-350`): message
  `OpenCfMoto closed unexpectedly last time. The log and crash report were saved — open Logs and tap Share Logs so we can see what happened.`,
  buttons `Share Logs` / `Keep logs` / `Dismiss` (Dismiss deletes the crash file).
* Field fix: nested restore banners once blew the heap (OOM) — hence consume-on-hydrate + banner stripping + caps
  (`docs/07-IDEAS-AND-ISSUES.md:105-116`). [V-HW via telemetry]
* iOS: Swift traps can't be caught. Persist the session log on `scenePhase` → background and every ~30 s while
  linked; on launch hydrate the same way; use **MetricKit** (`MXCrashDiagnostic`) to obtain crash call stacks on the
  next launch and write them to `last_crash.txt`.
* iOS (locked iPhone, Phase 0): when a launch finds the marker of a run that ended in the background during a dash
  session (`previous run ended in the background…`), that run's restored log stays at the head of this run's saves
  (same 256 KiB cap, no banner in the file), so a second kill before Share Logs does not lose it. A normal relaunch
  still consumes the old log.

### 6.5 Problem report (`ProblemReport.kt`, `MainActivity.kt:613-689`) [V-CODE]

Dialog: title `Report a problem`, message `main_report_problem_message`; fields: problem (≥ 3 lines, hint
`What went wrong?`), bike model (pre-filled with the active bike name, hint `Bike model (e.g. 800NK Advanced)`), year
(hint `Year (optional)`); buttons `Share` / `Cancel`.

Diagnostics block (`MainActivity.kt:1653-1666`), one per line:
```
app=<versionName> (<versionCode>) git=<gitHash>
profile=<active profile display name>
override=<ProfileOverride enum NAME, e.g. AUTO / CFDL26_PORT>
transport=<WifiTransport label: Auto (from QR) | Force Wi‑Fi AP | Force Wi‑Fi Direct>
margins=<ScreenMargins.summary()>
forceNonTouch=<true|false>
forceTouch=<true|false>
ssid=<selected bike SSID or —>
phase=<Phase NAME> <detail>
```

`RULE` = 56 × `═` (U+2550). `bikeLine(model, year)` = `"CFMOTO " + (model.trim() or "unknown model")` +
(`", " + year` if year non-blank) — always prefixed `CFMOTO` even for other brands.

File text (`ProblemReport.kt:12-31`) — `problem` = user text or `(not specified)` when blank:
```
<RULE>
OpenCfMoto problem report
<RULE>

WHAT WENT WRONG
<problem.trim()>

BIKE
<bikeLine(model, year)>

SETUP
<diagnostics.trim()>

<RULE>
LOG — passwords and serials removed unless "include secrets" is on
<RULE>
<full LogBus snapshot>
```

Body (`ProblemReport.kt:33-47`) — note: uses the **raw** problem text (empty if blank):
````
### What went wrong
<problem.trim()>

### Bike
<bikeLine(model, year)>

### Setup
```
<diagnostics.trim()>
```

Full log attached. Secrets redacted unless enabled in Setup.
````

Subject: `OpenCfMoto <bikeLine(model, "")> report — <versionName>` (e.g.
`OpenCfMoto CFMOTO 800NK Advanced report — 2.0.18`). Shared as `cacheDir/logs/opencfmoto-report.txt`
(`text/plain`, EXTRA_STREAM) + EXTRA_TEXT body; chooser `Share problem report`; failure toast
`Couldn't share report: <e>`.

Worked example (model `800NK Advanced`, year `2025`) [INF]:
```
════════════════════════════════════════════════════════
OpenCfMoto problem report
════════════════════════════════════════════════════════

WHAT WENT WRONG
Dash stays black after Connect

BIKE
CFMOTO 800NK Advanced, 2025

SETUP
app=2.0.18 (77) git=0abbe2a
profile=CFDL26 / 800NK Advanced (touch, 720×712)
override=AUTO
transport=Auto (from QR)
margins=Top 22 · bottom 0 · left 0 · right 0 px (profile default)
forceNonTouch=false
forceTouch=false
ssid=CFMOTO-805120
phase=ERROR Bike Wi‑Fi is up but EasyConn is offline — keep the pairing QR open on the dash

════════════════════════════════════════════════════════
LOG — passwords and serials removed unless "include secrets" is on
════════════════════════════════════════════════════════
19:02:11.402  [BUILD] versionName=2.0.18 …
```

### 6.6 Update checker (`UpdateChecker.kt`) & release notes (`ReleaseNotes.kt`) [V-CODE; N/A for App Store builds]

* `GET https://api.github.com/repos/zanderp/open-cfmoto/releases/latest`, headers
  `Accept: application/vnd.github+json`, `User-Agent: OpenCfMoto`; connect/read timeouts 8000 ms; non-200 or any error
  → silently "nothing" (`UpdateChecker.kt:18-79`).
* Release = `version` = `tag_name` (fallback `name`), `notes` = `body.trim()`, `apkUrl` = `browser_download_url` of the
  first asset whose name ends with `.apk` (case-insensitive), `pageUrl` = `html_url` (fallback
  `https://github.com/zanderp/open-cfmoto/releases`); download = apk ?: page.
* Automatic check on Home resume at most once per **24 h** (`lastCheckMs`, `CHECK_INTERVAL_MS = 86 400 000`); manual
  check ignores the interval and the skip. `lastCheckMs` is written after every successful fetch.
* `isNewer(latest, current)`: extract all `\d+` runs as Ints (overflow → 0); empty latest → false; compare
  element-wise padding with 0; first difference decides; equal → false (`UpdateChecker.kt:80-93`).
* Vectors — repo (`test/LogRedactorTest.kt:25-29`): `("v1.0.16","1.0.15")`→true, `("1.0.15","1.0.16")`→false,
  `("0.1.2.1","0.1.2")`→true. Derived [INF]: `("2.0.18","2.0.18")`→false, `("v2.0.19","2.0.18")`→true,
  `("2.0.18-pre2","2.0.18")`→**true** (pre-release tags look newer), `("2.0.18","2.0.18-pre2")`→false,
  `("latest","2.0.18")`→false, `("v3","2.0.18")`→true, `("99999999999.0","2.0.18")`→false (overflow → 0).
* Dialog: title `Update <version>`, message = notes via ReleaseNotes, buttons `Download` (open URL), `Skip`
  (store `skippedVersion`; auto-checks then ignore exactly that version), `Later`. Manual: toast
  `Checking for update…`, then `You're up to date (or offline)` or the dialog.
* ReleaseNotes (`ReleaseNotes.kt:15-80`): take first 4000 chars; empty → `A newer OpenCfMoto release is available.`;
  per line (after `\r\n`/`\r` → `\n`, trimmed): empty or `---`/`***`/`___` → `<br>`; `#…` → `<b>title</b><br>`;
  `- ` / `* ` → `• item<br>`; else `text<br>`; trailing `<br>` removed. Inline: links `\[([^\]]+)\]\(([^)]+)\)` →
  `<a href>`, bold `\*\*(.+?)\*\*` → `<b>`, everything else HTML-escaped (`&`,`<`,`>`).
* iOS: App Store/TestFlight handle updates — omit. For side-loaded builds, the same algorithm against the iOS repo
  (`Kevinparra535/opencfmoto-ios`) with `.ipa` assets; render notes with `AttributedString(markdown:)`.

### 6.7 Anonymous telemetry (`AnonymousTelemetry.kt`) [V-CODE — document only; recommend NOT implementing on iOS]

* Default **ON**; toggle in Setup → Privacy; the anonymous id is displayed (`Anonymous id: <uuid>`).
* Endpoint `POST <TELEMETRY_URL>/v1/ping`, default base `https://opencfmoto-telemetry.hello-3d9.workers.dev`
  (`app/build.gradle.kts:36-40`); empty base disables uploads.
* Request: `Content-Type: application/json; charset=utf-8`, `User-Agent: OpenCfMoto/<version> (moto dash map;
  +https://github.com/zanderp/open-cfmoto)` (`AppHttp.kt:35-36`), connect 12 000 ms, read 20 000 ms; success = HTTP 2xx.
  Body (insertion order): `{"uuid","type","version","versionCode","androidSdk","locale"[, "payload"]}` where `type` ∈
  `ping` | `crash` | `error`, `locale` = BCP-47 tag.
* Events are queued in `filesDir/telemetry_queue.json` = JSON array of `{"type","ts"(epoch ms)[,"payload"]}`, max
  **24** (oldest dropped), payload ≤ 40 000 chars; flushed in order, stopping at the first failure (the rest kept).
* `ping` at most every **20 h** (`last_ping_ms` updated only when a ping is delivered); `crash` once per fingerprint
  (`"<hashCode of first line containing Exception/Error, else first 120 chars>:<length>"`); `error` = Home ERROR
  details, rate-limited to one per **30 min**, ≤ 2000 chars, not sent for the AA 17.4 "head unit server" banner
  (`MainActivity.kt:855-870`).
* Extra redaction (even with include-secrets on) (`AnonymousTelemetry.kt:231-242`):
  `(?i)(pwd|password|passphrase)\s*[=:]\s*\S+` → `$1=***`; `(?i)"pwd"\s*:\s*"[^"]*"` → `"pwd":"***"`;
  `(?i)ssid\s*[=:]\s*\S+` → `ssid=***`; `(?i)\b([A-Z0-9]{10,})\b` → `***` if length ≥ 12; then truncate 40 000.
  Vectors [INF]: `qr ssid=CFMOTO-x&pwd=supersecret&modelid=1` → `qr ssid=***`;
  `HUID 6GUVA2C00100055 and ABCDEFGHIJK and ABCDEFGHIJKL` → `HUID *** and ABCDEFGHIJK and ***`.
* Turning it off deletes the queue but keeps the UUID.

### 6.8 Dependency prompt (`DependencyPrompt.kt`) [N/A-iOS]

Blocks Connect/Scan when Android Auto, Play services or required runtime permissions are missing (title
`Missing dependencies`, body `OpenCfMoto needs a few things on this phone before it can talk to your bike:` + bullets,
buttons primary fix / `Open Setup` / `Later`); shown on launch after 2500 ms only for AA/Play-services. iOS analog: an
inline checklist for **Local Network**, **Location** (trip log; also needed to read the current SSID), **Camera**
(scan only), **Notifications** (optional).

---

## 7. Home screen & flows

### 7.1 Layout, top → bottom (`res/layout/activity_main.xml`) [V-CODE]

1. Header: ride icon 28 dp (brand orange) + `OpenCfMoto` (20 sp bold, tap → About) + `v<versionName>` (12 sp) (:12-53).
2. Status card (:72-130): 64 dp circle icon tinted by state, **phase label** 22 sp bold, **detail / bike line** 13 sp,
   indeterminate progress bar (brand orange) visible only while busy.
3. **Connect ⇄ Stop** full-width primary button (power / stop icon) (:133-139).
4. Row: `Dash view` | `Controls` (tonal) (:141-169).
5. Tiles (icon on top): `Scan` | `Map` | `Mirror` (:171-219). A hidden legacy `Stop` button exists (:222-227).
6. Footer 2×2 text buttons: `Setup` · `Garage` / `Trip` · `Logs` (:230-307).
7. Search row: field `Search a place or address…` (IME action Go) + `Go` (:309-335).
8. Tips card (:337-400): `RIDER TIPS` + tips text + `About & credits`, `Check for update`, `Report a problem`,
   `Donate`. **Logs** toggles this card with the log card (only one visible): log card `DIAGNOSTICS` + `Share` +
   `Clear`, monospace 11 sp text `#9CDCFE` in a 220 dp scroller (:402-470).

Palette (`res/values/colors.xml`): brand orange `#FF6A2C` (dark `#E85A1E`, on-brand `#FFFFFF`), bg `#0E1116`,
surface `#171B22`, surface-high `#1F242E`, outline `#2C333F`, text `#F2F5FA` / secondary `#9AA4B2`, status live
`#34C759`, busy `#FFB020`, error `#FF5A52`, idle `#8A93A3`. Dark "cockpit" theme only.

### 7.2 Connection phases (`ConnectionState.kt:15-27`) [V-CODE]

| Phase | busy | EN label (`labelRes`) | ES label | Log label (EN) | Icon tint | Connect button | iOS |
|---|---|---|---|---|---|---|---|
| `IDLE` | no | `Ready` | `Listo` | `Ready` | idle grey | `Connect to <bike>` / `Connect` | yes |
| `STARTING_AA` | yes | `Starting Android Auto…` | `Iniciando Android Auto…` | same | busy amber | `Stop` | **no** |
| `AA_VIDEO_LIVE` | yes | `Android Auto live — joining bike…` | `Android Auto en vivo: unirse a la moto...` | same | busy | `Stop` | **no** |
| `JOINING_WIFI` | yes | `Connecting to bike Wi-Fi…` | `Conectándose al Wi-Fi de la moto...` | same | busy | `Stop` | yes |
| `PXC_CONNECTING` | yes | `Linking to dashboard…` | `Vinculando al panel...` | same | busy | `Stop` | yes |
| `STREAMING` | no | `Connected — projecting to dash` | `Conectado: proyectando al tablero` | same | live green | `Stop` | yes |
| `MIRRORING` | no | `Mirroring screen to dash` | `Duplicando la pantalla en el tablero` | same | live green | `Stop` | yes (mirror; Android also uses it for the own map until the first frame) |
| `RECONNECTING` | yes | `Link dropped — reconnecting…` | `Enlace caído - reconectando...` | same | busy | `Stop` | yes |
| `WAITING_FOR_BIKE` | yes | `Bike out of range — waiting…` | `Moto fuera de alcance - esperando...` | same | busy | `Stop` | yes |
| `STOPPED` | no | `Stopped` | `Detenido` | same | idle | `Connect…` | yes |
| `ERROR` | no | `Error — see logs` | `Error: ver registros` | `Error — see logs` | error red | `Connect…` | yes |

Lifecycle in practice [V-CODE]: AA Connect: `STARTING_AA → (JOINING_WIFI in parallel) → AA_VIDEO_LIVE →
PXC_CONNECTING → STREAMING`. Mirror / Map: `MIRRORING` (detail = bike name) → `JOINING_WIFI` → `PXC_CONNECTING` →
**`STREAMING` as soon as the dash pulls the first frame** (`EasyConnProber.kt:814`). Drop: `RECONNECTING`
(`attempt N`, up to 20 attempts, back-off `min(500+500·n, 4000)` ms, `EasyConnProber.kt:48,620-640`) → `STREAMING`
or `ERROR` `lost bike link`. Wi-Fi gone: `RECONNECTING` `waiting for bike Wi-Fi`; after 180 000 ms (auto-recovery on)
→ `WAITING_FOR_BIKE` `will resume when the bike is back`.

### 7.3 Status rendering rules (`MainActivity.kt:862-934`) [V-CODE]

* Phase label = localized `labelRes`. Second line = `detail` if non-blank, else
  `Paired: <name> — tap Connect to reconnect` / `No bike paired yet — tap Connect to scan the dash QR`.
* Tint: STREAMING/MIRRORING → live; ERROR → error; other busy → busy; else idle. Progress bar iff busy.
* Connect label: busy or STREAMING/MIRRORING → `Stop` (stop icon); else `Connect to %1$s` if a bike is saved, else
  `Connect` (power icon). Connect is always enabled; tapping it while busy/live = **Stop everything**.
* Enablement (disabled = alpha 0.4): Scan iff !busy; Mirror and Map iff (!busy || live) — so the rider can switch dash
  content while live.
* Side effects on ERROR: detail containing `CFMoto app` → "official app in the way" dialog once per error episode;
  detail containing `kill-switch` **and** an active VPN → VPN dialog once; any non-noise detail → telemetry error.

### 7.4 Detail-string catalog (`ConnectionState.set(phase, detail)` call sites) [V-CODE]

| Phase | Detail (EN; resource key if localized) | When | Source | iOS |
|---|---|---|---|---|
| any start | bike name or SSID | Connect/Mirror/Map start | `MainActivity.kt:101,194,1702,1749` | yes |
| ERROR | `VPN kill-switch blocking bike Wi‑Fi` | socket bind EPERM with VPN | `EasyConnProber.kt:183,430,529` | adapt (iOS VPN "includeAllNetworks") |
| ERROR | `close the official CFMoto app, then reconnect` | ports 10920–10922 already bound | `EasyConnProber.kt:216` | yes (official iOS app holding ports) |
| ERROR | `conn_detail_easyconn_offline` | Wi-Fi up but EasyConn never answered (and Yunmo failed) | `EasyConnProber.kt:442-445` | yes |
| ERROR | `lost bike link` | 20 re-probe attempts exhausted | `EasyConnProber.kt:624` | yes |
| RECONNECTING | `attempt <n>` | all bike sockets closed | `EasyConnProber.kt:628` | yes |
| ERROR | `conn_detail_wifi_picker` | first Wi-Fi join timed out | `BikeWifi.kt:186-196` | adapt (iOS join failure) |
| RECONNECTING | `waiting for bike Wi-Fi` | re-requesting Wi-Fi | `BikeWifi.kt:251-254` | yes |
| ERROR | `phone Wi‑Fi is off` | Wi-Fi radio off | `WifiGate.kt:48,62` | partial (iOS can't read the radio state) |
| PXC_CONNECTING | `reconnecting` | Wi-Fi re-acquired | `BikeLink.kt:129` | yes |
| ERROR | `prober start failed` / `prober restart failed` | exception | `BikeLink.kt:106,139` | yes |
| ERROR | `conn_detail_connect_failed` | exception in Connect | `MainActivity.kt:259` | yes |
| ERROR | `conn_detail_auto_connect_failed` | exception in auto-connect | `MainActivity.kt:798` | yes |
| ERROR | `conn_detail_aa_not_started` / `conn_detail_aa_dropped` | AA never attached after 18 000 ms | `MainActivity.kt:239-253` | no |
| ERROR | `conn_detail_need_bluetooth` | AA Connect without Nearby/BT | `MainActivity.kt:293` | no |
| JOINING_WIFI | `main_phone_hotspot_status` | phone-hotspot dash | `MainActivity.kt:1125,1148` | open question |
| ERROR | `main_phone_hotspot_cancelled` / `main_phone_hotspot_no_iface` / `main_phone_hotspot_no_peer` / `hotspot scan failed` | hotspot flow | `MainActivity.kt:1131,1176,1199,1234` | open question |
| ERROR | `Wi‑Fi Direct failed` | P2P failed and no SoftAP creds | `MainActivity.kt:1283` | no |
| PXC_CONNECTING / STREAMING | `Yunmo :<port> <w>x<h> map-nav` or `… mirror` / `Yunmo :<port> <w>x<h>` | Morini Yunmo path | `YunmoLink.kt:214-217,499` | protocol spec |
| ERROR | `Yunmo link dropped` | | `YunmoLink.kt:471` | protocol spec |
| WAITING_FOR_BIKE | `will resume when the bike is back` / `tap to resume` | AA parked / BAL fallback | `AndroidAutoService.kt:232,289` | adapt |
| ERROR | `Map switch failed — Stop, then Map` | soft switch failed | `AndroidAutoService.kt:607` | adapt |
| STOPPED | (empty — cleared) | Stop | `MainActivity.kt:1472`; `AndroidAutoService.kt:651` | yes |

### 7.5 Flows

#### 7.5.1 Launch (`MainActivity.kt:407-670`) [V-CODE]
1. Apply settings to globals; show any restored log; crash-recovery dialog if pending (§6.4).
2. After **2500 ms**: soft dependency dialog (AA / Play services only) [N/A-iOS].
3. If not projecting and not launched to start the map: abandon stale navigation (map spec).
4. Render status; reuse the process-global link object.
5. Request notification permission (Android 13+).
6. Log `Ready. Tap Connect to project Android Auto to your dash.`
7. **First run** (`setup_seen=false`) → open Setup; otherwise `maybeAutoConnect()`. Then handle "resume from parked"
   and "BT trigger" intents.
8. On every resume: refresh bike label/status, cancel the Wi-Fi-off notification if Wi-Fi is on, retry auto-connect
   (if setup seen), daily update check, resume-from-parked check (`MainActivity.kt:688-700`).

#### 7.5.2 First-run setup
Setup's `Done` writes `setup_seen=true` and closes (`SetupActivity.kt:213-216`); returning to Home triggers
auto-connect via `onResume`.

#### 7.5.3 Auto-connect (`MainActivity.kt:747-808`) [V-CODE]
Preconditions, in order: not already latched this process; `auto_connect` on; AA service not running; phase not busy
and not STREAMING/MIRRORING; a saved bike (else log once `→ Auto-connect idle: no bike paired.`); AA installed
[N/A-iOS]; phone Wi-Fi on (else prompt + log once, **not latched**); in-range check = associated SSID equals the
bike's, or the SSID in the last Wi-Fi scan; definitely absent (fresh scan without it) → log once
`'<name>' not in range — will retry when its Wi-Fi appears` and retry on next resume. Then latch, log
`→ Auto-connect: '<name>' (Wi-Fi in range|range unknown — trying anyway). Disable in Setup ▸ Startup.`, and after
**1200 ms** start the Connect flow (unlatch if the activity died meanwhile). iOS has no Wi-Fi scan API: always
"range unknown" → just attempt the join (NEHotspotConfiguration fails fast if absent).

#### 7.5.4 Connect / Stop (`MainActivity.kt:527-548,184-261,1029-1114,1459-1473`) [V-CODE]
* Connect while idle: dependency check → saved bike ⇒ start AA flow with it; none ⇒ open the scanner.
* AA flow [N/A-iOS]: Wi-Fi gate → Nearby/BT gate → tear down any previous mode → apply profile → `STARTING_AA` →
  start AA service; trigger AA after 900 ms, re-trigger after 4500 ms if no video, give up after 18 000 ms → ERROR;
  Wi-Fi join runs in parallel and the bike probe starts only when both AA video and Wi-Fi are ready.
* Wi-Fi join (shared with mirror/map; transport details belong to the pairing spec): `JOINING_WIFI`; phone-hotspot
  QR → hotspot flow; `p2p` setting forces P2P only if the QR supports it (else logs and uses SoftAP); AUTO uses P2P for
  P2P-only QRs or `DIRECT-*` SSIDs; per-SSID memory (`transport_<ssid>`) overrides AUTO; P2P-only without MAC but with a
  password → SoftAP first; P2P timeout 12 000 ms when a SoftAP fallback exists; success records the winning transport.
* **Stop everything**: stop AA service, link, BLE wake, mirror projection, map session, clock BLE, release Wi-Fi
  (unless keep-Wi-Fi) → `STOPPED` with empty detail.

#### 7.5.5 Scan (`MainActivity.kt:836-852,65-111`) [V-CODE]
Opens the QR scanner (camera, `1x/2x/3x` zoom, `Import QR from photo`, `Enter Wi‑Fi manually`; the scanner returns
the first QR text it decodes — `QrScanActivity.kt:53-164`). Parse failure → toast with
`QrData.parseFailureHint(raw)` or `Invalid QR` (pairing spec lists the hint texts). Success → save + select the bike,
then start Connect (or the mirror link if the scan was for Mirror).

#### 7.5.6 Mirror (`MainActivity.kt:1493-1529,352-405,1694-1716`) [V-CODE; iOS = ReplayKit]
Ignore a second tap if already MIRRORING/RECONNECTING and a frame was sent < 15 000 ms ago (toast
`Already mirroring — wait for the dash, or tap Stop first`). Ask screen-capture consent; wait for the foreground
service (poll 100 ms × 50 = 5 s); dialog **Mirror ready** (text in §9.13) → Continue → saved bike? connect
(`MIRRORING`, detail bike name) and send the app to background with toast `main_mirror_leave_shared_app`; else scan.
iOS: present `RPSystemBroadcastPickerView` for the broadcast extension; the extension streams independently; show the
same "Mirror ready" guidance (bike touch does not drive mirrored apps).

#### 7.5.7 Map & search (`MainActivity.kt:1480-1487,1367-1401,617-631`) [V-CODE]
`Map` opens the Map hub. The home search field: our map on the bike → search on the dash
(`Searching "<q>" on the dash`); AA live → geocode then hand to Google Maps [N/A-iOS]; nothing projected → open the
Map hub search. While our map is on the bike, typing ≥ 2 chars sends live suggestions after a **350 ms** debounce.
Empty query → toast `Type a place to search on the map`. "Type on phone" from the dash search highlights the field
for 2500 ms with hint `Bike dash search — type here`, vibrates 40 ms, toast
`Bike search open — type here. Results appear on the dash.`

#### 7.5.8 Error dialogs [V-CODE] (texts in §9.13)
Official-app-holding-ports dialog (`Close & retry` → best-effort kill + reconnect after 1500 ms; `App settings`;
`Dismiss`); VPN kill-switch dialog (`VPN settings`; `Dismiss`); Wi-Fi off dialog (`Wi‑Fi settings`; `Dismiss`);
Nearby/Bluetooth dialog [N/A-iOS].

#### 7.5.9 Recovery & resume (auto-recovery) [V-CODE; AA-specific parts N/A]
Watchdog every 5000 ms (AA service): STREAMING with no frame for > 8000 ms → force reconnect (cooldown 20 000 ms);
ERROR → re-arm (cooldown 20 000 ms); bike Wi-Fi gone > 180 000 ms → park (`WAITING_FOR_BIKE`) unless keep-Wi-Fi;
Wi-Fi back → resume (`AndroidAutoService.kt:134-195,695-700`). README still says "~1 minute grace" (`README.md:346`) — code is 180 s (`GRACE_MS`, comment *"60s was parking mid-ride"*).
The map session is never parked. iOS: same supervisor on the link layer (no AA to park): keep the dash UI renderer
alive, stop encoding while waiting, resume on Wi-Fi.

### 7.6 Timers & thresholds (home-level)

| Value | Meaning | Source |
|---|---|---|
| 2500 ms | delay before launch dependency dialog | `MainActivity.kt:489` |
| 1200 ms | auto-connect delay after the decision | `MainActivity.kt:785-800` |
| 900 / 4500 / 18000 ms | AA trigger / re-trigger / give-up [N/A-iOS] | `MainActivity.kt:215-253` |
| 350 ms | live-suggestion debounce | `MainActivity.kt:619-630` |
| 2500 ms / 40 ms | search-field highlight / vibration | `MainActivity.kt:591-608` |
| 100 ms × 50 | mirror FGS readiness poll [N/A-iOS] | `MainActivity.kt:363-403` |
| 15000 ms | duplicate Mirror tap guard | `MainActivity.kt:1497-1508` |
| 1500 ms × 30 (~45 s) | phone-hotspot tether poll | `MainActivity.kt:1150-1169` |
| 12000 ms | P2P timeout when SoftAP fallback exists | `MainActivity.kt:1249-1254` |
| 1500 ms | reconnect after "Close & retry" | `MainActivity.kt:960` |
| 5000 / 8000 / 20000 / 180000 ms | watchdog tick / stall / cooldown / park grace | `AndroidAutoService.kt:695-699` |
| 24 h / 20 h / 30 min | update check / telemetry ping / error report intervals | `UpdateChecker.kt:24`; `AnonymousTelemetry.kt:33-34` |

---

## 8. Setup screen & sub-pages

### 8.1 Section order (`res/layout/activity_setup.xml`) [V-CODE]

Every selector is a row of segmented buttons; the active segment is brand-orange with white text, others
surface-high (`SetupActivity.kt:627-638`); a description line shows the current choice's label.

1. Title `Setup & settings` + intro (:17-31).
2. **Get started** card (:36-161) [N/A-iOS]: `1. Android Auto` (✓/• + Install/Open), `2. Permissions`
   (`Grant permissions` / `All granted` + `App settings`), `3. Head-unit mode in Android Auto` (+ 17.4 note +
   `Android Auto settings`).
3. **Screen & display** (:163-734): Video quality (Smoother/Balanced/Sharper) · Screen fit (Fill/Fit/Stretch) ·
   Mirror orientation (Match dash/Follow phone/Landscape/Portrait) · `Screen margins…` · Map theme (Auto/Day/Night) ·
   Resolution & orientation (Auto; Landscape 800×480/1280×720; Portrait 720×1280/1080×1920) + `Match panel aspect…` ·
   Android Auto text size (Auto/160/180/240/320) · Disable touchscreen (On/Off) · Force touchscreen (On/Off).
4. **Battery & power** (:736-819): Auto/Smooth/Balanced/Saver + heat note.
5. **Bike profile** (:821-946): Auto; Legacy/800NK; 800MT/1000 MT-X; 800NK Adv/CL‑C450 + note.
6. **Handlebar** (:948-1128): Double-tap delay (200/300/450/1000 ms) · Hold detection (On/Off) · Hold delay
   (500/600/800 ms; description `Ignored while Hold detection is Off` when off).
7. **Bluetooth** (:1130-1187): explanation, live status line (`setup_bt_*`), `Open Bluetooth settings`.
8. **Startup & recovery** (:1189-1398): Auto-connect (On/Off) · Connect when a Bluetooth device joins (picker) ·
   Auto-recovery (On/Off) · Log trips automatically (On/Off) · Seamless auto-resume (`Enable seamless resume` /
   `✓ Seamless resume enabled`).
9. **Clock lab (EXPERIMENTAL)** (:1400-1685) [EXP]: presets Latest/2.0.12/Zontes OEM/Phone-sync/BT listen ·
   `0x10450 / QUERY_TIME` Empty ack/Carbit JSON/Zontes OEM/No ack · `0x10600 / TIME_SYNC` Echo bike/Phone local ·
   Bluetooth listen On/Off · Stay on bike Wi-Fi after disconnect On/Off. Toasts `Clock lab: <PRESET>`,
   `QUERY_TIME: <id>`, `TIME_SYNC: <id>`.
10. **Wi‑Fi & logs** (:1687-1912): Wi‑Fi transport (Auto/AP/P2P; description = transport label) · Privacy:
    Anonymous usage & crash reports (On/Off) + `Anonymous id: <uuid>` · Include secrets in shared logs (On/Off) ·
    Share settings (`Share JSON`, `Import…`).
11. **Supported bikes** (:1914-2024): intro, confirmed, other brands, full list, usually-no-QR, footer.
12. `Done` (:2027-2032) + footer `© 2026 Alexandru · OpenCfMoto · AGPL‑3.0` (:2039).

Behaviour: everything re-evaluated on resume (`SetupActivity.kt:640-661`); "applies next connect" toasts for
video/profile/touch/transport settings (`SetupActivity.kt:464-465`).

### 8.2 About page (`AboutActivity.kt`, `activity_about.xml`) [V-CODE]
`Version <versionName>  ·  build <versionCode>`; tagline; Community (`Discord` → `https://discord.gg/KNTjJhmFZ6`,
`Donate` → `https://ko-fi.com/alexandrupopa`); Copyright (`© 2026 Alexandru` + body, `Website — alexandru.rocks` →
`https://alexandru.rocks`, `Source on GitHub` → `https://github.com/zanderp/open-cfmoto`); License (AGPL text +
`View LICENSE & NOTICE` → `https://github.com/zanderp/open-cfmoto/blob/main/NOTICE`); Credits; Disclaimer; `Done`.
Link failure toast `Couldn't open link`. **iOS must keep AGPL notices and add its own source link** (the iOS repo) and
upstream attribution (`NOTICE`).

---

## 9. Strings — EN | ES

Notes [V-CODE]:
* Source: `res/values/strings.xml` (623 `<string>` + plurals) and `res/values-es/strings.xml` (578). Tables 9.1–9.12
  were generated programmatically from the two XML files (no hand copying), so the text is verbatim. Missing ES keys fall
  back to English (`docs/TRANSLATIONS.md:34`). Android escapes (`\'`, `\"`, `\n`, `✓`) are decoded below;
  `\n` is shown literally as a line break marker.
* Placeholders: `%1$s` / `%1$d` / `%2$.1f` → in iOS `.strings`/String Catalog use `%1$@` / `%1$lld` / `%2$.1f`
  (positional arguments are supported). Plurals (`trips_day_summary`) → String Catalog plural variations.
* "Android Auto" wording must be rewritten for iOS (the iOS app projects its own dash UI). Rows marked `(missing —
  falls back to EN)` are untranslated in the Spanish file.
* Spanish defects worth fixing on iOS [INF]: `notif_media_channel` and `notif_media_title` are swapped;
  `main_rival_title` "está en camino" means "is on its way" (should be "está estorbando"); `dash_left` (= distance
  remaining) translated as "IZQUIERDA" (direction) — use "RESTANTE"; `dash_arrive` "LLEGAR" → "LLEGADA";
  `about_questions…` "Los consejos" (advice) should be "Las donaciones/propinas"; `supported_bikes_*` ES lists are
  stale (missing Ibex 800, 675SR‑R, Rieju 307, Kove…).

### 9.1 Keys shared across screens

| Key | EN | ES |
|---|---|---|
| `gpx_map` | Map | Mapa |
| `gpx_on` | On | Activado |
| `res_off` | Off | Apagado |
| `controls_auto` | Auto | Auto |
| `controls_day` | Day | Día |
| `controls_night` | Night | Noche |
| `about_done` | Done | Hecho |
| `about_donate` | Donate | Donar |
| `hud_dash_view` | Dash view | Vista de tablero |
| `controls_controls` | Controls | Controles |
| `garage_garage` | Garage | Garaje |
| `dash_cancel` | Cancel | Cancelar |
| `gpx_free_ride_place` | Free ride | Ruta libre |
| `gpx_no_bike_open_phone_map` | No bike saved — opening on phone map instead | No hay ninguna moto guardada: se abre en el mapa del teléfono |

### 9.2 Home (`main_*`)

| Key | EN | ES |
|---|---|---|
| `main_connection_status` | Connection status | Estado de conexión |
| `main_ready` | Ready | Listo |
| `main_no_bike_paired_yet` | No bike paired yet | Ninguna moto emparejada todavía |
| `main_connect` | Connect | Conectar |
| `main_scan` | Scan | Escanear |
| `main_mirror` | Mirror | Espejo |
| `main_stop` | Stop | Detener |
| `main_setup` | Setup | Configuración |
| `main_trip` | Trip | Viaje |
| `main_logs` | Logs | Registros |
| `main_search_a_place_or_address` | Search a place or address… | Buscar un lugar o dirección… |
| `main_go` | Go | Ir |
| `main_rider_tips` | Rider tips | Consejos para moteros |
| `main_connect_start_android_auto_on_the_dash_becomes_s` | • Connect — start Android Auto on the dash (becomes Stop while linked).\n• Map — OpenCfMoto map / GPX (not Google Maps). Mirror — cast phone screen.\n• While connected, Map / Mirror switch what the dash shows.\n• Dash view & Controls — phone HUD and D-pad / handlebar. | • Conectar: inicia Android Auto en el tablero (se convierte en Detener mientras está vinculado).\n• Mapa: mapa OpenCfMoto / GPX (no Google Maps). Espejo: transmitir la pantalla del teléfono.\n• Mientras está conectado, Mapa/Espejo cambia lo que muestra el tablero.\n• Vista del tablero y controles: HUD del teléfono y D-pad/manillar. |
| `main_about_credits` | About & credits | Acerca de y créditos |
| `main_check_for_update` | Check for update | Buscar actualizaciones |
| `main_report_a_problem` | Report a problem | Informar de un problema |
| `main_report_problem_message` | Builds a shareable report with diagnostics + recent log (secrets redacted unless enabled in Setup). | Crea un informe que puedes compartir con los diagnósticos y el registro reciente (los secretos se ocultan salvo que lo actives en Configuración). |
| `main_report_hint_problem` | What went wrong? | ¿Qué ha fallado? |
| `main_report_hint_bike_model` | Bike model (e.g. 800NK Advanced) | Modelo de moto (p. ej. 800NK Advanced) |
| `main_report_hint_year` | Year (optional) | Año (opcional) |
| `main_mirror_leave_shared_app` | Leave the shared app on screen (OpenCfMoto stays in the notification) | Dejar en pantalla la aplicación compartida (OpenCfMoto se queda en la notificación) |
| `main_share_problem_report` | Share problem report | Compartir el informe del problema |
| `main_diagnostics` | Diagnostics | Diagnóstico |
| `main_share` | Share | Compartir |
| `main_clear` | Clear | Borrar |
| `main_aa_need_nearby_title` | Nearby devices required | Se necesitan los dispositivos cercanos |
| `main_aa_need_nearby_message` | Android Auto Connect needs Nearby devices (Bluetooth) so the phone can start wireless projection. Grant Nearby, turn Bluetooth on, then tap Connect again.\n\nMirror and Map do not need this. | Conectar con Android Auto necesita Dispositivos cercanos (Bluetooth) para que el teléfono pueda iniciar la proyección inalámbrica. Concede Dispositivos cercanos, enciende el Bluetooth y vuelve a tocar Conectar.\n\nEspejo y Mapa no lo necesitan. |
| `main_aa_need_bt_on_message` | Turn Bluetooth on, then tap Connect again. Android Auto Connect uses Bluetooth to start wireless projection on newer Android Auto builds.\n\nMirror and Map do not need this. | Enciende el Bluetooth y vuelve a tocar Conectar. Conectar con Android Auto usa Bluetooth para iniciar la proyección inalámbrica en las versiones recientes de Android Auto.\n\nEspejo y Mapa no lo necesitan. |
| `main_aa_need_nearby_settings` | Open settings | Abrir ajustes |
| `main_hide_logs` | Hide logs | Ocultar registros |
| `main_connect_to` | Connect to %1$s | Conectar con %1$s |
| `main_no_bike_paired` | No bike paired yet — tap Connect to scan the dash QR | Aún no hay ninguna moto emparejada: toca Conectar para escanear el QR del tablero |
| `main_paired` | Paired: %1$s — tap Connect to reconnect | Emparejado: %1$s: toca Conectar para volver a conectarte |
| `main_invalid_qr` | Invalid QR | QR no válido |
| `main_phone_hotspot_hint` | Turn on Android hotspot with the SSID and password shown on the dash, then wait — the bike joins your phone | Enciende el punto de acceso de Android con el SSID y la contraseña que muestra el tablero y espera: la moto se conecta a tu teléfono |
| `main_phone_hotspot_status` | Waiting for bike on phone hotspot… | Esperando a la moto en el punto de acceso del teléfono… |
| `main_phone_hotspot_no_iface` | No phone hotspot found — enable Android hotspot with the dash SSID/password, then Connect again | No se encontró el punto de acceso del teléfono: actívalo en Android con el SSID y la contraseña del tablero y vuelve a Conectar |
| `main_phone_hotspot_no_peer` | Hotspot is up but the dash wasn't found — keep the pairing screen open and retry | El punto de acceso está activo pero no se encontró el tablero: mantén abierta la pantalla de emparejamiento y reinténtalo |
| `main_phone_hotspot_dialog_title` | Phone hotspot setup | Configurar el punto de acceso del teléfono |
| `main_phone_hotspot_dialog_message` | This bike joins your phone's hotspot (Android cannot create that hotspot for you).\n\n1. Type the SSID and password shown on the dash (reminder only).\n2. Open hotspot settings and set those exact values.\n3. Keep the dash pairing screen open — we wait ~45s for the bike. | Esta moto se conecta al punto de acceso de tu teléfono (Android no puede crear ese punto de acceso por ti).\n\n1. Escribe el SSID y la contraseña que muestra el tablero (solo como recordatorio).\n2. Abre los ajustes del punto de acceso y pon esos valores exactos.\n3. Mantén abierta la pantalla de emparejamiento del tablero: esperamos unos 45 s a la moto. |
| `main_phone_hotspot_ssid_hint` | Dash hotspot SSID | SSID del punto de acceso del tablero |
| `main_phone_hotspot_pwd_hint` | Dash hotspot password | Contraseña del punto de acceso del tablero |
| `main_phone_hotspot_open_settings` | Open hotspot settings | Abrir los ajustes del punto de acceso |
| `main_phone_hotspot_ready` | Hotspot is on — scan | El punto de acceso está activo: escanea |
| `main_phone_hotspot_settings_failed` | Couldn't open hotspot settings — open them manually | No se pudieron abrir los ajustes del punto de acceso: ábrelos manualmente |
| `main_phone_hotspot_cancelled` | Phone hotspot setup cancelled | Configuración del punto de acceso cancelada |
| `main_phone_hotspot_waiting_named` | Waiting for hotspot "%1$s" — bike should join your phone | Esperando al punto de acceso "%1$s": la moto debería conectarse a tu teléfono |
| `main_donate_failed` | Couldn't open donate link | No se pudo abrir el enlace de donación |
| `main_settings_failed` | Couldn't open app settings | No se pudo abrir la configuración de la aplicación |
| `main_download_failed` | Couldn't open download link | No se pudo abrir el enlace de descarga |
| `main_share_report_failed` | Couldn't share report: %1$s | No se pudo compartir el informe: %1$s |
| `main_vpn_hint` | Open Settings ▸ Network ▸ VPN | Abre Ajustes ▸ Red ▸ VPN |
| `main_type_place` | Type a place to search on the map | Escribe un lugar para buscar en el mapa. |
| `main_searching_dash` | Searching "%1$s" on the dash | Buscando «%1$s» en el tablero |
| `main_sent_aa` | Sent "%1$s" to Android Auto | Enviado «%1$s» a Android Auto |
| `main_checking_update` | Checking for update… | Buscando actualizaciones... |
| `main_up_to_date` | You're up to date (or offline) | Estás actualizado (o desconectado) |
| `main_crash_title` | Recovered after a crash | Recuperado tras un fallo de la aplicación |
| `main_mirror_ready_title` | Mirror ready | Espejo listo |
| `main_rival_title` | Official CFMoto app is in the way | La aplicación oficial CFMoto está en camino |
| `main_bike_search_hint` | Bike dash search — type here | Búsqueda en el tablero de la moto: escribe aquí |

### 9.3 Connection phases & details (`conn_*`)

| Key | EN | ES |
|---|---|---|
| `conn_ready` | Ready | Listo |
| `conn_starting_aa` | Starting Android Auto… | Iniciando Android Auto… |
| `conn_aa_video_live` | Android Auto live — joining bike… | Android Auto en vivo: unirse a la moto... |
| `conn_joining_wifi` | Connecting to bike Wi-Fi… | Conectándose al Wi-Fi de la moto... |
| `conn_pxc_connecting` | Linking to dashboard… | Vinculando al panel... |
| `conn_streaming` | Connected — projecting to dash | Conectado: proyectando al tablero |
| `conn_mirroring` | Mirroring screen to dash | Duplicando la pantalla en el tablero |
| `conn_reconnecting` | Link dropped — reconnecting… | Enlace caído - reconectando... |
| `conn_waiting_for_bike` | Bike out of range — waiting… | Moto fuera de alcance - esperando... |
| `conn_stopped` | Stopped | Detenido |
| `conn_error` | Error — see logs | Error: ver registros |
| `conn_detail_connect_failed` | Connect failed — see Logs / Share Logs | Error de conexión: mira Registros o Compartir registros |
| `conn_detail_auto_connect_failed` | Auto-connect failed — see Logs | Error de conexión automática: mira Registros |
| `conn_detail_need_bluetooth` | Grant Nearby devices / Bluetooth, then tap Connect again | Concede Dispositivos cercanos / Bluetooth y vuelve a tocar Conectar |
| `conn_detail_aa_not_started` | Android Auto didn't attach. On Android Auto 17.4+ Google blocked the automatic start: open Android Auto, tap Version 10 times, then ⋮ → Start head unit server, and retry Connect. SoftAP/Mirror still prove the bike Wi‑Fi link. | Android Auto no se ha enganchado. En Android Auto 17.4+ Google bloqueó el arranque automático: abre Android Auto, toca Versión 10 veces, luego ⋮ → Start head unit server, y vuelve a Conectar. SoftAP y Espejo siguen demostrando que el enlace Wi-Fi con la moto funciona. |
| `conn_detail_aa_dropped` | Android Auto attached then dropped. Bike Wi-Fi is up — tap Connect again and leave the Android Auto connect banner. SoftAP/Mirror still prove the bike link. | (missing — falls back to EN) |
| `conn_detail_wifi_picker` | Approve the phone's Wi‑Fi / device picker (don't leave it open), then Connect again | Acepta el selector de Wi-Fi o de dispositivos del teléfono (no lo dejes abierto) y vuelve a Conectar |
| `conn_detail_easyconn_offline` | Bike Wi‑Fi is up but EasyConn is offline — keep the pairing QR open on the dash | El Wi-Fi de la moto está activo pero EasyConn está desconectado: mantén abierto el QR de emparejamiento en el tablero |

### 9.4 Setup & preference labels (`setup_*`, `pref_*`)

| Key | EN | ES |
|---|---|---|
| `setup_aa_dpi` | Android Auto text size (DPI) | (missing — falls back to EN) |
| `setup_aa_dpi_desc` | Auto uses the bike profile. Higher DPI makes Maps / AA chrome larger (useful if the TFT font is too small). | (missing — falls back to EN) |
| `setup_aa_dpi_auto` | Auto | (missing — falls back to EN) |
| `setup_bt_trigger` | Connect when a Bluetooth device joins | (missing — falls back to EN) |
| `setup_bt_trigger_desc` | Optional. Pair the trigger device first (helmet remote, watch). Next time it connects, OpenCfMoto starts Connect using the saved bike. | (missing — falls back to EN) |
| `setup_bt_trigger_pick` | Choose a bonded device | (missing — falls back to EN) |
| `setup_bt_trigger_none` | Off | (missing — falls back to EN) |
| `setup_bt_trigger_set` | Trigger: %1$s | (missing — falls back to EN) |
| `setup_setup_settings` | Setup & settings | Configuración y ajustes |
| `setup_a_one_time_setup_so_android_auto_can_project_to_` | A one-time setup so Android Auto can project to your CFMoto dash, plus display and battery options. | Una configuración única para que Android Auto pueda proyectar en tu tablero CFMoto, más las opciones de pantalla y batería. |
| `setup_get_started` | Get started | Empezar |
| `setup_1_android_auto` | 1. Android Auto | 1. Android Auto |
| `setup_android_auto_runs_maps_waze_opencfmoto_relays_it` | Android Auto runs Maps/Waze. OpenCfMoto relays its screen to the bike. | Android Auto ejecuta Maps/Waze. OpenCfMoto retransmite tu pantalla a la moto. |
| `setup_open_android_auto` | Open Android Auto | Abrir Android Auto |
| `setup_install_android_auto` | Install Android Auto | Instalar Android Auto |
| `setup_2_permissions` | 2. Permissions | 2. Permisos |
| `setup_all_granted` | All granted | Todos concedidos |
| `setup_camera_scan_the_dash_qr_location_join_the_bike_w` | Camera (scan the dash QR), Location (join the bike Wi-Fi), Notifications (keep running while you ride). | Cámara (escanea el QR del tablero), Ubicación (únete a la red Wi-Fi de la moto), Notificaciones (sigue corriendo mientras conduces). |
| `setup_grant_permissions` | Grant permissions | Conceder permisos |
| `setup_app_settings` | App settings | Configuración de la aplicación |
| `setup_3_head_unit_mode_in_android_auto` | 3. Head-unit mode in Android Auto | 3. Modo unidad principal en Android Auto |
| `setup_in_android_auto_settings_tap_version_10_times_to` | In Android Auto settings, tap "Version" ~10 times to unlock Developer settings, then turn ON "Add new cars to Android Auto" / "Unknown sources". (Can't be checked automatically.) | En los ajustes de Android Auto, toca «Versión» unas 10 veces para desbloquear los ajustes de desarrollador y luego activa «Añadir coches nuevos a Android Auto» / «Fuentes desconocidas». (No se puede comprobar automáticamente). |
| `setup_aa_17_4_start_head_unit_server` | On Android Auto 17.4+, also open the ⋮ Developer settings menu and tap Start head unit server before you Connect. You may need this again after a reboot or an Android Auto update. Do not uninstall Android Auto updates. | (missing — falls back to EN) |
| `setup_android_auto_settings` | Android Auto settings | Ajustes de Android Auto |
| `setup_screen_display` | Screen & display | Pantalla y visualización |
| `setup_video_quality` | Video quality | Calidad de vídeo |
| `setup_balanced_recommended` | Balanced (recommended) | Equilibrado (recomendado) |
| `setup_smoother` | Smoother | Más suave |
| `setup_balanced` | Balanced | Equilibrado |
| `setup_sharper` | Sharper | Más nítido |
| `setup_screen_fit` | Screen fit | Ajuste de pantalla |
| `setup_mirror_orientation` | Mirror orientation | (missing — falls back to EN) |
| `setup_mirror_orientation_desc` | While mirroring, lock the phone so the dash fills. Match dash uses the last measured / profile panel (wide TFT → landscape). Follow phone leaves the phone as you hold it. | (missing — falls back to EN) |
| `setup_match_dash` | Match dash | (missing — falls back to EN) |
| `setup_follow_phone` | Follow phone | (missing — falls back to EN) |
| `setup_fill_edge_to_edge_crops_a_little` | Fill — edge to edge (crops a little) | Rellenar: borde a borde (recorta un poco) |
| `setup_fill` | Fill | Rellenar |
| `setup_fit` | Fit | Ajustar |
| `setup_stretch` | Stretch | Estirar |
| `setup_screen_margins` | Screen margins… | Márgenes de la pantalla… |
| `setup_inset_android_auto_from_each_edge_of_the_dash_to` | Inset Android Auto from each edge of the dash (top / bottom / left / right). Useful on 800NK Advanced for the MotoPlay pull-down. | Aparta Android Auto de cada borde del tablero (arriba/abajo/izquierda/derecha). Útil en la 800NK Advanced por el desplegable de MotoPlay. |
| `setup_auto_day_night` | Auto (day / night) | Automático (día/noche) |
| `setup_resolution_orientation` | Resolution & orientation | Resolución y orientación |
| `setup_auto_match_your_bike_recommended` | Auto — match your bike (recommended) | Auto: combina con tu moto (recomendado) |
| `setup_landscape` | Landscape | Horizontal |
| `setup_800_480` | 800×480 | 800×480 |
| `setup_1280_720` | 1280×720 | 1280×720 |
| `setup_portrait` | Portrait | Vertical |
| `setup_720_1280` | 720×1280 | 720×1280 |
| `setup_1080_1920` | 1080×1920 | 1080×1920 |
| `setup_auto_fits_recognized_cfmoto_dashes_if_your_bike_` | Auto fits recognized CFMoto dashes. If your bike's screen is a different shape (e.g. a tall portrait display) or isn't recognized, pick the orientation + size that matches it. Android Auto supports only these fixed sizes, so Screen fit above decides how it's placed (Fill crops, Fit adds bars, Stretch distorts). HD is sharper but heavier and can black-screen on some dashes — drop to a smaller size or Auto if so. | Auto se adapta a los tableros CFMoto reconocidos. Si la pantalla de tu moto tiene otra forma (por ejemplo, vertical alargada) o no se reconoce, elige la orientación y el tamaño que coincidan. Android Auto solo admite estos tamaños fijos, así que el Ajuste de pantalla de arriba decide cómo se coloca (Rellenar recorta, Ajustar añade barras, Estirar deforma). HD se ve más nítido pero pesa más y en algunos tableros puede dejar la pantalla en negro; si pasa, baja a un tamaño menor o a Auto. |
| `setup_match_panel_aspect` | Match panel aspect… | Ajustar a la proporción del panel… |
| `setup_disable_touchscreen` | Disable touchscreen | Desactivar pantalla táctil |
| `setup_holds_off_desc` | Off — every release is a tap / ×2 (use with a long double-tap delay) | Desactivado: cada suelta es una pulsación / ×2 (úsalo con un retardo de doble pulsación largo) |
| `setup_nontouch_on_desc` | On — focus/knob UI so handlebar buttons work | Activado: interfaz de foco/rueda para que funcionen los botones del manillar |
| `setup_off_use_the_bike_profile_touch_dashes_stay_touch` | Off — use the bike profile (touch dashes stay touch) | Desactivado: usa el perfil de la moto (los tableros táctiles siguen siendo táctiles) |
| `setup_turn_on_if_handlebar_buttons_do_nothing_android_` | Turn On if handlebar buttons do nothing: Android Auto runs in focus/knob mode (no touchscreen advertised) so ▲/▼/Enter work. Needed next Connect — Stop first if you're already projecting. | Actívalo si los botones del manillar no hacen nada: Android Auto pasa a modo foco/mando (no anuncia pantalla táctil), así que ▲/▼/Enter funcionan. Se aplica en la próxima conexión: detén la proyección primero si ya está en marcha. |
| `setup_force_touchscreen` | Force touchscreen | Forzar pantalla táctil |
| `setup_forcetouch_on_desc` | On — Android Auto touch UI (tap the dash) | Activado: interfaz táctil de Android Auto (toca el tablero) |
| `setup_off_use_the_bike_profile_1000_mt_x_stays_focus_k` | Off — use the bike profile (1000 MT‑X stays focus/knob) | Desactivado: usa el perfil de la moto (la 1000 MT‑X sigue en modo foco/mando) |
| `setup_turn_on_for_a_touch_panel_on_a_focus_knob_profil` | Turn On for a touch panel on a focus/knob profile (e.g. 1000 MT‑X): Android Auto advertises a touchscreen so you can tap the dash. Turns off Disable touchscreen. Unlock the bike's own touch lock if needed. Applies next Connect — Stop first if you're already projecting. | Actívalo para un panel táctil sobre un perfil de foco/mando (por ejemplo, la 1000 MT‑X): Android Auto anuncia una pantalla táctil para que puedas tocar el tablero. Desactiva Desactivar pantalla táctil. Desbloquea el bloqueo táctil de la moto si hace falta. Se aplica en la próxima conexión: detén la proyección primero si ya está en marcha. |
| `setup_battery_power` | Battery & power | Batería y energía |
| `setup_balanced_24_fps_recommended` | Balanced — 24 fps (recommended) | Equilibrado: 24 fps (recomendado) |
| `setup_smooth` | Smooth | Fluido |
| `setup_saver` | Saver | Ahorrador |
| `setup_this_app_runs_a_live_video_transcoder_it_always_` | This app runs a live video transcoder — it always draws power and warms the phone. Keep it on the bike's USB charger, and turn the phone screen OFF while riding (projection keeps running). | Esta aplicación ejecuta un transcodificador de video en vivo: siempre consume energía y calienta el teléfono. Mantenlo en el cargador USB de la moto y apaga la pantalla del teléfono mientras conduces (la proyección sigue funcionando). |
| `setup_bike_profile` | Bike profile | Perfil de moto |
| `setup_auto_detect_from_the_bike_recommended` | Auto — detect from the bike (recommended) | Auto: detección desde la moto (recomendado) |
| `setup_legacy` | Legacy | Legado |
| `setup_800nk` | 800NK | 800NK |
| `setup_800mt` | 800MT | 800MT |
| `setup_1000_mt_x` | 1000 MT-X | 1000 MT-X |
| `setup_800nk_adv` | 800NK Adv | 800NK Adv |
| `setup_cl_c450` | CL‑C450 | CL‑C450 |
| `setup_use_legacy_for_cfdl16_450sr_style_non_touch_dash` | Use Legacy for CFDL16 / 450SR-style non-touch dashes if Auto picks the wrong bike. 800NK Adv = CFDL26 touch 720×712. Applies next Connect (Stop first if projecting). | Usa Legacy para tableros no táctiles estilo CFDL16/450SR si Auto elige la moto equivocada. 800NK Adv = CFDL26 táctil 720×712. Se aplica en la próxima conexión (detén la proyección primero si está en marcha). |
| `setup_handlebar` | Handlebar | Manillar |
| `setup_double_tap_delay` | Double-tap delay | Retardo de doble pulsación |
| `setup_300_ms_balanced_recommended` | 300 ms — balanced (recommended) | 300 ms: equilibrado (recomendado) |
| `setup_200_ms` | 200 ms | 200 ms |
| `setup_300_ms` | 300 ms | 300 ms |
| `setup_450_ms` | 450 ms | 450 ms |
| `setup_1000_ms` | 1000 ms | 1000 ms |
| `setup_hold_detection` | Hold detection | Detección de pulsación larga |
| `setup_on_press_and_hold_can_fire_hold_gestures` | On — press-and-hold can fire hold gestures | Activado: mantener pulsado puede disparar gestos de pulsación larga |
| `setup_hold_delay` | Hold delay | Retardo de pulsación larga |
| `setup_600_ms_balanced_recommended` | 600 ms — balanced (recommended) | 600 ms: equilibrado (recomendado) |
| `setup_500_ms` | 500 ms | 500 ms |
| `setup_600_ms` | 600 ms | 600 ms |
| `setup_800_ms` | 800 ms | 800 ms |
| `setup_bluetooth` | Bluetooth | Bluetooth |
| `setup_handlebar_media_call_buttons` | Handlebar media/call buttons | Botones multimedia/llamada del manillar |
| `setup_the_dash_sends_the_handlebar_volume_track_call_b` | The dash sends the handlebar volume/track/call buttons over Bluetooth — not the mirroring link. Pair your phone to the bike (as a phone/audio device) and they control Android Auto media and calls. | El tablero envía los botones de volumen, pista y llamada del manillar por Bluetooth, no por el enlace de duplicación. Empareja tu teléfono con la moto (como teléfono y dispositivo de audio) y esos botones controlarán la reproducción y las llamadas de Android Auto. |
| `setup_checking_bluetooth` | Checking Bluetooth… | Comprobando Bluetooth… |
| `setup_open_bluetooth_settings` | Open Bluetooth settings | Abrir la configuración de Bluetooth |
| `setup_bt_no_bluetooth` | This phone has no Bluetooth. | Este teléfono no tiene Bluetooth. |
| `setup_bt_off` | Bluetooth is off — turn it on, then pair your bike. | El Bluetooth está apagado: enciéndelo y luego empareja la moto. |
| `setup_bt_connected` | Connected to %1$s — handlebar buttons & calls should work. | Conectado a %1$s: los botones del manillar y las llamadas deberían funcionar. |
| `setup_bt_audio_device` | an audio device | un dispositivo de audio |
| `setup_bt_not_connected` | Bluetooth on, but not connected to the bike yet. Pair it to use the handlebar buttons. | Bluetooth encendido, pero aún sin conexión con la moto. Empárejala para usar los botones del manillar. |
| `setup_startup_recovery` | Startup & recovery | Inicio y recuperación |
| `setup_auto_connect_on_launch` | Auto-connect on launch | Conexión automática al iniciar |
| `setup_when_a_paired_bike_s_wi_fi_is_in_range_start_pro` | When a paired bike's Wi-Fi is in range, start projecting automatically. | Cuando el Wi-Fi de una moto emparejada esté a tiro, empieza a proyectar automáticamente. |
| `setup_auto_recovery_watchdog` | Auto-recovery watchdog | Vigilante de recuperación automática |
| `setup_if_the_dash_drops_or_projection_stalls_reconnect` | If the dash drops or projection stalls, reconnect automatically — no Stop/Start. | Si el tablero se cae o la proyección se atasca, se reconecta solo, sin parar y arrancar. |
| `setup_bluetooth_clock` | Set dash clock over Bluetooth (experimental) | Poner el reloj del tablero por Bluetooth (experimental) |
| `setup_bluetooth_clock_desc` | Some dashes ask for the time over Bluetooth, not Wi-Fi, and sit at 00:00 without it. Pair the bike in Android Bluetooth settings first. Off by default — we only reply after the dash speaks its own protocol. | Algunos tableros piden la hora por Bluetooth, no por Wi-Fi, y se quedan en 00:00 sin ella. Empareja antes la moto en los ajustes de Bluetooth de Android. Desactivado por defecto: solo respondemos cuando el tablero habla su propio protocolo. |
| `setup_clock_lab` | Clock lab (EXPERIMENTAL) | (missing — falls back to EN) |
| `setup_clock_lab_desc` | One tester pack for every clock experiment — Wi‑Fi query/sync, Bluetooth listen (ZT / EC-BTP), stay-on-bike-Wi‑Fi. Defaults match Latest 2.0.13 (empty 0x10451, echo 0x10600, BLE off). Pick a combo, Connect once, Share Logs in Discord #clock-issue. Do not leave a combo on for daily riding. | (missing — falls back to EN) |
| `setup_clock_lab_bt` | Bluetooth listen | (missing — falls back to EN) |
| `setup_clock_lab_presets` | Presets (fill the knobs only) | (missing — falls back to EN) |
| `setup_clock_lab_preset_latest` | Latest | (missing — falls back to EN) |
| `setup_clock_lab_preset_2012` | 2.0.12 | (missing — falls back to EN) |
| `setup_clock_lab_preset_zontes` | Zontes OEM | (missing — falls back to EN) |
| `setup_clock_lab_preset_phone` | Phone-sync | (missing — falls back to EN) |
| `setup_clock_lab_preset_bt` | BT listen | (missing — falls back to EN) |
| `setup_clock_lab_query` | 0x10450 / QUERY_TIME | (missing — falls back to EN) |
| `setup_clock_lab_query_empty` | Empty ack | (missing — falls back to EN) |
| `setup_clock_lab_query_carbit` | Carbit JSON | (missing — falls back to EN) |
| `setup_clock_lab_query_zontes` | Zontes OEM | (missing — falls back to EN) |
| `setup_clock_lab_query_none` | No ack | (missing — falls back to EN) |
| `setup_clock_lab_timesync` | 0x10600 / TIME_SYNC | (missing — falls back to EN) |
| `setup_clock_lab_timesync_echo` | Echo bike | (missing — falls back to EN) |
| `setup_clock_lab_timesync_phone` | Phone local | (missing — falls back to EN) |
| `setup_keep_wifi` | Stay on bike Wi-Fi after disconnect | Seguir en el Wi-Fi de la moto tras desconectar |
| `setup_keep_wifi_desc` | Some dashes forget the clock when SoftAP / Wi-Fi Direct drops. Keeps the phone associated until you leave the app or turn Wi-Fi off. Off by default. | Algunos tableros olvidan el reloj cuando se cae el SoftAP / Wi-Fi Direct. Mantiene el teléfono asociado hasta que salgas de la aplicación o apagues el Wi-Fi. Desactivado por defecto. |
| `setup_log_trips_automatically` | Log trips automatically | Registrar viajes automáticamente |
| `setup_record_each_ride_s_route_and_stats_from_gps_whil` | Record each ride's route and stats from GPS while projecting. View them under Trip ▸ Saved trips. | Registra la ruta y las estadísticas de cada viaje desde el GPS mientras proyectas. Los verás en Viaje ▸ Viajes guardados. |
| `setup_seamless_auto_resume` | Seamless auto-resume | Reanudación automática sin cortes |
| `setup_let_the_app_re_project_on_its_own_when_the_bike_` | Let the app re-project on its own when the bike comes back, even with the screen off or the phone in a bag. Needs the “Display over other apps” permission; otherwise you'll get a tap-to-resume notification instead. | Deja que la aplicación vuelva a proyectar por su cuenta cuando la moto regrese, incluso con la pantalla apagada o el teléfono en una bolsa. Necesita el permiso «Mostrar sobre otras aplicaciones»; si no, recibirás una notificación para reanudar con un toque. |
| `setup_enable_seamless_resume` | Enable seamless resume | Activar la reanudación sin cortes |
| `setup_seamless_resume_enabled` | ✓ Seamless resume enabled | ✓ Reanudación sin cortes activada |
| `setup_overlay_for_seamless_resume` | Turn on “Display over other apps” for seamless resume | Activa “Mostrar sobre otras aplicaciones” para la reanudación sin cortes |
| `setup_overlay_permission_failed` | Couldn’t open the overlay permission screen | No se pudo abrir la pantalla del permiso de superposición |
| `setup_some_permissions_still_off` | Some permissions are still off — use “App settings” to enable them. | Todavía hay permisos desactivados: usa “Configuración de la aplicación” para activarlos. |
| `setup_play_store_failed` | Couldn’t open the Play Store | No se pudo abrir Play Store |
| `setup_android_auto_settings_failed` | Couldn’t open Android Auto settings | No se pudieron abrir los ajustes de Android Auto |
| `pref_profile_auto` | Detect from the bike (recommended) | Detectar desde la moto (recomendado) |
| `pref_profile_legacy` | CFDL16 / 450SR-style non-touch | CFDL16 / no táctil estilo 450SR |
| `pref_profile_nk800` | CRCP / sdk 0.9.23.x non-touch | CRCP / sdk 0.9.23.x no táctil |
| `pref_profile_nk_adv` | CFDL26 touch 720×712 | CFDL26 táctil 720×712 |
| `pref_profile_cfdl26_land` | CFDL26 landscape touch | CFDL26 táctil horizontal |
| `pref_profile_cfdl26_port` | CFDL26 portrait (handlebar-primary) | CFDL26 vertical (manillar como principal) |
| `pref_profile_clc450` | 544×512 near-square | 544×512 casi cuadrado |
| `pref_map_theme_day` | Day (light) | Día (claro) |
| `pref_map_theme_night` | Night (dark) | Noche (oscuro) |
| `pref_dbltap_fast` | 200 ms — snappier singles | 200 ms: pulsaciones simples más rápidas |
| `pref_dbltap_normal` | 300 ms — balanced (recommended) | 300 ms: equilibrado (recomendado) |
| `pref_dbltap_slow` | 450 ms — forgiving doubles | 450 ms: dobles más tolerantes |
| `pref_dbltap_very_slow` | 1000 ms — slow doubles (long physical press) | 1000 ms: dobles lentos (pulsación física larga) |
| `pref_hold_short` | 500 ms — quicker hold | 500 ms: mantener más rápido |
| `pref_hold_normal` | 600 ms — balanced (recommended) | 600 ms: equilibrado (recomendado) |
| `pref_hold_long` | 800 ms — deliberate hold | 800 ms: mantener deliberado |
| `setup_wi_fi_logs` | Wi‑Fi & logs | Wi‑Fi y registros |
| `setup_wi_fi_transport` | Wi‑Fi transport | Transporte Wi-Fi |
| `setup_auto_ap_when_the_qr_advertises_it_else_wi_fi_dir` | Auto — AP when the QR advertises it, else Wi‑Fi Direct | Auto: AP cuando el QR lo anuncia; en caso contrario, Wi-Fi Direct |
| `setup_ap` | AP | AP |
| `setup_p2p` | P2P | P2P |
| `setup_include_secrets_in_shared_logs` | Include secrets in shared logs | Incluir secretos en registros compartidos |
| `setup_secrets_on_desc` | On — passwords/serials stay in shared logs | Activado: las contraseñas y los números de serie se quedan en los registros compartidos |
| `setup_off_passwords_and_serials_are_redacted_recommend` | Off — passwords and serials are redacted (recommended) | Desactivado: las contraseñas y los números de serie se ocultan (recomendado) |
| `setup_share_settings` | Share settings | Compartir configuración |
| `setup_export_bike_tuning_only_profile_resolution_fit_m` | Export bike tuning only — profile, resolution, fit, margins, buttons, Wi‑Fi transport (no passwords, no personal prefs). Share on Discord so others can Import. | Exporta solo ajustes de motos: perfil, resolución, ajuste, márgenes, botones, transporte Wi-Fi (sin contraseñas ni preferencias personales). Comparte en Discord para que otros puedan importar. |
| `setup_share_json` | Share JSON | Compartir JSON |
| `setup_import` | Import… | Importar… |
| `setup_supported_bikes` | Supported bikes | Motos compatibles |
| `setup_2026_alexandru_opencfmoto_agpl_3_0` | © 2026 Alexandru · OpenCfMoto · AGPL‑3.0 | © 2026 Alexandru · OpenCfMoto · AGPL‑3.0 |
| `pref_vq_smooth` | Smoother — less data/latency | Más fluido: menos datos/latencia |
| `pref_vq_balanced` | Balanced (recommended) | Equilibrado (recomendado) |
| `pref_vq_sharp` | Sharper — more data | Más nítido: más datos |
| `pref_fit_fill` | Fill — edge to edge (crops a little) | Rellenar: borde a borde (recorta un poco) |
| `pref_fit_fit` | Fit — no cropping (black bars) | Ajustar: sin recorte (barras negras) |
| `pref_fit_stretch` | Stretch — fills, slight distortion | Estirar: rellenos, ligera distorsión |
| `pref_power_auto` | Auto — adapts to heat & signal | Automático: se adapta al calor y la señal |
| `pref_power_smooth` | Smooth — 30 fps (most battery) | Suave: 30 fps (la mayor parte de la batería) |
| `pref_power_balanced` | Balanced — 24 fps (recommended) | Equilibrado: 24 fps (recomendado) |
| `pref_power_saver` | Battery saver — 20 fps (coolest) | Ahorro de batería: 20 fps (más frío) |
| `pref_res_auto` | Auto — match your bike (recommended) | Auto: combina con tu moto (recomendado) |
| `pref_res_land_sd` | Landscape · 800×480 | Paisaje · 800×480 |
| `pref_res_land_hd` | Landscape · 1280×720 (HD) | Paisaje · 1280×720 (HD) |
| `pref_res_port_sd` | Portrait · 720×1280 | Retrato · 720×1280 |
| `pref_res_port_hd` | Portrait · 1080×1920 (HD) | Retrato · 1080×1920 (HD) |
| `pref_mirror_orient_dash` | Match dash (recommended) | (missing — falls back to EN) |
| `pref_mirror_orient_follow` | Follow phone | (missing — falls back to EN) |
| `pref_mirror_orient_land` | Landscape | (missing — falls back to EN) |
| `pref_mirror_orient_port` | Portrait | (missing — falls back to EN) |
| `pref_hold_ignored` | Ignored while Hold detection is Off | Ignorado mientras la detección de retención está desactivada |
| `setup_toast_video_quality` | Video quality: %1$s | Calidad de vídeo: %1$s |
| `setup_toast_screen_fit` | Screen fit: %1$s | Ajuste de pantalla: %1$s |
| `setup_toast_mirror_orient` | Mirror orientation: %1$s | (missing — falls back to EN) |
| `setup_toast_power_mode` | Power mode: %1$s | Modo de energía: %1$s |
| `setup_toast_resolution` | Resolution: %1$s | Resolución: %1$s |
| `setup_toast_map_theme` | Map theme: %1$s | Tema del mapa: %1$s |
| `setup_toast_dbl_tap` | Double-tap delay: %1$s | Retardo de doble pulsación: %1$s |
| `setup_toast_hold` | Hold delay: %1$s | Retardo de pulsación larga: %1$s |
| `setup_toast_transport` | Wi‑Fi transport: %1$s | Transporte Wi-Fi: %1$s |
| `setup_privacy` | Privacy | Privacidad |
| `setup_anonymous_telemetry` | Anonymous usage & crash reports | Informes anónimos de uso y fallos |
| `setup_anonymous_telemetry_desc` | Sends a random device id, app version, and (if any) crash/error text to the OpenCfMoto project so we can see how many phones use the app and fix crashes. No account, no GPS routes, no Wi‑Fi passwords, no bike name. Off = nothing is uploaded. | Envía un id aleatorio, la versión de la app y (si hay) texto de crash/error al proyecto OpenCfMoto para ver cuántos móviles la usan y corregir fallos. Sin cuenta, sin rutas GPS, sin contraseñas Wi‑Fi, sin nombre de moto. Desactivado = no se sube nada. |
| `setup_anonymous_telemetry_on` | On — anonymous pings & crash reports | Activado — pings y fallos anónimos |
| `setup_anonymous_telemetry_off` | Off — nothing uploaded | Desactivado — no se sube nada |
| `setup_anonymous_id` | Anonymous id: %1$s | Id anónimo: %1$s |

### 9.5 Garage & QR scanner (`garage_*`, `qr_*`)

| Key | EN | ES |
|---|---|---|
| `garage_garage` | Garage | Garaje |
| `garage_each_bike_keeps_its_own_name_photo_screen_fit_re` | Each bike keeps its own name, photo, screen fit, resolution, power mode and button mapping. Tap a bike to make it active or edit it. | Cada moto mantiene su propio nombre, foto, ajuste de pantalla, resolución, modo de energía y asignación de botones. Toca una moto para activarla o editarla. |
| `garage_no_bikes_yet_scan_your_dash_qr_or_enter_wi_fi_na` | No bikes yet.\nScan your dash QR, or enter Wi‑Fi name + password (TRK). | Aún no hay motos.\nEscanea el QR del tablero o introduce el nombre de Wi-Fi y la contraseña (TRK). |
| `garage_scan_new_bike` | Scan new bike | Escanear una moto nueva |
| `garage_enter_wi_fi_manually` | Enter Wi‑Fi manually | Ingresar Wi-Fi manualmente |
| `qr_point_the_camera_at_the_bike_s_motoplay_qr_if_it` | Point the camera at the bike's MotoPlay QR\n\nIf it won't scan — try the iOS / CarPlay QR, or enter Wi‑Fi manually (TRK). | Apunta la cámara al QR de MotoPlay de la moto\n\nSi no escanea, prueba con el QR de iOS/CarPlay o introduce el Wi-Fi manualmente (TRK). |
| `qr_1x` | 1x | 1x |
| `qr_2x` | 2x | 2x |
| `qr_3x` | 3x | 3x |
| `qr_from_photo` | Import QR from photo | Importar QR desde una foto |

### 9.6 Screen margins & match aspect (`margins_*`, `res_*`)

| Key | EN | ES |
|---|---|---|
| `res_match_panel_aspect` | Match panel aspect | Ajustar a la proporción del panel |
| `res_makes_android_auto_render_at_your_dash_s_real_as` | Makes Android Auto render at your dash's real aspect ratio (AAP margins + crop) so the map can fill the screen without cropping or stretching. Auto uses the size the bike reports (or the profile). Odd panels (near-square, tall portrait) benefit; normal landscape dashes get zero margins and stay the same. | Hace que Android Auto se dibuje con la proporción real de tu tablero (márgenes AAP + recorte) para que el mapa llene la pantalla sin recortar ni estirar. Auto usa el tamaño que informa la moto (o el perfil). Beneficia a los paneles raros (casi cuadrados, verticales alargados); los tableros horizontales normales se quedan con márgenes cero y no cambian. |
| `res_off` | Off | Apagado |
| `res_manual` | Manual | Manual |
| `res_panel_width` | Panel width | Ancho del panel |
| `res_panel_height` | Panel height | Altura del panel |
| `res_save` | Save | Guardar |
| `res_detected_panel` | Detected panel %1$d×%2$d (from bike / profile). | Panel detectado %1$d×%2$d (según la moto / el perfil). |
| `res_no_panel_size_yet` | No panel size yet — connect once so the bike reports its screen; Auto will use it next time. | Aún no hay tamaño de panel: conecta una vez para que la moto informe de su pantalla; Auto lo usará la próxima vez. |
| `res_match_aspect_off_note` | Match aspect off — Screen fit letterbox/crop applies as before. | Ajustar proporción desactivado: el Ajuste de pantalla (barras/recorte) se aplica como antes. |
| `res_no_margins_until_panel` | No margins until a panel size is known. | No hay márgenes hasta conocer el tamaño del panel. |
| `res_aa_matches_panel` | AA %1$d×%2$d already matches this panel — margins 0 (no change). | AA %1$d×%2$d ya coincide con este panel: márgenes 0 (sin cambios). |
| `res_aa_coded_margins` | AA coded %1$d×%2$d → margins %3$d×%4$d, content %5$d×%6$d (aspect %7$s). Fills the panel; Screen fit no longer matters while margins apply. | AA codificado %1$d×%2$d → márgenes %3$d×%4$d, contenido %5$d×%6$d (proporción %7$s). Llena el panel; el Ajuste de pantalla deja de importar mientras se apliquen márgenes. |
| `margins_screen_margins` | Screen margins | Márgenes de la pantalla |
| `margins_inset_android_auto_from_each_edge_of_the_dash_pi` | Inset Android Auto from each edge of the dash (pixels). On 800NK Advanced, add a top margin so MotoPlay's pull-down handle doesn't steal swipes. | Aparta Android Auto de cada borde del tablero (en píxeles). En la 800NK Advanced, añade margen superior para que la pestaña desplegable de MotoPlay no se robe las pulsaciones. |
| `margins_top` | Top | Arriba |
| `margins_0` | 0 | 0 |
| `margins_bottom` | Bottom | Abajo |
| `margins_left` | Left | Izquierda |
| `margins_right` | Right | Derecha |
| `margins_reset_to_profile_default` | Reset to profile default | Restablecer al valor del perfil |
| `margins_summary_none` | None — Android Auto uses the whole dash | Ninguno: Android Auto usa todo el tablero |
| `margins_summary_profile_default` | Top %1$d · bottom %2$d · left %3$d · right %4$d px (profile default) | Arriba %1$d · abajo %2$d · izquierda %3$d · derecha %4$d px (valor del perfil) |
| `margins_summary_custom` | Top %1$d · bottom %2$d · left %3$d · right %4$d px | Arriba %1$d · abajo %2$d · izquierda %3$d · derecha %4$d px |

### 9.7 Trips (`trip_*`, `trips_*`)

| Key | EN | ES |
|---|---|---|
| `trip_trip_computer` | Trip computer | Ordenador de viaje |
| `trip_saved_trips` | Saved trips | Viajes guardados |
| `trip_waiting_for_gps` | Waiting for GPS… | Esperando al GPS… |
| `trip_distance` | Distance | Distancia |
| `trip_0_00_km` | 0.00 km | 0.00 km |
| `trip_duration` | Duration | Duración |
| `trip_00_00_00` | 00:00:00 | 00:00:00 |
| `trip_max_speed` | Max speed | Velocidad máxima |
| `trip_0_km_h` | 0 km/h | 0 km/h |
| `trip_avg_speed` | Avg speed | Velocidad media |
| `trip_speed_and_distance_come_from_the_phone_s_gps_the` | Speed and distance come from the phone's GPS (the bike doesn't share telemetry over the mirroring link). Keep a clear view of the sky for best accuracy. | La velocidad y la distancia salen del GPS del teléfono (la moto no comparte telemetría por el enlace de duplicación). Para más precisión, deja el teléfono con el cielo despejado a la vista. |
| `trip_start` | Start | Comenzar |
| `trip_pause` | Pause | Pausar |
| `trip_reset` | Reset | Reiniciar |
| `trips_trips` | Trips | Viajes |
| `trips_previous_day` | Previous day | Día anterior |
| `trips_str` | ‹ | ‹ |
| `trips_next_day` | Next day | Día siguiente |
| `trips_str_2` | › | › |
| `trips_today` | Today | Hoy |
| `trips_no_rides_this_day` | No rides this day. | No hay viajes este día. |
| `trips_no_trips_yet` | No trips yet.\nRides log automatically while you project Android Auto or use the built-in Map — or record one from the Trip screen. | Aún no hay viajes.\nLos viajes se registran solos mientras proyectas Android Auto o usas el mapa integrado, o puedes grabar uno desde la pantalla Viaje. |
| `trips_no_rides_browse_days` | No rides this day.\nUse ‹ › to browse other days. | No hay viajes este día.\nUsa ‹ › para ver otros días. |
| `trips_no_rides_summary` | No rides | Sin viajes |
| `trips_day_summary[one]` | %1$d ride · %2$.1f km | %1$d viaje · %2$.1f km |
| `trips_day_summary[other]` | %1$d rides · %2$.1f km | %1$d viajes · %2$.1f km |
| `trips_route_preview` | Route preview | Vista previa de la ruta |
| `trips_stat_time` | Time | Tiempo |
| `trips_stat_avg` | Avg | Media |
| `trips_stat_max` | Max | Máx. |
| `trips_export_gpx` | Export GPX | Exportar GPX |
| `trips_no_gps_points` | Trip has no GPS points | El viaje no tiene puntos GPS |
| `trips_export_failed` | Export failed: %1$s | Error al exportar: %1$s |
| `trips_delete_trip_title` | Delete trip? | ¿Eliminar el viaje? |
| `trips_delete` | Delete | Eliminar |

### 9.8 Controls, button mapping, saved places (`controls_*`, `buttons_*`, `row_saved_place_*`)

| Key | EN | ES |
|---|---|---|
| `buttons_button_mapping` | Button mapping | Asignación de botones |
| `buttons_choose_what_each_handlebar_gesture_does_in_andro` | Choose what each handlebar gesture does in Android Auto. Changes apply on the next press — no reconnect needed. Requires the phone paired to the bike over Bluetooth. | Elige qué hace cada gesto del manillar en Android Auto. Los cambios se aplican en la siguiente pulsación; no es necesario volver a conectarse. Requiere que el teléfono esté emparejado con la moto a través de Bluetooth. |
| `buttons_bt_status_placeholder` | Bluetooth: … | Bluetooth: … |
| `buttons_teach_handlebar` | Teach my handlebar… | Enseñar mi manillar… |
| `buttons_remote_pad` | Bluetooth remote pad | (missing — falls back to EN) |
| `buttons_remote_pad_desc` | Pair a gamepad, ring remote, or keypad. AVRCP remotes already drive Android Auto when handlebar capture is on. HID D-pad / face buttons need this screen or the main app in front. Each press stands in for a handlebar gesture. | (missing — falls back to EN) |
| `buttons_teach_remote` | Teach a remote button… | (missing — falls back to EN) |
| `buttons_teach_remote_pick` | Which handlebar gesture should the next remote press do? | (missing — falls back to EN) |
| `buttons_teach_remote_wait` | Press a button on the remote… | (missing — falls back to EN) |
| `buttons_teach_remote_ok` | Mapped %1$s → %2$s | (missing — falls back to EN) |
| `buttons_teach_title` | Teach my handlebar | Enseñar mi manillar |
| `buttons_teach_message` | Which buttons does this bike actually send?\n\n• ▲/▼ volume rocker — if the bike never changes phone volume when you press them, mark Absent so we stop pinning volume.\n• ◀/▶ / Select track keys — mark Absent if those never arrive.\n\nYou can also leave Unknown: after ~90s of streaming with no ▲/▼ we mark the rocker Absent automatically. | ¿Qué botones envía realmente esta moto?\n\n• Balancín de volumen ▲/▼: si la moto nunca cambia el volumen del teléfono al pulsarlos, marca Ausente para que dejemos de fijar el volumen.\n• Teclas ◀/▶ / cambio de pista: marca Ausente si nunca llegan.\n\nTambién puedes dejarlo en Desconocido: tras unos 90 s proyectando sin ▲/▼ marcamos el balancín como Ausente automáticamente. |
| `buttons_teach_volume_present` | ▲/▼ works | ▲/▼ funciona |
| `buttons_teach_volume_absent` | ▲/▼ absent | ▲/▼ ausente |
| `buttons_teach_reset` | Reset to untested | Volver a sin probar |
| `buttons_your_left_switch_cluster` | Your left switch cluster | Tu piña de mandos izquierda |
| `buttons_cfmoto_ships_a_few_different_left_pods_pick_the_` | CFMOTO ships a few different left pods. Pick the one that matches your bars — doubles and long-press do not work the same on every cluster. | CFMOTO monta varias piñas izquierdas distintas. Elige la que coincida con tu manillar: las pulsaciones dobles y largas no funcionan igual en todas. |
| `buttons_no_preset_shipped_defaults_your_custom_map` | No preset — shipped defaults / your custom map | Sin preajuste: valores de fábrica o tu mapa personalizado |
| `buttons_apply_preset` | Apply preset… | Aplicar preajuste… |
| `buttons_clear_preset` | Clear preset | Borrar preajuste |
| `buttons_gestures` | Gestures | Gestos |
| `buttons_reset_to_defaults` | Reset to defaults | Restablecer los valores predeterminados |
| `buttons_saved_places` | Saved places | Lugares guardados |
| `buttons_map_a_gesture_to_navigate_to_saved_place_and_a_p` | Map a gesture to “Navigate to saved place” and a press starts turn-by-turn there — hands-free. | Asigna un gesto a «Navegar al lugar guardado»: una pulsación arranca ahí la navegación paso a paso, sin soltar el manillar. |
| `buttons_allow_navigate_from_handlebars` | Allow navigate-from-handlebars | Permitir navegar desde el manillar |
| `buttons_starting_navigation_from_a_handlebar_button_whil` | Starting navigation from a handlebar button while the app is in your pocket needs the “Display over other apps” permission. Without it, use the in-app “Navigate to…” box instead. | Iniciar la navegación desde un botón del manillar con la aplicación en el bolsillo necesita el permiso «Mostrar sobre otras aplicaciones». Sin él, usa el cuadro «Navegar a…» de la aplicación. |
| `buttons_enable_display_over_other_apps` | Enable “Display over other apps” | Activar «Mostrar sobre otras aplicaciones» |
| `controls_controls` | Controls | Controles |
| `controls_drive_android_auto_without_touching_the_dash_typ` | Drive Android Auto without touching the dash: type a destination, use the on-screen pad, or map the bike's handlebar buttons. | Conduce Android Auto sin tocar el tablero: escribe un destino, usa el teclado en pantalla o asigna los botones del manillar de la moto. |
| `controls_navigate_to` | Navigate to… | Navega a… |
| `controls_type_an_address_or_place_the_route_appears_on_th` | Type an address or place; the route appears on the dash. Enter it while parked. | Escribe una dirección o un lugar y la ruta aparece en el tablero. Hazlo con la moto parada. |
| `controls_destination` | Destination | Destino |
| `controls_navigate` | Navigate | Navegar |
| `controls_map_theme` | Map theme | Tema del mapa |
| `controls_auto_switches_the_dash_map_to_dark_at_night_and_` | Auto switches the dash map to dark at night and light by day. Applies instantly while projecting. | Auto cambia el mapa del tablero a oscuro por la noche y claro durante el día. Se aplica instantáneamente mientras proyecta. |
| `controls_auto` | Auto | Auto |
| `controls_day` | Day | Día |
| `controls_night` | Night | Noche |
| `controls_on_screen_pad` | On-screen pad | Cruceta en pantalla |
| `controls_fullscreen` | Fullscreen | Pantalla completa |
| `controls_the_rotary_knob_steps_through_lists_the_arrows_j` | The rotary knob steps through lists; the arrows jump between areas. Works only while Android Auto is projecting. Use Fullscreen while riding — the phone stays awake. | El mando giratorio recorre las listas; las flechas saltan entre áreas. Solo funciona mientras Android Auto está proyectando. Usa la pantalla completa mientras conduces: el teléfono se mantiene activo. |
| `controls_volume` | Volume | Volumen |
| `controls_phone_media_volume_nav_voice_music_use_this_when` | Phone media volume (nav voice & music). Use this when the bike's volume buttons drive Android Auto. | Volumen multimedia del teléfono (voz de navegación y música). Úsalo cuando los botones de volumen de la moto controlen Android Auto. |
| `controls_low` | Low | Bajo |
| `controls_8` | 8 | 8 |
| `controls_prev` | ⟲ Prev | ⟲ Anterior |
| `controls_str` | ▲ | ▲ |
| `controls_next` | Next ⟳ | Siguiente ⟳ |
| `controls_str_2` | ◀ | ◀ |
| `controls_str_3` | ▶ | ▶ |
| `controls_str_4` | ▼ | ▼ |
| `controls_back` | Back | Atrás |
| `controls_home` | Home | Inicio |
| `controls_voice` | Voice | Voz |
| `controls_handlebar_buttons` | Handlebar buttons | Botones del manillar |
| `controls_your_dash_is_a_touchscreen_just_tap_the_screen_t` | Your dash is a touchscreen — just tap the screen to navigate. Handlebar-button control is meant for non-touch dashes (e.g. 450SR); on this bike it can't move the menu and only pauses your music. | Tu tablero es una pantalla táctil: toca la pantalla para navegar. El control por botones del manillar está pensado para tableros no táctiles (por ejemplo, la 450SR); en esta moto no mueve el menú y solo pausa la música. |
| `controls_handlebar_buttons_drive_android_auto` | Handlebar buttons drive Android Auto | Los botones del manillar controlan Android Auto |
| `controls_requires_the_phone_paired_to_the_bike_over_bluet` | Requires the phone paired to the bike over Bluetooth.\n\nWhile on, the bars drive the Android Auto UI (not track-skip). Music can keep playing — start/stop/skip by navigating that UI with the bars or the on-screen pad. Turn OFF only if you want the physical bars to control media again. | Requiere que el teléfono esté emparejado con la moto por Bluetooth.\n\nMientras esté activado, el manillar controla la interfaz de Android Auto (sin cambio de pista). La música puede seguir sonando: inicia, detén o salta navegando por esa interfaz con el manillar o con la cruceta en pantalla. Desactívalo solo si quieres que los botones físicos vuelvan a controlar la reproducción. |
| `controls_customize_buttons` | Customize buttons | Personalizar botones |
| `row_saved_place_name_e_g_home` | Name (e.g. Home) | Nombre (p. ej. Casa) |
| `row_saved_place_address_or_place` | Address or place | Dirección o lugar |

### 9.9 Dash UI & dash view labels (`dash_*`, `dashset_*`, `hud_*`) — useful for the iOS-rendered dash

| Key | EN | ES |
|---|---|---|
| `hud_start_android_auto_and_connect_to_your_bike_to_s` | Start Android Auto and connect to your bike to see the dash here.\n\nOr tap Map for a phone preview without the bike. | Inicia Android Auto y conéctate a tu moto para ver aquí el tablero.\n\nO toca Mapa para una vista previa en el teléfono, sin la moto. |
| `hud_str` | ✕ | ✕ |
| `hud_dash_view` | Dash view | Vista de tablero |
| `hud_hub` | Hub | Centro |
| `hud_str_2` | 🌗 | 🌗 |
| `hud_str_3` | ⛶ | ⛶ |
| `hud_str_4` | ⟲ | ⟲ |
| `hud_str_5` | ⟳ | ⟳ |
| `hud_str_6` | 🎙 | 🎙 |
| `dashset_settings` | Settings | Ajustes |
| `dashset_theme` | Theme | Tema |
| `dashset_next_stop` | Next stop | Próxima parada |
| `dashset_auto_finish` | Auto-finish | Finalizar automáticamente |
| `dashset_chrome` | Chrome | Interfaz |
| `dashset_3d` | 3D | 3D |
| `dashset_legacy_scenic_length_unused_circuit_is_there_and` | Legacy scenic length (unused — Circuit is there and back) | Longitud escénica heredada (sin usar: el circuito es de ida y vuelta) |
| `dashset_30` | 30 | 30 |
| `dashset_60` | 60 | 60 |
| `dashset_100` | 100 | 100 |
| `dash_search_here` | Search here | Busca aquí |
| `dash_next_maneuver` | Next maneuver | Próxima maniobra |
| `dash_time` | TIME | TIEMPO |
| `dash_arrive` | ARRIVE | LLEGAR |
| `dash_left` | LEFT | IZQUIERDA |
| `dash_alt_m` | ALT m | ALT m |
| `dash_limit` | LIMIT | LÍMITE |
| `dash_end` | End | Fin |
| `dash_save` | ★ Save | ★ Guardar |
| `dash_marker` | ＋ Marker | ＋ Marcador |
| `dash_you_ve_arrived` | You've arrived | Has llegado |
| `dash_mark_this_spot_or_keep_riding` | Mark this spot or keep riding | Marca este lugar o sigue conduciendo |
| `dash_park_here` | Park here | Aparca aquí |
| `dash_find_parking` | Find parking | Buscar aparcamiento |
| `dash_done_free_ride` | Done · free ride | Listo · ruta libre |
| `dash_recenter_gps` | Recenter GPS | Recentrar el GPS |
| `dash_zoom_in` | Zoom in | Acercar |
| `dash_zoom_out` | Zoom out | Alejar |
| `dash_compass` | Compass | Brújula |
| `dash_menu` | Menu | Menú |
| `dash_fit_route` | Fit route | Encuadrar la ruta |
| `dash_search_places_or_address` | Search places or address | Buscar lugares o dirección |
| `dash_end_navigation` | End navigation | Finalizar navegación |
| `dash_go_home` | Go Home | Ir a casa |
| `dash_recenter_recalc` | Recenter / Recalc | Recentrar/Recalcular |
| `dash_record_ride` | Record ride | Grabar la ruta |
| `dash_follow` | Follow | Seguir |
| `dash_heading_up` | Heading up | Rumbo arriba |
| `dash_str` | － | － |
| `dash_str_2` | ＋ | ＋ |
| `dash_close` | Close | Cerrar |
| `dash_cancel` | Cancel | Cancelar |

### 9.10 Notifications (`notif_*`)

| Key | EN | ES |
|---|---|---|
| `notif_aa_channel` | Android Auto receiver | Receptor de Android Auto |
| `notif_aa_title` | OpenCfMoto — Android Auto | OpenCfMoto - Android Auto |
| `notif_aa_reconnecting` | Reconnecting to the bike dash… | Reconectándose al tablero de la moto... |
| `notif_aa_receiving` | Receiving Android Auto for the bike dash — tap to open | Recibiendo Android Auto para el tablero de la moto: toca para abrir |
| `notif_bike_reconnected` | Bike reconnected | Moto reconectada |
| `notif_tap_resume` | Tap to resume projection to the dash | Toca para reanudar la proyección en el tablero |
| `notif_map_title` | OpenCfMoto Map | Mapa de OpenCfMoto |
| `notif_map_text` | Map on the dash — handlebars use your button mapping | Mapa en el tablero: los manillares usan el mapeo de botones |
| `notif_mirror_channel` | Screen mirroring | Duplicación de pantalla |
| `notif_mirror_title` | OpenCfMoto | OpenCfMoto |
| `notif_mirror_text` | Mirroring screen to bike | Duplicando la pantalla en la moto |
| `notif_media_channel` | Bike button control | Control de Android Auto |
| `notif_media_title` | Android Auto control | Control por botones de la moto |
| `notif_media_text` | Bike buttons drive Android Auto | Los botones de la moto controlan Android Auto |

### 9.11 About (`app_name`, `about_*`)

| Key | EN | ES |
|---|---|---|
| `app_name` | Open CfMoto | Open CfMoto |
| `about_copyright` | © 2026 Alexandru | © 2026 Alexandru |
| `about_copyright_body` | Maintained by Alexandru (zanderp). Free software under the GNU AGPL v3 or later — see LICENSE and NOTICE in the repository for the full copyright and attribution text. | Mantenido por Alexandru (zanderp). Software libre bajo la GNU AGPL v3 o posterior: consulta LICENSE y NOTICE en el repositorio para ver el texto completo de derechos de autor y atribución. |
| `about_license_body` | You may use, study, share, and modify this app under the AGPL. If you redistribute a modified version (including as a network service), you must offer the complete corresponding source under the same license. | Puedes usar, estudiar, compartir y modificar esta aplicación según la AGPL. Si redistribuyes una versión modificada (incluso como servicio de red), debes ofrecer el código fuente correspondiente completo bajo la misma licencia. |
| `about_credits` | Built on the open-cfmoto community lineage:\n\n• dcoletto / coletz — original QR & EasyConn work\n• BojanJ — Android Auto receiver integration\n• richardbizik — 1000 MT‑X support\n• ionutradu252 / open-cflink — handlebar controls, margins, reconnect & polish\n• eugen0309 — Wi‑Fi Direct / CL‑C450 path\n• Martin Escudero (martinescudero) — Android Auto 17.4+ head unit server path\n• Glifaus — Wi‑Fi Direct keep-alive\n• sashop2001 — AA DPI, Bluetooth trigger, Bulgarian\n• Authoritt — vehicle telemetry field notes\n• headunit-revived — Android Auto projection stack (AGPL)\n\nAnd everyone who tested bikes, shared logs, and filed issues. | Construido sobre el linaje de la comunidad open-cfmoto:\n\n• dcoletto / coletz: trabajo original de QR y EasyConn\n• BojanJ: integración del receptor Android Auto\n• richardbizik: compatibilidad con 1000 MT‑X\n• ionutradu252 / open-cflink — controles del manillar, márgenes, reconexión y pulido\n• eugen0309 — vía Wi‑Fi Direct/CL‑C450\n• unidad central revivida: pila de proyección de Android Auto (AGPL)\n\nY todos los que probaron motos, compartieron registros y abrieron incidencias. |
| `about_disclaimer` | OpenCfMoto is an independent community project. It is not affiliated with, endorsed by, or sponsored by CFMOTO, Carbit, Google, Android Auto, or other brands that license EasyConnect-style dashes (including Voge, Zontes, Moto Morini, Benelli, Rieju, QJ Motor, Morbidelli, Longjia, and Kove). CFMOTO, MotoPlay, EasyConn, Carbit, Android, Android Auto, and related marks are trademarks of their respective owners. Use at your own risk — set your route before you ride. | OpenCfMoto es un proyecto comunitario independiente. No está afiliado, respaldado ni patrocinado por CFMOTO, Carbit, Google, Android Auto u otras marcas que otorgan licencias para tableros estilo EasyConnect (incluidas Voge, Zontes, Moto Morini, Benelli, QJ Motor, Morbidelli y Longjia). CFMOTO, MotoPlay, EasyConn, Carbit, Android, Android Auto y las marcas relacionadas son marcas comerciales de sus respectivos propietarios. Úsalo bajo tu propia responsabilidad: fija la ruta antes de salir. |
| `about_about` | About | Acerca de |
| `about_wireless_android_auto_for_carbit_easyconnect_das` | Wireless Android Auto for Carbit / EasyConnect dashes (CFMoto MotoPlay and siblings). | Android Auto inalámbrico para tableros Carbit/EasyConnect (CFMoto MotoPlay y hermanos). |
| `about_community_support` | Community & support | Comunidad y soporte |
| `about_questions_logs_or_a_new_bike_join_discord_tips_k` | Questions, logs, or a new bike? Join Discord. Tips keep the project moving. | ¿Preguntas, registros o una moto nueva? Únete a Discord. Los consejos mantienen el proyecto en movimiento. |
| `about_discord` | Discord | Discord |
| `about_donate` | Donate | Donar |
| `about_copyright_2` | Copyright | Derechos de autor |
| `about_website_alexandru_rocks` | Website — alexandru.rocks | Sitio web — alexandru.rocks |
| `about_source_on_github` | Source on GitHub | Código fuente en GitHub |
| `about_license` | License | Licencia |
| `about_gnu_affero_general_public_license_v3_or_later` | GNU Affero General Public License v3 or later | Licencia Pública General Affero de GNU v3 o posterior |
| `about_view_license_notice` | View LICENSE & NOTICE | Ver LICENSE y NOTICE |
| `about_credits_2` | Credits | Créditos |
| `about_disclaimer_2` | Disclaimer | Descargo de responsabilidad |
| `about_done` | Done | Hecho |

### 9.12 Supported bikes (`supported_bikes_*`)

| Key | EN | ES |
|---|---|---|
| `supported_bikes_intro` | Works with CFMoto MotoPlay / EasyConnect and other Carbit-framework dashes that show a pairing QR. No T‑BOX required. US and international — if you see the QR, try Connect. | Funciona con CFMoto MotoPlay/EasyConnect y otros tableros del entorno Carbit que muestran un QR de emparejamiento. No hace falta T-BOX. EE. UU. e internacional: si ves el QR, prueba Connect. |
| `supported_bikes_confirmed_title` | Confirmed with OpenCfMoto | Confirmado con OpenCfMoto |
| `supported_bikes_confirmed` | CFMoto: 800MT (MT‑X / Explore / Explore GT / Ibex 800) · 1000 MT‑X · 800NK (US CRCP) · 800NK Advanced · 675NK · 675SR‑R · 700MT Adventure · 450MT · 450SR (+ SR‑S / TC) · 450CL‑C / CL‑C450 · 450NK · 150SC scooter · CFORCE 850 / 1000 · GOES Terrox 1000 / Gladiator G3 1000\nOther: Voge DS800 Rally / DS900X · Moto Morini X-Cape 649 / 700 / Seiemmezzo · Benelli TRK 702 / 702X · Rieju 307 · Zontes 125X · Morbidelli T1002VX / T352X · QJ Motor SRK800RR / SRK450RR / SRK250RD / SRT 600 / SRV600 | CFMoto: 800MT (MT‑X / Explore / Explore GT) · 1000 MT‑X · 800NK (US CRCP) · 800NK Advanced · 675NK · 700MT Adventure · 450MT · 450SR (+ SR‑S / TC) · 450CL‑C / CL‑C450 · 450NK · 150SC scooter · CFORCE 850 / 1000 · GOES Terrox 1000 / Gladiator G3 1000\nOtros: Voge DS800 Rally / DS900X · Moto Morini X-Cape 649 / 700 / Seiemmezzo · Benelli TRK 702 / 702X · Rieju 307 · Zontes 125X · Morbidelli T1002VX / T352X · QJ Motor SRK800RR / SRK450RR / SRK250RD / SRT 600 / SRV600 |
| `supported_bikes_other_title` | Other brands (Carbit / EasyConnect) | Otras marcas (Carbit / EasyConnect) |
| `supported_bikes_other` | Same Carbit QR path — try Connect if the dash shows a pairing QR. Report results in Discord.\nVoge (DS800 Rally / DS900X confirmed) · Moto Morini (X-Cape 649 / 700 / Seiemmezzo confirmed; 1200 SoftAP experimental; MotoFun) · Zontes (125X confirmed) · Benelli (e.g. TRK 702 / 702X) · Rieju (307 confirmed) · QJ Motor (SRK800RR / SRK250RD / SRK450RR / SRT/SRV 600 confirmed; 600SX / 550SX testing; Fort 4.0) · Morbidelli / MBP (T1002VX / T352X confirmed) · Longjia (e.g. V-Bob 650; MotoFUN / Carbit Ride — unconfirmed) · Kove (Thinkerride SoftAP experimental — no dash video yet) | Misma vía del QR de Carbit: prueba Connect si el tablero muestra un QR de emparejamiento. Informa de los resultados en Discord.\nVoge (DS800 Rally / DS900X confirmado) · Moto Morini (X-Cape 649 / 700 / Seiemmezzo confirmado; MotoFun) · Zontes (125X confirmado) · Benelli (por ejemplo, TRK 702 / 702X) · QJ Motor (SRK800RR / SRK250RD / SRK450RR / SRT/SRV 600 confirmados; 600SX / 550SX en pruebas; Fort 4.0) · Morbidelli / MBP (T1002VX confirmado) · Longjia (p. ej. V-Bob 650; MotoFUN / Carbit Ride — sin confirmar) |
| `supported_bikes_full_title` | Full list — known CFMoto EasyConnect / MotoPlay dashes | Lista completa: tableros CFMoto EasyConnect / MotoPlay conocidos |
| `supported_bikes_full` | Naked:  125NK · 450NK · 675NK · 800NK · 800NK Advanced · 800NK Sport · 800NK (US CRCP)\nSport:  300SR · 450SR · 450SR‑S · 450SR TC · 500SR VOOM · 675SR · 675SR‑R\nTouring / Adv:  450MT · 700MT · 700MT Adventure · 800MT‑X · 800MT Explore · 800MT Explore GT · 1000 MT‑X\nCruiser:  450CL‑C · CL‑C450\nScooter:  150SC\nATV / SSV (TFT):  CFORCE 800 · CFORCE 850 Touring · CFORCE 1000 · CFORCE 1000 Touring · GOES Terrox 1000 / Gladiator G3 1000\nOther:  U10 Pro (where the dash offers the QR) | Naked: 125NK · 450NK · 675NK · 800NK · 800NK Advanced · 800NK Sport · 800NK (US CRCP)\nDeportivas: 300SR · 450SR · 450SR‑S · 450SR TC · 500SR VOOM · 675SR · 675SR‑R\nTouring / Adv: 450MT · 700MT · 700MT Adventure · 800MT‑X · 800MT Explore · 800MT Explore GT · 1000 MT‑X\nCustom: 450CL‑C · CL‑C450\nScooter: 150SC\nATV / SSV (TFT): CFORCE 800 · CFORCE 850 Touring · CFORCE 1000 · CFORCE 1000 Touring · GOES Terrox 1000 / Gladiator G3 1000\nOtras: U10 Pro (donde el tablero ofrece el QR) |
| `supported_bikes_unlikely_title` | Usually no projection QR | Normalmente no hay QR de proyección |
| `supported_bikes_unlikely` | 800MT Sport · 800MT Touring · 450SR World Champion Edition · 700CL‑X (Adventure / Heritage / Sport) · PAPIO — unless your unit shows the QR anyway. | 800MT Sport · 800MT Touring · 450SR World Champion Edition · 700CL‑X (Adventure / Heritage / Sport) · PAPIO, a menos que tu unidad muestre el QR de todos modos. |
| `supported_bikes_footer` | Full list online: github.com/zanderp/open-cfmoto → docs/SUPPORTED-BIKES.md — report new bikes in Discord. | Lista completa en línea: github.com/zanderp/open-cfmoto → docs/SUPPORTED-BIKES.md: informa motos nuevas en Discord. |

### 9.13 Hard-coded English-only UI strings (not in resources) — with PROPOSED Spanish

The Android app shows these in English in every locale. The ES column is **my proposal** (not from the repo).

| Where | EN (verbatim) | ES (proposed) |
|---|---|---|
| Crash dialog `MainActivity.kt:340-345` | `OpenCfMoto closed unexpectedly last time. The log and crash report were saved — open Logs and tap Share Logs so we can see what happened.` · buttons `Share Logs` / `Keep logs` / `Dismiss` | `OpenCfMoto se cerró inesperadamente la última vez. El registro y el informe del fallo se guardaron: abre Registros y toca Compartir para que podamos ver qué pasó.` · `Compartir registros` / `Conservar registros` / `Descartar` |
| Mirror ready `MainActivity.kt:378-387` | `Entire screen — best for riding. Uses Setup ▸ Screen fit and Setup ▸ Mirror orientation (Match dash rotates the phone so the TFT fills).\n\nSingle app — that app must stay on screen; Android sends no frames in the background. Prefer GPX / Tracks or Android Auto for pocket use.\n\nBike touch does not drive mirrored apps. Continue connects and sends OpenCfMoto to the background.` · `Continue` | (rewrite for ReplayKit) `La pantalla completa del iPhone se envía al tablero. Los toques en el tablero no controlan las apps duplicadas. Para ir con el móvil en el bolsillo usa Mapa.` · `Continuar` |
| Duplicate mirror tap `MainActivity.kt:1504` | `Already mirroring — wait for the dash, or tap Stop first` | `Ya se está duplicando: espera al tablero o toca Detener primero` |
| Bike search `MainActivity.kt:612` | `Bike search open — type here. Results appear on the dash.` | `Búsqueda de la moto abierta: escribe aquí. Los resultados aparecen en el tablero.` |
| Official app dialog `MainActivity.kt:950-969` | `The official CFMoto/EasyConnect app is running and holding the bike's link ports, so the dash stays blank. Close it, then reconnect.\n\n"Close & retry" tries to stop it for you; if the dash is still blank, use "App settings" and tap Force stop.` · alt: `Something is holding the bike's link ports (10920-10922). Close any other CFMoto/EasyConnect app and reconnect.` · `Close & retry` / `App settings` / `Dismiss` | (iOS) `Otra app de CFMoto/EasyConnect está usando los puertos de enlace de la moto (10920-10922). Ciérrala desde el selector de apps y vuelve a conectar.` · `Reintentar` / `Descartar` |
| VPN dialog `MainActivity.kt:979-987` | title `VPN is blocking the bike`; `Android Auto reached the phone, but a VPN kill-switch is blocking the bike Wi‑Fi (Network.bindSocket → EPERM).\n\nFix (any one):\n• Turn the VPN off for this ride\n• Disable Always-on VPN → "Block connections without VPN"\n• Allow LAN / local network in the VPN app (PCAPdroid, AdGuard, etc.)\n\nThen tap Connect again.` · `VPN settings` / `Dismiss` | `La VPN está bloqueando la moto` · `Una VPN está bloqueando la red Wi‑Fi de la moto. Desactiva la VPN para este viaje o permite el acceso a la red local en la app de VPN, y vuelve a tocar Conectar.` · `Ajustes` / `Descartar` |
| Wi-Fi off `WifiGate.kt:106-117,140-141` | title `Turn on Wi‑Fi`; `OpenCfMoto joins the bike over Wi‑Fi, but your phone’s Wi‑Fi is off.\n\nTurn it on, then tap Connect again.` · `Wi‑Fi settings` / `Dismiss`; notification `OpenCfMoto can’t reach the bike — tap to open Wi‑Fi settings.` | `Activa el Wi‑Fi` · `OpenCfMoto se conecta a la moto por Wi‑Fi, pero el Wi‑Fi del teléfono está apagado.\n\nActívalo y vuelve a tocar Conectar.` |
| Update dialog `MainActivity.kt:1596-1606` | `Update <version>` · `Download` / `Skip` / `Later`; fallback notes `A newer OpenCfMoto release is available.` | `Actualización <versión>` · `Descargar` / `Omitir` / `Más tarde` |
| Setup toasts `SetupActivity.kt:361-465` | `Hold detection on` · `Hold detection off — long presses count as taps / ×2` · `Auto-connect on/off` · `Auto-recovery on/off` · `Bluetooth clock on/off` · `Keep bike Wi-Fi on/off` · `Trip logging on/off` · `Disable touchscreen: on/off` · `Force touchscreen: on/off` · `Bike profile: <label>` · `Shared logs will include secrets — turn off before posting publicly` · `Log redaction on` · suffix ` (applies next connect)` | `Detección de pulsación larga activada` · … · ` (se aplica en la próxima conexión)` |
| Settings import/share `SetupActivity.kt:228-271` | see §3.5 (`Import settings?`, `Empty file`, `Share settings JSON`, …) | `¿Importar ajustes?` · `Archivo vacío` · `Compartir ajustes JSON` |
| Garage `GarageActivity.kt:50-238` | `Invalid QR` · `Added <name>` · `Couldn't read that image` · `Active bike · tap to edit` · `tap to select or edit` · `Use this bike` · `Rename` · `Add photo` · `Change photo` · `Remove photo` · `Remove bike` · `Selected <name>` · `Rename bike` · `Bike name` · `Save` · `Cancel` · `Remove <name>?` · `This forgets its pairing, photo and settings. You can re-scan the dash QR or enter Wi‑Fi again later.` · `Remove` | `QR no válido` · `Añadida <nombre>` · `No se pudo leer esa imagen` · `Moto activa · toca para editar` · `toca para elegir o editar` · `Usar esta moto` · `Renombrar` · `Añadir foto` · `Cambiar foto` · `Quitar foto` · `Eliminar moto` · `Seleccionada <nombre>` · `Renombrar moto` · `Nombre de la moto` · `Guardar` · `Cancelar` · `¿Eliminar <nombre>?` · `Se olvidan su emparejamiento, su foto y sus ajustes. Puedes volver a escanear el QR o introducir el Wi‑Fi más tarde.` · `Eliminar` |
| Manual pairing `ManualWifiPairing.kt:51-73` | `Enter bike Wi‑Fi` · `For dashes that show SSID + password instead of a QR (e.g. Benelli TRK). Use the exact network name from the bike screen.` · `Wi‑Fi name (SSID)` · `Password` · `Bike name (optional)` · `Add bike` · `Cancel` · `SSID and password are required` | `Introduce el Wi‑Fi de la moto` · `Para tableros que muestran SSID y contraseña en lugar de un QR (p. ej. Benelli TRK). Usa el nombre de red exacto de la pantalla de la moto.` · `Nombre de Wi‑Fi (SSID)` · `Contraseña` · `Nombre de la moto (opcional)` · `Añadir moto` · `Cancelar` · `El SSID y la contraseña son obligatorios` |
| Trip HUD `TripActivity.kt:95-130` | `GPS is off` · `Turn on GPS/Location to record` · `Couldn't start GPS` · `Stopped` · `Acquiring GPS…` · `GPS fix` · `GPS fix ±<n>m` · `Location permission is required for the trip HUD` · unit `km/h` | `GPS desactivado` · `Activa la ubicación para grabar` · `No se pudo iniciar el GPS` · `Detenido` · `Buscando GPS…` · `GPS fijado` · `GPS fijado ±<n> m` · `Se necesita el permiso de ubicación para el ordenador de viaje` |
| Trip map `TripMapActivity.kt:55-82` | `Trip not found` · `Start` · `End` · `<dist> · <dur> · avg <n> · max <n> km/h` | `Viaje no encontrado` · `Inicio` · `Fin` · `<dist> · <dur> · media <n> · máx <n> km/h` |
| QR scanner `QrScanActivity.kt:48,100,135` | `Camera permission required` · `Camera bind failed: <msg>` · `QR photo failed` | `Se necesita permiso de cámara` · `No se pudo abrir la cámara: <msg>` · `No se pudo leer el QR de la foto` |
| About `AboutActivity.kt:32,56` | `Version <v>  ·  build <n>` · `Couldn't open link` | `Versión <v>  ·  compilación <n>` · `No se pudo abrir el enlace` |

---

## 10. README feature table (verbatim, `README.md:66-92`) with iOS applicability

| | | iOS |
| --- | --- | --- |
| 🗺️ **Android Auto on the dash** | Relays Google Maps / Waze / any AA app to the MotoPlay screen over Wi‑Fi. | **No** — replaced by our own dash UI (map + TBT HUD) |
| 👆 **Multi-touch** | Two-finger pinch-to-zoom and full tap/scroll straight from the dash touchscreen (ghost-touch filter for noisy digitizers). | Yes, driving our dash UI (input spec) |
| 📺 **Dash view** | Big home-screen button — watch and drive the live dash from the phone (touch, pad, fullscreen). | Yes — preview of our rendered dash frames |
| 🎛️ **Controls** | Big home-screen button — on-screen D-pad/knob, media volume, and handlebar-button mapping. | Yes (pad drives our UI; volume via `MPVolumeView`) |
| 🕹️ **Handlebar buttons → AA** | On touchless / focus-mode dashes, ◀/▶/★ (or ▲/▼) navigate Android Auto over Bluetooth — snappy singles, tap / hold / ×2, Teach-my-handlebar, every gesture remappable. | Yes → our UI via AVRCP remote commands |
| 🧭 **Navigate-to + saved places** | Type a destination or map a handlebar button to a saved place for one-press turn-by-turn. | Yes (our router) |
| 🎙️ **Voice / Assistant** | Streams your (helmet) mic to Android Auto so "Hey Google" sets a destination hands-free. | No (Siri not invokable); optional own speech search |
| ⚡ **One-tap Connect & Auto-connect** | Remembers your bike; reconnects on launch when in range; Wi‑Fi join timeout + auto re-join after ignition cycles. | Yes (no range scan) |
| 📶 **Wi‑Fi AP or Direct (P2P)** | Normal hotspot join, or **Wi‑Fi Direct** for dashes that are Group Owners (e.g. **CL‑C450**). Setup: Auto / AP / P2P. | AP only |
| 🖼️ **Screen margins** | Dedicated page — inset Android Auto from top/bottom/left/right (e.g. blank the 800NK Advanced MotoPlay pull-down). | Yes (dash UI insets + mirror) |
| 🏍️ **Garage (multiple bikes)** | Name + photo per bike; each keeps its own display, resolution, power, and button settings. | Yes |
| 🛰️ **Trip computer + ride logging** | Live speed/distance/duration from GPS, auto-logs every ride, day calendar of saved trips, route thumbnails, **Export GPX**. | Yes |
| 📐 **Smart resolution & learned panels** | Auto-fits recognized dashes; remembers measured panel size and picks a better AA resolution next connect. | Partly (remember canvas per SSID; no AA resolution) |
| 🌗 **Map dark mode** | Day / Night / Auto — from Setup, Controls, or Dash view; applies live. | Yes (our dash UI) |
| 🔋 **Battery & power tuning** | Smooth / Balanced / Saver + **Auto** (adapts to heat & Wi‑Fi). | Yes |
| 🛟 **Auto-recovery & seamless resume** | Stalled/dropped dash reconnects; long stop parks AA and re-projects when the bike returns. | Yes (no AA to park) |
| 🔄 **In-app updates** | Optional nag when a newer GitHub Release is available (Download / Skip / Later). | No (App Store/TestFlight) |
| 🧰 **Diagnostics & problem report** | Live logs (secrets redacted by default), Share Logs, and Setup → **Report a problem**. | Yes |
| 📤 **Share / import bike tuning** | Export profile, resolution, fit, margins & button map as JSON (no passwords / personal prefs) — share on Discord, Import on another phone. | Yes (format-compatible) |
| 📶 **Wi‑Fi-off alert** | If phone Wi‑Fi is off when connecting, a dialog offers **Wi‑Fi settings** (one tap). | Partly (iOS can't detect/open Wi-Fi settings directly) |
| 🗺️ **Map / GPX** | Free ride, GPX tracks, OSM search/POI, Home/favorites/markers, parked pin, road routing, voice cues — on the bike dash or phone. | Yes (map spec) |
| 📱 **Mirror phone** | Cast the phone screen when you really need it (screen on; awkward for nav apps). | Yes (ReplayKit, no touch back) |
| 🌐 **Languages** | Follows the phone language, or set **per-app** on Android 13+: Settings → Apps → OpenCfMoto → **Language**. Draft DE / IT / FR / ES / CA / PT / PL / CS / RO / NL / HU / TR ([docs/TRANSLATIONS.md](docs/TRANSLATIONS.md)). | Yes (iOS per-app language is built in) |

---

## 11. Privacy commitments to carry over (`PRIVACY.md`) [V-CODE/policy]

1. Local-first: no accounts, no sign-in, no ads (`PRIVACY.md:5-9,17`).
2. Ride data (bike profiles, trip GPS logs) stays on the device; never uploaded by the app (`PRIVACY.md:23,68,82`).
3. Trip logging is the one feature that records location history — on-device only, user-controllable (*Log trips
   automatically*), individually deletable (`PRIVACY.md:71-82`). iOS: honour the toggle, offer delete (and "delete
   all"), and explain background location use in the permission strings.
4. Diagnostic logs leave the device only when the user taps Share; passwords/serials redacted by default
   (`PRIVACY.md:69`; §6.2).
5. Camera only for scanning the pairing QR; frames are never stored or uploaded (`PRIVACY.md:38`).
6. Settings export never contains passwords, SSIDs, bike names or photos (§3).
7. Bike Wi-Fi passwords are stored in plaintext on Android (encryption "planned") (`PRIVACY.md:67`). **iOS should store
   the raw QR (it contains the password) in the Keychain** (`kSecAttrAccessibleAfterFirstUnlock`, so background
   reconnects work) and keep only non-secret metadata in UserDefaults/files.
8. Map tiles / geocoding requests go to third parties (OSM etc.) — disclose in the iOS privacy policy and App Store
   privacy label. iOS follows the OSMF tile policy on the default tile.openstreetmap.org: no route-corridor
   prefetch from the OSMF servers (only from a tile server the rider sets) and a "© OpenStreetMap" credit on the
   dash map (navigation-dash.md §10.4).
9. Telemetry: Android sends a random UUID, version, OS level, locale, redacted crash/error text, default ON. For iOS
   recommend **no telemetry** (simplest App Store privacy label); if ever added, make it opt-in.

---

## 12. Suggested iOS screen map (SwiftUI)

```
App (WindowGroup)
└─ NavigationStack ─ HomeView
   ├─ StatusCard (phase label, detail/bike line, ProgressView when busy, tinted icon)
   ├─ ConnectButton (Connect to <bike> ⇄ Stop)
   ├─ HStack: DashPreviewButton → DashPreviewView (live render of our dash UI + on-screen pad, fullscreen)
   │          ControlsButton → ControlsView (knob ◀▶, D-pad, Select/Back/Home, map theme, volume, "Customize buttons")
   │                           └─ ButtonMappingView (cluster presets, 9 gesture pickers, saved places ×3,
   │                              Teach my handlebar, remote pad (GameController))
   ├─ Tiles: Scan → QRScannerView (DataScannerViewController / AVFoundation; 1x/2x/3x; PhotosPicker import;
   │                                "Enter Wi‑Fi manually" sheet)
   │         Map → MapHubView (map spec)
   │         Mirror → MirrorSheet (RPSystemBroadcastPickerView + guidance)
   ├─ Footer: Setup → SettingsView        Garage → GarageView
   │          Trip → TripComputerView     Logs → (toggle LogsPanel inline, or LogsView)
   ├─ SearchField + Go (→ dash search / map hub search)
   └─ TipsCard: About & credits → AboutView · Report a problem → ProblemReportSheet · Donate (Link)
SettingsView (Form, sections in Android order minus AA):
   Display: Video quality · Power mode · Screen fit (mirror) · Screen margins… (ScreenMarginsView: 4 Sliders 0…200,
            Reset to profile default) · Map theme · Bike profile · Disable / Force touchscreen
   Handlebar: Double-tap delay · Hold detection · Hold delay
   Bluetooth: current audio route (AVAudioSession) + guidance to pair in iOS Settings
   Startup & recovery: Auto-connect · Auto-recovery · Log trips automatically
   Clock lab (EXPERIMENTAL, DisclosureGroup): presets · QUERY_TIME · TIME_SYNC · BLE listen · Keep Wi‑Fi
   Wi‑Fi & logs: (transport hidden or AP-only) · Include secrets in shared logs · Share settings (ShareLink) /
                 Import… (.fileImporter [.json])
   Permissions: Local Network · Location · Camera · Notifications (status + "Open Settings")
   Supported bikes (DisclosureGroups) · About
GarageView: List (active badge, photo thumb, swipe Delete, context menu Use/Rename/Photo/Remove), toolbar
            "Scan new bike" / "Enter Wi‑Fi manually"; empty state
TripComputerView: big speed, GPS line, 2×2 stats, Start / Stop & save / Discard, "Saved trips" →
   TripsListView (day pager ‹ Today ›, summary, cards with thumbnail + stats + ShareLink(GPX), swipe/long-press delete)
   └─ TripDetailView (MapKit polyline, start/end annotations, stats line)
LogsView: live log (monospace), Share (ShareLink files), Clear
```

Android features that do **not** apply on iOS: Android Auto setup checklist (install, head-unit mode, *Start head
unit server*), phases `STARTING_AA`/`AA_VIDEO_LIVE` and their errors, AA resolution/DPI/match-aspect pages, Google
Maps hand-off from the search box, Voice/Assistant mic streaming, Wi-Fi Direct (P2P) transport, phone-hotspot tether
detection (iOS cannot set the hotspot SSID — open question), Bluetooth ACL connect trigger, seamless-resume overlay
permission, "close the official app" force-stop, KILL_BACKGROUND_PROCESSES, mirror orientation lock, in-app APK
updates, DependencyPrompt (AA/Play services), Wi-Fi-off detection + settings deep link, logcat mirroring,
notification channels (use Live Activities / local notifications instead).

---

## 13. iOS implementation notes

1. **Settings store.** Use one `SettingsStore` with typed accessors over `UserDefaults` (suite in the App Group so
   the broadcast extension can read video/margins/fit). Implement the scoped lookup exactly:
   `scoped(base, bikeId) ?? global(base) ?? default`; writes go to the scoped key when a bike is selected. Keep the
   Android key names (`video_quality#b58cde373`) so the mental model and logs match.
2. **Enum persistence.** Persist the Android strings (`"BALANCED"`, `"auto"`, `"knobBack"`), not Swift raw ints —
   the same strings appear in the settings JSON. Decode leniently (unknown → default) like Android.
3. **Secrets.** Raw QR = Wi-Fi password: store garage `raw` in the Keychain (one item per bike id, or one JSON
   blob); never log it unredacted; never include it in exports, problem reports or crash files.
4. **Photo paths** must be relative (container UUID changes).
5. **Trips.** `CLLocationManager` with `desiredAccuracy = kCLLocationAccuracyBestForNavigation`,
   `distanceFilter = kCLDistanceFilterNone`, `activityType = .otherNavigation`, `allowsBackgroundLocationUpdates =
   true` (the `location` background mode is already in `project.yml`), `pausesLocationUpdatesAutomatically = false`.
   Map Android fields: `hasSpeed` ⇔ `location.speed >= 0`; `accuracy` ⇔ `horizontalAccuracy` (≥ 0). For `dt` prefer
   `location.timestamp` deltas (iOS may batch deliveries, which would make callback-time deltas ≈ 0) clamped to the
   same 1…5000 ms window; Android used callback time (`SystemClock.elapsedRealtime`). Point `time` = wall clock ms
   (match Android) or the fix timestamp (better) — both are valid in GPX. `CLLocation.distance(from:)` differs from
   Android's ellipsoidal `distanceTo` by well under 0.5 % — fine.
6. **Background execution.** The same location session that records trips is also what keeps the app (and the bike
   link) alive in the background on iOS; coordinate start/stop with the link supervisor so stopping a trip doesn't
   stop location updates needed for streaming.
7. **GPX & numbers**: always format with `Locale(identifier: "en_US_POSIX")`; never with the user locale.
8. **Day grouping**: use `Calendar.current.startOfDay(for:)` and `date(byAdding: .day, value: 1)` to avoid the
   Android 24 h DST bug.
9. **Redaction**: port the four regexes verbatim (§6.2) and add the derived vectors as unit tests in
   `OpenCfMotoCoreTests`. Run the redactor on ingest **or** on every exit path (screen, share, report, crash file).
10. **Crash capture**: MetricKit + periodic session persistence (§6.4); keep the same banners so mixed-platform
    support threads look familiar.
11. **Home state**: model `Phase` as a Swift enum with the same names (drop the two AA cases) and keep the English
    `logLabel` for logs; derive `busy`, tint and button state exactly as §7.3.
12. **Auto-connect**: no Wi-Fi scanning on iOS → attempt `NEHotspotConfiguration` apply with the saved SSID/password;
    if it fails with "not found"/timeout, stay idle and retry on `scenePhase == .active`; never loop.
13. **Wi-Fi off**: iOS gives no API to read the Wi-Fi radio state; infer from `NWPathMonitor` (no Wi-Fi interface)
    and show guidance (Control Center), not a settings deep link (private URL schemes are rejected).
14. **Local Network permission** (iOS 14+) is the most common silent failure: request it early (e.g. a Bonjour browse
    of `_EasyConn._tcp`, already declared in `project.yml`) and surface its state in Settings/Home errors.
15. **Settings JSON**: implement import/export in `OpenCfMotoCore` (pure Foundation) with unit tests using the two
    example files in §3.3 (import → export → import must be stable; Android-only keys round-trip).
16. **Strings**: build a String Catalog from §9 (EN + ES), rewrite Android-Auto wording, fix the ES defects listed in
    §9, and keep log lines English.
17. **Units**: Android trips are metric-only; iOS can honour the map units setting (`METRIC`/`IMPERIAL`) — but keep the
    stored data in SI units exactly as §5.1.
18. **Demo content** (`-demo` / `-demoSeed`, simulator screenshots): public places only. The demo GPS loop
    (`DemoRoutePlayer.defaultRoute`) runs on the public roads around Parque Simón Bolívar (Bogotá); the demo home
    (`DemoPlaces.home`) is "Demo home" / "Casa (demo)", a spot well inside that park, and the favourites are public
    landmarks. Never seed a real address, and post only demo or simulator pictures.

---

## 14. Open questions / risks

1. **Auto-log scope on iOS**: Android auto-logs only while the AA service ticks or the map UI is live (pure mirror
   sessions are not logged). Decide whether ReplayKit mirror sessions should log trips. [INF]
2. **Recording may outlive Stop in map mode** [INF]: `sync()` runs only on AA-service ticks and map bind/unbind; if the
   map UI is released while the phase is still `STREAMING` (Stop tears the pipeline down before setting `STOPPED`,
   `MainActivity.kt:1459-1473`), nothing re-evaluates and GPS recording continues. Verify on a device; on iOS
   re-evaluate on **every** phase change.
3. **Manual vs auto recording conflict**: Android kills manual recordings when *Log trips* is off and the AA service
   is running (§5.4). Confirm the intended behaviour before copying.
4. **Garage removal leaves orphaned per-bike settings** on Android; iOS should delete them — confirm no one relies on
   "re-adding the same QR restores its settings".
5. **Global vs per-bike mismatch**: README/strings claim map theme, touch overrides and margins are per bike; code
   says global. Decide which model iOS follows (recommend: keep Android's actual behaviour for import compatibility,
   but per-bike margins/touch would be more useful).
6. **`bikeHint.profile` is the process-active profile**, not necessarily the selected bike's — harmless (message
   only), but iOS should export the selected bike's profile.
7. **Phone-hotspot dashes (Carbit `action=128`, Zontes)**: iOS can't create a hotspot with the dash's SSID; the
   Personal Hotspot SSID is the device name. Probably unsupported on iOS unless the rider renames the iPhone — needs
   field testing (pairing spec).
8. **Official iOS CFMoto/EasyConnect app** might hold ports 10920–10922 in the background; iOS cannot force-stop it.
   The ERROR copy should tell the rider to swipe it away.
9. **Clock lab knobs** are experimental and not in the settings pack; if iOS implements them, mirror the presets and
   keep them out of exports.
10. **Telemetry**: not implementing it loses crash visibility — MetricKit + shared logs must compensate.
11. **Translation quality**: the Spanish file is a draft (`res/values-es/strings.xml:2`); several strings are wrong
    or stale (§9).
12. **AOSP JSON details** (slash escaping, number formatting) are library behaviour inferred from AOSP `org.json`;
    no Android test pins them. iOS parsing must accept both `\/` and `/`, integers with or without `.0`, and `E`
    notation.
13. **Update/release channel** for iOS (App Store vs TestFlight vs side-load) determines whether §6.6 is needed.
