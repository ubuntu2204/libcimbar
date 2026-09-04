#!/usr/bin/env bash
# ===================================================================
# run.sh — headless regression test for the cimbar WASM decoder
#
#   1. compiles dump_frames (links against the desktop libcimbar)
#   2. encodes a payload and dumps lossless RGB frames
#   3. runs the WASM decoder over them in Node
#
# This is the test that isolates "the WASM build is broken" from "the web
# capture chain is broken" — the distinction that found the auto-crop
# upscale bug (smooth interpolation -> ~5% of original sharpness ->
# scan_extract_decode -3, i.e. anchors not found).
#
# Requirements: node, g++ (or clang++), native/build_linux/libcimbar.so
#
# Usage:
#   ./run.sh                 # standard: native frames
#   ./run.sh --scale 2       # also verify at 2x size (nearest-neighbour)
#   ./run.sh --frames DIR    # reuse existing frames
#   ./run.sh --verbose
# ===================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

FRAMES="${TMPDIR:-/tmp}/libcimbar_wasm_frames"
EXTRA=()
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--frames" ]]; then
    j=$((i + 1))
    FRAMES="${!j}"
  fi
done

# ─── Locate the desktop library (needed to *make* the test frames) ──
SO="$ROOT/native/build_linux/libcimbar.so"
if [[ ! -f "$SO" ]]; then
  echo "ERROR: $SO not found."
  echo "Build it first:  cmake --build native/build_linux --config Release"
  exit 2
fi

command -v node >/dev/null 2>&1 || { echo "ERROR: node not found"; exit 2; }
CXX="${CXX:-g++}"
command -v "$CXX" >/dev/null 2>&1 || { echo "ERROR: $CXX not found"; exit 2; }

BUILD_DIR="$HERE/.build"
mkdir -p "$BUILD_DIR"

echo "[1/3] Building dump_frames..."
"$CXX" -O2 -std=c++17 "$HERE/dump_frames.cpp" \
  -L"$(dirname "$SO")" -Wl,-rpath,"$(dirname "$SO")" -lcimbar \
  -o "$BUILD_DIR/dump_frames"

echo "[2/3] Generating frames -> $FRAMES"
mkdir -p "$FRAMES"
rm -f "$FRAMES"/*.rgb
"$BUILD_DIR/dump_frames" "$FRAMES" 15

echo "[3/3] Running WASM decoder test..."
node "$HERE/wasm_decode_test.js" --frames "$FRAMES" "$@"
