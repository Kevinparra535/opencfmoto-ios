#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329 # the cmd_* functions are called indirectly: "cmd_${STEP//-/_}"
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build, sign and upload OpenCfMoto to TestFlight on a macOS GitHub Actions runner, with nothing but
# an App Store Connect API key (the owner has no Mac). .github/workflows/testflight.yml (job "build")
# runs one subcommand per step; `all` runs them in order (for a manual run on a Mac).
#
#   create-signing    asc.py create-signing: a distribution certificate + two App Store profiles
#   setup-keychain    a temporary keychain holding that identity and Apple's WWDR intermediate
#   install-profiles  copy the profiles to where every Xcode version looks for them
#   configure         Config/Local.xcconfig (Manual signing, the CI profiles) + xcodegen generate
#   archive           xcodebuild archive (Release, iPhone) + lint_bundle.py --archive
#   export            xcodebuild -exportArchive (app-store-connect) + lint_bundle.py --ipa
#   upload            asc.py upload (Build Upload API); `xcrun altool` when that API refuses (exit 3)
#   teardown          delete keychain, keys, profiles and Local.xcconfig; revoke the certificate and
#                     profiles at once unless the upload succeeded (then the workflow's finish job
#                     revokes them once Apple has processed the build). Safe to run more than once.
#   all               everything above in order, teardown on exit
#
# Environment:
#   TF_WORK          work directory (default $RUNNER_TEMP/testflight): keychain, archive, IPA, state
#   TF_SIGNING_DIR   asc.py create-signing --out (default $TF_WORK/signing): key.pem, cert.pem,
#                    profiles/<uuid>.mobileprovision, state.json
#   ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY   the API key: create-signing, upload and teardown only
#   APP_BUNDLE_ID MIRROR_BUNDLE_ID APP_BUNDLE_RESOURCE_ID MIRROR_BUNDLE_RESOURCE_ID APP_GROUP
#   BUNDLE_ID_PREFIX APP_ID BUILD_NUMBER MARKETING_VERSION   outputs of `asc.py prepare`
#   TF_ALLOW_UNTRUSTED_IDENTITY=1   setup-keychain accepts an identity macOS does not trust
#                                   (the CI dry run's self-signed certificate; never for real builds)
#
# Secrets never reach the log: passwords are random, masked (::add-mask::) and passed in the
# environment or in mode-600 files; teardown deletes every key file, also after a failure.
# Every failure ends with a ::error annotation (raw CI logs are not always readable). Written for
# bash 3.2 (/bin/bash on macOS) as well as newer versions.

set -Eeuo pipefail
umask 077 # keys, p12, passwords and everything else this script writes stay private

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASC="$ROOT/tools/testflight/asc.py"
LINT="$ROOT/tools/testflight/lint_bundle.py"
ANNOTATE="$ROOT/tools/ci/annotate.py"
WORK="${TF_WORK:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/testflight}"
SIGNING_DIR="${TF_SIGNING_DIR:-$WORK/signing}"
KEYCHAIN="$WORK/testflight.keychain-db"
STATE="$WORK/state.env"
ARCHIVE="$WORK/OpenCfMoto.xcarchive"
EXPORT_DIR="$WORK/export"
LOCAL_XCCONFIG="$ROOT/Config/Local.xcconfig"
OPENSSL="${OPENSSL:-/usr/bin/openssl}"
MIN_SDK_MAJOR="${TF_MIN_SDK_MAJOR:-26}" # App Store Connect only accepts builds made with the iOS 26 SDK
DOCS_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-Kevinparra535/opencfmoto-ios}/blob/main/docs/TESTFLIGHT.md"
STEP=""

# ------------------------------------------------------------------ output helpers
esc_data() { local s=${1//'%'/%25}; s=${s//$'\r'/%0D}; s=${s//$'\n'/%0A}; printf '%s' "$s"; }
esc_prop() { local s; s=$(esc_data "$1"); s=${s//:/%3A}; s=${s//,/%2C}; printf '%s' "$s"; }
annotate() { printf '::%s title=%s::%s\n' "$1" "$(esc_prop "$2")" "$(esc_data "$3")"; }
note() { printf '==> %s\n' "$*"; }
mask() { if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::add-mask::%s\n' "$1"; fi; }
gh_output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; fi; }
reported() { touch "$WORK/.reported.$$" 2>/dev/null || true; }

# Stop with a bilingual explanation: Spanish first, then English (annotation + job summary).
die() {
  annotate error "TestFlight ($STEP)" "$1"$'\n'"$2"
  summary "**Error ($STEP):** $1 — $2"
  reported
  exit 1
}

# Safety net for anything die() does not cover: name the failing command (never its expanded
# arguments: $BASH_COMMAND holds the unexpanded text, so no secret value can leak through it).
on_err() {
  if [ -e "$WORK/.reported.$$" ]; then return 0; fi
  reported
  annotate error "TestFlight ($STEP)" "Falló un comando (código $1, build_and_sign.sh línea $2): $3"$'\n'"A command failed (exit $1, build_and_sign.sh line $2): $3"
}
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

need_env() {
  local missing="" v
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then missing="$missing $v"; fi
  done
  if [ -n "$missing" ]; then
    die "Faltan variables de entorno:$missing" "Missing environment variables:$missing"
  fi
}

require_macos() {
  if [ "$(uname -s)" != Darwin ]; then die "Este paso necesita macOS." "This step needs macOS."; fi
}

state_set() { printf '%s=%q\n' "$1" "$2" >> "$STATE"; }
state_load() {
  if [ -f "$STATE" ]; then
    # shellcheck disable=SC1090
    . "$STATE"
  fi
}

random_secret() { "$OPENSSL" rand -hex 24; }

# key=value lines a tool appended to its GITHUB_OUTPUT file (multi-line values are not used).
output_value() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

# ------------------------------------------------------------------ create-signing
cmd_create_signing() {
  need_env ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY APP_BUNDLE_RESOURCE_ID MIRROR_BUNDLE_RESOURCE_ID \
    APP_BUNDLE_ID MIRROR_BUNDLE_ID APP_GROUP
  mkdir -p "$SIGNING_DIR"
  # Unique per run, so profiles left behind by a crashed run never clash by name.
  local suffix outputs="$WORK/create-signing.outputs" status=0
  suffix="${TF_SUFFIX:-${GITHUB_RUN_ID:-local$(date +%Y%m%d%H%M%S)}-${GITHUB_RUN_ATTEMPT:-1}}"
  : > "$outputs"
  note "creating a distribution certificate and two App Store profiles (suffix $suffix)"
  GITHUB_OUTPUT="$outputs" python3 "$ASC" create-signing \
    --app-bundle-resource-id "$APP_BUNDLE_RESOURCE_ID" --mirror-bundle-resource-id "$MIRROR_BUNDLE_RESOURCE_ID" \
    --app-bundle-id "$APP_BUNDLE_ID" --mirror-bundle-id "$MIRROR_BUNDLE_ID" --app-group "$APP_GROUP" \
    --out "$SIGNING_DIR" --suffix "$suffix" || status=$?
  # Pass every id on even after a failure: the job outputs and teardown need them.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then cat "$outputs" >> "$GITHUB_OUTPUT"; fi
  local profile_ids=""
  if [ -f "$SIGNING_DIR/state.json" ]; then
    profile_ids=$(python3 -I -c 'import json, sys
try:
    print(",".join(str(p) for p in json.load(open(sys.argv[1])).get("profile_ids") or []))
except Exception:
    pass' "$SIGNING_DIR/state.json")
  fi
  gh_output profile_ids "$profile_ids"
  if [ "$status" -ne 0 ]; then
    reported # asc.py has already explained the problem in an annotation
    exit "$status"
  fi

  local team app_name mirror_name
  team=$(output_value "$outputs" cert_team_id)
  if [ -z "$team" ]; then # fall back to the certificate itself: the team id is its subject OU
    team=$("$OPENSSL" x509 -in "$SIGNING_DIR/cert.pem" -noout -subject 2>/dev/null \
      | sed -n -E 's/.*OU[[:space:]]*=[[:space:]]*([A-Z0-9]{10}).*/\1/p' | head -n 1)
  fi
  app_name=$(output_value "$outputs" profile_app_name)
  mirror_name=$(output_value "$outputs" profile_mirror_name)
  if [ -z "$app_name" ]; then app_name="OpenCfMoto CI $suffix app"; fi
  if [ -z "$mirror_name" ]; then mirror_name="OpenCfMoto CI $suffix mirror"; fi
  if ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    die "No se pudo leer el Team ID del certificado ('$team')." "Could not read the team id from the certificate ('$team')."
  fi
  # The names end up in Config/Local.xcconfig and ExportOptions.plist: keep them plain.
  for v in "$app_name" "$mirror_name"; do
    if ! [[ "$v" =~ ^[A-Za-z0-9\ ._-]+$ ]]; then
      die "Nombre de perfil inesperado: '$v'." "Unexpected profile name: '$v'."
    fi
  done
  if [ ! -s "$SIGNING_DIR/key.pem" ] || [ ! -s "$SIGNING_DIR/cert.pem" ]; then
    die "asc.py no dejó key.pem / cert.pem en $SIGNING_DIR." "asc.py left no key.pem / cert.pem in $SIGNING_DIR."
  fi
  state_set S_TEAM_ID "$team"
  state_set S_PROFILE_APP_NAME "$app_name"
  state_set S_PROFILE_MIRROR_NAME "$mirror_name"
  note "team $team; profiles '$app_name' and '$mirror_name'; certificate $(output_value "$outputs" cert_id)"
}

# ------------------------------------------------------------------ setup-keychain
cmd_setup_keychain() {
  require_macos
  if [ ! -s "$SIGNING_DIR/key.pem" ] || [ ! -s "$SIGNING_DIR/cert.pem" ]; then
    die "No hay clave/certificado de firma en $SIGNING_DIR (¿falló create-signing?)." \
      "No signing key/certificate in $SIGNING_DIR (did create-signing fail?)."
  fi
  local kc_pass p12_pass p12="$WORK/signing.p12"
  kc_pass=$(random_secret)
  p12_pass=$(random_secret)
  mask "$kc_pass"
  mask "$p12_pass"
  printf '%s' "$kc_pass" > "$WORK/keychain-password" # archive/export unlock again with it

  # 1. A PKCS#12 bundle of key + certificate. `security import` only reads the legacy PKCS#12
  #    algorithms (3DES/RC2 + SHA-1 MAC): the defaults of /usr/bin/openssl (LibreSSL). OpenSSL 3
  #    defaults to AES/PBKDF2, which macOS rejects ("MAC verification failed"), hence -legacy there.
  local legacy="" version
  version=$("$OPENSSL" version 2> /dev/null || true)
  if [[ "$version" == "OpenSSL 3"* ]]; then legacy="-legacy"; fi
  P12_PASSWORD="$p12_pass" "$OPENSSL" pkcs12 -export ${legacy:+"$legacy"} -name "OpenCfMoto TestFlight CI" \
    -inkey "$SIGNING_DIR/key.pem" -in "$SIGNING_DIR/cert.pem" -passout env:P12_PASSWORD -out "$p12" \
    || die "openssl no pudo crear el archivo .p12." "openssl could not create the .p12 file."

  # 2. Our own keychain, unlocked, not locking itself again during the job.
  if [ ! -f "$WORK/keychains.orig" ]; then # first run: remember the user search list
    security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' \
      | grep -v -F "$KEYCHAIN" > "$WORK/keychains.orig" || true
  fi
  security delete-keychain "$KEYCHAIN" > /dev/null 2>&1 || true # left over by an earlier attempt
  security create-keychain -p "$kc_pass" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$kc_pass" "$KEYCHAIN"
  security import "$p12" -k "$KEYCHAIN" -f pkcs12 -P "$p12_pass" -T /usr/bin/codesign -T /usr/bin/security > /dev/null \
    || die "security no pudo importar el .p12 en el llavero temporal." "security could not import the .p12 into the temporary keychain."
  rm -f "$p12"

  # 3. Apple's WWDR intermediate: without it the identity is "not trusted" and codesign cannot
  #    build the certificate chain.
  import_wwdr

  # 4. Let Apple tools use the private key without the "allow access?" dialog: nobody can click it
  #    on a CI runner, and codesign would wait for it forever.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_pass" "$KEYCHAIN" > /dev/null

  # 5. Put the keychain first in the user search list: Xcode looks for identities there
  #    (xcodebuild -exportArchive has no --keychain option).
  local line
  local -a list=()
  while IFS= read -r line; do
    if [ -n "$line" ]; then list+=("$line"); fi
  done < "$WORK/keychains.orig"
  security list-keychains -d user -s "$KEYCHAIN" ${list[@]+"${list[@]}"}

  # 6. Check what Xcode will see.
  local ids
  if [ "${TF_ALLOW_UNTRUSTED_IDENTITY:-}" = 1 ]; then
    ids=$(security find-identity -p codesigning "$KEYCHAIN")
  else
    ids=$(security find-identity -v -p codesigning "$KEYCHAIN")
  fi
  printf '%s\n' "$ids"
  if ! grep -q '"Apple Distribution' <<< "$ids"; then
    local all
    all=$(security find-identity -p codesigning "$KEYCHAIN" 2>&1 | tr '\n' ' ')
    die "El llavero no tiene una identidad «Apple Distribution» válida: $all" \
      "The keychain has no valid \"Apple Distribution\" identity: $all"
  fi
  note "keychain ready: $KEYCHAIN"
}

import_wwdr() {
  # Apple Distribution certificates are issued by the WWDR "G3" intermediate today; also fetch a
  # newer generation if the certificate names one.
  local gens="G3" issuer gen cer subject err="$WORK/wwdr-import.err"
  issuer=$("$OPENSSL" x509 -in "$SIGNING_DIR/cert.pem" -noout -issuer 2>/dev/null || true)
  if [[ "$issuer" == *"Worldwide Developer Relations"* ]] && [[ "$issuer" =~ OU[[:space:]]*=[[:space:]]*(G[0-9]+) ]]; then
    if [ "${BASH_REMATCH[1]}" != G3 ]; then gens="G3 ${BASH_REMATCH[1]}"; fi
  fi
  for gen in $gens; do
    cer="$WORK/AppleWWDRCA$gen.cer"
    curl -fsSL --retry 3 --retry-delay 5 --max-time 60 -o "$cer" "https://www.apple.com/certificateauthority/AppleWWDRCA$gen.cer" \
      || die "No se pudo descargar el certificado intermedio WWDR $gen de apple.com." \
        "Could not download the WWDR $gen intermediate certificate from apple.com."
    subject=$("$OPENSSL" x509 -inform DER -in "$cer" -noout -subject 2>/dev/null || true)
    if [[ "$subject" != *"Apple Worldwide Developer Relations"* ]]; then
      die "AppleWWDRCA$gen.cer no es el certificado esperado ($subject)." "AppleWWDRCA$gen.cer is not the expected certificate ($subject)."
    fi
    if ! security import "$cer" -k "$KEYCHAIN" > /dev/null 2> "$err"; then
      if ! grep -q -i "already exists" "$err"; then
        die "security no pudo importar WWDR $gen: $(cat "$err")" "security could not import WWDR $gen: $(cat "$err")"
      fi
    fi
    note "imported the Apple WWDR $gen intermediate"
  done
}

unlock_keychain() {
  if [ ! -f "$WORK/keychain-password" ]; then
    die "No hay llavero temporal (¿falló setup-keychain?)." "No temporary keychain (did setup-keychain fail?)."
  fi
  security unlock-keychain -p "$(cat "$WORK/keychain-password")" "$KEYCHAIN"
}

# ------------------------------------------------------------------ install-profiles
cmd_install_profiles() {
  # Xcode 16+ reads ~/Library/Developer/Xcode/UserData/Provisioning Profiles, older versions
  # ~/Library/MobileDevice/Provisioning Profiles: install into both.
  local f d count=0
  for f in "$SIGNING_DIR"/profiles/*.mobileprovision; do
    if [ ! -f "$f" ]; then continue; fi
    for d in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
      mkdir -p "$d"
      cp "$f" "$d/"
      printf '%s\n' "$d/$(basename "$f")" >> "$WORK/installed-profiles"
    done
    count=$((count + 1))
  done
  if [ "$count" -ne 2 ]; then
    die "Se esperaban 2 perfiles en $SIGNING_DIR/profiles y hay $count." "Expected 2 profiles in $SIGNING_DIR/profiles, found $count."
  fi
  note "installed $count provisioning profiles"
}

# ------------------------------------------------------------------ configure
cmd_configure() {
  state_load
  need_env BUNDLE_ID_PREFIX
  if [ -z "${S_TEAM_ID:-}" ] || [ -z "${S_PROFILE_APP_NAME:-}" ] || [ -z "${S_PROFILE_MIRROR_NAME:-}" ]; then
    die "Falta el resultado de create-signing." "The create-signing results are missing."
  fi
  if ! [[ "$BUNDLE_ID_PREFIX" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    die "BUNDLE_ID_PREFIX no es válido: '$BUNDLE_ID_PREFIX'." "BUNDLE_ID_PREFIX is not valid: '$BUNDLE_ID_PREFIX'."
  fi
  if [ -e "$LOCAL_XCCONFIG" ] && [ ! -f "$WORK/wrote-local-xcconfig" ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
    die "Config/Local.xcconfig ya existe: muévelo a otro sitio antes (este paso lo sobrescribe)." \
      "Config/Local.xcconfig exists: move it away first (this step overwrites it)."
  fi
  # Config/OpenCfMoto.xcconfig includes this file last, so it overrides the developer defaults
  # (Automatic signing, Apple Development, no profile).
  cat > "$LOCAL_XCCONFIG" << EOF
// Written by tools/testflight/build_and_sign.sh for a TestFlight build; its teardown deletes it.
DEVELOPMENT_TEAM = $S_TEAM_ID
BUNDLE_ID_PREFIX = $BUNDLE_ID_PREFIX
OCM_FLAVOR = full
OCM_CODE_SIGN_STYLE = Manual
OCM_CODE_SIGN_IDENTITY = Apple Distribution
OCM_PROFILE_APP = $S_PROFILE_APP_NAME
OCM_PROFILE_MIRROR = $S_PROFILE_MIRROR_NAME
EOF
  touch "$WORK/wrote-local-xcconfig"
  note "wrote Config/Local.xcconfig (team $S_TEAM_ID, prefix $BUNDLE_ID_PREFIX, manual signing)"
  (cd "$ROOT" && xcodegen generate) || die "xcodegen generate falló." "xcodegen generate failed."
}

# ------------------------------------------------------------------ archive / export
# xcodebuild output is huge: keep it in a log, show errors and the result, annotate on failure.
run_xcodebuild() {
  local log=$1 success=$2 title=$3 status=0
  shift 3
  note "xcodebuild $*"
  xcodebuild "$@" > "$log" 2>&1 || status=$?
  grep -E "error:|warning: .*([Ss]ign|[Pp]rovision)|\*\* [A-Z ]+ (SUCCEEDED|FAILED) \*\*" "$log" | head -n 200 || true
  if [ "$status" -ne 0 ] || ! grep -q "$success" "$log"; then
    tail -n 40 "$log" || true
    python3 "$ANNOTATE" "$log" "$title" || true
    return 1
  fi
  return 0
}

# Plain-language hints for the signing failures an owner can fix on developer.apple.com.
signing_hints() {
  local log=$1
  if grep -q -E "Provisioning profile .*(doesn't include|doesn't match).*application-groups" "$log"; then
    annotate error "TestFlight: App Group" "El perfil no incluye el App Group ${APP_GROUP:-}: créalo y asígnalo a los DOS App IDs en developer.apple.com ▸ Identifiers, y vuelve a ejecutar. Guía: $DOCS_URL"$'\n'"The profile lacks App Group ${APP_GROUP:-}: create it and assign it to BOTH App IDs on developer.apple.com ▸ Identifiers, then run again. Guide: $DOCS_URL"
  fi
  if grep -q -E "Provisioning profile .*(doesn't include|doesn't match).*(HotspotConfiguration|wifi-info)" "$log"; then
    annotate error "TestFlight: capabilities" "Al App ID le falta Hotspot o Access Wi-Fi Information (la preparación las activa; ¿se desactivaron a mano?)."$'\n'"The App ID lacks Hotspot or Access Wi-Fi Information (the prepare job enables them; were they turned off by hand?)."
  fi
  if grep -q -E "No profiles? for|couldn't find any .*provisioning profiles" "$log"; then
    annotate error "TestFlight: profiles" "Xcode no encontró los perfiles de CI instalados (nombre o equipo distintos)."$'\n'"Xcode did not find the installed CI profiles (name or team mismatch)."
  fi
  if grep -q "errSecInternalComponent" "$log"; then
    annotate error "TestFlight: keychain" "codesign no pudo usar la clave privada (llavero bloqueado o lista de particiones)."$'\n'"codesign could not use the private key (locked keychain or key partition list)."
  fi
  return 0
}

lint_args() { # common lint_bundle.py options
  printf '%s\n' --app-group "$APP_GROUP" --expect-build "$BUILD_NUMBER" --min-sdk-major "$MIN_SDK_MAJOR"
  if [ -n "${MARKETING_VERSION:-}" ]; then printf '%s\n' --expect-version "$MARKETING_VERSION"; fi
}

cmd_archive() {
  require_macos
  state_load
  need_env BUILD_NUMBER APP_GROUP
  unlock_keychain
  rm -rf "$ARCHIVE"
  # CURRENT_PROJECT_VERSION = the build number asc.py chose (one more than any build Apple has);
  # --keychain keeps codesign on our keychain.
  if ! run_xcodebuild "$WORK/archive.log" "ARCHIVE SUCCEEDED" "TestFlight archive" \
    -project "$ROOT/OpenCfMoto.xcodeproj" -scheme OpenCfMoto -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
    archive; then
    signing_hints "$WORK/archive.log"
    die "xcodebuild archive falló (detalles en las anotaciones)." "xcodebuild archive failed (details in the annotations)."
  fi
  local -a lint=()
  local a
  while IFS= read -r a; do lint+=("$a"); done < <(lint_args)
  python3 "$LINT" --archive "$ARCHIVE" "${lint[@]}" || { reported; exit 1; }
}

cmd_export() {
  require_macos
  state_load
  need_env APP_BUNDLE_ID MIRROR_BUNDLE_ID APP_GROUP BUILD_NUMBER
  if [ -z "${S_TEAM_ID:-}" ]; then die "Falta el resultado de create-signing." "The create-signing results are missing."; fi
  unlock_keychain
  local options="$WORK/ExportOptions.plist" ipa
  TEAM_ID="$S_TEAM_ID" PROFILE_APP="$S_PROFILE_APP_NAME" PROFILE_MIRROR="$S_PROFILE_MIRROR_NAME" \
    APP_BUNDLE_ID="$APP_BUNDLE_ID" MIRROR_BUNDLE_ID="$MIRROR_BUNDLE_ID" python3 -I - "$options" << 'PY'
import os, plistlib, sys
options = {
    "method": "app-store-connect",            # Xcode 15.3+ name for "app-store"
    "signingStyle": "manual",
    "teamID": os.environ["TEAM_ID"],
    "signingCertificate": "Apple Distribution",
    "provisioningProfiles": {
        os.environ["APP_BUNDLE_ID"]: os.environ["PROFILE_APP"],
        os.environ["MIRROR_BUNDLE_ID"]: os.environ["PROFILE_MIRROR"],
    },
    "destination": "export",                  # only write the IPA; asc.py uploads it
    "uploadSymbols": True,
    "manageAppVersionAndBuildNumber": False,  # keep the build number asc.py chose
}
with open(sys.argv[1], "wb") as fh:
    plistlib.dump(options, fh)
PY
  rm -rf "$EXPORT_DIR"
  if ! run_xcodebuild "$WORK/export.log" "EXPORT SUCCEEDED" "TestFlight export" \
    -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$options" -exportPath "$EXPORT_DIR"; then
    distribution_log_errors
    signing_hints "$WORK/export.log"
    die "xcodebuild -exportArchive falló (detalles en las anotaciones)." "xcodebuild -exportArchive failed (details in the annotations)."
  fi
  ipa=$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -n 1)
  if [ -z "$ipa" ]; then die "La exportación no produjo ningún .ipa." "The export produced no .ipa."; fi
  state_set S_IPA "$ipa"
  note "IPA: $ipa ($(du -h "$ipa" | cut -f1))"
  local -a lint=()
  local a
  while IFS= read -r a; do lint+=("$a"); done < <(lint_args)
  python3 "$LINT" --ipa "$ipa" "${lint[@]}" || { reported; exit 1; }
}

# The export's own log (IDEDistribution*.log) names the real reason when exportArchive fails.
distribution_log_errors() {
  local dir lines
  dir=$(grep -o -E '/[^ ]+\.xcdistributionlogs' "$WORK/export.log" | head -n 1 || true)
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then return 0; fi
  lines=$(grep -h -i -E "error|failed" "$dir"/*.log 2> /dev/null | tail -n 25 || true)
  if [ -n "$lines" ]; then annotate error "TestFlight export (IDEDistribution log)" "$lines"; fi
  return 0
}

# ------------------------------------------------------------------ upload
cmd_upload() {
  state_load
  need_env ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY APP_ID MARKETING_VERSION BUILD_NUMBER
  local ipa="${S_IPA:-}" status=0
  if [ -z "$ipa" ] || [ ! -f "$ipa" ]; then die "No hay IPA (¿falló la exportación?)." "No IPA (did the export fail?)."; fi
  note "uploading $(basename "$ipa") $MARKETING_VERSION ($BUILD_NUMBER) with the Build Upload API"
  python3 "$ASC" upload --ipa "$ipa" --app-id "$APP_ID" --version "$MARKETING_VERSION" \
    --build "$BUILD_NUMBER" --timeout-min 30 || status=$?
  case "$status" in
    0)
      touch "$WORK/uploaded"
      gh_output upload_method rest
      ;;
    3) # the API refused before the file was committed: Apple's own uploader may still work
      annotate warning "TestFlight upload" "La API de subida de builds rechazó la subida; se intenta con xcrun altool."$'\n'"The Build Upload API refused the upload; trying xcrun altool instead."
      altool_upload "$ipa"
      ;;
    *)
      reported # asc.py has already explained why
      exit "$status"
      ;;
  esac
}

altool_upload() {
  require_macos
  local ipa=$1 dir="$HOME/.appstoreconnect/private_keys" key log="$WORK/altool.log" status=0 errors
  mkdir -p "$dir"
  key="$dir/AuthKey_${ASC_KEY_ID}.p8" # where altool looks for --apiKey
  printf '%s\n' "$key" >> "$WORK/secret-files"
  write_p8 "$key" || die "ASC_PRIVATE_KEY no parece el contenido de un archivo .p8." "ASC_PRIVATE_KEY does not look like the content of a .p8 file."
  xcrun altool --upload-app -f "$ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" > "$log" 2>&1 || status=$?
  rm -f "$key"
  cat "$log"
  # altool from Xcode 26 can exit 0 although the upload failed: trust its output, not only its status.
  if [ "$status" -eq 0 ] && ! grep -q "ERROR" "$log" && grep -q -E "UPLOAD SUCCEEDED|No errors uploading" "$log"; then
    touch "$WORK/uploaded"
    gh_output uploaded true
    gh_output upload_method altool
    note "uploaded with xcrun altool"
    return 0
  fi
  errors=$(grep -E "ERROR|[Ee]rror" "$log" | head -n 20 || true)
  die "xcrun altool no pudo subir la build (código $status): $errors" "xcrun altool could not upload the build (exit $status): $errors"
}

# The .p8 text from the secret, normalized: CRLF, surrounding blanks, literal "\n" and a key pasted
# on one line (no newlines between BEGIN and END) are all accepted; written with mode 600.
write_p8() {
  python3 -I - "$1" << 'PY'
import os, re, sys
raw = os.environ.get("ASC_PRIVATE_KEY", "").replace("\\n", "\n").replace("\r", "").strip()
m = re.search(r"-----BEGIN ([A-Z ]+)-----(.*?)-----END \1-----", raw, re.S)
label, body = (m.group(1), m.group(2)) if m else ("PRIVATE KEY", raw)
body = re.sub(r"\s+", "", body)
if not body or re.search(r"[^A-Za-z0-9+/=]", body):
    sys.exit("ASC_PRIVATE_KEY is not the text of an AuthKey_XXXXXXXXXX.p8 file")
lines = "\n".join(body[i:i + 64] for i in range(0, len(body), 64))
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write("-----BEGIN %s-----\n%s\n-----END %s-----\n" % (label, lines, label))
PY
}

# ------------------------------------------------------------------ teardown
cmd_teardown() {
  trap - ERR
  set +e # best effort: never stop half-way through the cleanup
  local f line
  if [ "$(uname -s)" = Darwin ]; then
    if [ -e "$KEYCHAIN" ]; then
      security delete-keychain "$KEYCHAIN" && note "deleted the temporary keychain"
    fi
    if [ -f "$WORK/keychains.orig" ]; then
      local -a list=()
      local count=0
      while IFS= read -r line; do
        if [ -n "$line" ]; then list+=("$line"); count=$((count + 1)); fi
      done < "$WORK/keychains.orig"
      # Never set an empty search list (a Mac would lose its login keychain from it).
      if [ "$count" -gt 0 ]; then security list-keychains -d user -s "${list[@]}"; fi
      rm -f "$WORK/keychains.orig"
    fi
  fi
  rm -f "$SIGNING_DIR/key.pem" "$WORK/signing.p12" "$WORK/keychain-password"
  if [ -f "$WORK/secret-files" ]; then
    while IFS= read -r f; do rm -f "$f"; done < "$WORK/secret-files"
    rm -f "$WORK/secret-files"
  fi
  if [ -f "$WORK/installed-profiles" ]; then
    while IFS= read -r f; do rm -f "$f"; done < "$WORK/installed-profiles"
    rm -f "$WORK/installed-profiles"
  fi
  if [ -f "$WORK/wrote-local-xcconfig" ]; then
    rm -f "$LOCAL_XCCONFIG" "$WORK/wrote-local-xcconfig"
  fi
  note "deleted the signing key, keychain password, installed profiles and Config/Local.xcconfig"

  # Apple side: a certificate counts against the team's small limit, so never leave one behind.
  if [ -f "$WORK/uploaded" ]; then
    note "the build was uploaded: the finish job revokes the CI certificate and profiles after Apple's processing"
  elif [ -f "$SIGNING_DIR/state.json" ] && [ ! -f "$WORK/apple-cleanup-done" ]; then
    if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_PRIVATE_KEY:-}" ]; then
      note "the build was not uploaded: revoking the CI certificate and profiles now"
      if python3 "$ASC" cleanup --state "$SIGNING_DIR/state.json"; then touch "$WORK/apple-cleanup-done"; fi
    else
      annotate warning "TestFlight (teardown)" "Sin clave de API no se pudo revocar el certificado de CI: revócalo en developer.apple.com ▸ Certificates."$'\n'"Without the API key the CI certificate could not be revoked: revoke it at developer.apple.com ▸ Certificates."
    fi
  fi
  return 0
}

# ------------------------------------------------------------------ main
cmd_all() {
  trap 'STEP=teardown; cmd_teardown' EXIT
  local s
  for s in create-signing setup-keychain install-profiles configure archive export upload; do
    STEP=$s
    "cmd_${s//-/_}"
  done
}

main() {
  STEP=${1:-}
  case "$STEP" in
    create-signing | setup-keychain | install-profiles | configure | archive | export | upload | teardown | all) ;;
    *)
      echo "usage: build_and_sign.sh create-signing|setup-keychain|install-profiles|configure|archive|export|upload|teardown|all" >&2
      exit 2
      ;;
  esac
  mkdir -p "$WORK"
  "cmd_${STEP//-/_}"
}

main "$@"
