# Instalar OpenCfMoto en tu iPhone

*Español primero · [English below](#english)*

OpenCfMoto no está en la App Store. Hay tres formas de instalarla en un iPhone, y una app para Android:

| Camino | Para quién | Coste | Wi-Fi de la moto | Dura |
|---|---|---|---|---|
| [A. IPA de prueba con tu Apple ID gratuito](#a-ipa-de-prueba-con-tu-apple-id-gratuito) | Cualquiera con un computador (Windows, Mac o Linux) | Gratis | Te unes tú desde Ajustes | 7 días, y se renueva |
| [B. Tu propia copia con TestFlight](#b-tu-propia-copia-completa-cuenta-de-pago-sin-mac) | Quien quiere todo y no tiene Mac | 99 USD al año | La app se une sola | 90 días por compilación |
| [C. Xcode en un Mac](#c-desarrolladores-xcode) | Desarrolladores | Gratis o de pago | Según la cuenta | 7 días o un año |
| [Android](#tienes-android) | Teléfonos Android | Gratis | La app original | — |

Sin moto también puedes probarla: en el iPhone, **Inicio ▸ Vista de tablero** dibuja la pantalla del
tablero sin tablero, con tu GPS real.

## A. IPA de prueba con tu Apple ID gratuito

Cada versión publicada en [Releases](https://github.com/Kevinparra535/opencfmoto-ios/releases) trae
`OpenCfMoto-vX.Y.Z-sideload.ipa`: la app sin firmar a nombre de nadie. Una herramienta de instalación
(SideStore, AltStore Classic o Sideloadly) la firma **con tu propio Apple ID** y la instala en tu
iPhone. Es la variante «free» de la app: la misma, salvo que no puede unirse sola al Wi-Fi (ver
[Qué no funciona en esta versión](#qué-no-funciona-en-esta-versión)).

### Antes de empezar

- Un iPhone con **iOS 17** o posterior.
- Un computador con **Windows o Mac** (Linux solo sirve para el instalador de SideStore). Con
  SideStore lo necesitas una vez; con AltStore, cuando renueva; con Sideloadly, cada semana.
- Un **Apple ID gratuito**. Mejor uno secundario, solo para esto, con la verificación en dos pasos
  activada. OpenCfMoto nunca te pide tu Apple ID: solo lo usa la herramienta de instalación, para
  firmar la app a tu nombre.
- Descarga el IPA **solo** desde la página de
  [Releases](https://github.com/Kevinparra535/opencfmoto-ios/releases) de este repositorio y
  [comprueba su SHA-256](#comprobar-el-sha-256) antes de instalarlo.
- Las herramientas cambian con cada versión de iOS. Antes de instalar, mira en su web oficial si
  funcionan con la tuya: [SideStore](https://sidestore.io), [AltStore](https://altstore.io),
  [Sideloadly](https://sideloadly.io). No uses servicios de firma de pago, certificados «enterprise» ni
  webs que redistribuyen IPA: no son legítimos y son un riesgo para tu cuenta y tu iPhone.

### Opción 1: SideStore (sin computador después de instalarla)

1. En el computador, instala el instalador de SideStore siguiendo su
   [guía oficial](https://sidestore.io).
2. En el iPhone, instala **LocalDevVPN** desde la App Store, ábrela y pulsa *Connect*.
3. Conecta el iPhone al computador por cable y acepta «Confiar en este ordenador». En el instalador,
   inicia sesión con tu Apple ID, instala SideStore y copia el *pairing file* a SideStore, como indica
   la guía.
4. En el iPhone, activa **Ajustes ▸ Privacidad y seguridad ▸ Modo de desarrollador** (el iPhone se
   reinicia). Después ve a **Ajustes ▸ General ▸ VPN y gestión de dispositivos**, toca tu Apple ID y
   pulsa **Confiar**.
5. En SideStore, ve a *Sources* ▸ **+** y pega esta dirección:

   ```
   https://github.com/Kevinparra535/opencfmoto-ios/releases/latest/download/altstore-source.json
   ```

   Después instala OpenCfMoto desde esa fuente. También puedes ir a *My Apps* ▸ **+** y elegir el
   `.ipa` que descargaste.
6. Cada 7 días, antes de que caduque: conecta LocalDevVPN y pulsa SideStore ▸ *My Apps* ▸
   **Refresh All**.

### Opción 2: AltStore Classic (Windows o Mac)

1. Instala **AltServer** en el computador siguiendo la guía oficial de
   [altstore.io](https://altstore.io) (en Windows indica qué versiones de iTunes e iCloud hacen falta).
2. Conecta el iPhone por cable y elige AltServer ▸ *Install AltStore* ▸ tu iPhone ▸ tu Apple ID.
3. Activa el Modo de desarrollador y confía en tu Apple ID, como en la opción 1 (paso 4).
4. En AltStore, ve a *Browse* (o *Sources*) ▸ **+**, pega la misma dirección de la opción 1 e instala
   OpenCfMoto. También puedes ir a *My Apps* ▸ **+** y elegir el `.ipa`.
5. AltStore renueva las apps sola mientras el computador con AltServer está encendido en el mismo
   Wi-Fi. También puedes abrir AltStore y pulsar **Refresh All**.

### Opción 3: Sideloadly (Windows o Mac, la más directa)

1. Instala Sideloadly desde su web oficial, [sideloadly.io](https://sideloadly.io), y conecta el iPhone
   por cable.
2. Arrastra el `.ipa` a Sideloadly, escribe tu Apple ID y pulsa **Start**.
3. Activa el Modo de desarrollador y confía en tu Apple ID, como en la opción 1 (paso 4).
4. Repite la instalación cada 7 días, con el mismo Apple ID.

Si la herramienta te ofrece quitar las extensiones de la app, di que no si quieres probar el modo
espejo: la extensión «OpenCfMoto Mirror» es la que duplica la pantalla.

### Al abrir OpenCfMoto

1. Permite la **ubicación** («Al usar la app», con ubicación exacta), la **cámara** (para el QR) y la
   **red local** (cuando conectes con la moto). Sin ellos la app no puede hablar con el tablero ni
   dibujar el mapa.
2. Empareja tu moto: **Inicio ▸ Escanear** y apunta al QR del tablero.
3. Pulsa **Conectar**. Esta versión no puede unirse sola al Wi-Fi de la moto, así que te muestra el
   nombre de la red y copia la contraseña. Abre **Ajustes ▸ Wi-Fi**, elige la red de la moto, pega la
   contraseña y vuelve a OpenCfMoto: sigue sola, o toca **«Ya me he conectado»**.

Para la primera salida sigue [PRUEBA-EN-LA-MOTO.md](PRUEBA-EN-LA-MOTO.md) (sáltate la parte de Xcode:
la app ya está instalada). Fija la ruta antes de salir.

### Qué no funciona en esta versión

- **No se une sola al Wi-Fi de la moto.** Unirse a una red desde una app (*Hotspot Configuration*)
  necesita una cuenta de pago de Apple Developer. Te unes tú en Ajustes, como arriba.
- **No puede leer el nombre de la red Wi-Fi** a la que estás conectado (*Access WiFi Information*,
  también de pago). La app reconoce la red de la moto por su dirección.
- **El modo espejo puede no estar disponible.** Con SideStore y AltStore debería funcionar si
  conservas la extensión: al firmar cambian el nombre del App Group que comparten la app y la
  extensión, y esta versión lo detecta. Con Sideloadly no está comprobado. El modo normal (el mapa de
  OpenCfMoto en el tablero) no depende de esto.
- **Caduca a los 7 días** si no la renuevas, como toda app firmada con un Apple ID gratuito.
- Con un Apple ID gratuito caben **como máximo 3 apps** instaladas así en el iPhone (SideStore o
  AltStore cuentan como una), y se pueden registrar 10 identificadores de app cada 7 días
  (OpenCfMoto usa 2: la app y la extensión de espejo).
- Si cambias de Apple ID, vuelve a escanear el QR de la moto: las contraseñas guardadas van ligadas
  a la firma.

### Actualizar

Con la fuente de la opción 1, SideStore y AltStore te avisan cuando hay una versión nueva. Si no,
descarga el IPA nuevo de [Releases](https://github.com/Kevinparra535/opencfmoto-ios/releases) e
instálalo encima, con la misma herramienta y el mismo Apple ID, para conservar tus ajustes.

### Comprobar el SHA-256

Cada release trae `SHA256SUMS.txt` con la huella del IPA (también aparece en la página de la
release). Calcula la del archivo que descargaste y compara las dos: tienen que ser idénticas.

- **Mac:** `shasum -a 256 OpenCfMoto-vX.Y.Z-sideload.ipa`
- **Windows** (PowerShell o Símbolo del sistema): `certutil -hashfile OpenCfMoto-vX.Y.Z-sideload.ipa SHA256`
- **Linux:** `sha256sum OpenCfMoto-vX.Y.Z-sideload.ipa`

Con `SHA256SUMS.txt` en la misma carpeta, en Mac o Linux basta `shasum -a 256 -c SHA256SUMS.txt` (o
`sha256sum -c SHA256SUMS.txt`): debe decir `OK`.

El IPA lo compila GitHub Actions a partir de este código público
([.github/workflows/release.yml](../.github/workflows/release.yml)), sin certificado ni equipo de
Apple: solo lleva una firma *ad hoc* con el App Group, para que tu herramienta pueda firmarla a tu
nombre. Las notas de cada release enlazan la ejecución que lo compiló.

## B. Tu propia copia completa (cuenta de pago, sin Mac)

Con una cuenta de pago la app se une sola al Wi-Fi, lee el nombre de la red y el modo espejo
funciona. No hace falta Mac: GitHub la compila en la nube y la sube a **tu** TestFlight.

- **Coste:** el Apple Developer Program, 99 USD al año. La inscripción (en developer.apple.com o en la
  app Apple Developer) suele tardar de 1 a 2 días, a veces más.
- **Tiempo:** cerca de una hora la primera vez, casi todo de espera.
- **Duración:** cada compilación dura 90 días en TestFlight; después lanzas otra.

Pasos:

1. Haz un *fork* de este repositorio en GitHub y activa los workflows en la pestaña **Actions** de tu
   fork.
2. Sigue [TESTFLIGHT.md](TESTFLIGHT.md): la clave de la API de App Store Connect (de administrador) y
   sus 3 secretos, «Solo preparar», el App Group en los 2 identificadores, la app en App Store Connect,
   y después *Run workflow*.
3. Instala OpenCfMoto con la app TestFlight, con el mismo Apple ID de tu cuenta de desarrollador.

Esa copia es solo para ti (pruebas internas de TestFlight).

## C. Desarrolladores: Xcode

Con un Mac sigue [Compilar e instalar](../README.md#compilar-e-instalar) en el README. Con una cuenta
gratuita (*Personal Team*) pon `OCM_FLAVOR = free` en `Config/Local.xcconfig`: es la misma variante
que el IPA de la opción A. También puedes lanzar **Actions ▸ Release (sideload IPA) ▸ Run workflow**
en tu fork: deja el IPA y su fuente de AltStore como artefacto de la ejecución.

## ¿Tienes Android?

Usa la app original, **OpenCfMoto para Android**, de Alexandru Popa (zanderp):
[github.com/zanderp/open-cfmoto/releases/latest](https://github.com/zanderp/open-cfmoto/releases/latest).
Descarga `OpenCfMoto.apk` (o `OpenCfMoto.armv7.apk` si Android dice que no es compatible) desde esa
página y sigue su README, también para Android Auto. Aquí no se publican APK: usa siempre su página.

## Licencia y código fuente

OpenCfMoto para iOS es software libre bajo la **GNU AGPL v3 o posterior** ([LICENSE](../LICENSE),
[NOTICE](../NOTICE)), y se ofrece **sin ninguna garantía**. Es un port de OpenCfMoto (Android), de
Alexandru Popa (zanderp) y la comunidad open-cfmoto.

Cada IPA se publica junto a su código fuente correspondiente: la etiqueta `vX.Y.Z` de la release es
exactamente el commit con el que se compiló, y GitHub ofrece su «Source code» (zip y tar.gz) en la
misma página, con `LICENSE.txt` y `NOTICE.txt`. Ese código sigue disponible mientras se ofrezca el
IPA. Si modificas la app y la distribuyes, tienes que ofrecer tu código fuente bajo la misma licencia.

## Avisos

- Proyecto comunitario independiente, sin afiliación con CFMOTO, Carbit, Apple, Google ni ninguna
  marca de motos. Las marcas pertenecen a sus dueños.
- Software experimental que se ofrece **sin ninguna garantía**: lo usas bajo tu propia
  responsabilidad.
- **Nunca manipules el teléfono ni la app mientras conduces.** Fija la ruta antes de salir, usa un
  soporte seguro, cumple las normas de tránsito y no dependas de la app para una navegación crítica.
- Descarga el IPA solo desde la página de Releases de este repositorio y comprueba su SHA-256.

---

## English

OpenCfMoto is not on the App Store. There are three ways to install it on an iPhone, and an app for
Android:

| Path | For | Cost | Bike Wi-Fi | Lasts |
|---|---|---|---|---|
| [A. Sideload IPA with your free Apple ID](#a-sideload-ipa-with-your-free-apple-id) | Anyone with a computer (Windows, Mac or Linux) | Free | You join it in Settings | 7 days, then refresh |
| [B. Your own TestFlight copy](#b-your-own-full-copy-paid-account-no-mac) | Riders who want everything and have no Mac | 99 USD a year | The app joins by itself | 90 days per build |
| [C. Xcode on a Mac](#c-developers-xcode) | Developers | Free or paid | Depends on the account | 7 days or a year |
| [Android](#on-android) | Android phones | Free | The original app | — |

No bike? On the iPhone, **Home ▸ Dash view** draws the dash picture without a dash, with your real
GPS.

### A. Sideload IPA with your free Apple ID

Every release on the [Releases](https://github.com/Kevinparra535/opencfmoto-ios/releases) page carries
`OpenCfMoto-vX.Y.Z-sideload.ipa`: the app, signed for nobody. An install tool (SideStore, AltStore
Classic or Sideloadly) signs it **with your own Apple ID** and installs it on your iPhone. It is the
app's "free" flavour: the same app, except that it cannot join Wi-Fi networks by itself (see
[What does not work in this build](#what-does-not-work-in-this-build)).

#### Before you start

- An iPhone with **iOS 17** or later.
- A **Windows or Mac** computer (Linux only works for SideStore's installer). You need it once with
  SideStore, whenever AltStore refreshes, and every week with Sideloadly.
- A **free Apple ID**. A secondary one, just for this, with two-factor authentication, is best.
  OpenCfMoto never asks for your Apple ID: only the install tool uses it, to sign the app for you.
- Download the IPA **only** from this repository's
  [Releases](https://github.com/Kevinparra535/opencfmoto-ios/releases) page, and
  [check its SHA-256](#check-the-sha-256) before installing it.
- The tools change with every iOS version. Before installing, check on their official site that they
  work with yours: [SideStore](https://sidestore.io), [AltStore](https://altstore.io),
  [Sideloadly](https://sideloadly.io). Do not use paid signing services, "enterprise" certificates or
  sites that rehost IPAs: they are not legitimate and put your account and your iPhone at risk.

#### Option 1: SideStore (no computer after the setup)

1. On the computer, install SideStore's installer following its [official guide](https://sidestore.io).
2. On the iPhone, install **LocalDevVPN** from the App Store, open it and tap *Connect*.
3. Connect the iPhone to the computer by cable and accept "Trust This Computer". In the installer,
   sign in with your Apple ID, install SideStore and copy the *pairing file* to SideStore, as the guide
   says.
4. On the iPhone, turn on **Settings ▸ Privacy & Security ▸ Developer Mode** (the iPhone restarts).
   Then go to **Settings ▸ General ▸ VPN & Device Management**, tap your Apple ID and tap **Trust**.
5. In SideStore, go to *Sources* ▸ **+** and paste this address:

   ```
   https://github.com/Kevinparra535/opencfmoto-ios/releases/latest/download/altstore-source.json
   ```

   Then install OpenCfMoto from that source. You can also go to *My Apps* ▸ **+** and pick the `.ipa`
   you downloaded.
6. Every 7 days, before it expires: connect LocalDevVPN and tap SideStore ▸ *My Apps* ▸ **Refresh
   All**.

#### Option 2: AltStore Classic (Windows or Mac)

1. Install **AltServer** on the computer following the official guide at
   [altstore.io](https://altstore.io) (on Windows it says which iTunes and iCloud versions you need).
2. Connect the iPhone by cable and choose AltServer ▸ *Install AltStore* ▸ your iPhone ▸ your Apple ID.
3. Turn on Developer Mode and trust your Apple ID, as in option 1 (step 4).
4. In AltStore, go to *Browse* (or *Sources*) ▸ **+**, paste the same address as in option 1 and install
   OpenCfMoto. You can also go to *My Apps* ▸ **+** and pick the `.ipa`.
5. AltStore refreshes its apps by itself while the computer running AltServer is on the same Wi-Fi.
   You can also open AltStore and tap **Refresh All**.

#### Option 3: Sideloadly (Windows or Mac, the most direct)

1. Install Sideloadly from its official site, [sideloadly.io](https://sideloadly.io), and connect the
   iPhone by cable.
2. Drop the `.ipa` into Sideloadly, enter your Apple ID and press **Start**.
3. Turn on Developer Mode and trust your Apple ID, as in option 1 (step 4).
4. Install it again every 7 days, with the same Apple ID.

If a tool offers to remove the app's extensions, say no if you want to try mirror mode: the
"OpenCfMoto Mirror" extension is the one that mirrors the screen.

#### First run

1. Allow **Location** ("While Using the App", with Precise Location), the **Camera** (for the QR) and
   the **Local Network** (when you connect to the bike). Without them the app cannot talk to the dash
   or draw the map.
2. Pair your bike: **Home ▸ Scan** and point the camera at the dash QR.
3. Tap **Connect**. This build cannot join the bike Wi-Fi by itself, so it shows the network name and
   copies the password. Open **Settings ▸ Wi-Fi**, pick the bike's network, paste the password and
   come back to OpenCfMoto: it carries on by itself, or tap **"I've joined"**.

For the first ride, follow [PRUEBA-EN-LA-MOTO.md](PRUEBA-EN-LA-MOTO.md) (in Spanish; skip the Xcode
part: the app is already installed). Set the route before you ride.

#### What does not work in this build

- **It does not join the bike Wi-Fi by itself.** Joining a network from an app (*Hotspot
  Configuration*) needs a paid Apple Developer account. You join it in Settings, as above.
- **It cannot read the name of the Wi-Fi network** you are on (*Access WiFi Information*, also paid
  only). The app recognises the bike's network by its address.
- **Mirror mode may be unavailable.** With SideStore and AltStore it should work if you keep the
  extension: they rename the App Group the app and the extension share when they sign them, and this
  build follows the new name. With Sideloadly it is untested. Normal mode (the OpenCfMoto map on the
  dash) does not depend on it.
- **It expires after 7 days** unless refreshed, like every app signed with a free Apple ID.
- A free Apple ID fits **at most 3 apps** installed this way on the iPhone (SideStore or AltStore counts
  as one), and can register 10 app identifiers every 7 days (OpenCfMoto uses 2: the app and the mirror
  extension).
- If you switch Apple ID, scan the bike's QR again: saved passwords are tied to the signature.

#### Updating

With the source from option 1, SideStore and AltStore tell you when a new version is out. Otherwise
download the new IPA from [Releases](https://github.com/Kevinparra535/opencfmoto-ios/releases) and
install it over the old one, with the same tool and the same Apple ID, to keep your settings.

#### Check the SHA-256

Every release carries `SHA256SUMS.txt` with the IPA's fingerprint (the release page shows it too).
Compute the fingerprint of the file you downloaded and compare the two: they must be identical.

- **Mac:** `shasum -a 256 OpenCfMoto-vX.Y.Z-sideload.ipa`
- **Windows** (PowerShell or Command Prompt): `certutil -hashfile OpenCfMoto-vX.Y.Z-sideload.ipa SHA256`
- **Linux:** `sha256sum OpenCfMoto-vX.Y.Z-sideload.ipa`

With `SHA256SUMS.txt` in the same folder, on Mac or Linux `shasum -a 256 -c SHA256SUMS.txt` (or
`sha256sum -c SHA256SUMS.txt`) is enough: it must say `OK`.

GitHub Actions builds the IPA from this public code
([.github/workflows/release.yml](../.github/workflows/release.yml)) with no Apple certificate or team:
it only carries an ad-hoc signature with the App Group, so that your tool can sign it for you. Each
release's notes link the run that built it.

### B. Your own full copy (paid account, no Mac)

With a paid account the app joins the Wi-Fi by itself, reads the network name, and mirror mode works.
No Mac needed: GitHub builds it in the cloud and uploads it to **your** TestFlight.

- **Cost:** the Apple Developer Program, 99 USD a year. Enrolment (on developer.apple.com or in the
  Apple Developer app) usually takes 1 to 2 days, sometimes longer.
- **Time:** about an hour the first time, mostly waiting.
- **Lifetime:** each build lasts 90 days in TestFlight; then you start another.

Steps:

1. Fork this repository on GitHub and enable workflows in your fork's **Actions** tab.
2. Follow [TESTFLIGHT.md](TESTFLIGHT.md#english): the App Store Connect API key (Admin) and its 3
   secrets, "Solo preparar" (setup only), the App Group on both identifiers, the app record in App Store
   Connect, then *Run workflow*.
3. Install OpenCfMoto with the TestFlight app, signed in with your developer account's Apple ID.

That copy is for you only (TestFlight internal testing).

### C. Developers: Xcode

With a Mac, follow [Build and install](../README.md#build-and-install) in the README. With a free
account (*Personal Team*) set `OCM_FLAVOR = free` in `Config/Local.xcconfig`: the same flavour as the
option A IPA. You can also run **Actions ▸ Release (sideload IPA) ▸ Run workflow** in your fork: it
leaves the IPA and its AltStore source as the run's artifact.

### On Android?

Use the original app, **OpenCfMoto for Android**, by Alexandru Popa (zanderp):
[github.com/zanderp/open-cfmoto/releases/latest](https://github.com/zanderp/open-cfmoto/releases/latest).
Download `OpenCfMoto.apk` (or `OpenCfMoto.armv7.apk` if Android says it is not compatible) from that
page and follow its README, Android Auto included. No APKs are published here: always use its page.

### License and source code

OpenCfMoto for iOS is free software under the **GNU AGPL v3 or later** ([LICENSE](../LICENSE),
[NOTICE](../NOTICE)), and comes with **no warranty**. It is a port of OpenCfMoto (Android) by
Alexandru Popa (zanderp) and the open-cfmoto community.

Every IPA is published next to its Corresponding Source: the release's `vX.Y.Z` tag is exactly the
commit it was built from, and GitHub offers its "Source code" (zip and tar.gz) on the same page,
together with `LICENSE.txt` and `NOTICE.txt`. That source stays available for as long as the IPA is
offered. If you modify the app and distribute it, you must offer your source code under the same
license.

### Disclaimers

- Independent community project, not affiliated with CFMOTO, Carbit, Apple, Google or any motorcycle
  brand. Trademarks belong to their owners.
- Experimental software with **no warranty**: use it at your own risk.
- **Never handle the phone or the app while riding.** Set the route before you go, use a secure
  mount, obey traffic law and do not rely on the app for critical navigation.
- Only download the IPA from this repository's Releases page, and check its SHA-256.
