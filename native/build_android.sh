#!/bin/bash
# ===================================================================
# build_android.sh — Cross-compile libcimbar for Android
#
# Prerequisites:
#   - Android NDK r25+ (set ANDROID_NDK_HOME)
#   - OpenCV Android SDK (set OPENCV_ANDROID_SDK)
#   - CMake 3.22+ / Ninja
#
# Usage:
#   ./build_android.sh [path-to-libcimbar-source]
#
# Environment:
#   ABIS="arm64-v8a armeabi-v7a"   # default: both
#   ANDROID_STL=c++_static         # default: static STL (see below)
#
# Output:
#   build_android/<abi>/libcimbar_jni.so
#
# Why ANDROID_STL=c++_static:
#   These .so files are shipped as PREBUILT binaries in
#   android/src/main/jniLibs/<abi>/ so that consumers of the package need
#   neither the NDK nor the OpenCV SDK. Nothing in that setup bundles
#   libc++_shared.so, so a .so linked against the shared STL fails to dlopen
#   at runtime ("library libc++_shared.so not found") and the decoder reports
#   "not ready". Statically linking the STL makes each .so self-contained.
# ===================================================================

set -e

echo ""
echo "============================================================"
echo " libcimbar Android Build Script"
echo "============================================================"
echo ""

# Source path
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBCIMBAR_SRC="${1:-$SCRIPT_DIR/../third_party/libcimbar}"
if [ ! -f "$LIBCIMBAR_SRC/src/lib/encoder/Encoder.h" ]; then
    # The vendored directory used to be called libcimbar_cpp.
    if [ -f "$SCRIPT_DIR/../third_party/libcimbar_cpp/src/lib/encoder/Encoder.h" ]; then
        LIBCIMBAR_SRC="$SCRIPT_DIR/../third_party/libcimbar_cpp"
    else
        echo "ERROR: Cannot find libcimbar source at $LIBCIMBAR_SRC"
        echo "Usage: $0 [path-to-libcimbar-source]"
        exit 1
    fi
fi
echo "[1/5] Source: $LIBCIMBAR_SRC"

# Android NDK
if [ -z "$ANDROID_NDK_HOME" ]; then
    for dir in \
        "$HOME/Android/Sdk/ndk"/*  \
        "$HOME/Library/Android/sdk/ndk"/* \
        "/opt/android-ndk" \
        ; do
        if [ -d "$dir" ]; then
            ANDROID_NDK_HOME="$dir"
            break
        fi
    done
fi
if [ -z "$ANDROID_NDK_HOME" ]; then
    echo "ERROR: ANDROID_NDK_HOME not set and NDK not found."
    echo "Install Android NDK and set ANDROID_NDK_HOME."
    exit 1
fi
echo "[2/5] NDK: $ANDROID_NDK_HOME"

# OpenCV Android SDK
if [ -z "$OPENCV_ANDROID_SDK" ]; then
    echo "WARNING: OPENCV_ANDROID_SDK not set."
    echo "Download from: https://opencv.org/releases/"
    echo "Set OPENCV_ANDROID_SDK to the SDK root directory."
    exit 1
fi
echo "[3/5] OpenCV Android SDK: $OPENCV_ANDROID_SDK"

ABIS="${ABIS:-arm64-v8a armeabi-v7a}"
ANDROID_STL="${ANDROID_STL:-c++_static}"

BUILD_DIR="$SCRIPT_DIR/build_android"
mkdir -p "$BUILD_DIR"
echo "[4/5] Build dir: $BUILD_DIR"
echo "      ABIs: $ABIS"
echo "      STL:  $ANDROID_STL"

echo ""
for ABI in $ABIS; do
    echo "---- Building $ABI ----"
    cmake "$SCRIPT_DIR/../android/src/main/cpp" \
        -G "Ninja" \
        -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM=android-24 \
        -DANDROID_STL="$ANDROID_STL" \
        -DLIBCIMBAR_SRC_PATH="$LIBCIMBAR_SRC" \
        -DOPENCV_ANDROID_SDK_PATH="$OPENCV_ANDROID_SDK" \
        -DCMAKE_BUILD_TYPE=Release \
        -B "$BUILD_DIR/$ABI"

    cmake --build "$BUILD_DIR/$ABI" --parallel
done

echo ""
echo "============================================================"
echo " BUILD SUCCESSFUL"
echo "============================================================"
for ABI in $ABIS; do
    echo ""
    SO="$BUILD_DIR/$ABI/libcimbar_jni.so"
    echo "Output: $SO"
    if command -v readelf >/dev/null 2>&1 && [ -f "$SO" ]; then
        echo "NEEDED dependencies:"
        readelf -d "$SO" | grep NEEDED || true
    fi
done
echo ""
echo "Next: copy each .so into android/src/main/jniLibs/<abi>/"
echo "      (the Flutter build merges them into the APK; no NDK needed)."
echo ""
