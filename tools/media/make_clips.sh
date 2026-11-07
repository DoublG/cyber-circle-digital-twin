#!/usr/bin/env bash
# Gameplay clips (game/movie/clips.gd): every clip as one movie of the whole
# installation (out/movies/gameplay/<clip>.mp4) and every screen on its own
# (out/movies/gameplay/<clip>/<screen>.mp4, full HD, the same moments).
#   tools/media/make_clips.sh                 all clips
#   tools/media/make_clips.sh joining full    only these
set -e
cd "$(dirname "$0")/../../game"
OUT=../out/movies/gameplay
TMP=$(realpath -m ../out/render/clips_tmp)   # (outside the project: no import; in the home folder: the Godot snap can write it)
clips=${*:-setup joining few full mobile leaving}
mkdir -p "$OUT" "$TMP"; touch "$TMP/.gdignore"
for c in $clips; do
    echo "== $c"
    rm -rf "$TMP/$c"; mkdir -p "$TMP/$c"
    godot-4 --path . --resolution 1920x1080 --fixed-fps 30 --disable-vsync \
        --write-movie "$TMP/$c/all.avi" res://movie/clips.tscn -- --clip=$c --split="$TMP/$c" \
        2>&1 | grep -E "\[clip\]|SCRIPT ERROR" || true
    ffmpeg -y -loglevel error -i "$TMP/$c/all.avi" -c:v libx264 -crf 28 -preset slow \
        -pix_fmt yuv420p -c:a aac -b:a 96k "$OUT/$c.mp4"
    mkdir -p "$OUT/$c"
    for d in "$TMP/$c"/*/; do
        s=$(basename "$d")
        ffmpeg -y -loglevel error -framerate 30 -i "$d/%05d.jpg" -c:v libx264 -crf 28 -preset slow \
            -pix_fmt yuv420p "$OUT/$c/$s.mp4"
    done
    rm -rf "$TMP/$c"
    echo "$c: $(du -sh "$OUT/$c.mp4" "$OUT/$c" | cut -f1 | paste -sd' ')"
done
