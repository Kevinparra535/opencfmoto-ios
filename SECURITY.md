# Security policy / Política de seguridad

## Report a vulnerability / Reportar una vulnerabilidad

Please report it **privately** with GitHub's
[Report a vulnerability](https://github.com/Kevinparra535/opencfmoto-ios/security/advisories/new) form
(the repository's **Security** tab ▸ **Report a vulnerability**). Do not post any details in a public
issue, pull request or discussion.

If the **Report a vulnerability** button or form is unavailable, open an issue titled
"Security contact request" (the **Bug or idea** form) with no details, and we will reply with a private
channel.

Repórtala **en privado** con el formulario
[Report a vulnerability](https://github.com/Kevinparra535/opencfmoto-ios/security/advisories/new) de
GitHub (pestaña **Security** del repositorio ▸ **Report a vulnerability**). No publiques ningún detalle
en una incidencia, una pull request ni una discusión públicas.

Si no ves el botón o el formulario **Report a vulnerability**, abre una incidencia titulada
«Security contact request» (formulario **Error o idea**) sin detalles y te responderemos con un canal
privado.

Include what you can: the app version and build (About screen), the iPhone model and iOS version, the
bike or dash model, the steps to reproduce and what an attacker could do. Attach logs only **after
removing** Wi-Fi network names (SSIDs), MAC addresses, serial numbers, passwords, pairing QR codes and
locations. Never send keys or tokens (for example an App Store Connect key).

Incluye lo que puedas: versión y compilación de la app (pantalla Acerca de), modelo de iPhone y versión
de iOS, modelo de moto o tablero, los pasos para reproducirlo y lo que podría hacer un atacante. Adjunta
registros solo **después de quitar** nombres de redes Wi-Fi (SSID), direcciones MAC, números de serie,
contraseñas, códigos QR de emparejamiento y ubicaciones. Nunca envíes claves ni tokens (por ejemplo, una
clave de App Store Connect).

## Scope / Alcance

In scope / Incluido:

- the iOS app and its mirror (ReplayKit) extension, and the Swift packages in `Packages/` /
  la app de iOS, su extensión de espejo (ReplayKit) y los paquetes Swift de `Packages/`;
- the GitHub Actions workflows and the tools in this repository (CI, TestFlight, release builds,
  `tools/`) / los workflows de GitHub Actions y las herramientas de este repositorio.

Out of scope / Fuera del alcance:

- dash firmware and the official CFMOTO / Carbit apps: report them to the vendor / el firmware del
  tablero y las apps oficiales de CFMOTO / Carbit: repórtalo al fabricante;
- Apple's platforms and services / las plataformas y servicios de Apple;
- the public map services the app uses (OpenStreetMap tiles, Photon, Nominatim, Overpass, Valhalla,
  OSRM, openrouteservice): tell their operators / los servicios de mapas públicos que usa la app:
  avisa a quien los opera;
- OpenCfMoto for Android: report it upstream / la app Android: repórtalo en el proyecto original,
  <https://github.com/zanderp/open-cfmoto>.

## Supported versions / Versiones

The latest commit on `main` and the latest release built from it. / El último commit de `main` y la
última versión publicada a partir de él.

## What to expect / Qué esperar

This is a volunteer project, so it is best effort: we aim to acknowledge a report within 7 days, fix it
on `main`, publish a GitHub security advisory and credit you in it if you want.

Es un proyecto de voluntarios, así que hacemos lo posible: intentamos responder en 7 días, corregirlo en
`main`, publicar un aviso de seguridad en GitHub y darte el crédito si quieres.
