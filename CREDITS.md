# Credits / Créditos

> **Resumen en español.** OpenCfMoto para iOS es un port a Swift de
> [OpenCfMoto para Android](https://github.com/zanderp/open-cfmoto), de **Alexandru Popa
> ([@zanderp](https://github.com/zanderp))**. Ese proyecto continúa el trabajo de la comunidad
> open-cfmoto: dcoletto / coletz, richardbizik, BojanJ, ionutradu252, eugen0309, Martin Escudero,
> Glifaus, sashop2001, Authoritt y los traductores. De él vienen el protocolo PXC / EasyConnect, los
> perfiles de tablero, la navegación, los viajes y los formatos de ajustes (AGPL-3.0); de Authoritt,
> además, la traducción al español y la memoria del transporte Wi-Fi de cada moto. El receptor de
> Android Auto de la app Android (headunit de Michael Reid y Open Headunit de Andre Rinas) se acredita,
> pero **no** está en esta app. Esta app incluye código traducido de AOSP e iconos Material de Google
> (Apache-2.0) y usa datos de OpenStreetMap (© colaboradores de OpenStreetMap, ODbL) a través de
> servicios públicos: teselas de la Fundación OpenStreetMap, Photon de komoot, Nominatim, Overpass,
> Valhalla de FOSSGIS, OSRM y, con tu propia clave, openrouteservice de HeiGIT. Gracias a todos los
> que probaron motos y compartieron registros. ¿Falta alguien o hay un error? Abre una incidencia.

This file lists the people, projects, code and services that OpenCfMoto for iOS is built on.
If a credit is missing or wrong, please [open an issue](https://github.com/Kevinparra535/opencfmoto-ios/issues).

## 1. The app this is ported from

**[OpenCfMoto for Android](https://github.com/zanderp/open-cfmoto)**
© 2026 Alexandru Popa ([@zanderp](https://github.com/zanderp) · [alexandru.rocks](https://alexandru.rocks))
and the OpenCfMoto contributors · AGPL-3.0-or-later.

This app is a Swift port of OpenCfMoto **2.0.18** (commit `0abbe2a`), and in particular of its
"Map / GPX on the dash" mode. These parts were ported from its Kotlin sources and its
reverse-engineering documentation:

- the PXC / EasyConnect link: discovery, probe, handshake, `CLIENT_INFO` with the RSA identity, the
  control and media planes, heartbeats and reconnect;
- dash and bike profiles, pairing-QR parsing for every brand format, the garage and per-bike memory;
- the dash UI: layouts, palette, icons, strings, handlebar focus navigation, the gesture engine and
  the switch-cluster presets;
- navigation: place search, nearby places and speed limits, routing (Valhalla / OSRM /
  openrouteservice), GPX following, rerouting and voice prompts;
- the trip computer, trip logs and GPX export; the `opencfmoto.settings` and `opencfmoto.map`
  formats; log redaction;
- part of the Spanish texts, from the Android app's Spanish locale (completed by
  [@Authoritt](https://github.com/Authoritt)).

The protocol was worked out by the open-cfmoto community (section 2) and verified against the
official CFMOTO app and real dashes.

If OpenCfMoto helps you, consider supporting its author: <https://ko-fi.com/alexandrupopa>

## 2. The open-cfmoto community

OpenCfMoto for Android credits these people and forks. Their work is described as upstream
describes it; the last column says what of it is in this iOS app.

| Who | Work | In this iOS app | Link |
|---|---|---|---|
| dcoletto (coletz) | The original open-cfmoto: the first open CFMoto MotoPlay / EasyConnect mirroring app (QR and EasyConn work) | Yes: QR pairing and the EasyConnect link build on it | [dcoletto/open-cfmoto](https://github.com/dcoletto/open-cfmoto) (archived) |
| richardbizik | 1000 MT-X support and profile work | Yes: bike profiles | [richardbizik/open-cfmoto](https://github.com/richardbizik/open-cfmoto) |
| ionutradu252 | OpenCFLink: handlebar controls, on-screen pad, navigate-to, Assistant mic, screen margins, log redaction, update checker, ghost-touch / stitch, reconnect polish, 800NK Advanced geometry, CFDL16 / 450SR buttons | Partly: handlebar controls, screen margins, log redaction, reconnect, 800NK Advanced geometry | [ionutradu252/open-cflink](https://github.com/ionutradu252/open-cflink) (formerly `ionutradu252/open-cfmoto`) |
| eugen0309 | Wi-Fi Direct (`BikeWifiP2p`) and the CL-C450 path | Partly: the CL-C450 dash (iOS has no Wi-Fi Direct) | [eugen0309/open-cfmoto](https://github.com/eugen0309/open-cfmoto) |
| Authoritt | Vehicle-telemetry field notes, per-bike Wi-Fi transport memory, the complete Spanish locale | Yes: per-bike transport memory and the Spanish texts | [@Authoritt](https://github.com/Authoritt) |
| BojanJ | Fuller Android Auto receiver integration | No: Android Auto, Android app only | [BojanJ/open-cfmoto](https://github.com/BojanJ/open-cfmoto) |
| Martin Escudero | Android Auto 17.4+ head-unit-server dial-out | No: Android Auto, Android app only | [@martinescudero](https://github.com/martinescudero) |
| Glifaus | Wi-Fi Direct keep-alive | No: Android app only | [@Glifaus](https://github.com/Glifaus) |
| sashop2001 | Android Auto DPI, Bluetooth connect trigger, Bulgarian strings | No: Android app only | [sashop2001/open-cfmoto](https://github.com/sashop2001/open-cfmoto) |

Translations and fixes merged into OpenCfMoto for Android:
[@danielrakaczki](https://github.com/danielrakaczki) (Hungarian, a supported-bikes fix),
[@JoaoRodrigoNeves](https://github.com/JoaoRodrigoNeves) (Android 11 Bluetooth permissions),
[@zerorespect](https://github.com/zerorespect) (Turkish),
[@raffybest94V01](https://github.com/raffybest94V01) (Italian),
[@arnaullv](https://github.com/arnaullv) (Catalan), [@matejde](https://github.com/matejde) (Czech),
[@dgtal1](https://github.com/dgtal1) (Polish). The iOS app ships English and Spanish only.

And thanks to everyone in the [Open CFMoto community](https://discord.gg/KNTjJhmFZ6) (upstream's
Discord) who tested bikes, shared logs and captures, and posted dash photos. The bike list in the
README comes from them.

## 3. Android Auto lineage (credited, not included)

The Android app's Android Auto receiver comes from the headunit family:

- **headunit** by Michael Reid ([@mikereidis](https://github.com/mikereidis)):
  <https://github.com/mikereidis/headunit>
- **headunit-revived**, now **Open Headunit**, by Andre Rinas
  ([@andreknieriem](https://github.com/andreknieriem)), AGPL-3.0:
  <https://github.com/andreknieriem/open-headunit>

The iOS app does not implement Android Auto and contains none of this code. It is listed because
the whole open-cfmoto family was built on it.

## 4. Third-party code and assets in this repository

| Component | License | Where | How |
|---|---|---|---|
| Android `Location.computeDistanceAndBearing`, © 2007 The Android Open Source Project | Apache-2.0 | `Packages/OpenCfMotoKit/Sources/OpenCfMotoCore/Trips/TripGeodesy.swift` | Translated to Swift, so trip distances match Android |
| Android libcore `org.json`, © 2010 The Android Open Source Project | Apache-2.0 | `Packages/OpenCfMotoKit/Sources/OpenCfMotoCore/Settings/AndroidOrgJSON.swift`, `Protocol/PxcOrgJSON.swift`, `Util/OrderedJSON.swift` | Tokenizer, coercions and writer behaviour re-implemented in Swift |
| The same `org.json` Java files | Apache-2.0 | `tools/android-prober-harness/aosp-json/` | Vendored unmodified (from Robolectric `android-all` 14); test tool only, not in the app |
| [Material Icons](https://fonts.google.com/icons) by Google: two_wheeler, gps_fixed, add, remove, explore, more_vert, crop_free, volume_up, search, place | Apache-2.0 | `App/Resources/Assets.xcassets/RideGlyph.imageset/ride.svg`, `Packages/OpenCfMotoKit/Sources/OpenCfMotoCore/Dash/DashIcons.swift` | Path data, via the Android app's vector drawables; explore and place slightly modified (see the file headers) |

The Apache License 2.0 text is in [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt), and the
notices are in [`NOTICE`](NOTICE) and in each file's header.

These algorithms are implemented from their public specifications, with no code copied: the Google
encoded polyline format (precision 6), the Vincenty inverse formula, haversine, Web Mercator /
slippy-map tiles, SipHash-2-4 (Jean-Philippe Aumasson and Daniel J. Bernstein), and H.264 / Annex B
parsing (ITU-T H.264).

Apple's frameworks (SwiftUI, MapKit, MusicKit, VideoToolbox, ReplayKit and the rest of the iOS SDK)
are part of the platform, not third-party code in this repository.

## 5. Map data and online services

| Service | Used for | Operator | Attribution / policy |
|---|---|---|---|
| OpenStreetMap data | the dash map, search and routing | OpenStreetMap contributors | **© OpenStreetMap contributors**, ODbL 1.0, <https://www.openstreetmap.org/copyright> |
| tile.openstreetmap.org | default dash map tiles (you can change the server in Settings) | OpenStreetMap Foundation | [Tile Usage Policy](https://operations.osmfoundation.org/policies/tiles/) |
| Photon, photon.komoot.io | place search | komoot | fair use |
| Nominatim, nominatim.openstreetmap.org | search fallback | OpenStreetMap Foundation | [Nominatim Usage Policy](https://operations.osmfoundation.org/policies/nominatim/) |
| Overpass API, overpass-api.de | nearby places, speed limits | FOSSGIS e.V. | fair use |
| Valhalla, valhalla1.openstreetmap.de | routing, avoiding tolls or highways | FOSSGIS e.V. | at most 1 request per second; please be polite with request volume |
| OSRM, router.project-osrm.org | routing | Project OSRM demo server | Routes by OSRM; non-commercial, fair use |
| openrouteservice, api.openrouteservice.org | optional routing with your own key | HeiGIT gGmbH | © openrouteservice.org by HeiGIT · Map data © OpenStreetMap contributors |

These public servers are run by volunteers and non-profits. For heavy use, point the app at your own
tile server or use an openrouteservice key (Settings). The phone's own map is Apple Maps, which shows
Apple's legal notice; Apple Music artwork comes from Apple through MusicKit.

## 6. Tools

[XcodeGen](https://github.com/yonaskolb/XcodeGen) (Yonas Kolb, MIT) generates the Xcode project.
CI also uses GitHub Actions, ffmpeg, pngquant, actionlint and shellcheck. None of these ship in the
app.

## 7. Trademarks

CFMOTO, MotoPlay, EasyConn / EasyConnect, Carbit, Apple, iPhone, CarPlay, Apple Music, Apple Maps,
Android, Android Auto and Google are trademarks of their respective owners. This is an independent
community project. It is not affiliated with, endorsed by or sponsored by any of them, and uses the
names only to describe compatibility.
