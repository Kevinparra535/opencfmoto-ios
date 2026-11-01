# Instalar en el iPhone sin Mac (TestFlight)

*Español primero · [English below](#english)*

GitHub compila la app en un Mac en la nube, la firma con tu cuenta de Apple Developer y la sube a
**TestFlight**. Tú la instalas en el iPhone con la app TestFlight. No necesitas un Mac: todo se hace
desde el navegador. La primera vez lleva unos 30–45 minutos, casi todo de espera.

Es solo para ti (pruebas internas de TestFlight). Distribuirla a otras personas requiere el permiso de
los autores originales (ver [Seguridad y licencia](#seguridad-y-licencia)).

## Qué necesitas

- Tu cuenta **de pago** de Apple Developer (como titular de la cuenta).
- Un navegador. Para copiar la clave del paso 1 viene bien una computadora (Windows o Linux sirven).
- Un iPhone con **iOS 17** o posterior y la app **TestFlight** (gratis en la App Store).

En los pasos siguientes, `com.kevinparra535` es el prefijo de los identificadores: por defecto es
`com.` seguido del dueño del repositorio en GitHub, en minúsculas. En tu propia copia (*fork*) es
`com.` + tu usuario en minúsculas, y antes hay que habilitar los workflows en su pestaña **Actions**.
Si creas la variable `BUNDLE_ID_PREFIX` (paso 2, opcional), se usa el prefijo que pongas ahí. El
resumen del paso 3 muestra los identificadores exactos.

## 1. Crea una clave de la API de App Store Connect

1. Entra en [appstoreconnect.apple.com](https://appstoreconnect.apple.com) ▸ **Usuarios y acceso**
   (*Users and Access*) ▸ **Integraciones** (*Integrations*) ▸ **API de App Store Connect**
   (*App Store Connect API*).
2. Si es la primera vez, pulsa **Solicitar acceso** (*Request Access*) y acepta las condiciones.
3. En **Claves de equipo** (*Team Keys*) pulsa **+** (*Generate API Key*):
   - Nombre: `GitHub`
   - Acceso: **Administrador** (*Admin*). Hace falta para crear el certificado temporal y los
     perfiles de firma.
4. Anota el **ID del emisor** (*Issuer ID*, encima de la tabla) y el **ID de la clave** (*Key ID*).
5. Pulsa **Descargar** (*Download API Key*). Apple solo deja descargarla **una vez**: es un archivo
   `AuthKey_XXXXXXXXXX.p8`.

## 2. Guarda la clave en GitHub

En el repositorio: **Settings** ▸ **Secrets and variables** ▸ **Actions** ▸ **New repository
secret**. Crea estos tres secretos:

| Nombre | Valor |
|---|---|
| `ASC_KEY_ID` | El *Key ID* (10 caracteres) |
| `ASC_ISSUER_ID` | El *Issuer ID* (con guiones, por ejemplo `69a6de7e-…`) |
| `ASC_PRIVATE_KEY` | Todo el contenido del archivo `.p8`: ábrelo con el Bloc de notas (o cualquier editor de texto) y copia desde `-----BEGIN PRIVATE KEY-----` hasta `-----END PRIVATE KEY-----`, ambas líneas incluidas |

Después guarda el `.p8` en un lugar seguro o bórralo: con él se puede administrar tu cuenta de App
Store Connect.

*Opcional:* en la pestaña **Variables** puedes crear `BUNDLE_ID_PREFIX` con otro prefijo. Si no
existe, se usa `com.` + el dueño del repositorio en minúsculas (aquí, `com.kevinparra535`).

## 3. Prepara (registra los identificadores)

En GitHub: **Actions** ▸ **TestFlight** ▸ **Run workflow** ▸ marca **Solo preparar** ▸ **Run
workflow**.

En un minuto termina. Abre la ejecución: el resumen confirma que tu clave funciona, muestra los dos
identificadores que registró en tu cuenta (`com.kevinparra535.opencfmoto` para la app y
`com.kevinparra535.opencfmoto.mirror` para la extensión de espejo) y lo que falta.

## 4. Crea el App Group y asígnalo

La API de Apple no permite este paso, así que se hace en la web:

1. [developer.apple.com/account](https://developer.apple.com/account) ▸ **Certificates, IDs &
   Profiles** ▸ **Identifiers** ▸ botón **+** ▸ **App Groups** ▸ **Continue**.
2. *Description*: `OpenCfMoto` · *Identifier*: `group.com.kevinparra535.opencfmoto` ▸ **Continue** ▸
   **Register**.
3. En **Identifiers**, cambia el filtro de arriba a la derecha a **App IDs** y abre
   `com.kevinparra535.opencfmoto`. En la fila **App Groups** pulsa **Configure** (o **Edit**), marca
   `group.com.kevinparra535.opencfmoto` ▸ **Continue** ▸ **Save** ▸ **Confirm**.
4. Repite el punto 3 con `com.kevinparra535.opencfmoto.mirror`.

## 5. Crea la app en App Store Connect

[appstoreconnect.apple.com](https://appstoreconnect.apple.com) ▸ **Apps** ▸ **+** ▸ **Nueva app**
(*New App*):

- Plataforma: **iOS**
- Nombre: `OpenCfMoto`. Si dice que está ocupado, usa otro, por ejemplo `OpenCfMoto KP`: solo lo ves tú.
- Idioma principal: **Español**
- ID del paquete (*Bundle ID*): `com.kevinparra535.opencfmoto`
- SKU: `opencfmoto`
- Acceso de usuario: **Acceso completo**

Pulsa **Crear**. No hace falta rellenar nada más, porque no se publica en la App Store.

## 6. Compila y sube

**Actions** ▸ **TestFlight** ▸ **Run workflow**, ahora **sin** marcar *Solo preparar*. Es una
ejecución nueva: el botón *Re-run* de la ejecución del paso 3 repetiría «Solo preparar». Tarda unos
20–40 minutos, repartidos en tres trabajos (*jobs*):

1. **Prepare (App Store Connect)**, un minuto: comprueba la clave, los identificadores y la app.
2. **Build, sign and upload (macOS)**: un Mac de GitHub elige el número de build, compila la app con
   Xcode 26, la firma con un certificado temporal y la sube a App Store Connect.
3. **Processing, TestFlight group, revoke the certificate**: espera a que Apple la procese (de 5 a
   30 minutos), te añade al grupo de pruebas internas «OpenCfMoto (interno)» (solo a ti, el titular
   de la cuenta) y revoca el certificado temporal.

Al terminar en verde, el apartado «TestFlight — resultado / result» del resumen dice si la build ya
está lista en TestFlight. Si Apple tarda más de 90 minutos en procesarla, la ejecución también acaba
en verde, pero con el aviso «La build sigue en proceso / Build still processing»: la build aparecerá
en TestFlight cuando Apple termine.

## 7. Instálala en el iPhone

1. Instala **TestFlight** desde la App Store.
2. Abre TestFlight con el mismo Apple ID de tu cuenta de desarrollador. Si te llegó el correo de
   invitación de TestFlight (Apple suele enviarlo), también puedes abrirlo en el iPhone y pulsar
   **Ver en TestFlight**.
3. **OpenCfMoto** ▸ **Instalar**.

Si no aparece, comprueba que TestFlight usa ese mismo Apple ID y mira si la ejecución dejó el aviso
«TestFlight: añade el tester a mano / add the tester by hand».

Para la primera prueba con la moto sigue [PRUEBA-EN-LA-MOTO.md](PRUEBA-EN-LA-MOTO.md). Sáltate la
parte de Xcode: la app ya está instalada.

## Actualizar

Cuando quieras una versión nueva (por ejemplo, después de un arreglo), lanza una ejecución nueva:
**Actions** ▸ **TestFlight** ▸ **Run workflow**. El número de build sube solo y TestFlight suele
avisarte.
Cada build caduca a los 90 días; para seguir usando la app, lanza otra ejecución.

## Si algo falla

Una ejecución en rojo explica el motivo y lo que hay que hacer, en español y en inglés, en el cuadro
**Annotations** de la ejecución y en su resumen. Copia ese texto: describe el problema y es lo que
hace falta para pedir ayuda (por ejemplo, en un *issue* del repositorio). Los títulos más comunes:

| Título del aviso | Qué hacer |
|---|---|
| Faltan secretos / Missing secrets<br>ASC_PRIVATE_KEY no válida / invalid<br>Clave de API rechazada / API key rejected (401) | Revisa los tres secretos del paso 2: el `.p8` completo, sin cortar, y el *Key ID* y el *Issuer ID* de una clave **de equipo** |
| Permiso denegado / Not allowed (403) | La clave no es de **Administrador**: crea otra en el paso 1 y actualiza `ASC_KEY_ID` y `ASC_PRIVATE_KEY` (si ya lo es, mira la fila siguiente) |
| Acuerdos pendientes / Agreements to accept (403) | Como titular, entra en [developer.apple.com/account](https://developer.apple.com/account) y acepta el acuerdo que aparece arriba; después, en App Store Connect ▸ **Negocios** (*Business*), acepta lo que esté pendiente |
| Bundle ID no disponible / Bundle ID not available<br>Prefijo no válido / Invalid prefix | Crea o corrige la variable `BUNDLE_ID_PREFIX` (paso 2) con un prefijo tuyo, como `com.tunombre`. Si «Bundle ID no disponible» sale en la primera ejecución, prueba antes con una ejecución nueva: puede ser pasajero |
| Falta la app en App Store Connect / App record missing | Pasos 4 y 5 |
| Falta el App Group en los perfiles / App Group missing from the profiles<br>TestFlight: App Group | Paso 4, en los **dos** identificadores |
| Límite de certificados / Certificate limit | developer.apple.com ▸ **Certificates**: revoca los *Apple Distribution* que no uses |
| Apple rechazó la subida / Apple rejected the upload<br>Apple rechazó la build / Apple rejected the build | El motivo (códigos `ITMS-…`) viene en el correo de Apple o en los avisos titulados «App Store Connect». Suele hacer falta un cambio en el código: pide ayuda con ese texto |
| La build ya existe / Build already exists<br>Fallo temporal de Apple / Temporary Apple error (404)<br>Error de red / Network error<br>App Store Connect no responde / not responding (5xx)<br>Límite de peticiones / Rate limited (429) | Nada que corregir: espera unos minutos (una hora si es el 429) y lanza una ejecución nueva |
| La build sigue en proceso / Build still processing (aviso, en una ejecución en verde) | Nada: Apple tarda más de lo normal; la build aparecerá en TestFlight cuando termine |
| TestFlight: añade el tester a mano / add the tester by hand (aviso) | Añádete tú, como dice el aviso: App Store Connect ▸ **Apps** ▸ OpenCfMoto ▸ **TestFlight** ▸ **Pruebas internas** ▸ el grupo ▸ **Testers** **+** |
| Limpieza incompleta / Cleanup incomplete<br>Revoca a mano / Revoke by hand<br>Certificado sin confirmar / Certificate not confirmed | Lo que diga el aviso. A veces no hace falta nada (la próxima ejecución lo intenta otra vez). Si pide revocar a mano, en developer.apple.com: solo el certificado *Apple Distribution* que describe (**Certificates**: el creado hoy, o el de la fecha de caducidad que da) y solo los perfiles que nombra (**Profiles**: los de esa ejecución, nunca todos los «OpenCfMoto CI …»). El *id* entre paréntesis es solo una referencia: esas listas no lo muestran |
| Cualquier otro | Haz lo que diga el aviso y lanza una ejecución nueva; si se repite, pide ayuda con ese texto |

**Para reintentar**, cuando hayas hecho lo que dice el aviso, lanza siempre una ejecución **nueva**:
**Actions** ▸ **TestFlight** ▸ **Run workflow**. El botón **Re-run jobs** de una ejecución terminada
repite el mismo commit (sin los arreglos subidos después) y las mismas opciones (con «Solo preparar»,
no compila).

Lo que el workflow resuelve solo:

- Cada ejecución elige su número de build (uno más que el último que tiene Apple): ni una ejecución
  nueva ni un *Re-run* chocan con una build anterior.
- Si el archivo ya llegó a Apple y después algo falla en el trabajo «Build, sign and upload (macOS)»,
  el trabajo «Processing, TestFlight group, revoke the certificate» espera igualmente a la build y
  luego revoca el certificado temporal.
- Si una ejecución se interrumpe (por ejemplo, si la cancelas) y deja restos (perfiles
  «OpenCfMoto CI …» y su certificado temporal), los borra el último trabajo de esa ejecución o, si
  no, la siguiente al prepararse, con la nota «Restos borrados / Leftovers removed». No tienes que
  hacer nada. Solo se borran perfiles con el nombre exacto que les da el workflow: los de este
  repositorio siempre; los de otro repositorio (un *fork*) o de un Mac con la misma cuenta, solo
  si tienen más de 12 horas, porque esa otra ejecución podría seguir en marcha. Tus propios
  perfiles no se tocan, ni ningún certificado que use alguno de ellos.
- Apple puede enviarte un correo por cada certificado temporal revocado (uno por ejecución, alguno
  más si se borraron restos). Es normal.

## Seguridad y licencia

- La clave queda cifrada en los secretos de GitHub. Solo quien puede escribir en el repositorio
  puede lanzar el workflow, y la clave nunca aparece en los registros, que son públicos porque el
  repositorio lo es. No se publica ningún archivo de la app como artefacto.
- Si crees que la clave se filtró, revócala en App Store Connect (paso 1) y crea otra.
- **Solo pruebas internas, para ti.** La licencia AGPL del proyecto original es difícil de
  compatibilizar con las condiciones de la App Store. Distribuir la app a otras personas, ya sea con
  pruebas externas, un enlace público de TestFlight o la App Store, requiere el permiso de sus
  titulares.

---

## English

GitHub builds the app on a cloud Mac, signs it with your Apple Developer account and uploads it to
**TestFlight**. You install it with the TestFlight app. No Mac needed: everything happens in a browser.

1. **API key**: App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API ▸ (Request
   Access) ▸ Team Keys ▸ **+**, access **Admin**. Note the Issuer ID and the Key ID, then download the
   `.p8` (one download only).
2. **GitHub secrets** (Settings ▸ Secrets and variables ▸ Actions): `ASC_KEY_ID`, `ASC_ISSUER_ID`,
   `ASC_PRIVATE_KEY` (the whole `.p8` text). Optional variable `BUNDLE_ID_PREFIX`; the default prefix
   is `com.` + the repository owner in lower case (here `com.kevinparra535`). In a fork it is `com.` +
   your user name in lower case, and you must first enable workflows in the fork's **Actions** tab.
3. Actions ▸ **TestFlight** ▸ Run workflow with **Solo preparar** (setup only). This checks the key and
   registers `<prefix>.opencfmoto` and `<prefix>.opencfmoto.mirror` (its summary shows the exact
   identifiers).
4. developer.apple.com ▸ Identifiers: register the App Group `group.<prefix>.opencfmoto` and assign it to
   **both** App IDs (App Groups ▸ Configure). The API cannot do this.
5. App Store Connect ▸ Apps ▸ **+** New App: iOS, any free name, bundle ID `<prefix>.opencfmoto`, SKU
   `opencfmoto`. The API cannot create apps.
6. Start a new run without *Solo preparar* (a *Re-run* of step 3 would repeat setup only). Its jobs:
   **Prepare (App Store Connect)**; **Build, sign and upload (macOS)** picks the build number, builds
   with Xcode 26, signs with a temporary distribution certificate and uploads; **Processing,
   TestFlight group, revoke the certificate** waits for Apple's processing, adds only the Account
   Holder (you) to the internal group "OpenCfMoto (interno)" and revokes the temporary certificate.
   On a green run, the "TestFlight — resultado / result" summary says whether the build is ready. If
   Apple takes longer than the 90-minute wait, the run still ends green, with the warning "La build
   sigue en proceso / Build still processing", and the build shows up in TestFlight once Apple is done.
7. On the iPhone: install TestFlight, open it with your developer account's Apple ID (or the
   invitation e-mail, which Apple usually sends) and install OpenCfMoto.

**If a run fails**, its Annotations box and summary say why and what to do, in Spanish and English; the
table under [Si algo falla](#si-algo-falla) lists the usual titles.

- Fix it, then start a **new** run (Actions ▸ TestFlight ▸ Run workflow): *Re-run jobs* repeats the
  same commit and inputs.
- Each run picks its own build number (one above Apple's highest), so new runs and re-runs never
  collide.
- If the file already reached Apple when something in the build job fails, the last job still waits
  for the build, then revokes the temporary certificate.
- Leftovers of an interrupted run ("OpenCfMoto CI …" profiles and their temporary certificate) are
  removed by that run's last job or by the next run's preparation, with the notice "Restos borrados /
  Leftovers removed": nothing to do. Only profiles with the exact names the workflow gives are
  removed: this repository's always; another repository's (a fork) or a Mac's with the same account
  only when older than 12 hours, as that run may still be going. Your own profiles are never touched,
  nor any certificate one of them uses.
- Apple may e-mail you about each revoked temporary certificate; that is expected.

Builds expire after 90 days: start a new run to keep using the app.

Internal testing only: distributing the app to anyone else needs permission from the upstream AGPL
copyright holders.
