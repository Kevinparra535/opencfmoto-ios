# Media / Imágenes

## social-preview.png

`social-preview.png` (1280 × 640 PNG, about 135 KB) is the image GitHub, LinkedIn and chat apps show
when someone shares a link to this repository.

### Upload it (repository owner, once)

GitHub does not read it from the repository: it has to be uploaded in the settings.

1. Open the repository on GitHub ▸ **Settings** ▸ **General**.
2. Under **Social preview**, click **Edit** ▸ **Upload an image…** and choose
   `docs/media/social-preview.png` (download it first from this folder: open the file ▸ **Download
   raw file**).
3. Check the preview that GitHub shows, then share the repository link.

LinkedIn keeps the preview it saw first for a while. If a post shows an old or empty card, paste the
repository URL into LinkedIn's [Post Inspector](https://www.linkedin.com/post-inspector/) to refresh it
before posting.

### What is in it, and the rules for changing it

- Left: the 800 × 384 dash frame `docs/screenshots/readme/dash-map.png` in a dash-style bezel, with
  "Map © OpenStreetMap contributors" under it. It is what the app streamed to the simulated dash in
  the CI E2E run (the `music` scenario: OpenStreetMap tiles along the demo route, the demo song's
  cover, no tile ids or test labels).
- Right: the app icon, "OpenCfMoto for iOS", a one-line pitch, the model chips
  450MT · 800MT · 450SR · 675SR-R and "Open source · AGPL-3.0 · Swift / SwiftUI".
- Colours are the app's own (`App/Sources/UI/Common/Theme.swift`); the type is Inter.
- Everything important stays 40 px inside the edges, so LinkedIn's 1.91:1 crop keeps it.
- Keep it that way: no CFMOTO, Carbit or Apple logos, no photos of real bikes or plates, no map
  positions other than the demo route (public streets and parks), no snapshot-test placeholders
  (tile ids, artwork ids) and no screenshots of the real app with personal data (Garage, Logs,
  Wi-Fi screens, the dash QR). Every picture with OpenStreetMap tiles carries the caption
  "© OpenStreetMap contributors" on the image (here) or right under it (the README strip).
- GitHub needs a PNG, JPG or GIF under 1 MB; 1280 × 640 is the recommended size.

### Regenerate it

```sh
python3 docs/media/make_social_preview.py
```

It needs Pillow and the Inter typeface (`fonts-inter` on Debian / Ubuntu; pass another folder with
`--fonts`). The script reads only images from this repository and refuses to write a file over 1 MB.

## The README images

`docs/screenshots/readme/`: `phone-home.png` and `phone-dash-view.png` are iOS simulator screenshots in
demo mode. `dash-map.png`, `dash-apple-music.png` and `dash-portrait.png` are frames the app streamed to
the simulated dash in the CI E2E run (the `music` scenario's map and Music sheet frames, and the last
frame of the `cfdl26` scenario, downscaled to 624 × 736), copied from the run's evidence and saved as
palette PNGs under 300 KB. To refresh them, take the same frames from a newer E2E run; never use
snapshot-test renders with placeholder tiles, and keep the OpenStreetMap caption under the strip.

---

**Resumen en español.** `social-preview.png` es la imagen que muestran GitHub, LinkedIn y las apps de
chat al compartir el enlace del repositorio. GitHub no la lee del repositorio: el dueño la sube una vez
en **Settings** ▸ **General** ▸ **Social preview** ▸ **Edit** ▸ **Upload an image…** (primero
descárgala con **Download raw file**). Si LinkedIn muestra una tarjeta vieja, pega la URL del
repositorio en su [Post Inspector](https://www.linkedin.com/post-inspector/) antes de publicar. Solo
lleva imágenes de demostración del propio repositorio: el mapa de OpenStreetMap de la ruta de
demostración (con el crédito «Map © OpenStreetMap contributors» en la imagen), sin logotipos de CFMOTO,
Carbit o Apple, fotos de motos reales, otras ubicaciones ni capturas de la app con datos personales
(Garaje, Registros, pantallas de Wi-Fi o el QR del tablero). Para regenerarla:
`python3 docs/media/make_social_preview.py` (con Pillow y la fuente Inter). Las imágenes del README son
fotogramas que la app envió al tablero simulado en la prueba E2E de la CI y capturas del simulador.
