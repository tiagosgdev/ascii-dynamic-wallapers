#!/bin/zsh
# Records each wallpaper's base animation into saver-media/<scene>.mp4.
# Re-run after changing how a scene looks, then run build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

FADE=3   # seconds of cross-fade that hides the loop point
BIN="$(mktemp -d /tmp/ascii-capture.XXXXXX)/capture"
swiftc -O -o "$BIN" tools/capture.swift
mkdir -p saver-media

# scene, loop seconds, query, setup js, per-frame js
record() {
  local scene=$1 secs=$2 query=$3 setup=$4 frame=$5
  local total=$((secs + FADE))
  "$BIN" "file://$PWD/web/$scene.html$query" $((total * 30)) "$setup" "$frame" | \
    ffmpeg -v error -y -framerate 30 -f image2pipe -c:v png -i - \
      -filter_complex "[0:v]split[a][b];[a]trim=start=${FADE}:end=${total},setpts=PTS-STARTPTS[a1];[b]trim=start=0:end=${FADE},setpts=PTS-STARTPTS[b1];[a1][b1]xfade=transition=fade:duration=${FADE}:offset=$((secs - FADE)),format=yuv420p[v]" \
      -map "[v]" -c:v hevc_videotoolbox -b:v 14M -tag:v hvc1 -movflags +faststart -an \
      "saver-media/$scene.mp4"
  echo "done: $scene"
}

# The camera period matches the clip so the loop's camera position lines up.
record blackhole 40 "?orbitPeriod=40" "1" 'ascii.frame($T)'
record pond 60 "" "ascii.warp(8)" '(ascii.warp(1/30),ascii.frame())'
