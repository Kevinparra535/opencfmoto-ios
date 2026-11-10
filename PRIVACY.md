# Privacidad · Privacy

*Español primero · [English below](#english)*

Última actualización: 9 de noviembre de 2026. Esta página describe lo que hace la app de iPhone
**OpenCfMoto para iOS** según el código de este repositorio: la beta pública de TestFlight, la versión
para sideload de [Releases](https://github.com/Kevinparra535/opencfmoto-ios/releases), las copias de
TestFlight que cada persona compila para sí y las que se compilan con Xcode.

## En resumen

- **Sin cuentas, sin anuncios, sin telemetría ni analítica, sin rastreo.** La app no lleva SDK de
  terceros (ni de analítica ni de publicidad) y OpenCfMoto no tiene servidor propio: la app no nos envía
  nada de tu iPhone. La excepción es TestFlight, de Apple: con la beta pública, TestFlight nos muestra
  los fallos y el uso de la app y los comentarios que envíes, sin tu nombre ni tu correo (salvo el correo
  que escribas en un comentario; ver [Si la instalas con TestFlight](#si-la-instalas-con-testflight)).
- **Tus datos se quedan en tu iPhone** (motos, viajes, lugares, registros) hasta que tú los compartes.
- **El mapa, las búsquedas, las rutas y los límites de velocidad** salen de servicios públicos basados
  en OpenStreetMap y, en las pantallas del iPhone, de Apple. Ven tu dirección IP y lo que se les pide,
  que incluye posiciones (detalle abajo).

## Lo que se queda en tu iPhone

Todo esto se guarda solo en tu iPhone. Las motos, viajes, lugares, ajustes y registros entran en las
copias de seguridad del iPhone (iCloud o el computador) si las usas; las teselas del mapa y los archivos
para compartir (también las grabaciones del tablero), no. La contraseña Wi-Fi va en el llavero, solo en
este iPhone: no pasa a otro iPhone ni al llavero de iCloud, e iOS puede conservarla aunque borres la app.
Para borrarla, quita la moto en Garaje («Eliminar moto») antes de borrar la app; lo demás se borra con
la app.

- **Tus motos** (Garaje): nombre, modelo, nombre de la red Wi-Fi de la moto y lo que el tablero cuenta de
  sí mismo (modelo, número de serie). La **contraseña Wi-Fi** de cada moto va en el llavero (Keychain)
  de iOS, solo en este iPhone (no se sincroniza con el llavero de iCloud). La foto de la moto, si eliges
  una.
- **Tus viajes**: los que se registran solos con «Registrar viajes automáticamente» (activado de
  fábrica, mientras el tablero muestra el mapa) y los que grabas tú con «Empezar a grabar» (o con
  «Grabar la ruta» en el tablero): el recorrido GPS, la distancia, las velocidades y las horas de cada
  uno.
- **Tus lugares**: casa, favoritos, marcadores, los últimos destinos y dónde aparcaste.
- **Tus ajustes**, con tu servidor de mapas y tu clave de openrouteservice si los pones.
- **Los registros** (Registros): lo que hace la app (pasos de la conexión, errores, el modelo del
  tablero, el nombre de la red Wi-Fi de la moto, los nombres de los destinos y, a veces, una posición).
  Una copia, sin contraseñas ni números de serie, se guarda al pasar la app a segundo plano (y cada medio
  minuto mientras está conectada) para no perderla si iOS la cierra; el siguiente arranque la recupera y
  la borra. Si iOS entrega a la app el informe de un cierre inesperado (MetricKit), la app lo guarda con
  los registros.
- **Las grabaciones del tablero** (Registros ▸ Diagnóstico del enlace ▸ «Grabar el video enviado al
  tablero»): el vídeo que recibe el tablero: el mapa alrededor de ti o, en el modo Espejo, todo lo que
  muestra la pantalla del iPhone (también otras apps y avisos). Se borran en el siguiente arranque.
- **Las teselas del mapa** que ya se descargaron (hasta 512 MB, cada una caduca a los 90 días).
- **Los archivos que preparas para compartir** (GPX, registros, ajustes y datos de mapa; estos últimos
  llevan tu casa, tus lugares y dónde aparcaste): se borran solos poco después (al pasar la app a segundo
  plano, los que tienen más de 2 minutos) y en el siguiente arranque.

## Permisos y para qué

- **Cámara**: escanear el código QR de emparejamiento que muestra el tablero. Solo mientras el escáner
  está abierto; no se guardan fotos.
- **Fotos**: ningún permiso. El selector de fotos de iOS le da a la app solo la foto que eliges (la de tu
  moto, o una foto del QR).
- **Ubicación** («Al usar la app», ubicación exacta): el mapa, la navegación giro a giro, la velocidad,
  los límites de velocidad y los viajes. Con el iPhone bloqueado la app la sigue usando solo mientras
  está conectada al tablero, graba un viaje o navega; iOS muestra entonces el indicador azul de
  ubicación. La app nunca pide «Siempre».
- **Red local**: encontrar el tablero en el Wi-Fi de la moto y enviarle el mapa.
- **Multimedia y Apple Music** (solo si activas Apple Music en el tablero, en Ajustes): leer la canción
  que suena en la app Música (título, artista y portada) y controlarla desde el tablero. Las canciones no
  aparecen en los registros: cada una sale como un código que cambia en cada arranque.
- **Wi-Fi** (solo en las copias de TestFlight o Xcode con cuenta de pago): unirse sola al Wi-Fi de la
  moto y leer el nombre de la red Wi-Fi actual. La versión para sideload no puede hacer ninguna de las
  dos cosas.
- **Audio en segundo plano** (no es un permiso): los avisos de voz y, solo si activas los botones del
  manillar, un audio silencioso para recibirlos. La app no usa el micrófono.
- **Grabación de pantalla** (no es un permiso): la transmisión del modo Espejo, que inicias tú.

## Servicios en línea que usa la app

La app se conecta directamente desde tu iPhone a estos servicios (por los datos móviles mientras estás
unido al Wi-Fi de la moto, que no tiene internet). Cada uno ve tu **dirección IP** y la hora de la
petición, y tiene su propia política de privacidad. A los servicios de mapas la app se presenta como
`OpenCfMoto-iOS/<versión> (moto dash map; +https://github.com/Kevinparra535/opencfmoto-ios)`
(User-Agent), como piden sus normas de uso; no añade ningún identificador tuyo ni de tu iPhone.

| Servicio | Para qué | Qué recibe |
|---|---|---|
| tile.openstreetmap.org (Fundación OpenStreetMap), o el servidor de teselas que pongas en Ajustes | El mapa del tablero y de la Vista de tablero | Las coordenadas de las teselas que muestra el mapa, es decir, la zona en la que estás y la de tu ruta. Con tu propio servidor, también las de la ruta por delante (como máximo 400); a los servidores de OpenStreetMap no se les piden por adelantado. |
| Photon, photon.komoot.io (komoot); si falla o no hay posición, Nominatim, nominatim.openstreetmap.org (Fundación OpenStreetMap) | Buscar lugares y direcciones | El texto que escribes, mientras lo escribes (desde 2 letras), y tu posición **redondeada a 2 decimales** (cerca de 1 km). |
| Overpass API, overpass-api.de (FOSSGIS e.V.) | Lugares cercanos (gasolina, café, comida…) | La categoría y tu posición **redondeada a 3 decimales** (cerca de 100 m). |
| Overpass API, overpass-api.de (FOSSGIS e.V.) | El límite de velocidad de la vía | Mientras la app recibe tu GPS, tu **posición exacta**, como mucho una vez cada 12 segundos (y una vez cada 10 minutos por cada zona de unos 100 m). |
| Valhalla, valhalla1.openstreetmap.de (FOSSGIS e.V.) y OSRM, router.project-osrm.org (servidor de demostración del proyecto OSRM) | Calcular rutas | El origen (tu **posición exacta**), el destino, los puntos intermedios de las rutas alternativas o de ida y vuelta, y si evitar peajes o autovías. Al recalcular, tu posición de nuevo. |
| openrouteservice, api.openrouteservice.org (HeiGIT), **solo si pones tu propia clave** en Ajustes | Calcular rutas: primero las que evitan peajes o autovías, y de reserva si los otros fallan | Lo mismo que los de arriba, y tu clave. |
| Apple Maps (MapKit), de Apple | El mapa de las pantallas Mapa y Viajes del iPhone | Lo que iOS pide a Apple para dibujar ese mapa (la zona que muestras). |
| Apple Music (MusicKit), de Apple, solo con Apple Music en el tablero | La portada de una canción en streaming que no trae la suya | La petición de esa portada a los servidores de Apple. |

**El tablero de la moto** no es un servicio de internet: la app le habla por el Wi-Fi de la moto y le
envía el vídeo del mapa (con la canción, si activaste Apple Music en el tablero). Para enlazar le envía lo
que pide su protocolo: «Apple» y el modelo de tu iPhone (o la marca y el modelo de un teléfono Android si
activas «Identificarse como teléfono Android»), un identificador y una clave de firma que la app crea de
nuevo en cada arranque.

En el modo Espejo («Duplicar toda la pantalla del iPhone»), iOS da a la extensión OpenCfMoto Mirror la
imagen de la pantalla solo mientras dura la transmisión que tú inicias (la extensión no usa el sonido);
iOS muestra el indicador rojo. La app la envía al tablero por el Wi-Fi de la moto: no se guarda (salvo
que actives la grabación) ni sale a internet.

Fuera de estos servicios y del tablero, la app no se conecta a nada: ni a GitHub ni a ningún servidor
nuestro. Los enlaces de la pantalla Acerca de se abren en Safari solo si los tocas.

## Registros e informes de problemas

Los registros y los informes de problemas salen del iPhone **solo si tú los compartes** (con el menú de
compartir de iOS: eliges la app y a quién). Antes de compartirlos, la app quita las contraseñas Wi-Fi
(también las que van dentro de un código QR de emparejamiento), los números de serie e identificadores
del tablero y las claves de API en las direcciones de servidores de mapas, salvo que actives
**Ajustes ▸ Privacidad y registros ▸ «Incluir secretos en registros compartidos»**. El nombre de la red
Wi-Fi de la moto, los modelos y los nombres de los destinos sí quedan: léelos antes de publicarlos.
Si vas a adjuntar registros a una incidencia pública de GitHub, quita también las ubicaciones.

iOS puede enviar a Apple sus propios datos de diagnóstico si lo permitiste en Ajustes ▸ Privacidad y
seguridad ▸ Análisis y mejoras. Eso lo hace iOS, no la app, y a nosotros no nos llega; con la beta de
TestFlight, los fallos sí nos llegan por TestFlight (ver
[Si la instalas con TestFlight](#si-la-instalas-con-testflight)).

## Si la instalas con TestFlight

TestFlight es un servicio de Apple, con su propio aviso de privacidad:
[TestFlight & Privacy](https://www.apple.com/legal/privacy/data/en/test-flight/) (en inglés). Mientras
pruebas la beta pública, Apple recoge estos datos de la prueba y nos los muestra en App Store Connect, su
web para quien publica la beta:

- **Los fallos:** el informe de cada cierre inesperado de la app y, si TestFlight te ofrece contar qué
  pasó y lo escribes, también ese comentario.
- **El uso:** si la instalaste y cuándo, cuántas veces la usas (sesiones), cuántos fallos tuvo, el modelo
  de tu iPhone y su versión de iOS.
- **Tus comentarios:** lo que envíes desde TestFlight o con una captura de pantalla hecha en la app (el
  texto y las capturas). Una captura muestra todo lo que haya en la pantalla (por ejemplo, el mapa con tu
  ubicación o el nombre del Wi-Fi de la moto): revísala antes de enviarla.
- **Datos del iPhone en ese momento**, con cada comentario y cada aviso de fallo que envíes: modelo,
  versión de iOS, idioma y región, zona horaria, operador, tipo de conexión (Wi-Fi o datos móviles),
  batería, espacio libre, resolución de pantalla, arquitectura y cuánto tiempo llevaba abierta la app.

Con el enlace público no vemos tu nombre ni tu correo: en App Store Connect apareces como anónimo. Si
escribes tu correo al enviar un comentario, lo vemos solo en ese comentario. Si envías un comentario por
correo desde TestFlight, vemos la dirección desde la que lo envías. Lo que Apple hace con estos datos lo
explica su aviso.

OpenCfMoto no añade nada a esto: la app sigue sin enviarnos datos; esto lo recoge TestFlight, no el
código de la app. Con la versión para sideload o con Xcode no pasa, y en tu propia copia de TestFlight
(un *fork*) estos datos te llegan a ti, no a nosotros.

Para dejar de compartirlos, sal de la beta: en TestFlight, abre OpenCfMoto, toca «Dejar de probar»
(*Stop Testing*) y después borra la app. Lo que ya se envió sigue el aviso de privacidad de TestFlight.

## Contacto

Dudas o problemas: una [incidencia en GitHub](https://github.com/Kevinparra535/opencfmoto-ios/issues/new/choose).
Fallos de seguridad: en privado, como explica [SECURITY.md](SECURITY.md). Los cambios de esta página quedan
en el historial del repositorio.

---

## English

Last updated: November 9, 2026. This page describes what the **OpenCfMoto for iOS** iPhone app does,
according to the code in this repository: the public TestFlight beta, the sideload build from
[Releases](https://github.com/Kevinparra535/opencfmoto-ios/releases), the TestFlight copies each person
builds for themselves, and builds made with Xcode.

### In short

- **No accounts, no ads, no telemetry or analytics, no tracking.** The app contains no third-party SDKs
  (no analytics, no advertising), and OpenCfMoto has no server of its own: the app sends us nothing from
  your iPhone. The exception is Apple's TestFlight: with the public beta, TestFlight shows us the app's
  crashes and usage and the feedback you send, without your name or e-mail (unless you type your e-mail
  in your feedback; see [If you install it with TestFlight](#if-you-install-it-with-testflight)).
- **Your data stays on your iPhone** (bikes, trips, places, logs) until you share it.
- **The map, search, routing and speed limits** come from public OpenStreetMap-based services and, on
  the iPhone's own screens, from Apple. They see your IP address and what is asked of them, which
  includes positions (details below).

### What stays on your iPhone

All of this is kept only on your iPhone. Bikes, trips, places, settings and logs are part of your
iPhone's backups (iCloud or a computer) if you use them; map tiles and files prepared for sharing (dash
recordings included) are not. The Wi-Fi password is in the Keychain, on this iPhone only: it does not move
to another iPhone or to iCloud Keychain, and iOS may keep it even after you delete the app. To erase it,
remove the bike in Garage ("Remove bike") before deleting the app; everything else is deleted with the
app.

- **Your bikes** (Garage): name, model, the bike's Wi-Fi network name and what the dash reports about
  itself (model, serial number). Each bike's **Wi-Fi password** is kept in the iOS Keychain, on this
  iPhone only (it does not sync to iCloud Keychain). The bike photo, if you choose one.
- **Your trips**: those logged by themselves with "Log trips automatically" (on by default, while the
  dash shows the map) and those you record with "Start recording" (or with "Record ride" on the dash):
  the GPS track, distance, speeds and times of each.
- **Your places**: home, favorites, markers, recent destinations and where you parked.
- **Your settings**, including your tile server and openrouteservice key if you set them.
- **The logs** (Logs): what the app does (connection steps, errors, the dash model, the bike's Wi-Fi
  network name, destination names and, at times, a position). A copy without passwords or serial
  numbers is saved when the app goes to the background (and every half minute while it is connected),
  so it is not lost if iOS closes the app; the next launch restores it and deletes it. If iOS hands the
  app a crash report (MetricKit), the app keeps it with the logs.
- **Dash recordings** (Logs ▸ Link diagnostics ▸ "Record the dash video stream"): the video the dash
  receives: the map around you or, in Mirror mode, everything the iPhone screen shows (other apps and
  notifications too). They are deleted at the next launch.
- **Map tiles** already downloaded (up to 512 MB; each expires after 90 days).
- **Files you prepare for sharing** (GPX, logs, settings and map data; map data carries your home, your
  places and where you parked): deleted soon after by themselves (when the app goes to the background,
  those older than 2 minutes) and at the next launch.

### Permissions and why

- **Camera**: scan the pairing QR code shown on the dash. Only while the scanner is open; no photos are
  saved.
- **Photos**: no permission. The iOS photo picker gives the app only the photo you pick (your bike's, or
  a photo of the QR).
- **Location** ("While Using the App", precise): the map, turn-by-turn guidance, speed, speed limits and
  trips. With the iPhone locked the app keeps using it only while it is connected to the dash, recording a
  trip or navigating; iOS then shows the blue location indicator. The app never asks for "Always".
- **Local Network**: find the dash on the bike's Wi-Fi and send it the map.
- **Media & Apple Music** (only if you turn on Apple Music on the dash in Settings): read the song the
  Music app plays (title, artist and cover) and control it from the dash. Songs do not appear in the
  logs: each one shows as a code that changes at every launch.
- **Wi-Fi** (only in TestFlight or Xcode copies with a paid account): join the bike's Wi-Fi by itself and
  read the name of the current Wi-Fi network. The sideload build can do neither.
- **Background audio** (not a permission): voice prompts and, only if you turn on the handlebar buttons,
  a silent audio track to receive them. The app does not use the microphone.
- **Screen recording** (not a permission): the Mirror mode broadcast, which you start.

### Online services the app uses

The app connects straight from your iPhone to these services (over cellular data while you are joined
to the bike's Wi-Fi, which has no internet). Each one sees your **IP address** and the time of the
request, and has its own privacy policy. To the map services the app introduces itself as
`OpenCfMoto-iOS/<version> (moto dash map; +https://github.com/Kevinparra535/opencfmoto-ios)`
(User-Agent), as their usage policies ask; it adds no identifier of you or your iPhone.

| Service | What for | What it receives |
|---|---|---|
| tile.openstreetmap.org (OpenStreetMap Foundation), or the tile server you set in Settings | The dash map and the Dash view | The coordinates of the tiles the map shows, that is, the area you are in and the one of your route. With your own server, also those of the route ahead (at most 400); OpenStreetMap's servers are never asked in advance. |
| Photon, photon.komoot.io (komoot); if it fails or there is no position, Nominatim, nominatim.openstreetmap.org (OpenStreetMap Foundation) | Place and address search | The text you type, as you type it (from 2 letters), and your position **rounded to 2 decimals** (about 1 km). |
| Overpass API, overpass-api.de (FOSSGIS e.V.) | Nearby places (fuel, cafe, food…) | The category and your position **rounded to 3 decimals** (about 100 m). |
| Overpass API, overpass-api.de (FOSSGIS e.V.) | The speed limit of the road | While the app gets your GPS, your **exact position**, at most once every 12 seconds (and once every 10 minutes for each area of about 100 m). |
| Valhalla, valhalla1.openstreetmap.de (FOSSGIS e.V.), and OSRM, router.project-osrm.org (the OSRM project's demo server) | Routing | The start (your **exact position**), the destination, the in-between points of alternative or there-and-back routes, and whether to avoid tolls or highways. When rerouting, your position again. |
| openrouteservice, api.openrouteservice.org (HeiGIT), **only if you enter your own key** in Settings | Routing: first for routes that avoid tolls or highways, and as a fallback when the others fail | The same as above, and your key. |
| Apple Maps (MapKit), by Apple | The map on the iPhone's Map and Trips screens | What iOS asks Apple for to draw that map (the area you look at). |
| Apple Music (MusicKit), by Apple, only with Apple Music on the dash | The cover of a streamed song that has none of its own | The request for that cover to Apple's servers. |

**The bike's dash** is not an internet service: the app talks to it over the bike's Wi-Fi and sends it the
map video (with the song, if you turned on Apple Music on the dash). To link, it sends what the dash's
protocol asks for: "Apple" and your iPhone's model (or an Android phone's brand and model if you turn on
"Identify as an Android phone"), and an identifier and a signing key the app makes anew at every launch.

In Mirror mode ("Mirror the whole iPhone screen"), iOS gives the OpenCfMoto Mirror extension the screen
image only while the broadcast you start lasts (the extension does not use the sound); iOS shows the red
indicator. The app sends it to the dash over the bike's Wi-Fi: it is not saved (unless you turn on the
recording) and never goes to the internet.

Apart from these services and the dash, the app connects to nothing: not to GitHub, not to any server of
ours. The links on the About screen open in Safari only if you tap them.

### Logs and problem reports

Logs and problem reports leave the iPhone **only if you share them** (with the iOS share sheet: you pick
the app and the recipient). Before sharing, the app removes Wi-Fi passwords (also those inside a pairing
QR code), the dash's serial numbers and identifiers, and API keys in map server addresses, unless you turn
on **Settings ▸ Privacy & logs ▸ "Include secrets in shared logs"**. The bike's Wi-Fi network name, the
models and destination names do stay: read them before you post them. If you attach logs to a public
GitHub issue, remove locations too.

iOS may send Apple its own diagnostic data if you allowed it in Settings ▸ Privacy & Security ▸
Analytics & Improvements. That is iOS, not the app, and it does not reach us; with the TestFlight beta,
crashes do reach us through TestFlight (see
[If you install it with TestFlight](#if-you-install-it-with-testflight)).

### If you install it with TestFlight

TestFlight is an Apple service with its own privacy notice,
[TestFlight & Privacy](https://www.apple.com/legal/privacy/data/en/test-flight/). While you test the
public beta, Apple collects this testing data and shows it to us in App Store Connect, its website for
whoever publishes the beta:

- **Crashes:** the report of each time the app closes unexpectedly and, if you add a comment when
  TestFlight offers it, that comment too.
- **Usage:** whether and when you installed it, how many times you use it (sessions), how many crashes it
  had, your iPhone model and its iOS version.
- **Your feedback:** what you send from TestFlight or with a screenshot taken in the app (the text and the
  screenshots). A screenshot shows everything on the screen (the map with your location or the bike's
  Wi-Fi name, for example): check it before you send it.
- **Details of the iPhone at that moment**, with each piece of feedback and each crash report you send:
  model, iOS version, language and region, time zone, carrier, connection type (Wi-Fi or cellular),
  battery level, free storage, screen resolution, architecture and how long the app had been open.

Through the public link we do not see your name or e-mail: App Store Connect shows you as anonymous. If you
type your e-mail when you send feedback, we see it on that feedback only. If you send feedback by e-mail
from TestFlight, we see the address you send it from. What Apple does with this data is in its notice.

OpenCfMoto adds nothing to this: the app still sends us no data; TestFlight collects this, not the app's
code. It does not happen with the sideload build or with Xcode, and in your own TestFlight copy (a fork)
this data reaches you, not us.

To stop sharing it, leave the beta: in TestFlight, open OpenCfMoto, tap Stop Testing, then delete the app.
What was already sent follows Apple's TestFlight privacy notice.

### Contact

Questions or problems: a [GitHub issue](https://github.com/Kevinparra535/opencfmoto-ios/issues/new/choose).
Security issues: privately, as [SECURITY.md](SECURITY.md) explains. Changes to this page stay in the
repository's history.
