# OpenCfMoto for iOS — Architecture

Status: v0.1 design (implementation in progress). Read this before touching code.

## 1. What the app is

An iPhone app that streams its **own dash UI** (map + turn-by-turn HUD, speed, speed limit, ETA,
clock, menus) to Carbit / EasyConnect motorcycle dashboards (CFMoto MotoPlay and siblings) over
the reverse-engineered **PXC protocol**, exactly like the Android app's built-in "Map / GPX on the
dash" mode. It does **not** do Android Auto (impossible on iOS) and cannot relay CarPlay.
Optional extra: a ReplayKit **mirror** mode (whole iPhone screen → dash, no touch back).

Ground truth for behaviour lives in `docs/spec/*.md` (extracted from OpenCfMoto Android 2.0.18
with file:line citations):

| Spec | Covers |
|---|---|
| `control-plane.md` | :10922 CmdBaseHead frames, :10930 probe, handshake, CLIENT_INFO, RSA identity, profiles, heartbeats, clock frames |
| `media-video.md` | :10921/:10920 ReqBase, config-capture, frame pulls, H.264 rules, keyframes, power modes, adaptive policy, fit/margins |
| `session-network.md` | QR formats, Wi-Fi join, addressing, discovery ladder, session state machine + every timer, persistence, logging |
| `input-controls.md` | dash touch (cmd 32) + ghost filter, gestures, handlebar AVRCP gestures/presets, focus engine, iOS feasibility |
| `navigation-dash.md` | route following (GpxNav), voice, routers, search, speed limits, night, THE DASH UI (pixel geometry, palette, icons, behaviours), places |
| `app-features.md` | settings (+ JSON pack), garage, trips, logs/redaction, problem report, home/setup flows, EN/ES strings |
| `ios-platform-facts.md` | verified iOS platform constraints (NEHotspotConfiguration, cellular pinning, background, VT, ReplayKit, MPRemoteCommandCenter) |

## 2. Repository layout

```
project.yml                     XcodeGen spec (app + ReplayKit extension)
Config/OpenCfMoto.xcconfig      bundle prefix / team / app group (Local.xcconfig overrides, git-ignored)
App/                            iOS app target (SwiftUI)            — Apple only
MirrorExtension/                ReplayKit Broadcast Upload Extension — Apple only
Packages/OpenCfMotoKit/         Swift package
  Sources/OpenCfMotoCore/       PURE Swift + Foundation. Builds & tests on Linux.
    Util/      ByteIO, Log, OrderedJSON, Async (withTimeout, Locked, MonotonicClock)
    Protocol/  PXC codecs: CmdBaseHead, ReqBase, config-capture, CLIENT_INFO, clock, touch decode
    Link/      Transport contract, EasyConnLink (session engine), discovery ladder, ghost filter, RSA (pure Swift)
    Bike/      BikeQR (+parser), bike profiles, garage model, DashMemory
    Video/     VideoTypes, AnnexB, FrameQueue, AdaptivePolicy/encoder parameter derivation, canvas fit math
    Nav/       NavTypes, NavSnapshot, RouteFollower (GpxNav), VoicePlanner, NavigationSession, routers, search, Overpass, GPX, places, lap timer, formatting
    Dash/      DisplayList contract, DashInput, dash UI (layout, palette, icons, map layer, controller, focus, gestures), SVG export
    Net/       HTTPClient contract, HTTP/1.1 codec (for the cellular client), throttle
    Settings/  SettingsTypes, SettingsStore (scoped keys), SettingsBackup (opencfmoto.settings v1)
    Storage/   KeyValueStore / SecretStore contracts + in-memory impls
    Trips/     trip model, recorder, store, stats, GPX export, thumbnail geometry
  Sources/OpenCfMotoAppModel/   The app's @Observable model layer (Observation + Core only). Talks to the
                                platform through the ports in Contract/AppPorts.swift → builds and
                                is unit-tested on Linux with the fakes in Testing/PreviewServices.swift.
  Sources/OpenCfMotoApple/      Apple-framework adapters. EVERY file wrapped in `#if canImport(<framework>)`
                                so the target compiles (empty) on Linux. Compiled for real on macOS CI.
  Tests/OpenCfMotoCoreTests/    XCTest, runs on Linux + macOS (+ Fixtures/)
  Tests/OpenCfMotoAppleTests/   XCTest, macOS only in practice (guard with canImport)
docs/spec/                      behaviour specs (read-only reference)
tools/                          dev tools (e.g. Kotlin golden-vector harness)
```

Toolchain: Swift 5 language mode (`swift-tools-version:5.9`), iOS 17+, macOS 14+ (package),
no third-party dependencies. Linux dev toolchain: Swift 6.0.3 (`. scratchpad/swiftenv.sh`).

## 3. Runtime data flow

```
            ┌──────────── iPhone (app process) ───────────────────────────────────────────┐
QR scan ─▶ BikeQR ─▶ Garage/SettingsStore                                                   │
            │                                                                              │
CLLocation ─▶ LocationService ─▶ LocationFix ─┬─▶ NavigationSession (Core) ─▶ NavSnapshot ─┐│
            │                                 ├─▶ TripRecorder (Core)                     ││
            │                                 └─▶ DashUIController camera                 ││
            │   NavEffect.speak ─▶ SpeechAnnouncer (AVSpeechSynthesizer)                  ││
            │                                                                             ▼│
            │   DashUIController (Core): DashModel(NavSnapshot, prefs, clock, places…) +  │
            │   UI state (sheets, focus, camera) ─▶ DashDisplayList (+ hit regions)        │
            │        ▲ DashInput (touch / handlebar keys)        │                        │
            │        │                                            ▼                        │
            │   GhostTouchFilter ◀── LinkEvent.touch      DashRenderer (CoreGraphics,      │
            │   HandlebarGestureEngine ◀── HandlebarRemote  tiles from TileImageCache)     │
            │        (MPRemoteCommandCenter)                       │ CVPixelBuffer (BGRA)  │
            │                                                      ▼                        │
            │                     DashVideoEncoder: foreground H264Encoder (VT hardware,   │
            │                     Baseline 3.1); locked: background ladder (VT software →  │
            │                     [CPU encoder, Phase 1] → pre-encoded hold IDRs)          │
            │                                                      │ AVCC → AnnexB         │
            │                                                      ▼                        │
            │                         DashProjectionEngine : VideoFrameSource ─▶ FrameQueue │
            │                                                      │                        │
            │   EasyConnLink (Core) ◀── POSIXNetworkProvider (BSD sockets) ─────────────────┤
            └─────────────────────────────────────────────────────┼────────────────────────┘
                     Wi-Fi (NEHotspotConfiguration)               ▼
                     dash :10930 probe ◀── phone listens :10922/:10921/:10920 ◀── dash connects back
```

Internet (tiles, routing, search, Overpass) goes through `HTTPClient`; on iOS the implementation
prefers the **cellular** interface while joined to the bike Wi-Fi (no internet there), with a disk
tile cache and corridor prefetch.

## 4. Module ownership (who writes what)

Each implementation agent owns a set of paths and must not edit files outside them. **Contract
files** (header says `CONTRACT FILE`) are frozen: do not edit them; if a contract is insufficient,
add an extension in your own file and report a *contract change request*.

Contract files: `Util/*` (ByteIO, Log, OrderedJSON, Async), `Link/Transport.swift`,
`Link/LinkTypes.swift`, `Video/VideoTypes.swift`, `Video/AnnexB.swift`, `Video/FrameQueue.swift`,
`Nav/NavTypes.swift`, `Nav/NavSnapshot.swift`, `Dash/DisplayList.swift`, `Dash/DashInput.swift`,
`Bike/BikeQR.swift`, `Net/HTTPClient.swift`, `Settings/SettingsTypes.swift`, `Storage/KeyValueStore.swift`.

| Agent | Owns | Produces (public API others rely on) |
|---|---|---|
| **core-link** | `Core/Protocol/**`, `Core/Link/**` (except contracts), `Core/Bike/BikeProfile*.swift`, tests `Tests/.../Link*`, `Protocol*`, `Profile*` | `EasyConnLink`, `BikeProfiles` (selection), `PureSwiftRSASigner`, `InterfaceAddresses`, `GhostTouchFilter`, codecs |
| **core-nav** | `Core/Nav/**` (except contracts), `Core/Net/**` (except contract), tests `Nav*`, `Router*`, `Gpx*`, `Search*` | `NavigationSession` (→ `NavSnapshot` + `NavEffect`), `RouteFollower`, routers + `RouteOrchestrator`, `PlaceSearch`, `SpeedLimitService`, `GpxParser`/`GpxWriter`, `PlacesStore`, `LapTimer`, `NavFormat`, `ThrottledHTTPClient`, `HTTP1` codec |
| **core-app** | `Core/Bike/**` (except profiles + contract), `Core/Settings/**` (except contract), `Core/Trips/**`, `Core/Video/AdaptivePolicy.swift`, `Core/Video/EncoderPlanner.swift`, `Core/Video/CanvasFit.swift`, `Core/Util/LogRedactor.swift`, `Core/Util/ProblemReport.swift`, `Core/Dash/Handlebar*.swift` | `BikeQR.parse`, `Garage`, `DashMemory`, `SettingsStore`, `SettingsBackup`, `TripRecorder`/`TripStore`/`TripGpx`, `AdaptivePolicy`, `EncoderPlanner`, `CanvasFit`, `LogRedactor`, `ProblemReport`, `HandlebarGestureEngine` |
| **core-dash** | `Core/Dash/**` (except contracts + Handlebar*), tests `Dash*` | `DashUIController` (DashModel + DashInput → DashDisplayList + `DashIntent`s), `DashLayout`, `DashPalette`, `DashIcons`, `MapProjection`, `DashSVGExporter` |
| **apple-platform** | `Apple/` files: `NWNetworkProvider`, `BonjourDashDiscovery`, `WiFiInfo`, `WifiJoiner`, `CellularHTTPClient`, `SecKeyHuidSigner`, `UserDefaultsKeyValueStore`, `KeychainSecretStore`, `LocationService`, `SpeechAnnouncer`, `HandlebarRemote`, `AppGroup` | adapters implementing the contracts |
| **apple-video** | `Apple/` files: `H264Encoder`, `DashRenderer`, `CoreTextMeasurer`, `TileImageCache`, `DashProjectionEngine`, `MirrorFrameSource`, `ThermalMonitor` | `DashProjectionEngine: VideoFrameSource`, `MirrorFrameSource: VideoFrameSource` |
| **logic-session** (wave 2) | `AppModel/{App,Connection,Ride,Controls}/**`, new files in `AppModel/Testing/**`, `App/Sources/Services/**`, `MirrorExtension/**`, tests `Tests/OpenCfMotoAppModelTests/{App,Connection,Ride,Controls}*` | `AppModel`, `ConnectionModel`, `RideModel`, `ControlsModel`, `PermissionsModel`, iOS port adapters, `AppPlatform`, `SampleHandler` |
| **logic-data** (wave 2) | `AppModel/{Garage,Settings,Navigation,Trips,Logs}/**`, tests `Tests/OpenCfMotoAppModelTests/{Garage,Settings,Navigation,Trips,Logs}*` | `GarageModel`, `SettingsModel`, `NavigationModel`, `TripsModel`, `LogsModel` |
| **ui-main** (wave 2) | `App/Sources/UI/{App,Home,Dash,Ride,Mirror,Scan,Garage,Onboarding,About}/**`, `App/Resources/Localization/ui-main.json` | `@main` app, home, dash preview, pocket mode («Modo bolsillo», formerly Ride Mode), mirror, QR scanner, garage, onboarding, about |
| **ui-features** (wave 2) | `App/Sources/UI/{Navigate,Trips,Settings,Controls,Logs}/**`, `App/Resources/Localization/ui-features.json`, `README.md` | map hub/search, trips, settings, handlebar controls, logs/problem report, README |

Wave-2 contract files (frozen): `AppModel/Contract/*`, `AppModel/AppCore.swift`,
`AppModel/Testing/PreviewServices.swift`, `App/Sources/UI/Common/Theme.swift`; the public surface of
every skeleton model and of `App/Sources/Services/AppPlatform.swift` (bodies are implemented by
the owner, signatures are frozen). Spanish strings: each UI agent writes its own
`App/Resources/Localization/<agent>.json`; `tools/l10n/build_strings.py` merges them into
`App/Resources/Localizable.xcstrings`.

## 5. Key runtime rules (from the specs — do not "simplify" them away)

1. Listeners on 10922/10921/10920 are up **before** the probe. Probe bytes are fixed (spoof the
   Android CFMoto app; `phoneType/phoneOs = "Android"`). The dash connects back to the probe's
   source IP; probe and listeners must use the Wi-Fi interface.
2. Phone heartbeats `0x70000000` every 2 s on **every** channel-selected :10922 socket; answer the
   dash's `0x70000000` with `0x70000001`; ack **every** unknown control frame with `cmd+1` (empty).
3. `0x10600` time sync: echo the request bytes zero-padded to 45 bytes (phone time only for blank /
   1969–1971 stamps). `0x10450` → empty `0x10451`. Never advertise `supportSyncCorrectTime:true`.
4. Media: reply token 0; RLY 17 = encoder, w&0xFFF0, h&0xFFF0, ext byte; 48→49 `03 00 00 00 01 00 00 00`;
   96→97 `{"state":0}`; 112 → resynchronize (gate, flush, force IDR) **then** reply 113;
   114 → exactly one `[size i32 LE][Annex-B AU]` with SPS+PPS before every IDR; never reply to 32.
   Never leave a 114 unanswered if any picture exists (re-encode / resend last IDR), never send a
   zero-size frame or a repeated P-frame. The dash drops media after ~9 s without a frame.
5. Encoder: H.264 Baseline 3.1, no frame reordering, CBR-ish 2.5 Mbit/s × quality, IDR every 1 s
   (Morini 2 s), repeat the last picture if nothing was encoded for 0.9 s.
6. Watchdog 5 s tick: STREAMING with no frame sent for > 8 s → drop all bike sockets and re-probe
   (20 s cooldown). Reconnect budget 20, backoff `min(500+500n, 4000)` ms, 2.5 s settle.
   Add a connect-back timeout (~10 s) that Android lacks.
7. iOS background: projection runs in the foreground with the idle timer disabled; with the
   `location` background mode the process keeps the sockets alive while locked. The engine encodes
   through the `DashVideoEncoder` seam (`OpenCfMotoApple/DashVideoEncoder.swift`; `H264Encoder`
   conforms): in the foreground the VideoToolbox hardware session; at `.background` a **ladder** of
   background encoders (pure rules in `OpenCfMotoCore/Video/BackgroundEncoding.swift`): a VideoToolbox
   software session (pre-warmed at `.inactive`), then a bundled CPU encoder (Phase 1; none in the Phase 0
   build), then the pre-encoded hold picture ("Map paused"). A rung is used only after a probe IDR
   passed `H264StreamCheck` (nothing of a rejected encoder reaches the dash); a failing encoder is demoted
   to the next rung; every encoder change happens at an IDR (gate closed, `EncodedFrame.encoderTag`
   changes only on IDRs). A timed-out pull is answered with the live background encoder's last IDR, then
   the hold picture, then any live IDR of the canvas (foreground: live only), so the dash never drops the
   link for want of a frame. Details and log lines: `spec/media-video.md` §15.3a.
8. Dash rendering: CoreGraphics only (no GPU map views in front of the encoder), BGRA buffers at
   exactly the negotiated canvas, top-left origin; dash touches map 1:1 to canvas pixels.
9. Deliberate iOS deviations of the dash map, each with an Android-parity switch: the follow camera
   and the puck ease between fixes (cubic ease-out over `DashUIController.Options.followEaseDuration`
   = 0.35 s; osmdroid jumps, 0 = parity; explicit camera actions still jump), and night tiles use a
   hue-preserving HSL lightness inversion dimmed ×0.9 (`TileImageCache.Configuration.nightStyle =
   .rgbInvert` = osmdroid INVERT_COLORS, which turns parks magenta and water orange).

## 6. Concurrency conventions

- Core types used across threads are either `actor`s, value types, or `final class … : @unchecked
  Sendable` guarded by `NSLock` (document which). No global mutable state except `Log.shared`.
- Async APIs use Swift concurrency; timeouts via `withTimeout`. Every long-running task must be
  cancellable and must stop when its owning session stops (use per-session generation tokens).
- The render/encode loop runs on its own serial queue (Apple layer); it calls
  `DashUIController.displayList(...)` which must be thread-safe.

## 7. Coding rules for all agents

- Header on every file: `// SPDX-License-Identifier: AGPL-3.0-or-later`; when porting, add
  `// Ported from OpenCfMoto (Android) <File.kt>` (AGPL derivative work, see NOTICE).
- Core: Foundation only; no `Darwin`/`Glibc`-only APIs without `#if canImport(Darwin)` /
  `#elseif canImport(Glibc)` branches; no `DispatchQueue.main` assumptions; deterministic time
  via injected `MonotonicClock`/`now` closures where timers matter.
- Number/date formatting that ends up on the wire, in JSON, GPX or test vectors uses
  `en_US_POSIX` / explicit formats — never the user locale.
- User-facing strings produced by the core (HUD words, voice phrases) come from small EN/ES tables
  in code (no bundle lookups in the core); default language follows `Locale.preferredLanguages`.
- Avoid generic top-level names that could collide across agents (prefix helpers or keep them
  `private`/`fileprivate`). Never declare `extension Data`, `extension Double`, etc. with
  `public` generic names already used elsewhere (`hexString`, `hexDump` exist in ByteIO).
- Logging: `Log.i("TAG", "…")` with the Android stage tags (`[PROBE]`, `[:10922]`, `[hb]`,
  `[profile]`, `[watchdog]`, …) so logs can be compared with the Android app.
- Tests: XCTest only. Copy every vector from the specs that applies to your area. Core tests must
  pass on Linux: `cd Packages/OpenCfMotoKit && swift build && swift test`.
- Apple-only code cannot be compiled in the Linux sandbox: write it against the iOS 17 SDK with
  exact API names, avoid deprecated APIs, keep it simple and well-commented; it is compiled by the
  macOS CI job.
