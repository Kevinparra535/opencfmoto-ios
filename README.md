# OpenCfMoto para iOS

*[English version below](#opencfmoto-for-ios-english)*

**OpenCfMoto para iOS** es una app de iPhone que envía su **propia interfaz de navegación** —mapa,
indicaciones giro a giro, velocidad, límite de velocidad, hora de llegada, reloj y menús— a los
tableros **Carbit / EasyConnect** de las motos (CFMoto **MotoPlay** y sus hermanos de otras marcas),
usando el protocolo **PXC** obtenido por ingeniería inversa. Es un port a Swift de la app Android
[OpenCfMoto](https://github.com/zanderp/open-cfmoto) (AGPL-3.0), concretamente de su modo
«Mapa / GPX en el tablero».

> ⚠️ Proyecto comunitario en desarrollo (v0.1). Todavía no se ha probado en todas las motos:
> los informes de campo (con registros) son lo más valioso que puedes aportar.

## Qué hace

- **Mapa propio en el tablero**: el iPhone dibuja la pantalla del tablero (CoreGraphics), la
  codifica en H.264 (VideoToolbox) y la envía por el Wi-Fi de la moto. Teselas de OpenStreetMap,
  modo día/noche, ruta, cartel de giro con distancia, carriles, métricas (tiempo, llegada,
  distancia restante, altitud) y límite de velocidad.
- **Navegación**: búsqueda de lugares y direcciones, categorías cercanas (gasolina, café, comida,
  aparcamiento, hotel, cajero, hospital, mirador), rutas alternativas (Rápida / Divertida),
  circuito de ida y vuelta, evitar peajes o autovías, seguimiento de pistas **GPX**, recálculo,
  avisos de voz en español o inglés, favoritos, marcadores, casa y «dónde aparqué».
- **Táctil del tablero** (en los tableros táctiles) y **botones del manillar** (opcional y
  experimental, a través de los controles multimedia del iPhone), con asignación de gestos,
  preajustes por piña de mandos y lugares guardados para navegar con un botón.
- **Viajes**: ordenador de viaje, registro automático de cada ruta mientras el tablero muestra el
  mapa, lista por días con miniaturas y exportación **GPX**.
- **Garaje** con varias motos (cada una con sus propios ajustes), **conexión automática** y
  **recuperación** del enlace, **modo espejo** (toda la pantalla del iPhone en el tablero) y
  **registros** con informe de problemas (contraseñas y números de serie ocultos).
- **Ajustes compatibles con Android**: los paquetes `opencfmoto.settings` y `opencfmoto.map`
  se importan y exportan en el mismo formato que la app Android.
- Interfaz en **español e inglés** (sigue el idioma del iPhone).

## Tableros compatibles

Cualquier tablero CFMoto MotoPlay / EasyConnect u otro tablero del entorno Carbit que muestre un
**QR de emparejamiento**; no hace falta T-BOX. Estas motos están confirmadas con la app Android
(el protocolo y los perfiles de tablero son los mismos en iOS):

- **CFMoto**: 800MT (MT-X / Explore / Explore GT / Ibex 800) · 1000 MT-X · 800NK (US, CRCP) ·
  800NK Advanced · 675NK · 675SR-R · 700MT Adventure · 450MT · 450SR (+ SR-S / TC) ·
  450CL-C / CL-C450 · 450NK · 150SC · CFORCE 850 / 1000 · GOES Terrox 1000 / Gladiator G3 1000.
- **Otras marcas**: Voge DS800 Rally / DS900X · Moto Morini X-Cape 649 / 700 / Seiemmezzo ·
  Benelli TRK 702 / 702X (Wi-Fi introducido a mano, sin QR) · Rieju 307 · Zontes 125X ·
  Morbidelli T1002VX / T352X · QJ Motor SRK800RR / SRK450RR / SRK250RD / SRT 600 / SRV600.

Si tu tablero muestra el QR, prueba a conectar y comparte el resultado. Los tableros que se
conectan al punto de acceso del teléfono (algunos Zontes / Carbit «action=128») no funcionan en
iOS: iOS no permite crear un punto de acceso con el nombre que pide el tablero.

## Cómo funciona

1. **Emparejar**: escaneas el QR del tablero (o introduces el SSID y la contraseña). El QR
   contiene el Wi-Fi de la moto; se guarda en el llavero (Keychain) del iPhone.
2. **Conectar**: la app se une al Wi-Fi de la moto (`NEHotspotConfiguration`), abre los puertos
   10920–10922, envía la sonda a `:10930` y el tablero se conecta de vuelta al iPhone. Tras el
   saludo (`CLIENT_INFO`, firma RSA) el tablero pide fotogramas y la app le envía el vídeo H.264
   de su propia interfaz. Los toques del tablero vuelven a la app y la manejan.
3. **Internet**: el Wi-Fi de la moto no tiene internet. Búsquedas, rutas y teselas van por los
   datos móviles mientras estás unido a la moto (por eso se recomienda una tarifa de datos).

**¿Por qué no Android Auto ni CarPlay?** La app Android retransmite Android Auto, que es un
componente de Android: en iOS no existe. CarPlay solo funciona con unidades certificadas por Apple
(autenticación MFi) y iOS no deja que una app capture o reenvíe el vídeo de CarPlay. Por eso la app
de iOS dibuja **su propia interfaz** de navegación para el tablero, como el modo «Mapa» de Android.

**Modo espejo**: con la extensión de ReplayKit puedes enviar **toda la pantalla del iPhone** al
tablero (por ejemplo, para otra app de mapas). Los toques del tablero no controlan las apps
duplicadas, la pantalla debe estar encendida y la emisión se detiene al bloquear el teléfono.

## Requisitos

- Un **iPhone con iOS 17** o posterior y, para compilarla tú, un **Mac con Xcode 16** o posterior.
  **Sin Mac**: con la cuenta de pago, GitHub la compila y la sube a TestFlight
  ([docs/TESTFLIGHT.md](docs/TESTFLIGHT.md)).
- Una **cuenta de Apple Developer**:
  - **De pago** (Apple Developer Program) para la variante `full`: la app se une sola al Wi-Fi de
    la moto (*Hotspot Configuration*) y lee el SSID actual (*Access WiFi Information*).
  - **Gratuita** (Personal Team) para la variante `free`: sin esos permisos, te unes al Wi-Fi de
    la moto desde Ajustes de iOS cuando la app te lo pide (muestra el nombre y copia la
    contraseña). Con una cuenta gratuita la app caduca a los 7 días (vuelve a instalarla desde
    Xcode), hay un máximo de 3 apps por dispositivo y la extensión de espejo usa otro App ID.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) para generar el proyecto de Xcode.

## Compilar e instalar

```sh
brew install xcodegen
git clone https://github.com/Kevinparra535/opencfmoto-ios.git
cd opencfmoto-ios
cp Config/Local.xcconfig.example Config/Local.xcconfig
#   edita Config/Local.xcconfig:
#   DEVELOPMENT_TEAM = <tu Team ID>
#   BUNDLE_ID_PREFIX = com.tunombre        (un prefijo que sea tuyo)
#   OCM_FLAVOR       = full                (o free con una cuenta gratuita)
xcodegen generate
open OpenCfMoto.xcodeproj
```

En Xcode elige el esquema **OpenCfMoto**, tu iPhone como destino y pulsa **Run**. Antes, en el
iPhone, activa el **Modo de desarrollador** (Ajustes ▸ Privacidad y seguridad ▸ Modo de
desarrollador; la opción aparece después de conectar el iPhone al Mac con Xcode abierto). Usa el
Xcode más reciente: tiene que ser compatible con la versión de iOS de tu iPhone. Si iOS dice
«Desarrollador no confiable» (pasa con la cuenta gratuita), confía en él en Ajustes ▸ General ▸ VPN
y gestión de dispositivos. Al conectar con la moto, iOS pide permiso de **red local** y de
**ubicación**: acéptalos, sin ellos la app no puede hablar con el tablero ni dibujar el mapa.
`Config/Local.xcconfig` no se sube al repositorio.

Para la prueba en la moto compílala en **Release** (Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Build
Configuration ▸ Release), que va más fluida que Debug. Después no necesitas el Mac: abre la app desde
la pantalla de inicio. Con la cuenta de pago la instalación dura hasta un año (con la gratuita, 7 días).

### Sin Mac: TestFlight

Con la cuenta de pago, el workflow **TestFlight** de GitHub Actions compila la app en un Mac en la
nube, la firma y la sube a TestFlight; tú la instalas con la app TestFlight. Solo hay que crear una
clave de la API de App Store Connect, guardarla como secreto en GitHub y hacer dos pasos en la web
de Apple. Guía paso a paso: [docs/TESTFLIGHT.md](docs/TESTFLIGHT.md).

### Modo demostración

Para probar sin moto (por ejemplo en el **Simulador**), añade el argumento de arranque `-demo`
(Xcode ▸ Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments). La app usa servicios simulados: sin
Wi-Fi ni tablero, con una ruta GPS de demostración para ver la interfaz del tablero en el teléfono.

### Primera prueba en la moto

Sigue la guía paso a paso [docs/PRUEBA-EN-LA-MOTO.md](docs/PRUEBA-EN-LA-MOTO.md): qué esperar en cada fase de la conexión, cómo compartir registros, grabar el vídeo enviado al tablero y qué opciones probar si algo falla.

## Limitaciones conocidas

- **Modo ruta en primer plano**: iOS solo garantiza el codificador de vídeo por hardware y el
  Wi-Fi con la app en primer plano. Durante la ruta deja la app abierta en **Modo ruta** (pantalla
  negra, el teléfono no se bloquea) y con el iPhone cargando.
- **Teléfono bloqueado**: en segundo plano iOS no deja codificar vídeo; el tablero mantiene una
  imagen fija («Teléfono bloqueado: desbloquéalo para actualizar el mapa») y el enlace sigue vivo
  mientras iOS conserve el Wi-Fi, lo que no está garantizado con la pantalla bloqueada.
- **Permiso de red local**: iOS lo pide la primera vez que la app busca el tablero; si lo
  deniegas, actívalo en Ajustes ▸ OpenCfMoto ▸ Red local.
- **Botones del manillar**: solo llegan a la app que está «reproduciendo» (Now Playing). La
  opción es experimental y voluntaria: reproduce audio silencioso y **pausa la música de otras
  apps** mientras está activa; no todos los tableros envían esos botones; la pulsación larga de ★
  no es detectable en iOS; los ▲/▼ de volumen solo funcionan con la opción experimental.
- **App Store**: el audio silencioso para los botones y la lectura del volumen podrían no ser
  aceptados en la revisión de Apple. Además, la licencia **AGPL** es difícil de compatibilizar con
  las condiciones de la App Store: distribuir esta app (o un derivado) a otras personas, ya sea en
  la App Store o con pruebas externas o un enlace público de TestFlight, requiere el permiso de los
  titulares del proyecto original. La forma prevista es instalarla tú mismo, con Xcode o con las
  pruebas internas de TestFlight (solo para ti).
- Los servicios públicos de OpenStreetMap (teselas, Photon, Nominatim, Overpass, OSRM, Valhalla)
  tienen políticas de uso justo; para un uso intensivo configura tu propio servidor de teselas o
  una clave de OpenRouteService en Ajustes.

## Estructura del repositorio

```
project.yml                     Especificación de XcodeGen (app + extensión de espejo)
Config/                         OpenCfMoto.xcconfig (+ Local.xcconfig, tuyo, no versionado)
App/Sources/                    App SwiftUI: pantallas en UI/<función>/, servicios iOS en Services/
App/Resources/                  Recursos; Localization/*.json → Localizable.xcstrings (español)
MirrorExtension/                Extensión ReplayKit (modo espejo)
Packages/OpenCfMotoKit/         Paquete Swift
  Sources/OpenCfMotoCore/         Swift puro: protocolo PXC, enlace, navegación, interfaz del
                                  tablero, viajes, ajustes (compila y se prueba en Linux)
  Sources/OpenCfMotoAppModel/     Modelos @Observable de la app (también probados en Linux)
  Sources/OpenCfMotoApple/        Adaptadores de Apple: red, Wi-Fi, ubicación, voz, vídeo, mapa
  Tests/                          Pruebas XCTest
docs/ARCHITECTURE.md            Arquitectura y reglas del proyecto
docs/spec/                      Especificaciones de comportamiento extraídas de la app Android
docs/TESTFLIGHT.md              Instalar sin Mac: compilar y subir a TestFlight desde GitHub
.github/workflows/              ci.yml (pruebas y compilaciones) y testflight.yml (TestFlight)
tools/                          Herramientas: traducciones, CI, tablero simulado (fakedash)
  testflight/                     App Store Connect (asc.py), firma y subida, revisión del IPA
```

## Pruebas e integración continua

```sh
swift test --package-path Packages/OpenCfMotoKit
```

El núcleo y los modelos de la app (unas mil pruebas) se ejecutan en Linux y macOS. En cada push,
GitHub Actions (`.github/workflows/ci.yml`) ejecuta las pruebas en Linux, las vuelve a ejecutar en
macOS compilando los adaptadores de Apple, genera el proyecto con XcodeGen y compila la app para
el Simulador de iOS y para iPhone (también con el Xcode más reciente). Además ensaya el flujo de
TestFlight sin credenciales: pruebas de `asc.py` contra un App Store Connect simulado, ajustes de
firma, archivo sin firmar revisado por `lint_bundle.py`, el llavero temporal y la limpieza tras una
cancelación. Las traducciones se reúnen con `python3 tools/l10n/build_strings.py`.

## Privacidad

Sin cuentas, sin anuncios y sin telemetría. Las motos, los viajes y los registros se quedan en el
iPhone hasta que tú los compartes; las contraseñas Wi-Fi se guardan en el llavero y se ocultan en
los registros. Las búsquedas, rutas y teselas consultan servicios de OpenStreetMap.

## Créditos y licencia

Port para iOS de **[OpenCfMoto](https://github.com/zanderp/open-cfmoto)**, © 2026 Alexandru y los
colaboradores de OpenCfMoto, construido sobre el trabajo de la comunidad open-cfmoto: dcoletto /
coletz (QR y EasyConn originales), richardbizik (1000 MT-X), ionutradu252 / open-cflink (controles
del manillar, márgenes, reconexión), eugen0309 (Wi-Fi Direct / CL-C450), Glifaus, sashop2001,
Authoritt y todos los que probaron motos y compartieron registros. El protocolo, los perfiles de
tablero, la navegación, los GPX, los viajes y los formatos de ajustes se han portado de su código
Kotlin y de su documentación de ingeniería inversa. No incluye código del receptor de Android Auto.

Software libre bajo la **GNU Affero General Public License v3.0 o posterior** (ver
[LICENSE](LICENSE) y [NOTICE](NOTICE)). Si redistribuyes una versión modificada, debes ofrecer su
código fuente completo bajo la misma licencia. Datos de mapa © colaboradores de OpenStreetMap (ODbL).

## Aviso

Proyecto comunitario independiente. No está afiliado, respaldado ni patrocinado por CFMOTO,
Carbit, Apple, Google ni ninguna marca de motos. CFMOTO, MotoPlay, EasyConn, Carbit, iPhone,
CarPlay, Android Auto y las marcas relacionadas pertenecen a sus propietarios. Úsalo bajo tu propia
responsabilidad: no dependas de él para una navegación crítica, fija la ruta antes de salir y no
manipules el teléfono mientras conduces.

---

# OpenCfMoto for iOS (English)

**OpenCfMoto for iOS** is an iPhone app that streams its **own navigation dash UI** — map,
turn-by-turn guidance, speed, speed limit, arrival time, clock and menus — to **Carbit /
EasyConnect** motorcycle dashboards (CFMoto **MotoPlay** and its siblings from other brands) over
the reverse-engineered **PXC** protocol. It is a Swift port of the Android app
[OpenCfMoto](https://github.com/zanderp/open-cfmoto) (AGPL-3.0), specifically of its
"Map / GPX on the dash" mode.

> ⚠️ Community project, work in progress (v0.1). It has not been tested on every bike yet: field
> reports (with logs) are the most valuable contribution you can make.

## Features

- **Own map on the dash**: the iPhone draws the dash picture (CoreGraphics), encodes it as H.264
  (VideoToolbox) and sends it over the bike's Wi-Fi. OpenStreetMap tiles, day/night themes, the
  route, the maneuver card with distance and lanes, metrics (time, arrival, distance left,
  altitude) and the speed limit.
- **Navigation**: place and address search, nearby categories (fuel, cafe, food, parking, hotel,
  ATM, hospital, viewpoint), alternative routes (Fast / Fun), there-and-back circuits, avoid tolls
  or highways, **GPX** track following, rerouting, voice prompts in English or Spanish, favorites,
  markers, home and "where did I park".
- **Dash touch** (on touch dashes) and **handlebar buttons** (opt-in and experimental, through the
  iPhone's media remote) with gesture mapping, switch-cluster presets and saved places for
  one-button navigation.
- **Trips**: trip computer, automatic logging of every ride while the dash shows the map, a
  by-day list with route thumbnails and **GPX** export.
- **Garage** with several bikes (each with its own settings), **auto-connect** and **link
  recovery**, **mirror mode** (the whole iPhone screen on the dash) and **logs** with a problem
  report (passwords and serial numbers redacted).
- **Android-compatible settings**: `opencfmoto.settings` and `opencfmoto.map` packs import and
  export in the same format as the Android app.
- **English and Spanish** UI (follows the iPhone language).

## Supported dashes

Any CFMoto MotoPlay / EasyConnect dash, or another Carbit-framework dash that shows a **pairing
QR**; no T-BOX needed. These bikes are confirmed with the Android app (the protocol and the dash
profiles are the same on iOS):

- **CFMoto**: 800MT (MT-X / Explore / Explore GT / Ibex 800) · 1000 MT-X · 800NK (US, CRCP) ·
  800NK Advanced · 675NK · 675SR-R · 700MT Adventure · 450MT · 450SR (+ SR-S / TC) ·
  450CL-C / CL-C450 · 450NK · 150SC · CFORCE 850 / 1000 · GOES Terrox 1000 / Gladiator G3 1000.
- **Other brands**: Voge DS800 Rally / DS900X · Moto Morini X-Cape 649 / 700 / Seiemmezzo ·
  Benelli TRK 702 / 702X (Wi-Fi entered by hand, no QR) · Rieju 307 · Zontes 125X ·
  Morbidelli T1002VX / T352X · QJ Motor SRK800RR / SRK450RR / SRK250RD / SRT 600 / SRV600.

If your dash shows the QR, try Connect and share the result. Dashes that join the *phone's*
hotspot (some Zontes / Carbit "action=128") cannot work on iOS: iOS does not let an app create a
hotspot with the name the dash expects.

## How it works

1. **Pair**: scan the dash QR (or type the SSID and password). The QR holds the bike's Wi-Fi; it is
   stored in the iPhone Keychain.
2. **Connect**: the app joins the bike Wi-Fi (`NEHotspotConfiguration`), opens ports 10920–10922,
   sends the probe to `:10930` and the dash connects back to the iPhone. After the handshake
   (`CLIENT_INFO`, RSA signature) the dash pulls frames and the app sends the H.264 video of its own
   UI. Dash touches come back to the app and drive it.
3. **Internet**: the bike Wi-Fi has no internet. Search, routing and tiles use cellular data while
   you are joined to the bike (a data plan is recommended).

**Why not Android Auto or CarPlay?** The Android app relays Android Auto, which is an Android
component: it does not exist on iOS. CarPlay only works with head units certified by Apple (MFi
authentication), and iOS does not let an app capture or forward CarPlay video. So the iOS app draws
**its own navigation UI** for the dash, like the Android "Map" mode.

**Mirror mode**: with the ReplayKit extension you can send **the whole iPhone screen** to the dash
(for another maps app, for example). Dash touches do not drive mirrored apps, the screen must stay
on and the broadcast stops when the phone locks.

## Requirements

- An **iPhone with iOS 17** or later and, to build it yourself, a **Mac with Xcode 16** or later.
  **No Mac**: with a paid account, GitHub builds it and uploads it to TestFlight
  ([docs/TESTFLIGHT.md](docs/TESTFLIGHT.md)).
- An **Apple Developer account**:
  - **Paid** (Apple Developer Program) for the `full` flavor: the app joins the bike Wi-Fi by itself
    (*Hotspot Configuration*) and reads the current SSID (*Access WiFi Information*).
  - **Free** (Personal Team) for the `free` flavor: without those entitlements you join the bike
    Wi-Fi in iOS Settings when the app asks (it shows the network name and copies the password).
    With a free account the app expires after 7 days (reinstall it from Xcode), there is a limit of
    3 apps per device and the mirror extension uses one more App ID.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project.

## Build and install

```sh
brew install xcodegen
git clone https://github.com/Kevinparra535/opencfmoto-ios.git
cd opencfmoto-ios
cp Config/Local.xcconfig.example Config/Local.xcconfig
#   edit Config/Local.xcconfig:
#   DEVELOPMENT_TEAM = <your Team ID>
#   BUNDLE_ID_PREFIX = com.yourname        (a prefix you own)
#   OCM_FLAVOR       = full                (or free with a free account)
xcodegen generate
open OpenCfMoto.xcodeproj
```

In Xcode pick the **OpenCfMoto** scheme and your iPhone, then **Run**. First turn on **Developer
Mode** on the iPhone (Settings ▸ Privacy & Security ▸ Developer Mode; the option appears after the
iPhone has been connected to the Mac with Xcode open). Use the newest Xcode: it must support the iOS
version on your iPhone. If iOS says "Untrusted Developer" (free accounts), trust it in Settings ▸
General ▸ VPN & Device Management. When connecting to the bike, iOS asks for **Local Network** and
**Location** access: allow both, the app cannot talk to the dash or draw the map without them.
`Config/Local.xcconfig` is git-ignored.

For the bike test build it in **Release** (Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Build
Configuration ▸ Release), which runs smoother than Debug. After that you do not need the Mac: open the
app from the Home Screen. With a paid account the install lasts up to a year (7 days with a free one).

### No Mac: TestFlight

With a paid account, the **TestFlight** GitHub Actions workflow builds the app on a cloud Mac, signs
it and uploads it to TestFlight; you install it with the TestFlight app. You only create an App Store
Connect API key, store it as GitHub secrets and do two steps on Apple's website. Step-by-step guide:
[docs/TESTFLIGHT.md](docs/TESTFLIGHT.md#english).

### Demo mode

To try it without a bike (in the **Simulator**, for example), add the `-demo` launch argument
(Xcode ▸ Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments). The app then uses simulated services:
no Wi-Fi or dash, and a demo GPS route so you can watch the dash UI on the phone.

## Known limitations

- **Foreground Ride Mode**: iOS only guarantees the hardware video encoder and the Wi-Fi while the
  app is in the foreground. During a ride keep the app open in **Ride Mode** (black screen, the
  phone does not auto-lock) with the iPhone charging.
- **Locked phone**: iOS does not allow video encoding in the background; the dash keeps a still
  "hold" picture ("Phone locked — unlock to update the map") and the link stays up as long as iOS
  keeps the Wi-Fi, which is not guaranteed while locked.
- **Local Network permission**: iOS asks for it the first time the app looks for the dash; if you
  deny it, turn it on in Settings ▸ OpenCfMoto ▸ Local Network.
- **Handlebar buttons**: they only reach the app that is "playing" (Now Playing). The option is
  experimental and opt-in: it plays silent audio and **pauses other apps' music** while on; not
  every dash sends those buttons; a ★ long press cannot be detected on iOS; the ▲/▼ volume keys only
  work with the experimental option.
- **App Store**: the silent audio for the buttons and the volume observation may not pass Apple's
  review. The **AGPL** is also hard to reconcile with the App Store terms: distributing this app (or
  a derivative) to other people — on the App Store, or through TestFlight external testing or a
  public link — needs permission from the upstream copyright holders. The intended way is to install
  it yourself, with Xcode or with TestFlight internal testing (only you).
- The public OpenStreetMap services (tiles, Photon, Nominatim, Overpass, OSRM, Valhalla) have
  fair-use policies; for heavy use set your own tile server or an OpenRouteService key in Settings.

## Repository layout

```
project.yml                     XcodeGen spec (app + mirror extension)
Config/                         OpenCfMoto.xcconfig (+ your own git-ignored Local.xcconfig)
App/Sources/                    SwiftUI app: screens in UI/<feature>/, iOS services in Services/
App/Resources/                  Resources; Localization/*.json → Localizable.xcstrings (Spanish)
MirrorExtension/                ReplayKit broadcast upload extension (mirror mode)
Packages/OpenCfMotoKit/         Swift package
  Sources/OpenCfMotoCore/         Pure Swift: PXC protocol, link, navigation, dash UI, trips,
                                  settings (builds and is tested on Linux)
  Sources/OpenCfMotoAppModel/     The app's @Observable models (tested on Linux too)
  Sources/OpenCfMotoApple/        Apple adapters: network, Wi-Fi, location, voice, video, tiles
  Tests/                          XCTest suites
docs/ARCHITECTURE.md            Architecture and project rules
docs/spec/                      Behaviour specs extracted from the Android app
docs/TESTFLIGHT.md              No Mac: build and upload to TestFlight from GitHub
.github/workflows/              ci.yml (tests and builds) and testflight.yml (TestFlight)
tools/                          Tooling: translations, CI, simulated dash (fakedash)
  testflight/                     App Store Connect (asc.py), signing and upload, IPA checks
```

## Tests and CI

```sh
swift test --package-path Packages/OpenCfMotoKit
```

The core and the app models (about a thousand tests) run on Linux and macOS. On every push GitHub
Actions (`.github/workflows/ci.yml`) runs the tests on Linux, runs them again on macOS while
compiling the Apple adapters, generates the project with XcodeGen and builds the app for the iOS
Simulator and for iPhone (also with the newest Xcode). It also rehearses the TestFlight pipeline
without credentials: `asc.py` tests against a fake App Store Connect, the signing settings, an
unsigned archive checked by `lint_bundle.py`, the temporary keychain and the clean-up after a
cancel. Translations are merged with `python3 tools/l10n/build_strings.py`.

## Privacy

No accounts, no ads, no telemetry. Bikes, trips and logs stay on the iPhone until you share them;
Wi-Fi passwords live in the Keychain and are redacted in logs. Search, routing and map tiles query
OpenStreetMap services.

## Credits and license

iOS port of **[OpenCfMoto](https://github.com/zanderp/open-cfmoto)**, © 2026 Alexandru and the
OpenCfMoto contributors, built on the open-cfmoto community lineage: dcoletto / coletz (original QR
& EasyConn work), richardbizik (1000 MT-X), ionutradu252 / open-cflink (handlebar controls,
margins, reconnect), eugen0309 (Wi-Fi Direct / CL-C450), Glifaus, sashop2001, Authoritt and
everyone who tested bikes and shared logs. The protocol, dash profiles, navigation, GPX, trips and
settings formats were ported from its Kotlin sources and reverse-engineering notes. No code from
the Android Auto receiver is included.

Free software under the **GNU Affero General Public License v3.0 or later** (see
[LICENSE](LICENSE) and [NOTICE](NOTICE)). If you redistribute a modified version you must offer its
complete source under the same license. Map data © OpenStreetMap contributors (ODbL).

## Disclaimer

Independent community project. Not affiliated with, endorsed by or sponsored by CFMOTO, Carbit,
Apple, Google or any motorcycle brand. CFMOTO, MotoPlay, EasyConn, Carbit, iPhone, CarPlay, Android
Auto and related marks belong to their owners. Use at your own risk: do not rely on it for critical
navigation, set your route before you ride and do not handle the phone while riding.
