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
#
# The vendored directory was renamed upstream (libcimbar_cpp -> libcimbar),
# so probe both spellings instead of hardcoding one — a hardcoded name means
# a rename silently leaves you shipping a stale binary.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -n "$1" ]; then
    LIBCIMBAR_SRC="$1"
else
    LIBCIMBAR_SRC=""
    for _candidate in \
        "${SCRIPT_DIR}/../third_party/libcimbar" \
        "${SCRIPT_DIR}/../third_party/libcimbar_cpp"; do
        if [ -f "$_candidate/src/lib/encoder/Encoder.h" ]; then
            LIBCIMBAR_SRC="$_candidate"
            break
        fi
    done
fi
if [ ! -f "$LIBCIMBAR_SRC/src/lib/encoder/Encoder.h" ]; then
    echo "ERROR: Cannot find libcimbar source. Looked in"
    echo "  ../third_party/libcimbar and ../third_party/libcimbar_cpp"
    echo "Usage: $0 [path-to-libcimbar-source]"
    exit 1
fi
echo "[2/4] Source: $LIBCIMBAR_SRC"

# OpenCV for WASM
OPENCV_DIR="${OPENCV_DIR:-/home/ubuntu/project/opencv}"
if [ ! -d "$OPENCV_DIR/opencv-build-wasm/build_wasm/lib" ]; then
    echo ""
    echo "  OpenCV WASM not found. Building from source..."
    echo "  (This takes ~5-10 minutes on first run)"
    echo ""

    if [ ! -d "$OPENCV_DIR/.git" ]; then
        echo "ERROR: OpenCV not found at $OPENCV_DIR"
        echo "  Set OPENCV_DIR or clone: git clone --depth 1 --branch 4.11.0 https://github.com/opencv/opencv.git $OPENCV_DIR"
        exit 1
    fi

    echo "  Building OpenCV for WASM..."
    rm -rf "$OPENCV_DIR/opencv-build-wasm"
    mkdir -p "$OPENCV_DIR/opencv-build-wasm"
    cd "$OPENCV_DIR/opencv-build-wasm"
    python3 "$OPENCV_DIR/platforms/js/build_js.py" build_wasm \
        --emscripten_dir="$EMSDK/upstream/emscripten" \
        --build_wasm \
        --cmake_option="-DCMAKE_CXX_FLAGS=-std=c++17" \
        --cmake_option="-DCMAKE_C_FLAGS=-std=c17"
    echo "  OpenCV WASM build complete."
    cd "$SCRIPT_DIR"
fi
echo "  OpenCV: $OPENCV_DIR"

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
    -DOPENCV_DIR="$OPENCV_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS="-O2 -s USE_WEBGL2=1 -s FULL_ES3=1"

cd "$BUILD_DIR"
emmake make -j$(nproc 2>/dev/null || echo 4) cimbar_js 2>/dev/null || \
emmake make -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4) cimbar_js 2>/dev/null || \
emmake make cimbar_js

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
    cp "$JS_FILE" "$BUILD_DIR/libcimbar.js" 2>/dev/null || true
fi
if [ -n "$WASM_FILE" ]; then
    echo "WASM: $WASM_FILE"
    # Keep original name (Emscripten JS glue hardcodes cimbar_js.wasm)
    cp "$WASM_FILE" "$BUILD_DIR/cimbar_js.wasm" 2>/dev/null || true
    cp "$WASM_FILE" "$BUILD_DIR/libcimbar.wasm" 2>/dev/null || true
fi

# Auto-deploy to example app
DEPLOY_DIR="${SCRIPT_DIR}/../example/web/assets/wasm"
mkdir -p "$DEPLOY_DIR"
cp "$BUILD_DIR/libcimbar.js" "$DEPLOY_DIR/libcimbar.js" 2>/dev/null || true
cp "$BUILD_DIR/cimbar_js.wasm" "$DEPLOY_DIR/cimbar_js.wasm" 2>/dev/null || true
echo ""
echo "Deployed to: $DEPLOY_DIR"
echo "  libcimbar.js  — JS glue"
echo "  cimbar_js.wasm — WASM binary (name required by JS glue)"
