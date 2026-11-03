#!/usr/bin/env bash
# Display nodes end to end: a master and a display node (--replica) on this PC,
# the display shows screens 2, 4 and 6 (an invite, a free place, a drone). At
# each moment the display checks its replicated state against the master's and
# both save their screens; tests/compare_shots.gd compares them. Needs a desktop.
#   tests/run_replica_test.sh            (godot-4 on the PATH, or GODOT=...)
#   PROXY="--loss 10 --jitter 50 --blackout 18:9" REPLICA_TAIL=10 tests/run_replica_test.sh
#        (through tests/udp_proxy.py: a bad network, a 9 s blackout; "after": back in step)
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot-4}
OUT=${REPLICA_SHOTS:-$PWD/tests/shots/replica}
rm -rf "$OUT"; mkdir -p "$OUT"
export REPLICA_SHOTS="$OUT"
PORT=7361
"$GODOT" --path . --disable-vsync --max-fps 60 res://tests/test_replica.tscn -- --serve-replicas=$PORT ${MASTER_ARGS:-} > "$OUT/master.log" 2>&1 &
MASTER=$!
TO=$PORT
if [ -n "${PROXY:-}" ]; then
	TO=7371
	python3 tests/udp_proxy.py --listen $TO --to 127.0.0.1:$PORT $PROXY > "$OUT/proxy.log" 2>&1 &
	PROXY_PID=$!
fi
sleep 2
"$GODOT" --path . --disable-vsync --max-fps 60 -- --replica --show=2,4,6 --master=127.0.0.1:$TO --windowed \
	--view-scale=1 --detail=0 --lod=1 --node=test-display ${DISPLAY_ARGS:-} --shots="$OUT" > "$OUT/display.log" 2>&1 &
DISPLAY_PID=$!
wait $MASTER || true
sleep 2
kill $DISPLAY_PID 2>/dev/null || true
[ -n "${PROXY_PID:-}" ] && kill $PROXY_PID 2>/dev/null || true
grep -E "TEST|replica:" "$OUT/master.log" || true
grep -E "replica:|SCRIPT ERROR" "$OUT/display.log" || true
"$GODOT" --headless --path . -s tests/compare_shots.gd -- "$OUT" 2>&1 | grep -E "OK|FAIL|MISSING|pairs"
