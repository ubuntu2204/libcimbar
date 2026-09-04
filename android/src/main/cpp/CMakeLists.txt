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
# C is required alongside CXX: zstd and libcorrect are plain C libraries, and
# with a CXX-only project CMake cannot determine their linker language
# ("CMake can not determine linker language for target: zstd").
project(cimbar_jni CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ─── Paths ──────────────────────────────────────────────────────

# Override with -DLIBCIMBAR_SRC_PATH=/path/to/libcimbar
#
# The vendored directory was renamed upstream (libcimbar_cpp -> libcimbar),
# so accept either spelling. A stale CMakeCache.txt can also pin
# LIBCIMBAR_SRC_PATH to a directory that no longer exists, so any preset
# value is validated and falls back to probing rather than failing outright.
if(DEFINED LIBCIMBAR_SRC_PATH AND
   NOT EXISTS "${LIBCIMBAR_SRC_PATH}/src/lib/encoder/Encoder.h")
    message(WARNING
        "LIBCIMBAR_SRC_PATH does not look like a libcimbar tree: "
        "${LIBCIMBAR_SRC_PATH} — falling back to the vendored defaults.")
    # CACHE is required: a plain unset() leaves the cache entry in place.
    unset(LIBCIMBAR_SRC_PATH CACHE)
    unset(LIBCIMBAR_SRC_PATH)
endif()

if(NOT DEFINED LIBCIMBAR_SRC_PATH)
    foreach(_candidate
            "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/libcimbar"
            "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/libcimbar_cpp")
        if(EXISTS "${_candidate}/src/lib/encoder/Encoder.h")
            set(LIBCIMBAR_SRC_PATH "${_candidate}")
            break()
        endif()
    endforeach()
    unset(_candidate)
endif()

if(NOT DEFINED LIBCIMBAR_SRC_PATH OR
   NOT EXISTS "${LIBCIMBAR_SRC_PATH}/src/lib/encoder/Encoder.h")
    message(FATAL_ERROR
        "libcimbar source not found. Looked in "
        "../../../../third_party/libcimbar and .../libcimbar_cpp. "
        "Pass -DLIBCIMBAR_SRC_PATH=<path>.")
endif()

message(STATUS "libcimbar source: ${LIBCIMBAR_SRC_PATH}")

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
#
# Globbed, not hardcoded to zstd.c: upstream bundles zstd as a set of .c
# files under common/ compress/ decompress/ with no top-level zstd.c, so
# naming the single file breaks as soon as the vendored tree changes.
# ZSTD_DISABLE_ASM mirrors the desktop build — we compile the .c sources
# only (no huf_decompress_amd64.S), so zstd must not reference them.
file(GLOB_RECURSE ZSTD_SRC ${LIBCIMBAR_THIRD}/zstd/*.c)
add_library(zstd STATIC ${ZSTD_SRC})
target_include_directories(zstd PUBLIC ${LIBCIMBAR_THIRD}/zstd)
target_compile_definitions(zstd PRIVATE ZSTD_DISABLE_ASM)

# wirehair (fountain codes)
file(GLOB WIREHAIR_SRC ${LIBCIMBAR_THIRD}/wirehair/*.cpp)
add_library(wirehair STATIC ${WIREHAIR_SRC})
target_include_directories(wirehair PUBLIC ${LIBCIMBAR_THIRD}/wirehair/include)

# libcorrect (Reed-Solomon)
#
# convolutional/sse/ is an x86 fast path. Upstream only builds it when NOT
# cross-compiling AND the compiler accepts SSE intrinsics (see
# libcorrect/CMakeLists.txt — HAVE_SSE gates both -msse4.1 and adding the
# sse/ subdirectory). Android is a cross build targeting ARM, so pulling it
# in fails outright with MMX/SSE errors ("invalid conversion between vector
# type '__m64' ...", __builtin_ia32_*). The generic convolutional sources
# are self-contained, so excluding sse/ is safe.
file(GLOB_RECURSE CORRECT_SRC
    ${LIBCIMBAR_THIRD}/libcorrect/src/*.c
)
list(FILTER CORRECT_SRC EXCLUDE REGEX ".*/sse/.*")
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
    # Drop the upstream unit tests. They are in <module>/test/ and pull in
    # "unittest.h" from a path we do not add, so including them fails the
    # build with "'unittest.h' file not found".
    list(FILTER MOD_SRC EXCLUDE REGEX ".*[Tt]est.*")
    list(FILTER MOD_SRC EXCLUDE REGEX ".*/test/.*")
    list(APPEND ALL_SOURCES ${MOD_SRC})
endforeach()

# C API surface the JNI bridge links against.
#
# The JNI wrapper calls BOTH halves of the C API:
#   cimbard_*  (decoder) -> cimbar_recv_js.cpp           (no GLFW, fine here)
#   cimbare_*  (encoder) -> upstream cimbar_js.cpp       (needs GLFW, which
#                           Android has no equivalent for)
# So the encoder side comes from native/cimbar_js_headless.cpp — the same
# GLFW-free replacement the desktop build uses. Without it the link fails
# with undefined cimbare_* symbols.
list(APPEND ALL_SOURCES
    ${LIBCIMBAR_LIB}/cimbar_js/cimbar_recv_js.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../native/cimbar_js_headless.cpp
)

# ─── JNI bridge library ─────────────────────────────────────────

add_library(cimbar_jni SHARED
    ${ALL_SOURCES}
    ${CMAKE_CURRENT_SOURCE_DIR}/cimbar_jni.cpp
)

target_include_directories(cimbar_jni PRIVATE
    ${LIBCIMBAR_LIB}
    ${LIBCIMBAR_LIB}/cimbar_js
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
    # zstd's skippable-frame API (ZSTD_isSkippableFrame /
    # ZSTD_readSkippableFrame, used by compression/zstd_header_check.h) is
    # guarded behind ZSTD_STATIC_LINKING_ONLY. Without it those calls fail to
    # compile with "use of undeclared identifier". The desktop build defines
    # this too.
    ZSTD_STATIC_LINKING_ONLY
)
