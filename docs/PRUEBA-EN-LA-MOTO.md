# Prueba en la moto — guía paso a paso

Esta guía es para la **primera prueba real** de OpenCfMoto para iOS con tu tablero CFMoto / Carbit.
Todo lo que se pudo probar sin moto ya pasó:

- **1253 pruebas automáticas.**
- **Comparación byte a byte del protocolo con la app Android**: en 6 escenarios se comporta igual
  (ver `docs/verification/pxc-differential.md`).
- **La app real en el simulador de iOS conectada a un tablero simulado**, sin violaciones del
  protocolo y con todo el video decodificable.

Lo que falta es lo que solo un iPhone y un tablero reales pueden confirmar: el Wi-Fi de la moto, el
permiso de red local, el codificador de video del teléfono y el comportamiento exacto de tu tablero.

## Antes de salir

1. **Instala la app** en tu iPhone. **Sin Mac**: con TestFlight ([TESTFLIGHT.md](TESTFLIGHT.md)); esa
   build ya es Release y la variante completa. **Con Mac**: desde Xcode (README → *Compilar e
   instalar*), con `OCM_FLAVOR = full`, que permite que la app se una sola al Wi-Fi de la moto; para
   la moto compílala en **Release** (va más fluida) y ábrela desde la pantalla de inicio, sin el Mac.
2. **Abre la app una vez en casa** y completa la bienvenida: permiso de ubicación *Al usar la app* y
   precisa.
3. **Opcional, para probar sin moto**: en una computadora conectada a la misma Wi-Fi que el iPhone
   (Mac; Linux con `avahi-utils`; Windows con Python 3 y el servicio Bonjour de Apple) ejecuta
   `python3 tools/fakedash/fakedash.py --bonjour --ffplay --scenario cfdl16 --seconds 120`
   (`--ffplay` necesita ffmpeg: `brew install ffmpeg` en Mac, `sudo apt install ffmpeg` en Linux), empareja a mano tu Wi-Fi de casa en Garaje ▸
   *Ingresar Wi-Fi manualmente* y pulsa **Conectar** antes de 90 s. Si en una ventana de la computadora ves
   el mapa durante 2 minutos, toda la cadena funciona en tu iPhone (ver `tools/fakedash/README.md`).

## En la moto (con el motor parado y la moto segura)

1. Enciende el tablero y abre su pantalla de **conexión del teléfono / QR** (la misma que usa la app
   oficial de CFMoto). **Cierra la app oficial de CFMoto** en el iPhone, porque ocupa los mismos puertos.
2. En OpenCfMoto: **Escanear** → apunta al QR del tablero. Debe aparecer tu moto en el Garaje.
3. Pulsa **Conectar con <tu moto>**. Lo esperado, en orden:

   | Paso | Qué verás en el iPhone | Tiempo típico |
   |---|---|---|
   | Unirse al Wi-Fi | iOS pregunta «¿Conectarse a la red CFMOTO…?» → **Conectar** | 2–10 s |
   | Red local | La primera vez, iOS pide **permiso de red local** → **Permitir** (imprescindible) | — |
   | Vinculando | «Vinculando al panel…» | 1–5 s |
   | En vivo | «Conectado: proyectando al tablero» (verde) y **el mapa aparece en el tablero** | < 1 s |

4. Toca el tablero (si es táctil): botones **+ / −**, el **menú ⋮**, la **barra de búsqueda**.
   Prueba también **Vista de tablero** en el iPhone, que muestra lo mismo que ve el tablero.
5. Navega a un destino desde el iPhone (**Mapa** → busca → **Ir**) y comprueba en el tablero el cartel
   de giro, las distancias, la hora de llegada y la voz en el iPhone o el casco.
6. Para rodar: pulsa **Modo ruta**. La pantalla queda negra, el teléfono no se bloquea y el tablero
   sigue recibiendo el mapa. Para salir, mantén pulsado 1,5 s.

## Si algo falla

- **Comparte los registros**: Registros ▸ **Compartir**. Los datos sensibles van ocultos por defecto.
  Para un fallo concreto usa **Informar de un problema**, que adjunta el diagnóstico.
- **Graba lo que se envía al tablero**: Registros ▸ **«Grabar el vídeo enviado al tablero»**.
  Actívalo, reproduce el problema, desactívalo y comparte el archivo `.h264`. Se puede analizar con
  ffmpeg.
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
- **Pulsaste Conectar justo cuando la app ya conectaba sola**: ese toque no la detiene (cuenta como
  Conectar). Para detenerla, vuelve a pulsar.
- **El tablero muestra «Teléfono bloqueado»**: es lo esperado si bloqueas el iPhone. iOS no deja
  codificar vídeo en segundo plano. Usa **Modo ruta** en lugar de bloquear.

## Qué me ayuda saber de tu prueba

1. Modelo de moto y año, y el texto que aparece en el tablero en la pantalla de conexión.
2. Hasta qué paso de la tabla llegaste y cuánto tardó cada uno.
3. Si el mapa se ve completo, nítido y fluido, y si los toques responden en el lugar correcto.
4. **Espejo con el iPhone en horizontal** (por ejemplo, un vídeo de YouTube a pantalla completa): si
   la imagen se ve derecha en el tablero girando el iPhone hacia un lado y hacia el otro. Y con los
   **botones del manillar** activados, si el recuadro de música del tablero dice «OpenCfMoto < > move»
   sin cuadros vacíos.
5. El archivo de registros compartido (y el `.h264` si algo se ve mal).
