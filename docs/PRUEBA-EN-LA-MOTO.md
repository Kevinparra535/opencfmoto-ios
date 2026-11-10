# Prueba en la moto — guía paso a paso

> **In English, in short:** this is the checklist for a first ride. Install the app (easiest: the public
> TestFlight beta, <https://testflight.apple.com/join/aWur6hxp>; or the free sideload IPA from Releases:
> [INSTALAR.md](INSTALAR.md#english)), pair the bike by scanning the dash QR, tap **Connect** with the
> engine off and compare what you see with the table in «En la moto». With the sideload build you join
> the bike Wi-Fi yourself: the app shows the **"Join the bike Wi-Fi"** sheet (use the sideload row of
> the table). Then share the logs (Logs ▸ Share) in a
> [field report](https://github.com/Kevinparra535/opencfmoto-ios/issues/new?template=field-report.yml).

Esta guía es para la **primera prueba real** de OpenCfMoto para iOS con tu tablero CFMoto / Carbit.
Todo lo que se pudo probar sin moto ya pasó:

- **Más de 1700 pruebas automáticas.**
- **Comparación byte a byte del protocolo con la app Android**: en 6 escenarios se comporta igual
  (ver `docs/verification/pxc-differential.md`).
- **La app real en el simulador de iOS conectada a un tablero simulado**, sin violaciones del
  protocolo y con todo el video decodificable.

Lo que falta es lo que solo un iPhone y un tablero reales pueden confirmar: el Wi-Fi de la moto, el
permiso de red local, el codificador de video del teléfono y el comportamiento exacto de tu tablero.

## Antes de salir

1. **Instala la app** en tu iPhone. **La más fácil, gratis y sin Mac**: la beta pública de TestFlight
   ([INSTALAR.md](INSTALAR.md#testflight-la-beta-pública)); ya es Release y la variante completa (en la
   tabla, la fila de TestFlight). **Con tu Apple ID gratuito**: la versión sideload de Releases
   ([INSTALAR.md](INSTALAR.md)); es Release, pero la variante «free»: al Wi-Fi de la moto te unes tú en
   Ajustes (ver la tabla). **Sin Mac, con cuenta de pago**: tu propio TestFlight
   ([TESTFLIGHT.md](TESTFLIGHT.md)); esa build ya es Release y la variante completa. **Con Mac**:
   desde Xcode (README → *Compilar e instalar*), con `OCM_FLAVOR = full`, que permite que la app se
   una sola al Wi-Fi de la moto; para la moto compílala en **Release** (va más fluida) y ábrela desde
   la pantalla de inicio, sin el Mac.
2. **Abre la app una vez en casa** y completa la bienvenida: permiso de ubicación *Al usar la app* y
   precisa.
3. **Opcional, para probar sin moto**: en una computadora conectada a la misma Wi-Fi que el iPhone
   (Mac; Linux con `avahi-utils`; Windows con Python 3 y el servicio Bonjour de Apple) ejecuta
   `python3 tools/fakedash/fakedash.py --bonjour --ffplay --scenario cfdl16 --seconds 120`
   (`--ffplay` necesita ffmpeg: `brew install ffmpeg` en Mac, `sudo apt install ffmpeg` en Linux), empareja a mano tu Wi-Fi de casa en Garaje ▸
   *Ingresar Wi-Fi manualmente* y pulsa **Conectar** antes de 90 s (versión sideload u
   `OCM_FLAVOR = free`: si aparece «Conéctate al Wi-Fi de la moto», ya estás en tu Wi-Fi: toca
   **«Ya me he conectado»**). Si en una ventana de la computadora ves
   el mapa durante 2 minutos, toda la cadena funciona en tu iPhone (ver `tools/fakedash/README.md`).

## En la moto (con el motor parado y la moto segura)

1. Enciende el tablero y abre su pantalla de **conexión del teléfono / QR** (la misma que usa la app
   oficial de CFMoto). **Cierra la app oficial de CFMoto** en el iPhone, porque ocupa los mismos puertos.
2. En OpenCfMoto: **Escanear** → apunta al QR del tablero. Debe aparecer tu moto en el Garaje.
3. Pulsa **Conectar con <tu moto>**. Lo esperado, en orden:

   | Paso | Qué verás en el iPhone | Tiempo típico |
   |---|---|---|
   | Unirse al Wi-Fi (TestFlight, o Xcode con `OCM_FLAVOR = full`) | iOS pregunta «¿Conectarse a la red CFMOTO…?» → **Conectar** | 2–10 s |
   | Unirse al Wi-Fi (versión sideload, o Xcode con `OCM_FLAVOR = free`) | La hoja **«Conéctate al Wi-Fi de la moto»**: copia la contraseña con su botón (la copia dura 2 minutos), ve a Ajustes ▸ Wi-Fi, elige la red de la moto, pégala y vuelve a OpenCfMoto; sigue sola o toca **«Ya me he conectado»**. Si el iPhone ya estaba en la red de la moto, la hoja no aparece | a tu ritmo |
   | Red local | La primera vez, iOS pide **permiso de red local** → **Permitir** (imprescindible) | — |
   | Vinculando | «Vinculando al panel…» | 1–5 s |
   | En vivo | «Conectado: proyectando al tablero» (verde) y **el mapa aparece en el tablero** | < 1 s |

4. Toca el tablero (si es táctil): botones **+ / −**, el **menú ⋮**, la **barra de búsqueda**.
   Prueba también **Vista de tablero** en el iPhone, que muestra lo mismo que ve el tablero.
5. Navega a un destino desde el iPhone (**Mapa** → busca → **Ir**) y comprueba en el tablero el cartel
   de giro, las distancias, la hora de llegada y la voz en el iPhone o el casco.
6. Para rodar: guarda el teléfono en **Modo bolsillo**. La app lo ofrece sola: 5 s después de
   **Conectar** o de **Ir** aparece la cuenta atrás «Modo bolsillo en 5 s · Guarda el teléfono: el
   tablero sigue en vivo» y entra, salvo que toques **Quedarme aquí** (también está el botón **Modo
   bolsillo** en la pantalla de inicio). La pantalla queda negra, el teléfono no se bloquea y el
   tablero sigue recibiendo el mapa. Para salir, mantén presionado 1,5 s.
7. En una parada, apaga la moto un minuto y vuelve a encenderla: el iPhone no debe mostrar ninguna
   alarma. El estado dice «Moto apagada · se reconecta sola» y el mapa vuelve al tablero solo.

## Apple Music en el tablero

Actívalo **en casa o con la moto parada**: Ajustes ▸ **Apple Music en el tablero** ▸ **«Mostrar Apple
Music en el tablero»** y permite **Multimedia y Apple Music**. Si el interruptor ya está activado y
aparece **«Permitir el acceso a Multimedia y Apple Music»**, tócalo (iOS aún no lo había preguntado).
Solo funciona con la app **Música** de Apple: iOS no deja ver lo que suena en Spotify u otras apps.

Comparte los registros (líneas `MUSIC` y `BTN`). No llevan títulos, artistas ni identificadores: cada
canción es un código que cambia en cada arranque de la app, por ejemplo
`state paused track=p3f9a01c2 other=1` (`other=1`: iOS oye otro audio, o todavía el final de la
canción justo tras una pausa).

1. **Permiso**: el texto del aviso de iOS. Con **No permitir** no aparece música en el tablero;
   actívalo luego en Ajustes de iOS ▸ OpenCfMoto ▸ **Multimedia y Apple Music** y, al volver a la
   app, aparece la portada sin reiniciarla.
2. **Una canción descargada**: la portada en el recuadro del mapa (abajo a la derecha), la barra de
   progreso y, al tocarlo, la hoja **Música** con ⏮ ⏯ ⏭. **Pausar con ⏯ deja la hoja abierta** y
   ⏯ la reanuda. ⏮ con más de 3 s de canción vuelve al principio; con menos, va a la anterior.
   Al pasar de canción con ⏮ o ⏭ la hoja sigue abierta en el mismo botón; si el registro muestra
   `no song in the reading`, iOS dio un instante sin canción y el tablero siguió con la anterior.
3. **Una canción en streaming** que no está en tu biblioteca: si sale la portada (registro
   `artwork source=mp`, `musickit` o `none`, y `ms=`). Repítelo con los **datos móviles desactivados
   para OpenCfMoto** (Ajustes de iOS ▸ Datos móviles).
4. **Una radio o emisora en directo**: sin barra ni tiempos, con el título.
5. **Música en primer plano y OpenCfMoto en segundo plano**: al pasar de canción en Música, el
   tablero cambia en unos 2 s; el ⏯ del tablero funciona.
6. **Tablero sin táctil** (Ajustes ▸ «Desactivar pantalla táctil») **con el mando multimedia del
   teléfono activado** (Controles): ◀ lleva al recuadro (antes de pulsar ★, mira que el aro naranja
   esté en el recuadro: sin recuadro, ◀ ★ ★ abre el menú y termina la navegación), ★ abre la hoja,
   ★ pone la música → aviso «Los botones del manillar controlan ahora Apple Music» y la hoja se
   cierra; los botones pasan de canción. ★ en el manillar pausa la música → aviso «Los botones del
   manillar vuelven a controlar el tablero» (registro `handlebar buttons back on the dash`). Con la
   hoja abierta y la música en pausa, dos ▶ rápidos abren el menú en «Música», no en «Finalizar
   navegación» (★ vuelve a la hoja). Si la hoja ya se cerró sola (10 s sin tocarla en marcha, cerca
   de un giro, o la canción se fue), dos ▶ rápidos pueden abrir el menú en «Finalizar navegación»:
   mira antes de pulsar ★. Un aviso de voz con música baja la música sin pararla.
7. **Spotify con Música en pausa**: si Spotify ya sonaba al abrir el tablero, no aparece el recuadro;
   si empieza después, el recuadro se va a los 3 s (registro `other audio for 3 s: song hidden`). Un
   sonido corto de otra app no lo quita.
8. **Navegando**: la hoja Música se cierra sola unos 200 m antes de un giro y tras 10 s sin tocarla
   en marcha; con la moto parada sigue abierta.
9. **Bloquear y desbloquear el iPhone**: lo que muestre el tablero bloqueado (casi siempre la imagen
   fija de «Teléfono bloqueado», ver la sección siguiente) y, al desbloquear, el recuadro correcto.

## Teléfono bloqueado: prueba de diagnóstico (fase 0)

Esta build **mide** qué pasa con el iPhone bloqueado; no promete el mapa en vivo. En el tablero verás
casi siempre lo mismo que antes (la imagen fija «Teléfono bloqueado»): la app intenta un codificador
de vídeo por software de iOS y apunta en los registros qué responde iOS, si el Wi-Fi y el enlace
siguen vivos, cuánto gasta y si llegan el GPS y la brújula.

Antes de salir:

1. Instala la última versión: con TestFlight o, si usas la versión sideload, el IPA nuevo de
   Releases con la misma herramienta y el mismo Apple ID ([INSTALAR.md](INSTALAR.md#actualizar)).
2. En Ajustes de iOS ▸ OpenCfMoto:
   - Ubicación: «Mientras se usa la app», con «Ubicación exacta» activada;
   - «Red local» activada;
   - «Actualización en segundo plano» activada.
3. Desactiva el Modo de bajo consumo. Apunta si tienes activados los botones del manillar.

En la moto, parada y segura, con el contacto puesto:

4. Conecta y espera a ver el mapa en el tablero, sin menú ni hoja abierta (abajo a la derecha se ve
   la hora).
5. En Registros ▸ «Diagnóstico del enlace», activa «Grabar el video enviado al tablero» (si ya está
   activado, desactívalo y vuelve a activarlo: así empieza una grabación nueva). A los 5 segundos,
   bloquea el iPhone con el botón lateral y apunta la hora.
6. Mira el tablero a los 30 s, a los 2 min y a los 10 min. Con la moto parada el mapa en vivo no
   se mueve: lo que cambia es la **hora del tablero** (abajo a la derecha), una vez por minuto.
   ¿Qué ves?
   - el mapa sin aviso y la hora del tablero avanza (en vivo);
   - «Teléfono bloqueado»;
   - el mapa sin aviso y la hora no avanza (imagen congelada);
   - sin imagen o desconectado.
7. Desbloquea. ¿Vuelve el mapa en menos de 5 s? Enseguida, antes de volver a bloquear y en este orden:
   - desactiva «Grabar el video enviado al tablero» si sigue activado (se desactiva solo al llegar a
     los 600 fotogramas) y toca **«Compartir la grabación»**: la app solo ofrece la última grabación,
     y compartir antes el registro puede borrarla;
   - después, Registros ▸ **Compartir**.

   Si al desbloquear la app se abrió de nuevo (iOS la cerró), la grabación de esa condición ya no está,
   pero el registro sí: compártelo enseguida, antes de la siguiente condición.
8. Repite los pasos 4 a 7 en estas condiciones:
   - **A:** iPhone cargando;
   - **B:** sin cargar;
   - **C** (opcional): con los botones del manillar activados.
9. Al terminar, envía las horas, lo que viste en cada momento, el % de batería al empezar y al terminar,
   y si el iPhone se calentó.

Qué significa cada resultado (con el iPhone bloqueado):

- **El mapa en vivo** (sin aviso y la hora del tablero avanza; con la moto parada el mapa no se
  mueve): iOS dejó a la app comprimir el vídeo por software con el teléfono bloqueado. Es justo lo
  que esta prueba busca: compártelo aunque solo dure un rato.
- **«Teléfono bloqueado»**: lo esperado en esta build. iOS no dio un codificador de vídeo, pero la
  app siguió viva y respondió al tablero; el registro dice por qué (líneas `[bg] try vt-sw …`).
- **La imagen congelada** (el último mapa, sin el aviso, y la hora del tablero no avanza): la app
  dejó de recibir peticiones del tablero, no tenía imagen de pausa para esa pantalla, o el tablero
  no muestra el vídeo nuevo; el registro lo dice.
- **Sin imagen o desconectado**: iOS cortó el Wi-Fi del tablero o paró la app. Repite con el iPhone
  cargando (condición A).
- Para rodar, **Modo bolsillo** sigue siendo lo fiable: pantalla negra y el teléfono no se bloquea.

## Si algo falla

- **Comparte los registros**: Registros ▸ **Compartir**. Los datos sensibles van ocultos por defecto.
  Para un fallo concreto usa **Informar de un problema**, que adjunta el diagnóstico.
- **Graba lo que se envía al tablero**: Registros ▸ **«Grabar el video enviado al tablero»**.
  Actívalo y reproduce el problema; si sigue activado, desactívalo (se desactiva solo al llegar a los
  600 fotogramas). Luego toca **«Compartir la grabación»** para enviar el archivo `.h264`. Se puede
  analizar con ffmpeg.
- **Prueba la compatibilidad**: si el tablero **no conecta** o **corta el enlace**, activa Ajustes ▸
  **Compatibilidad ▸ «Identificarse como teléfono Android»** y reconecta. Es la única diferencia
  con la app Android en lo que se envía al tablero.
- **Perfil del tablero**: si la imagen se ve cortada, estirada o en la orientación equivocada,
  elige el modelo exacto en Ajustes ▸ **Perfil de moto** y ajusta **Márgenes de la pantalla…**.
- **«Cierra la app oficial de CFMoto»**: otra app ocupa los puertos 10920–10922. Ciérrala desde el
  selector de apps y pulsa **Reintentar**.
- **«El acceso a la red local está desactivado»**: Ajustes de iOS ▸ OpenCfMoto ▸ **Red local** → activar.
- **«Algo en el teléfono bloquea el Wi-Fi de la moto (VPN, restricción de datos o filtro)»**: la red
  local está permitida, pero iOS cortó igualmente la conexión con el tablero. Desactiva la VPN (o su
  opción de bloquear el tráfico fuera de la VPN), los filtros de contenido o la restricción de datos
  Wi-Fi para OpenCfMoto, y vuelve a conectar. La app lo reintenta sola cada 20 s.
- **«El teléfono bloqueó la conexión con el tablero»**: iOS no dijo por qué. Revisa las dos cosas de
  arriba (red local activada, ninguna VPN ni restricción) y comparte los registros.
- **Versión sideload: la hoja «Conéctate al Wi-Fi de la moto» no se cierra al volver de Ajustes**:
  esta versión no lee el nombre de la red y reconoce la de la moto solo por su dirección. Comprueba
  en Ajustes ▸ Wi-Fi que el iPhone está en la red de la moto (no en la de casa) y toca **«Ya me he
  conectado»**.
- **Versión sideload: «Ningún tablero respondió en este Wi-Fi…»**: lo más probable es que el iPhone
  siga en el Wi-Fi de casa (por ejemplo, tocaste «Ya me he conectado» sin cambiar de red): la app no
  puede distinguirlas. Únete a la red de la moto en Ajustes ▸ Wi-Fi (la contraseña está en
  **Garaje ▸ tu moto**), vuelve, toca **Detener** y luego **Conectar**. Si el iPhone ya estaba en la
  red de la moto, abre en el tablero su pantalla de conexión / QR.
- **Pulsaste Conectar justo cuando la app ya conectaba sola**: ese toque no la detiene (cuenta como
  Conectar). Para detenerla, vuelve a pulsar.
- **El tablero muestra «Teléfono bloqueado»**: lo esperado si bloqueas el iPhone, salvo que iOS le
  dé a la app un codificador por software (ver «Qué significa cada resultado» en la prueba de
  diagnóstico de arriba). Para rodar, usa **Modo bolsillo** en lugar de bloquear.

## Qué me ayuda saber de tu prueba

1. Modelo de moto y año, y el texto que aparece en el tablero en la pantalla de conexión.
2. Cómo la instalaste (versión sideload, TestFlight o Xcode), hasta qué paso de la tabla llegaste y
   cuánto tardó cada uno.
3. Si el mapa se ve completo, nítido y fluido, y si los toques responden en el lugar correcto.
4. **Espejo con el iPhone en horizontal** (por ejemplo, un vídeo de YouTube a pantalla completa): si
   la imagen se ve derecha en el tablero girando el iPhone hacia un lado y hacia el otro. Y con los
   **botones del manillar** activados, si el recuadro de música del tablero dice «OpenCfMoto < > move»
   sin cuadros vacíos.
5. El archivo de registros compartido (y el `.h264` si algo se ve mal).
