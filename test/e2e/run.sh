#!/usr/bin/env bash
# ===================================================================
# run.sh — headless END-TO-END regression test for decode_example web
#
#   1. compiles dump_frames (reuses test/wasm's binary if present)
#   2. encodes a payload and dumps lossless RGB frames
#   3. composites them into a cimbar Y4M video (make_y4m.py)
#   4. builds decode_example for web and serves build/web locally
#   5. runs headless_e2e.py: Chrome fake camera plays the video into
#      the app (?autostart=1) and the console is watched for a
#      completed file
#
# Where test/wasm/ proves "the WASM decoder works on lossless input",
# this test proves "the whole WEB APP decodes what its own camera
# pipeline delivers" — the layer where the callAsFunction arg-spreading
# and dart2js BigInt bugs lived.
#
# Requirements: python3 (+ playwright: `pip install playwright &&
#   playwright install chromium`), flutter, g++, and
#   native/build_linux/libcimbar.so (only for frame generation)
#
# Usage:
#   ./run.sh                  # full run (builds the web app first)
#   ./run.sh --skip-build     # reuse decode_example/build/web as-is
#   ./run.sh --seconds 60     # longer budget for slow machines
#   ./run.sh --verbose        # dump every console line
# ===================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PORT="${PORT:-8903}"
SECONDS_BUDGET=45
SKIP_BUILD=0
VERBOSE=()
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in
    --skip-build) SKIP_BUILD=1 ;;
    --seconds) j=$((i + 1)); SECONDS_BUDGET="${!j}" ;;
    --verbose) VERBOSE=(--verbose) ;;
  esac
done

FRAMES="${TMPDIR:-/tmp}/libcimbar_wasm_frames"
Y4M="${TMPDIR:-/tmp}/libcimbar_e2e_feed.y4m"
SO="$ROOT/native/build_linux/libcimbar.so"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found"; exit 2; }
python3 -c "import playwright" 2>/dev/null || {
  echo "ERROR: python playwright not installed."
  echo "  pip install playwright && playwright install chromium"
  exit 2
}

# ─── [1/4] Frames ──────────────────────────────────────────────────
DUMP="$ROOT/test/wasm/.build/dump_frames"
if [[ ! -x "$DUMP" ]]; then
  [[ -f "$SO" ]] || { echo "ERROR: $SO not found (build native first)"; exit 2; }
  CXX="${CXX:-g++}"
  echo "[1/4] Building dump_frames..."
  mkdir -p "$ROOT/test/wasm/.build"
  "$CXX" -O2 -std=c++17 "$ROOT/test/wasm/dump_frames.cpp" \
    -L"$(dirname "$SO")" -Wl,-rpath,"$(dirname "$SO")" -lcimbar \
    -o "$DUMP"
fi
if [[ ! -f "$FRAMES/frame_000.rgb" ]]; then
  echo "[1/4] Generating frames -> $FRAMES"
  mkdir -p "$FRAMES"
  "$DUMP" "$FRAMES" 15
else
  echo "[1/4] Reusing frames in $FRAMES"
fi

# ─── [2/4] Y4M video ───────────────────────────────────────────────
echo "[2/4] Generating Y4M -> $Y4M"
python3 "$HERE/make_y4m.py" --frames "$FRAMES" --out "$Y4M"

# ─── [3/4] Web app build + local server ────────────────────────────
cd "$ROOT/decode_example"
if [[ "$SKIP_BUILD" == 0 || ! -d build/web ]]; then
  echo "[3/4] flutter build web..."
  flutter build web --release >/dev/null
else
  echo "[3/4] Reusing build/web (--skip-build)"
fi
(pkill -f "http.server $PORT" 2>/dev/null || true)
sleep 0.3
python3 -m http.server "$PORT" --bind 127.0.0.1 \
  --directory build/web >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 1

# ─── [4/4] Headless run ────────────────────────────────────────────
echo "[4/4] Running headless E2E (budget ${SECONDS_BUDGET}s)..."
python3 "$HERE/headless_e2e.py" \
  --url "http://127.0.0.1:$PORT/?autostart=1" \
  --y4m "$Y4M" --seconds "$SECONDS_BUDGET" "${VERBOSE[@]}"
