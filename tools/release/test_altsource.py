#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for tools/release/altsource.py with synthetic IPAs (standard library only, any OS).

The IPAs are zip files with the layout package_ipa.sh writes: Payload/OpenCfMoto.app with an
extension in PlugIns/, binary and XML Info.plists, and executables that are minimal Mach-O files
carrying a code signature superblob with an XML entitlements blob, as `codesign` writes them.

usage: python3 tools/release/test_altsource.py
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import altsource  # noqa: E402

GROUP = "group.io.github.example.opencfmoto"
APP_ID = "io.github.example.opencfmoto"
REPO = "Example/opencfmoto-ios"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
APP_GROUP_ENT = {"com.apple.security.application-groups": [GROUP]}


def macho(entitlements, cputype=0x0100000C):
    """A 64-bit Mach-O image: an LC_UUID, then (unless entitlements is None) an LC_CODE_SIGNATURE
    whose superblob has a CodeDirectory placeholder and the XML entitlements blob."""
    uuid = struct.pack("<II", 0x1B, 24) + bytes(range(16))
    commands = [uuid]
    body = b""
    if entitlements is not None:
        xml = plistlib.dumps(entitlements, fmt=plistlib.FMT_XML)
        directory = struct.pack(">II", 0xFADE0C02, 16) + b"\0" * 8
        ents = struct.pack(">II", 0xFADE7171, 8 + len(xml)) + xml
        header_len = 12 + 2 * 8
        superblob = struct.pack(">III", 0xFADE0CC0, header_len + len(directory) + len(ents), 2)
        superblob += struct.pack(">II", 0, header_len) + struct.pack(">II", 5, header_len + len(directory))
        superblob += directory + ents
        body = superblob
        commands.append(None)                         # placeholder: its offset depends on the size
    sizeofcmds = 24 + (16 if entitlements is not None else 0)
    dataoff = 32 + sizeofcmds + 8                     # 8 bytes of "text" before the signature
    if entitlements is not None:
        commands[1] = struct.pack("<IIII", 0x1D, 16, dataoff, len(body))
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, cputype, 0, 2, len(commands), sizeofcmds, 0, 0)
    return header + b"".join(commands) + b"\xd5\x03\x20\x1f" * 2 + body


def fat(*images):
    """A fat (universal) file of the images, 2^14-aligned."""
    out = struct.pack(">II", 0xCAFEBABE, len(images))
    offset = 1 << 14
    table, blobs = b"", b""
    for i, image in enumerate(images):
        table += struct.pack(">iiIII", 0x0100000C + i, 0, offset + len(blobs), len(image), 14)
        blobs += image + b"\0" * ((-len(image)) % (1 << 14))
    out += table
    return out + b"\0" * (offset - len(out)) + blobs


class Fixture:
    """An IPA that passes every check; tests change one thing before `ipa()`."""

    def __init__(self, root):
        self.root = root
        self.info = {"CFBundleExecutable": "OpenCfMoto", "CFBundleIdentifier": APP_ID,
                     "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "42", "MinimumOSVersion": "17.0",
                     "OCMAppGroupIdentifier": GROUP, "NSCameraUsageDescription": "app camera text",
                     "NSLocationWhenInUseUsageDescription": "app location text",
                     "NSLocalNetworkUsageDescription": "app network text",
                     "NSAppleMusicUsageDescription": "app music text", "UIBackgroundModes": ["location", "audio"],
                     "NSBonjourServices": ["_EasyConn._tcp"]}
        self.xinfo = {"CFBundleExecutable": "OpenCfMotoMirror", "CFBundleIdentifier": APP_ID + ".mirror",
                      "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "42", "OCMAppGroupIdentifier": GROUP,
                      "NSLocationWhenInUseUsageDescription": "extension location text"}
        self.app_binary = macho(APP_GROUP_ENT)
        self.ext_binary = macho(APP_GROUP_ENT)
        self.extra = {}                               # zip name -> bytes
        self.with_extension = True
        self.binary_plist = True

    def ipa(self, name="OpenCfMoto-v0.1.0-sideload.ipa"):
        path = os.path.join(self.root, name)
        fmt = plistlib.FMT_BINARY if self.binary_plist else plistlib.FMT_XML
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("Payload/", b"")
            z.writestr("Payload/OpenCfMoto.app/Info.plist", plistlib.dumps(self.info, fmt=fmt))
            z.writestr("Payload/OpenCfMoto.app/OpenCfMoto", self.app_binary)
            if self.with_extension:
                ext = "Payload/OpenCfMoto.app/PlugIns/OpenCfMotoMirror.appex"
                z.writestr(f"{ext}/Info.plist", plistlib.dumps(self.xinfo, fmt=plistlib.FMT_XML))
                z.writestr(f"{ext}/OpenCfMotoMirror", self.ext_binary)
            for zname, data in self.extra.items():
                z.writestr(zname, data)
        return path


class AltSourceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="altsource-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.fx = Fixture(self.tmp)
        self.colorset = os.path.join(self.tmp, "AccentColor.colorset")
        os.makedirs(self.colorset)
        self.color({"alpha": "1.000", "blue": "0x2C", "green": "0x6A", "red": "0xFF"})
        self.source_path = os.path.join(self.tmp, "altstore-source.json")
        self.notes_path = os.path.join(self.tmp, "RELEASE_NOTES.md")

    def color(self, components):
        with open(os.path.join(self.colorset, "Contents.json"), "w", encoding="utf-8") as fh:
            json.dump({"colors": [{"color": {"color-space": "srgb", "components": components},
                                   "idiom": "universal"}]}, fh)

    def run_tool(self, ipa=None, tag="v0.1.0", extra=()):
        """altsource.main() in this process; returns (exit code, output)."""
        args = ["--ipa", ipa or self.fx.ipa(), "--repo", REPO, "--tag", tag, "--commit", COMMIT,
                "--run-url", "https://github.com/Example/opencfmoto-ios/actions/runs/1", "--date", "2026-11-04",
                "--colorset", self.colorset, "--source-out", self.source_path, "--notes-out", self.notes_path,
                *extra]
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                code = altsource.main(args)
            except SystemExit as exc:                 # argparse usage errors
                code = exc.code
        return code, out.getvalue()

    def source(self):
        with open(self.source_path, encoding="utf-8") as fh:
            return json.load(fh)

    def notes(self):
        with open(self.notes_path, encoding="utf-8") as fh:
            return fh.read()

    def assert_refused(self, needle, **kwargs):
        code, out = self.run_tool(**kwargs)
        self.assertEqual(code, 1, out)
        self.assertIn("::error title=AltStore source::", out)
        self.assertIn(needle, out)
        self.assertIn("(nothing written)", out)
        self.assertFalse(os.path.exists(self.source_path), "a refused IPA must leave no source behind")
        self.assertFalse(os.path.exists(self.notes_path))
        return out

    # ------------------------------------------------------------ the source document

    def test_the_source_matches_the_ipa(self):
        ipa = self.fx.ipa()
        code, out = self.run_tool(ipa)
        self.assertEqual(code, 0, out)
        with open(ipa, "rb") as fh:
            data = fh.read()
        doc = self.source()
        self.assertEqual(doc["name"], "OpenCfMoto for iOS")
        self.assertEqual(doc["identifier"], "io.github.example.opencfmoto.source")
        self.assertEqual(doc["website"], "https://github.com/Example/opencfmoto-ios")
        self.assertEqual(doc["news"], [])
        self.assertEqual(doc["tintColor"], "FF6A2C")
        (app,) = doc["apps"]
        self.assertEqual(app["bundleIdentifier"], APP_ID)
        self.assertEqual(app["category"], "utilities")
        self.assertEqual(app["iconURL"], "https://raw.githubusercontent.com/Example/opencfmoto-ios/"
                                         f"{COMMIT}/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
        self.assertEqual(doc["iconURL"], app["iconURL"])
        (version,) = app["versions"]
        download = "https://github.com/Example/opencfmoto-ios/releases/download/v0.1.0/OpenCfMoto-v0.1.0-sideload.ipa"
        self.assertEqual(version, {
            "version": "0.1.0", "buildVersion": "42", "date": "2026-11-04",
            "localizedDescription": version["localizedDescription"], "downloadURL": download,
            "size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "minOSVersion": "17.0"})
        self.assertIn("Settings ▸ Wi-Fi", version["localizedDescription"])
        # The app never copies the password by itself: it shows it with a copy button (2-minute copy).
        for text in (version["localizedDescription"], app["localizedDescription"]):
            self.assertIn("with a copy button", text)
            self.assertIn("the copy lasts 2 minutes", text)
            self.assertNotIn("copies the password", text)
        # The single-version fields older AltStore / SideStore releases read: the same version.
        self.assertEqual((app["version"], app["versionDate"], app["downloadURL"], app["size"]),
                         ("0.1.0", "2026-11-04", download, len(data)))
        self.assertEqual(app["appPermissions"], {
            "entitlements": ["com.apple.security.application-groups"],
            "privacy": {"NSAppleMusicUsageDescription": "app music text", "NSCameraUsageDescription": "app camera text",
                        "NSLocalNetworkUsageDescription": "app network text",
                        "NSLocationWhenInUseUsageDescription": "app location text"}})
        for text in (app["localizedDescription"], doc["description"]):
            self.assertIn("Not affiliated with CFMOTO, Carbit or Apple", text)
            self.assertIn("zanderp", text)
        self.assertIn("no warranty", app["localizedDescription"])
        self.assertIn("never handle the phone while riding", app["localizedDescription"])
        self.assertIn(f"sha256 {hashlib.sha256(data).hexdigest()}", out)

    def test_every_extension_entitlement_and_privacy_key_is_declared(self):
        # AltStore throws undeclaredPermissions for anything in an extension the source does not list.
        self.fx.ext_binary = macho({**APP_GROUP_ENT, "com.apple.developer.example": True})
        self.fx.xinfo["NSMicrophoneUsageDescription"] = "extension microphone text"
        self.assertEqual(self.run_tool()[0], 0)
        perms = self.source()["apps"][0]["appPermissions"]
        self.assertEqual(perms["entitlements"], ["com.apple.developer.example", "com.apple.security.application-groups"])
        self.assertEqual(perms["privacy"]["NSMicrophoneUsageDescription"], "extension microphone text")
        self.assertEqual(perms["privacy"]["NSLocationWhenInUseUsageDescription"], "app location text",
                         "the app's purpose string wins")

    def test_signing_identity_entitlements_are_not_declared(self):
        # A re-signing tool replaces these; AltStore does not compare them.
        self.fx.app_binary = macho({**APP_GROUP_ENT, "application-identifier": "ABCDE12345." + APP_ID,
                                    "com.apple.developer.team-identifier": "ABCDE12345", "get-task-allow": False})
        self.assertEqual(self.run_tool()[0], 0)
        self.assertEqual(self.source()["apps"][0]["appPermissions"]["entitlements"],
                         ["com.apple.security.application-groups"])

    def test_xml_info_plist_and_a_fat_executable(self):
        self.fx.binary_plist = False
        self.fx.app_binary = fat(macho(APP_GROUP_ENT), macho(APP_GROUP_ENT, cputype=0x01000007))
        self.assertEqual(self.run_tool()[0], 0)
        self.assertEqual(self.source()["apps"][0]["bundleIdentifier"], APP_ID)

    def test_an_app_without_extensions(self):
        self.fx.with_extension = False
        self.assertEqual(self.run_tool()[0], 0)
        self.assertEqual(self.source()["apps"][0]["appPermissions"]["entitlements"],
                         ["com.apple.security.application-groups"])

    def test_the_output_is_stable_utf8_json(self):
        ipa = self.fx.ipa()
        self.assertEqual(self.run_tool(ipa)[0], 0)
        with open(self.source_path, "rb") as fh:
            first = fh.read()
        self.assertTrue(first.endswith(b"}\n"))
        self.assertIn("▸".encode(), first)            # not \u escapes
        os.remove(self.source_path)
        self.assertEqual(self.run_tool(ipa)[0], 0)
        with open(self.source_path, "rb") as fh:
            self.assertEqual(fh.read(), first)

    # ------------------------------------------------------------ tint colour

    def test_tint_colour_from_the_colorset(self):
        self.color({"alpha": "1.000", "blue": "0.000", "green": "0.500", "red": "1.000"})
        self.assertEqual(altsource.tint_color(self.colorset), "FF8000")
        self.color({"red": "255", "green": "106", "blue": "44"})
        self.assertEqual(altsource.tint_color(self.colorset), "FF6A2C")
        for bad in ({"red": "0x1FF", "green": "0", "blue": "0"}, {"red": "x", "green": "0", "blue": "0"}, {}):
            self.color(bad)
            self.assertIsNone(altsource.tint_color(self.colorset), bad)
        self.assertIsNone(altsource.tint_color(os.path.join(self.tmp, "missing.colorset")))

    def test_an_unreadable_colour_is_left_out(self):
        # A malformed tintColor makes AltStore reject the whole source: none is better.
        self.color({"red": "nope"})
        self.assertEqual(self.run_tool()[0], 0)
        doc = self.source()
        self.assertNotIn("tintColor", doc)
        self.assertNotIn("tintColor", doc["apps"][0])

    def test_the_repository_accent_colour_reads(self):
        self.assertRegex(altsource.tint_color(altsource.DEFAULT_COLORSET) or "", r"^[0-9A-F]{6}$")

    # ------------------------------------------------------------ refusals (nothing written)

    def test_the_bundle_id_must_end_in_opencfmoto(self):
        self.fx.info["CFBundleIdentifier"] = "io.github.example.other"
        self.fx.xinfo["CFBundleIdentifier"] = "io.github.example.other.mirror"
        self.assert_refused("does not end in .opencfmoto")

    def test_the_version_must_be_the_tag(self):
        self.assert_refused("the tag says 0.2.0", tag="v0.2.0")

    def test_the_extension_must_carry_the_apps_version_and_build(self):
        self.fx.xinfo["CFBundleVersion"] = "41"
        self.assert_refused("CFBundleVersion «41», the app 42")
        self.fx.xinfo["CFBundleVersion"] = "42"
        self.fx.xinfo["CFBundleShortVersionString"] = "0.0.9"
        self.assert_refused("CFBundleShortVersionString «0.0.9»")

    def test_the_extension_id_must_be_under_the_apps(self):
        self.fx.xinfo["CFBundleIdentifier"] = "io.github.example.mirror"
        self.assert_refused("not one under «io.github.example.opencfmoto»")

    def test_an_unsigned_bundle_is_refused(self):
        self.fx.ext_binary = macho(None)
        out = self.assert_refused("OpenCfMotoMirror.appex/OpenCfMotoMirror is not signed")
        self.assertIn("package_ipa.sh", out)

    def test_broken_executables_are_refused(self):
        for binary, needle in ((b"#!/bin/sh\n" * 4, "not a Mach-O file"), (b"\x01", "too short"),
                               (macho(APP_GROUP_ENT)[:60], "cut short"),
                               (fat(macho(APP_GROUP_ENT), macho({"other": True}, cputype=7)), "different entitlements")):
            with self.subTest(needle=needle):
                self.fx.app_binary = binary
                self.assert_refused(needle)

    def test_entitlements_that_are_no_property_list_are_refused(self):
        image = bytearray(macho(APP_GROUP_ENT))
        start = image.index(b"<?xml")
        image[start:start + 5] = b"<?xmX"
        self.fx.app_binary = bytes(image)
        self.assert_refused("not a property list")

    def test_exactly_one_app(self):
        self.fx.extra["Payload/Second.app/Info.plist"] = plistlib.dumps(self.fx.info)
        self.assert_refused("exactly one app in Payload/ (found 2)")

    def test_a_missing_executable_or_info_plist(self):
        self.fx.info["CFBundleExecutable"] = "Elsewhere"
        self.assert_refused("Payload/OpenCfMoto.app/Elsewhere (the executable) is missing")
        self.fx.info["CFBundleExecutable"] = ""
        self.assert_refused("no usable CFBundleExecutable")

    def test_not_a_zip(self):
        path = os.path.join(self.tmp, "broken.ipa")
        with open(path, "wb") as fh:
            fh.write(b"not a zip")
        self.assert_refused("is not a zip archive", ipa=path)

    def test_usage_errors(self):
        for extra, tag in (((), "0.1.0"), (("--commit", "abc"), "v0.1.0"), (("--date", "4/11/2026"), "v0.1.0"),
                           (("--repo", "no-slash"), "v0.1.0")):
            with self.subTest(extra=extra, tag=tag):
                code, _out = self.run_tool(tag=tag, extra=extra)
                self.assertEqual(code, 2)
                self.assertFalse(os.path.exists(self.source_path))

    # ------------------------------------------------------------ release notes

    def test_the_release_notes(self):
        ipa = self.fx.ipa()
        self.assertEqual(self.run_tool(ipa)[0], 0)
        with open(ipa, "rb") as fh:
            sha = hashlib.sha256(fh.read()).hexdigest()
        notes = self.notes()
        self.assertTrue(notes.startswith("## OpenCfMoto for iOS v0.1.0 — sideload build (beta)\n"))
        for needle in (f"`{sha}`", "`OpenCfMoto-v0.1.0-sideload.ipa`", "SHA256SUMS.txt",
                       "https://github.com/Example/opencfmoto-ios/releases/latest/download/altstore-source.json",
                       f"tag `v0.1.0` = commit `{COMMIT}`", "(https://github.com/Example/opencfmoto-ios/actions/runs/1)",
                       "https://github.com/Example/opencfmoto-ios/blob/main/docs/INSTALAR.md#english",
                       "0.1.0 (42)", "iOS 17.0", "LICENSE.txt", "NOTICE.txt", "LICENSE-Apache-2.0.txt",
                       "Apache License 2.0", "licencia Apache 2.0", "zanderp", "AGPL",
                       "sin ninguna garantía", "no warranty", "Nunca manipules el teléfono mientras conduces",
                       "Never handle the phone while riding", "Ajustes ▸ Wi-Fi", "Settings ▸ Wi-Fi",
                       "«Ya me he conectado»", "\"I've joined\"", "solo de esta página", "Only download it from this page",
                       "con un botón para copiarla (la copia dura 2 minutos)",
                       "with a copy button (the copy lasts 2 minutes)"):
            self.assertIn(needle, notes)
        for claim in ("copia la contraseña", "copies the password"):
            self.assertNotIn(claim, notes)
        self.assertLess(notes.index("**ES:**"), notes.index("**EN:**"), "Spanish first")
        self.assertLess(notes.index("### ES:"), notes.index("### EN:"))

    def test_without_notes_out_only_the_source_is_written(self):
        ipa = self.fx.ipa()
        args = ["--ipa", ipa, "--repo", REPO, "--tag", "v0.1.0", "--date", "2026-11-04", "--colorset", self.colorset,
                "--source-out", self.source_path]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(altsource.main(args), 0)
        self.assertTrue(os.path.exists(self.source_path))
        self.assertFalse(os.path.exists(self.notes_path))
        # Without --commit the icon comes from the tag.
        self.assertIn("/opencfmoto-ios/v0.1.0/App/Resources/", self.source()["iconURL"])

    # ------------------------------------------------------------ as the workflow runs it

    def test_the_command_line_with_python_isolated_mode(self):
        ipa = self.fx.ipa()
        proc = subprocess.run([sys.executable, "-I", os.path.join(HERE, "altsource.py"), "--ipa", ipa, "--repo", REPO,
                               "--tag", "v0.1.0", "--commit", COMMIT, "--date", "2026-11-04",
                               "--source-out", self.source_path, "--notes-out", self.notes_path],
                              capture_output=True, text=True, timeout=60, cwd=self.tmp)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("AltStore / SideStore source:", proc.stdout)
        self.assertEqual(self.source()["apps"][0]["bundleIdentifier"], APP_ID)


if __name__ == "__main__":
    unittest.main(verbosity=2)
