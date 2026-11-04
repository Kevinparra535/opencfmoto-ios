#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The sideload build (docs/INSTALAR.md), step 1 of 2: an unsigned Release archive for iPhone of the
# FREE flavour (OCM_FLAVOR = free: no Hotspot / Access Wi-Fi Information entitlements, so riders
# join the bike Wi-Fi in Settings and every free Apple ID can sign it), under a public bundle id
# prefix and with no team, linted like the TestFlight build. Step 2, tools/release/package_ipa.sh,
# signs it ad hoc and zips the IPA. Used by .github/workflows/release.yml and by the sideload dry
# run in ci.yml; also works on a Mac.
#
#   usage: build_ipa.sh <archive path> <vX.Y.Z> <build number>
#
# Environment:
#   SIDELOAD_BUNDLE_PREFIX   bundle id prefix (default io.github.<GITHUB_REPOSITORY_OWNER in lower
#                            case>). Not the TestFlight prefix: AltStore / SideStore append the
#                            rider's team id, Sideloadly makes its own id, so this one only names the
#                            build. The App Group is group.<prefix>.opencfmoto.
#
# Writes Config/Local.xcconfig for the build and deletes it on exit (refuses to run when one exists:
# a developer's own); the generated Xcode project keeps these settings until the next
# `xcodegen generate`. Every failure ends with a ::error annotation. Written for bash 3.2.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_XCCONFIG="$ROOT/Config/Local.xcconfig"
ANNOTATE="$ROOT/tools/ci/annotate.py"
MIN_SDK_MAJOR=26 # the newest Xcode, as for TestFlight: it supports the newest iOS on riders' iPhones

esc() { local s=${1//'%'/%25}; s=${s//$'\r'/%0D}; s=${s//$'\n'/%0A}; printf '%s' "$s"; }
die() {
  printf '::error title=%s::%s\n' "Sideload build" "$(esc "$1")"
  exit 1
}
note() { printf '==> %s\n' "$*"; }
trap 'die "build_ipa.sh line $LINENO: \"$BASH_COMMAND\" failed"' ERR

if [ $# -ne 3 ]; then
  echo "usage: build_ipa.sh <archive path> <vX.Y.Z> <build number>" >&2
  exit 2
fi
ARCHIVE=$1 VERSION=$2 BUILD=$3

if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then die "The version must be vX.Y.Z (e.g. v0.1.0)."; fi
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then die "The build number must be a whole number."; fi
declared=$(sed -n -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?[[:space:]]*$/\1/p' "$ROOT/project.yml" | awk 'NR == 1')
if [ "${VERSION#v}" != "$declared" ]; then
  die "project.yml says MARKETING_VERSION ${declared:-?}: build v${declared:-?}, or raise the version in project.yml first."
fi

if [ -n "${SIDELOAD_BUNDLE_PREFIX:-}" ]; then
  PREFIX=$SIDELOAD_BUNDLE_PREFIX
elif [ -n "${GITHUB_REPOSITORY_OWNER:-}" ]; then
  PREFIX="io.github.$(printf '%s' "$GITHUB_REPOSITORY_OWNER" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
else
  die "Set SIDELOAD_BUNDLE_PREFIX (e.g. io.github.yourname)."
fi
if ! [[ "$PREFIX" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then die "Not a valid bundle id prefix: $PREFIX"; fi

if [ -e "$LOCAL_XCCONFIG" ]; then
  die "Config/Local.xcconfig exists (a developer's own settings): move it away first; this build writes its own."
fi
cleanup() { rm -f "$LOCAL_XCCONFIG"; }
trap cleanup EXIT

# Config/OpenCfMoto.xcconfig includes Local.xcconfig last. Signing stays at the developer defaults
# (Automatic): CODE_SIGNING_ALLOWED=NO below turns it off.
cat > "$LOCAL_XCCONFIG" << EOF
// Written by tools/release/build_ipa.sh (the sideload build); deleted when it ends.
BUNDLE_ID_PREFIX = $PREFIX
DEVELOPMENT_TEAM =
OCM_FLAVOR = free
EOF
note "free flavour, bundle id prefix $PREFIX, no team, unsigned"
(cd "$ROOT" && xcodegen generate) || die "xcodegen generate failed."

project="$ROOT/OpenCfMoto.xcodeproj"
python3 "$ROOT/tools/testflight/assert_build_settings.py" --project "$project" --configuration Release \
  --label "Sideload build settings" \
  "OpenCfMoto:OCM_FLAVOR=free" "OpenCfMoto:CODE_SIGN_ENTITLEMENTS=App/Entitlements/free.entitlements" \
  "OpenCfMotoMirror:CODE_SIGN_ENTITLEMENTS=MirrorExtension/OpenCfMotoMirror.entitlements" \
  "OpenCfMoto:PRODUCT_BUNDLE_IDENTIFIER=$PREFIX.opencfmoto" \
  "OpenCfMotoMirror:PRODUCT_BUNDLE_IDENTIFIER=$PREFIX.opencfmoto.mirror" \
  "OpenCfMoto:APP_GROUP_ID=group.$PREFIX.opencfmoto" "OpenCfMotoMirror:APP_GROUP_ID=group.$PREFIX.opencfmoto" \
  "OpenCfMoto:DEVELOPMENT_TEAM=" "OpenCfMotoMirror:DEVELOPMENT_TEAM=" \
  "OpenCfMoto:TARGETED_DEVICE_FAMILY=1" "OpenCfMotoMirror:TARGETED_DEVICE_FAMILY=1" \
  || die "The sideload build settings are not as expected (see the annotation above)."
# The free flavour's Swift flag: without it the app would still try to join Wi-Fi networks itself.
conditions=$(xcodebuild -project "$project" -target OpenCfMoto -configuration Release -sdk iphoneos \
  -showBuildSettings 2> /dev/null | awk -F ' = ' '$1 ~ /^[[:space:]]*SWIFT_ACTIVE_COMPILATION_CONDITIONS$/ { v = $2 } END { print v }')
case " $conditions " in
  *" OCM_NO_HOTSPOT "*) note "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $conditions" ;;
  *) die "SWIFT_ACTIVE_COMPILATION_CONDITIONS lacks OCM_NO_HOTSPOT (it is «$conditions»): not the free flavour." ;;
esac

rm -rf "$ARCHIVE"
mkdir -p "$(dirname "$ARCHIVE")"
log="$(dirname "$ARCHIVE")/archive.log"
note "xcodebuild archive (Release, generic iOS device, CODE_SIGNING_ALLOWED=NO, build $BUILD)"
status=0
xcodebuild -project "$project" -scheme OpenCfMoto -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$BUILD" archive > "$log" 2>&1 || status=$?
grep -E "error:|\*\* ARCHIVE (SUCCEEDED|FAILED) \*\*" "$log" | head -n 200 || true
if [ "$status" -ne 0 ] || ! grep -q "ARCHIVE SUCCEEDED" "$log"; then
  tail -n 40 "$log" || true
  python3 "$ANNOTATE" "$log" "Sideload archive" || true
  die "xcodebuild archive failed (exit $status; details in the annotations)."
fi

python3 "$ROOT/tools/testflight/lint_bundle.py" --archive "$ARCHIVE" --unsigned --expect-version "${VERSION#v}" \
  --expect-build "$BUILD" --min-sdk-major "$MIN_SDK_MAJOR" --expect-device-family 1 \
  || die "The archive does not pass tools/testflight/lint_bundle.py (see the annotations above)."
note "archive ready: $ARCHIVE"
