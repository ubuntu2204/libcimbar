cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "libcimbar")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "libcimbar_plugin")

add_library(${PLUGIN_NAME} SHARED
  "libcimbar_plugin.cpp"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Prebuilt native DLL shipped inside the package (windows/libcimbar.dll).
#
# It statically links OpenCV and the MinGW runtimes, so on the target machine
# it only needs kernel32/msvcrt - no separate OpenCV DLL to distribute.
# This used to point at native/build_windows/Release/... (a local build output
# that is not part of the package) plus a hardcoded opencv_world490.dll from
# somebody else's machine; both are gone.
set(LIBCIMBAR_NATIVE_DLL "${CMAKE_CURRENT_SOURCE_DIR}/libcimbar.dll")

# Bundled libraries: Flutter copies these next to the runner .exe.
set(BUNDLED_LIBS "$<TARGET_FILE:${PLUGIN_NAME}>")
if(EXISTS "${LIBCIMBAR_NATIVE_DLL}")
  list(APPEND BUNDLED_LIBS "${LIBCIMBAR_NATIVE_DLL}")
endif()

set(libcimbar_bundled_libraries
  ${BUNDLED_LIBS}
  PARENT_SCOPE
)
