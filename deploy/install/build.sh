#!/usr/bin/env bash
# Build a release on the development PC (x86-64): everything the machines need,
# packed as dist/cybercircle-<date>.tar.gz (install with install_server.sh /
# install_game.sh from the unpacked folder, or update.sh <tarball>).
#   deploy/install/build.sh [--test] [--apk] [--no-export]
#   --test       run the automatic tests first (Godot, control server, app)
#   --apk        also the Android app (needs a JDK 17 and the Android SDK)
#   --no-export  no exported game (the machines run the project with Godot)
# Steps: Godot import -> gamemaster web app (served at /gm/) -> [APK] ->
# exported game for x86_64 and arm64 (Raspberry Pi; needs Godot's export
# templates: Editor > Manage Export Templates) -> the tarball.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GODOT=${GODOT:-$(command -v godot-4 || command -v godot)}
TEST=0; APK=0; EXPORT=1
for a in "$@"; do
    case "$a" in --test) TEST=1 ;; --apk) APK=1 ;; --no-export) EXPORT=0 ;; *) echo "unknown: $a"; exit 1 ;; esac
done
say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
cd "$ROOT"

say "Godot import ($("$GODOT" --version))"
"$GODOT" --headless --path godot --import >/dev/null 2>&1 || true

if [ $TEST = 1 ]; then
    say "tests"
    for t in test_flow test_db test_piet test_settings test_recovery test_control_queue; do
        out=$("$GODOT" --headless --path godot --fixed-fps 60 "res://tests/$t.tscn" 2>&1 | grep -E "^DONE" || true)
        echo "  $t: ${out:-no result}"
        grep -q "0 failure" <<<"$out" || { echo "FAILED: $t"; exit 1; }
    done
    control/.venv/bin/python control/test_e2e.py | tail -1
    (cd gamemaster_app && flutter test | tail -1)
fi

say "gamemaster app: web (served by the control server at /gm/)"
(cd gamemaster_app && flutter build web --release --base-href /gm/ --no-web-resources-cdn | tail -1)
if [ $APK = 1 ]; then
    say "gamemaster app: Android"
    (cd gamemaster_app && flutter build apk --release | tail -1)
    mkdir -p dist && cp gamemaster_app/build/app/outputs/flutter-apk/app-release.apk dist/cybercircle-gamemaster.apk
fi

if [ $EXPORT = 1 ]; then
    say "the game: exported builds (x86_64, arm64)"
    mkdir -p dist/game
    for preset in "Linux x86_64:cybercircle.x86_64" "Linux arm64:cybercircle.arm64"; do
        name=${preset%%:*}; file=${preset##*:}
        if "$GODOT" --headless --path godot --export-release "$name" "../dist/game/$file" >/tmp/cc_export.log 2>&1 \
            && [ -f "dist/game/$file" ]; then
            echo "  $name: dist/game/$file"
        else
            echo "  $name: not exported (export templates installed? see /tmp/cc_export.log) - the machines run the project instead"
            rm -f "dist/game/$file" "dist/game/${file%.*}.pck"
        fi
    done
fi

say "release tarball"
stamp=$(date +%F)
stage=$(mktemp -d)
rsync -a --exclude-from="$ROOT/deploy/install/rsync-exclude.txt" --exclude=control/cert.pem --exclude=control/key.pem \
    "$ROOT/" "$stage/digital_twin/"
tar czf "dist/cybercircle-$stamp.tar.gz" -C "$stage" digital_twin
rm -rf "$stage"
ls -lh "dist/cybercircle-$stamp.tar.gz"
