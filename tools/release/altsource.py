#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""AltStore / SideStore source and release notes for the sideload IPA, read from the IPA itself.

AltStore (and SideStore, its fork) refuse to install an app whose source entry does not match the
IPA they download: the bundle id, the version and build, the SHA-256 when one is given, and every
entitlement and every NS...UsageDescription key of the app AND of its extensions must be declared.
So everything here comes from the final IPA (tools/release/package_ipa.sh): the Info.plists, the
entitlements in the code signature of each bundle's executable, the file's size and SHA-256.
Python 3.9+ standard library only; .github/workflows/release.yml runs it with `python3 -I`.

usage:
  altsource.py --ipa OpenCfMoto-v0.1.0-sideload.ipa --repo OWNER/NAME --tag v0.1.0
               [--commit SHA] [--run-url URL] [--date YYYY-MM-DD] [--colorset DIR]
               --source-out altstore-source.json [--notes-out RELEASE_NOTES.md]

Writes nothing when a check fails (exit 1, the reason as an ::error annotation): exactly one app in
Payload/; its bundle id ends in .opencfmoto; CFBundleShortVersionString is the tag without "v";
every extension has an id under the app's and the app's version and build; every bundle is signed
(its entitlements are what AltStore compares). Exit 2: usage.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import struct
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_COLORSET = os.path.join(ROOT, "App", "Resources", "Assets.xcassets", "AccentColor.colorset")
ICON_PATH = "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
UPSTREAM = "https://github.com/zanderp/open-cfmoto"

# Entitlements a re-signing tool replaces with its own (AltStore does not compare them either).
IGNORED_ENTITLEMENTS = {"application-identifier", "com.apple.developer.team-identifier", "get-task-allow"}
PRIVACY_KEY_RE = re.compile(r"^NS[A-Za-z]+UsageDescription$")
TAG_RE = re.compile(r"^v([0-9]+\.[0-9]+\.[0-9]+)$")
REPO_RE = re.compile(r"^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$")
APP_PLIST_RE = re.compile(r"^Payload/([^/]+\.app)/Info\.plist$")

# Mach-O and code signature constants (<mach-o/loader.h>, <mach-o/fat.h>, xnu cs_blobs.h).
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
MH_MAGIC, MH_MAGIC_64 = 0xFEEDFACE, 0xFEEDFACF
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSSLOT_ENTITLEMENTS = 5


class Refused(Exception):
    """A check failed: nothing is written."""


# ---------------------------------------------------------------- code signature entitlements

def _slices(data: bytes) -> list:
    """The Mach-O images of an executable: itself, or each architecture of a fat (universal) file."""
    if len(data) < 8:
        raise Refused("the executable is too short to be a Mach-O file")
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        return [data]
    count = struct.unpack_from(">I", data, 4)[0]
    size = 20 if magic == FAT_MAGIC else 32
    images = []
    for i in range(count):
        if magic == FAT_MAGIC:
            _cpu, _sub, offset, length, _align = struct.unpack_from(">iiIII", data, 8 + i * size)
        else:
            _cpu, _sub, offset, length, _align, _reserved = struct.unpack_from(">iiQQII", data, 8 + i * size)
        if offset + length > len(data):
            raise Refused("a fat executable's architecture lies outside the file")
        images.append(data[offset:offset + length])
    return images


def _image_entitlements(image: bytes):
    """Entitlements (dict) of one Mach-O image; None when it carries no code signature."""
    if len(image) < 28:
        raise Refused("the executable is too short to be a Mach-O file")
    magic = struct.unpack_from("<I", image, 0)[0]
    if magic == MH_MAGIC_64:
        offset = 32
    elif magic == MH_MAGIC:
        offset = 28
    else:
        raise Refused("the executable is not a Mach-O file")
    ncmds = struct.unpack_from("<I", image, 16)[0]
    for _ in range(ncmds):
        if offset + 8 > len(image):
            raise Refused("the executable's load commands are cut short")
        cmd, cmdsize = struct.unpack_from("<II", image, offset)
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from("<II", image, offset + 8)
            if dataoff + datasize > len(image):
                raise Refused("the code signature lies outside the executable")
            return _signature_entitlements(image[dataoff:dataoff + datasize])
        if cmdsize < 8:
            raise Refused("the executable has a malformed load command")
        offset += cmdsize
    return None


def _signature_entitlements(blob: bytes) -> dict:
    """The XML entitlements of a code signature superblob ({} when it has none)."""
    if len(blob) < 12:
        raise Refused("the code signature is cut short")
    magic, _length, count = struct.unpack_from(">III", blob, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        raise Refused("the code signature is not an embedded signature")
    for i in range(count):
        slot, offset = struct.unpack_from(">II", blob, 12 + 8 * i)
        if slot != CSSLOT_ENTITLEMENTS:
            continue
        emagic, elength = struct.unpack_from(">II", blob, offset)
        if emagic != CSMAGIC_EMBEDDED_ENTITLEMENTS or elength < 8 or offset + elength > len(blob):
            raise Refused("the code signature has a malformed entitlements blob")
        try:
            value = plistlib.loads(blob[offset + 8:offset + elength])
        except Exception as exc:   # plistlib raises several types for bad input
            raise Refused(f"the entitlements in the code signature are not a property list ({exc})") from None
        if not isinstance(value, dict):
            raise Refused("the entitlements in the code signature are not a dictionary")
        return value
    return {}


def executable_entitlements(data: bytes, where: str) -> dict:
    """Entitlements of an executable (every architecture must carry the same)."""
    found = [_image_entitlements(image) for image in _slices(data)]
    if any(e is None for e in found):
        raise Refused(f"{where} is not signed: AltStore / SideStore read the App Group from the "
                      "IPA's signature (tools/release/package_ipa.sh signs it ad hoc)")
    if any(e != found[0] for e in found[1:]):
        raise Refused(f"the architectures of {where} carry different entitlements")
    return found[0]


# ---------------------------------------------------------------- reading the IPA

def _plist(archive: zipfile.ZipFile, name: str) -> dict:
    try:
        value = plistlib.loads(archive.read(name))
    except KeyError:
        raise Refused(f"{name} is missing from the IPA") from None
    except Exception as exc:
        raise Refused(f"{name} is not a property list ({exc})") from None
    if not isinstance(value, dict):
        raise Refused(f"{name} is not a dictionary")
    return value


def _bundle(archive: zipfile.ZipFile, path: str) -> dict:
    info = _plist(archive, f"{path}/Info.plist")
    executable = str(info.get("CFBundleExecutable") or "")
    if not executable or "/" in executable:
        raise Refused(f"{path}/Info.plist has no usable CFBundleExecutable")
    try:
        data = archive.read(f"{path}/{executable}")
    except KeyError:
        raise Refused(f"{path}/{executable} (the executable) is missing from the IPA") from None
    return {"path": path, "info": info, "entitlements": executable_entitlements(data, f"{path}/{executable}")}


def read_ipa(path: str) -> dict:
    """The app and its extensions: Info.plist, entitlements; plus the file's size and SHA-256."""
    digest = hashlib.sha256()
    size = 0
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
            size += len(chunk)
    try:
        archive = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError) as exc:
        raise Refused(f"{os.path.basename(path)} is not a zip archive (an IPA): {exc}") from None
    with archive:
        names = archive.namelist()
        apps = sorted({m.group(1) for m in map(APP_PLIST_RE.match, names) if m})
        if len(apps) != 1:
            raise Refused(f"the IPA must hold exactly one app in Payload/ (found {len(apps)})")
        app_path = f"Payload/{apps[0]}"
        extension_re = re.compile(rf"^{re.escape(app_path)}/PlugIns/([^/]+\.appex)/Info\.plist$")
        extensions = sorted({m.group(1) for m in map(extension_re.match, names) if m})
        app = _bundle(archive, app_path)
        app["extensions"] = [_bundle(archive, f"{app_path}/PlugIns/{name}") for name in extensions]
    return {"app": app, "size": size, "sha256": digest.hexdigest()}


def check(ipa: dict, version: str) -> None:
    """The rules AltStore enforces (and ours): see the module docstring."""
    info = ipa["app"]["info"]
    bundle_id = str(info.get("CFBundleIdentifier") or "")
    if not re.fullmatch(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.opencfmoto", bundle_id):
        raise Refused(f"the app's bundle id «{bundle_id}» does not end in .opencfmoto")
    short = str(info.get("CFBundleShortVersionString") or "")
    build = str(info.get("CFBundleVersion") or "")
    if short != version:
        raise Refused(f"the app is version «{short}», the tag says {version}")
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", build):
        raise Refused(f"the app's build number «{build}» is not a number")
    for ext in ipa["app"]["extensions"]:
        einfo, name = ext["info"], os.path.basename(ext["path"])
        ext_id = str(einfo.get("CFBundleIdentifier") or "")
        if not ext_id.startswith(bundle_id + "."):
            raise Refused(f"the extension {name} has the id «{ext_id}», not one under «{bundle_id}»")
        for key, want in (("CFBundleShortVersionString", short), ("CFBundleVersion", build)):
            if str(einfo.get(key) or "") != want:
                raise Refused(f"the extension {name} has {key} «{einfo.get(key)}», the app {want}")


def permissions(ipa: dict) -> dict:
    """appPermissions: every entitlement and NS...UsageDescription of the app and its extensions
    (the app's purpose string wins when both have the key)."""
    bundles = [ipa["app"]] + ipa["app"]["extensions"]
    entitlements = set()
    privacy = {}
    for bundle in bundles:
        entitlements.update(key for key in bundle["entitlements"] if key not in IGNORED_ENTITLEMENTS)
        for key, value in bundle["info"].items():
            if PRIVACY_KEY_RE.match(key) and key not in privacy:
                privacy[key] = str(value)
    return {"entitlements": sorted(entitlements), "privacy": dict(sorted(privacy.items()))}


# ---------------------------------------------------------------- tint colour

def tint_color(colorset: str):
    """The accent colour as AltStore wants it (6 hex digits), from an Xcode .colorset; None when
    it cannot be read (the field is optional; a malformed one would make AltStore reject the source)."""
    try:
        with open(os.path.join(colorset, "Contents.json"), encoding="utf-8") as fh:
            doc = json.load(fh)
        components = doc["colors"][0]["color"]["components"]
        rgb = []
        for key in ("red", "green", "blue"):
            raw = str(components[key]).strip()
            if raw.lower().startswith("0x"):
                value = int(raw, 16)
            elif "." in raw:
                value = round(float(raw) * 255)
            else:
                value = int(raw)
            if not 0 <= value <= 255:
                return None
            rgb.append(value)
    except (OSError, ValueError, KeyError, IndexError, TypeError):
        return None
    return "".join(f"{v:02X}" for v in rgb)


# ---------------------------------------------------------------- outputs

def source_document(ipa: dict, args, version: str) -> dict:
    info = ipa["app"]["info"]
    owner, _name = args.repo.split("/", 1)
    site = f"https://github.com/{args.repo}"
    ref = args.commit or args.tag
    icon = f"https://raw.githubusercontent.com/{args.repo}/{ref}/{ICON_PATH}"
    ipa_name = os.path.basename(args.ipa)
    download = f"{site}/releases/download/{args.tag}/{ipa_name}"
    build = str(info.get("CFBundleVersion"))
    version_notes = (f"Sideload build {version} ({build}): join the bike Wi-Fi in Settings ▸ Wi-Fi (the app "
                     f"copies the password). Release notes: {site}/releases/tag/{args.tag} · Versión para "
                     "instalar con tu Apple ID: te unes al Wi-Fi de la moto en Ajustes ▸ Wi-Fi.")
    description = (
        "Your own map, turn-by-turn guidance and Apple Music on CFMOTO MotoPlay and other Carbit / "
        "EasyConnect motorcycle dashboards, streamed from the iPhone over the bike's Wi-Fi.\n\n"
        "Sideload build: join the bike Wi-Fi yourself in Settings ▸ Wi-Fi when the app asks (it shows the "
        "network and copies the password); it cannot join or read Wi-Fi networks by itself. Screen "
        "mirroring is best effort. Set the route before you ride: never handle the phone while riding.\n\n"
        "Tu propio mapa, navegación giro a giro y Apple Music en el tablero de tu moto CFMOTO, por el Wi-Fi "
        "de la moto. Te unes al Wi-Fi de la moto en Ajustes ▸ Wi-Fi cuando la app te lo pide. Fija la ruta "
        "antes de salir: nunca manipules el teléfono mientras conduces.\n\n"
        f"Community iOS port of OpenCfMoto (Android) by Alexandru Popa (zanderp): {UPSTREAM}. Not affiliated "
        "with CFMOTO, Carbit or Apple. Free software under the GNU AGPL v3 or later, with no warranty: "
        f"source at {site}")
    tint = tint_color(args.colorset)
    app = {
        "name": "OpenCfMoto",
        "bundleIdentifier": str(info.get("CFBundleIdentifier")),
        "developerName": "OpenCfMoto for iOS contributors",
        "subtitle": "Map and turn-by-turn on your bike's dash",
        "localizedDescription": description,
        "iconURL": icon,
        "category": "utilities",
        "versions": [{
            "version": version,
            "buildVersion": build,
            "date": args.date,
            "localizedDescription": version_notes,
            "downloadURL": download,
            "size": ipa["size"],
            "sha256": ipa["sha256"],
            "minOSVersion": str(info.get("MinimumOSVersion") or "17.0"),
        }],
        # The same version in the single-version fields older AltStore / SideStore releases read.
        "version": version,
        "versionDate": args.date,
        "versionDescription": version_notes,
        "downloadURL": download,
        "size": ipa["size"],
        "appPermissions": permissions(ipa),
    }
    source = {
        "name": "OpenCfMoto for iOS",
        "identifier": f"io.github.{owner.lower()}.opencfmoto.source",
        "subtitle": "Own navigation UI on CFMOTO / Carbit EasyConnect dashes",
        "description": (f"Community iOS port of OpenCfMoto (Android, by Alexandru Popa / zanderp). Not "
                        f"affiliated with CFMOTO, Carbit or Apple. AGPL-3.0: source at {site}"),
        "iconURL": icon,
        "website": site,
        "apps": [app],
        "news": [],
    }
    if tint:
        source["tintColor"] = tint
        app["tintColor"] = tint
    return source


def release_notes(ipa: dict, args, version: str) -> str:
    info = ipa["app"]["info"]
    site = f"https://github.com/{args.repo}"
    ipa_name = os.path.basename(args.ipa)
    guide = f"{site}/blob/main/docs/INSTALAR.md"
    source_url = f"{site}/releases/latest/download/altstore-source.json"
    commit = f" = commit `{args.commit}`" if args.commit else ""
    built_by = f"[workflow run]({args.run_url})" if args.run_url else "`.github/workflows/release.yml`"
    minos = str(info.get("MinimumOSVersion") or "17.0")
    lines = [
        f"## OpenCfMoto for iOS {args.tag} — sideload build (beta)",
        "",
        f"**ES:** versión para instalar con tu propio Apple ID, sin cuenta de pago (SideStore, AltStore o "
        f"Sideloadly). Guía paso a paso: [docs/INSTALAR.md]({guide}).",
        "",
        f"**EN:** build to install with your own Apple ID, no paid account (SideStore, AltStore or "
        f"Sideloadly). Step-by-step guide: [docs/INSTALAR.md]({guide}#english).",
        "",
        "| | |",
        "|---|---|",
        f"| IPA | `{ipa_name}` ({ipa['size'] / 1e6:.1f} MB) |",
        f"| SHA-256 | `{ipa['sha256']}` (`SHA256SUMS.txt`) |",
        f"| Versión / version | {version} ({info.get('CFBundleVersion')}), iPhone, iOS {minos} o posterior / or later |",
        f"| Fuente AltStore / SideStore source | `{source_url}` |",
        f"| Código fuente / Corresponding Source (AGPL-3.0 §6) | tag `{args.tag}`{commit}: «Source code» abajo / below |",
        f"| Compilada por / built by | {built_by}: sin certificado de Apple; firma ad hoc con solo el App Group / no "
        "Apple certificate; ad-hoc signature carrying only the App Group |",
        "",
        "### ES: qué funciona en esta versión",
        "- Te unes al Wi-Fi de la moto a mano, en Ajustes ▸ Wi-Fi: la app muestra la red y copia la contraseña, "
        "y sigue sola al volver (o toca «Ya me he conectado»). No puede unirse sola ni leer el nombre de la red.",
        "- El modo espejo (duplicar la pantalla) puede no estar disponible: depende de la herramienta de instalación.",
        "- La app caduca a los 7 días si no la renuevas, y con un Apple ID gratuito caben como máximo 3 apps instaladas "
        "así en el iPhone (SideStore o AltStore cuentan como una).",
        "- Descárgala solo de esta página y comprueba el SHA-256 antes de instalarla.",
        "",
        "### EN: what works in this build",
        "- You join the bike Wi-Fi by hand in Settings ▸ Wi-Fi: the app shows the network, copies the password and "
        "carries on when you come back (or tap \"I've joined\"). It cannot join or read Wi-Fi networks by itself.",
        "- Screen mirroring may be unavailable: it depends on the install tool.",
        "- The app expires after 7 days unless refreshed; with a free Apple ID at most 3 such apps fit on the iPhone "
        "(SideStore or AltStore counts as one).",
        "- Only download it from this page and check the SHA-256 before installing it.",
        "",
        "### Licencia / License",
        "Software libre bajo la GNU AGPL v3 o posterior (`LICENSE.txt`, `NOTICE.txt`), port para iOS de "
        f"[OpenCfMoto]({UPSTREAM}) (Android) de Alexandru Popa (zanderp) y la comunidad open-cfmoto. / Free "
        f"software under the GNU AGPL v3 or later (`LICENSE.txt`, `NOTICE.txt`): an iOS port of "
        f"[OpenCfMoto]({UPSTREAM}) (Android) by Alexandru Popa (zanderp) and the open-cfmoto community.",
        "",
        "### Avisos / Disclaimers",
        "- **ES:** proyecto comunitario independiente, sin afiliación con CFMOTO, Carbit, Apple ni ninguna marca de "
        "motos. Software experimental **sin ninguna garantía**: lo usas bajo tu propia responsabilidad. **Nunca "
        "manipules el teléfono mientras conduces**: fija la ruta antes de salir y no dependas de la app para una "
        "navegación crítica.",
        "- **EN:** independent community project, not affiliated with CFMOTO, Carbit, Apple or any motorcycle brand. "
        "Experimental software with **no warranty**: use it at your own risk. **Never handle the phone while "
        "riding**: set the route before you go and do not rely on the app for critical navigation.",
        "",
    ]
    return "\n".join(lines)


def _write(path: str, text: str) -> None:
    """All or nothing: a temporary file next to the target, then a rename."""
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".altsource-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def _esc(text: str) -> str:
    return str(text).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ipa", required=True)
    parser.add_argument("--repo", required=True, help="OWNER/NAME of the GitHub repository")
    parser.add_argument("--tag", required=True, help="vX.Y.Z")
    parser.add_argument("--commit", default="", help="the commit the IPA was built from")
    parser.add_argument("--run-url", default="", help="the workflow run that built it")
    parser.add_argument("--date", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))
    parser.add_argument("--colorset", default=DEFAULT_COLORSET, help="Xcode .colorset of the tint colour")
    parser.add_argument("--source-out", required=True)
    parser.add_argument("--notes-out", default="")
    args = parser.parse_args(argv)
    tag = TAG_RE.match(args.tag)
    if not tag:
        parser.error(f"--tag must be vX.Y.Z, not {args.tag!r}")
    if not REPO_RE.match(args.repo):
        parser.error(f"--repo must be OWNER/NAME, not {args.repo!r}")
    if args.commit and not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("--commit must be a full 40-character commit SHA")
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", args.date):
        parser.error("--date must be YYYY-MM-DD")
    version = tag.group(1)
    try:
        ipa = read_ipa(args.ipa)
        check(ipa, version)
        source = json.dumps(source_document(ipa, args, version), indent=2, ensure_ascii=False) + "\n"
        notes = release_notes(ipa, args, version) if args.notes_out else ""
    except Refused as exc:
        print(f"::error title=AltStore source::{_esc(exc)} (nothing written)", flush=True)
        return 1
    except OSError as exc:
        print(f"::error title=AltStore source::cannot read the IPA: {_esc(exc)} (nothing written)", flush=True)
        return 1
    _write(args.source_out, source)
    if args.notes_out:
        _write(args.notes_out, notes)
    perms = permissions(ipa)
    print(f"AltStore / SideStore source: {args.source_out} ({ipa['app']['info'].get('CFBundleIdentifier')} "
          f"{version} ({ipa['app']['info'].get('CFBundleVersion')}), {ipa['size']} bytes, sha256 {ipa['sha256']}; "
          f"entitlements {', '.join(perms['entitlements']) or 'none'}; privacy keys "
          f"{', '.join(perms['privacy']) or 'none'})", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
