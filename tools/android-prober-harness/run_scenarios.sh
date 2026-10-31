#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Runs the ORIGINAL Android EasyConnProber (JVM harness) against tools/fakedash/fakedash.py on the real
# PXC ports (10920-10922 + 10930 on 127.0.0.1), one scenario at a time.
#   ./copy_upstream.sh && gradle installDist && ./run_scenarios.sh [scenario...]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TOOLS=$HERE/..
OUT=${OUT:-$HERE/out}; mkdir -p "$OUT"
LOCK=${LOCK:-${TMPDIR:-/tmp}/pxc-ports.lock}
DASH=$TOOLS/fakedash/fakedash.py
RUN=$HERE/build/install/kotlin-prober-runner/bin/kotlin-prober-runner
CLIPS=$TOOLS/fakedash/clips
run_one() { # name secs "dash args" "runner args"
  local name=$1 secs=$2 dargs=$3 rargs=$4 P=$OUT/kotlin-$1
  echo "=== kotlin $name"
  flock -w 1800 "$LOCK" bash -c "
    timeout 150 python3 $DASH --bind 127.0.0.1 $dargs --transcript $P.jsonl --summary-json $P.dash.json \
       --max-runtime 120 --probe-wait 40 > $P.dash.log 2>&1 &
    D=\$!; sleep 1
    timeout $((secs + 40)) $RUN --seconds $secs --gateway 127.0.0.1 --bind 127.0.0.1 --clips $CLIPS $rargs > $P.runner.log 2>&1
    echo runner exit=\$?; wait \$D; echo dash exit=\$?"
}
for s in ${*:-cfdl16 cfdl26 mt800 reconnect stall touch}; do
  case $s in
    cfdl16)    run_one cfdl16 20 "--scenario cfdl16 --seconds 15 --decode" "" ;;
    cfdl26)    run_one cfdl26 20 "--scenario cfdl26 --seconds 15 --decode" "" ;;
    mt800)     run_one mt800 20 "--scenario mt800 --seconds 15 --decode" "" ;;
    reconnect) run_one reconnect 32 "--scenario reconnect --seconds 5 --cycles 2 --decode" "" ;;
    stall)     run_one stall 40 "--scenario stall --decode" "" ;;
    touch)     run_one touch 20 "--scenario touch --seconds 10 --touch-fuzz --decode" "--touch-out $OUT/kotlin-touch.touches.jsonl" ;;
  esac
done
