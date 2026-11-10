#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Screenshot every app screen in the booted simulator with the demo services + demo content
# (`-demo -demoSeed -uiScreen <name>`, App/Sources/Services/AppLaunchOptions.swift).
#
# usage: screenshots.sh <udid> <bundle id> <out dir>
# Writes <out>/screens/<name>.png (long side scaled to 1400 px) and <out>/screens/status.tsv
# (name, launch result, whether the app was still running when the screenshot was taken).

UDID=$1
BUNDLE=$2
OUT=$3
DIR="$OUT/screens"
mkdir -p "$DIR/logs"
STATUS="$DIR/status.tsv"
printf "screen\tlaunch\talive\tseconds\n" > "$STATUS"

# shoot <name> <wait seconds> <app arguments…>
shoot() {
  local name=$1 wait=$2
  shift 2
  local t0 out pid alive
  t0=$(date +%s)
  out=$(xcrun simctl launch --terminate-running-process --stdout="$DIR/logs/$name.out" --stderr="$DIR/logs/$name.err" \
        "$UDID" "$BUNDLE" "$@" 2>&1)
  if [ $? -ne 0 ]; then
    echo "::warning title=screenshot $name::launch failed: $out"
    printf "%s\tlaunch-failed\tno\t0\n" "$name" >> "$STATUS"
    return 0
  fi
  pid=${out##*: }
  sleep "$wait"
  if kill -0 "$pid" 2>/dev/null; then alive=yes; else alive=no; fi
  xcrun simctl io "$UDID" screenshot --type=png "$DIR/$name.png" > /dev/null 2>&1 \
    || echo "::warning title=screenshot $name::simctl io screenshot failed"
  [ "$alive" = yes ] || echo "::warning title=screenshot $name::the app was not running any more after ${wait}s (crash?) — see screens/logs/$name.err"
  printf "%s\tok\t%s\t%s\n" "$name" "$alive" "$(( $(date +%s) - t0 ))" >> "$STATUS"
}

DEMO=(-demo -demoSeed)
# Warm-up launch (first launch after install is slow), not kept.
shoot _warmup 8 "${DEMO[@]}"
rm -f "$DIR/_warmup.png"

shoot home 5 "${DEMO[@]}"
shoot dash 9 "${DEMO[@]}" -uiScreen dash
# Apple Music on the dash: the Dash view with the Music sheet open (fake Music app of -demoSeed).
# The sheet closes itself after 10 s without dash input while the bike moves (contract §3.7; the
# demo GPS rides), so -uiDashSheet taps it open again every 3 s; no map tiles show under it.
shoot dash_music 7 "${DEMO[@]}" -uiScreen dash -uiDashSheet music
shoot navigate 9 "${DEMO[@]}" -uiScreen navigate
for s in trips settings controls logs garage about mirror onboarding scan ride; do
  shoot "$s" 5 "${DEMO[@]}" -uiScreen "$s"
done
# An opened GPX track shown as a preview over a running route (UI/UX P0, UX-17).
shoot gpx_preview 9 "${DEMO[@]}" -uiScreen gpx
shoot es_gpx_preview 9 "${DEMO[@]}" -uiScreen gpx -AppleLanguages "(es)" -AppleLocale es_ES
# Settings scrolled to "Apple Music on the dash" (the -demoSeed fake Music app: on, access allowed).
shoot settings_music 5 "${DEMO[@]}" -uiScreen settings -uiSettingsAnchor music
shoot dash_landscape_raw 9 "${DEMO[@]}" -uiScreen dash -uiOrientation landscape
shoot es_home 5 "${DEMO[@]}" -AppleLanguages "(es)" -AppleLocale es_ES
shoot es_settings 5 "${DEMO[@]}" -uiScreen settings -AppleLanguages "(es)" -AppleLocale es_ES
shoot es_settings_music 5 "${DEMO[@]}" -uiScreen settings -uiSettingsAnchor music -AppleLanguages "(es)" -AppleLocale es_ES
shoot es_dash 9 "${DEMO[@]}" -uiScreen dash -AppleLanguages "(es)" -AppleLocale es_ES
shoot es_dash_music 7 "${DEMO[@]}" -uiScreen dash -uiDashSheet music -AppleLanguages "(es)" -AppleLocale es_ES
xcrun simctl terminate "$UDID" "$BUNDLE" > /dev/null 2>&1 || true

# The Simulator framebuffer stays portrait: the landscape-right interface is drawn rotated 90°
# clockwise, so rotate the shot back by 270°.
if [ -f "$DIR/dash_landscape_raw.png" ]; then
  mv "$DIR/dash_landscape_raw.png" "$DIR/dash_landscape.png" && sips -r 270 "$DIR/dash_landscape.png" > /dev/null
fi

# Keep the artifact branch small: long side 1400 px.
for f in "$DIR"/*.png; do
  [ -f "$f" ] && sips -Z 1400 "$f" > /dev/null 2>&1
done
# Launch logs: keep only the tails.
for f in "$DIR"/logs/*; do
  [ -f "$f" ] || continue
  tail -n 80 "$f" > "$f.tail" && mv "$f.tail" "$f"
  [ -s "$f" ] || rm -f "$f"
done
cat "$STATUS"
