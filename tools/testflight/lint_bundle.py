#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Check an Xcode archive or an IPA before it goes to App Store Connect (TestFlight).

App Store Connect validates a build only after the upload, and a rejection arrives by e-mail
("ITMS-9xxxx") many minutes later. This script catches the usual reasons first and reports every
problem at once as GitHub ::error annotations (annotations stay readable when raw CI logs are not).

usage:
  lint_bundle.py --archive OpenCfMoto.xcarchive [--unsigned] [options]
  lint_bundle.py --ipa OpenCfMoto.ipa [options]

options:
  --app-group G       App Group both signatures must carry (default: the app's
                      OCMAppGroupIdentifier Info.plist value)
  --expect-version V  CFBundleShortVersionString the app and the extension must have
  --expect-build N    CFBundleVersion the app and the extension must have
  --expect-device-family F  UIDeviceFamily the app and the extension must have, e.g. 1
                      (iPhone only) or 1,2 (iPhone and iPad)
  --min-sdk-major N   the app must be built with the iOS N SDK or newer (App Store Connect: 26)
  --appex NAME        extension bundle inside PlugIns/ (default OpenCfMotoMirror.appex)

checks:
  archive  Info.plist has ApplicationProperties: an "iOS App" archive, not a "Generic Xcode
           Archive" (Xcode cannot export or upload those)
  bundles  PlugIns/<appex> exists; no Frameworks/ inside the .appex (ITMS-90206); the same
           CFBundleVersion and CFBundleShortVersionString in app and extension; extension id is
           <app id>.<name>; CFBundleIconName/CFBundleIcons + Assets.car; ITSAppUsesNonExemptEncryption;
           built for iPhoneOS; the same UIDeviceFamily in app and extension; an app that runs on
           iPad (UIDeviceFamily has 2) supports all four iPad orientations unless it sets
           UIRequiresFullScreen (ITMS-90474)
  privacy  each bundle has a PrivacyInfo.xcprivacy that declares, with valid reasons, every
           "required reason" API category its binary uses (ITMS-91053). Evidence: undefined symbols
           (`xcrun nm -u`) and Objective-C selectors (`xcrun otool -v -s __TEXT __objc_methname`).
           Also the NS...UsageDescription purpose strings the referenced privacy-sensitive classes
           need, per bundle (ITMS-90683).
  signed   (not with --unsigned) entitlements of app and extension: application-groups contains the
           group, get-task-allow false, the app has HotspotConfiguration + wifi-info; App Store
           profiles embedded; `codesign --verify --deep --strict` passes. The IPA (what is uploaded)
           must also carry beta-reports-active = true: Xcode adds it when it exports for App Store
           Connect, so an archive is not required to have it.

Exit status: 0 = no errors (warnings allowed), 1 = errors, 2 = usage.
"""
from __future__ import annotations

import argparse
import datetime
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

DEFAULT_APPEX = "OpenCfMotoMirror.appex"
CATEGORY_PREFIX = "NSPrivacyAccessedAPICategory"

# Apple's "required reason" APIs (developer.apple.com ▸ Describing use of required reason API).
# category -> (undefined symbols, Objective-C selectors) that show a binary uses it. Symbols cover
# C functions, global constants (NSFileModificationDate...) and Objective-C classes; Swift calls
# to Objective-C methods (ProcessInfo.systemUptime) only leave the selector name behind.
REQUIRED_REASON_APIS = {
    "UserDefaults": ({"_OBJC_CLASS_$_NSUserDefaults"}, set()),
    "SystemBootTime": ({"_mach_absolute_time"}, {"systemUptime"}),
    "FileTimestamp": (
        {"_stat", "_lstat", "_fstat", "_fstatat", "_getattrlist", "_getattrlistbulk", "_fgetattrlist",
         "_getattrlistat", "_NSFileCreationDate", "_NSFileModificationDate",
         "_NSURLContentModificationDateKey", "_NSURLCreationDateKey"},
        {"fileModificationDate", "fileCreationDate"},
    ),
    # Apple lists getattrlist, fgetattrlist and getattrlistat under file timestamps AND disk space
    # (not getattrlistbulk): one symbol may require both categories.
    "DiskSpace": (
        {"_statfs", "_statvfs", "_fstatfs", "_fstatvfs", "_getattrlist", "_fgetattrlist",
         "_getattrlistat", "_NSURLVolumeAvailableCapacityKey",
         "_NSURLVolumeAvailableCapacityForImportantUsageKey",
         "_NSURLVolumeAvailableCapacityForOpportunisticUsageKey", "_NSURLVolumeTotalCapacityKey",
         "_NSFileSystemFreeSize", "_NSFileSystemSize"},
        set(),
    ),
    "ActiveKeyboards": (set(), {"activeInputModes"}),
}

# Reason codes Apple documents per category. An unknown code is only a warning (Apple adds codes).
VALID_REASONS = {
    "FileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "SystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "DiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "ActiveKeyboards": {"3EC4.1", "54BD.1"},
    "UserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}

# Purpose strings App Store Connect asks for (ITMS-90683) when a binary references these classes or
# selectors. It checks every bundle on its own: an app extension needs its own keys.
# (what, symbols, selectors, Info.plist keys — any one of them is enough)
PURPOSE_STRINGS = [
    ("camera", {"_OBJC_CLASS_$_AVCaptureDevice"}, set(), ("NSCameraUsageDescription",)),
    ("location", {"_OBJC_CLASS_$_CLLocationManager"}, set(), ("NSLocationWhenInUseUsageDescription",)),
    ("location (always)", set(), {"requestAlwaysAuthorization"},
     ("NSLocationAlwaysAndWhenInUseUsageDescription",)),
    ("photo library", {"_OBJC_CLASS_$_PHPhotoLibrary"}, set(), ("NSPhotoLibraryUsageDescription",)),
    ("saving to the photo library", {"_UIImageWriteToSavedPhotosAlbum"}, set(),
     ("NSPhotoLibraryAddUsageDescription", "NSPhotoLibraryUsageDescription")),
    ("contacts", {"_OBJC_CLASS_$_CNContactStore"}, set(), ("NSContactsUsageDescription",)),
    ("Bluetooth", {"_OBJC_CLASS_$_CBCentralManager", "_OBJC_CLASS_$_CBPeripheralManager"}, set(),
     ("NSBluetoothAlwaysUsageDescription",)),
    ("motion activity", {"_OBJC_CLASS_$_CMMotionActivityManager", "_OBJC_CLASS_$_CMPedometer"}, set(),
     ("NSMotionUsageDescription",)),
    ("microphone", {"_OBJC_CLASS_$_AVAudioRecorder"},
     {"requestRecordPermission:", "requestRecordPermissionWithCompletionHandler:"},
     ("NSMicrophoneUsageDescription",)),
    ("speech recognition", {"_OBJC_CLASS_$_SFSpeechRecognizer"}, set(),
     ("NSSpeechRecognitionUsageDescription",)),
    ("calendars", {"_OBJC_CLASS_$_EKEventStore"}, set(),
     ("NSCalendarsUsageDescription", "NSCalendarsFullAccessUsageDescription",
      "NSCalendarsWriteOnlyAccessUsageDescription")),
    ("tracking", {"_OBJC_CLASS_$_ATTrackingManager"}, set(), ("NSUserTrackingUsageDescription",)),
    ("media library", {"_OBJC_CLASS_$_MPMediaLibrary"}, set(), ("NSAppleMusicUsageDescription",)),
    ("NFC", {"_OBJC_CLASS_$_NFCNDEFReaderSession", "_OBJC_CLASS_$_NFCTagReaderSession"}, set(),
     ("NFCReaderUsageDescription",)),
]

# An app that runs on iPad must support every orientation there, or App Store Connect rejects the
# upload: "ITMS-90474: Invalid Bundle. iPad Multitasking support requires these orientations".
IPAD_ORIENTATIONS = {"UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                     "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"}
DEVICE_NAMES = {1: "iPhone", 2: "iPad"}

ENT_GROUPS = "com.apple.security.application-groups"
ENT_HOTSPOT = "com.apple.developer.networking.HotspotConfiguration"
ENT_WIFI = "com.apple.developer.networking.wifi-info"
VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+){0,2}$")
BUNDLE_EXTENSIONS = (".app", ".appex", ".framework", ".bundle", ".xctest")
MAX_INDIVIDUAL_ERRORS = 8  # GitHub keeps 10 error annotations per step: 1 aggregate + these


# ---------------------------------------------------------------- annotations / output helpers
def esc_data(s: str) -> str:
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def esc_prop(s: str) -> str:
    return esc_data(s).replace(":", "%3A").replace(",", "%2C")


def annotate(level: str, title: str, message: str) -> None:
    print(f"::{level} title={esc_prop(title)}::{esc_data(message)}", flush=True)


def append_summary(markdown: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(markdown)
    except OSError:
        pass


class Report:
    def __init__(self, label: str) -> None:
        self.label = label
        self.errors: list = []
        self.warnings: list = []
        self.rows: list = []      # (bundle, used categories with evidence, declared, verdict)
        self.contents: list = []  # (bundle, files)
        self.facts: list = []     # (bundle, device family and orientations)

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


# ---------------------------------------------------------------- small utilities
def run(cmd: list, binary: bool = False):
    """Run a tool; returns (status, stdout, stderr). A missing tool is status 127, not an exception."""
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
    except FileNotFoundError:
        return 127, b"" if binary else "", f"{cmd[0]}: not found"
    except subprocess.TimeoutExpired:
        return 124, b"" if binary else "", f"{' '.join(cmd)}: timed out"
    if binary:
        return proc.returncode, proc.stdout, proc.stderr.decode("utf-8", "replace")
    return (proc.returncode, proc.stdout.decode("utf-8", "replace"),
            proc.stderr.decode("utf-8", "replace"))


def load_plist(path: str):
    with open(path, "rb") as fh:
        return plistlib.load(fh)  # XML or binary


def bundle_name(path: str) -> str:
    return os.path.basename(path.rstrip("/"))


def list_bundle(path: str) -> list:
    """Top-level entries of a bundle (directories end with '/'), for the CI report."""
    try:
        names = sorted(os.listdir(path))
    except OSError:
        return []
    return [n + "/" if os.path.isdir(os.path.join(path, n)) else n for n in names]


def device_family(info: dict):
    """UIDeviceFamily as a sorted list of ints (1 iPhone, 2 iPad), or None when the key is missing."""
    raw = info.get("UIDeviceFamily")
    if raw is None:
        return None
    family = set()
    for item in raw if isinstance(raw, list) else [raw]:
        try:
            family.add(int(item))
        except (TypeError, ValueError):
            pass
    return sorted(family)


def fmt_family(family) -> str:
    if family is None:
        return "(no UIDeviceFamily)"
    return f"{family} ({', '.join(DEVICE_NAMES.get(f, str(f)) for f in family) or 'none'})"


def parse_family(text: str) -> list:
    try:
        family = sorted({int(part) for part in text.split(",") if part.strip()})
    except ValueError:
        family = []
    if not family:
        raise argparse.ArgumentTypeError(f"{text!r} is not a device family list (e.g. 1 or 1,2)")
    return family


def string_list(value) -> list:
    return [v for v in value if isinstance(v, str)] if isinstance(value, list) else []


def short_orientations(values: list) -> str:
    return ", ".join(v.replace("UIInterfaceOrientation", "") for v in values) or "none"


def normalize_symbol(name: str) -> str:
    # x86_64 macOS variants ($INODE64...) never appear on arm64 iOS, but stay safe.
    return re.sub(r"\$(INODE64|UNIX2003|DARWIN_EXTSN|NOCANCEL)$", "", name)


def scan_binary(rep: Report, path: str, label: str):
    """Undefined symbols and Objective-C selectors of a Mach-O binary, or None when unreadable."""
    status, out, err = run(["xcrun", "nm", "-u", path])
    if status != 0:
        rep.error(f"{label}: cannot list the binary's symbols (xcrun nm -u {bundle_name(path)}): "
                  f"{(err or out).strip()[:300]}")
        return None
    symbols = set()
    for line in out.splitlines():
        line = line.strip()
        if not line or line.endswith(":"):  # "binary (for architecture arm64):" headers
            continue
        symbols.add(normalize_symbol(line.split()[-1]))  # "U _sym" or just "_sym"
    status, out, err = run(["xcrun", "otool", "-v", "-s", "__TEXT", "__objc_methname", path])
    if status != 0:
        rep.error(f"{label}: cannot read the binary's selectors (xcrun otool): {(err or out).strip()[:300]}")
        return None
    selectors = set()
    for line in out.splitlines():
        m = re.match(r"^\s*[0-9a-fA-F]{8,}\s+(\S+)\s*$", line)
        if m:
            selectors.add(m.group(1))
    return symbols, selectors


def required_categories(symbols: set, selectors: set) -> dict:
    """category -> sorted evidence (symbols / selectors found)."""
    found = {}
    for category, (cat_symbols, cat_selectors) in REQUIRED_REASON_APIS.items():
        evidence = sorted(symbols & cat_symbols) + sorted(selectors & cat_selectors)
        if evidence:
            found[category] = evidence
    return found


def read_privacy_manifest(rep: Report, bundle: str, label: str):
    """Declared categories -> reasons, or None when the manifest is missing or unreadable."""
    path = os.path.join(bundle, "PrivacyInfo.xcprivacy")
    if not os.path.isfile(path):
        return None
    try:
        data = load_plist(path)
    except Exception as exc:  # plistlib raises several types
        rep.error(f"{label}: PrivacyInfo.xcprivacy is not a valid property list: {exc}")
        return None
    if not isinstance(data, dict):
        rep.error(f"{label}: PrivacyInfo.xcprivacy must be a dictionary")
        return None
    if not isinstance(data.get("NSPrivacyTracking"), bool):
        rep.warn(f"{label}: PrivacyInfo.xcprivacy has no boolean NSPrivacyTracking")
    for key in ("NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes"):
        if not isinstance(data.get(key), list):
            rep.warn(f"{label}: PrivacyInfo.xcprivacy has no {key} array")
    declared = {}
    entries = data.get("NSPrivacyAccessedAPITypes", [])
    if not isinstance(entries, list):
        rep.error(f"{label}: NSPrivacyAccessedAPITypes must be an array")
        return declared
    for entry in entries:
        if not isinstance(entry, dict):
            rep.error(f"{label}: NSPrivacyAccessedAPITypes entries must be dictionaries")
            continue
        category = str(entry.get("NSPrivacyAccessedAPIType", ""))
        short = category[len(CATEGORY_PREFIX):] if category.startswith(CATEGORY_PREFIX) else category
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
        if short not in VALID_REASONS:
            rep.error(f"{label}: unknown NSPrivacyAccessedAPIType '{category}'")
            continue
        if not isinstance(reasons, list) or not reasons:
            rep.error(f"{label}: {category} needs at least one NSPrivacyAccessedAPITypeReasons code")
            continue
        unknown = [r for r in reasons if r not in VALID_REASONS[short]]
        if unknown:
            rep.warn(f"{label}: {category}: reason code(s) {', '.join(map(str, unknown))} are not in "
                     f"Apple's list known to this script ({', '.join(sorted(VALID_REASONS[short]))})")
        declared[short] = [str(r) for r in reasons]
    return declared


def signed_entitlements(rep: Report, bundle: str, label: str):
    """Entitlements of the code signature (dict), or None."""
    # `--entitlements - --xml` is the current syntax; `:-` the older one (deprecated, still works).
    for cmd in (["codesign", "-d", "--entitlements", "-", "--xml", bundle],
                ["codesign", "-d", "--entitlements", ":-", bundle]):
        status, out, err = run(cmd, binary=True)
        if status != 0:
            continue
        start = out.find(b"<?xml")
        if start < 0:
            start = out.find(b"<plist")
        if start < 0:
            return {}  # signed without entitlements
        try:
            return plistlib.loads(out[start:])
        except Exception as exc:
            rep.error(f"{label}: cannot parse the signature's entitlements: {exc}")
            return None
    rep.error(f"{label}: codesign cannot read the signature (is the bundle signed?)")
    return None


def embedded_profile(bundle: str):
    """The plist inside embedded.mobileprovision (a CMS envelope around plain XML), or None."""
    path = os.path.join(bundle, "embedded.mobileprovision")
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    start, end = data.find(b"<?xml"), data.rfind(b"</plist>")
    if start < 0 or end < 0:
        return None
    try:
        return plistlib.loads(data[start:end + len(b"</plist>")])
    except Exception:
        return None


# ---------------------------------------------------------------- checks
def check_privacy(rep: Report, bundle: str, info: dict, label: str, fallback_declared=None) -> None:
    executable = info.get("CFBundleExecutable") or os.path.splitext(bundle_name(bundle))[0]
    binary = os.path.join(bundle, executable)
    if not os.path.isfile(binary):
        rep.error(f"{label}: executable {executable} is missing")
        return
    scanned = scan_binary(rep, binary, label)
    declared = read_privacy_manifest(rep, bundle, label)
    if declared is None and fallback_declared is None:
        if not os.path.isfile(os.path.join(bundle, "PrivacyInfo.xcprivacy")):
            rep.error(f"{label}: PrivacyInfo.xcprivacy is missing (it must be copied into the bundle: "
                      f"Copy Bundle Resources)")
    if scanned is None:
        rep.rows.append((label, "(binary not scanned)", fmt_declared(declared), "error"))
        return
    symbols, selectors = scanned
    used = required_categories(symbols, selectors)
    effective = dict(fallback_declared or {})
    effective.update(declared or {})
    missing = sorted(c for c in used if c not in effective)
    for category in missing:
        rep.error(f"{label}: the binary uses required-reason API category {category} "
                  f"({', '.join(used[category][:6])}) but PrivacyInfo.xcprivacy does not declare "
                  f"{CATEGORY_PREFIX}{category}")
    unused = sorted(c for c in (declared or {}) if c not in used)
    for category in unused:
        rep.warn(f"{label}: PrivacyInfo.xcprivacy declares {category} but the binary does not use it "
                 f"(declare only what the binary uses)")
    for what, cls_symbols, cls_selectors, keys in PURPOSE_STRINGS:
        evidence = sorted(symbols & cls_symbols) + sorted(selectors & cls_selectors)
        if evidence and not any(isinstance(info.get(k), str) and info.get(k).strip() for k in keys):
            rep.error(f"{label}: the binary references {what} APIs ({', '.join(evidence)}) but its "
                      f"Info.plist has no {' / '.join(keys)} purpose string (ITMS-90683)")
    used_text = "; ".join(f"{c} ({', '.join(e[:4])}{', …' if len(e) > 4 else ''})"
                          for c, e in sorted(used.items())) or "none"
    verdict = "MISSING " + ", ".join(missing) if missing else "ok"
    if unused and not missing:
        verdict = "ok (declared but unused: " + ", ".join(unused) + ")"
    rep.rows.append((label, used_text, fmt_declared(declared), verdict))


def fmt_declared(declared) -> str:
    if declared is None:
        return "(no PrivacyInfo.xcprivacy)"
    if not declared:
        return "none"
    return "; ".join(f"{c} [{', '.join(r)}]" for c, r in sorted(declared.items()))


def check_entitlements(rep: Report, bundle: str, info: dict, label: str, app_group: str,
                       is_app: bool, require_beta_reports: bool) -> None:
    ents = signed_entitlements(rep, bundle, label)
    if ents is None:
        return
    groups = ents.get(ENT_GROUPS)
    if not isinstance(groups, list) or app_group not in groups:
        rep.error(f"{label}: signed entitlements lack App Group {app_group} "
                  f"({ENT_GROUPS} = {groups!r})")
    if ents.get("get-task-allow") not in (None, False):
        rep.error(f"{label}: get-task-allow is {ents.get('get-task-allow')!r}: a development signature, "
                  f"App Store Connect needs a distribution one")
    if require_beta_reports and ents.get("beta-reports-active") is not True:
        rep.error(f"{label}: beta-reports-active is not true: TestFlight will not accept this build "
                  f"(was it exported with method app-store-connect and an App Store profile?)")
    if is_app:
        for key in (ENT_HOTSPOT, ENT_WIFI):
            if ents.get(key) is not True:
                rep.error(f"{label}: signed entitlements lack {key} = true")
    app_identifier = ents.get("application-identifier", "")
    bundle_id = info.get("CFBundleIdentifier", "")
    if app_identifier and bundle_id and not str(app_identifier).endswith("." + bundle_id):
        rep.error(f"{label}: application-identifier {app_identifier} does not match {bundle_id}")
    profile = embedded_profile(bundle)
    if profile is None:
        rep.error(f"{label}: embedded.mobileprovision is missing or unreadable")
        return
    if profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
        rep.error(f"{label}: the embedded profile '{profile.get('Name')}' is not an App Store profile "
                  f"(it lists devices)")
    profile_ents = profile.get("Entitlements", {}) or {}
    if profile_ents.get("get-task-allow") not in (None, False):
        rep.error(f"{label}: the embedded profile '{profile.get('Name')}' allows get-task-allow "
                  f"(development profile)")
    expires = profile.get("ExpirationDate")
    if isinstance(expires, datetime.datetime):
        now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        if expires.replace(tzinfo=None) < now:
            rep.error(f"{label}: the embedded profile expired on {expires}")


def check_codesign_verify(rep: Report, app: str, label: str) -> None:
    status, out, err = run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
    if status != 0:
        lines = [ln for ln in (err + out).splitlines() if ln.strip()][-8:]
        rep.error(f"{label}: codesign --verify --deep --strict failed: " + " | ".join(lines))


def load_info(rep: Report, bundle: str, label: str) -> dict:
    path = os.path.join(bundle, "Info.plist")
    try:
        info = load_plist(path)
        if isinstance(info, dict):
            return info
        rep.error(f"{label}: Info.plist is not a dictionary")
    except FileNotFoundError:
        rep.error(f"{label}: Info.plist is missing")
    except Exception as exc:
        rep.error(f"{label}: Info.plist is unreadable: {exc}")
    return {}


def lint_app(rep: Report, app: str, args, signed: bool, is_ipa: bool) -> None:
    app_label = bundle_name(app)
    info = load_info(rep, app, app_label)
    rep.contents.append((app_label, list_bundle(app)))

    # Bundle basics App Store Connect rejects at upload time.
    if "ITSAppUsesNonExemptEncryption" not in info:
        rep.error(f"{app_label}: Info.plist lacks ITSAppUsesNonExemptEncryption (TestFlight would stop "
                  f"at the export-compliance question)")
    if not (info.get("CFBundleIconName") or info.get("CFBundleIcons")):
        rep.error(f"{app_label}: Info.plist has neither CFBundleIconName nor CFBundleIcons (ITMS-90713)")
    if not os.path.isfile(os.path.join(app, "Assets.car")):
        rep.error(f"{app_label}: Assets.car is missing (compiled asset catalog with the app icon)")
    platforms = info.get("CFBundleSupportedPlatforms") or []
    if "iPhoneOS" not in platforms:
        rep.error(f"{app_label}: built for {platforms!r}, not iPhoneOS (a simulator build cannot be uploaded)")

    # Devices: on iPad, App Store Connect wants every orientation unless the app opts out of
    # multitasking (UIRequiresFullScreen).
    family = device_family(info)
    orientations = string_list(info.get("UISupportedInterfaceOrientations"))
    ipad_orientations = string_list(info.get("UISupportedInterfaceOrientations~ipad")) or orientations
    if family and 2 in family and info.get("UIRequiresFullScreen") is not True:
        missing = sorted(IPAD_ORIENTATIONS - set(ipad_orientations))
        if missing:
            rep.error(f"{app_label}: UIDeviceFamily {fmt_family(family)} includes iPad, but the iPad "
                      f"orientations lack {short_orientations(missing)}: App Store Connect rejects the "
                      f"upload (ITMS-90474). Set TARGETED_DEVICE_FAMILY = 1 on both targets in "
                      f"project.yml (iPhone only), or support all four orientations on iPad")
    if args.expect_device_family and family != args.expect_device_family:
        rep.error(f"{app_label}: UIDeviceFamily is {fmt_family(family)}, expected "
                  f"{fmt_family(args.expect_device_family)} (TARGETED_DEVICE_FAMILY of both targets in "
                  f"project.yml)")
    fact = f"UIDeviceFamily {fmt_family(family)}; orientations {short_orientations(orientations)}"
    if "UISupportedInterfaceOrientations~ipad" in info:
        fact += f"; iPad orientations {short_orientations(ipad_orientations)}"
    rep.facts.append((app_label, fact))
    if args.min_sdk_major:
        sdk = str(info.get("DTSDKName", ""))
        m = re.match(r"^iphoneos([0-9]+)", sdk)
        if not m or int(m.group(1)) < args.min_sdk_major:
            rep.error(f"{app_label}: built with SDK '{sdk or 'unknown'}' (Xcode {info.get('DTXcode', '?')}); "
                      f"App Store Connect needs the iOS {args.min_sdk_major} SDK or newer")

    # The broadcast extension.
    appex = os.path.join(app, "PlugIns", args.appex)
    appex_label = f"{app_label}/PlugIns/{args.appex}"
    appex_info = {}
    if not os.path.isdir(appex):
        found = list_bundle(os.path.join(app, "PlugIns"))
        rep.error(f"{app_label}: PlugIns/{args.appex} is missing (PlugIns: {', '.join(found) or 'none'})")
    else:
        appex_info = load_info(rep, appex, appex_label)
        rep.contents.append((appex_label, list_bundle(appex)))
        if os.path.isdir(os.path.join(appex, "Frameworks")):
            rep.error(f"{appex_label}: contains a Frameworks directory (ITMS-90206): frameworks must be "
                      f"embedded in the app only")
        app_id, appex_id = info.get("CFBundleIdentifier", ""), appex_info.get("CFBundleIdentifier", "")
        if app_id and not str(appex_id).startswith(app_id + "."):
            rep.error(f"{appex_label}: bundle id '{appex_id}' must start with the app's '{app_id}.'")
        for key in ("CFBundleVersion", "CFBundleShortVersionString"):
            if info.get(key) != appex_info.get(key):
                rep.error(f"{key} differs: app {info.get(key)!r}, extension {appex_info.get(key)!r} "
                          f"(App Store Connect rejects mismatched extension versions)")
        # The extension must target the same devices as the app (iPhone only here).
        appex_family = device_family(appex_info)
        if appex_family is not None and family is not None and appex_family != family:
            rep.error(f"{appex_label}: UIDeviceFamily {fmt_family(appex_family)} differs from the app's "
                      f"{fmt_family(family)}: set the same TARGETED_DEVICE_FAMILY on both targets in "
                      f"project.yml")
        rep.facts.append((appex_label, f"UIDeviceFamily {fmt_family(appex_family)}"))

    # Versions.
    for key, expected in (("CFBundleShortVersionString", args.expect_version),
                          ("CFBundleVersion", args.expect_build)):
        value = info.get(key)
        if not isinstance(value, str) or not VERSION_RE.match(value):
            rep.error(f"{app_label}: {key} {value!r} must be one to three dot-separated integers")
        if expected and value != expected:
            rep.error(f"{app_label}: {key} is {value!r}, expected {expected!r}")

    # Privacy: the app, the extension and any embedded framework (scanned on its own).
    check_privacy(rep, app, info, app_label)
    if appex_info:
        check_privacy(rep, appex, appex_info, appex_label)
    app_declared = read_privacy_manifest(Report("scratch"), app, app_label) or {}
    frameworks_dir = os.path.join(app, "Frameworks")
    for name in list_bundle(frameworks_dir):
        path = os.path.join(frameworks_dir, name.rstrip("/"))
        if name.endswith(".framework/"):
            fw_info = load_info(rep, path, f"{app_label}/Frameworks/{name.rstrip('/')}")
            check_privacy(rep, path, fw_info, f"{app_label}/Frameworks/{name.rstrip('/')}",
                          fallback_declared=app_declared)

    # Signature.
    if signed:
        app_group = args.app_group or info.get("OCMAppGroupIdentifier", "")
        if not app_group:
            rep.error(f"{app_label}: no App Group to check (pass --app-group or set OCMAppGroupIdentifier)")
        if args.app_group and info.get("OCMAppGroupIdentifier") not in (None, args.app_group):
            rep.error(f"{app_label}: OCMAppGroupIdentifier is {info.get('OCMAppGroupIdentifier')!r}, "
                      f"expected {args.app_group!r} (BUNDLE_ID_PREFIX mismatch?)")
        check_entitlements(rep, app, info, app_label, app_group, True, require_beta_reports=is_ipa)
        if appex_info:
            check_entitlements(rep, appex, appex_info, appex_label, app_group, False,
                               require_beta_reports=is_ipa)
        check_codesign_verify(rep, app, app_label)


def lint_archive(rep: Report, archive: str, args) -> None:
    info_path = os.path.join(archive, "Info.plist")
    try:
        info = load_plist(info_path)
    except Exception as exc:
        rep.error(f"{bundle_name(archive)}: Info.plist missing or unreadable ({exc}); is this an .xcarchive?")
        return
    products = os.path.join(archive, "Products")
    props = info.get("ApplicationProperties") if isinstance(info, dict) else None
    if not isinstance(props, dict):
        # Xcode makes an "iOS App" archive only when Products/ holds nothing but the app; any other
        # installed product (a static library, the extension on its own...) makes it "generic".
        others = []
        for root, dirs, files in os.walk(products):
            rel = os.path.relpath(root, products)
            bundles = [d for d in dirs if d.endswith(BUNDLE_EXTENSIONS)]
            dirs[:] = [d for d in dirs if not d.endswith(BUNDLE_EXTENSIONS)]  # do not descend into bundles
            for name in files + bundles:
                path = os.path.normpath(os.path.join(rel, name))
                if not (rel == "Applications" and name.endswith(".app")):  # the app itself is expected
                    others.append(path)
        rep.error("the archive is a 'Generic Xcode Archive' (Info.plist has no ApplicationProperties): "
                  "Xcode cannot export or upload it. Products/ also holds: "
                  + (", ".join(sorted(others)[:20]) or "nothing else (no app?)")
                  + " — set SKIP_INSTALL = YES on those targets")
    apps = sorted(glob_dirs(os.path.join(products, "Applications"), ".app"))
    if len(apps) != 1:
        rep.error(f"the archive must contain exactly one app in Products/Applications (found {len(apps)})")
        if not apps:
            return
    app = apps[0]
    if isinstance(props, dict):
        expected_path = os.path.join("Applications", bundle_name(app))
        if props.get("ApplicationPath") != expected_path:
            rep.warn(f"ApplicationPath is {props.get('ApplicationPath')!r}, expected {expected_path!r}")
        identity = str(props.get("SigningIdentity", ""))
        if not args.unsigned and identity and not identity.startswith(("Apple Distribution",
                                                                         "iPhone Distribution")):
            rep.warn(f"the archive is signed with '{identity}', not a distribution identity")
    lint_app(rep, app, args, signed=not args.unsigned, is_ipa=False)


def glob_dirs(parent: str, suffix: str) -> list:
    try:
        return [os.path.join(parent, n) for n in os.listdir(parent)
                if n.endswith(suffix) and os.path.isdir(os.path.join(parent, n))]
    except OSError:
        return []


def extract_ipa(ipa: str, dest: str) -> None:
    # ditto keeps permissions, symlinks and extended attributes exactly as Xcode wrote them.
    if shutil.which("ditto"):
        status, out, err = run(["ditto", "-x", "-k", ipa, dest])
        if status != 0:
            raise RuntimeError(f"ditto could not unpack the IPA: {err.strip()[:300]}")
        return
    with zipfile.ZipFile(ipa) as zf:
        zf.extractall(dest)


def lint_ipa(rep: Report, ipa: str, args) -> None:
    tmp = tempfile.mkdtemp(prefix="lint-ipa-")
    try:
        try:
            extract_ipa(ipa, tmp)
        except Exception as exc:
            rep.error(f"{bundle_name(ipa)}: cannot unpack: {exc}")
            return
        apps = sorted(glob_dirs(os.path.join(tmp, "Payload"), ".app"))
        if len(apps) != 1:
            rep.error(f"{bundle_name(ipa)}: Payload/ must contain exactly one .app (found {len(apps)})")
            if not apps:
                return
        lint_app(rep, apps[0], args, signed=True, is_ipa=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------- report
def print_report(rep: Report) -> None:
    header = ("Bundle", "Required-reason APIs used (evidence)", "Declared in PrivacyInfo.xcprivacy", "Result")
    print(f"\n== Bundle lint: {rep.label} ==")
    for row in [header] + rep.rows:
        print(" | ".join(row))
    for name, files in rep.contents:
        print(f"{name}: {' '.join(files)}")
    for name, fact in rep.facts:
        print(f"{name}: {fact}")
    for w in rep.warnings:
        print(f"warning: {w}")
    for e in rep.errors:
        print(f"error: {e}")

    # Annotations: raw logs may be unreadable, so the findings travel as annotations too.
    for label, used, declared, verdict in rep.rows:
        files = next((f for n, f in rep.contents if n == label), [])
        devices = next((f for n, f in rep.facts if n == label), "?")
        annotate("notice", f"Privacy manifest check: {label}",
                 f"uses: {used}\ndeclared: {declared}\nresult: {verdict}\ndevices: {devices}\n"
                 f"bundle files: {', '.join(files)}")
    if rep.warnings:
        annotate("warning", f"Bundle lint ({rep.label}): {len(rep.warnings)} warning(s)", "\n".join(rep.warnings))
    if rep.errors:
        annotate("error", f"Bundle lint ({rep.label}): {len(rep.errors)} problem(s)", "\n".join(rep.errors))
        for e in rep.errors[:MAX_INDIVIDUAL_ERRORS]:
            annotate("error", f"Bundle lint ({rep.label})", e)

    md = [f"\n### Revisión del paquete / Bundle lint — {rep.label}\n\n",
          "| " + " | ".join(header) + " |\n", "|---|---|---|---|\n"]
    for row in rep.rows:
        md.append("| " + " | ".join(c.replace("|", "\\|") for c in row) + " |\n")
    if rep.facts:
        md.append("\n" + "".join(f"- {name}: {fact}\n" for name, fact in rep.facts))
    if rep.errors:
        md.append(f"\n**{len(rep.errors)} problema(s) / problem(s):**\n\n")
        md.extend(f"- {e}\n" for e in rep.errors)
    else:
        md.append("\nSin problemas / No problems found.\n")
    if rep.warnings:
        md.append("\nAvisos / Warnings:\n\n")
        md.extend(f"- {w}\n" for w in rep.warnings)
    append_summary("".join(md))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Lint an iOS archive or IPA before a TestFlight upload.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--archive", help="path to the .xcarchive")
    source.add_argument("--ipa", help="path to the exported .ipa")
    parser.add_argument("--unsigned", action="store_true", help="archive built with CODE_SIGNING_ALLOWED=NO")
    parser.add_argument("--app-group", help="App Group the signed entitlements must contain")
    parser.add_argument("--expect-version", help="expected CFBundleShortVersionString")
    parser.add_argument("--expect-build", help="expected CFBundleVersion")
    parser.add_argument("--expect-device-family", type=parse_family,
                        help="expected UIDeviceFamily, e.g. 1 (iPhone only) or 1,2")
    parser.add_argument("--min-sdk-major", type=int, help="minimum iOS SDK major version (e.g. 26)")
    parser.add_argument("--appex", default=DEFAULT_APPEX, help=f"extension bundle name (default {DEFAULT_APPEX})")
    args = parser.parse_args(argv)
    if args.ipa and args.unsigned:
        parser.error("--unsigned applies to --archive only (an IPA for App Store Connect is always signed)")

    target = args.archive or args.ipa
    label = ("unsigned archive" if args.unsigned else "archive") if args.archive else "IPA"
    rep = Report(f"{label} {bundle_name(target)}")
    try:
        if not os.path.exists(target):
            rep.error(f"{target} does not exist")
        elif args.archive:
            lint_archive(rep, args.archive, args)
        else:
            lint_ipa(rep, args.ipa, args)
    except Exception as exc:  # report, never die silently: CI only shows annotations
        rep.error(f"lint_bundle.py crashed: {type(exc).__name__}: {exc}")
    print_report(rep)
    return 1 if rep.errors else 0


if __name__ == "__main__":
    sys.exit(main())
