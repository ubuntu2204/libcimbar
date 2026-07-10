# CMake build for the Android JNI bridge library.
#
# This compiles the libcimbar C++ core + a thin JNI wrapper into a
# single shared library (libcimbar_jni.so) for Android.
#
# Prerequisites:
#   - Android NDK (r25+) with CMake 3.22.1
#   - OpenCV Android SDK (set OPENCV_ANDROID_SDK_PATH)
#   - libcimbar source at ../../../../libcimbar (relative to this file)
#     or set LIBCIMBAR_SRC_PATH

cmake_minimum_required(VERSION 3.22)
project(cimbar_jni CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ─── Paths ──────────────────────────────────────────────────────

# Override with -DLIBCIMBAR_SRC_PATH=/path/to/libcimbar
if(NOT DEFINED LIBCIMBAR_SRC_PATH)
    # Default: assume libcimbar is alongside the flutter project
    set(LIBCIMBAR_SRC_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../libcimbar/libcimbar")
endif()

set(LIBCIMBAR_LIB "${LIBCIMBAR_SRC_PATH}/src/lib")
set(LIBCIMBAR_THIRD "${LIBCIMBAR_SRC_PATH}/src/third_party_lib")

# ─── OpenCV ─────────────────────────────────────────────────────

if(DEFINED OPENCV_ANDROID_SDK_PATH)
    include(${OPENCV_ANDROID_SDK_PATH}/sdk/native/jni/abi-${ANDROID_ABI}/OpenCVConfig.cmake)
else()
    find_package(OpenCV REQUIRED)
endif()

# ─── Third-party static libraries ───────────────────────────────

# zstd
add_library(zstd STATIC
    ${LIBCIMBAR_THIRD}/zstd/zstd.c
)
target_include_directories(zstd PUBLIC ${LIBCIMBAR_THIRD}/zstd)

# wirehair (fountain codes)
file(GLOB WIREHAIR_SRC ${LIBCIMBAR_THIRD}/wirehair/*.cpp)
add_library(wirehair STATIC ${WIREHAIR_SRC})
target_include_directories(wirehair PUBLIC ${LIBCIMBAR_THIRD}/wirehair/include)

# libcorrect (Reed-Solomon)
file(GLOB_RECURSE CORRECT_SRC
    ${LIBCIMBAR_THIRD}/libcorrect/src/*.c
)
add_library(correct STATIC ${CORRECT_SRC})
target_include_directories(correct PUBLIC ${LIBCIMBAR_THIRD}/libcorrect/include)

# ─── libcimbar core modules ─────────────────────────────────────

set(LIBCIMBAR_MODULES
    bit_file
    cimb_translator
    compression
    encoder
    extractor
    fountain
    image_hash
    serialize
    util
)

set(ALL_SOURCES "")
foreach(MOD ${LIBCIMBAR_MODULES})
    file(GLOB_RECURSE MOD_SRC
        ${LIBCIMBAR_LIB}/${MOD}/*.cpp
        ${LIBCIMBAR_LIB}/${MOD}/*.c
    )
    list(APPEND ALL_SOURCES ${MOD_SRC})
endforeach()

# ─── JNI bridge library ─────────────────────────────────────────

add_library(cimbar_jni SHARED
    ${ALL_SOURCES}
    ${CMAKE_CURRENT_SOURCE_DIR}/cimbar_jni.cpp
)

target_include_directories(cimbar_jni PRIVATE
    ${LIBCIMBAR_LIB}
    ${LIBCIMBAR_THIRD}
    ${LIBCIMBAR_THIRD}/zstd
    ${LIBCIMBAR_THIRD}/wirehair/include
    ${LIBCIMBAR_THIRD}/libcorrect/include
    ${LIBCIMBAR_THIRD}/cxxopts/include
    ${LIBCIMBAR_THIRD}/intx/include
    ${OpenCV_INCLUDE_DIRS}
)

target_link_libraries(cimbar_jni
    zstd
    wirehair
    correct
    ${OpenCV_LIBS}
    android
    log
    jnigraphics
)

target_compile_definitions(cimbar_jni PRIVATE
    USE_WASM=0
    BUILD_JNI=1
)
