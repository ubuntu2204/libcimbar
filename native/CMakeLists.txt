# CMakeLists.txt — Build libcimbar as a shared library for desktop FFI usage.
#
# This CMake script compiles the libcimbar C++ core into a single shared
# library (libcimbar.dll / libcimbar.so / libcimbar.dylib) that can be
# loaded by the Dart FFI bindings.
#
# ## Prerequisites (Windows)
#
# 1. Visual Studio 2022 (or Build Tools) with C++ workload
# 2. CMake 3.22+
# 3. OpenCV 4.5+ — download from https://opencv.org/releases/
#    Set OPENCV_DIR environment variable to the OpenCV build directory.
# 4. vcpkg (recommended for GLFW and OpenGL):
#    vcpkg install glfw3:x64-windows
#
# ## Build (Windows)
#
#   cd native
#   mkdir build && cd build
#   cmake .. -G "Visual Studio 17 2022" -A x64 ^
#       -DOPENCV_DIR="C:/opencv/build" ^
#       -DCMAKE_TOOLCHAIN_FILE="C:/vcpkg/scripts/buildsystems/vcpkg.cmake"
#   cmake --build . --config Release
#
# The output library will be in build/Release/libcimbar.dll
#
# ## Build (Linux)
#
#   sudo apt install libopencv-dev libglfw3-dev
#   cd native && mkdir build && cd build
#   cmake .. && make -j$(nproc)
#
# ## Installation
#
# After building, copy the shared library to the Flutter app's platform
# directory:
#   Windows: example/windows/libcimbar.dll (next to the .exe)
#   Linux:   example/linux/libcimbar.so

cmake_minimum_required(VERSION 3.22)
project(libcimbar_shared CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ─── Configuration ────────────────────────────────────────────────

# Path to the libcimbar source tree.
if(NOT DEFINED LIBCIMBAR_SRC)
    # Default: sibling directory
    set(LIBCIMBAR_SRC "C:/project/libcimbar/libcimbar")
endif()

if(NOT EXISTS "${LIBCIMBAR_SRC}/src/lib/encoder/Encoder.h")
    message(FATAL_ERROR "libcimbar source not found at: ${LIBCIMBAR_SRC}")
endif()

message(STATUS "libcimbar source: ${LIBCIMBAR_SRC}")

set(LIB_DIR "${LIBCIMBAR_SRC}/src/lib")
set(THIRD_DIR "${LIBCIMBAR_SRC}/src/third_party_lib")

# ─── Dependencies ─────────────────────────────────────────────────

# OpenCV — supports two layouts:
#   1. Standard install with OpenCVConfig.cmake (find_package)
#   2. Manual layout: <OPENCV_DIR>/include + <OPENCV_DIR>/lib/opencv_world*.lib
if(DEFINED OPENCV_DIR AND EXISTS "${OPENCV_DIR}/include/opencv2/core.hpp")
    # Manual layout (e.g. paddle_ocr bundled OpenCV)
    message(STATUS "OpenCV: manual layout at ${OPENCV_DIR}")
    set(OpenCV_INCLUDE_DIRS "${OPENCV_DIR}/include")

    # Find the opencv_world library (release)
    file(GLOB OPENCV_LIBS "${OPENCV_DIR}/lib/opencv_world[0-9]*.lib")
    # Filter out debug libs
    set(OpenCV_LIBS "")
    foreach(_lib ${OPENCV_LIBS})
        if(NOT _lib MATCHES "d\\.lib$")
            list(APPEND OpenCV_LIBS "${_lib}")
        endif()
    endforeach()
    if(NOT OpenCV_LIBS)
        # Fall back to any available lib
        list(APPEND OpenCV_LIBS ${OPENCV_LIBS})
    endif()
    message(STATUS "OpenCV libs: ${OpenCV_LIBS}")
else()
    # Standard install
    if(DEFINED OPENCV_DIR)
        set(OpenCV_DIR "${OPENCV_DIR}")
    endif()
    find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs)
    message(STATUS "OpenCV: ${OpenCV_VERSION} at ${OpenCV_INCLUDE_DIRS}")
endif()

# GLFW (optional — only needed for animated window display)
find_package(glfw3 QUIET)
if(glfw3_FOUND)
    message(STATUS "GLFW: found")
    set(HAS_GLFW ON)
else()
    message(STATUS "GLFW: not found (headless encoding only)")
    set(HAS_GLFW OFF)
endif()

# ─── Third-party static libraries ────────────────────────────────

# zstd
file(GLOB_RECURSE ZSTD_SRC ${THIRD_DIR}/zstd/*.c)
add_library(zstd_static STATIC ${ZSTD_SRC})
target_include_directories(zstd_static PUBLIC ${THIRD_DIR}/zstd)
set_target_properties(zstd_static PROPERTIES OUTPUT_NAME "zstd")

# wirehair (fountain codes)
file(GLOB WIREHAIR_SRC ${THIRD_DIR}/wirehair/*.cpp)
add_library(wirehair_static STATIC ${WIREHAIR_SRC})
target_include_directories(wirehair_static PUBLIC
    ${THIRD_DIR}/wirehair/include
    ${THIRD_DIR}/wirehair
)

# libcorrect (Reed-Solomon error correction)
file(GLOB_RECURSE CORRECT_SRC ${THIRD_DIR}/libcorrect/src/*.c)
add_library(correct_static STATIC ${CORRECT_SRC})
target_include_directories(correct_static PUBLIC
    ${THIRD_DIR}/libcorrect/include
)

# ─── libcimbar core modules ──────────────────────────────────────

set(CIMBAR_MODULES
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
# Note: gui module excluded (requires OpenGL/GLFW, not needed for headless encoding)

set(ALL_CIMBAR_SOURCES "")
foreach(MOD ${CIMBAR_MODULES})
    file(GLOB_RECURSE MOD_SRC
        "${LIB_DIR}/${MOD}/*.cpp"
        "${LIB_DIR}/${MOD}/*.c"
    )
    # Exclude test files
    list(FILTER MOD_SRC EXCLUDE REGEX ".*[Tt]est.*")
    list(FILTER MOD_SRC EXCLUDE REGEX ".*/test/.*")
    list(APPEND ALL_CIMBAR_SOURCES ${MOD_SRC})
endforeach()

# C API sources: headless encoder wrapper + decoder
list(APPEND ALL_CIMBAR_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/cimbar_js_headless.cpp"
    "${LIB_DIR}/cimbar_js/cimbar_recv_js.cpp"
)

# ─── Shared library target ───────────────────────────────────────

# MSVC requires /utf-8 for libcimbar source files (fmt library + non-ASCII)
if(MSVC)
    add_compile_options(/utf-8 /permissive-)
endif()

add_library(cimbar SHARED ${ALL_CIMBAR_SOURCES})

target_include_directories(cimbar PRIVATE
    ${LIB_DIR}
    ${LIB_DIR}/cimbar_js
    ${THIRD_DIR}
    ${THIRD_DIR}/zstd
    ${THIRD_DIR}/wirehair/include
    ${THIRD_DIR}/libcorrect/include
    ${THIRD_DIR}/cxxopts/include
    ${THIRD_DIR}/intx/include
    ${THIRD_DIR}/base91
    ${THIRD_DIR}/libpopcnt
    ${OpenCV_INCLUDE_DIRS}
)

target_link_libraries(cimbar PRIVATE
    zstd_static
    wirehair_static
    correct_static
    ${OpenCV_LIBS}
)

if(HAS_GLFW)
    target_link_libraries(cimbar PRIVATE glfw)
    target_compile_definitions(cimbar PRIVATE HAS_GLFW=1)
else()
    target_compile_definitions(cimbar PRIVATE HAS_GLFW=0)
endif()

target_compile_definitions(cimbar PRIVATE
    BUILD_SHARED=1
    CIMBAR_EXPORT=1
    ZSTD_STATIC_LINKING_ONLY
)

# Export symbols on Windows
if(WIN32)
    target_compile_definitions(cimbar PRIVATE CIMBAR_DLL_EXPORT)
    set_target_properties(cimbar PROPERTIES
        WINDOWS_EXPORT_ALL_SYMBOLS ON
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/$<CONFIG>"
    )
endif()

# Set output name
set_target_properties(cimbar PROPERTIES
    OUTPUT_NAME "libcimbar"
    PREFIX ""
)

# ─── Install ──────────────────────────────────────────────────────

install(TARGETS cimbar
    RUNTIME DESTINATION bin    # .dll
    LIBRARY DESTINATION lib    # .so / .dylib
    ARCHIVE DESTINATION lib    # .lib (import library)
)

message(STATUS "")
message(STATUS "=== libcimbar shared library build ===")
message(STATUS "  Source:    ${LIBCIMBAR_SRC}")
message(STATUS "  OpenCV:    ${OpenCV_VERSION}")
message(STATUS "  GLFW:      ${HAS_GLFW}")
message(STATUS "  Output:    ${CMAKE_BINARY_DIR}")
message(STATUS "")
