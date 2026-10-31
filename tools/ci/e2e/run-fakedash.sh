#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# One end-to-end run: tools/fakedash/fakedash.py on 127.0.0.1 ↔ the REAL app in the booted simulator
# (`-e2eFakeDash`, App/Sources/Services/E2EFakeDash.swift). The Simulator shares the Mac's network
# stack, so the app's probe to 127.0.0.1:10930 reaches the fake dash, which calls back to the app's
# listeners on 127.0.0.1:10922/10921/10920 and pulls H.264 at 20 fps.
#
# usage: run-fakedash.sh <udid> <bundle id> <scenario> <dash model> <seconds> <out dir> [extra app args…]
# Writes <out>/e2e-<scenario>/: fakedash.log, summary.json, transcript.jsonl, dash.h264 (removed by
# the report step), app_*.png screenshots, app-log.txt / app-status.json (the app's Documents
# dumps), app-stdout.log, frames/dash_NN.png (decoded from what the fake dash received),
# frames/app_first.png (decoded from the app-side wire dump) and result.env.

UDID=$1
BUNDLE=$2
SCENARIO=$3
DASH=$4
SECONDS_STREAM=$5
OUT=$6
shift 6
D="$OUT/e2e-$SCENARIO"
rm -rf "$D"
mkdir -p "$D/frames"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)

xcrun simctl terminate "$UDID" "$BUNDLE" > /dev/null 2>&1 || true
sleep 1

DECODE=()
if command -v ffprobe > /dev/null && command -v ffmpeg > /dev/null; then DECODE=(--decode); fi

t0=$(date +%s)
python3 "$ROOT/tools/fakedash/fakedash.py" --bind 127.0.0.1 --scenario "$SCENARIO" --dash "$DASH" \
  --seconds "$SECONDS_STREAM" --probe-wait 90 --max-runtime $((SECONDS_STREAM + 160)) \
  --out-h264 "$D/dash.h264" --transcript "$D/transcript.jsonl" --summary-json "$D/summary.json" \
  ${DECODE[@]+"${DECODE[@]}"} > "$D/fakedash.log" 2>&1 &
FAKEDASH=$!
sleep 1.5
if ! kill -0 "$FAKEDASH" 2>/dev/null; then
  echo "::error title=e2e $SCENARIO::fakedash exited right away"
  tail -n 30 "$D/fakedash.log"
fi

launch=$(xcrun simctl launch --terminate-running-process --stdout="$D/app-stdout.log" --stderr="$D/app-stderr.log" \
         "$UDID" "$BUNDLE" -e2eFakeDash -e2eDash "$DASH" "$@" 2>&1)
launch_rc=$?
echo "launch: $launch (rc $launch_rc)"
APP_PID=${launch##*: }

# Screenshots while streaming (the session starts ~3 s after launch).
sleep 15
xcrun simctl io "$UDID" screenshot --type=png "$D/app_streaming_1.png" > /dev/null 2>&1
sleep 15
xcrun simctl io "$UDID" screenshot --type=png "$D/app_streaming_2.png" > /dev/null 2>&1

# Wait for the fake dash (one complete session, or its own timeouts).
limit=$((SECONDS_STREAM + 200))
while kill -0 "$FAKEDASH" 2>/dev/null; do
  if [ $(( $(date +%s) - t0 )) -gt $limit ]; then
    echo "::warning title=e2e $SCENARIO::fakedash still running after ${limit}s — interrupting it"
    kill -INT "$FAKEDASH" 2>/dev/null
    sleep 5
    kill -9 "$FAKEDASH" 2>/dev/null
    break
  fi
  sleep 2
done
wait "$FAKEDASH" 2>/dev/null
dash_rc=$?
t1=$(date +%s)
sleep 3
xcrun simctl io "$UDID" screenshot --type=png "$D/app_after.png" > /dev/null 2>&1
if kill -0 "$APP_PID" 2>/dev/null; then app_alive=yes; else app_alive=no; fi

# The app's evidence files (Documents of its data container).
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null)
if [ -n "$DATA" ] && [ -d "$DATA/Documents" ]; then
  cp "$DATA/Documents/e2e-log.txt" "$D/app-log.txt" 2>/dev/null
  cp "$DATA/Documents/e2e-status.json" "$D/app-status.json" 2>/dev/null
  cp "$DATA/Documents/e2e-app.h264" "$D/app.h264" 2>/dev/null
else
  echo "::warning title=e2e $SCENARIO::no app data container ($DATA)"
fi
xcrun simctl terminate "$UDID" "$BUNDLE" > /dev/null 2>&1 || true

# Decode sample frames of what the fake dash received (every 60th frame ≈ every 3 s at 20 fps).
frames=0
if command -v ffmpeg > /dev/null && [ -s "$D/dash.h264" ]; then
  ffmpeg -hide_banner -loglevel error -f h264 -i "$D/dash.h264" -vf "select=not(mod(n\,60))" -fps_mode vfr \
    -frames:v 24 "$D/frames/dash_%02d.png" > "$D/frames/ffmpeg.log" 2>&1
  frames=$(ls "$D"/frames/dash_*.png 2>/dev/null | wc -l | tr -d ' ')
  ffprobe -v error -f h264 -count_frames -select_streams v:0 \
    -show_entries stream=codec_name,profile,level,width,height,pix_fmt,nb_read_frames -of json "$D/dash.h264" \
    > "$D/frames/ffprobe-dash.json" 2> "$D/frames/ffprobe-dash.err"
fi
if command -v ffmpeg > /dev/null && [ -s "$D/app.h264" ]; then
  ffmpeg -hide_banner -loglevel error -f h264 -i "$D/app.h264" -frames:v 1 "$D/frames/app_first.png" > /dev/null 2>&1
  ffprobe -v error -f h264 -count_frames -select_streams v:0 \
    -show_entries stream=codec_name,profile,level,width,height,nb_read_frames -of json "$D/app.h264" \
    > "$D/frames/ffprobe-app.json" 2> "$D/frames/ffprobe-app.err"
fi
for f in "$D"/*.png; do [ -f "$f" ] && sips -Z 1400 "$f" > /dev/null 2>&1; done

cat > "$D/result.env" <<EOF
scenario=$SCENARIO
dash=$DASH
seconds=$SECONDS_STREAM
fakedash_rc=$dash_rc
launch_rc=$launch_rc
app_alive_after=$app_alive
duration_s=$((t1 - t0))
decoded_pngs=$frames
EOF
cat "$D/result.env"
tail -n 45 "$D/fakedash.log"
exit 0
