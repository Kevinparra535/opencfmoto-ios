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

En los pasos siguientes, `com.kevinparra535` es el prefijo de los identificadores. Si configuras otro
(paso 2, opcional), usa el tuyo en su lugar.

## 1. Crea una clave de la API de App Store Connect

1. Entra en [appstoreconnect.apple.com](https://appstoreconnect.apple.com) ▸ **Usuarios y acceso**
   (*Users and Access*) ▸ **Integraciones** (*Integrations*) ▸ **API de App Store Connect**.
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
existe, se usa `com.kevinparra535`.

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

**Actions** ▸ **TestFlight** ▸ **Run workflow**, ahora **sin** marcar *Solo preparar*. Tarda unos
20–40 minutos:

1. Un Mac de GitHub compila la app con Xcode 26 y la firma con un certificado temporal.
2. La sube a App Store Connect.
3. Espera a que Apple la procese (de 5 a 30 minutos), te añade al grupo de pruebas internas
   «OpenCfMoto (interno)» y revoca el certificado temporal.

Cuando la ejecución termina en verde, el resumen dice que la build está lista en TestFlight.

## 7. Instálala en el iPhone

1. Instala **TestFlight** desde la App Store.
2. Abre en el iPhone el correo de invitación de TestFlight y pulsa **Ver en TestFlight**. También
   puedes abrir TestFlight con el mismo Apple ID de tu cuenta de desarrollador.
3. **OpenCfMoto** ▸ **Instalar**.

Para la primera prueba con la moto sigue [PRUEBA-EN-LA-MOTO.md](PRUEBA-EN-LA-MOTO.md). Sáltate la
parte de Xcode: la app ya está instalada.

## Actualizar

Cuando quieras una versión nueva (por ejemplo, después de un arreglo): **Actions** ▸ **TestFlight**
▸ **Run workflow**. El número de build sube solo y TestFlight te avisa. Cada build caduca a los 90
días; para seguir usándola, vuelve a ejecutar el workflow.

## Si algo falla

La ejecución en rojo muestra el motivo arriba (**Annotations**) y en el resumen, junto con lo que
hay que hacer. Mándame ese texto. Los casos más comunes:

| Mensaje | Qué hacer |
|---|---|
| Faltan secretos / clave no válida | Revisa los tres secretos del paso 2 (el `.p8` completo, sin cortar) |
| Acuerdos pendientes | App Store Connect ▸ **Negocios** (*Business*): acepta el acuerdo nuevo del Apple Developer Program |
| No existe la app | Paso 5 |
| Falta el App Group | Paso 4 (en los **dos** identificadores) |
| Límite de certificados | developer.apple.com ▸ **Certificates**: revoca los *Apple Distribution* que no uses (o espera a que termine otra ejecución) |
| Apple rechazó la build | Revisa el correo de App Store Connect, que trae códigos `ITMS-…`, y mándamelo |

Después de cada ejecución Apple puede enviarte un correo diciendo que se revocó un certificado. Es
normal: es el certificado temporal de esa ejecución.

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
   `ASC_PRIVATE_KEY` (the whole `.p8` text). Optional variable `BUNDLE_ID_PREFIX` (default
   `com.<repository owner>`).
3. Actions ▸ **TestFlight** ▸ Run workflow with **Solo preparar** (setup only). This checks the key and
   registers `<prefix>.opencfmoto` and `<prefix>.opencfmoto.mirror`.
4. developer.apple.com ▸ Identifiers: register the App Group `group.<prefix>.opencfmoto` and assign it to
   **both** App IDs (App Groups ▸ Configure). The API cannot do this.
5. App Store Connect ▸ Apps ▸ **+** New App: iOS, any free name, bundle ID `<prefix>.opencfmoto`, SKU
   `opencfmoto`. The API cannot create apps.
6. Run the workflow again without *Solo preparar*. It builds with Xcode 26, signs with a temporary
   distribution certificate, uploads, waits for Apple's processing, adds you to the internal group
   "OpenCfMoto (interno)" and revokes the temporary certificate (Apple may email you about the
   revocation; that is expected).
7. On the iPhone: install TestFlight, open the invitation, install OpenCfMoto.

Internal testing only: distributing the app to anyone else needs permission from the upstream AGPL
copyright holders.
