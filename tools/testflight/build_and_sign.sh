#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329 # the cmd_* functions are called indirectly: "cmd_${STEP//-/_}"
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build, sign and upload OpenCfMoto to TestFlight on a macOS GitHub Actions runner, with nothing but
# an App Store Connect API key (the owner has no Mac). .github/workflows/testflight.yml (job "build")
# runs one subcommand per step; `all` runs them in order (for a manual run on a Mac).
#
#   create-signing    asc.py create-signing: a distribution certificate + two App Store profiles
#                     named after the run and the build number («OpenCfMoto CI <suffix> b<build> …»)
#   setup-keychain    a temporary keychain holding that identity and Apple's WWDR intermediate
#   install-profiles  copy the profiles to where every Xcode version looks for them
#   configure         Config/Local.xcconfig (Manual signing, the CI profiles) + xcodegen generate
#   archive           xcodebuild archive (Release, iPhone) + lint_bundle.py --archive
#   export            xcodebuild -exportArchive (app-store-connect) + lint_bundle.py --ipa
#   upload            asc.py upload (Build Upload API); `xcrun altool` when that API refuses (exit 3)
#   teardown          stop what a cancelled step left running; delete keychain, keys, profiles and
#                     Local.xcconfig; revoke the certificate and profiles at once unless the build
#                     reached Apple (uploaded, or committed or being committed: then the workflow's
#                     finish job keeps them if Apple accepts the build, until it accepts a newer one,
#                     and revokes them if not; teardown revokes only a duplicate certificate an
#                     unanswered request made). Writes the step outputs uploaded=true|false and
#                     teardown=done. Safe to run more than once, also without the API key.
#   all               everything above in order, teardown on exit. On a Mac there is no finish
#                     job: an uploaded build's set («OpenCfMoto CI local… b<build> …») stays, and
#                     the workflow's janitor revokes it 12 hours after it was made, whatever the
#                     build's state; submit a Mac-built build for beta review before then, or use
#                     the workflow
#
# Environment:
#   TF_WORK          work directory (default $RUNNER_TEMP/testflight): keychain, archive, IPA, state
#   TF_SIGNING_DIR   asc.py create-signing --out (default $TF_WORK/signing): key.pem, cert.pem,
#                    profiles/<uuid>.mobileprovision, state.json
#   ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY   the API key: create-signing, upload and teardown only
#   APP_BUNDLE_ID MIRROR_BUNDLE_ID APP_BUNDLE_RESOURCE_ID MIRROR_BUNDLE_RESOURCE_ID APP_GROUP
#   BUNDLE_ID_PREFIX APP_ID MARKETING_VERSION   outputs of `asc.py prepare`
#   BUILD_NUMBER     output of `asc.py next-build` (the workflow puts it in GITHUB_ENV)
#   TF_ALLOW_UNTRUSTED_IDENTITY=1   setup-keychain accepts an identity macOS does not trust
#                                   (the CI dry run's self-signed certificate; never for real builds)
#   TF_LEFTOVER_WAIT_SEC, TF_KILL_WAIT_SEC   teardown: how long to let a running create-signing
#                    finish (default 60 s) and to wait for stopped leftovers (default 15 s)
#   TF_DUPLICATES_WAIT_SEC   teardown of an uploaded build: how long the look for a duplicate
#                    certificate may take (default 120 s; GitHub stops Clean up soon after a cancel)
#   GITHUB_REPOSITORY_ID GITHUB_RUN_ID GITHUB_RUN_ATTEMPT BUILD_NUMBER   name the CI profiles
#                    ("OpenCfMoto CI r<repository>-<run>-<attempt> b<build> app"; "local<date>-1" on
#                    a Mac); TF_SUFFIX replaces that suffix (asc.py janitor never removes such
#                    profiles unless the result matches its names)
#
# The workflow runs each subcommand by its absolute path: that is how teardown recognizes (and
# stops) a subcommand a cancelled step left running.
#
# Secrets never reach the log: passwords are random, masked (::add-mask::) and passed in the
# environment or in mode-600 files; teardown deletes every key file, also after a failure. Neither
# does who signs: the log is public, and a signing identity is named after the account holder
# ("Apple Distribution: <legal name> (<team id>)"). Identities are only counted, the team ID is
# never printed, and every line of a tool's log shown here goes through redact() first.
# Every failure ends with a ::error annotation (raw CI logs are not always readable). Written for
# bash 3.2 (/bin/bash on macOS) as well as newer versions.

set -Eeuo pipefail
umask 077 # keys, p12, passwords and everything else this script writes stay private

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="$ROOT/tools/testflight/build_and_sign.sh"
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
DEVICE_FAMILY=1                        # iPhone only (TARGETED_DEVICE_FAMILY in project.yml)
LEFTOVER_WAIT_SEC="${TF_LEFTOVER_WAIT_SEC:-60}"
KILL_WAIT_SEC="${TF_KILL_WAIT_SEC:-15}"
DUPLICATES_WAIT_SEC="${TF_DUPLICATES_WAIT_SEC:-120}"
DOCS_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-Kevinparra535/opencfmoto-ios}/blob/main/docs/TESTFLIGHT.md"
URL_CERTS="https://developer.apple.com/account/resources/certificates/list"
URL_PROFILES="https://developer.apple.com/account/resources/profiles/list"
NEW_RUN_ES="lanza una ejecución nueva: Actions ▸ TestFlight ▸ Run workflow (Re-run repite el mismo commit, sin tus arreglos)"
NEW_RUN_EN="start a new run: Actions ▸ TestFlight ▸ Run workflow (Re-run repeats the same commit, without your fixes)"
FINISH_JOB="Processing, TestFlight group, keep or revoke the certificate" # the workflow's third job (asc.py FINISH_JOB)
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

# stdin to stdout without who signs: in "<kind>: <legal name> (<team id>)", quoted or not, the name
# and the team ID become placeholders, and so does this run's team ID (S_TEAM_ID) anywhere else.
# Every line of xcodebuild, altool, lint_bundle.py or Xcode distribution logs that this script
# prints or turns into annotations goes through it.
redact() {
  local team=${S_TEAM_ID:-}
  if ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then team="__no_team_id__"; fi
  LC_ALL=C sed -E \
    -e 's/(Apple|iPhone|iOS|Mac) (Distribution|Development|Developer)( ID)?: [^"()]*\([A-Z0-9]{10}\)/\1 \2: <name> (<team id>)/g' \
    -e 's/"(Apple|iPhone|iOS|Mac) (Distribution|Development|Developer)( ID)?: [^"]*"/"\1 \2: <name>"/g' \
    -e "s/$team/<team id>/g"
}

# How many distinct identities (SHA-1 hashes) `security find-identity` output ($1) lists: the
# "Apple Distribution" ones, or all of them with a second argument `any`. Never their names.
identity_count() {
  printf '%s\n' "$1" | awk -v any="${2:-}" '
    $1 ~ /^[0-9]+\)$/ && length($2) == 40 && (any != "" || index($0, "\"Apple Distribution") > 0) { seen[$2] = 1 }
    END { n = 0; for (k in seen) n++; print n }'
}

# A value of create-signing's state.json: a list joined with commas; only App Store Connect id
# characters; nothing when there is no such file or value.
state_json() {
  if [ ! -f "$SIGNING_DIR/state.json" ]; then return 0; fi
  python3 -I -c 'import json, re, sys
try:
    value = json.load(open(sys.argv[1])).get(sys.argv[2])
    values = value if isinstance(value, list) else [value]
    print(",".join(str(v) for v in values if re.fullmatch(r"[A-Za-z0-9._-]+", str(v or ""))))
except Exception:
    pass' "$SIGNING_DIR/state.json" "$1"
}

# The CI profiles' name suffix, as asc.py default_suffix() makes it: r<repository id>-<run>-<attempt>
# on GitHub (asc.py janitor knows this repository's profiles by it), local<date and time>-1 on a
# Mac, or TF_SUFFIX; cleaned as asc.py cleans it (clean_suffix), so it is the one in the names.
profile_suffix() {
  local suffix
  suffix="${GITHUB_RUN_ID:-local$(date +%Y%m%d%H%M%S)}-${GITHUB_RUN_ATTEMPT:-1}"
  case "${GITHUB_REPOSITORY_ID:-x}" in
    *[!0-9]*) ;;
    *) suffix="r$GITHUB_REPOSITORY_ID-$suffix" ;;
  esac
  python3 -I -c 'import re, sys
print(re.sub(r"[^A-Za-z0-9-]+", "-", sys.argv[1]).strip("-") or "run")' "${TF_SUFFIX:-$suffix}"
}

# Run a command with a time limit (macOS has no `timeout`): after $1 seconds it gets SIGALRM and
# ends with exit status 142.
bounded() {
  local seconds=$1
  shift
  if command -v perl > /dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV; exit 127' "$seconds" "$@"
  else
    "$@"
  fi
}

# ------------------------------------------------------------------ create-signing
cmd_create_signing() {
  need_env ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY APP_BUNDLE_RESOURCE_ID MIRROR_BUNDLE_RESOURCE_ID \
    APP_BUNDLE_ID MIRROR_BUNDLE_ID APP_GROUP
  # Markers and profiles of an earlier run in the same work directory (a manual run on a Mac) do
  # not apply to the certificate created now; install-profiles installs every profile it finds.
  rm -f "$WORK/uploaded" "$WORK/committed" "$WORK/apple-cleanup-done" "$WORK/teardown-started"
  rm -f "$SIGNING_DIR"/profiles/*.mobileprovision
  mkdir -p "$SIGNING_DIR"
  # Unique per run, so profiles left behind by a crashed run never clash by name. Recorded before
  # asc.py runs: the teardown names this run's profiles by it in its manual steps.
  # The build number (the workflow's «Choose the build number» step runs first) goes into the
  # names too: the janitor decides about each kept signing set by its build's state.
  local suffix build="" outputs="$WORK/create-signing.outputs" status=0
  suffix=$(profile_suffix)
  case "${BUILD_NUMBER:-}" in
    '' | *[!0-9]*) ;;
    *) build=$BUILD_NUMBER ;;
  esac
  state_set S_SUFFIX "$suffix"
  state_set S_BUILD "$build"
  : > "$outputs"
  note "creating a distribution certificate and two App Store profiles (suffix $suffix, build ${build:-?})"
  GITHUB_OUTPUT="$outputs" python3 "$ASC" create-signing \
    --app-bundle-resource-id "$APP_BUNDLE_RESOURCE_ID" --mirror-bundle-resource-id "$MIRROR_BUNDLE_RESOURCE_ID" \
    --app-bundle-id "$APP_BUNDLE_ID" --mirror-bundle-id "$MIRROR_BUNDLE_ID" --app-group "$APP_GROUP" \
    --out "$SIGNING_DIR" --suffix "$suffix" --build "$build" || status=$?
  # Pass every id on even after a failure: the job outputs and teardown need them.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then cat "$outputs" >> "$GITHUB_OUTPUT"; fi
  gh_output profile_ids "$(state_json profile_ids)"
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
  if [ -z "$app_name" ]; then app_name="OpenCfMoto CI $suffix${build:+ b$build} app"; fi
  if [ -z "$mirror_name" ]; then mirror_name="OpenCfMoto CI $suffix${build:+ b$build} mirror"; fi
  if ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    die "No se pudo leer el Team ID del certificado." "Could not read the team id from the certificate."
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
  note "certificate and profiles '$app_name' and '$mirror_name' ready (team ID read from the certificate; not shown)"
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

  # 6. Check what Xcode will see. Only counted: an identity's name is the account holder's legal
  #    name plus the team ID, and this log is public.
  local ids count total
  if [ "${TF_ALLOW_UNTRUSTED_IDENTITY:-}" = 1 ]; then
    ids=$(security find-identity -p codesigning "$KEYCHAIN")
  else
    ids=$(security find-identity -v -p codesigning "$KEYCHAIN")
  fi
  count=$(identity_count "$ids")
  if [ "$count" -lt 1 ]; then
    total=$(identity_count "$(security find-identity -p codesigning "$KEYCHAIN" 2>&1 || true)" any)
    die "El llavero no tiene una identidad «Apple Distribution» válida (identidades de firma en el llavero, válidas o no: $total; sus nombres no se muestran porque el registro es público)." \
      "The keychain has no valid \"Apple Distribution\" identity (code-signing identities in the keychain, valid or not: $total; their names are not shown, as the log is public)."
  fi
  note "keychain ready: $KEYCHAIN ($count Apple Distribution identity; name and team not shown)"
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
  note "wrote Config/Local.xcconfig (prefix $BUNDLE_ID_PREFIX, manual signing; team ID not shown)"
  (cd "$ROOT" && xcodegen generate) || die "xcodegen generate falló." "xcodegen generate failed."
}

# ------------------------------------------------------------------ archive / export
# xcodebuild output is huge: keep it in a log, show errors and the result, annotate on failure.
run_xcodebuild() {
  local log=$1 success=$2 title=$3 status=0
  shift 3
  note "xcodebuild $*"
  xcodebuild "$@" > "$log" 2>&1 || status=$?
  grep -E "error:|warning: .*([Ss]ign|[Pp]rovision)|\*\* [A-Z ]+ (SUCCEEDED|FAILED) \*\*" "$log" | redact | head -n 200 || true
  if [ "$status" -ne 0 ] || ! grep -q "$success" "$log"; then
    tail -n 40 "$log" | redact || true
    redact < "$log" > "$log.public" || true
    python3 "$ANNOTATE" "$log.public" "$title" || true
    return 1
  fi
  return 0
}

# Plain-language hints for the signing failures an owner can fix on developer.apple.com.
signing_hints() {
  local log=$1
  if grep -q -E "Provisioning profile .*(doesn't include|doesn't match).*application-groups" "$log"; then
    annotate error "TestFlight: App Group" "El perfil no incluye el App Group ${APP_GROUP:-}: créalo y asígnalo a los DOS App IDs en developer.apple.com ▸ Identifiers; después $NEW_RUN_ES. Guía: $DOCS_URL"$'\n'"The profile lacks App Group ${APP_GROUP:-}: create it and assign it to BOTH App IDs on developer.apple.com ▸ Identifiers, then $NEW_RUN_EN. Guide: $DOCS_URL"
  fi
  if grep -q -E "Provisioning profile .*(doesn't include|doesn't match).*(HotspotConfiguration|wifi-info)" "$log"; then
    annotate error "TestFlight: capabilities" "Al App ID le falta Hotspot o Access Wi-Fi Information (¿se desactivaron a mano?). Lanza una ejecución nueva (Actions ▸ TestFlight ▸ Run workflow): el trabajo «Prepare (App Store Connect)» las vuelve a activar."$'\n'"The App ID lacks Hotspot or Access Wi-Fi Information (turned off by hand?). Start a new run (Actions ▸ TestFlight ▸ Run workflow): the «Prepare (App Store Connect)» job turns them on again."
  fi
  if grep -q -E "No profiles? for|couldn't find any .*provisioning profiles" "$log"; then
    annotate error "TestFlight: profiles" "Xcode no encontró los perfiles de CI instalados (nombre o equipo distintos). Lanza una ejecución nueva; si vuelve a pasar, pide ayuda con este mensaje (por ejemplo, en un issue del repositorio)."$'\n'"Xcode did not find the installed CI profiles (name or team mismatch). Start a new run; if it happens again, ask for help with this message (for example in an issue of the repository)."
  fi
  if grep -q "errSecInternalComponent" "$log"; then
    annotate error "TestFlight: keychain" "codesign no pudo usar la clave privada (llavero bloqueado o lista de particiones). Lanza una ejecución nueva; si vuelve a pasar, pide ayuda con este mensaje (por ejemplo, en un issue del repositorio)."$'\n'"codesign could not use the private key (locked keychain or key partition list). Start a new run; if it happens again, ask for help with this message (for example in an issue of the repository)."
  fi
  return 0
}

lint_args() { # common lint_bundle.py options
  printf '%s\n' --app-group "$APP_GROUP" --expect-build "$BUILD_NUMBER" --min-sdk-major "$MIN_SDK_MAJOR" \
    --expect-device-family "$DEVICE_FAMILY"
  if [ -n "${MARKETING_VERSION:-}" ]; then printf '%s\n' --expect-version "$MARKETING_VERSION"; fi
}

cmd_archive() {
  require_macos
  state_load
  need_env BUILD_NUMBER APP_GROUP
  unlock_keychain
  rm -rf "$ARCHIVE"
  # CURRENT_PROJECT_VERSION = the build number `asc.py next-build` chose (one more than any build
  # Apple has); --keychain keeps codesign on our keychain.
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
  python3 "$LINT" --archive "$ARCHIVE" "${lint[@]}" 2>&1 | redact || { reported; exit 1; }
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
    "manageAppVersionAndBuildNumber": False,  # keep the build number `asc.py next-build` chose
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
  python3 "$LINT" --ipa "$ipa" "${lint[@]}" 2>&1 | redact || { reported; exit 1; }
}

# The export's own log (IDEDistribution*.log) names the real reason when exportArchive fails.
distribution_log_errors() {
  local dir lines
  dir=$(grep -o -E '/[^ ]+\.xcdistributionlogs' "$WORK/export.log" | head -n 1 || true)
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then return 0; fi
  lines=$(grep -h -i -E "error|failed" "$dir"/*.log 2> /dev/null | redact | tail -n 25 || true)
  if [ -n "$lines" ]; then annotate error "TestFlight export (IDEDistribution log)" "$lines"; fi
  return 0
}

# ------------------------------------------------------------------ upload
# A step that a cancel left running must not upload anything once teardown has started.
not_after_teardown() {
  if [ -e "$WORK/teardown-started" ]; then
    die "La limpieza («Clean up») ya empezó: no se sube nada más." "Clean up has already started: nothing more is uploaded."
  fi
}

cmd_upload() {
  state_load
  need_env ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY APP_ID MARKETING_VERSION BUILD_NUMBER
  not_after_teardown
  local ipa="${S_IPA:-}" status=0
  if [ -z "$ipa" ] || [ ! -f "$ipa" ]; then die "No hay IPA (¿falló la exportación?)." "No IPA (did the export fail?)."; fi
  note "uploading $(basename "$ipa") $MARKETING_VERSION ($BUILD_NUMBER) with the Build Upload API"
  # asc.py creates $WORK/committed just before it asks Apple to commit the upload (from then on
  # Apple may have the whole file, even if this step is stopped) and deletes it again whenever
  # Apple refuses the upload: while it exists, the certificate must outlive this job.
  python3 "$ASC" upload --ipa "$ipa" --app-id "$APP_ID" --version "$MARKETING_VERSION" \
    --build "$BUILD_NUMBER" --timeout-min 30 --committed-marker "$WORK/committed" || status=$?
  case "$status" in
    0)
      touch "$WORK/uploaded"
      gh_output upload_method rest
      ;;
    3) # the API refused before the file was committed: Apple's own uploader may still work
      if [ -e "$WORK/committed" ]; then # Apple has the file already: never send it twice
        die "asc.py pidió usar altool, pero Apple ya tiene el archivo: no se sube otra vez. El trabajo «${FINISH_JOB}» espera a la build." \
          "asc.py asked for altool, but Apple already has the file: it is not uploaded again. The «${FINISH_JOB}» job waits for the build."
      fi
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
  not_after_teardown
  mkdir -p "$dir"
  key="$dir/AuthKey_${ASC_KEY_ID}.p8" # where altool looks for --apiKey
  printf '%s\n' "$key" >> "$WORK/secret-files"
  write_p8 "$key" || die "ASC_PRIVATE_KEY no parece el contenido de un archivo .p8." "ASC_PRIVATE_KEY does not look like the content of a .p8 file."
  xcrun altool --upload-app -f "$ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" > "$log" 2>&1 || status=$?
  rm -f "$key"
  redact < "$log" || true
  # altool can exit 0 although the upload failed, and print harmless "ERROR" lines when it
  # worked: go by its verdict lines (and its exit status).
  if [ "$status" -eq 0 ] && grep -q -E "UPLOAD SUCCEEDED|No errors uploading" "$log" && ! grep -q "UPLOAD FAILED" "$log"; then
    touch "$WORK/uploaded"
    gh_output uploaded true
    gh_output upload_method altool
    note "uploaded with xcrun altool"
    return 0
  fi
  errors=$(grep -E "ERROR|[Ee]rror" "$log" | redact | head -n 20 || true)
  if grep -q -E "ENTITY_ERROR\.ATTRIBUTE\.INVALID\.DUPLICATE|must be higher than the previously uploaded|ITMS-90189|ITMS-4238|Redundant Binary Upload" "$log"; then
    die "La build $BUILD_NUMBER ya existe en App Store Connect: $NEW_RUN_ES; la ejecución nueva elige el número siguiente." \
      "Build $BUILD_NUMBER already exists in App Store Connect: $NEW_RUN_EN; the new run picks the next number."
  fi
  die "xcrun altool no pudo subir la build (código $status): $errors. Corrige lo que diga y $NEW_RUN_ES." \
    "xcrun altool could not upload the build (exit $status): $errors. Fix what it says and $NEW_RUN_EN."
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
re_quote() { printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|]/\\&/g'; } # literal text as an ERE

# On cancel or timeout GitHub stops only the step's own shell: the subcommand it ran, and that
# subcommand's asc.py, xcodebuild or altool, can keep running next to this teardown. The patterns
# name this job's paths and subcommands only, so they never match the teardown itself.
stop_leftovers() {
  if ! command -v pgrep > /dev/null 2>&1 || ! command -v pkill > /dev/null 2>&1; then return 0; fi
  local asc p n waited found
  asc=$(re_quote "$ASC")
  local -a labels patterns
  labels=("build_and_sign.sh step" "asc.py" "altool upload" "xcodebuild")
  patterns=("$(re_quote "$SELF") (create-signing|setup-keychain|install-profiles|configure|archive|export|upload)( |\$)"
    "$asc (create-signing|upload)( |\$)"
    "altool --upload-app -f $(re_quote "$EXPORT_DIR")/"
    "xcodebuild .*-archivePath $(re_quote "$ARCHIVE")( |\$)")
  # 1. A create-signing still talking to Apple writes each certificate and profile it creates to
  #    state.json at once: let it finish, so the revocation below knows about them.
  waited=0
  while [ "$waited" -lt "$LEFTOVER_WAIT_SEC" ] && pgrep -f "$asc create-signing( |\$)" > /dev/null 2>&1; do
    if [ "$waited" -eq 0 ]; then note "waiting (up to ${LEFTOVER_WAIT_SEC} s) for a create-signing that is still running"; fi
    sleep 1
    waited=$((waited + 1))
  done
  # 2. Stop the rest (step scripts first, so none starts another tool) and wait until it is gone.
  n=0
  while [ "$n" -lt ${#patterns[@]} ]; do
    p=${patterns[$n]}
    if pgrep -f "$p" > /dev/null 2>&1; then
      note "stopping a leftover ${labels[$n]}: pid $(pgrep -f "$p" | tr '\n' ' ')"
      pkill -TERM -f "$p" > /dev/null 2>&1
    fi
    n=$((n + 1))
  done
  waited=0
  while :; do
    found=""
    for p in "${patterns[@]}"; do
      if pgrep -f "$p" > /dev/null 2>&1; then found=1; fi
    done
    if [ -z "$found" ]; then return 0; fi
    if [ "$waited" -eq "$KILL_WAIT_SEC" ]; then
      for p in "${patterns[@]}"; do pkill -KILL -f "$p" > /dev/null 2>&1; done
    elif [ "$waited" -gt $((KILL_WAIT_SEC + 5)) ]; then
      annotate warning "TestFlight (teardown)" "Un paso anterior sigue en marcha y no se pudo parar; GitHub lo detiene al terminar este trabajo (no hace falta hacer nada)."$'\n'"An earlier step is still running and could not be stopped; GitHub stops it when this job ends (nothing to do)."
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

cmd_teardown() {
  trap - ERR
  set +e # best effort: never stop half-way through the cleanup
  touch "$WORK/teardown-started"
  stop_leftovers
  local f line uploaded=false
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
  # Once Apple has (or may have) the file - uploaded, or committed or being committed - the
  # certificate must outlive this job: the finish job keeps it if Apple accepts the build (beta
  # review checks the signature again) and revokes it if not.
  local have_key="" suffix="" build="" status
  if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_PRIVATE_KEY:-}" ]; then have_key=1; fi
  state_load
  suffix="${S_SUFFIX:-}" # this run's profile names: «OpenCfMoto CI <suffix> b<build> app|mirror»
  build="${S_BUILD:-}"
  if [ -f "$WORK/uploaded" ] || [ -f "$WORK/committed" ]; then
    uploaded=true
    # Written before anything below talks to Apple: should GitHub stop this step half-way (its
    # time limit after a cancel), the finish job must still wait for the build before it revokes
    # the certificate, not take this job for one that lost its runner.
    gh_output uploaded true
    if [ "${GITHUB_ACTIONS:-}" != true ]; then
      note "Apple has (or may have) this build, sent from a Mac, where there is no «${FINISH_JOB}» job: the CI certificate and profiles stay, and the TestFlight workflow's janitor revokes them 12 hours after they were made; submit this build for beta review before then, or use the workflow"
    elif [ -f "$WORK/uploaded" ]; then
      note "the build was uploaded: after Apple's processing the «${FINISH_JOB}» job keeps the CI certificate and profiles if Apple accepts the build, and revokes them if not"
    else
      note "Apple has, or may have, the whole file although the upload step did not finish: the «${FINISH_JOB}» job waits for the build, then keeps or revokes the CI certificate and profiles"
    fi
    # A second certificate that an unanswered certificate request of this run made is in no
    # profile, so only this run's key (csr.pem) finds it: revoke it now (asc.py keeps the
    # recorded one and does nothing unless state.json says a request went unanswered).
    if [ -f "$SIGNING_DIR/state.json" ] && [ -n "$have_key" ]; then
      status=0
      bounded "$DUPLICATES_WAIT_SEC" python3 "$ASC" cleanup --state "$SIGNING_DIR/state.json" --duplicates-only || status=$?
      if [ "$status" -eq 142 ]; then
        annotate warning "Certificado sin confirmar / Certificate not confirmed" "Una petición de certificado de esta ejecución quedó sin respuesta clara, y App Store Connect no respondió a tiempo (${DUPLICATES_WAIT_SEC} s) para comprobar si creó un segundo certificado. Cuando termine el trabajo «${FINISH_JOB}», el certificado de esta build sigue en la cuenta si Apple la aceptó (lo usan sus perfiles «OpenCfMoto CI ${suffix:-…}${build:+ b$build} app» y «… mirror»): no lo revoques mientras esa build esté en revisión o sea la que vas a enviar. Un segundo certificado «Apple Distribution» creado hoy que no usa ningún perfil es el duplicado: revócalo en $URL_CERTS solo si sabes cuál es. Ante la duda, déjalo: no firma nada; solo ocupa uno de los pocos certificados de distribución que permite Apple hasta que caduque."$'\n'"A certificate request of this run got no clear answer, and App Store Connect did not answer in time (${DUPLICATES_WAIT_SEC} s) to check whether it made a second certificate. Once the «${FINISH_JOB}» job has finished, this build's certificate stays in the account if Apple accepted the build (its profiles «OpenCfMoto CI ${suffix:-…}${build:+ b$build} app» and «… mirror» use it): do not revoke it while that build is in review or is the one you will submit. A second «Apple Distribution» certificate created today that no profile uses is the duplicate: revoke it at $URL_CERTS only if you know which one it is. When in doubt, leave it: it signs nothing; it only uses one of the few distribution certificates Apple allows until it expires."
      fi
    fi
  elif [ -f "$SIGNING_DIR/state.json" ] && [ ! -f "$WORK/apple-cleanup-done" ]; then
    if [ -n "$have_key" ]; then
      note "the build was not uploaded: revoking the CI certificate and profiles now"
      if python3 "$ASC" cleanup --state "$SIGNING_DIR/state.json" --suffix "$suffix" --build "$build"; then touch "$WORK/apple-cleanup-done"; fi
    else
      # Only this run's profiles by name: another repository's or a Mac's run may be using its own.
      local cert_id profile_ids app mirror
      cert_id=$(state_json cert_id)
      profile_ids=$(state_json profile_ids)
      app="OpenCfMoto CI ${suffix:-…}${build:+ b$build} app"
      mirror="OpenCfMoto CI ${suffix:-…}${build:+ b$build} mirror"
      annotate warning "Revoca a mano / Revoke by hand" "Sin la clave de la API no se pudo revocar lo que creó esta ejecución. En $URL_CERTS revoca el certificado «Apple Distribution» creado hoy${cert_id:+ (id $cert_id)} (púlsalo ▸ Revoke) y en $URL_PROFILES borra los perfiles «${app}» y «${mirror}»${profile_ids:+ (ids $profile_ids)} (cada uno ▸ Remove; ningún otro «OpenCfMoto CI …»). No revoques el certificado que el workflow conserva a propósito para la última build que Apple aceptó (lo usan sus perfiles «OpenCfMoto CI … bN app» y «… bN mirror», de otra ejecución, con N el número de esa build): mientras esa build esté en revisión o sea la que vas a enviar a las pruebas externas, revocarlo hace que Apple la marque «Invalid Binary» (ITMS-90035)."$'\n'"Without the API key, what this run created could not be revoked. At $URL_CERTS revoke the «Apple Distribution» certificate created today${cert_id:+ (id $cert_id)} (click it ▸ Revoke) and at $URL_PROFILES delete the «${app}» and «${mirror}» profiles${profile_ids:+ (ids $profile_ids)} (each ▸ Remove; no other «OpenCfMoto CI …» one). Do not revoke the certificate the workflow keeps on purpose for the latest build Apple accepted (its profiles «OpenCfMoto CI … bN app» and «… bN mirror», of another run, N being that build's number, use it): while that build is in review or is the one you will send to external testing, revoking it makes Apple mark it «Invalid Binary» (ITMS-90035)."
    fi
  fi
  gh_output uploaded "$uploaded"
  gh_output teardown "done"
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
