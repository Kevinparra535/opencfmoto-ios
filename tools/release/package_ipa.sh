#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The sideload build (docs/INSTALAR.md), step 2 of 2: the IPA from tools/release/build_ipa.sh's
# unsigned archive. macOS only (codesign, ditto).
#
# Riders sign the IPA again with their own Apple ID, and SideStore / AltStore register the App
# Groups that the IPA's signature carries (an unsigned app carries none, and mirror mode would be
# off). So it is signed ad hoc, with no certificate and no team, and exactly one entitlement: the
# App Group the app declares (OCMAppGroupIdentifier). The extension first, then the app. The script
# fails when anything else shows up: a team ID, another entitlement, an embedded provisioning
# profile, or a signature that does not verify again after zipping. It also fails when the IPA lacks
# the licence texts (LICENSE, NOTICE, Apache-2.0.txt at the app's root, as project.yml bundles them):
# riders who add the AltStore / SideStore source receive only the IPA.
#
#   usage: package_ipa.sh <unsigned .xcarchive> <out dir> <vX.Y.Z>
#
# Writes <out dir>/OpenCfMoto-<vX.Y.Z>-sideload.ipa and <out dir>/SHA256SUMS.txt (check with
# `shasum -a 256 -c SHA256SUMS.txt`), and the step outputs ipa_name and sha256 (GITHUB_OUTPUT).
# Every failure ends with a ::error annotation. Written for bash 3.2.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENT_APP_GROUPS=com.apple.security.application-groups
# The licence texts inside the app: <name in the bundle>=<file in the repository>.
LICENCE_FILES=(LICENSE=LICENSE NOTICE=NOTICE Apache-2.0.txt=LICENSES/Apache-2.0.txt)

esc() { local s=${1//'%'/%25}; s=${s//$'\r'/%0D}; s=${s//$'\n'/%0A}; printf '%s' "$s"; }
die() {
  printf '::error title=%s::%s\n' "Sideload IPA" "$(esc "$1")"
  exit 1
}
note() { printf '==> %s\n' "$*"; }
trap 'die "package_ipa.sh line $LINENO: \"$BASH_COMMAND\" failed"' ERR

if [ $# -ne 3 ]; then
  echo "usage: package_ipa.sh <unsigned .xcarchive> <out dir> <vX.Y.Z>" >&2
  exit 2
fi
ARCHIVE=$1 OUT=$2 VERSION=$3
if [ "$(uname -s)" != Darwin ]; then die "This step needs macOS (codesign)."; fi
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then die "The version must be vX.Y.Z (e.g. v0.1.0)."; fi
SRC_APP="$ARCHIVE/Products/Applications/OpenCfMoto.app"
if [ ! -d "$SRC_APP" ]; then die "No Products/Applications/OpenCfMoto.app in $ARCHIVE."; fi

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sideload-ipa.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Payload/OpenCfMoto.app"
APPEX="$APP/PlugIns/OpenCfMotoMirror.appex"
IPA_NAME="OpenCfMoto-$VERSION-sideload.ipa"

# 1. The app (with its extension) into Payload/, without any provisioning profile.
mkdir -p "$WORK/Payload"
ditto "$SRC_APP" "$APP"
find "$APP" -name embedded.mobileprovision -exec rm -f {} +
if [ ! -d "$APPEX" ]; then die "The app has no PlugIns/OpenCfMotoMirror.appex (the screen mirroring extension)."; fi

# 2. What the bundles declare.
# A top-level Info.plist value (nothing when the key is missing; plistlib reads binary plists).
plist_value() {
  python3 -I -c 'import plistlib, sys
try:
    with open(sys.argv[1], "rb") as fh:
        value = plistlib.load(fh).get(sys.argv[2])
except Exception:
    value = None
if value is not None:
    print(value)' "$1/Info.plist" "$2"
}
app_id=$(plist_value "$APP" CFBundleIdentifier)
ext_id=$(plist_value "$APPEX" CFBundleIdentifier)
group=$(plist_value "$APP" OCMAppGroupIdentifier)
ext_group=$(plist_value "$APPEX" OCMAppGroupIdentifier)
short=$(plist_value "$APP" CFBundleShortVersionString)
case "$app_id" in *.opencfmoto) ;; *) die "The app's bundle id «$app_id» does not end in .opencfmoto." ;; esac
if [ "$ext_id" != "$app_id.mirror" ]; then die "The extension's bundle id is «$ext_id», expected «$app_id.mirror»."; fi
if [ "$group" != "group.$app_id" ] || [ "$ext_group" != "$group" ]; then
  die "OCMAppGroupIdentifier is «$group» (app) / «$ext_group» (extension), expected group.$app_id in both."
fi
if [ "$short" != "${VERSION#v}" ]; then die "The app is version «$short», not ${VERSION#v}."; fi
for bundle in "$APP" "$APPEX"; do
  if [ -n "$(plist_value "$bundle" ALTAppGroups)" ]; then
    die "$(basename "$bundle") already lists ALTAppGroups: this is not a fresh archive (re-signed by AltStore?)."
  fi
done

# 3. Sign inside out: nested code first (none today: the Swift packages are linked statically),
#    then the extension, then the app. --generate-entitlement-der: iOS 15+ reads the DER copy.
ENTITLEMENTS="$WORK/entitlements.plist"
python3 -I -c 'import plistlib, sys
with open(sys.argv[1], "wb") as fh:
    plistlib.dump({sys.argv[2]: [sys.argv[3]]}, fh)' "$ENTITLEMENTS" "$ENT_APP_GROUPS" "$group"
sign() { codesign --force --sign - --timestamp=none --generate-entitlement-der "$@"; }
nested=0
while IFS= read -r -d '' code; do
  sign "$code"
  nested=$((nested + 1))
done < <(find "$APP" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
sign --entitlements "$ENTITLEMENTS" "$APPEX"
sign --entitlements "$ENTITLEMENTS" "$APP"
note "signed ad hoc: $nested nested framework(s) / dylib(s), the extension and the app, with only $ENT_APP_GROUPS = $group"

# 4. Check what the sideloading tools will read.
entitlements_of() {
  local xml
  xml=$(codesign -d --entitlements - --xml "$1" 2> /dev/null || true)
  if [ -z "$xml" ]; then xml=$(codesign -d --entitlements :- "$1" 2> /dev/null || true); fi
  printf '%s' "$xml"
}
for bundle in "$APPEX" "$APP"; do
  name=$(basename "$bundle")
  info=$(codesign -dvv "$bundle" 2>&1) || die "codesign -dvv failed for $name: $info"
  if ! grep -q -x 'Signature=adhoc' <<< "$info"; then die "$name is not signed ad hoc."; fi
  if ! grep -q -x 'TeamIdentifier=not set' <<< "$info"; then die "$name carries a team ID: the sideload IPA must not."; fi
  entitlements_of "$bundle" | python3 -I -c 'import plistlib, sys
raw = sys.stdin.buffer.read()
try:
    found = plistlib.loads(raw) if raw.strip() else {}
except Exception as exc:
    sys.exit("unreadable entitlements: %s" % exc)
want = {sys.argv[1]: [sys.argv[2]]}
if found != want:
    sys.exit("entitlements are %s, expected exactly %s" % (sorted(found), want))' "$ENT_APP_GROUPS" "$group" \
    || die "$name: its signature must carry exactly one entitlement, $ENT_APP_GROUPS = [$group] (see above)."
done
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 || die "codesign --verify --deep --strict failed for the app."
if [ -n "$(find "$APP" -name embedded.mobileprovision)" ]; then die "A provisioning profile is still inside the app."; fi

# 5. The IPA: Payload/ only (no __MACOSX, no extended attributes), then the same checks on a copy
#    unzipped from it.
rm -f "$OUT/$IPA_NAME"
(cd "$WORK" && zip -qry -X "$OUT/$IPA_NAME" Payload)
others=$(unzip -Z1 "$OUT/$IPA_NAME" | grep -v -E '^Payload(/|$)' || true)
if [ -n "$others" ]; then die "The IPA holds more than Payload/: $others"; fi
mkdir "$WORK/unzipped"
(cd "$WORK/unzipped" && unzip -q "$OUT/$IPA_NAME")
codesign --verify --deep --strict "$WORK/unzipped/Payload/OpenCfMoto.app" 2>&1 \
  || die "The signature does not verify in the zipped IPA (a file changed while zipping?)."
# The licence texts, byte for byte the repository's (project.yml copies them into the app).
found=""
for pair in "${LICENCE_FILES[@]}"; do
  name=${pair%%=*} src=${pair#*=}
  inside="$WORK/unzipped/Payload/OpenCfMoto.app/$name"
  [ -f "$inside" ] || die "The IPA lacks Payload/OpenCfMoto.app/$name (the $src text): check project.yml's resources."
  cmp -s "$inside" "$ROOT/$src" || die "Payload/OpenCfMoto.app/$name differs from the repository's $src."
  found="$found $name ($(wc -c < "$inside" | tr -d ' ') bytes)"
done
note "licence texts in the IPA, identical to the repository's:$found"

# 6. SHA256SUMS.txt (the format of `shasum -a 256` and `sha256sum`) and the step outputs.
(cd "$OUT" && shasum -a 256 "$IPA_NAME" > SHA256SUMS.txt)
sha=$(awk 'NR == 1 { print $1 }' "$OUT/SHA256SUMS.txt")
if ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then die "Could not compute the IPA's SHA-256."; fi
size=$(wc -c < "$OUT/$IPA_NAME" | tr -d ' ')
note "$IPA_NAME: $size bytes, SHA-256 $sha"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'ipa_name=%s\nsha256=%s\n' "$IPA_NAME" "$sha" >> "$GITHUB_OUTPUT"
fi
