#!/bin/sh
# Convert any video (mp4, mov, ...) to Ogg Theora, the format Godot plays.
#   tools/assets/convert_video.sh input.mp4 [output.ogv]
# Output goes to game/data/videos/ by default; use the file name in the
# "video" field of a question in game/data/questions.json.
set -e
[ -n "$1" ] || { echo "usage: $0 input [output.ogv]"; exit 1; }
here=$(dirname "$0")
out=${2:-"$here/../../game/data/videos/$(basename "${1%.*}").ogv"}
# 1280x720 max, 30 fps: smooth on the installation PC while 5 screens render
ffmpeg -y -i "$1" -vf "scale='min(1280,iw)':-2,fps=30" \
  -c:v libtheora -q:v 7 -c:a libvorbis -q:a 4 "$out"
echo "saved $out"
