#!/usr/bin/env bash
# ===================================================================
# decode_video.sh — decode-test a REAL recorded video through the
# WASM decoder, without any browser.
#
# Extracts frames from a video (e.g. a phone recording of the encoder
# screen) with ffmpeg and feeds them to wasm_decode_test.js — the same
# cimbard_* calls the web app makes, run in Node. Much faster than the
# browser E2E (test/e2e/): seconds instead of a minute.
#
# Usage:
#   ./decode_video.sh                      # default fixture video
#   ./decode_video.sh /path/to/clip.mp4    # any video
#   ./decode_video.sh clip.mp4 --every 3 --verbose
#
# Options:
#   --every N   sample every Nth frame (default 5)
#   anything else is passed through to wasm_decode_test.js
#
# Exit code: 0 = decoded, 1 = not decoded, 2 = setup problem.
# ===================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

VIDEO="$ROOT/test/74c1430d5f0fbd3e8376f7bfbfb2bdb2.mp4"
EVERY=5
PASSTHRU=()
VIDEO_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --every) EVERY="$2"; shift 2 ;;
    *) if [[ "$VIDEO_SET" == 0 && -f "$1" ]]; then
         VIDEO="$1"; VIDEO_SET=1
       else
         PASSTHRU+=("$1")
       fi
       shift ;;
  esac
done

command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: ffmpeg not found"; exit 2; }
command -v ffprobe >/dev/null 2>&1 || { echo "ERROR: ffprobe not found"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "ERROR: node not found"; exit 2; }
[[ -f "$VIDEO" ]] || { echo "ERROR: video not found: $VIDEO"; exit 2; }

DIMS=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height -of csv=p=0 "$VIDEO")
W="${DIMS%,*}"; H="${DIMS#*,}"
echo "video: $VIDEO (${W}x${H}, sampling every $EVERY frames)"

TMPD="$(mktemp -d /tmp/libcimbar_video_frames.XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

ffmpeg -v error -i "$VIDEO" -vf "select='not(mod(n\,$EVERY))'" -vsync 0 \
  -f image2 -c:v rawvideo -pix_fmt rgb24 "$TMPD/frame_%03d.rgb"
echo "extracted $(ls "$TMPD" | wc -l) frames"

node "$HERE/wasm_decode_test.js" --frames "$TMPD" \
  --width "$W" --height "$H" "${PASSTHRU[@]}"
