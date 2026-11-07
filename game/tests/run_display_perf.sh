#!/usr/bin/env bash
# What a display node renders (a Raspberry Pi's load, measured on this PC):
# every place taken, the master renders nothing of screens 1 and 2, a display
# node shows both with the Pi settings (Compatibility renderer = OpenGL ES 3);
# the master prints what the display reports, in the lobby and in a round.
#   tests/run_display_perf.sh ["--view-scale=0.6 --detail=2.5"]
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot-4}
OUT=$PWD/tests/shots/perf
rm -rf "$OUT"; mkdir -p "$OUT"
REPLICA_FULL=1 REPLICA_SHOTS="$OUT" "$GODOT" --path . --disable-vsync res://tests/test_replica.tscn -- \
	--serve-replicas=7364 --remote-screens=1,2 > "$OUT/master.log" 2>&1 &
MASTER=$!
sleep 2
"$GODOT" --rendering-method gl_compatibility --path . --disable-vsync --max-fps 60 -- --replica --show=1,2 \
	--master=127.0.0.1:7364 --windowed --view-scale=0.75 --msaa=2 --detail=3 --detail-size=0.2 --lod=4 ${1:-} \
	> "$OUT/display.log" 2>&1 &
DISP=$!
wait $MASTER || true
sleep 1
kill $DISP 2>/dev/null || true
grep -E "TEST perf" "$OUT/master.log" || true
grep -E "SCRIPT ERROR" "$OUT/display.log" | sort | uniq -c || true
