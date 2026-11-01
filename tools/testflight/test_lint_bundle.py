#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for lint_bundle.py with synthetic archives / IPAs and fake `xcrun` + `codesign` tools.

The CI dry run lints a real but unsigned archive; the signed checks (entitlements, embedded
profiles, beta-reports-active) only meet a real signature in the TestFlight workflow. These tests
cover them, and every other rule, on any machine with python3 and bash (macOS or Linux).

usage: python3 tools/testflight/test_lint_bundle.py
"""
from __future__ import annotations

import contextlib
import datetime
import io
import os
import plistlib
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lint_bundle  # noqa: E402

GROUP = "group.com.x.opencfmoto"

# Fake tools: `xcrun nm|otool ... <bin>` prints <bin>.nm / <bin>.otool; `codesign -d` prints
# <bundle>/.ents.xml; `codesign --verify` fails when <bundle>/.badsig exists.
FAKE_XCRUN = """#!/bin/bash
tool=$1; shift
bin="${@: -1}"
case "$tool" in
  nm) cat "$bin.nm" ;;
  otool) echo "$bin:"; echo "Contents of (__TEXT,__objc_methname) section"; cat "$bin.otool" 2>/dev/null || true ;;
  *) exit 1 ;;
esac
"""
FAKE_CODESIGN = """#!/bin/bash
bundle="${@: -1}"
if [ "$1" = "-d" ]; then [ -f "$bundle/.ents.xml" ] || exit 1; cat "$bundle/.ents.xml"; exit 0; fi
if [ "$1" = "--verify" ]; then [ -f "$bundle/.badsig" ] && { echo "invalid signature" >&2; exit 1; }; exit 0; fi
exit 1
"""


def manifest(*categories):
    reasons = {"UserDefaults": ["CA92.1", "1C8F.1"], "SystemBootTime": ["35F9.1"], "FileTimestamp": ["C617.1"],
               "DiskSpace": ["E174.1"]}
    return {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [],
            "NSPrivacyAccessedAPITypes": [{"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategory" + c,
                                           "NSPrivacyAccessedAPITypeReasons": reasons[c]} for c in categories]}


class Fixture:
    """An archive (and optionally an IPA made from it) that passes every check; tests break one thing."""

    def __init__(self, root):
        self.root = root
        self.archive = os.path.join(root, "OpenCfMoto.xcarchive")
        self.app = os.path.join(self.archive, "Products/Applications/OpenCfMoto.app")
        self.appex = os.path.join(self.app, "PlugIns/OpenCfMotoMirror.appex")
        os.makedirs(self.appex)
        self.archive_info = {"ApplicationProperties": {"ApplicationPath": "Applications/OpenCfMoto.app",
                                                       "CFBundleIdentifier": "com.x.opencfmoto",
                                                       "SigningIdentity": "Apple Distribution: X (ABCDE12345)"}}
        self.info = {"CFBundleExecutable": "OpenCfMoto", "CFBundleIdentifier": "com.x.opencfmoto",
                     "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7", "CFBundleIconName": "AppIcon",
                     "ITSAppUsesNonExemptEncryption": False, "CFBundleSupportedPlatforms": ["iPhoneOS"],
                     "DTSDKName": "iphoneos26.2", "NSCameraUsageDescription": "camera",
                     "NSLocationWhenInUseUsageDescription": "location", "OCMAppGroupIdentifier": GROUP}
        self.xinfo = {"CFBundleExecutable": "OpenCfMotoMirror", "CFBundleIdentifier": "com.x.opencfmoto.mirror",
                      "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7", "OCMAppGroupIdentifier": GROUP}
        self.app_manifest = manifest("UserDefaults", "SystemBootTime", "FileTimestamp")
        self.appex_manifest = manifest("SystemBootTime", "FileTimestamp")
        self.app_symbols = ["_OBJC_CLASS_$_NSUserDefaults", "_lstat", "_NSFileModificationDate",
                            "_OBJC_CLASS_$_AVCaptureDevice", "_OBJC_CLASS_$_CLLocationManager"]
        self.appex_symbols = ["_lstat"]
        self.app_selectors = ["init", "systemUptime"]
        self.appex_selectors = ["systemUptime"]
        self.ents = {"application-identifier": "ABCDE12345.com.x.opencfmoto", "get-task-allow": False,
                     "beta-reports-active": True, "com.apple.security.application-groups": [GROUP],
                     "com.apple.developer.networking.HotspotConfiguration": True,
                     "com.apple.developer.networking.wifi-info": True}
        self.xents = {"application-identifier": "ABCDE12345.com.x.opencfmoto.mirror", "get-task-allow": False,
                      "beta-reports-active": True, "com.apple.security.application-groups": [GROUP]}
        self.profile = {"Name": "OpenCfMoto CI 1-1 app", "ExpirationDate": datetime.datetime(2099, 1, 1),
                        "Entitlements": {"get-task-allow": False, "beta-reports-active": True}}

    def write(self):
        def dump(path, obj, fmt=plistlib.FMT_BINARY):
            with open(path, "wb") as fh:
                plistlib.dump(obj, fh, fmt=fmt)
        dump(os.path.join(self.archive, "Info.plist"), self.archive_info, plistlib.FMT_XML)
        for bundle, info, man, syms, sels, ents in (
                (self.app, self.info, self.app_manifest, self.app_symbols, self.app_selectors, self.ents),
                (self.appex, self.xinfo, self.appex_manifest, self.appex_symbols, self.appex_selectors, self.xents)):
            dump(os.path.join(bundle, "Info.plist"), info)
            if man is not None:
                dump(os.path.join(bundle, "PrivacyInfo.xcprivacy"), man, plistlib.FMT_XML)
            binary = os.path.join(bundle, info["CFBundleExecutable"])
            open(binary, "w").close()
            with open(binary + ".nm", "w") as fh:
                fh.write("".join(f"                 U {s}\n" for s in syms))
            with open(binary + ".otool", "w") as fh:
                fh.write("".join(f"0000000100004000  {s}\n" for s in sels))
            if ents is not None:
                dump(os.path.join(bundle, ".ents.xml"), ents, plistlib.FMT_XML)
            with open(os.path.join(bundle, "embedded.mobileprovision"), "wb") as fh:
                fh.write(b"0\x82cms" + plistlib.dumps(self.profile) + b"\x00sig")
        open(os.path.join(self.app, "Assets.car"), "w").close()
        return self

    def ipa(self):
        path = os.path.join(self.root, "OpenCfMoto.ipa")
        with zipfile.ZipFile(path, "w") as zf:
            for folder, _dirs, files in os.walk(self.app):
                for name in files:
                    full = os.path.join(folder, name)
                    zf.write(full, os.path.join("Payload", os.path.relpath(full, os.path.dirname(self.app))))
        return path


class LintBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bin = tempfile.mkdtemp(prefix="lint-fake-bin-")
        for name, body in (("xcrun", FAKE_XCRUN), ("codesign", FAKE_CODESIGN)):
            path = os.path.join(cls.bin, name)
            with open(path, "w") as fh:
                fh.write(body)
            os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        cls.old_path = os.environ.get("PATH", "")
        os.environ["PATH"] = cls.bin + os.pathsep + cls.old_path
        os.environ.pop("GITHUB_STEP_SUMMARY", None)

    @classmethod
    def tearDownClass(cls):
        os.environ["PATH"] = cls.old_path
        shutil.rmtree(cls.bin, ignore_errors=True)

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="lint-test-")
        self.fx = Fixture(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def lint(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = lint_bundle.main(list(args))
        text = out.getvalue()
        errors = [line for line in text.splitlines() if line.startswith("error: ")]
        warnings = [line for line in text.splitlines() if line.startswith("warning: ")]
        return status, errors, warnings, text

    def assertClean(self, *args):
        status, errors, warnings, text = self.lint(*args)
        self.assertEqual(errors, [], text)
        self.assertEqual(warnings, [], text)
        self.assertEqual(status, 0)
        return text

    def assertError(self, needle, *args):
        status, errors, _warnings, text = self.lint(*args)
        self.assertEqual(status, 1, text)
        self.assertTrue(any(needle in e for e in errors), f"no error containing {needle!r} in:\n{text}")

    # ---- the happy paths
    def test_clean_signed_archive_and_ipa(self):
        self.fx.write()
        text = self.assertClean("--archive", self.fx.archive, "--app-group", GROUP, "--expect-build", "7",
                                "--expect-version", "0.1.0", "--min-sdk-major", "26")
        self.assertIn("FileTimestamp (_NSFileModificationDate, _lstat)", text)
        self.assertIn("::notice title=Privacy manifest check%3A OpenCfMoto.app::", text)
        self.assertClean("--ipa", self.fx.ipa(), "--app-group", GROUP, "--expect-build", "7")

    def test_unsigned_archive_skips_signature_checks(self):
        self.fx.ents = self.fx.xents = None  # no signature at all
        self.fx.write()
        self.assertClean("--archive", self.fx.archive, "--unsigned")
        self.assertError("codesign cannot read the signature", "--archive", self.fx.archive)

    # ---- archive / bundle layout
    def test_generic_archive_names_the_extra_products(self):
        self.fx.archive_info = {"Name": "OpenCfMoto"}
        self.fx.write()
        os.makedirs(os.path.join(self.fx.archive, "Products/usr/local/lib"))
        open(os.path.join(self.fx.archive, "Products/usr/local/lib/libX.a"), "w").close()
        self.assertError("Generic Xcode Archive", "--archive", self.fx.archive, "--unsigned")
        _s, errors, _w, _t = self.lint("--archive", self.fx.archive, "--unsigned")
        self.assertTrue(any("usr/local/lib/libX.a" in e for e in errors), errors)

    def test_frameworks_inside_the_extension(self):
        self.fx.write()
        os.makedirs(os.path.join(self.fx.appex, "Frameworks"))
        self.assertError("ITMS-90206", "--archive", self.fx.archive, "--unsigned")

    def test_versions(self):
        self.fx.xinfo["CFBundleVersion"] = "6"
        self.fx.write()
        self.assertError("CFBundleVersion differs", "--archive", self.fx.archive, "--unsigned")
        self.assertError("expected '8'", "--archive", self.fx.archive, "--unsigned", "--expect-build", "8")

    def test_info_plist_basics(self):
        for key, needle in (("ITSAppUsesNonExemptEncryption", "ITSAppUsesNonExemptEncryption"),
                            ("CFBundleIconName", "CFBundleIconName"), ("DTSDKName", "iOS 26 SDK")):
            with self.subTest(key=key):
                self.tearDown()
                self.setUp()
                del self.fx.info[key]
                self.fx.write()
                self.assertError(needle, "--archive", self.fx.archive, "--unsigned", "--min-sdk-major", "26")

    def test_extension_bundle_id_must_extend_the_app_id(self):
        self.fx.xinfo["CFBundleIdentifier"] = "com.y.mirror"
        self.fx.write()
        self.assertError("must start with the app's", "--archive", self.fx.archive, "--unsigned")

    # ---- privacy
    def test_missing_privacy_manifest(self):
        self.fx.appex_manifest = None
        self.fx.write()
        self.assertError("PrivacyInfo.xcprivacy is missing", "--archive", self.fx.archive, "--unsigned")

    def test_undeclared_required_reason_category(self):
        self.fx.appex_symbols.append("_statfs")
        self.fx.write()
        self.assertError("required-reason API category DiskSpace", "--archive", self.fx.archive, "--unsigned")

    def test_declared_but_unused_is_only_a_warning(self):
        self.fx.appex_manifest = manifest("UserDefaults", "SystemBootTime", "FileTimestamp")
        self.fx.write()
        status, errors, warnings, _text = self.lint("--archive", self.fx.archive, "--unsigned")
        self.assertEqual((status, errors), (0, []))
        self.assertTrue(any("declares UserDefaults but the binary does not use it" in w for w in warnings))

    def test_purpose_string_per_bundle(self):
        self.fx.appex_symbols.append("_OBJC_CLASS_$_CLLocationManager")
        self.fx.write()
        self.assertError("NSLocationWhenInUseUsageDescription", "--archive", self.fx.archive, "--unsigned")

    def test_invalid_reason_code_and_category(self):
        self.fx.app_manifest["NSPrivacyAccessedAPITypes"].append(
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryBogus", "NSPrivacyAccessedAPITypeReasons": ["X"]})
        self.fx.app_manifest["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPITypeReasons"] = []
        self.fx.write()
        self.assertError("unknown NSPrivacyAccessedAPIType", "--archive", self.fx.archive, "--unsigned")
        self.assertError("needs at least one", "--archive", self.fx.archive, "--unsigned")

    # ---- signature
    def test_signed_entitlements(self):
        self.fx.ents["get-task-allow"] = True
        del self.fx.ents["com.apple.developer.networking.wifi-info"]
        self.fx.xents["com.apple.security.application-groups"] = []
        self.fx.write()
        for needle in ("get-task-allow is True", "wifi-info", "lack App Group"):
            self.assertError(needle, "--archive", self.fx.archive, "--app-group", GROUP)

    def test_beta_reports_active_is_required_in_the_ipa_only(self):
        del self.fx.ents["beta-reports-active"]
        self.fx.write()
        self.assertClean("--archive", self.fx.archive, "--app-group", GROUP)
        self.assertError("beta-reports-active", "--ipa", self.fx.ipa(), "--app-group", GROUP)

    def test_development_or_expired_profile_and_bad_signature(self):
        self.fx.profile["ProvisionedDevices"] = ["00008110-000A"]
        self.fx.profile["ExpirationDate"] = datetime.datetime(2001, 1, 1)
        self.fx.write()
        open(os.path.join(self.fx.app, ".badsig"), "w").close()
        for needle in ("not an App Store profile", "expired", "codesign --verify"):
            self.assertError(needle, "--archive", self.fx.archive, "--app-group", GROUP)

    def test_app_group_mismatch_with_info_plist(self):
        self.fx.write()
        self.assertError("BUNDLE_ID_PREFIX mismatch", "--archive", self.fx.archive, "--app-group", "group.other")


if __name__ == "__main__":
    unittest.main(verbosity=2)
