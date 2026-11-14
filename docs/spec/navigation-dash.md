# SPEC — Navigation engine, routing/search services, map tiles & the built-in dash map UI

Target: the iOS (Swift) re-implementation of OpenCfMoto's **Map / GPX on the dash** feature — the
app's own map + turn-by-turn HUD, rendered by the phone, H.264-encoded and streamed to
Carbit/EasyConnect (CFMoto MotoPlay & siblings) dashes over PXC. This document is written so that
engineers who will **not** read the Kotlin can re-implement the feature with behavioural parity.

Source of truth: Android app `/home/user/open-cfmoto` at `versionName 2.0.18` / `versionCode 77`
(`app/build.gradle.kts:22-23`). Kotlin sources live in
`app/src/main/java/dev/zanderp/opencfmoto/`; citations below are `File.kt:line` relative to that
directory (resources: `res/...` relative to `app/src/main/`; tests: `*Test.kt` in
`app/src/test/java/dev/zanderp/opencfmoto/`). Shorthand: `layout-land:N` = line N of
`res/layout-land/presentation_gpx.xml`; a bare `:N` refers to the file cited just before.

## 0. Conventions

| Tag | Meaning |
| --- | --- |
| **[V]** | VERIFIED — the shipping code path in the release build (read directly from the code that runs). |
| **[HW]** | Additionally confirmed on real hardware (repo docs say so, or visible in the repo's real-dash demo footage `docs/media/map-demo-1.gif`, `map-demo-2.gif`). |
| **[I]** | INFERRED by the spec author: arithmetic derived from layout rules, behaviour of third-party libraries/services, or a probable bug found by reading the code. Treat as a strong hint, not ground truth. |
| **[X]** | EXPERIMENTAL / DORMANT / UNUSED / LEGACY code — present in the repo but not on a live path (or flagged experimental in code/docs). |

Units: distances in metres (m), times in milliseconds (ms) or seconds (s) as stated, speeds in m/s
unless suffixed km/h, angles in degrees clockwise from true north (0..360). "dp" = Android
density-independent pixel, "sp" = scaled pixel (dp × user font scale). On the 800-px-wide dash
canvases **1 dp = 1 px** (see §11.1), so most geometry below is directly in canvas pixels.

Numeric string formats: Kotlin `String.format("%.1f", x)` uses the **default JVM locale** and
**HALF_UP** rounding (`GpxNav.kt:550-559`). On a Romanian/German phone the decimal separator is a
comma (`"1,5 km"`). Unit tests assume an English locale. See §15 for the iOS recommendation.

---

## 1. Architecture overview (Android) and how it maps to iOS

### 1.1 Components

| Android component | Role | iOS counterpart (recommended) |
| --- | --- | --- |
| `GpxSession` (`GpxSession.kt`) | Process-global session: mode, track file, destination, overlay places, touch target. | `MapSession` value/actor in Core. |
| `GpxDashUi` (`GpxDashUi.kt`, 2 801 lines) | The whole dash UI controller: binds `presentation_gpx.xml`, runs GPS/compass, nav state machine, search, preview, menus, handlebar focus. | Dash view-model + CoreGraphics renderer + hit-testing. |
| `GpxNav` (`GpxNav.kt`) | Route-following maths: snapping, progress, next maneuver, ETA, formatting. | Pure Swift `RouteFollower` (Linux-testable, OpenCfMotoCore). |
| `GpxVoice` (`GpxVoice.kt`) | TTS cue scheduler. | Pure `VoicePlanner` (Core) + `AVSpeechSynthesizer` adapter (Apple). |
| `OfflineRouter` (`OfflineRouter.kt`) | Routing orchestrator (offline graph → ORS → Valhalla → OSRM → beeline). | `RouteOrchestrator`. |
| `OsrmRouter`, `ValhallaRouter`, `OrsRouter` | HTTP routing clients. | Same three clients. |
| `FunRoutePlanner` | Via-point generators for alternatives / "Fun". | Same. |
| `OfflineRoadGraph`, `OfflinePoiIndex`, `MapOfflineManager`, `OfflineAreasStore`, `RegionPackStore` | Offline areas & on-device A*. | Optional / later (§6.7). |
| `NominatimSearch` (Photon + Nominatim), `OverpassClient` | Place search, POI "near me", speed limits. | Same clients. |
| `AppHttp`, `CellularTileDownloader` | Shared HTTP (UA, timeouts, throttle, cellular pinning). | `HTTPClient` with identical policy. |
| `DashMapEngine` → `DashMapController` (osmdroid raster, **bike**) / `MapLibreDashController` (vector, **phone preview**) | Map rendering. | Own raster-tile renderer in CoreGraphics (bike path parity). |
| `MapPlaces`, `MapPrefs`, `NightPrefs`, `SavedPlaces`, `MapDataBackup` | Persistence. | Same schemas (JSON). |
| `LapTimer` | Flying-lap timer. | Same. |
| `MapInputBridge`, `DashRemote` | Handlebar keys → map focus; phone keyboard → dash search. | In-process callbacks. |

### 1.2 Data flow on the bike [V]

```
CLLocation/GPS (800 ms, 1.5 m) ──▶ GpxDashUi.onLocationChanged ──▶ GpxNav.progress()
     │                                   │            │
     │                                   │            ├─▶ HUD texts/icons, metrics, voice (GpxVoice)
     │                                   │            └─▶ auto-reroute → OfflineRouter.routeAsync
     │                                   ├─▶ Overpass maxspeed (every 12 s) → limit sign
     │                                   └─▶ DashMapEngine.setMe/follow (camera)
Rotation-vector compass (≤ every 120 ms) ─▶ heading-up while stopped, join-route arrow
Bike touch (PXC media cmdType 32) ─▶ GpxSession.dispatchTouch(action,x,y) ─▶ root View
Handlebar AVRCP ─▶ MediaButtonBridge ─▶ MapInputBridge.keySink/scrollSink ─▶ focus navigation
Presentation on private VirtualDisplay (canvas W×H) ─▶ MediaCodec H.264 ─▶ PXC data socket
```

### 1.3 Session modes (`GpxSession`) [V]

`enum Mode { FREE_RIDE, GPX, NAV_TO }` (`GpxSession.kt:16`). State fields: `active`, `mode`,
`trackFile`, `trackName`, `destination: MapPlace?`, `overlayPlaces: List<MapPlace>`,
`pendingCircuit: Boolean`, `navStartedAtMs: Long` (`GpxSession.kt:18-45`).

| Call | Effect (`GpxSession.kt`) |
| --- | --- |
| `prepareFreeRide(overlays)` | mode FREE_RIDE, trackFile null, trackName `"Free ride"`, destination null, navStartedAtMs 0, active true (`:47-55`). |
| `prepareGpx(file, displayName, overlays)` | mode GPX, trackFile, trackName = displayName, destination null, navStartedAtMs 0 (`:57-65`). |
| `prepareNavTo(place, overlays)` | mode NAV_TO, trackFile null, trackName = place.name, destination = place, navStartedAtMs = now wall-clock (`:67-75`). |
| `clear()` | everything reset, active false, touch target null, pendingCircuit false (`:77-87`). |
| `finishToFreeRide()` | if active: `prepareFreeRide(overlayPlaces)` (keeps overlays) (`:90-94`). |
| `abandonStaleNavigation(reason)` | if active and NAV_TO → finishToFreeRide (`:100-104`). Called on app open when not projecting (`MainActivity.kt:490-496`), when the map projection stops (`VideoPipeline.kt:755-757`), and from the Map hub. Purpose: a killed/reopened app must never "resume" a route and flash "Arrived". |

Overlay places = session-only POIs (the corridor-POI download from the hub, `GpxActivity.kt:532`).

### 1.4 Rendering engine choice [V][HW]

`DashMapEngine` uses MapLibre **only when the host context is an `Activity`** (phone preview);
on the bike Presentation (VirtualDisplay) it uses **osmdroid raster tiles drawn with Canvas**
(`DashMapEngine.kt:25-54`). Rationale stated in code: MapLibre GL on a VirtualDisplay produced
incomplete GL frames during camera motion that the H.264 encoder turned into heavy block
artifacts on the bike (`DashMapEngine.kt:13-20`, `DashMapController.kt:30-33`). The bike look in
the demo footage is the OSM "Mapnik" raster style [HW].

**iOS consequence:** render the bike map yourself from 256-px raster tiles into a CPU bitmap
(CoreGraphics) — this is the proven path; do not render a GPU map view into the encoder.

---

## 2. Data models (exact fields)

```kotlin
data class GpxPoint(val lat: Double, val lon: Double, val ele: Double? = null, val name: String? = null)   // GpxParser.kt:8
data class GpxTrack(val name: String, val points: List<GpxPoint>, val waypoints: List<GpxPoint>)           // GpxParser.kt:10-14
data class MapPlace(val name: String, val lat: Double, val lon: Double,
                    val category: String = "", val subtitle: String = "")                                  // MapPlaces.kt:10-16
// OsrmRouter.kt:17-40 — the common route model used by ALL routers
data class Lane(val valid: Boolean, val indications: List<String>)
data class RouteStep(val maneuverType: String, val modifier: String?, val roadName: String,
                     val maneuverLat: Double, val maneuverLon: Double, val distanceM: Double,
                     val exit: Int?, val lanes: List<Lane>?)
data class Route(val points: List<GpxPoint>, val distanceM: Double, val durationSec: Double,
                 val steps: List<RouteStep> = emptyList(), val label: String = "")   // label: Fast/Fun/Alt/Circuit/Direct/No highway/No toll/No hwy/toll
data class RouteResult(val routes: List<Route>, val avoidHonored: Boolean = true, val warning: String? = null) // OfflineRouter.kt:26-30
data class RouteOptions(val mode: RouteMode = FAST, val avoidTolls: Boolean = false, val avoidHighways: Boolean = false,
                        val maxAlternatives: Int = 4, val circuitKm: Int = 60)          // MapPrefs.kt:157-166; wantsAvoids = avoidTolls || avoidHighways
enum class MapUnits { METRIC, IMPERIAL }                                                // MapPrefs.kt:8-11
enum class MapChrome(color) { DARK 0xFF101418, BLACK 0xFF000000, SLATE 0xFF1A2332, FOREST 0xFF0E1A14 } // MapPrefs.kt:13-18
enum class RouteMode { FAST, FUN }                                                      // MapPrefs.kt:21-24
enum class MapTheme { AUTO, DAY, NIGHT }                                                // NightPrefs.kt:16-20
enum class TurnDir { LEFT, RIGHT, SHARP_LEFT, SHARP_RIGHT, SLIGHT_LEFT, SLIGHT_RIGHT,
                     UTURN, ROUNDABOUT, MERGE_LEFT, MERGE_RIGHT, FORK_LEFT, FORK_RIGHT,
                     STRAIGHT, ARRIVE, CONTINUE }                                       // GpxNav.kt:66-70
data class TurnCue(index: Int, distanceAlongM: Double, distanceFromRiderM: Double, dir: TurnDir,
                   speak: String, shortLabel: String, instr: String = "", roadName: String? = null,
                   laneLabel: String? = null)                                          // GpxNav.kt:72-85
data class Progress(nearestIndex: Int, doneM: Double, remainM: Double, offTrackM: Double,
                    snapLat: Double, snapLon: Double, nextWaypoint: GpxPoint?, nextWaypointM: Double?,
                    trackBearingDeg: Float, upcomingTurn: TurnCue?, altitudeM: Double?,
                    remainAscentM: Double?, gradePct: Double?, etaSec: Long?)          // GpxNav.kt:87-107
data class SpeedLimit(val kmh: Int?, val label: String)                                 // OverpassClient.kt:20
```

---

## 3. GPX parsing and track orientation

### 3.1 Parser [V] (`GpxParser.kt:50-109`)

Regex-based (no XML parser). Case-insensitive patterns:

```
pointTag  = <(trkpt|rtept|wpt)\b([^>]*)>([\s\S]*?)</\1>
selfClose = <(trkpt|rtept|wpt)\b([^>]*)/>
latAttr   = \blat\s*=\s*["']([^"']+)["']
lonAttr   = \blon\s*=\s*["']([^"']+)["']
eleTag    = <ele[^>]*>\s*([^<]+)\s*</ele>
nameTag   = <name[^>]*>\s*([^<]+)\s*</name>
trkName   = <trk\b[^>]*>[\s\S]*?<name[^>]*>\s*([^<]+)\s*</name>
rteName   = <rte\b[^>]*>[\s\S]*?<name[^>]*>\s*([^<]+)\s*</name>
```

Algorithm: collect all `pointTag` matches in document order, then all `selfClose` matches; each
point needs parseable `lat` and `lon` (else skipped); `ele` and trimmed `name` optional.
`trkpt` → track list, `rtept` → route list, `wpt` → waypoints. Name = first `<trk>` name, else
first `<rte>` name, else the file name without extension. Points = track points if any, else
route points, else empty (`GpxParser.kt:72-108`).

Quirks [I]: (a) self-closing points are appended **after** all long-form points → order breaks if
a file mixes both; (b) a self-closing point followed later by a long-form one can be swallowed by
`pointTag`'s lazy body match. **iOS: use `XMLParser` and preserve document order** (parity with
the test vector below is still required).

Hub import validation (`GpxActivity.kt:68-122`): copy to cache `gpx-import-<ms>.gpx`; reject when
both points and waypoints are empty ("GPX has no track points or waypoints"); display name =
`track.name.ifBlank { fileName }`; label `"<name>  ·  <N> pts · <M> wpt · <distance>"`; push a
history entry `MapPlace(name, firstPt.lat, firstPt.lon, "gpx", "GPX track")`.

**Test vector (GpxParserTest.kt:10-33)** — input:

```xml
<?xml version="1.0"?>
<gpx version="1.1">
  <trk><name>Test Ride</name>
    <trkseg>
      <trkpt lat="45.0" lon="25.0"><ele>100</ele></trkpt>
      <trkpt lat="45.1" lon="25.1"/>
    </trkseg>
  </trk>
  <wpt lat="45.05" lon="25.05"><name>Peak</name></wpt>
</gpx>
```
Expected: name `"Test Ride"`, 2 points, `points[0].lat == 45.0`, `points[0].ele == 100.0`,
1 waypoint named `"Peak"`.

### 3.2 Track orientation for the rider [V] (`GpxParser.kt:19-43`)

`orientedForRider(lat, lon, headingDeg?) -> (track, flipped)`; applied **once**, on the first GPS
fix in GPX mode (`GpxDashUi.kt:2302-2313`), with `heading = loc.bearing` only if the fix has a
bearing and `speed > 1.0 m/s`, else null.

1. If `points.size < 3` → unchanged.
2. `nearest` = index of the closest point (haversine). `i = clamp(nearest, 0, lastIndex-1)`.
3. `fwd = bearing(p[i] → p[i+1])`, `rev = (fwd + 180) % 360`.
4. With heading: `reverse = |Δ(heading,rev)| + 25 < |Δ(heading,fwd)|` (Δ normalised to ±180).
5. Without heading: `reverse = nearest / lastIndex > 0.65`.
6. If reverse → `points.asReversed()`; UI rebuilds `GpxNav`, speaks `"Following the track the other way"`, refreshes title.

**Test vector (GpxNavTest.kt:103-115):** pts (0,0),(0.01,0),(0.02,0); rider at (0.02,0) heading
180° → flipped == true, first point lat 0.02, last 0.0.

---

## 4. Route-following engine (`GpxNav`)

`GpxNav(track, steps: List<RouteStep>? = null)` — steps are present for road routes (OSRM/
Valhalla/ORS/offline graph), absent for GPX tracks (`GpxNav.kt:9-13`, `GpxDashUi.kt:230`).

### 4.1 Construction [V] (`GpxNav.kt:25-64`)

* `cumDistM[i]` = cumulative haversine distance (R = 6 371 000 m) to point i; `totalM = cumDistM[last]`.
* `cumAscentM[i]` = cumulative sum of positive elevation deltas (only between consecutive points that both have `ele`).
* `hasElevation = (#points with ele) >= max(n/2, 2)` (integer division) (`:47`).
* `stepIndex[s]` = index of the track point nearest (haversine, **global search**) to step s's maneuver coordinate (`:50-63`).
* `cursor = 0` — mutable "last snapped index" used to stay on the forward leg (`:23`).

Helper maths (`GpxNav.kt:353-379`):

```
haversineM(a,b) = 2·6371000·asin(min(1, sqrt(sin²(Δφ/2) + cosφ1·cosφ2·sin²(Δλ/2))))
bearingDeg(a,b) = (atan2(sinΔλ·cosφ2, cosφ1·sinφ2 − sinφ1·cosφ2·cosΔλ)° + 360) % 360   (Float)
normalizeDelta(d): while d > 180 → d −= 360; while d < −180 → d += 360
bearingAt(i) = bearing(p[k] → p[k+1]) with k = clamp(i, 0, max(n−2, 0)); 0 if n < 2
```

### 4.2 `progress(lat, lon, speedMps, gpsAltitudeM?, units)` [V] (`GpxNav.kt:109-162`)

1. Empty track → null.
2. **Windowed nearest vertex**: search indices `max(cursor−8, 0) .. n−1`, start `bestI = clamp(cursor)`, strict `<` comparison (`:118-128`).
3. If `bestD > 80 m` → **global** nearest search over all points (`:129-137`).
4. Else if `bestI < cursor` and `cumDistM[cursor] − cumDistM[bestI] > 40 m` → keep `bestI = cursor` (no backward hop onto e.g. the return leg of an out-and-back) (`:138-141`).
5. `cursor = bestI`.
6. **Snap** onto the two segments touching `bestI`: `(bestI−1, bestI)` and `(bestI, bestI+1)` (skipping out-of-range) using a local equirectangular projection with `mLat = 111 320 m/°`, `mLon = 111 320·cos(lat_a)` (a = segment start): `t = clamp(dot(P−A, B−A)/|B−A|², 0, 1)`, `dist = |P − (A + t(B−A))|`; keep the smaller `dist`. `along` = `t·|AB|` for the forward segment, `−(1−t)·|AB|` for the backward segment (signed offset from vertex `bestI`). Single-point track → snap = the point, dist 0 (`:164-198`).
7. `offTrackM = snap.dist`; `doneM = clamp(cumDistM[bestI] + along, 0, totalM)`; `remainM = max(totalM − doneM, 0)`.
8. `trackBearingDeg = bearingAt(bestI)`; `nextWaypoint` (§4.5); `upcomingTurn = upcomingTurn(bestI, units=units)` (§4.3); `altitudeM = gpsAltitude ?: p[bestI].ele`; `remainAscentM = totalAscent − cumAscent[bestI]` (≥0, only if hasElevation); `gradePct = gradeAhead(bestI, 150 m)`; `etaSec = etaSeconds(remainM, speedMps)`.

Notes [I]: the planar `111 320` constant and the haversine `R` disagree by ~0.11 % (harmless);
the turn distance is measured from the nearest **vertex** `bestI`, not from the snapped position,
so on sparse geometry it can be off by up to one segment length — iOS should use
`cumDist[stepIdx] − doneM`.

`pointsDone(i) = points[0 ..= clamp(i,0..n-1)]` (at least 1 point), `pointsRemain(i) = points[clamp(i) ..]` (`GpxNav.kt:200-206`) — used to paint the grey "done" and blue "remaining" polylines on every fix (`GpxDashUi.kt:2149-2154`).

### 4.3 Next-maneuver selection [V]

`upcomingTurn(fromIndex, lookAheadM = 900, minTurnDeg = 38, units)` (`GpxNav.kt:208-266`):

* If steps exist → `stepCue(fromIndex)`; if it returns a cue use it; **if steps are non-empty and stepCue returned null → return null** (never fake geometric turns on a road route) (`:214-216`).
* Else (GPX track) **geometric inference**: walk forward from `fromIndex` while `cumDist[i] ≤ cumDist[from] + 900`; sample only when ≥ 40 m beyond the previous sample (always sample the last index); at each sample `brng = bearingAt(min(i, last−1))`, `delta = normalizeDelta(brng − prevBrng)`; first sample with `|delta| ≥ 38°` yields `dir = delta > 100 → SHARP_RIGHT; delta < −100 → SHARP_LEFT; delta > 0 → RIGHT; else LEFT`. `distanceFromRiderM = cumDist[i] − cumDist[from]`. Texts: `speak = "In <formatDistance>, <dirWord>"`, `shortLabel = "<short> · <dist>"`, `instr = dirWord`, with dirWord ∈ {`turn left`,`turn right`,`sharp left`,`sharp right`} and short ∈ {`← Left`,`Right →`,`←← Sharp`,`Sharp →→`}. No road name, no lanes. `prevBrng` is updated after each sample.

`stepCue(fromIndex)` (`GpxNav.kt:269-309`), steps in route order:

```
start = cumDist[fromIndex]
for s in steps:
    if type == "depart": continue
    idx = stepIndex[s]
    if idx < fromIndex - 1: continue                 // behind
    dist = cumDist[idx] - start
    if dist < -15: continue
    if type == "arrive": if dist <= 25 continue else return null   // arrival handled elsewhere
    dir = dirFor(type, modifier); road = roadName if not blank
    return TurnCue(idx, cumDist[idx], max(dist,0), dir,
                   speak = "In <formatDistance(dist)>, <instr>",
                   shortLabel = "<arrowFor(dir)>[ <road>] · <dist>",
                   roadName = road, laneLabel = laneLabel(lanes), instr = instruction(type, modifier, road, exit))
return null
```

**Known pitfalls in this logic [I]** (iOS should fix, but keep a parity mode for tests):
1. **Intermediate "arrive" steps.** OSRM (one `arrive` per leg) and Valhalla (destination maneuver types 4/5/6 at the end of each leg) emit an arrival at every via point. Routes built with vias — every **Circuit** (start→dest→start) and every "Alt"/"Fun" option built from via offsets (§6.1) — therefore hit `return null` at the via's `arrive` and show **no turn cues until the via is passed**.
2. **Global `stepIndex` snapping.** On out-and-back geometry the return-leg maneuvers can snap to outbound-leg indices and are then skipped as "behind". Assign step indices monotonically (search forward from the previous step's index).

Maneuver mapping tables (`GpxNav.kt:429-523`):

`dirFor(type, modifier)` (both lower-cased):

| type | modifier | TurnDir |
| --- | --- | --- |
| `roundabout`, `rotary`, `roundabout turn`, `exit roundabout`, `exit rotary` | any | ROUNDABOUT |
| `merge` | contains `left` | MERGE_LEFT, else MERGE_RIGHT |
| `fork` | contains `left` | FORK_LEFT, else FORK_RIGHT |
| `arrive` | any | ARRIVE |
| anything else | `uturn` / `sharp left` / `sharp right` / `slight left` / `slight right` / `left` / `right` / `straight` / other-or-null | UTURN / SHARP_LEFT / SHARP_RIGHT / SLIGHT_LEFT / SLIGHT_RIGHT / LEFT / RIGHT / STRAIGHT / CONTINUE |

`instruction(type, modifier, road, exit)` — `onto = road != null ? " onto <road>" : ""`;
`modWord`: sharp left/right, slight left/right, left, right, straight map to themselves, `uturn`→`around`, else null;
`sideWord`: null if modifier null, `left` if contains left, `right` if contains right, else null:

| type | text |
| --- | --- |
| `roundabout`, `rotary`, `roundabout turn` | exit != null: `at the roundabout take exit <exit><onto>`; else `at the roundabout[, <modWord>]<onto>` |
| `merge` | `merge[ <modWord>]<onto>` |
| `fork` | `keep <sideWord ?: "ahead"><onto>` |
| `on ramp` | `take the ramp[ <modWord>]<onto>` |
| `off ramp` | `take the exit[ <modWord>]<onto>` |
| `end of road` | `turn <sideWord ?: "ahead"><onto>` |
| `new name`, `continue` | road != null: `continue onto <road>`; else `continue straight` |
| `arrive` | `you have arrived` |
| other (`turn`, `depart`, `exit roundabout`, `ferry`, `notification`, …) | modifier `uturn`: `make a U-turn<onto>`; null or `straight`: `continue straight<onto>`; else `turn <modWord><onto>` |

Examples: (`turn`,`right`,`Main St`) → `turn right onto Main St`; (`roundabout`,null,`DN1`,2) → `at the roundabout take exit 2 onto DN1`; (`fork`,`slight left`,null) → `keep left`; (`turn`,`slight left`,null) → `turn slight left`.

`arrowFor(dir)`: LEFT `←`, RIGHT `→`, SHARP_LEFT `↰`, SHARP_RIGHT `↱`, SLIGHT_LEFT `↖`, SLIGHT_RIGHT `↗`, UTURN `⤺`, ROUNDABOUT `↻`, MERGE_LEFT `⇜`, MERGE_RIGHT `⇝`, FORK_* `⋔`, STRAIGHT/CONTINUE `↑`, ARRIVE `◉`.

`iconResFor(dir)` → `ic_man_left/right/sharp_left/sharp_right/slight_left/slight_right/uturn/roundabout`, MERGE_* → `ic_man_merge` (no handedness), FORK_* → `ic_man_fork` (no handedness), STRAIGHT/CONTINUE → `ic_man_straight`, ARRIVE → `ic_man_arrive` (§11.5).

HUD fallback words when a cue has no road name — `maneuverWord(dir)` (`GpxDashUi.kt:2450-2464`): LEFT `Turn left`, RIGHT `Turn right`, SHARP_LEFT `Sharp left`, SHARP_RIGHT `Sharp right`, SLIGHT_LEFT `Slight left`, SLIGHT_RIGHT `Slight right`, UTURN `U-turn`, ROUNDABOUT `Roundabout`, MERGE_* `Merge`, FORK_LEFT `Keep left`, FORK_RIGHT `Keep right`, STRAIGHT/CONTINUE `Continue`, ARRIVE `Arrive`.

`laneLabel(lanes)` (`GpxNav.kt:526-546`): null if no lanes or no `valid` lanes; else valid lanes'
arrows joined by a single space, where each arrow is from the lane's **first** indication
(lower-cased, substring match, in this order): `sharp left`→`↰`, `sharp right`→`↱`, `slight left`→`↖`,
`slight right`→`↗`, `uturn`→`⤺`, `left`→`←`, `right`→`→`, else `↑` (also when no indication).
Example: lanes `[{valid:false,[left]},{valid:true,[straight]},{valid:true,[straight,right]}]` → `"↑ ↑"`.

### 4.4 Off-route guidance, hysteresis and puck snapping [V]

| Threshold | Constant | Use | Source |
| --- | --- | --- | --- |
| `offTrackM < 40` | literal | puck drawn at the snapped point instead of raw GPS | `GpxDashUi.kt:2385-2388` |
| `offTrackM > 40` | `OFF_ROUTE_GUIDE_M = 40.0` | "join-route" compass guidance replaces turn-by-turn in the HUD and voice; status line shows `OFF <dist>` | `GpxNav.kt:426`, `GpxDashUi.kt:2168-2178`, `GpxNav.kt:647` |
| `offTrackM > 80` | literal | status text colour `#FF8A80` (else `#C8D0D8`); arms the auto-reroute timer | `GpxDashUi.kt:2159-2161`, `:2358` |

**Join-route guidance** (`GpxDashUi.kt:2168-2178`): `toSnap = bearing(rider → snap)`,
`dir = dirToFace(bestBearing(), toSnap)`; HUD icon = `iconResFor(dir)`, distance =
`formatDistance(offTrackM)`, text = `joinRouteWord(dir)`; lanes hidden; voice `onJoinRoute`.

`dirToFace(heading, target)` (`GpxNav.kt:385-397`), `d = normalizeDelta(target − heading)`:
`d > 150 || d < −150` UTURN; `d > 100` SHARP_RIGHT; `d < −100` SHARP_LEFT; `d > 35` RIGHT;
`d < −35` LEFT; `d > 15` SLIGHT_RIGHT; `d < −15` SLIGHT_LEFT; else STRAIGHT.

`joinRouteWord` (HUD): LEFT `Turn left`, RIGHT `Turn right`, SHARP_* `Sharp left/right`,
SLIGHT_* `Bear left/right`, UTURN `Turn around`, STRAIGHT/CONTINUE `Go ahead`, other `To route`.
`joinRouteSpeak` (voice): `turn left toward the route`, `turn right toward the route`,
`sharp left toward the route`, `sharp right toward the route`, `bear left toward the route`,
`bear right toward the route`, `turn around toward the route`, `go ahead to the route`, other
`head to the route` (`GpxNav.kt:400-423`).

`bestBearing()` (`GpxDashUi.kt:1138-1146`): GPS course if the fix has a bearing **and** is moving
(`speed > 1.2 m/s`); else the smoothed device compass heading if available; else the last map bearing.

A compass tick (§4.9) re-runs `applyProgress` when `offTrackM > 40` or when NAV_TO has no route
yet, so the join arrow follows the phone even while standing still (`GpxDashUi.kt:2263-2277`).

### 4.5 Waypoints, grade, ascent [V]

* `nextWaypointAhead` (`GpxNav.kt:322-343`): for each waypoint find its nearest track index (global); skip it if `cumDist[thatIndex] + 30 < cumDist[fromIndex]` (behind); among the rest choose the smallest **straight-line** distance to the rider. If none qualifies → the nearest waypoint overall (even if behind).
* `gradeAhead(from, 150)` (`GpxNav.kt:311-320`): null unless hasElevation and both ends have `ele`; walk forward until `cumDist[i] − cumDist[from] ≥ 150` or the end; `grade% = (e1 − e0) / max(dist, 1) × 100`.

### 4.6 ETA, remaining, formatting [V] (`GpxNav.kt:548-678`)

```
etaSeconds(remainM, speedMps): remainM <= 0 → 0
                               v = speedMps >= 1.5 ? speedMps : 50/3.6 (13.888… m/s)
                               round(remainM / v), >= 0                         // never null in practice
formatEta(sec):  null → "—"; m = sec/60 (int); m < 60 → "<m>m"; else "%dh%02dm"(m/60, m%60)
formatArrival(sec): null → "—"; now + min(sec, 48·3600) s, local time "%02d:%02d" (24 h, always)
formatDistance(m, METRIC):   m >= 1000 → "%.1f km"(m/1000) else "%.0f m"
formatDistance(m, IMPERIAL): mi = m/1609.344; mi >= 0.1 → "%.1f mi" else "%.0f ft"(m·3.28084)
formatSpeed(kmh): METRIC "%.0f"(kmh); IMPERIAL "%.0f"(kmh·0.621371)
speedUnitLabel: "km/h" | "mph"
formatAltitude(m): METRIC round(m); IMPERIAL round(m·3.28084)          (no unit; unit lives in the label)
formatAscent(m):   "↑<round(m)>" or "↑<round(m·3.28084)>"
```

Important [V]: the in-ride ETA uses the **instantaneous GPS speed** (with the 50 km/h floor
below 1.5 m/s) — not the router's duration. Route-preview chips instead use the router's
`durationSec` when > 0, else `etaSeconds(distanceM, currentSpeed)` (`GpxDashUi.kt:721-722, 740-741`).

Status-line text `formatHud(speedKmh, avgKmh, p, totalM, units, showNextStop)` (`GpxNav.kt:637-666`):
joins with `" · "` the non-empty parts `"Route · <total>"` (if total > 0), `"OFF <dist>"` (if offTrack > 40),
grade `"%+d%%"` (if |grade| ≥ 2, rounded), `"avg <speed>"` (if avg ≥ 1 km/h), and (if showNextStop and
a waypoint exists) `"→ <name|wpt> <dist>"`.

Follow-zoom ladder `zoomForSpeedKmh(v)` (`GpxNav.kt:670-678`) and the bike offset
(`GpxDashUi.kt:221-224`: projected → `min(z + 1.1, 18.6)`):

| speed km/h | `< 8` | `< 20` | `< 35` | `< 55` | `< 80` | `< 110` | `≥ 110` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| phone zoom | 17.8 | 17.0 | 16.2 | 15.4 | 14.6 | 13.8 | 13.0 |
| **bike zoom** | 18.6 | 18.1 | 17.3 | 16.5 | 15.7 | 14.9 | 14.1 |

When `speedZoom == false` (after any manual zoom) the follow zoom is fixed at **17.2 on the bike / 16.0 on the phone** (`GpxDashUi.kt:2390`, `:1209`).

`GpxRideStats` (average moving speed, `GpxNav.kt:683-713`): ignore the first fix; ignore samples
with `dt <= 0` or `dt > 10 000 ms`, `speed < 1.0 m/s`, or a jump `> 80 m`; accumulate distance/time;
`avgKmh()` = 0 until ≥ 5 000 ms of moving time.

### 4.7 Auto-reroute policy [V] (`GpxDashUi.kt:2356-2372`)

Only in NAV_TO with a destination and a non-null progress:

```
if offTrackM > 80:
    if offRouteSinceMs == 0: offRouteSinceMs = now
    if now − offRouteSinceMs > 8 000 ms
       and now − lastAutoRerouteMs > 15 000 ms
       and fix.hasAccuracy and fix.accuracy < 60 m:
        lastAutoRerouteMs = now; offRouteSinceMs = 0
        speak "Rerouting"; requestOsrm(loc, "recalc")
else:
    offRouteSinceMs = 0
```

`requestOsrm` (`GpxDashUi.kt:254-287`) shows `"Routing…"`, calls `OfflineRouter.routeAsync`
(single best route, §6.1). On result: `applyRoadRoute` (replace nav, clear preview/to-dest lines,
paint remaining route, camera to heading-up follow — or overview if no fix), status
`"Route · <distance>"`, and speaks `"Route updated"` (reason recalc) / `"Route ready"` (reason
start) **only if the route is ≥ 150 m**. On error: `"No road route · straight line"` (in practice
`routeAsync` always yields at least a beeline, §6.1). Manual reroute: menu **Recenter / Recalc** (§11.8).

GPX mode never auto-reroutes; FREE_RIDE has no route.

### 4.8 Arrival detection [V] + probable bug [I]

Route present (`GpxDashUi.kt:2201-2212`): `if remainM < 40 && !destArrivedSpoken && canDeclareArrival(remainM)`
→ `destArrivedSpoken = true`, speak `"Destination reached"`, then
autoFinish ? after **2 000 ms** `finishToFreeRideUi("Arrived", offerParking = true)` : show the arrive card.

No route yet (straight line, `:2238-2249`): `if dM < 80 && … canDeclareArrival(dM)` → speak
`"Arriving at <name>"`, autoFinish ? after **2 500 ms** finish-with-parking-offer : arrive card.

`canDeclareArrival(distM)` (`GpxDashUi.kt:334-354`): NAV_TO only. If `navStartDistM == null`
→ set it to `distM`; if `distM < 200` → `destArrivedSpoken = true`, post
`finishToFreeRideUi("Already nearby", offerParking=false)` (silent: that phrase is never spoken,
`:320`) and return false. Then require `start >= 200` and
(`elapsed since nav engaged >= 15 000 ms` **or** `start − distM >= 80 m`).

**Probable bug [I]:** both call sites evaluate `canDeclareArrival` lazily *after* the
`< 40 m` / `< 80 m` check, so `navStartDistM` is first recorded when the rider is already inside
the arrival radius (< 200 m) — every real arrival therefore takes the silent `"Already nearby"`
branch and **the Arrived sheet / "Destination reached" never appear**. The comment at
`GpxDashUi.kt:101` shows the intent: record the distance at the **first GPS fix after Go**.
README (`README.md:621`) advertises the arrival/parking sheet. **iOS: implement the intent** —
capture `navStartDist` on the first progress after nav engagement; `< 200 m` → "Already nearby"
(silent finish); otherwise declare arrival when inside the radius and (≥ 15 s elapsed or ≥ 80 m progressed).

`finishToFreeRideUi(spoken, offerParking)` (`GpxDashUi.kt:300-329`): no-op if already free ride
and not offering parking; `GpxSession.finishToFreeRide()`; clear nav/dest/route lines/dest pin;
hide maneuver row, lanes, next; metrics `"—"`; status colour normal; status text = spoken; speak
it unless `"Already nearby"`; arrive card shown iff offerParking with title `"Arrived · <name>"`
(or `"You've arrived"` if no name) and meta `"Mark parking, find a spot, or continue free ride"`;
hide HUD + metrics + preview, show the search pill.

Manual **End** never fakes arrival: `finishToFreeRideUi("Navigation finished", false)` (`:1484-1501`).

GPX mode has no arrival detection (the HUD shows `"To <trackName>"` + remaining distance when no turn is ahead).

### 4.9 Camera, puck and compass policy

Per GPS fix (`GpxDashUi.kt:2373-2398`) [V]:

```
moving = fix.hasSpeed && speed > 1.2 m/s
brng = fix.hasBearing && moving        → fix.bearing
     | headingUp && haveDeviceHeading → deviceHeading
     | progress != null               → progress.trackBearingDeg
     | dest != null                   → bearing(rider → dest)
     | else 0
me = (progress != null && offTrackM < 40) ? snap : raw fix
map.setMe(me, brng)
if follow && !inPreview:
    z = speedZoom ? followZoom(speedKmh) : (bike 17.2 | phone 16.0)
    map.follow(me, brng, z, headingUp, moving); lastMapBearing = headingUp ? brng : 0
    compassFab.rotation = headingUp ? −lastMapBearing : 0
```

Bike camera (`DashMapController.follow`, `DashMapController.kt:288-323`) [V]:
* heading-up: `mapOrientation = −bearing` (map rotated so travel points up); north-up: 0. The puck marker is always rotated by `bearing` (flat marker), so it points up in heading-up mode.
* **Look-ahead**: if moving and heading-up, the camera centre is offset ahead along the bearing by `zoom ≥ 17 → 40 m`, `≥ 15.5 → 70 m`, `≥ 14 → 110 m`, else `160 m`, using `dLat = m·cos(b)/111 320`, `dLon = m·sin(b)/(111 320·max(cos(lat), 0.2))` (`:402-407`). Result: the puck sits below the canvas centre.
* Zoom is re-applied only if `|currentZoom − target| ≥ 0.35`. **No animation** (camera jumps each fix).
* Worked example [I]: at 45° N, bike zoom 18.1 (8–20 km/h) = 0.394 m/px → 40 m ≈ **102 px** below centre; on a 384-px-tall canvas the puck lands at y ≈ 294, i.e. right at the top edge of the metrics card (§11.3). Zoom 18.6 (4.3–8 km/h): ≈ 144 px → hidden behind the card. Consider the visible map rect on iOS.

Phone camera (`MapLibreDashController.follow`, `:206-232`) [V]: tilt 52° when 3D on else 0;
bearing = heading if heading-up; target offset 70 m ahead if moving & heading-up; zoom clamped
[11, 18.5]; `easeCamera` 280 ms.

Compass [V] (`GpxDashUi.kt:1153-1227`): `TYPE_ROTATION_VECTOR` at `SENSOR_DELAY_UI`; axes
remapped for display rotation; azimuth smoothed as a unit vector with α = 0.15
(`s += 0.15·(sin r − s)`, `c += 0.15·(cos r − c)`, heading = atan2(s, c) in 0..360). Processing
throttled to once per **120 ms**. Each processed tick calls the join-route refresh; if not
moving and heading-up → map bearing = compass, and if following (not previewing) the camera
follows with zoom `speedZoom ? followZoom(0) : (17.2 | 16.0)`, `moving=false`.

Follow / free-pan [V]:
* `bumpFreePan()` (zoom FABs, overview): `follow = false`, label "Free pan", auto-recenter (`follow = true`) after **12 000 ms** (`GpxDashUi.kt:610-625`).
* Zoom FABs also set `speedZoom = false` permanently (until the next **Go**, which resets `follow`, `speedZoom`, `headingUp` to true, `:656-658`). After the 12 s auto-recenter the camera therefore returns to the fixed 17.2 (bike) zoom, not the user's zoom [V/I].
* **Dragging the map does not disable follow**: osmdroid pans, but the next fix (≤ 0.8 s) re-centres. Only FABs call `bumpFreePan` [V]. iOS may improve (pan ⇒ free pan 12 s).
* Previewing (`inPreview`) suspends follow; overview is always north-up (`resetNorth`).

Location acquisition [V] (`GpxDashUi.kt:2406-2444`): GPS provider `minTime 800 ms, minDistance 1.5 m`,
network provider `2 000 ms, 5 m`, both if enabled; the newest last-known fix of the two is fed
immediately. Status `"no GPS"` / `"location off"` / `"GPS error"` on failure.

### 4.10 Per-fix pipeline order [V] (`GpxDashUi.kt:2282-2399`)

1. `lastLoc = fix`; sync saved places if `MapPlaces.revision` changed.
2. Speed gauge = `formatSpeed(speed·3.6)`; unit label.
3. Ride stats; lap timer `onFix` (lap-finished status/voice `"Lap <n>"`); paint lap card.
4. GPX one-time orientation (§3.2).
5. NAV_TO without route and not yet requested → `requestOsrm(loc, "start")`.
6. Every **> 12 000 ms** (wall clock) → Overpass maxspeed lookup (§8).
7. `progress = nav?.progress(...)`; status line text (§4.6 / §11.11).
8. `applyProgress` (HUD, metrics, voice, arrival) (`:2144-2260`).
9. Auto-reroute check (§4.7).
10. Bearing / puck / camera (§4.9).

### 4.11 Test vectors

From `GpxNavTest.kt` (expected values in brackets are the exact derived values [I]):

| Test | Input | Expected |
| --- | --- | --- |
| totalAndProgressAlongStraightTrack (`:11-27`) | pts (0,0),(0.01,0),(0.02,0); `progress(0.01, 0, speed 10)` | `totalM ∈ [2200,2300]` [2223.8985]; nearestIndex 1; `doneM`, `remainM ∈ [1100,1150]` [1111.9493]; `offTrackM < 5` [0]; `etaSec ∈ [100,130]` [111] |
| etaUsesAssumedCruiseWhenStopped (`:29-37`) | pts (0,0),(0.01,0); `progress(0,0, speed 0)` | `etaSec > 60` [80 = 1111.95/13.889] |
| elevationAscentAndGrade (`:39-54`) | (0,0,100),(0.001,0,110),(0.002,0,130); `progress(0,0)` | hasElevation; `totalAscentM ∈ [29,31]` [30]; `remainAscentM ≥ 25` [30]; `gradePct > 0` [13.4898 %] |
| detectsRightTurnAhead (`:56-67`) | 21 pts north along lon 0 (lat 0..0.02 step 0.001) then 20 pts east at lat 0.02; `upcomingTurn(0, 5000, 35)` | RIGHT or SHARP_RIGHT [RIGHT, index 20, distance 2223.90 m, delta +90°] |
| zoomForSpeed (`:69-74`) | 10 km/h; 80 km/h | 17.0; 13.8 |
| formatKmAndEta (`:76-81`) | formatKm(500), formatKm(1500), formatEta(300) | `"500 m"`, `"1.5 km"`, `"5m"` |
| formatImperialDistanceAndSpeed (`:83-89`) | 152.4 m; 1609.344 m; 100 km/h | `"500 ft"`, `"1.0 mi"`, `"62"`, unit `"mph"` |
| dirToFaceUsesCompassRelativeToTarget (`:91-101`) | (0→90), (0→270), (45→50), (0→180) | RIGHT, LEFT, STRAIGHT, UTURN |
| orientsTrackOppositeWhenHeadingIsReverse (`:103-115`) | see §3.2 | flipped |
| progressDoesNotHopBackwardOnNearbyReturnLeg (`:117-131`) | (0,0),(0.01,0),(0.02,0),(0.01,0.0002),(0,0.0002); progress(0.01,0,8) then (0.01,0.00005,8) | nearestIndex 1; then ≤ 2 |

Derived vectors [I]:

* Snap: track as row 1, rider (0.004, 0.0003) → nearest index 0 (446.03 m > 80 → global search, still 0); t = 0.4; `offTrackM = 33.396`; snap (0.004, 0.0); `doneM = 445.28`; `remainM = 1778.6185`; eta @0 m/s = 128 s, @20 m/s = 89 s. Puck is snapped (33.4 < 40).
* `dirToFace` boundaries: (0→150) SHARP_RIGHT, (0→151) UTURN, (0→100) RIGHT, (0→101) SHARP_RIGHT, (0→35) SLIGHT_RIGHT, (0→36) RIGHT, (0→15) STRAIGHT, (0→16) SLIGHT_RIGHT, (350→10) SLIGHT_RIGHT, (10→350) SLIGHT_LEFT.
* `formatEta`: 0→`0m`, 59→`0m`, 60→`1m`, 3599→`59m`, 3600→`1h00m`, 3900→`1h05m`, 36000→`10h00m`.
* `formatDistance` metric: 12.5→`13 m` (Java HALF_UP; C `printf` would give `12 m`), 999.4→`999 m`, 999.6→`1000 m` (edge case: the < 1000 branch rounds up), 1000→`1.0 km`, 1049→`1.0 km`, 1050→`1.1 km`, 12345→`12.3 km`; imperial: 152.4→`500 ft`, 160.9→`528 ft` (0.09998 mi < 0.1), 161→`0.1 mi`, 499.5→`0.3 mi`.

---

## 5. Voice guidance (`GpxVoice`) [V]

Engine: Android `TextToSpeech`, language `Locale.getDefault()`, speech rate **0.95**, every
utterance `QUEUE_FLUSH` (interrupts whatever is speaking), utterance id `gpx-<ms>`
(`GpxVoice.kt:24-30, 113-118`). **All phrases are hard-coded English** while the TTS language
follows the phone locale (a German phone reads English text with a German voice) [V]; the docs
list GPX/TTS localisation as not done (`docs/07-IDEAS-AND-ISSUES.md:182-183`). Output goes to the
phone / helmet headset, never the bike speakers (`README.md:664`). Voice is gated by the
`voicePrompts` pref (default **on**).

### 5.1 Turn cues (`onProgress`, `GpxVoice.kt:32-78`)

Ignored when `offTrackM > 40` (join-route owns the mic); otherwise resets the join state. For the upcoming cue at distance d:

```
prepareM = clamp(speedMps × 14.0, 150, 700)
executeM = clamp(speedMps × 1.6, 25, 60)
phrase   = cue.instr if not blank else dirPhrase(dir)
if d <= executeM and executedIdx != cue.index:  executedIdx = preparedIdx = cue.index
                                                speak(capitalizeFirst(phrase))           // "Turn right onto Main St"
elif d <= prepareM and preparedIdx != cue.index: preparedIdx = cue.index
                                                speak("In " + roundedSpokenDistance(d) + ", " + phrase)
```

| speed | 0–38.6 km/h | 50 km/h | 80 km/h | 100 km/h | 130 km/h |
| --- | --- | --- | --- | --- | --- |
| prepare (m) | 150 | 194.4 | 311.1 | 388.9 | 505.6 |
| execute (m) | 25 | 25 | 35.6 | 44.4 | 57.8 |

`dirPhrase` fallback: `turn left`, `turn right`, `make a sharp left`, `make a sharp right`,
`keep left` (slight left), `keep right` (slight right), `make a U-turn`, `enter the roundabout`,
`merge left`, `merge right`, `keep left at the fork`, `keep right at the fork`,
`you have arrived`, `continue straight` (`GpxVoice.kt:96-111`). Note the geometric (GPX) cues
always carry `instr` (`turn left`, …) so the fallback is mostly unused.

`roundedSpokenDistance(m, units)` (`GpxNav.kt:565-584`):
* METRIC: `m ≥ 1000` → `"%.1f kilometers"`; else first of `[50,100,150,200,300,400,500,700,800]` ≥ m, else `round(m/100)·100` → `"<n> meters"`.
* IMPERIAL: miles ≥ 0.2 → `"%.1f miles"`; else ft = m·3.28084, first of `[50,100,150,200,300,500,800,1000,1500]` ≥ ft, else `round(ft/500)·500` → `"<n> feet"`.
* Vectors [I]: 10→`50 meters`, 51→`100 meters`, 260→`300 meters`, 650→`700 meters`, **820→`800 meters`** (rounds below), 850→`900 meters`, 950→`1000 meters`, 1250→`1.2 kilometers`; imperial 50 m→`200 feet`, 152.4 m→`800 feet`, 260 m→`1000 feet`, 322 m→`0.2 miles`.

Waypoints: when `nextWaypointM ≤ 120` and the waypoint key `"<lat>,<lon>"` differs from the last
announced → `"Approaching <name | waypoint>"`.

### 5.2 Join-route cues (`onJoinRoute`, `GpxVoice.kt:84-94`)

Speak when the turn band changed **or** ≥ **18 000 ms** since the last join cue:
`"<JoinRouteSpeak capitalised>, <formatDistance(offTrack)>"`, e.g. `"Turn left toward the route, 120 m"`.
Called from HUD updates when off route (> 40 m) and, with no route yet, when the straight-line
distance to the destination is > 40 m (`GpxDashUi.kt:2235-2237`).

### 5.3 Other spoken phrases (all English, `GpxDashUi.kt`)

`"Route updated"` (:269), `"Route ready"` (:271), finish texts `"Arrived"`, `"Navigation finished"` (:320),
`"Type your search on the phone"` (:593), `"Navigating to <name>"` (:695), `"Saved"` (:1393),
`"Home set"` (:1401, :1549), `"Marker added"` (:1409), `"Parking marked"` (:1425, :1526),
`"Parking updated"` (:1526), `"Parking cleared"` (:1516), `"Back on track"` (:1582),
`"Centered"` (:1588), `"Building there and back circuit"` (:1792), `"Lap timer armed"` (:1843),
`"Recording saved"` (:1897), `"Recording started"` (:1901), `"Pin dropped"` (:1914),
`"Destination reached"` (:2203), `"Arriving at <name>"` (:2240), `"Lap <n>"` (:2296),
`"Following the track the other way"` (:2310), `"Rerouting"` (:2366).

---

## 6. Routing services

### 6.1 Orchestrator (`OfflineRouter`) [V]

Entry points (all run on a worker thread; results posted to UI):
* `routeAsync(...)` — single best route for **nav start without a cached preview** and **reroute**: `computeRoutes(wantAlts=false)`, returns `routes.first()`; **never calls onError** (`OfflineRouter.kt:42-55`).
* `routeAlternativesDetailedAsync(...)` — preview options: `computeRoutes(wantAlts=true)` → `RouteResult` (`:69-81`).
* `circuitAlternativesAsync(...)` — out-and-back circuit (`:87-112`).

ORS key: user key from prefs if non-blank, else the build-time default `BuildConfig.ORS_API_KEY`
(from `-PorsApiKey`, `gradle.properties` or env `ORS_API_KEY`; empty by default) (`:33-36`, `app/build.gradle.kts:27-33`).

`computeRoutes(from, to, wantAlts, forcedVias=[], forceLabel=null)` (`OfflineRouter.kt:222-319`),
`approxKm` = haversine km:

1. **Offline graph** if `!wantAlts && !wantsAvoids && no vias` and a downloaded area's bbox covers both ends → A* route (§6.7) labelled `forceLabel ?: (FUN ? "Fun" : "Fast")`.
2. **wantsAvoids**:
   1. ORS (if key): `routeWithAvoids` — ORS with alternatives when `wantAlts && no vias && approxKm < 90`; if empty retry without alternatives; if `wantAlts && no vias && approxKm ≥ 50` and exactly 1 result → add one ORS route through `altViaSets[0]` labelled `"Alt"` (`:338-382`). Non-empty → `finalizeAvoid`, `avoidHonored = true`.
   2. Valhalla (no key needed): alternates = 0 if `!wantAlts` or vias; `> 100 km → 3`; `< 50 km → 1`; else 2 (`:385-413`). Non-empty → `finalizeAvoid`, honored.
   3. Offline avoid-highways (no vias, `avoidHighways`): A* skipping motorway+trunk → `[route "No highway"]`, `avoidHonored = !avoidTolls`, warning `"Avoiding motorways offline — tolls may still appear"` when tolls were requested.
   4. Fallback: `cloudWithoutAvoids` with FAST and no avoids, `wantAlts=false`, label `forceLabel ?: "Fast"`; `avoidHonored=false`, warning `"Couldn't avoid highways/tolls online — showing normal (may use motorway)"`.
3. **No avoids**: `cloudWithoutAvoids(opts, wantAlts, …)`, honored.

`cloudWithoutAvoids` (`OfflineRouter.kt:448-566`): `longTrip = approxKm > 100`, `shortTrip = approxKm < 50`.
* `osrmAlts` = 0 if `!wantAlts` or vias; 1 if longTrip; else 2.
* If `wantAlts && no vias`: Valhalla (avoids off) with alternates `longTrip ? 3 : 2`, label `forceLabel ?: "Fast"`.
* OSRM(`osrmAlts`); if still empty → OSRM(0) again (a second attempt).
* If still empty and an ORS key exists → ORS single route without avoids.
* Via fill: if `wantAlts && no vias && non-empty` and `dedupe(merged).size < need` (`need = longTrip ? 5 : 3`): via sets = shortTrip ? `shortViaSets` (3 sets) : `funViaSets.take(longTrip?2:1) + altViaSets.take(longTrip?2:1)`; for each set (stop once deduped size ≥ need+1) → OSRM(0, vias, `"Alt"`) and drop "junk" (below).
* `finalize`: `!wantAlts` → fastest after dedupe labelled `forceLabel ?: (FUN ? "Fun" : "Fast")`; `wantAlts` → `pickPreviewRoutes`.
* If nothing → **beeline** labelled `forceLabel ?: "Direct"`.

`finalizeAvoid` (`:423-440`): `!wantAlts` → fastest deduped labelled `forceLabel ?: "Fast"`; else `pickPreviewRoutes` (so avoid routes are labelled Fast/Fun/Alt in the preview, not "No highway").

`pickPreviewRoutes(routes, approxKm, mode, forceLabel)` (`:595-639`):
```
maxTotal = approxKm > 100 ? 5 : 3
distinct = dedupe(routes, approxKm) sorted by durationSec
fast = distinct[0]
rest = distinct where !sameCorridor(r, fast)
fun  = rest max by twistScore
alt  = rest where (fun == null || !sameCorridor(r, fun)) min by durationSec
labels: fast → (forceLabel if mode FAST and forceLabel non-blank) else "Fast"
        fun  → (forceLabel if mode FUN and non-blank) else "Fun";  alt → "Alt"
core = FUN ? [fun, fast, alt] : [fast, fun, alt]   (nulls dropped)
if approxKm <= 100 or core.size >= maxTotal → core.take(maxTotal)
else core + (rest not sameCorridor with any core, by duration, labelled "Alt").take(maxTotal − core.size)
```
Index 0 is pre-selected in the UI (so in FUN mode the "Fun" route is the default).

Tolerances (`:641-647`, `:734-749`) — both conditions must hold to count as "same":

| | approxKm < 50 | otherwise |
| --- | --- | --- |
| `dedupe` | abs(Δdistance) < 200 m and abs(Δduration) < 40 s | < 800 m and < 120 s |
| `sameCorridor` | abs(Δdistance) < 500 m and abs(Δduration) < 90 s | < 1 500 m and < 180 s |

"Junk" filter for via-offset routes (`:650-732`): (1) any U-turn step strictly between the first
and last steps (`uturn`/`u-turn` in type or modifier); (2) road-name ping-pong: a **Romanian local
street** name (lower-cased, length ≥ 5, not `-`/`unnamed road`, not matching `^(dn|dj|dr|a|e)\s*\d.*`,
not starting with `autostrada`/`centura`/`bulevard`/`calea `, and starting with `strada`/`aleea`/`intrarea`)
re-appearing 40–500 m further along; (3) tight cul-de-sac: resample the geometry every ≥ 20 m
(needs ≥ 10 raw / ≥ 8 resampled points) and flag any pair 60–450 m apart along-track that is
< 25 m apart in a straight line.

Beeline (`:751-784`): `n = clamp(int(dist/2000), 2, 200)` segments, linear interpolation of
lat/lon (n+1 points), `durationSec = dist / 13.9`, steps `[depart "Head toward destination (offline)" @from, arrive "Destination" @to]`.
The UI flags it as `"Straight line (no road route) · …"` when `label == "Direct"` or any step's
road name contains `offline` (`GpxDashUi.kt:723-726`).

**Circuit (out-and-back)** (`computeOutAndBack`, `:115-220`): one request start → [dest] → start,
label `"Circuit"`: ORS (if avoids & key) → Valhalla (if avoids) → OSRM(0, vias=[dest]). If all
fail: compute A→B and B→A with `computeRoutes(wantAlts=false)` and concatenate (points
`a + b.drop(1)`, distances/durations/steps summed). If avoids were requested but only OSRM
succeeded → `avoidHonored=false`, warning `"Couldn't avoid highways/tolls — circuit may use motorway"`.
Returns at most one route (deduped). Errors: `"Couldn't build there-and-back circuit"` / `"Circuit failed"`.

### 6.2 OSRM (public demo) [V] (`OsrmRouter.kt`)

```
GET https://router.project-osrm.org/route/v1/driving/{fromLon},{fromLat}[;{viaLon},{viaLat}…];{toLon},{toLat}
    ?overview=full&geometries=geojson&steps=true&alternatives={false|N}          (N = clamp(alts,0,4))
fallback query: ?overview=simplified&geometries=geojson&steps=false&alternatives=false
```
Example [I]: `https://router.project-osrm.org/route/v1/driving/26.1025,44.4268;21.2087,45.7489?overview=full&geometries=geojson&steps=true&alternatives=2`.
Coordinates are Kotlin `Double.toString()` (shortest repr, `.` decimal).

* Throttle host `router.project-osrm.org` 600 ms; connect timeout 25 s; read 60 s (full) / 45 s (simplified); max body 24 MiB (`:84-103`). `annotations` deliberately not requested (`:81`).
* Fallback chain (`:117-133`): alts>0: full+alts → full single (`&alternatives=false`) → simplified single. alts=0: full single → simplified single. A simplified response has no steps (`steps=false`), so `GpxNav` receives an empty step list and falls back to geometric turn inference (§4.3) [V].
* Response: `code` must equal `"Ok"` else error `message` (or `code`, or "No route"); `routes[]` (empty → "No route"); per route `geometry.coordinates[[lon,lat],…]` (≥ 2 points else "Route too short"), `distance` (m), `duration` (s), `legs[].steps[]` with `maneuver.type` (default `"continue"`), `maneuver.modifier` (blank → null), `maneuver.location[lon,lat]`, `maneuver.exit` else `step.exit`, `step.name` (default ""), `step.distance`, lanes from the **first** `step.intersections[]` entry that has `lanes[]`: `{valid (default false), indications[]}` (`:136-204`). Routes that fail to parse are skipped.
* No avoid flags (public demo has none).

### 6.3 Valhalla (FOSSGIS OSM.de public instance) [V] (`ValhallaRouter.kt`)

`POST https://valhalla1.openstreetmap.de/route`, JSON body built with insertion-ordered keys
(`:37-60`). Costing profile is **`motorcycle`** when avoiding highways (with
`"exclude_highways": true`), otherwise **`auto`**; never `use_highways` (comment `:12-17`: auto
`use_highways=0` invented 8–10 h detours). Exact bodies [V/I]:

```json
{"locations":[{"lat":44.4268,"lon":26.1025},{"lat":45.7489,"lon":21.2087}],"costing":"auto","costing_options":{"auto":{"shortest":false}},"directions_options":{"units":"kilometers"},"alternates":2}
```
```json
{"locations":[{"lat":44.4268,"lon":26.1025},{"lat":45.7489,"lon":21.2087}],"costing":"motorcycle","costing_options":{"motorcycle":{"shortest":false,"exclude_highways":true,"use_tolls":0,"toll_booth_penalty":600}},"directions_options":{"units":"kilometers"},"alternates":3}
```
Tolls only: `"costing":"auto"`, `{"auto":{"shortest":false,"use_tolls":0,"toll_booth_penalty":600}}`.
Vias are inserted as extra `locations` objects. `alternates` present only when `clamp(n,0,3) > 0`.

* Throttle `valhalla1.openstreetmap.de` 500 ms; connect 25 s; read 60 s; max 24 MiB.
* Response (`:76-96, 117-184`): `trip` (label = given label or `avoidLabel`: `No hwy/toll`, `No highway`, `No toll`, `Fast`) and `alternates[].trip` (label `"Alt"`). Per trip: `legs[]` — `shape` (polyline **precision 6**), `summary.length` (**km**) and `summary.time` (s) summed over legs (fallback `trip.summary`); points concatenated with the first point of each subsequent leg dropped; `maneuvers[]`: `begin_shape_index` (into that leg's shape), `street_names[]` (joined with `/`, road name = text before the first `/`), `length` (km → m), `highway` (bool), `toll` (bool), `type` (int). Motorway km += length if `highway` or the name looks like a motorway (`autostrada`/`autobahn`/`autoroute` or regex `(?<![a-z])a\s?\d{1,3}(?!\d*[a-z])`, case-insensitive); toll km += length if `toll`. `exit` and `lanes` are always null (roundabout exit counts are **not** consumed).
* Filter: when avoiding highways keep trips with motorway < 1.0 km; avoiding tolls keep toll < 1.0 km; if none survive keep all. Sort by duration. Empty → error "No Valhalla route".

Maneuver type → (type, modifier) (`:199-224`):

| Valhalla type | mapped | | Valhalla type | mapped |
| --- | --- | --- | --- | --- |
| 1,2,3 (Start*) | depart, – | | 17 RampStraight | on ramp, straight |
| 4,5,6 (Destination*) | arrive, – | | 18 RampRight | on ramp, right |
| 7 Becomes, 8 Continue | continue, straight | | 19 RampLeft | on ramp, left |
| 9 SlightRight | turn, slight right | | 20 ExitRight | off ramp, right |
| 10 Right | turn, right | | 21 ExitLeft | off ramp, left |
| 11 SharpRight | turn, sharp right | | 22 StayStraight | continue, straight |
| 12 UturnRight, 13 UturnLeft | turn, uturn | | 23 StayRight | fork, right |
| 14 SharpLeft | turn, sharp left | | 24 StayLeft | fork, left |
| 15 Left | turn, left | | 25 Merge | merge, – |
| 16 SlightLeft | turn, slight left | | 26 RoundaboutEnter | roundabout, – |
| 27 RoundaboutExit | exit roundabout, – | | 28, 29 Ferry | ferry, – |
| other | continue, straight | | | |

### 6.4 OpenRouteService [V] (`OrsRouter.kt`) — needs an API key

`POST https://api.openrouteservice.org/v2/directions/driving-car/geojson`, headers as §9 plus
`Authorization: <key>` (raw); on **any** failure, unless the key already starts with `Bearer `,
retry once with `Authorization: Bearer <key>` (`:133-159`). Throttle `api.openrouteservice.org`
400 ms; connect 20 s; read 35 s; max 8 MiB.

Body (`:40-69`), example with alternatives and both avoids [V/I]:
```json
{"coordinates":[[26.1025,44.4268],[21.2087,45.7489]],"instructions":true,"geometry":true,"elevation":false,"preference":"recommended","alternative_routes":{"target_count":3,"weight_factor":2,"share_factor":0.8},"options":{"avoid_features":["highways","tollways"]}}
```
`preference` = `recommended` when avoiding; `shortest` in FUN mode (no avoids); else `recommended`.
`alternative_routes` only when requested and `maxAlternatives > 0` (default 4); on failure the
request is retried once without it (`:70-80`). `avoid_features` lists `highways` and/or `tollways`.

Response: `features[]` (missing/empty → error `error.message` or "No route"); per feature
`geometry.coordinates[[lon,lat]]`, `properties.summary.distance` (m) / `.duration` (s),
`properties.segments[].steps[]`: `way_points[0]` (index into coordinates), `type` (default 6),
`name` (`"-"` → ""), `distance`, `exit_number` (`:160-219`). Type map (`:221-237`): 0 turn/left,
1 turn/right, 2 turn/sharp left, 3 turn/sharp right, 4 turn/slight left, 5 turn/slight right,
6 continue/straight, 7 roundabout, 8 exit roundabout, 9 turn/uturn, 10 arrive, 11 depart,
12 turn/slight left (keep left), 13 turn/slight right (keep right), other continue/straight.

`roundTrip(...)` with `options.round_trip {length 5 000–200 000, points 3–8, seed}` exists but is **never called** [X] (`OrsRouter.kt:87-121`).

### 6.5 Fun / alternative via planner [V] (`FunRoutePlanner.kt`)

`offsetPoint(from, to, fraction, sideKm)` = point at `fraction` of the straight lat/lon
interpolation, moved `|sideKm|` perpendicular (bearing ± 90°, + for positive side) using the
spherical destination formula with R = 6 371 km (`:83-106`).

| Generator | offset | via sets |
| --- | --- | --- |
| `funViaSets` (`:23-36`) | `clamp(distKm·0.18, 3, 18)` km (distKm ≥ 1) | [midL(0.45,+o)], [midR(0.55,−o)], [earlyL(0.28,+0.7o), lateR(0.72,−0.7o)] |
| `altViaSets` (`:42-49`) | `clamp(distKm·0.10, 1.5, 12)` | [midL(0.40,+o)], [midR(0.60,−o)], [farL(0.50,+1.6o)] |
| `shortViaSets` (`:55-62`) | `clamp(distKm·0.14, 0.35, 2.8)` (distKm ≥ 0.4) | [midL(0.45,+o)], [midR(0.55,−o)], [midL2(0.35,+1.35o)] |

`twistScore(r) = (km / max(min,1))·8 + steps·0.15 + km·0.05` (`:76-81`).
`circuitWaypoints` (triangle loop) is **unused** [X] (`:68-73`).

Test vectors (`FunRoutePlannerTest.kt`): `circuitWaypoints(45,25,60)` → 4 points, last == start,
others > 3 km away (radius 9.549 km [I]); `funViaSets(45,25,46,26)` → ≥ 2 non-empty sets
[I: dist 135.79 km, offset 18 km, midL (45.35776, 25.63947), midR (45.64193, 25.35958)];
twistScore(10 km/600 s/0 steps) = 8.5 < twistScore(25 km/1200 s/20 steps) = 14.25.

### 6.6 Polyline decoding [V]

* OSRM and ORS: GeoJSON coordinates (no polyline). Valhalla: encoded polyline with **1e-6** precision (`ValhallaRouter.kt:227-257`). Decoding: standard Google algorithm (5-bit chunks, `+63`, continuation bit `0x20`, zig-zag sign `(r & 1) ? ~(r >> 1) : (r >> 1)`), values accumulated as 32-bit ints, divided by 1e6. Using 1e5 on Valhalla data yields coordinates 10× too small.
* Test vectors: `ValhallaRouterTest.kt:10-24` round-trip (44.4268, 26.1025), (45.7489, 21.2087) within 1e-5; empty string → empty list. Derived [I]: that pair encodes (precision 6) to `_brvsAgmdxp@gfuoAneuiH`; Google's sample (38.5,−120.2),(40.7,−120.95),(43.252,−126.453) encodes to `_izlhA~rlgdF_{geC~ywl@_kwzCn`{nI` at precision 6 and `_p~iF~ps|U_ulLnnqC_mqNvxq`@` at precision 5.

### 6.7 Offline routing & areas (summary) [V] — optional for iOS v1

* `OfflineRoadGraph` (`OfflineRoadGraph.kt`): when the rider downloads an area, roads are fetched once from Overpass (`POST https://overpass-api.de/api/interpreter`, `data=` form body, read timeout 120 s, max 64 MiB, throttle 1 000 ms) with
  ```
  [out:json][timeout:120];
  way["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|road)(_link)?$"]({south},{west},{north},{east});
  out body;
  >;
  out skel qt;
  ```
  Directed edges honour `oneway` (`yes/true/1` forward only, `-1/reverse` backward only). Class → speed m/s: motorway 30.6, trunk 25.0, primary 19.4, secondary 16.7, tertiary 13.9, unclassified/road/other 11.1, residential 8.3, service 5.6, living_street 4.2 (`_link` stripped). File `filesDir/offline_routing/<sanitized name>.graph`, **big-endian** (Java `DataOutputStream`): `int32 magic 0x4F43524F ('OCRO')`, `int32 version 1`, `float64 south, west, north, east`, `int32 nodeCount`, nodeCount × (`float64 lat`, `float64 lon`), `int32 edgeCount`, edgeCount × (`int32 from`, `int32 to`, `float32 distM`, `int8 class`) (`:228-241`). A* on time cost `dist/classSpeed`, heuristic `haversine/30.6`; endpoints snap to the nearest node within 3 000 m; `avoidHighways` skips classes 0–1; turn steps synthesised where the bearing changes ≥ 25° (`< 60` slight, `≤ 150` normal, else sharp), `roadName` always empty (`:284-424`).
* `MapOfflineManager` downloads MapLibre vector regions for both styles (day+night) at z10..15 (standard) or z10..16 (high), tile-count limit 200 000, metadata JSON `{"name","style","night"}` (`MapOfflineManager.kt:32-142`); `OfflineAreasStore` keeps `{"name","north","south","east","west","zoomMax","vector","raster","createdAt"}` in prefs `opencfmoto_offline_areas` key `areas` (`OfflineAreasStore.kt:28-85`). Area presets: radius 10/25/50 km around the rider (`dLat = r/111.32`, `dLon = r/(111.32·max(cos lat, 0.01))`) or the GPX bbox padded 2 km (`GpxActivity.kt:804-835`). These benefit the **phone** (MapLibre) map; the bike raster map has only its interactive tile cache (OSM forbids bulk raster downloads, `GpxOsmdroid.kt:20-24`).
* `RegionPackStore` (PMTiles packs, `pois.json`, local styles) is **dormant** [X] (`RegionPackStore.kt:10-16`); `OfflinePoiIndex` reads that pack plus an in-memory "corridor" cache (§7.5).

---

## 7. Search

### 7.1 Photon (primary, location-biased) [V] (`NominatimSearch.kt:92-146`)

When the rider position is known, two GET requests (throttle `photon.komoot.io` 300 ms, default timeouts §9):
```
https://photon.komoot.io/api/?q={enc}&lat={lat}&lon={lon}&limit=12&location_bias_scale=0.2&lang=default
https://photon.komoot.io/api/?q={enc}&lat={lat}&lon={lon}&limit=10&location_bias_scale=0.12&lang=default&osm_tag=place:city&osm_tag=place:town&osm_tag=place:municipality
```
`{enc}` = Java `URLEncoder.encode(q, "UTF-8")` (space → `+`). Example [I]: `q=C%C3%A2mpina&lat=44.4268&lon=26.1025`.
Parsed fields: `features[].geometry.coordinates[lon,lat]`, `properties.name` (blank → `street` → `"Place"`),
type = `osm_value` (blank → `type`), importance = `extentImportance + properties.importance(default 0)`,
`extentImportance = min(0.9, |e2−e0|·|e1−e3|·80)` from `properties.extent[4]` (0 if absent).
Subtitle (`:255-270`): `"<osm_value> · <distinct non-blank of city, county, state, country joined by ", ">"`,
falling back to `country`. Example (hardware footage [HW]): `"city · Prahova, România"`.

### 7.2 Nominatim (fallback) [V] (`NominatimSearch.kt:148-190`)

Used when there is no position, or Photon failed/returned nothing:
```
https://nominatim.openstreetmap.org/search?q={enc}&format=jsonv2&addressdetails=1&limit=20[&viewbox={lon-1.6},{lat+1.6},{lon+1.6},{lat-1.6}&bounded=0]
```
Throttle **1 100 ms** (usage policy ≤ 1 req/s). Parsed: array of `{display_name, name (blank → display_name before first ',' → "Place"), type (blank → addresstype), importance, lat, lon}` (lat/lon arrive as **JSON strings**); subtitle = `display_name`.

### 7.3 Ranking, cache, result limits [V] (`NominatimSearch.kt:192-244`, `:73-85`)

```
distKm = haversine(near, place) or 500 if no position
nameBonus = name == q ? 40 : name.startsWith(q) ? 28 : name.contains(q) ? 10 : 0     (lower-cased)
distPenalty = d < 50   ? d·0.12
            : d < 150  ? 6 + (d−50)·0.35
            : d < 500  ? 41 + (d−150)·0.55
            : d < 2000 ? 233 + (d−500)·0.35
            :            758 + d·0.15
score = typeWeight·12 + importance·90 + nameBonus − distPenalty         → sort desc,
distinct by "<lower name>|%.3f lat|%.3f lon", take 12
typeWeight: city,municipality 100; town 88; administrative,county,state,region 70;
            suburb,borough,quarter,neighbourhood,neighborhood 45; village 28;
            hamlet,isolated_dwelling,farm,allotments 8; locality 22; highway,road,residential 35;
            station,bus_stop,tram_stop,subway_entrance 12; else 20
```
LRU cache: 64 entries, key `"<lower q>|%.2f,%.2f"` of the position (or `"-"`), non-empty results only.
Errors propagate as the exception message (e.g. §9 HTTP messages).

### 7.4 POI chips — "near me" via Overpass [V]

Chips (`NominatimSearch.kt:24-33`): **Fuel** `amenity=fuel`, **Cafe** `amenity=cafe`,
**Food** `amenity=restaurant`, **Parking** `amenity=parking`, **Hotel** `tourism=hotel`,
**ATM** `amenity=atm`, **Hospital** `amenity=hospital`, **Viewpoint** `tourism=viewpoint`.

`nearbyByTag(tag, lat, lon, radius=6000, max=30)` (`OverpassClient.kt:73-152`): radii tried in
order **6 000, 18 000, 48 000 m** until something is found. Query (exact, after trimIndent):
```
[out:json][timeout:25];
(
  node["{key}"="{value}"](around:{radius},{lat},{lon});
  way["{key}"="{value}"](around:{radius},{lat},{lon});
);
out center {max*2};
```
POSTed as `data=<URLEncoder(query)>`. Example body [I] for fuel at (44.4268, 26.1025):
`data=%5Bout%3Ajson%5D%5Btimeout%3A25%5D%3B%0A%28%0A++node%5B%22amenity%22%3D%22fuel%22%5D%28around%3A6000%2C44.4268%2C26.1025%29%3B%0A++way%5B%22amenity%22%3D%22fuel%22%5D%28around%3A6000%2C44.4268%2C26.1025%29%3B%0A%29%3B%0Aout+center+60%3B`
Parse `elements[]`: position = `lat/lon` or `center.lat/lon`; `brand` = tags.brand → tags.operator;
`name` = tags.name → brand → value with `_`→space, first letter capitalised; subtitle = non-empty of
(brand if ≠ name, `"<addr:street> <addr:housenumber>"`) joined `" · "`; category = value.
Sorted by `approxMetres` (`dLat·111 320`, `dLon·111 320·cos(mean lat)`, hypot), distinct by
`%.5f,%.5f`, take `max`. UI then rewrites each result: `category = chip label`,
`subtitle = "<formatDistance> · <old subtitle>"`, sorted by distance (`GpxDashUi.kt:1043-1049`).
Status texts: `"Need GPS for nearby POI"`, `"Finding <Label> nearby…"`, `"No <label> found nearby"`,
`"<n> <label> nearby"`.

### 7.5 Offline POI index [V] (`OfflinePoiIndex.kt`)

Sources: the active region pack's `pois.json` (dormant, §6.7) + the corridor cache (hub
"download roadside POI" for the loaded GPX: Overpass bbox of ≤ 60 sampled track points padded
0.003°, `node["amenity"~"fuel|parking|cafe|restaurant|hospital|atm"]` + `node["tourism"~"hotel|viewpoint"]`,
`out body 40`, subtitle `"OSM <kind>"` — `OverpassClient.kt:178-225`). Text search = substring
of name/category/subtitle, sorted by `|Δlat|+|Δlon|`, limit 20; category search = substring of the
chip label in category/name/subtitle. On the dash: POI chips use offline results **first** if any;
text search uses online first and offline only when online returns nothing or fails (`GpxDashUi.kt:1016-1085`).

### 7.6 Dash search UX [V] (`GpxDashUi.kt:572-609, 863-1085, 1348-1375`)

* Open via the search pill (or ASSISTANT key). Sheet covers the full canvas (§11.3).
* Typing: on every change cancel the pending suggestion; `< 2` chars → idle list; else status `"Suggestions…"` and run the search after **350 ms** debounce. IME "search" / magnifier → immediate search. Empty query → idle list.
* Search statuses: `"Searching…"`, `"No results"`, `"<n> places"`, error text.
* **Idle list** (`:981-1009`): home, parked, favorites, markers, history (history minus category `mode`, `parking`, and (0,0)), distinct by `"<name>|%.4f|%.4f"`, first 12; status `"Recent & favorites"`; when empty `"Search for a place or tap a category"` (phone) / `"Type on PHONE, or tap a category"` (bike).
* **On the bike** (projected) the dash has no keyboard: input not focusable, hint `"Type on your PHONE keyboard…"`, status `"⌨ Type on PHONE — results show here"` in `#E65100` 16 sp; the phone app is brought forward with its destination field focused and the keyboard shown (`MainActivity.kt:572-610`); if no phone UI is registered: `"Open OpenCfMoto on the phone, then type"`. Phone keystrokes are debounced 350 ms and forwarded when ≥ 2 chars (`MainActivity.kt:612-625`); the dash sets its input text and runs `runDashSearch` (`GpxDashUi.kt:1335-1347`). Voice: `"Type your search on the phone"`.
* Result row tap → route preview (§11.7).

---

## 8. Speed limits via Overpass [V] (`OverpassClient.kt:154-176, 227-247`; `GpxDashUi.kt:2319-2336`)

* Trigger: on a GPS fix when **> 12 000 ms** since the last lookup (time-based, every mode, no distance criterion).
* Cache: key `"%.3f,%.3f"` of the fix (≈ 111 m × 111·cos φ m cell), TTL **10 min**, in-memory.
* Query (radius 25 m), POST `data=` to `https://overpass-api.de/api/interpreter` (throttle 1 000 ms, connect 20 s, read 25 s):
  ```
  [out:json][timeout:12];
  way(around:25,{lat},{lon})["maxspeed"];
  out tags center 1;
  ```
  Example body [I]: `data=%5Bout%3Ajson%5D%5Btimeout%3A12%5D%3B%0Away%28around%3A25%2C44.4268%2C26.1025%29%5B%22maxspeed%22%5D%3B%0Aout+tags+center+1%3B`
* Result: first element's `tags.maxspeed` (trimmed); none → `SpeedLimit(null,"—")`; any exception → `(null,"—")`.
* `parseMaxspeedKmh(raw)`: lower-case/trim; `none|signals|variable|walk` → null; ends with `mph` → `toInt(n·1.60934)`; else leading `[0-9.]*` → `toDouble().toInt()` (else null). Implicit values such as `RO:urban` → null (sign hidden).
* `formatLimit`: null → `"—"`; METRIC `"<kmh>"`; IMPERIAL `"<toInt(kmh·0.621371)>"`. Display: sign visible iff label not blank and ≠ `"—"`.
* Pitfall [I]: an OSM `50 mph` limit shown in imperial becomes `toInt(toInt(50·1.60934)·0.621371) = toInt(80·0.621371) = 49`. iOS should keep the native unit.
* **Test vectors** (`OverpassClientTest.kt`): `"50"`→50, `"50 km/h"`→50, `"50 mph"`→80, `"none"`→null; `formatLimit(SpeedLimit(100,"100"))` metric `"100"`, imperial `"62"`.

---

## 9. HTTP layer (`AppHttp`) [V]

* **User-Agent** on every request (and osmdroid tiles): `OpenCfMoto/<versionName> (moto dash map; +https://github.com/zanderp/open-cfmoto)` → `OpenCfMoto/2.0.18 (moto dash map; +https://github.com/zanderp/open-cfmoto)` (`AppHttp.kt:35-36`). iOS must send its own identifying UA (required by OSM/Nominatim/Overpass policies).
* `getText(url, connect=10 000, read=10 000, accept="application/json", max=8 MiB)` (`:253-269`).
* `postForm(url, body, connect=20 000, read=25 000, max=8 MiB)`, `Content-Type: application/x-www-form-urlencoded; charset=UTF-8`, `Accept: application/json` (`:272-291`).
* `postJson(url, body, connect=15 000, read=20 000, accept="application/json, application/geo+json", max=8 MiB, extraHeaders)`, `Content-Type: application/json; charset=UTF-8` (`:294-316`).
* Size caps: 8 MiB default, `MAX_ROUTE_BYTES` 24 MiB (OSRM/Valhalla), 64 MiB (offline roads); overflow → `IOException("Response too large")` (counts UTF-16 chars) (`:38-40, 340-355`).
* Errors (`:320-338`): non-2xx → `HttpError(code, msg, busy)`, `busy = code == 429 || 5xx`; messages `"Map service is busy (rate limited) — try again shortly"` (429), `"Map service temporarily unavailable (HTTP <code>)"` (5xx), `"Request failed (HTTP <code>)"` (other).
* Per-host spacing `throttle(host, minIntervalMs)` (`:239-250`): sleeps `last + min − now` when in `1..min`, then stamps now. Values: photon 300, nominatim 1 100, OSRM 600, valhalla 500, ORS 400, overpass 1 000 ms. Implementation detail [I]: the sleep happens **inside one global lock**, so concurrent requests to different hosts serialise; iOS should use a per-host async gate.
* URL/form encoding = Java `URLEncoder` (`:318`): unreserved `A–Z a–z 0–9 . - * _`, space → `+`, everything else `%XX` (UTF-8, upper-case hex). Note `~` is encoded (`%7E`).
* **Cellular pinning** (`:62-163`): while projecting, the Android process is bound to the bike Wi-Fi (no internet). Every map/nav request and osmdroid tile is opened on a validated internet network — preferring cellular (`requestNetwork(INTERNET + TRANSPORT_CELLULAR)`), skipping VPNs and unvalidated Wi-Fi — and MapLibre gets an OkHttp client bound to that network (connect 20 s, read 30 s, write 20 s, call 60 s). Preview shows `"No mobile data pin — enable cellular for road routes"` when no such network exists (`GpxDashUi.kt:809-814`). README: a mobile-data plan is recommended (`README.md:106`). **iOS: see §16 risk R3.**

---

## 10. Map tiles, styles, night mode

### 10.1 Bike raster tiles (osmdroid) [V][HW]

* Tile source `TileSourceFactory.MAPNIK` of osmdroid **6.1.20** (`gradle/libs.versions.toml`): `https://tile.openstreetmap.org/{z}/{x}/{y}.png`, zoom 0–19, 256-px tiles, `.png`, policy max 2 threads, no bulk, no preventive download, meaningful UA required [V] (constant read from the published `osmdroid-android-6.1.20-sources.jar`, `TileSourceFactory.java:100-108`; URL pattern `XYTileSource.getTileURLString`: `baseUrl + z + "/" + x + "/" + y + ".png"`).
* MapView: `minZoom 5`, `maxZoom 20` (over-zoom past 19), initial zoom 16, multi-touch on, data connection on, `isTilesScaledToDpi = true`, background `#101418` (`DashMapController.kt:38-55`).
* Cache/config (`GpxOsmdroid.kt:34-49`): base `filesDir/osmdroid`, tile cache `…/tiles`, UA = §9 UA, **expiration override 90 days**, **2 download threads**, cache cap **512 MiB**. Downloads go through `CellularTileDownloader`: redirects 301/302/307/308 followed up to 3 times, non-image MIME only logged, non-200 → tile missing (`CellularTileDownloader.kt:38-183`). The app never calls osmdroid `Configuration.load()`, so the normalised UA is null and the OpenCfMoto UA is sent [I].
* Hub can clear the raster cache (`GpxOsmdroid.kt:83-86`).

### 10.2 Phone vector styles (MapLibre) [V]

`https://tiles.openfreemap.org/styles/liberty` (day) and `https://tiles.openfreemap.org/styles/dark`
(night) (`MapLibreDashController.kt:581-582`), unless a dormant region pack provides local style
files. 3D: tilt 52° plus an added fill-extrusion layer `ocm-buildings-3d` on source-layer
`building` (source `openmaptiles` or the first source), min zoom 14, colour `#C8CCD4`, opacity 0.7,
height `coalesce(render_height, height, 6)`, base `coalesce(render_min_height, min_height, 0)`
(`:376-409`). On the bike the 3D toggle is a no-op (`DashMapController.kt:142-144`).

### 10.3 Night mode [V]

There is **no sunrise/sunset algorithm** anywhere in the code (README's "sunset/sunrise clock"
wording is loose) (`NightPrefs.kt:55-69`):

```
isNightNow = DAY → false; NIGHT → true;
             AUTO → (phone UI mode is night) || (local hour < 7 || hour >= 19)     // night 19:00–06:59
```
Pref: SharedPreferences `opencfmoto_bike`, key `map_theme`, values `AUTO|DAY|NIGHT` (default AUTO);
`cycle()` order AUTO → DAY → NIGHT → AUTO.

Effect:
* Bike (osmdroid): night applies `TilesOverlay.INVERT_COLORS`, a colour matrix `R' = 255 − R, G' = 255 − G, B' = 255 − B, A' = A` on the **tiles only** (`DashMapController.kt:148-153`; matrix from osmdroid `TilesOverlay`). Route lines, markers and all chrome are unchanged.
* Phone (MapLibre): reloads the OpenFreeMap dark/liberty style.
* The chrome (cards, FABs, search sheet, menu) has **one palette** for day and night (§11.2). The white search sheet stays white at night.
* Re-evaluation [V]: only on bind, on a theme segment tap, on **Recenter / Recalc**, and from the phone Dash-view 🌗 button (`GpxDashUi.kt:170-173, 1562, 1610-1624`; `HudViewActivity.kt:268-272`). Unlike the Android-Auto path (60 s loop, `aa/AaReceiver.kt:128-145`) the built-in map does **not** flip at 19:00 by itself [I]. iOS: re-evaluate every 60 s.

### 10.4 iOS: tile source rules — no prefetch from the OSMF servers, the "© OpenStreetMap" credit

The dash map's raster tiles come from `BikeSettings.tileURLTemplate` (default
`https://tile.openstreetmap.org/{z}/{x}/{y}.png`, editable in Settings). `MapTileSource` (OpenCfMotoCore,
Linux-tested) reads the host of an http(s) template (the only schemes the downloader fetches) — the RFC 3986
authority (userinfo and port dropped, `{…}` placeholders lose their braces), plus Foundation's `URL.host`
when it differs — and calls it an **OSMF host** when it is `openstreetmap.org`, `osm.org` or any of their
subdomains (`tile.`, the legacy `a.` / `b.` / `c.tile.` …), whatever the case or a trailing dot. When in
doubt it picks the OSMF side.

* **No prefetch from the OSMF servers.** Their Tile Usage Policy forbids prefetching and offline or bulk
  downloads (Android never prefetches). The iOS route-corridor prefetch (§16 R3: zooms 14–17 within 250 m
  of a new route, at most 400 tiles) runs only for a tile server the rider configured:
  `MapTileSource.allowsCorridorPrefetch(template:)` is false for an OSMF host and for a template whose host
  cannot be read, so RideModel does not ask, `TileImageCache.prefetch` refuses (queues nothing, returns 0),
  and a corridor queued for another server is dropped — never fetched from the new one — when the template
  changes. Visible tiles load as before (2 downloads, 90-day cache, identifying User-Agent).
* **Credit on the dash map.** The OSMF tiles need a visible credit next to the map. RideModel sets
  `DashModel.mapAttribution` = `MapTileSource.attribution(template:)` ("© OpenStreetMap" for an OSMF host, nil
  for any other server: no label), and the scene draws it as a small plate — 11 sp medium `#E8EEF5` on 75 %
  `#1A2332` (legible on day and night tiles), padding 8 × 2 dp, radius 6 dp, ellipsised to 45 % of the safe
  width — in the **map layer** (after the tiles, route and puck, under every card, overlay and sheet; no hit
  region: touches on it reach the map).
  * Place (`DashLayout.mapAttribution`): the map's bottom-left corner, 8 dp from the safe area's left and
    bottom edges, raised to end 6 dp above every piece of chrome it would come within 6 dp of — the metrics
    card / bar, the preview, arrive and lap cards, the speed chip (and, for completeness, the pill, the nav
    card and the FAB lane with the music tile and the clock). It therefore sits just above the bottom-left
    stack: free ride landscape → the corner; navigating → above the metrics card (and the lap card); preview /
    arrival → above the card; portrait free ride → above the speed chip. It never touches a control, a card,
    the music tile, the speed chip or the clock on any supported canvas (DashLayoutInvariantTests,
    DashMapAttributionTests); with no room left under the top chrome it is not drawn (not reached on those
    canvases).
  * The opaque Music sheet hides the map and its credit; the menu dimmer, the search sheet and the hold
    picture draw over it like over the rest of the map. Toasts and the link banner are drawn over everything
    from the top chrome down: with one-line texts they stay clear of it in every map state on the supported
    canvases (DashMapAttributionTests); a long two-line toast may cover it while it shows (2.5 s).
* Pictures of the dash with real OSM tiles (README, social posts) also caption them "Map © OpenStreetMap
  contributors": the README strip and `docs/media/social-preview.png` use frames from the CI E2E run, with
  real tiles, and carry that caption. The snapshot images in `docs/screenshots/dash/` use placeholder tiles
  and show the credit where the dash draws it.

---

## 11. THE DASH UI

### 11.1 Canvas, density, layout selection [V]

* The map video canvas is the bike-negotiated capture size, rounded down to multiples of 16 (`w & 0xFFF0`, `h & 0xFFF0`, `BikeProfile.kt:105`): **800×384** landscape (CFDL16 asks 800×386) and **800×944** portrait (CFDL26 1000 MT-X asks 800×951) (`docs/01-REVERSE-ENGINEERING.md:15, 239-242`) [HW]. Other observed canvases: ~1280×576 (800MT), 720×712 (800NK Advanced), 544×512 (CL-C450), 1024×464 (Yunmo / Ride MO) (`BikeProfile.kt:588-597, 660-668, 751-761`, `YunmoLink.kt:632-637`). Default before negotiation 800×384 (`EasyConnProber.kt:88-89`).
* The UI renders into a private VirtualDisplay of exactly that size with density `dpi = clamp(round(160·W/900), 160, 640)` (Yunmo: fixed 187) (`VideoPipeline.kt:529-534, 783`). ⇒ **W = 800 → 160 dpi → 1 dp = 1 px**; W = 1024 → 182 (1.1375 px/dp); W = 1280 → 228 (1.425 px/dp). Text px = sp × density × system font scale (normally 1.0).
* Layout file: `res/layout-land/presentation_gpx.xml` when W > H, else `res/layout/presentation_gpx.xml`; then `adaptChromeLayout()` rewrites sizes/positions at runtime (`GpxDashUi.kt:2477-2771`). Insets (cutouts/system bars) are 0 on a VirtualDisplay. Smallest width ≥ 360 dp ⇒ `values-sw360dp` dimens apply (segment text 13 sp).
* System font (Roboto on stock Android; no custom fonts in the layouts). Text "bold" = Roboto Bold.
* Z-order (back → front, XML order): map · search pill · lap card · nav card (`gpx_hud`) · metrics card (`gpx_hud_bottom`) · speed chip · preview card · arrive card · FAB column · dimmer · search sheet · menu sheet (`res/layout-land/presentation_gpx.xml:10-1071`). `showMenu`/`showSearch` bring their sheet to the front.

### 11.2 Palette (ARGB hex; alpha first when 8 digits) [V]

| Token | Value | Used by |
| --- | --- | --- |
| Root/chrome background | `#101418` default; settings: Dark `#101418`, Black `#000000`, Slate `#1A2332`, Forest `#0E1A14` | behind the map (`MapPrefs.kt:13-18`, `GpxDashUi.kt:118`) |
| Card fill | `#F01A2332` (94 % `#1A2332`), radius 14 dp | nav card (land), metrics (land), preview, arrive (`bg_nav_card.xml`) |
| Top banner fill | `#FF1A2332`, bottom corners 14 dp only | portrait nav banner (`bg_nav_top_edge.xml`) |
| Bottom bar fill | `#F01A2332`, top corners 14 dp only | portrait metrics, lap card (`bg_nav_bottom_edge.xml`) |
| Primary text | `#FFFFFF` | distances, values, titles |
| Road-name text | `#8AB4F8` | cue line |
| Lane arrows | `#FFB74D` | lane line |
| Metric labels | `#889098` | TIME/ARRIVE/LEFT/ALT |
| Secondary text | `#B0B8C0` | preview meta, arrive meta, gauge unit, Cancel/Done |
| Status text | `#C8D0D8` normal / `#FF8A80` off-route > 80 m | status line; also unselected route chip text, lap meta |
| End pill | fill `#33FF5A52`, stroke 1 dp `#55FF5A52`, radius 12 dp, text `#FF8A80` | `bg_end_pill.xml` |
| Blue action | `#1A73E8`, radius 24 dp | Go, Park here (`bg_go_button.xml`); also route remain line, search action chips text |
| Route chip | fill `#22FFFFFF`, stroke 1 dp `#33FFFFFF`, radius 18 dp | unselected chip, Find parking (`bg_route_chip.xml`) |
| Route chip selected | fill `#1A73E8`, stroke 1 dp `#8AB4F8`, radius 18 dp | (`bg_route_chip_sel.xml`) |
| FAB | oval fill `#F01E2430`, stroke 1 dp `#33FFFFFF`; icon `#FFFFFF` | (`bg_fab_circle.xml`) |
| Speed gauge | oval fill `#F01A2332`, stroke 3 dp `#66FFFFFF` | (`bg_speed_gauge.xml`) |
| Speed-limit sign | red disc `#E53935`, white inner disc inset 5 dp (40-dp variant: 4 dp), number `#111111` | (`bg_speed_limit_sign*.xml`) |
| Search pill | `#F2FFFFFF`, radius 28 dp; text `#3C4043`; icon tint `#5F6368`; Circuit/Lap `#E65100` | (`bg_search_pill.xml`) |
| Search sheet | bg `#F8FFFFFF`; input `#202124`, hint `#80868B`; status `#5F6368`; rows `#FFFFFF`; name `#202124`; sub `#5F6368`; actions `#1A73E8`; Delete `#D93025`; divider `#DADCE0` | |
| POI chip | fill `#F1F3F4`, stroke 1 dp `#DADCE0`, radius 18 dp, text `#3C4043` | (`bg_chip_pill.xml`) |
| Dimmer | `#66000000` | |
| Menu sheet | `#F0141A20` | |
| Segments | selected `#FF6A2C` / text `#FFFFFF`; unselected `#1F242E` / text `#F2F5FA`; radius 12 dp; min height 44 dp | (`colors.xml`, `themes.xml:80-89`, `GpxDashUi.kt:466-477`) |
| Preview action text | Save `#90CAF9`, Home `#FFD54F`, Marker `#A5D6A7`, Circuit `#FFB74D`, Cancel/Done `#B0B8C0` | |
| Handlebar focus ring | fill `#66FF9800`, stroke 5 dp `#FF9800`, radius 12 dp (drawn over the focused control) | `GpxDashUi.kt:1925-1956` |
| Route lines (bike) | remain `#1A73E8` 7 dp; done `#9AA0A6` 5.5 dp α 200/255; preview `#34A853` 6.5 dp α 220; alternatives `#9AA0A6` 5 dp α 160 (≤ 4, under the preview); to-destination `#FBBC04` 3.5 dp dashed 8 dp on / 6 dp off; all round caps/joins, anti-aliased | `DashMapController.kt:57-95, 175-199` |
| Pins (bike) | destination `ic_dest_pin` 36×44 dp, anchor bottom-centre; other pins same icon 28×34 dp; puck `ic_nav_arrow` 48×48 dp centred, rotated by bearing | `DashMapController.kt:97-102, 241-282` |

Map overlay z-order (bike): tiles < done < alternatives < preview < remain < to-dest line < pins < puck < destination pin (`DashMapController.kt:114-130, 259-282`). Pins are not styled by category on the bike (all red teardrops); the phone draws pins as `#FFCA28` circles r 6 with 1.2 black stroke (`MapLibreDashController.kt:463-470`).

### 11.3 Geometry — landscape bike canvas 800×384 [V layout rules][I pixel maths][HW appearance]

All values px at 1 dp = 1 px, font scale 1.0, insets 0. Rules from `adaptChromeLayout` land
branch with `projected = true` (`GpxDashUi.kt:2529-2657`): `edge = 8`, `fabLane = 88`.

| Element | Position rule | Size / content | Notes |
| --- | --- | --- | --- |
| Search pill (idle & preview) | top-left: x = 12, y = 8 | h 48; w = wrap ≈ 4 + 20 (search icon, 8 gap) + 300 (text field) + "Circuit" label + "Lap" label + 14 ≈ **453** [I] | Back-arrow "←" (44×44, 22 sp) and "Hub" are hidden on the bike (`:1231-1237`). Text `"Search here"` or the previewed place's name, 16 sp `#3C4043`, 1 line ellipsised. Labels: "Circuit"/"Lap"(/"Stop") 14 sp bold `#E65100`, h 36, padding-x 8 (`layout-land:16-90`). |
| Nav card (navigating) | top-left: x = 8, y = 8; right margin 88 (max right x = 712) | padding L18 T14 R22 B14; row = maneuver icon 64×64 + 14 gap + text column; width = wrap (≤ 18+64+14+≈528+22 ≈ **646**); height ≈ 92 (1-line road) – 107 (2 lines) [I] | Column: distance 30 sp bold `#FFFFFF`; road/instruction 18 sp bold `#8AB4F8`, max 2 lines, ellipsised, top margin 2 — the code sets `maxWidth = 420` and then `maxEms = 24`; both write the same TextView field, so the **last call wins**: max width = 24 × line height ≈ 24 × 22 ≈ 528 px [I]; lanes 16 sp bold `#FFB74D`, letter-spacing 0.12 em, top margin 4, hidden unless lanes. Font padding disabled. Vertical centring. |
| Metrics card (navigating) | bottom-left: x = 8, bottom = 376; right margin 88 | padding L22 T14 R22 B14; one row; height ≈ 82 [I] | Columns (each centred, label 13 sp `#889098`, value top margin 4, bold `#FFFFFF`): **TIME** (value 26 sp, min width 80, gap 20), **ARRIVE** (26 sp, min 80, gap 20), **LEFT** (30 sp, min 90, gap 20), **ALT m/ALT ft** (26 sp, min 80, gap 24), then **End** button: margin-left 8, padding-x 22, min height 48, `"End"` 17 sp bold `#FF8A80` on the End pill. Status line hidden in landscape. |
| Speed chip | bottom-right of the free area: right edge x = 712 (800 − 88), bottom = 376 | horizontal: gauge **84×84** + (12 gap + limit sign **56×56**, vertically centred, only when a limit is known) ⇒ gauge x = 628 (no limit) or 560 (with limit); limit x = 656 | Gauge: speed 32 sp bold `#FFFFFF` over unit 11 sp bold `#B0B8C0` (`km/h`/`mph`), centred; "—" until the first fix. Limit number 20 sp bold `#111111`. Always visible (also in free ride and preview). [HW] |
| FAB column | top-right: right margin 6 (x = 748..794), y = 8 | 5 circles **46×46**, gap 6: y = 8, 60, 112, 164, 216 (bottom 262); icon 24×24 (padding 11) | Order: **Recenter** (`ic_fab_gps`), **Zoom in** (`ic_fab_plus`), **Zoom out** (`ic_fab_minus`), **Compass** (`ic_fab_compass`, rotated by −mapBearing in heading-up, alpha 0.55 north-up), **Menu** (`ic_fab_menu`). "Fit route" and "Mute" FABs exist but are hidden (`layout-land:770-791`). [HW] |
| Preview card | bottom-left: x = 10, bottom = 374; right margin 96 | padding 16×12; row 1: name 17 sp bold white (max w 280, 1 line) / meta 13 sp `#B0B8C0` (max w 280, 1 line, top 2) + **Go** (h 44, margin-left 16, min w 110, padding-x 20, 16 sp bold white on `#1A73E8` r24); row 2 (top 8): route chips (horizontal scroll); row 3 (top 8, h 40): text actions 14 sp bold, padding-x 12: ★ Save · [Home] · [＋ Marker] · Circuit · Cancel/Done | [HW] (`layout-land:475-629`) |
| Arrive card | bottom-left: x = 10, bottom = 374; right margin 76 | padding 16×12; title 17 sp bold; meta 13 sp `#B0B8C0`; buttons (top 10, h 44): **Park here** (min w 120, blue), **Find parking** (min w 120, route-chip style, margin 8), **Done** (transparent, `#B0B8C0`) | (`layout-land:631-702`) |
| Lap card | bottom-left: x = 12, bottom = 296 (margin 88) | padding 14×8; line 1 22 sp bold white; line 2 13 sp `#C8D0D8`, top 2; bottom-edge card shape | visible only while the lap timer is armed |
| Dimmer | full canvas | `#66000000`, tap → close sheets | only with the menu |
| Search sheet | full canvas | header h 64 (padding-x 10): "←" 44×44 24 sp `#3C4043` + pill (h 48, weight 1, margin-left 4, padding L14 R6): input 17 sp + search icon 40×40 (padding 9, tint `#5F6368`); chips row (padding 10×8); status (padding-x 16, bottom 4, 13 sp, max 2 lines); scrollable results (bottom padding 24) | (`layout-land:805-909`) |
| Menu sheet | right side: x = 520, w 280, full height, scrollable | padding 12; content §11.8 | (`layout-land:912-1071`) |

Overlap note [I]: the metrics card is wrap-content (≈ 600 px with "123.4 km") while the speed
chip with a limit sign starts at x = 560 — they can overlap; the gauge (later in z-order) wins.
The computed-but-unused `speedBottom = 88` (`GpxDashUi.kt:2536-2541`) suggests the gauge was once
meant to sit above the card. iOS should lay out deterministically (e.g. clamp the metrics card to
end before the chip).

Phone-landscape (not projected) differences: metric values 32 sp, LEFT 38 sp, road 22 sp,
distance 36 sp, column gap 32 / min widths 100 (LEFT 110), FAB right margin 12, gauge 88×88 with
36 sp / 12 sp and limit 22 sp (`GpxDashUi.kt:2531-2535, 2592-2593, 2629-2638`).

### 11.4 Geometry — portrait bike canvas 800×944 [V rules][I pixels] (not hardware-photographed)

Rules from the portrait branch (`GpxDashUi.kt:2658-2766`) and `res/layout/presentation_gpx.xml`.

| Element | Position | Size / content |
| --- | --- | --- |
| Search pill | x = 12, y = 8 | as landscape |
| Nav banner | full width at the top (x 0..800, y 0) | top-edge shape; padding L16 T10 R16 B12; content centred horizontally; icon 64×64 + 14 + column: distance **32 sp** bold, road **20 sp** bold `#8AB4F8` (2 lines; `maxEms = 20` set last ⇒ max width ≈ 20 × line height ≈ 470 px [I]), lanes **18 sp** bold `#FFB74D` (top 2, letter-spacing 0.12); font padding left on (XML default); height ≈ 92–120 [I] (code assumes ~100) |
| Metrics bar | full width at the bottom (bottom = 944) | bottom-edge shape; padding L12 T10 R12 B10; row 1: 4 weighted columns TIME (1), ARRIVE (1), LEFT (1.2), ALT (1) over 776 px ⇒ 184.8 / 184.8 / 221.7 / 184.8 px [I]; labels 11 sp `#889098`; values 22 sp (LEFT 24 sp) bold white, 1 line, ellipsised; row 2 (top 6): status text (weight 1, 13 sp `#C8D0D8`, 1 line) + **End** (h 40, margin-left 8, padding-x 16, 15 sp bold `#FF8A80`); height ≈ 107 [I] |
| Speed chip — navigating | top-right: right edge 792, y = 100 | gauge **96×96** (speed 36 sp, unit 12 sp) + optional limit 56×56 (20 sp) ⇒ x = 628 (with limit) / 696 |
| Speed chip — not navigating | bottom-left: x = 12, bottom = 932 | same |
| FAB column | right edge 792 (margin 8), vertically centred | 254 px tall ⇒ y = 345..599 |
| Preview card | x 10..790, bottom 934 | name 17 sp, meta 13 sp, chips row, actions row: ★ Save · [Home] · [＋ Marker] · Circuit · ⟨spacer⟩ · Cancel/Done · **Go** (h 44, min w 110, margin-left 4) |
| Arrive card | x 10..790, bottom 934 | title 18 sp; meta 13 sp; row (top 12): Park here + Find parking (equal weights, min h 48, gap 8); full-width **"Done · free ride"** (h 44, top 8) |
| Lap card | x = 12, bottom = 856 | as landscape (may overlap the metrics bar top [I]) |
| Menu / search / dimmer | as landscape (menu x = 520) | |

### 11.5 Icons — vector paths for CoreGraphics [V]

All `ic_man_*` are 24×24 viewport, nominal 40 dp, drawn into the 64×64 icon slot with
aspect-fit (scale 64/24 = 2.667), fill/stroke `#FFFFFF` (`res/drawable/ic_man_*.xml`).
Android `rotation` is clockwise about (12,12) in a y-down space — identical sign to a UIKit
(y-down) `CGAffineTransform(rotationAngle:)`.

**Base arrow** (filled): `M12,3 L19,12 L14,12 L14,21 L10,21 L10,12 L5,12 Z` (head triangle
(5,12)-(12,3)-(19,12), shaft x 10..14, y 12..21). Rotations: straight 0°, slight_right +45°,
right +90°, sharp_right +135°, slight_left −45°, left −90°, sharp_left −135°.

| Icon | Geometry |
| --- | --- |
| `ic_man_uturn` | stroke 2.4, round caps/joins: `M8,20 L8,11 A4,4 0 0 1 16,11 L16,15` (up the left leg, clockwise arc over the top centred (12,11) r 4, down the right leg); filled head `M12.5,14 L19.5,14 L16,19 Z` (points down) |
| `ic_man_roundabout` | stroke 2.2 round caps: stem `M12,21 L12,15`; circle centre (12,15) r 4; exit stem `M16,11 L16,4`; filled head `M13,6 L16,2 L19,6 Z` |
| `ic_man_merge` | stroke 2.2 round caps/joins: `M7,21 L7,14 Q7,11 10,10 L13,8.5` and `M13,8.5 L13,21`; filled head `M9.5,10.5 L13,5 L16.5,10.5 Z`. Same icon for left and right merges. |
| `ic_man_fork` | stroke 2.2 round caps/joins: `M12,21 L12,13`, `M12,13 L7,8`, `M12,13 L17,8`; filled heads `M4.5,9.5 L7,4 L9.5,9.5 Z` and `M14.5,9.5 L17,4 L19.5,9.5 Z`. Same icon for both sides. |
| `ic_man_arrive` | map pin, filled, with a hole (use even-odd): `M12,2 C8.13,2 5,5.13 5,9 C5,14.25 12,22 12,22 C12,22 19,14.25 19,9 C19,5.13 15.87,2 12,2 Z` + circle centre (12,9) r 2.5 |

FAB icons (24×24 viewport, white, Material-style; exact path data in `res/drawable/ic_fab_*.xml:9`):
`ic_fab_gps` (my-location crosshair: filled centre disc r 4, ring between r ≈ 7 and ≈ 9, 2-wide
ticks reaching the 1..23 edges), `ic_fab_plus` `M19,13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z`,
`ic_fab_minus` `M19,13H5v-2h14v2z`, `ic_fab_compass` (disc r 10 centred (12,12) with a
parallelogram needle cut out `M14.14,14.14L9,15l0.86,-5.14L15,9l-0.86,5.14z` — opposite winding,
so fill even-odd), `ic_fab_menu` (three dots r 2 at (12,6), (12,12), (12,18)); hidden FABs use
`ic_fab_fit` and `ic_fab_voice`; `ic_search` = Material magnifier (`res/drawable/ic_search.xml:8-9`).

Puck `ic_nav_arrow` (48×48 viewport): shadow disc centre (24,24) r 15 `#66000000`; blue chevron
`M24,6 L38,36 L24,30 L10,36 Z` `#1A73E8`; white inner chevron `M24,10 L33,32 L24,27.5 L15,32 Z`
(the result reads as a white arrow with a blue rim) (`ic_nav_arrow.xml`).
Destination pin `ic_dest_pin` (40×48 viewport): teardrop
`M20,0C11.16,0 4,7.16 4,16c0,12 16,32 16,32s16,-20 16,-32C36,7.16 28.84,0 20,0z` `#E53935` + white
circle centre (20,16) r 6; anchor = bottom centre (20,48).

### 11.6 UI state machine & visibility [V] (`GpxDashUi.kt:442-465, 553-609`)

State variables: `liveMode`, `inPreview`, `pinSetupOnly`, `follow`, `headingUp`, `speedZoom`,
`pendingPlace`, `pendingRoutes`, `selectedRouteIdx`, `voiceOn`, sheet visibilities.
`navigating = !inPreview && liveMode != FREE_RIDE` (GPX counts as navigating).

| Element | Free ride | Preview / pin setup | Navigating (GPX or NAV_TO) |
| --- | --- | --- | --- |
| Search pill | visible (`"Search here"`) | visible (text = place name) | hidden |
| Nav card + metrics | hidden | hidden | visible |
| Preview card | hidden | visible | hidden |
| Arrive card | after an arrival only | hidden | hidden |
| Speed chip | visible | visible | visible |
| FAB column | visible unless a sheet is open | same | same |

While navigating, if the maneuver row is hidden or empty, it is seeded with the arrive icon,
distance `"GPS"` and text `"To <destination | trackName>"` so the top bar is never empty (`:455-462`).
`showMenu`: hide search + FABs, show dimmer + menu. `showSearch`: hide menu, FABs and dimmer, show
the full-screen sheet with the idle list. `hideSheets`: hide menu, search and dimmer, show FABs,
hide the keyboard. Long-press / previews also hide sheets.

### 11.7 HUD content rules per GPS fix [V] (`applyProgress`, `GpxDashUi.kt:2144-2260`)

* Hidden `w_speed` = formatted speed (the visible speed is the gauge, set earlier per fix).
* **Route present**: done/remaining lines repainted; TIME = `formatEta(etaSec)`, ARRIVE = `formatArrival(etaSec)`, LEFT = `formatDistance(remainM)`, ALT = `formatAltitude(progress alt ?: GPS alt)` or `"—"`. Cue card:
  * off route (> 40 m) → join-route arrow / distance / word (§4.4);
  * upcoming turn → icon `iconResFor(dir)`, distance `formatDistance(distanceFromRiderM)`, text `roadName ?: maneuverWord(dir)`, lane line if any; voice `onProgress`;
  * no turn ahead → arrive icon, distance `formatDistance(remainM)`, text `"To <dest | trackName>"`; voice `onProgress` (waypoints).
* **NAV_TO, no route yet**: straight-line distance `dM` and `etaSeconds(dM, speed)` for TIME/ARRIVE/LEFT; dashed yellow me→dest line; cue = `dirToFace(bestBearing, bearing(me→dest))` icon, distance `dM`, text `"Go ahead"` for STRAIGHT/CONTINUE else `joinRouteWord`; join voice when `dM > 40`.
* **No route, no destination** (free ride): TIME/LEFT/ARRIVE `"—"`, ALT from GPS, cue hidden.
* Initial texts at bind: status `"GPS… · free ride"` / `"GPS… · navigate to <name>"` / `"GPS… · <total> track"`; LEFT = total track length or `"—"`; title (hidden) `"Free ride"` / `"→ <dest>"` / `"<track> · <km> · ↑<ascent>"` (`:174-189, 1089-1103`).

### 11.8 Behaviours — every tap target [V]

**Map**
* Drag: pan (single pointer). Follow stays on, so the next fix re-centres (§4.9). Double-tap zoom is osmdroid's default [I].
* **Long-press** → drop pin: `MapPlace("Dropped pin", lat, lon, "pin", "%.5f, %.5f")`, speak `"Pin dropped"`, open the pin-setup sheet (`:1906-1917`).

**Search pill**: body → search sheet; `Circuit` → `startCircuit()`; `Lap`/`Stop` → toggle lap timer; `←` (phone only) → close the map screen; `Hub` hidden.

**FABs** (`:1245-1330`)
* **Recenter**: `follow = true`, cancel auto-recenter; with a fix: bearing = heading-up ? `bestBearing()` : 0, follow at `followZoom(speed)`, status `"Centered on GPS"`; else `"No GPS yet — wait for a fix"`. Does not reset `speedZoom`.
* **Zoom in / out**: `bumpFreePan()`, `speedZoom = false`, zoom ±1 (bike clamps 5..20, instant; phone eases 180 ms).
* **Compass**: toggle heading-up ⇄ north-up. North-up → reset bearing 0; heading-up → adopt `bestBearing()` immediately and follow. Status `"Heading up"` / `"North up"`.
* **Menu**: open the menu sheet.
* (hidden) **Fit route**: free pan, north-up, fit the remaining route (pad 72 px) with status `"Route overview · north up"`, or centre on destination/rider at z14 `"Overview · north up"`. (hidden) **Mute**: toggle voice.

**Preview card** (`:1376-1411, 699-862`)
* Opened by a search/POI/idle-list row tap or menu **Go Home** → `previewPlace(place)`: `follow = speedZoom = headingUp = false`, destination pin, north-up; meta `subtitle` or `"Getting route…"` (+ `"No mobile data pin — enable cellular for road routes"` if no internet pin). Without a fix: meta `"<subtitle> · Waiting for GPS to route"`, centre on place z16. With a fix: dashed me→dest line, fit both points, request alternatives (§6.1). On result: `selectRoute(0)`; append `avoidHonored`/`warning` text (default `"Avoid setting not applied"`) to meta and status. On error: dashed line, centre z15, meta `"No road route · straight line"`. Stale results (another place or pin mode) are ignored.
* `selectRoute(i)`: clamp index, `pendingRoute = routes[i]`, preview line = selected (green), others grey; fit all routes plus the me/dest pair (pad 160 px, re-applied after 350 ms); meta `"[Straight line (no road route) · ]<distance> · <HH:mm arrival>[ · <subtitle>]"`; chips rebuilt: text `"[★ ]<label> · <HH:mm> · <distance>"` (label blank → `"Fast"` for index 0 else `"Alt"`), 13 sp bold, white (selected) / `#C8D0D8`, selected/unselected chip shapes, padding 28×14 px, gap 16 px; tapping a chip selects it. Focus → Go.
* **Go**: `startNavigationTo(place)` — push history, `GpxSession.prepareNavTo`, NAV_TO, reset arrival state and engage time, `follow = speedZoom = headingUp = true`, close sheets; reuse the selected preview route if it has ≥ 2 points (no new request) else request a route (`"GPS… · navigate to <name>"` and centre z16 without a fix); speak `"Navigating to <name>"`; focus → End.
* **★ Save** → favorite (+ `"Saved"`); **Home** / **＋ Marker** (pin mode only) → set home (renaming `"Dropped pin"` to `"Home"`) / add marker; in pin mode these also close the sheet. **Circuit** → `startCircuit()`. **Cancel** (trip) / **Done** (pin) → `cancelPreview()` (restore the live destination pin and chrome). Note [V]: `cancelPreview` does **not** restore `follow`, `headingUp` or `speedZoom` (set false by the preview, `:626-638`), so after Cancel/Done the camera stays on the north-up overview — even when a navigation is running underneath — until the rider taps **Recenter** or toggles **Follow**.
* `startCircuit()` (`:1729-1793`): needs a fix (`"Need GPS for a circuit"`) and a previewed place (`"Pick a destination, then Circuit (there & back)"`); place within 120 m → `"Pick a place away from you, then Circuit"`; else preview meta `"There & back · returning home"`, request the circuit (§6.1), select route 0 and append `"There & back · returns home"`; speak `"Building there and back circuit"`. A hub-started circuit (`pendingCircuit`) fires 600 ms after bind and, having no previewed place, only shows the "Pick a destination" message (`:1847-1854`).

**Arrive card** (`:1412-1439`): **Park here** → parked pin at the fix (`"Parked"`, category `parking`, subtitle `"Marked on arrival"`), `"Parking marked"`; **Find parking** → open search and run the Parking POI chip; **Done** → hide (`"Free ride"`).

**Metrics card End** / menu **End navigation** → `endRouteNow()`: in preview → cancel preview; in free ride → `"Already free ride"`; else finish (`"Navigation finished"`), focus default (`:1484-1501`).

**Menu sheet** (order as rendered; `layout-land:912-1071`, handlers `GpxDashUi.kt:1442-1728`)
* Title **Ride** (15 sp bold): **End navigation**; **Park here** (fix required — toggles: an existing parked pin < 40 m away is cleared `"Parked spot cleared"`/`"Parking cleared"`, otherwise set/replaced with subtitle `"Marked on dash"`, `"Parking marked"`/`"Parking updated"`); **Go Home** (preview home or `"No Home set — long-press map or use Set Home"`); **Set Home here** (`MapPlace("Home", …, "home", "Set on dash")`, `"Home set here"`/`"Home set"`); **Recenter / Recalc** (follow on; reload units/next-stop/auto-finish/3D/chrome; re-apply theme; NAV_TO → reroute `"recalc"`; GPX → centre on the first remaining point at z15, `"Snap · back on track"`/`"Back on track"`; free ride → centre, `"Recentered"`/`"Centered"`; no fix `"No GPS"`); **Record ride** / **Stop recording** (manual trip recorder toggle, `"Recording ride…"`, `"Can't record — check GPS / permission"`, `"Ride recording saved"`); **Circuit**.
* Title **Map**: **Follow on** / **Free pan** (toggle, cancels auto-recenter); **Heading up** / **North up**; **Voice on** / **Voice muted**; row **－** | **＋** (U+FF0D / U+FF0B, 18 sp) zoom.
* **Settings** (segmented rows, label 13 sp bold white, rows top margin 12, segment gap 8): Units (Metric | Imperial), Theme (Auto | Day | Night), Voice (On | Off), Next stop (On | Off), Auto-finish (On | Off), Chrome (Dark | Black | Slate | Forest), 3D (On | Off), Route mode (Fast | Fun), Avoid tolls (On | Off), Avoid highways (On | Off), "Legacy scenic length (unused — Circuit is there and back)" (30 | 60 | 100 — stored, bucketed `≤45→30, ≤80→60, else 100`, **unused** [X]). Each tap persists immediately; route mode / avoid changes re-run the preview if a place is pending (`:1687-1716`).
* **Close**.
* Buttons are plain `<Button>`s (min height 48, no all-caps); on the phone they inflate as Material3 filled buttons (brand orange `#FF6A2C`, white text); on the bike Presentation (no AppCompat inflater) platform styling may apply [I]. Free choice on iOS.

**Lap timer** (`:1797-1846`): pill **Lap** arms at the current fix (`"Lap: ride out, then pass start/finish"`, `"Lap timer armed"`), adds an `"S/F"` pin (category `lap`), repaints the lap card every 100 ms; **Stop** disarms (`"Lap timer off"`). Card line 1: `"Pass start/finish"` until the clock starts, then `"LAP <n>  <m:ss.cc>"`; line 2 `"LAST <m:ss.cc|—>   BEST <m:ss.cc|—>"`. See §13.

### 11.9 Handlebar focus navigation (bike only) [V] (`GpxDashUi.kt:1921-2136`)

Installed only when projected. Keys arrive from AVRCP handlebar gestures already mapped to
abstract actions (`MediaButtonBridge.kt:728-771`; the map sink wins over Android Auto). Keycodes
(`aa/AaInput.kt:33-51`): UP 19, DOWN 20, LEFT 21, RIGHT 22, ENTER 23, BACK 4, HOME 3, ASSISTANT 84;
knob = `scroll(±1)`.

| Input | Action |
| --- | --- |
| ENTER (Select) | `ensureFocus()`; click the focused control |
| BACK | close arrive card → else cancel preview → else close search/menu; then focus the default |
| HOME (Select-hold by default) | toggle menu |
| ASSISTANT | toggle search sheet |
| LEFT / UP, knob −1 | focus previous (wraps) |
| RIGHT / DOWN, knob +1 | focus next (wraps) |

Focus lists (only visible, enabled, clickable/focusable views): arrive card → [Park here, Find
parking, Done]; preview → [Go, Circuit, Cancel/Done, Save, Home, Marker, route chips…]; search →
[POI chips…, result rows…, search button, back]; menu → [End navigation, Park here, Go Home, Set
Home here, Recenter/Recalc, Record, Circuit, Follow, Heading, Voice, －, ＋, Close]; otherwise →
[End (if navigating), search pill + Circuit label (if pill visible), Recenter, (Fit), Zoom in,
Zoom out, (Mute), Compass, Menu] — the **Lap** pill label is not in any focus list, so the lap
timer cannot be reached from the handlebar [V]. Preferences: `"go"` focuses Go, `"end"` focuses End,
`"default"` keeps the current focus if still listed else index 0. Default preference = `"go"` with
a preview, `"end"` while navigating, else `"default"`. Focus is never scaled; the ring (§11.2) is
drawn on top; the focused row is scrolled into view.

### 11.10 Touch input routing [V]

Bike touch frames (PXC media cmdType 32, little-endian `action u16 @0 (2 DOWN, 3 MOVE, 1 UP)`,
`x u16 @2`, `y u16 @4`, `pointerId u16 @6`, canvas pixel coordinates — `EasyConnProber.kt:827-847`)
pass ghost/stitch filtering (ghost merge 48 px, UP held 80 ms for re-acquisition within 150 px,
stale pointer 300 ms, max 2 pointers — `EasyConnProber.kt:51-66`) and are then delivered to the
map UI as **single-pointer** `MotionEvent`s (0 DOWN, 1 UP, 2 MOVE at canvas x/y) on the root view
(`GpxSession.kt:114-134`, `EasyConnProber.kt:922-929`). No pinch zoom on the dash. Long-press /
tap timing is Android's default gesture detection [I: ~400–500 ms long-press, ~8 dp slop].

### 11.11 Status / feedback strings

`statusView` messages (e.g. `"Routing…"`, `"Saved <name> to favorites"`, `"Marker added"`,
`"Save this pin — open it later to navigate"`) are only visible inside the **portrait** metrics bar
while navigating; in landscape the status line is hidden and in free ride the bar is hidden, so
most feedback is invisible on the dash [V] (`GpxDashUi.kt:2612, 2724`). iOS should add a transient toast.

### 11.12 Hardware observations [HW] (demo footage, landscape dashes)

Search pill top-left with orange "Circuit"; 5-button FAB column top-right; dark round speed gauge
with an EU-style "50" limit sign to its right, bottom-right next to the FAB lane; preview card
bottom-left showing `Câmpina`, meta `10.2 km · 14:14 · city · Prahova, România`, blue Go pill,
chips `★ Fast · 14:14 · 10.2 km` (selected, blue) and `Fun · 14:20 · 25.4 km`, actions
`★ Save · Circuit · Cancel`; green selected route + grey alternative; white full-screen search
sheet with POI chips; OSM Mapnik raster tiles (`docs/media/map-demo-1.gif`, `map-demo-2.gif`).

### 11.13 Video-path facts that matter to the map [V][HW]

* The bike drops the media connection if no frame arrives for ~9 s (`socketTimeoutPeriodWifi = 9`, `docs/01-REVERSE-ENGINEERING.md:19-20`) [HW]. Android's encoder repeats the last frame after 0.9 s of no new input (`VideoPipeline.kt:204, 792`).
* Map boost: when the map session is active and the profile frame rate ≥ 30, bitrate × **1.35** and keyframe interval `max(1, iframeSec/2)` (`VideoPipeline.kt:171-180`).
* When switching the live bike video to the map: flush the queue + request an IDR immediately, and again **200 ms** later "after the Presentation has painted" (`EasyConnProber.kt:286-292`); each served keyframe is prefixed with SPS/PPS (`VideoPipeline.kt:559-571`).
* The phone preview (MapLibre) is never encoded; only the osmdroid bike rendering is.

---

## 12. Saved places, favorites, home, parked [V]

### 12.1 `MapPlaces` storage (`MapPlaces.kt`)

SharedPreferences file `opencfmoto_map_places`, each key holds a JSON **array string** of
`{"name":…, "lat":…, "lon":…, "category":…, "subtitle":…}`:

| Key | Content | Cap | Order |
| --- | --- | --- | --- |
| `favorites` | favorites | 100 | newest first |
| `markers` | map markers | 50 | newest first |
| `history` | recent places/tracks | 30 (`MAX_HISTORY`) | newest first |
| `parked` | 0 or 1 parked pin | 1 | — |
| `home` | 0 or 1 home | 1 | — |

Identity ("same place"): `|Δlat| < 1e-5 && |Δlon| < 1e-5` (≈ 1.1 m); names are ignored
(`:144-145`). `add*`/`pushHistory` insert at the front after removing the same place. Every write
bumps the in-memory `revision` counter, which open dash UIs poll to refresh pins/lists live
(`:30-33, 185`). Invalid JSON loads as an empty list.

Rules: `setParked(p)` removes the previous parked pin's marker + history entry, stores
`p.copy(category="parking", name=p.name.ifBlank{"Parked"})`, adds it as a marker and pushes a
history copy with subtitle `"Parked here"` (`:45-55`). `clearParked` removes marker/history (or,
if none, purges all history rows with category `parking`) and empties `parked` (`:57-68`).
`setHome(p)` stores `p.copy(category="home", name=p.name.ifBlank{"Home"}, subtitle="Home")` and also
adds it to favorites, markers and history (`:76-82`). `deletePlace` clears parked/home if it matches
and removes it from markers, favorites, history (`:132-142`).

Categories in use: `home`, `parking`, `pin` (dropped pin), `gpx` (track history), `mode`
(free-ride history at (0,0)), `wpt` (GPX waypoint overlay), `lap` (S/F gate overlay), router/search
types (`city`, `fuel`, …), POI chip labels (`Fuel`, …).

Pins drawn on the map (`collectPins`, `GpxDashUi.kt:190-209`): home, parked, markers, favorites,
GPX waypoints (`name ?: "Waypoint"`, category `wpt`), session overlays (except category
`home`/`pin` and anything named/subtitled "Parked"), lap gate `"S/F"`; distinct by
`"%.5f,%.5f|<name>"`. The destination is drawn separately (bigger pin). Places at exactly (0,0) are never drawn.

### 12.2 Map data backup (`MapDataBackup.kt`) — exchange format

```json
{
  "format": "opencfmoto.map",
  "version": 1,
  "exportedAt": "2026-10-31T14:05:00+02:00",
  "appVersion": "2.0.18",
  "prefs": {"units": "METRIC", "voicePrompts": true, "showNextStop": true, "autoFinishArrive": true,
            "chrome": "DARK", "buildings3d": true, "mapTheme": "AUTO", "routeMode": "FAST",
            "avoidTolls": false, "avoidHighways": false, "funCircuitKm": 60},
  "favorites": [ {"name": "...", "lat": 0, "lon": 0, "category": "...", "subtitle": "..."} ],
  "markers": [ ... ], "history": [ ... ],
  "parked": { ... },            // optional
  "home": { ... }               // optional
}
```
Pretty-printed with 2-space indent; `exportedAt` = `yyyy-MM-dd'T'HH:mm:ssXXX` (US locale);
file name `OpenCfMoto-map-yyyyMMdd.json` (`:23-50, 103-104, 141-142`). Import: strip a UTF-8 BOM,
`format` must match (`"Not an OpenCfMoto map file"`), `1 ≤ version ≤ 1`
(`"Unsupported map backup version <v>"`); prefs applied key-by-key when present; places replaced
wholesale with caps 100/50/30 (`:52-101`, `MapPlaces.kt:89-102`). Messages `"Map data imported"`,
`"Not valid JSON: …"`, `"Import failed: …"`.

### 12.3 Map preferences (`MapPrefs.kt`, prefs file `opencfmoto_map`) [V]

| Key | Type / default |
| --- | --- |
| `units` | `METRIC`/`IMPERIAL`, default METRIC |
| `voice_prompts` | bool, true |
| `show_next_stop` | bool, true |
| `auto_finish_arrive` | bool, true |
| `chrome` | `DARK`/`BLACK`/`SLATE`/`FOREST`, DARK |
| `buildings_3d` | bool, true |
| `ors_api_key` | string, "" (trimmed) |
| `route_mode` | `FAST`/`FUN`, FAST |
| `avoid_tolls` | bool, false |
| `avoid_highways` | bool, false |
| `fun_circuit_km` | int 20..150, default 60 (legacy, unused) |
| (prefs `opencfmoto_bike`) `map_theme` | `AUTO`/`DAY`/`NIGHT`, AUTO |

### 12.4 Handlebar saved-place slots (`SavedPlaces.kt`) [V]

Prefs `saved_places`, keys `name0..name2` and `query0..query2` (trimmed strings); a slot is set
when its query is non-blank; picker label `"Navigate: <name | query>"` or
`"Navigate to saved place <n> (not set yet)"`. On Android the NAV_1..3 handlebar actions launch
**Google Maps** (`https://www.google.com/maps/dir/?api=1&destination=<enc>&travelmode=driving&dir_action=navigate`,
then `google.navigation:q=<enc>&mode=d`, `geo:0,0?q=<enc>`, `google.navigation:q=<enc>`) for
Android Auto (`NavLauncher.kt:37-62`); lat/lon variant uses `"%.6f,%.6f"` (US locale)
(`:68-95`). This is an AA-only path [V]; on iOS the equivalent is to geocode the query (§7) and
start **our own** navigation.

---

## 13. Lap timer (summary) [V] (`LapTimer.kt`, `LapTimerTest.kt`)

Flying start/finish gate at the armed position. Constants: `CROSS_M = 25`, `EXIT_M = 55`,
`MIN_LAP_MS = 15 000`. Per fix: `d = haversine(fix, gate)`; `d > 55` → `away = true`; else if
`away && d ≤ 25` and `≥ 15 s` since the last crossing → crossing: the first crossing starts the
clock (lap 1); later ones close a lap (`last`, `best = min`, `finished++`, `lap = finished + 1`) and
return true. `formatMs(ms) = "%d:%02d.%02d"(min, sec, centis)` (US locale). Fix time = GPS fix
time if > 0 else wall clock.

Tests: arm (45,7); fixes (45,7,0 ms) false; (45.00072,7,5 000) false [~80 m away];
(45,7,10 000) false (clock starts, lap 1, not waiting); (45.00072,7,20 000) false;
(45,7,40 000) **true** → finished 1, last = best = 30 000, lap 2. Bounce (1/2/3/4 s fixes) → no lap.
`formatMs(1500) = "0:01.50"`, `formatMs(62030) = "1:02.03"`.

---

## 14. Phone-side flows (Map hub, `GpxActivity`) — summary [V]

* **Free ride** (to bike): `prepareFreeRide(overlays)`, history entry `("Free ride", 0, 0, "mode", "Started free ride")`, launch on the bike (needs a saved bike QR; else phone preview).
* **See map on phone**: free ride in the phone preview (MapLibre).
* **Pick GPX** → **Open GPX on phone map** / **Project GPX to bike** (warns if no offline area was downloaded).
* **Search** box + POI chips (same services, rows with Go / ★ / Marker / Remove / Delete); **Go** = `navigateTo(place, toBike = true)` → `prepareNavTo` + launch.
* **Parking**: Mark/Update parking here (`"Marked from Map hub"`), Navigate to parked (**phone**, walking back), Clear parked spot. **Home**: Set Home here (`"Set from Map hub"`), Navigate home (bike).
* **Circuit** button: sets route mode **FUN**, `pendingCircuit = true`, free ride, phone preview (see §11.8 caveat).
* Offline areas (radius 10/25/50 km or GPX bbox; standard/high detail) + roadside-POI corridor download; ORS key field; export/import map data; the same settings segments as the dash.
* Home-screen search bar (`MainActivity.navigateToTyped`, `:1362-1400`): when our map is on the bike → forward the query to the dash search; when Android Auto is live → hand to Google Maps; otherwise open the hub search.
* Launch semantics (`MainActivity.beginGpxProjection`, `:1724-1755`): if a bike session is live or `toBike` was requested and a QR is saved → hard switch (tear down AA/mirror, keep Wi-Fi, re-join with map video); else open the phone preview. A live AA session can be soft-switched to the map on the same PXC link (`AndroidAutoService.switchToMapProjection`, `EasyConnProber.attachOwnedGpxVideo`).
* While the map UI is bound, trips are auto-logged like AA rides when "Log trips automatically" is on (`TripAutoLog.kt:30-52`).

---

## 15. iOS implementation notes

1. **Split pure logic from platform.** Put the parser, `RouteFollower` (port of `GpxNav` incl. the cursor/backtrack rules), formatting, voice planner, routing orchestrator and clients (with injectable HTTP), ranking, Overpass parsing, places store and lap timer in `OpenCfMotoCore` so the §4.11 / §5 / §6 / §8 / §13 vectors run on Linux CI. Keep platform adapters (CoreLocation, AVSpeech, tile fetcher, renderer, VideoToolbox) in `OpenCfMotoApple`.
2. **Parity mode vs fixes.** Implement the Android behaviour exactly first (tests), then enable fixes behind flags: (a) arrival start-distance at the first fix after Go (§4.8); (b) ignore intermediate `arrive`/`depart` steps and assign step indices monotonically (§4.3); (c) turn distance from the snapped position (§4.2); (d) keep maxspeed in its native unit (§8); (e) periodic 60 s theme re-evaluation (§10.3); (f) pan ⇒ free-pan 12 s; (g) visible toasts for status messages (§11.11); (h) restore follow/heading-up/speed-zoom when a preview is cancelled (§11.8); (i) make the Lap control reachable by handlebar focus (§11.9).
3. **Rendering.** Draw into a `CVPixelBuffer` (BGRA, IOSurface-backed) at the exact canvas size; scale factor = `clamp(round(160·W/900),160,640)/160` (1.0 for 800-wide). Map = Web-Mercator 256-px raster tiles (z 5–20, over-zoom > 19), rotated about the canvas centre by `−bearing` in heading-up; camera centre offset per §4.9. Pre-invert tiles for night (`255 − c`, alpha unchanged) and cache both variants. Draw route polylines with `CGPath` (round caps/joins, widths in §11.2, dashed yellow 8/6). Use CoreText with SF Pro (bold) at the px sizes of §11.3/§11.4; disable leading padding to mimic `includeFontPadding=false`. Render only on state change (GPS fix, compass tick ≤ 8 Hz, animation, touch), but **guarantee a frame at least every ~1 s** to stay well under the 9 s bike timeout; consider interpolating the camera between 0.8 s fixes for smoothness (Android jumps).
4. **Layout engine.** Implement explicit rect computation for landscape and portrait (§11.3–11.4) from text measurements, avoiding the gauge/metrics overlap. Hit-test touches in canvas pixels; single pointer; DOWN/MOVE/UP → tap / long-press (≈ 500 ms) / pan.
5. **Location.** `CLLocationManager` with `kCLLocationAccuracyBestForNavigation`, `distanceFilter ≈ 1.5 m`, `activityType = .automotiveNavigation`, background location. Map `speed < 0` → "no speed", `course < 0` → "no bearing", `horizontalAccuracy` → accuracy (reroute requires < 60 m). Heading: `CLHeading.trueHeading` smoothed with the same α = 0.15 unit-vector filter, processed at most every 120 ms.
6. **Voice.** `AVSpeechSynthesizer`; emulate `QUEUE_FLUSH` with `stopSpeaking(at: .immediate)` before each utterance; rate ≈ 0.95 × default; audio session `.playback` + `.voicePrompt`/`.duckOthers`, routed to the BT helmet. Localise phrases (the Android ones are English only) but keep the English templates as the reference.
7. **HTTP.** One `URLSession` with the identifying UA, the per-endpoint timeouts and size caps of §9, a non-blocking per-host throttle (actor), Java-`URLEncoder`-compatible encoding (space → `+`, encode `~`), and the same error strings. Format coordinates in URLs/JSON with the POSIX locale (`.` decimal). Nominatim returns lat/lon as strings.
8. **Number formatting.** For parity with the Kotlin strings use HALF_UP rounding (`NumberFormatter.roundingMode = .halfUp`) and decide explicitly between POSIX and the rider's locale for UI text (Android uses the device locale for `%.1f`).
9. **Routing.** Port the orchestrator decision tree, tolerances and labels verbatim (§6.1); polyline6 decoding with 64-bit ints; treat Valhalla `length` as km. Use a cached preview route on Go; reroute with the single-route path. Never block the UI: carry a request token so stale preview results are dropped (Android checks `pendingPlace == place`).
10. **Persistence.** Store places/prefs as JSON with the same field names; implement the `opencfmoto.map` v1 export/import for cross-platform compatibility.
11. **Handlebar.** Map AVRCP remote commands to the same abstract actions (ENTER/BACK/HOME/ASSISTANT/DPAD/knob) and reproduce the focus lists and ring of §11.9; the dash UI must be fully operable without touch (many dashes are non-touch).
12. **Video coupling.** On (re)attach of the map stream: flush, force an IDR, and force another ~200 ms after the first map paint; prefix keyframes with SPS/PPS; apply the 1.35× bitrate / halved GOP "map boost" when fps ≥ 30.

### Apple Music (iOS addition)

No Android counterpart. When the app fills `DashModel.music` (`DashNowPlaying`: title, artist, album,
artwork id, playing / paused, duration, and the position as a sample `position` at `positionAt` on the
controller's `now` clock), the dash shows what the system Music app plays. Only Apple Music: iOS gives
apps no access to other players. `music == nil` (feature off, no permission, nothing loaded, or a paused
song while another app plays) → no tile, no menu entry, and an open sheet closes once that lasted 2 s
(`Options.musicSheetVanishGrace`, see "Focus when a Music control vanishes"). The app keeps the last
song through a reading without one for 2 s (MusicModel `trackGapGrace`, review round 3): one reading with
no item between two songs never reaches the dash, so the tile, the open sheet, the menu's "Music" and
the focus stay put; a gap that lasts sets `music = nil`.

**Now-playing tile** (`music.tile`, map screen, no sheet; free ride, navigating, preview, arrival). A
square under the FAB column, right-aligned with it, 8 dp under the last FAB: min(64 dp, room), at least
the 46-dp FAB size (`DashLayout.musicTile`). Landscape: down to 8 dp above the clock chip; if that leaves
< 46 dp the clock gives way (`hidesClock`, room measured to 8 dp above the safe bottom). Portrait: under
the clock, down to 12 dp above the safe bottom. A card that would intersect it (metrics, speed chip,
preview, arrive, lap) shrinks it to end 8 dp above that card; < 46 dp → no tile (the menu entry stays).
800×384: 730–794 × 270–334 (clock 733–794 × 348–376). No text: placeholder (#263040, radius 10 dp,
music note 40 %) → artwork (`DashDrawCommand.image`, aspect fill, rounded clip; an unknown id draws
nothing) → night: 15 % black (never inverted) → 1-dp outline → progress track 3 dp inset 6 dp at the
bottom (known duration only; fill = whole px) → paused: 45 % black dim + 20-dp ❚❚ badge top-right. Tap /
★ → `.openMusic`. Focusable last in the map lists (free ride `pill … fab.menu, music.tile`, navigating
`metrics.end, fab.* , music.tile`): one ◀ from the default item reaches it. Drawn but inert in preview /
arrival: not focusable, and a tap does nothing (it swallows touches; R3-FOCUS-2, see "No Music sheet over
a preview or the arrival card" below). Focus ring on the tile (fix F3; every close of the sheet parks the
focus there, so the usual ring would tint the cover for the rest of the ride): no fill, and the 5-dp
stroke runs OUTSIDE the cover (path = frame grown by 2.5 dp, radius 12.5 dp: the band starts at the
cover's edge and follows its corners). It fits on every canvas, inside the safe area and clear of every
other widget: 800×384 725–799 × 265–339, 3 px under the Menu FAB and 9 px above the clock; with screen
margins 1 px inside the safe area; portrait 3 px under the clock (`DashMusicFocusRingTests`).

**Music sheet** (`DashSheet.music`, `DashLayout.musicSheet`). Opaque #12171E over the whole canvas;
nothing of the map or its chrome is drawn under it. While navigating the nav card is drawn again ON TOP
(same rect) and reserved by the layout: guidance is never hidden. Margin 16 dp, gap 12 dp. Two
candidates, the larger artwork wins (tie: side-by-side in landscape, stacked in portrait):
side-by-side (artwork square on the right, side = min(safe.h − 32, safe.w − 48 − 300) dp, moved below
the nav card when that reaches its column; text column ≥ 300 dp on the left, block vertically centred)
or stacked (artwork centred at the top, block below at the least compressed step that fits 60 % … 30 %
of the height left). Artwork < 96 dp → candidate rejected; none → text only. Block, centred: title
22 sp bold (24 sp stacked on portrait) ≤ 2 lines ("" → "Unknown song") · +4 artist 17 sp · +2 album
15 sp · +14 progress bar 6 dp · +4 times 14 sp tabular ("2:13" left, "-3:51" right) · +14 transport
⏮ 64 dp · 20 · ⏯ 80 dp (blue) · 20 · ⏭ 64 dp. Empty artist / album and an unknown duration (radio,
live) drop their lines and spacing. Compression ladder: full → no album → title 1 line → compact
transport (52 / 64 dp) → no artist → no times. ✕ (48 dp, `.closeSheets`) on the artwork's top-right
corner, inset 8 dp. No seek, queue, volume, marquee or animation; targets ≥ 48 dp. 800×384: artwork
432–784 × 16–368, ⏮ ⏯ ⏭ x 92–156 / 176–256 / 276–340.

**Ids and intents.** `music.tile` (`.openMusic`), `music.sheet` (full-canvas blocker), `music.previous`
(`.musicPrevious`), `music.playPause` (`.musicPlayPause`), `music.next` (`.musicNext`), `music.close`
(`.closeSheets`), menu `menu.music` "Music" / "Música" after `menu.circuit` (`.openMusic`, only with
music and never over a preview or the arrival card). `.openMusic` is UI-only (without music: toast
"Nothing playing in Apple Music"; over a preview or the arrival card it opens nothing); the app performs
the transport intents. Sheet focus order: ⏮ ⏯ ⏭ ✕, initial focus ⏯; BACK / ✕ / auto-close → focus on the
tile (not listed: see below); BACK on the tile keeps it (R2-DASH-2: after the sheet closed by itself —
idle, near a turn, R2 — the rider's BACK was meant for that sheet, and Android's idle BACK → End would
turn the next ★ into an unconfirmed end of navigation; the scene is built first, so a timed close that
no frame has applied yet counts too); HOME opens the menu on "Music", not End, from the sheet, from the
tile and from a vanish's stand-in (R3-FOCUS-3, R4-FOCUS-1: on the iOS default map HOME is ▶▶, and two
quick ▶ are also the rider's way from ⏯ to ✕ — on End, the ★ meant for ✕ ended navigation; after the
sheet closed by itself, HOME on the tile or the parked Recenter was the map's HOME and its ★ ended
navigation the same way; "Music" not listed → its stand-in Circuit, parked). ▶▶ is a knob step first:
begun after the sheet already closed, its first ▶ leaves the tile (for End) or Recenter (for Zoom in)
before HOME arrives, and the menu then opens on End as after any close.

**Focus when a Music control vanishes** (fixes F2, R2-DASH-1). The song can go away for a moment (a
paused song while another app plays, a stale "other audio" reading right after a pause, no item between
songs for longer than the app's 2-s hold) and with it the tile, the menu's "Music" or the open sheet.
The handlebar focus then never falls
back to the default item — End while navigating, where the rider's next ★, meant for the tile, ⏯ or
"Music", would end navigation without confirmation. `DashFocusPreference.musicGone` → the first listed of
`fab.recenter` (map; ★ only recenters and the focus stays on the map, so repeated ★ meant for the tile or
⏯ are harmless — on `fab.menu`, round 1, ★★ opened the menu on End and ended navigation) and
`menu.circuit` (menu; ★ without a previewed place only shows a hint), else the usual keep / first item.
It applies when the focused `music.*` / `menu.music` id is no longer listed (the song went away, or a lap
card took the tile's room), when the sheet closes because `music == nil` stayed so for
`Options.musicSheetVanishGrace` (2 s; arrival keeps its own rule), and when the closing sheet's
`.musicTile` finds no tile (no room for it, or the song went away in the same frame). A shorter vanish
does not close the open sheet (R3-FOCUS-1): it stays on the song it showed and on the control the rider
left. Closed at once, it handed the knob back to the tile, the last item of the map list, from where the
rider's next ▶ ★, meant for ⏭, wrapped to End (`DashMusicSheetVanishTests`). For those 2 s the song is held
for whatever the rider reaches from the sheet too (review R4-FOCUS-2): the menu HOME opens lists "Music"
(focused, `.menuMusic`), BACK / ✕ land on the tile, ★ on either re-opens the held sheet — so every press
means what it would mean with the song (`testEveryPressDuringTheHoldMeansWhatItWouldWithTheSong`); when the
hold ends they go as above. Without it HOME's menu had no "Music" and parked on Circuit, whose ◀ ★ is Record,
and a sheet closed during the hold landed on the parked Recenter, whose ◀ ★ ends navigation (Lap in free
ride). A preview, the arrival card or a navigation start drop the hold. When the control is listed
again and no dash input came in between, the focus returns to it (the tile for the tile and the sheet's
controls, `menu.music` in the menu); after any input it stays where it is. A closed sheet stays closed.
Trade-off of the map target: `fab.recenter` follows End in the map list, so ◀★ while the tile is still
gone ends navigation — the same two presses as ▶★ from the tile itself. Nothing else hands the focus to End this
way (F2 audit, pinned by `testNothingButMusicCanVanishFromTheListsThatFallBackToEnd`): while navigating
the map list is End, the FABs and the tile (the pill is not drawn; cards, toasts and the banner are not
focusable), and the menu's ids are fixed except `menu.music`; a search row that vanishes falls back to
the sheet's first item, a route chip of a preview to Go, and a preview only ends on an explicit action.

**No Music sheet over a preview or the arrival card** (iOS addition, review R3-FOCUS-2,
`DashModel.offersMusicSheet`). The tile is drawn there but inert, the menu has no "Music" and `.openMusic`
opens nothing; a sheet open on the map still closes when a preview or the arrival card comes up. Their
lists hold neither the tile nor a harmless stand-in, so every close of a sheet there — a song gone for a
moment, the idle close, BACK — left the focus on their first item: the rider's next ★, meant for ⏭, was
Go (it replaces a running navigation without confirmation) or Park, BACK cancelled the preview, ★ on the
menu's parked "Circuit" built a circuit to the previewed place, and on a touch dash a second tap on ⏭
hit-tested after the gap could land on Go. Pinned by `testNoMusicSheetOverAPreviewOrTheArrivalCard` and
`DashMusicBlindInputTests.testPreviewAndArrivalHaveNoMusicStateAndAVanishChangesNothing`.

**Blind input** (iOS addition, review round 2). While the Music app holds the bars, or with the eyes on
the road, the rider presses ★ and BACK for the Music control the focus was left on without looking.
HOME from the sheet opens the menu on "Music" (`.menuMusic`), and closing the menu from "Music"
(BACK, HOME) lands on the tile (`.musicTile`), not on End — Android's own
items keep Android's rule. While the focus rests on the stand-in a vanish parked it on (`fab.recenter`
for the tile, `menu.circuit` for the menu's "Music"), BACK there and any sheet close under it (★ on the
parked Circuit closes the menu) go to `.musicTile` too: the tile, else parked again until it is back.
★ on the stand-in keeps it parked (Recenter only recenters; Circuit closes the menu onto the tile, else
Recenter, parked again); moving the knob off it ends that. No Android flow lands here: "Music" is an iOS
addition, and a stand-in only exists after a Music control vanished — a Recenter FAB or Circuit the
rider moved to keeps Android's rule. `DashMusicBlindInputTests` pins it
exhaustively — from the tile (playing, paused), the sheet on each of ⏮ ⏯ ⏭ ✕ and the menu on "Music",
navigating and in free ride, with the song staying, gone for one built frame or gone for good, with or
without a frame between the presses, no sequence of 1–3 ★ / BACK (and HOME from the tile or a stand-in,
R4-FOCUS-1) returns `.endNavigation` or any other
action of consequence. Knob steps are not blind-safe: End is a stop of the map's list, and from where a
vanish parked the focus a knob step lands on other neighbours than from the vanished control. That test
lists, from every one of those states, the shortest knob sequences to End — a vanish for one frame adds
none, compared with the same start without a vanish (an open sheet stays open through it), and a song
gone for good adds only the Recenter trade-off above (◀★, and B◀★ / ★◀★ since BACK and ★ keep the
stand-in) to what any close of the sheet leaves (the tile's paths) — and to the other actions of
consequence (Lap / Stop, Record, Park here, Set home here, Go home, Go, the voice): in free ride the
pill's Lap precedes `fab.recenter`, so the same sequences and ◀B★ press Lap / Stop (★ stops a running lap
timer and clears its laps, or arms one); in the menu ◀★ from the parked Circuit is Record / Stop
recording (◀◀★ from "Music"). From a control that is not a Music control nothing parks or returns: the
list only loses the tile (between the Menu FAB and End) or the menu's "Music" (between Circuit and
Follow), and a knob step meant for them lands on that neighbour, where ★ and BACK keep Android's rules.
With the song gone, or gone at the very knob step and back before the ★ (a gap that outlasted the app's
2-s hold), these are a dash without music: while navigating the field guide's ◀★★ from End (◀ wraps to
the tile) and ◀B★ from End, ▶★ / ▶B★ from the Menu FAB (▶▶★ from Compass), ▶B★ from Circuit and
◀B★ / ◀★★ from Follow end navigation (BACK at idle or in the menu, and ★ on Circuit, land on End), and
◀◀★ from Follow, also in free ride, is Record / Stop recording. Longer ones first reach one of these
starts (B◀★★, ★◀B★; ◀◀B★ from Recenter) or add knob steps (◀★▶★ Park here from End or the free-ride
pill, ▶▶▶★ Lap from the free-ride Menu FAB) (`testFromEndTheTileMustBeListed`,
`testFromAControlThatIsNotAMusicControlAVanishIsADashWithoutMusic`).

**Safety rules** (`DashUIController`): the sheet never opens by itself and closes on ✕ / BACK; 2 s after
its song went away (`Options.musicSheetVanishGrace`, drawn with that song meanwhile); after
10 s without dash input while the bike moves or has no fix (`Options.musicSheetIdleTimeout`; it stays
open while stopped); while navigating when the next turn comes within 200 m
(`musicSheetTurnDistanceM`; once per turn, never within 3 s of an input — `musicSheetInputGrace`; a
turn already near when the sheet opens does not close it); on preview start, navigation start, arrival
start. `tick(now:)` returns `[.closeSheets]` for the timed closes (idle, near a turn, the song gone
2 s). Every dash input and every music intent counts as activity.

**Re-render cadence.** The scene extrapolates the position to the frame time; the display list changes
only when what is drawn changes: on the sheet once per elapsed second (labels and bar move together:
remaining = whole seconds of the length − elapsed seconds, so the two labels always add up to ⌊length⌋
and, the position being clamped to the length, the remaining label reaches "-0:00" at the end — 245.6 s:
"-4:05" … "-0:00", fix F8), on the tile when the bar gains a whole pixel, never while paused. The app
updates `DashModel.music` only on meaningful changes (song, state, seek / drift).

---

### P0 safety and legibility (iOS, UI/UX proposal)

Changes to today's layouts, no new slot layout (that is P1). Pinned by `DashSafetyRulesTests` over every
dash state the tests build, on eight canvases.

- **No destructive default (D01).** While navigating the default focus is the Recenter FAB, not End.
  End left the metrics card; the menu opens on «Recenter» (the camera only: it closes the menu and
  recentres) and lists «Reroute» and «End route…» last in its Ride section (only while a route runs:
  Reroute asks the router again from the fix, which turns a circuit into its outbound leg and a picked
  alternative into the preferred route). «End route…» opens a confirm card «End the route?» with the
  consequence line and [Keep going*][End route]; Go over a preview while a route runs asks «Change
  route?» the same way (the card stands in for the preview card), and so does a handlebar saved place
  (nav1–3), which opens as a preview while a route runs. The safe option is the default, the card closes
  after 8 s without input committing nothing, and closes when its question no longer applies. Its
  consequence line shortens the place names (whole words, «…») so its fixed part always shows; in
  landscape the metrics card it covers is not drawn while it is up (no cut numbers beside it). No
  destructive or route-replacing item is the default or one knob step from it, except the confirm card's
  own action.
- **Doubles (D02).** On the iOS default map ★★ is unmapped (a quick second ★ is swallowed) and ◀◀ / ▶▶ are
  their own knob step (two presses, two steps, at any tempo); with the single-button option the single waits
  out the double window, so ★★ chooses what is focused (input-controls.md §9.1).
- **Speed and limit never covered (D03, D19).** The gauge and the limit sign are the scene's last drawing,
  over the menu, the search and Music sheets and every card; the limit sign's room is always reserved
  (the gauge does not jump and the metrics card does not reflow when a limit appears). Scroll containers
  under it scroll the focused control clear of it and get end padding (`testTheKnobNeverFocusesAnItemUnderTheGauge`
  steps the knob through every menu, search and Music item on every canvas).
- **Focus ring (D09).** Outline only: white 3 dp on a black 5-dp band, 0–5 dp outside the control (the
  music tile's ring of fix F3, for every control). Never a fill over the control.
- **Map (D05).** `tile(…, treatment:)` replaced `tile(…, invert:)`: `normal`, `inverted` (classic night),
  `mutedDay`, `mutedNight` (the default `DashMapStyle.muted`). TileImageCache builds each variant once per
  tile and caches it. The route is cased (10 dp over 17 dp: blue on white by day, light blue on near-black
  at night); the puck is a white chevron with a dark outline over a halo (dark by day, white at night).
- **Night (D06).** AUTO = the sun below −0.833° (sunset to sunrise) at the last fix, computed on the phone
  (`SunPosition`, `NightModePolicy.isNight(theme:position:date:)`); without a fix yet 19:00–06:59; the
  phone's dark mode plays no part. At night the search pill and the search sheet are dark.
- **Type and cards (D11, D12).** Turn distance 48 sp (portrait 52), road 26 (28), speed 44 (48, shrunk to
  fit three digits); the portrait metrics bar uses the landscape card's sizes (labels 13, values 26 / 26 / 30:
  never smaller than 800x384); cards, gauge, clock and FABs are opaque with a 1.5-dp edge; ALT left the
  metrics card.
- **Hold picture (D17).** A card on the plain chrome colour — «Map paused», «Voice keeps guiding» while a
  route runs with the voice on, «Resumes when you open the app, stopped» — no map and no numbers; dash
  keys and touches are ignored while it shows (the controller with `holdMessage`, RideModel while the
  projection is in hold mode).
- **Arrival (D22).** [Done*][Park here][Find parking], the same labels on every canvas; Park here only sets
  the parked spot (the menu's toggle that cleared a pin within 40 m is gone).
- **Copy (D23).** Neutral Latin-American Spanish (estacionar, autopista, viaje, gasolinera, cajero
  automático; «Llegaste»), no shouting capitals, verb labels on the menu toggles («Pan the map», «Put north
  up», «Mute voice»…).

### Fuel range alert (iOS addition)

The dash's only fuel element in the MVP is one transient toast, with no new input: «Autonomía baja: ~70 km
hasta la reserva» / "Low range: ~70 km to reserve" once when the phone's range estimate crosses into low
(≤ 80 km to the reserve) and «En reserva: carga gasolina pronto» / "On reserve: refuel soon" once at the
reserve, for 6 s through the existing `showToast` path (`DashLayout.overlayPill`, below the top chrome, ≤ 2
lines, never over the gauge or the limit sign), plus a voice line when voice prompts are on. It waits until the
own UI is live on the dash (projecting and streaming) and while a sheet, the confirm or arrival card, a preview,
the hold picture (the engine's, e.g. a locked phone) or another toast is up, and the voice waits
for silence and for no turn cue within 500 m; Mirror sessions get the voice only. No `DashModel` field, intent,
hit region or focus target. Rules, strings and the estimate: `app-features.md` §15.8.

## 16. Open questions / risks

* **R1 — Arrival logic.** The shipping Android code appears never to show the Arrived sheet (§4.8). Confirm intent with maintainers / a ride log (`[GPX] near dest at nav start`) before choosing iOS semantics.
* **R2 — Via-leg cues.** Circuits and via-built alternatives likely lack turn cues on Android (§4.3). Confirm on a ride; iOS should fix.
* **R3 — Internet while joined to the bike AP.** Android pins traffic to cellular explicitly. On iOS, verify that URLSession traffic reaches the internet while associated to a no-internet accessory Wi-Fi (NEHotspotConfiguration); fallbacks: `NWConnection` with `requiredInterfaceType = .cellular`, Multipath TCP entitlement, or prefetching routes/tiles before joining (tiles: only from a tile server the rider configured, never the OSMF ones, §10.4).
* **R4 — Public-service policies.** tile.openstreetmap.org (no bulk, UA required, may refuse heavy app usage), Nominatim (1 req/s), Overpass (fair use), router.project-osrm.org and valhalla1.openstreetmap.de (demo servers, no SLA), Photon (komoot public). An App-Store app may need its own/paid tile & routing providers; keep endpoints configurable. iOS today: no route-corridor prefetch from the OSMF tile servers and a "© OpenStreetMap" credit on the dash map (§10.4).
* **R5 — ORS key.** Android bakes an optional default key at build time; decide how iOS supplies one (user-entered only?).
* **R6 — Portrait canvas.** The 800×944 layout is shipping code but not visible in the repo's hardware footage; pixel estimates in §11.4 are derived.
* **R7 — Text-dependent layout.** Wrap-content cards make exact geometry font-dependent (Roboto vs SF Pro); the gauge can overlap the metrics card on 800×384 (§11.3).
* **R8 — Night mode.** No solar algorithm exists; AUTO = phone dark mode or 19:00–06:59. Decide whether iOS adds a real sunrise/sunset calculation (parity says no). iOS P0 decided yes: AUTO follows the sun at the fix (§15, P0).
* **R9 — Puck vs bottom card.** Look-ahead at high zoom puts the puck behind the metrics card on 384-px-tall dashes (§4.9).
* **R10 — Dead/legacy features.** Fun circuit length, ORS round-trip, `circuitWaypoints`, `laneHintFromText`, region packs, hidden Fit/Mute FABs and the hub "Circuit" button (sets FUN mode, then cannot build a circuit without a previewed place) — decide whether to port.
* **R11 — Off-dash pan.** Android has no pan-suspends-follow; dash panning is effectively unusable while moving. UX decision for iOS.
* **R12 — Screen margins / pull-down zones.** The built-in map ignores the per-bike screen margins used for AA (e.g. 800NK Advanced's MotoPlay pull-down area); top-edge controls (search pill) may conflict with the dash's own gestures.
* **R13 — Locale.** Android output mixes device-locale decimals with English phrases; iOS must choose a consistent policy (and keep wire formats POSIX).
