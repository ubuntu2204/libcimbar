#!/bin/bash
# ===================================================================
# build_android.sh — Cross-compile libcimbar for Android (arm64-v8a)
#
# Prerequisites:
#   - Android NDK r25+ (set ANDROID_NDK_HOME)
#   - OpenCV Android SDK (set OPENCV_ANDROID_SDK)
#   - CMake 3.22+
#
# Usage:
#   ./build_android.sh [path-to-libcimbar-source]
#
# Output:
#   build_android/arm64-v8a/libcimbar_jni.so
# ===================================================================

set -e

echo ""
echo "============================================================"
echo " libcimbar Android Build Script"
echo "============================================================"
echo ""

# Source path
LIBCIMBAR_SRC="${1:-$(pwd)/../C:/project/libcimbar/libcimbar}"
if [ ! -f "$LIBCIMBAR_SRC/src/lib/encoder/Encoder.h" ]; then
    echo "ERROR: Cannot find libcimbar source at $LIBCIMBAR_SRC"
    echo "Usage: $0 [path-to-libcimbar-source]"
    exit 1
fi
echo "[1/4] Source: $LIBCIMBAR_SRC"

# Android NDK
if [ -z "$ANDROID_NDK_HOME" ]; then
    # Try common locations
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
echo "[2/4] NDK: $ANDROID_NDK_HOME"

# OpenCV Android SDK
if [ -z "$OPENCV_ANDROID_SDK" ]; then
    echo "WARNING: OPENCV_ANDROID_SDK not set."
    echo "Download from: https://opencv.org/releases/"
    echo "Set OPENCV_ANDROID_SDK to the SDK root directory."
    exit 1
fi
echo "[3/4] OpenCV Android SDK: $OPENCV_ANDROID_SDK"

# Build
BUILD_DIR="$(dirname "$0")/build_android"
mkdir -p "$BUILD_DIR"
echo "[4/4] Build dir: $BUILD_DIR"

echo ""
echo "Building for arm64-v8a..."

cmake "$SCRIPT_DIR/../android/src/main/cpp" \
    -G "Ninja" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DANDROID_STL=c++_shared \
    -DLIBCIMBAR_SRC_PATH="$LIBCIMBAR_SRC" \
    -DOPENCV_ANDROID_SDK_PATH="$OPENCV_ANDROID_SDK" \
    -DCMAKE_BUILD_TYPE=Release \
    -B "$BUILD_DIR/arm64-v8a"

cmake --build "$BUILD_DIR/arm64-v8a" --parallel

echo ""
echo "============================================================"
echo " BUILD SUCCESSFUL"
echo "============================================================"
echo ""
echo "Output: $BUILD_DIR/arm64-v8a/libcimbar_jni.so"
echo ""
echo "This library will be automatically included when building"
echo "the Flutter Android app via the plugin's CMakeLists.txt."
echo ""
