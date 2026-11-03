# fakedash — simulador de tablero PXC / PXC dash simulator

*Español primero · [English below](#english)*

---

## Español

`fakedash.py` es un **tablero falso** (CFMoto MotoPlay / Carbit EasyConnect) que habla el protocolo
PXC por sockets TCP reales. Sirve para probar la app de iPhone (o el `EasyConnLink` en Swift, o el
`EasyConnProber` original de Android) **sin moto**, y para **validar todo lo que envía el teléfono**
contra `docs/spec/*.md`.

Está escrito de forma independiente a partir de las especificaciones (`control-plane.md`,
`media-video.md`, `session-network.md`, `input-controls.md`); cada regla cita su sección.
Solo usa la biblioteca estándar de Python 3.8+ (`ffmpeg`/`ffplay` son opcionales).

### Qué hace (igual que un tablero real)

1. Escucha el *probe* del teléfono en **:10930**, lo valida byte a byte
   (`0x70000010` + `{"phoneType":"Android","packageName":"com.cfmoto.cfmotointernational"}`, 86 bytes),
   responde `0x70000011 {"status":true}` y cierra.
2. Se **conecta de vuelta a la IP de origen del probe**: dos sockets de control a :10922
   (`CAR_CTRL 0x10000`, luego `CAR_DATA 0x20000`), después :10921 (control de medios) y :10920
   (datos de medios), con las secuencias del spec (CLIENT_INFO, QUERY_SPEED, CHECK_SN, ráfaga de
   notificaciones del CFDL26, relojes `0x10600`/`0x10450`, REQ 16/48/64/96/112).
3. Pide fotogramas H.264 con `114` a ~20 fps (lock-step) y los guarda / muestra / decodifica.
4. Envía latidos `0x70000000` cada 2 s en cada socket de control y responde los del teléfono con
   `0x70000001`.
5. Si una petición "puerta" no recibe respuesta, se comporta como un tablero real: se queda en
   silencio y cierra todo a los 9 s (`socketTimeoutPeriodWifi`). Si un `114` no recibe fotograma en
   9 s, corta el enlace de medios. (`--lenient` continúa para recoger más diagnósticos.)

### Probar la app del iPhone SIN moto (Mac en la misma Wi‑Fi)

Requisitos: un Mac y el iPhone en **la misma red Wi‑Fi** (no una red de invitados ni con
"aislamiento de clientes"), la VPN del iPhone desactivada, y opcionalmente `brew install ffmpeg`
(para ver el vídeo con `ffplay`).

1. **Crea una moto para tu Wi‑Fi de casa** en la app: *Garaje ▸ introducir el Wi‑Fi manualmente*
   (el formulario de emparejamiento manual: nombre de la red (SSID), contraseña, nombre opcional,
   p. ej. «Tablero falso»). La app lo guarda como cualquier moto escaneada por QR.
2. **En el Mac**, desde la raíz del repositorio:

   ```sh
   python3 tools/fakedash/fakedash.py --bonjour --ffplay --scenario cfdl16
   ```

   - La primera vez macOS pregunta si `python3` puede aceptar conexiones entrantes: **Permitir**.
   - `--bonjour` anuncia `_EasyConn._tcp` en el puerto 10930 con los TXT de un tablero real
     (`huid`, `huname`, `channel`, `flavor`, `port`, `ip`) usando `dns-sd -R` (incluido en macOS).
     Si el Mac tiene varias interfaces, fija la IP: `--advertise-ip 192.168.1.23`.
3. **En el iPhone**, elige esa moto y pulsa **Conectar**. Acepta el permiso de **Red local** si iOS
   lo pide (si la app pide unirte a la Wi‑Fi a mano, ya estás conectado: confírmalo).
   - La app abre 10922/10921/10920, busca por Bonjour, encuentra el Mac y le manda el probe
     (también probará el router de casa en :10930; es normal que falle).
   - El simulador se conecta de vuelta al iPhone, hace el handshake y empieza a pedir vídeo: la
     interfaz del tablero aparece en la ventana de `ffplay`.
4. Al terminar (`--seconds`, por defecto 10 s, o **Ctrl‑C**) se imprime el **resumen**: violaciones,
   avisos, FPS, latencias de `114`, intervalo de IDR, SPS, latidos, decodificación.

Otros tableros: `--scenario cfdl26` (vertical 800×944 con la ráfaga de notificaciones),
`--scenario mt800` (1280×576 panorámico táctil), `--scenario touch` (toques del tablero; la app
debe reaccionar en pantalla y **no** responder nunca a los `cmd 32`). Para una prueba larga:
`--seconds 600`. Para guardar todo: `--transcript sesion.jsonl --out-h264 video.h264 --decode`.

Si el iPhone no encuentra el tablero: `dns-sd -B _EasyConn._tcp` en otro terminal del Mac debe
listar el servicio; comprueba que el iPhone y el Mac están en la misma subred.

### Escenarios

| `--scenario` | Tablero (`--dash`) | Qué hace | `--seconds` por defecto |
|---|---|---|---|
| `cfdl16` | `cfdl16` (675 SR‑R, pide 800×386 → lienzo 800×384, no táctil, sdk 0.9.29.1) | CAR_CTRL, CLIENT_INFO, QUERY_SPEED, CAR_DATA, CHECK_SN (+`0x201c0`/`0x201c1`), `0x10600` + `0x10450`, medios 16/48/64/96/112, luego `114` a 20 fps | 10 |
| `cfdl26` | `cfdl26` (1000 MT‑X, 800×951 → 800×944 vertical, sdk 1.1.4) | igual + la **ráfaga** en CAR_DATA: `0x10780` (primera puerta), CHECK_SN, `0x103a0` (contraseña de relleno, nunca una real), `0x10020`, `0x10040`, `0x10600`, `0x10750`, `0x10430`, `0x10450`, `0x10460`; los medios solo se abren cuando todas tienen `cmd+1` | 10 |
| `mt800` | `mt800` (800MT, 1280×576 panorámico táctil, sdk 1.1.2) | como `cfdl26` | 10 |
| `reconnect` | `cfdl16` | transmite `--seconds`, **cierra todos los sockets**, espera un probe nuevo y repite (`--cycles`, 2) | 5 por ciclo |
| `stall` | `cfdl16` | transmite, **deja de pedir fotogramas 12 s** (`--stall-seconds`) con los sockets abiertos y luego reanuda; informa si el *watchdog* del teléfono (> 8 s sin fotograma, tic de 5 s) cortó y re‑sondeó | 4 antes y después |
| `touch` | `mt800` | inyecta `cmd 32` (input‑controls §2/§4.5): toques en esquinas y centro, arrastre con recontacto, **contacto fantasma** y pellizco con dos dedos (`--touch-fuzz` añade cuerpos inválidos) | 6 |
| `music` | `cfdl16` | como `cfdl16`, más largo: la app con `-e2eMusic` abre la hoja Música, pasa de canción, pausa y la cierra mientras se transmite | 30 |
| `locked` | `cfdl16` | como `cfdl16`, a través de un bloqueo simulado del iPhone (la app con `-e2eBackgroundCycle 15:30 -e2eBackgroundEncoder vtsw` cambia de codificador): anota cada SPS/PPS distinto, exige al menos dos [LOCKED_NO_SWITCH] y cada cambio en un IDR [SWITCH_NOT_AT_IDR]; con `--decode`, decodificación estricta | 60 |

Cualquier escenario acepta `--dash cfdl16|cfdl26|mt800`.

### Qué se valida (ID de regla entre corchetes)

- **Probe** [PROBE_FORMAT, PROBE_PAYLOAD]: cabecera, magic, longitud 86, reservado 0, JSON exacto.
- **Tramas de control** [FRAME_MAGIC, FRAME_LENGTH, FRAME_RESERVED]: `magic = cmd ^ totalLen` en
  cada trama del teléfono.
- **Cada petición respondida** con `cmd+1` en `--reply-timeout` (3 s) [REPLY_TIMEOUT, REPLY_LATE];
  acks vacíos donde el spec lo exige [REPLY_PAYLOAD]; nada no solicitado [UNSOLICITED_CTRL,
  UNSOLICITED_MEDIA], p. ej. un `0x10601` empujado.
- **CLIENT_INFO `0x10011`** (§8) [CLIENT_INFO_KEYS, CLIENT_INFO_VALUE, CLIENT_INFO_SYNC_TIME]:
  **orden** exacto de claves, `pxcVersion 1.0.2`, `phoneOs "Android"`, `package`, `versionCode 126`,
  `token 0`, `bluetoothName`, `supportH264IFrame true`, `supportFunction 0|128`,
  `supportSyncCorrectTime false`, `appVersionFingerPrint`, `supportScreenTouch` solo `true` o ausente.
  [CLIENT_INFO_PUBKEY] `pubkey` = SPKI RSA‑1024 en base64 (216 caracteres) con el prefijo fijo de 22
  bytes, e = 65537. [CLIENT_INFO_SIGNATURE] `encryptedHUID` se **verifica**: exponenciación modular
  propia en Python, `s^e mod n` debe dar `00 01 FF…FF 00 ‖ HUID` (PKCS#1 v1.5 tipo 1).
  Avisos: [CLIENT_INFO_PROFILE] `supportFunction`/`supportScreenTouch` frente al perfil por defecto
  de Android (puntuación §12.4 portada); [CLIENT_INFO_BYTES] bytes distintos de `org.json` de
  Android (p. ej. `/` sin escapar como `\/`).
- **CHECK_SN** [CHECK_SN_RESULT]: `0x103e1` vacío y después `0x201c0`
  `{"isOk":true,"errCode":0,"errMsg":"","id":"<sn>","client_set":"easy_conn"}` en ese orden de claves.
- **Reloj** [CLOCK_REPLY]: `0x10601` = petición copiada y rellenada con ceros hasta 45 bytes (eco);
  hora del teléfono `yyyy-MM-dd HH:mm:ss.SSS000000` solo para sellos vacíos/1969–1971. Se envían
  variantes reales: corto de 39 bytes, separador `T`, 1970 (`--clock-variants`). `0x10451` vacío.
- **Latidos** [HEARTBEAT_MISSING, HEARTBEAT_GAP, HEARTBEAT_FIRST]: el teléfono debe latir cada 2 s
  en **cada** socket :10922 (el primero ~2 s tras el *select*); hueco > 6,5 s = violación (el 800NK de
  EE. UU. corta a los ~7 s; `--no-dash-heartbeat --silence-teardown 7` lo emula).
- **Medios** [MEDIA_RLY17/49/65/97/113, MEDIA_TOKEN]: RLY 17 = codificador (eco, 2 si 0),
  `w & 0xFFF0`, `h & 0xFFF0`, byte ext; 49 = `03 00 00 00 01 00 00 00`; 97 = `{"state":0}`;
  113 tras 112; **token 0** siempre; [TOUCH_REPLY] **nada** en respuesta a `cmd 32`.
- **Fotogramas** (cada respuesta a `114`): exactamente un `[tamaño i32 LE][AU Annex‑B]`
  [FRAME_EXTRA_BYTES], tamaño > 0 [FRAME_SIZE]; empieza con código de inicio (detecta AVCC sin
  convertir de VideoToolbox) y contiene un *slice* [FRAME_ANNEXB]; **el primero tras 112 es IDR**
  [FRAME_FIRST_NOT_IDR]; **cada IDR lleva SPS+PPS** delante [FRAME_IDR_NO_PARAMS]; ningún P repetido
  idéntico seguido [FRAME_REPEATED_P]; sin B‑slices ni reordenación [FRAME_B_SLICE]; el SPS mide
  exactamente el lienzo negociado [FRAME_SIZE_MISMATCH]; avisos de perfil/nivel ≠ Baseline 3.1
  [SPS_PROFILE], latencia > 1,5 s [PULL_SLOW]; [PULL_TIMEOUT] si un `114` queda sin respuesta 9 s.
- **Sesión**: conexión de vuelta rechazada (escuchas no abiertas antes del probe) [CONNECT_BACK];
  probe durante una sesión viva [PROBE_DURING_SESSION]; `phoneUUID`/`pubkey` que cambian entre
  reconexiones [IDENTITY_CHANGED]; *watchdog* prematuro [WATCHDOG_EARLY]; sin re‑sondeo
  [NO_REPROBE]; con `--decode`, decodificación limpia con `ffmpeg` y resolución [DECODE].
- **Variantes de SPS/PPS** (todos los escenarios): cada par SPS + PPS distinto se anota en
  `sps_variants` de la sesión (`hex`, `pps_hex`, `first_frame`, `frames`, `profile`, `level`,
  `constraints`, `poc_type`, `refs`, `log2_max_frame_num`, `vui`, `reorder`, tamaño) y en el log
  (`SPS #n at frame k: …`); las reglas del SPS se aplican a cada una. Solo en `locked`: menos de dos
  variantes en toda la ejecución [LOCKED_NO_SWITCH] (el bloqueo simulado nunca llevó un segundo
  codificador al tablero; también pasa si los dos escriben el mismo SPS/PPS byte a byte: el log de la
  app dice cuál), un cambio de variante fuera de un IDR [SWITCH_NOT_AT_IDR], y `--decode` decodifica
  con `-xerror -err_detect +crccheck+bitstream+buffer+explode` (`decodable`; la pasada normal queda
  como `lenient_decodable`). `--trace-headers F` guarda los SPS/PPS que leyó `ffmpeg -bsf:v
  trace_headers` cada vez que cambian (el primero y cada cambio de codificador), con la primera
  cabecera de *slice* de ese fotograma y su número.

### Opciones útiles

`--transcript F.jsonl` (cada trama en ambos sentidos), `--summary-json F.json`, `--out-h264 F`,
`--decode`, `--trace-headers F`, `--ffplay`, `--strict` (código de salida 1 si hay violaciones), `--lenient`,
`--reject-probes N` (prueba los reintentos de probe), `--fps`, `--reply-timeout`,
`--no-dash-heartbeat`, `--silence-teardown 7`, `--burst-mode sequential`, `--start-h264`,
`--bind`, `--probe-port`, `--phone-ports`, `--connect-back-ip`, `-v` / `-q`.
Códigos de salida: 0 terminado, 1 violaciones con `--strict`, 2 error de arranque (puerto ocupado),
3 no llegó ningún probe.

### Contra implementaciones locales (Swift / Kotlin) en esta máquina

Los puertos PXC son compartidos: **cualquier proceso que abra 10920/10921/10922/10930 debe ir bajo el
candado** (el simulador y el teléfono a la vez):

```sh
flock /tmp/pxc-ports.lock sh -c '
  python3 tools/fakedash/fakedash.py --bind 127.0.0.1 --scenario cfdl26 --seconds 8 \
      --transcript /ruta/t.jsonl --summary-json /ruta/s.json --max-runtime 120 & DASH=$!
  sleep 0.5; <arranca aquí el teléfono (probe a 127.0.0.1:10930)>; wait $DASH'
```

Ojo con el código Android ejecutado en una JVM de escritorio: `org.json` de escritorio (JSON‑java)
es un `HashMap` (pierde el orden de claves) y no escapa `/`; Android usa el `org.json` de AOSP, que
conserva el orden y escribe `\/`. Esas diferencias son **artefactos del arnés**, no de la app; los
mensajes de CLIENT_INFO_KEYS / CLIENT_INFO_BYTES / CHECK_SN_RESULT lo indican.

### Autoprueba

```sh
python3 -m unittest -v tools/fakedash/test_fakedash.py          # ~85 s, incluye extremo a extremo
FAKEDASH_SKIP_E2E=1 python3 tools/fakedash/test_fakedash.py     # solo unitarias (~1 s)
```

Las pruebas unitarias usan los vectores del spec (tramas §2.3, respuesta CLIENT_INFO §8.4, clave
RSA fija §9.5 y mensaje recuperado §9.3, tabla de puntuación §12.6, reloj §13.2, RLY 17/49/65/97/113,
toques §2.4, Annex‑B). Las de extremo a extremo lanzan `fakedash.py` contra `phone_smoke.py` (un
teléfono **mínimo** solo para probar el simulador: escucha, probe, respuestas del spec, fotogramas
de `clips/*.h264`, latidos, watchdog y reconexión) en puertos libres altos (sin candado), e inyectan
fallos (`phone_smoke.py --bug …`) para comprobar que cada validador los detecta.
`phone_smoke.py --sps-switch-at N` cambia a un segundo SPS (otros *constraint flags*, la misma
imagen) desde el primer IDR a partir del fotograma N, como un cambio de codificador; con
`--bug sps-on-p` el cambio llega en un fotograma P (escenario `locked`).

Los clips de prueba se generaron así (`clips/`, < 300 KB cada uno):

```sh
ffmpeg -f lavfi -i testsrc=size=800x384:rate=20 -t 3 -c:v libx264 -profile:v baseline -level 3.1 \
       -bf 0 -g 20 -pix_fmt yuv420p -f h264 clip_800x384.h264      # y 800x944, 1280x576
```

### Decisiones donde el spec no fija el comportamiento del tablero

- Periodo de latidos del tablero (no documentado): 2 s. Latido de medios `64`: cada 3 s.
- `0x10600` cada 2 s en CAR_DATA; el CFDL16 clásico no documenta relojes, así que el modelo `cfdl16`
  anuncia `supportSyncCorrectTime:true` para ejercitarlos. `0x10750` periódico cada 6 s (CFDL26).
- Orden en medios: 16 → 48 → 64 → 96 → 112 (el spec no fija 48/64/96), cada uno esperando su
  respuesta; :10920 se abre ~70 ms después del 113.
- Ráfaga CFDL26: `0x10780` y CHECK_SN esperan su respuesta; el resto va seguido (`--burst-mode`).
- Cuerpo de REQ 16: 32 bytes + `encryptedHUID` de 172 caracteres (204 bytes como el CFDL26), fps 30,
  encoder 2, `supportExtendProtocol` = 1 (para que el eco sea significativo); contenido del JSON del
  `96` desconocido: se envía `{"version":1,"fakedash":true}`. Tokens de medios 1, 2, 3… (`--media-token`).
- Respuestas: 3 s de margen; un `114` espera hasta 9 s (`socketTimeoutPeriodWifi`) antes de cortar.
- Un probe recibido mientras hay una sesión viva se acepta pero se ignora (aviso).
- Los JSON de CLIENT_INFO del tablero son reconstrucciones a partir de valores documentados
  (§7, §12.6), no capturas reales.

---

<a name="english"></a>
## English

`fakedash.py` is a **fake dash** (CFMoto MotoPlay / Carbit EasyConnect) speaking the PXC protocol
over real TCP sockets. Use it to test the iPhone app (or the Swift `EasyConnLink`, or the original
Android `EasyConnProber`) **without a motorcycle**, and to **validate everything the phone sends**
against `docs/spec/*.md`.

It was written independently from the specs (`control-plane.md`, `media-video.md`,
`session-network.md`, `input-controls.md`); every rule cites its section. Python 3.8+ standard
library only (`ffmpeg`/`ffplay` optional).

### What it does (like a real dash)

1. Listens for the phone **probe** on **:10930**, validates it byte by byte
   (`0x70000010` + `{"phoneType":"Android","packageName":"com.cfmoto.cfmotointernational"}`, 86 bytes),
   answers `0x70000011 {"status":true}` and closes.
2. **Connects back to the probe's source IP**: two control sockets on :10922 (`CAR_CTRL 0x10000`,
   then `CAR_DATA 0x20000`), then :10921 (media control) and :10920 (media data), with the spec
   sequences (CLIENT_INFO, QUERY_SPEED, CHECK_SN, the CFDL26 notify burst, `0x10600`/`0x10450`
   clock frames, REQ 16/48/64/96/112).
3. Pulls H.264 frames with `114` at ~20 fps (lock-step) and saves / shows / decodes them.
4. Sends `0x70000000` heartbeats every 2 s on each control socket and answers the phone's with
   `0x70000001`.
5. If a gate request is not answered it behaves like a real dash: goes silent and closes everything
   after 9 s (`socketTimeoutPeriodWifi`). A `114` without a frame for 9 s drops the media link.
   (`--lenient` continues to collect more diagnostics.)

### Testing the iPhone app WITHOUT a bike (Mac on the same Wi-Fi)

You need a Mac and the iPhone on **the same Wi-Fi network** (not a guest network / no client
isolation), the iPhone's VPN off, and optionally `brew install ffmpeg` (to watch the video in
`ffplay`).

1. **Create a bike for your home Wi-Fi** in the app: *Garage ▸ enter the Wi-Fi manually* (the manual
   pairing form: network name (SSID), password, optional name such as "Fake dash"). The app stores
   it like any QR-scanned bike.
2. **On the Mac**, from the repository root:

   ```sh
   python3 tools/fakedash/fakedash.py --bonjour --ffplay --scenario cfdl16
   ```

   - The first time, macOS asks whether `python3` may accept incoming connections: **Allow**.
   - `--bonjour` advertises `_EasyConn._tcp` on port 10930 with a real dash's TXT keys (`huid`,
     `huname`, `channel`, `flavor`, `port`, `ip`) via `dns-sd -R` (built into macOS;
     `avahi-publish-service` on Linux). On a multi-homed Mac pin the IP: `--advertise-ip 192.168.1.23`.
3. **On the iPhone**, pick that bike and tap **Connect**. Accept the **Local Network** prompt if iOS
   shows it (if the app asks you to join the Wi-Fi manually, you already are: confirm).
   - The app opens 10922/10921/10920, browses Bonjour, finds the Mac and sends it the probe (it also
     probes the home router on :10930; failing there is expected).
   - The simulator connects back to the iPhone, runs the handshake and starts pulling video: the dash
     UI appears in the `ffplay` window.
4. At the end (`--seconds`, default 10 s, or **Ctrl-C**) the **summary** is printed: violations,
   warnings, FPS, `114` latencies, IDR interval, SPS, heartbeats, decodability.

Other dashes: `--scenario cfdl26` (800×944 portrait with the notify burst), `--scenario mt800`
(1280×576 wide touch), `--scenario touch` (dash touches; the app should react on screen and must
**never** answer a `cmd 32`). For a long run: `--seconds 600`. To keep everything:
`--transcript session.jsonl --out-h264 video.h264 --decode`.

If the iPhone does not find the dash: `dns-sd -B _EasyConn._tcp` in another Mac terminal must list
the service; check that the iPhone and the Mac are on the same subnet.

### Scenarios

| `--scenario` | Dash (`--dash`) | What happens | default `--seconds` |
|---|---|---|---|
| `cfdl16` | `cfdl16` (675 SR-R, asks 800×386 → canvas 800×384, non-touch, sdk 0.9.29.1) | CAR_CTRL, CLIENT_INFO, QUERY_SPEED, CAR_DATA, CHECK_SN (+`0x201c0`/`0x201c1`), `0x10600` + `0x10450`, media 16/48/64/96/112, then `114` at 20 fps | 10 |
| `cfdl26` | `cfdl26` (1000 MT-X, 800×951 → 800×944 portrait, sdk 1.1.4) | same + the CAR_DATA **notify burst**: `0x10780` (first gate), CHECK_SN, `0x103a0` (placeholder password, never a real one), `0x10020`, `0x10040`, `0x10600`, `0x10750`, `0x10430`, `0x10450`, `0x10460`; media opens only after every frame got its `cmd+1` | 10 |
| `mt800` | `mt800` (800MT, 1280×576 wide touch, sdk 1.1.2) | like `cfdl26` | 10 |
| `reconnect` | `cfdl16` | streams `--seconds`, **closes ALL sockets**, waits for a new probe and redoes the sequence (`--cycles`, 2) | 5 per cycle |
| `stall` | `cfdl16` | streams, **stops pulling for 12 s** (`--stall-seconds`) with every socket open, then resumes; reports whether the phone watchdog (> 8 s without a frame, 5 s tick) dropped and re-probed | 4 before and after |
| `touch` | `mt800` | injects `cmd 32` (input-controls §2/§4.5): corner/centre taps, drag with a re-acquired contact, a **ghost second contact** and a two-finger pinch (`--touch-fuzz` adds invalid bodies) | 6 |
| `music` | `cfdl16` | like `cfdl16`, longer: the app run with `-e2eMusic` opens the Music sheet, skips a song, pauses and closes it while streaming | 30 |
| `locked` | `cfdl16` | like `cfdl16`, across a simulated iPhone lock (the app run with `-e2eBackgroundCycle 15:30 -e2eBackgroundEncoder vtsw` switches encoders): records every distinct SPS/PPS, requires at least two [LOCKED_NO_SWITCH] and every switch at an IDR [SWITCH_NOT_AT_IDR]; with `--decode`, a strict decode | 60 |

Every scenario accepts `--dash cfdl16|cfdl26|mt800`.

### What is validated (rule ID in brackets)

- **Probe** [PROBE_FORMAT, PROBE_PAYLOAD]: header, magic, length 86, reserved 0, exact JSON.
- **Control frames** [FRAME_MAGIC, FRAME_LENGTH, FRAME_RESERVED]: `magic = cmd ^ totalLen` on every
  phone frame.
- **Every request answered** with `cmd+1` within `--reply-timeout` (3 s) [REPLY_TIMEOUT,
  REPLY_LATE]; empty acks where the spec says so [REPLY_PAYLOAD]; nothing unsolicited
  [UNSOLICITED_CTRL, UNSOLICITED_MEDIA], e.g. a pushed `0x10601`.
- **CLIENT_INFO `0x10011`** (§8) [CLIENT_INFO_KEYS, CLIENT_INFO_VALUE, CLIENT_INFO_SYNC_TIME]: exact
  key **order**, `pxcVersion 1.0.2`, `phoneOs "Android"`, `package`, `versionCode 126`, `token 0`,
  `bluetoothName`, `supportH264IFrame true`, `supportFunction 0|128`, `supportSyncCorrectTime false`,
  `appVersionFingerPrint`, `supportScreenTouch` only `true` or absent. [CLIENT_INFO_PUBKEY] `pubkey` =
  base64 RSA-1024 SPKI (216 chars) with the fixed 22-byte prefix, e = 65537.
  [CLIENT_INFO_SIGNATURE] `encryptedHUID` is **verified**: own modular exponentiation in Python,
  `s^e mod n` must equal `00 01 FF…FF 00 ‖ HUID` (PKCS#1 v1.5 type 1). Warnings:
  [CLIENT_INFO_PROFILE] `supportFunction`/`supportScreenTouch` vs Android's default profile (§12.4
  scoring, ported); [CLIENT_INFO_BYTES] bytes differ from Android's `org.json` (e.g. `/` not escaped
  as `\/`).
- **CHECK_SN** [CHECK_SN_RESULT]: empty `0x103e1`, then `0x201c0`
  `{"isOk":true,"errCode":0,"errMsg":"","id":"<sn>","client_set":"easy_conn"}` in that key order.
- **Clock** [CLOCK_REPLY]: `0x10601` = the request copied and zero-padded to 45 bytes (echo); phone
  time `yyyy-MM-dd HH:mm:ss.SSS000000` only for blank / 1969–1971 stamps. Real field variants are
  sent: 39-byte short stamp, `T` separator, 1970 (`--clock-variants`). Empty `0x10451`.
- **Heartbeats** [HEARTBEAT_MISSING, HEARTBEAT_GAP, HEARTBEAT_FIRST]: the phone must beat every 2 s on
  **every** :10922 socket (first ~2 s after the select); a gap > 6.5 s is a violation (the US 800NK
  drops after ~7 s; `--no-dash-heartbeat --silence-teardown 7` emulates it).
- **Media** [MEDIA_RLY17/49/65/97/113, MEDIA_TOKEN]: RLY 17 = encoder (echo, 2 if 0), `w & 0xFFF0`,
  `h & 0xFFF0`, ext byte; 49 = `03 00 00 00 01 00 00 00`; 97 = `{"state":0}`; 113 after 112; **token 0**
  always; [TOUCH_REPLY] **nothing** in reply to `cmd 32`.
- **Frames** (every `114` reply): exactly one `[size i32 LE][Annex-B AU]` [FRAME_EXTRA_BYTES],
  size > 0 [FRAME_SIZE]; starts with a start code (detects unconverted VideoToolbox AVCC) and holds a
  slice [FRAME_ANNEXB]; **the first one after 112 is an IDR** [FRAME_FIRST_NOT_IDR]; **every IDR
  carries SPS+PPS** in front [FRAME_IDR_NO_PARAMS]; no byte-identical P-frame back to back
  [FRAME_REPEATED_P]; no B slices / reordering [FRAME_B_SLICE]; the SPS size equals the negotiated
  canvas [FRAME_SIZE_MISMATCH]; warnings for profile/level ≠ Baseline 3.1 [SPS_PROFILE] and latency
  > 1.5 s [PULL_SLOW]; [PULL_TIMEOUT] when a `114` stays unanswered for 9 s.
- **Session**: connect-back refused (listeners not up before the probe) [CONNECT_BACK]; probe during a
  live session [PROBE_DURING_SESSION]; `phoneUUID`/`pubkey` changing across reconnects
  [IDENTITY_CHANGED]; premature watchdog [WATCHDOG_EARLY]; no re-probe [NO_REPROBE]; with `--decode`,
  clean `ffmpeg` decode and resolution [DECODE].
- **SPS/PPS variants** (every scenario): each distinct SPS + PPS pair is recorded in the session's
  `sps_variants` (`hex`, `pps_hex`, `first_frame`, `frames`, `profile`, `level`, `constraints`,
  `poc_type`, `refs`, `log2_max_frame_num`, `vui`, `reorder`, size) and logged (`SPS #n at frame k:
  …`); the SPS rules apply to each. `locked` only: fewer than two variants over the run
  [LOCKED_NO_SWITCH] (the simulated lock never put a second encoder on the wire; two encoders that
  write the same SPS/PPS byte for byte look the same: the app log tells which), a variant change that
  is not at an IDR [SWITCH_NOT_AT_IDR], and `--decode` decodes with `-xerror -err_detect
  +crccheck+bitstream+buffer+explode` (`decodable`; the normal pass stays as `lenient_decodable`).
  `--trace-headers F` saves the SPS/PPS that `ffmpeg -bsf:v trace_headers` read each time they change
  (the first one and every encoder switch), with the first slice header of that frame and its number.

### Useful options

`--transcript F.jsonl` (every frame, both directions), `--summary-json F.json`, `--out-h264 F`,
`--decode`, `--trace-headers F`, `--ffplay`, `--strict` (exit 1 on violations), `--lenient`, `--reject-probes N` (exercises
the probe retries), `--fps`, `--reply-timeout`, `--no-dash-heartbeat`, `--silence-teardown 7`,
`--burst-mode sequential`, `--start-h264`, `--bind`, `--probe-port`, `--phone-ports`,
`--connect-back-ip`, `-v` / `-q`. Exit codes: 0 done, 1 violations with `--strict`, 2 setup error
(port busy), 3 no probe received.

Transcript (`--transcript`): one JSON object per line. Frames:
`{"t", "cycle", "conn": "probe|ctrl1|ctrl2|mctrl|mdata", "dir": "phone->dash|dash->phone",
"kind": "cmdbase|reqbase|raw", "cmd": "0x…" (null for raw frames), "name", "len",
"payload_hex" (raw frames: first 64 bytes unless --transcript-full-frames), "payload_text",
"note"}` plus `token` for ReqBase and `frame`/`keyframe`/`nal_types`/`latency_ms` for raw frames.
Events (`"kind": "event"` / `"finding"`) mark connects, closes and findings; the last line is
`{"kind": "summary", "summary": {…}}` (same object as `--summary-json`: counts per command, sessions,
frames, fps, findings).

### Against local implementations (Swift / Kotlin) on this machine

The PXC ports are shared: **every process binding 10920/10921/10922/10930 must run under the lock**
(the simulator and the phone together):

```sh
flock /tmp/pxc-ports.lock sh -c '
  python3 tools/fakedash/fakedash.py --bind 127.0.0.1 --scenario cfdl26 --seconds 8 \
      --transcript /path/t.jsonl --summary-json /path/s.json --max-runtime 120 & DASH=$!
  sleep 0.5; <start the phone here (probe to 127.0.0.1:10930)>; wait $DASH'
```

Beware of Android code run on a desktop JVM: desktop `org.json` (JSON-java) is a `HashMap` (loses
key order) and does not escape `/`; Android ships AOSP `org.json`, which keeps insertion order and
writes `\/`. Those differences are **harness artifacts**, not app behaviour; the CLIENT_INFO_KEYS /
CLIENT_INFO_BYTES / CHECK_SN_RESULT messages say so.

### Self-test

```sh
python3 -m unittest -v tools/fakedash/test_fakedash.py          # ~85 s, includes end to end
FAKEDASH_SKIP_E2E=1 python3 tools/fakedash/test_fakedash.py     # unit tests only (~1 s)
```

Unit tests use the spec vectors (frames §2.3, CLIENT_INFO reply §8.4, fixed RSA key §9.5 and
recovered message §9.3, scoring table §12.6, clock §13.2, RLY 17/49/65/97/113, touch §2.4, Annex-B).
End-to-end tests run `fakedash.py` against `phone_smoke.py` (a **minimal** phone only meant to test
the simulator: listeners, probe, spec replies, frames from `clips/*.h264`, heartbeats, watchdog,
reconnect loop) on free high ports (no lock needed), and inject bugs (`phone_smoke.py --bug …`) to
prove each validator fires. `phone_smoke.py --sps-switch-at N` switches to a second SPS (other
constraint flags, the same picture) from the first IDR at or after frame N, like an encoder switch;
with `--bug sps-on-p` the switch comes on a P-frame (scenario `locked`).

Test clips (`clips/`, < 300 KB each) were generated with:

```sh
ffmpeg -f lavfi -i testsrc=size=800x384:rate=20 -t 3 -c:v libx264 -profile:v baseline -level 3.1 \
       -bf 0 -g 20 -pix_fmt yuv420p -f h264 clip_800x384.h264      # and 800x944, 1280x576
```

### Decisions where the spec does not pin the dash behaviour

- Dash heartbeat period (undocumented): 2 s. Media heartbeat `64`: every 3 s.
- `0x10600` every 2 s on CAR_DATA; the classic CFDL16 documents no clock frames, so the `cfdl16`
  model advertises `supportSyncCorrectTime:true` to exercise them. Periodic `0x10750` every 6 s (CFDL26).
- Media order: 16 → 48 → 64 → 96 → 112 (the spec does not pin 48/64/96), each waiting for its reply;
  :10920 opens ~70 ms after 113.
- CFDL26 burst: `0x10780` and CHECK_SN wait for their replies; the rest goes back to back
  (`--burst-mode`).
- REQ 16 body: 32 bytes + a 172-char `encryptedHUID` (204 bytes like the CFDL26), fps 30, encoder 2,
  `supportExtendProtocol` = 1 (so the echo is meaningful); the `96` JSON content is unknown:
  `{"version":1,"fakedash":true}` is sent. Media tokens 1, 2, 3… (`--media-token`).
- Replies: 3 s budget; a `114` waits up to 9 s (`socketTimeoutPeriodWifi`) before the link is cut.
- A probe received while a session is alive is accepted but ignored (warning).
- The dash CLIENT_INFO JSONs are reconstructions from documented values (§7, §12.6), not captures.
