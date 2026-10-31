#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Runs the Swift EasyConnLink (tools/linkrunner) against tools/fakedash/fakedash.py on the REAL PXC
# ports, one scenario per acquisition of the shared port lock.
#   usage: run_swift_scenarios.sh [scenario...]     (default: cfdl16 cfdl26 mt800 reconnect stall touch)
set -u
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}
HERE=$(cd "$(dirname "$0")" && pwd)
LOCK=${LOCK:-${TMPDIR:-/tmp}/pxc-ports.lock}
OUT=${OUT:-$HERE/out}; mkdir -p "$OUT"
REPO=$HERE/../..
DASH=$REPO/tools/fakedash/fakedash.py
RUNNER=$REPO/tools/linkrunner/.build/debug/linkrunner
[ -n "${SWIFTENV:-}" ] && . "$SWIFTENV"   # optional toolchain env (Linux sandbox)
export TMPDIR=${TMPDIR:-$OUT/tmp}
mkdir -p "$TMPDIR"

run_one() {  # name runner-seconds "dash args" "runner args"
  local name=$1 secs=$2 dargs=$3 rargs=$4
  local P=$OUT/swift-$name
  rm -f $P.jsonl $P.dash.json $P.dash.log $P.h264 $P.runner.log $P.runner.json $P.events.jsonl
  echo "=== $name: fakedash $dargs | linkrunner --seconds $secs $rargs"
  flock -w 1800 $LOCK bash -c "
    timeout 150 python3 $DASH --bind 127.0.0.1 $dargs --transcript $P.jsonl --summary-json $P.dash.json \
        --out-h264 $P.h264 --max-runtime 120 --probe-wait 40 > $P.dash.log 2>&1 &
    D=\$!
    sleep 1
    timeout $((secs + 30)) $RUNNER --dash 127.0.0.1 --seconds $secs $rargs \
        --summary-json $P.runner.json --events-jsonl $P.events.jsonl > $P.runner.log 2>&1
    echo \"runner exit=\$?\" > $P.exit.txt
    wait \$D; echo \"dash exit=\$?\" >> $P.exit.txt

    true"
  cat $P.exit.txt
  python3 - "$P.dash.json" "$name" <<'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception as e:
    print("  no dash summary: %s" % e); sys.exit(0)
v = [i for i in s.get("findings", []) if i.get("severity") in ("violation", "warning")]
sess = "; ".join("s%d %s frames=%d" % (x.get("cycle", 0), x.get("end_reason"), x.get("frames", 0)) for x in s.get("sessions", []))
dec = s.get("decode") or {}
print("  %-10s %s violations=%s warnings=%s  %s  decode=%s %sx%s" % (sys.argv[2], s.get("result"), s.get("violations"),
      s.get("warnings"), sess, dec.get("decodable"), dec.get("width"), dec.get("height")))
for i in v:
    print("    %s [%s] %s" % (i["severity"], i["rule"], i["message"][:220]))
PY
  grep -E 'SUM  ' $P.runner.log | sed 's/^/  /'
}

SCEN=${*:-cfdl16 cfdl26 mt800 reconnect stall touch}
for s in $SCEN; do
  case $s in
    cfdl16)    run_one cfdl16    20 "--scenario cfdl16 --seconds 15 --decode" "" ;;
    cfdl26)    run_one cfdl26    20 "--scenario cfdl26 --seconds 15 --decode" "" ;;
    mt800)     run_one mt800     20 "--scenario mt800 --seconds 15 --decode" "" ;;
    reconnect) run_one reconnect 32 "--scenario reconnect --seconds 5 --cycles 2 --decode" "" ;;
    stall)     run_one stall     40 "--scenario stall --decode" "" ;;
    touch)     run_one touch     20 "--scenario touch --seconds 10 --touch-fuzz --decode" "" ;;
    *) echo "unknown scenario $s" ;;
  esac
done
