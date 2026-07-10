#!/bin/bash
# ===================================================================
# build_wasm.sh — Compile libcimbar to WebAssembly using Emscripten
#
# Prerequisites:
#   - Emscripten SDK (emsdk) installed and activated
#     https://emscripten.org/docs/getting_started/downloads.html
#   - OpenCV.js or OpenCV compiled for Emscripten (optional)
#   - CMake 3.22+
#
# Usage:
#   emsdk install latest && emsdk activate latest
#   source emsdk_env.sh
#   ./build_wasm.sh [path-to-libcimbar-source]
#
# Output:
#   build_wasm/libcimbar.js    — JS glue code
#   build_wasm/libcimbar.wasm  — WASM binary
#
# Deploy:
#   Copy both files to your Flutter Web app's web/assets/wasm/ directory.
# ===================================================================

set -e

echo ""
echo "============================================================"
echo " libcimbar WASM Build Script (Emscripten)"
echo "============================================================"
echo ""

# Verify Emscripten is active
if ! command -v emcc &> /dev/null; then
    echo "ERROR: emcc not found. Please activate Emscripten SDK first:"
    echo "  source /path/to/emsdk/emsdk_env.sh"
    exit 1
fi
echo "[1/4] Emscripten: $(emcc --version | head -1)"

# Source path
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBCIMBAR_SRC="${1:-${SCRIPT_DIR}/../../C:/project/libcimbar/libcimbar}"
if [ ! -f "$LIBCIMBAR_SRC/src/lib/encoder/Encoder.h" ]; then
    echo "ERROR: Cannot find libcimbar source at $LIBCIMBAR_SRC"
    exit 1
fi
echo "[2/4] Source: $LIBCIMBAR_SRC"

# Build directory
BUILD_DIR="${SCRIPT_DIR}/build_wasm"
mkdir -p "$BUILD_DIR"
echo "[3/4] Build dir: $BUILD_DIR"

# ── Configure with Emscripten CMake ──
echo "[4/4] Configuring and building..."
echo ""

emcmake cmake "$LIBCIMBAR_SRC" \
    -B "$BUILD_DIR" \
    -DUSE_WASM=1 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS="-O2 -s USE_WEBGL2=1 -s FULL_ES3=1"

cd "$BUILD_DIR"
emmake make -j$(nproc 2>/dev/null || echo 4) cimb_js 2>/dev/null || \
emmake make -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4) cimb_js 2>/dev/null || \
emmake make cimb_js

echo ""
echo "============================================================"
echo " BUILD SUCCESSFUL"
echo "============================================================"
echo ""

# Find output files
JS_FILE=$(find "$BUILD_DIR" -name "cimbar_js.js" -o -name "libcimbar.js" | head -1)
WASM_FILE=$(find "$BUILD_DIR" -name "cimbar_js.wasm" -o -name "libcimbar.wasm" | head -1)

if [ -n "$JS_FILE" ]; then
    echo "JS:   $JS_FILE"
    # Rename to standard names
    cp "$JS_FILE" "$BUILD_DIR/libcimbar.js" 2>/dev/null || true
fi
if [ -n "$WASM_FILE" ]; then
    echo "WASM: $WASM_FILE"
    cp "$WASM_FILE" "$BUILD_DIR/libcimbar.wasm" 2>/dev/null || true
fi

echo ""
echo "Deploy to Flutter Web:"
echo "  mkdir -p your_flutter_app/web/assets/wasm/"
echo "  cp $BUILD_DIR/libcimbar.js  your_flutter_app/web/assets/wasm/"
echo "  cp $BUILD_DIR/libcimbar.wasm your_flutter_app/web/assets/wasm/"
echo ""
echo "Then add to web/index.html before </body>:"
echo '  <script src="assets/wasm/libcimbar.js"></script>'
echo ""
