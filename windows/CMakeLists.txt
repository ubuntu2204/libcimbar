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

# Pre-built native DLLs compiled separately via native/build_windows.bat
set(LIBCIMBAR_NATIVE_DLL "${CMAKE_CURRENT_SOURCE_DIR}/../native/build_windows/Release/libcimbar.dll")
set(OPENCV_DLL "C:/project/paddle_ocr/windows/third_party/opencv/lib/opencv_world490.dll")

# Bundled libraries: Flutter copies these to the runner output automatically
set(BUNDLED_LIBS "$<TARGET_FILE:${PLUGIN_NAME}>")
if(EXISTS "${LIBCIMBAR_NATIVE_DLL}")
  list(APPEND BUNDLED_LIBS "${LIBCIMBAR_NATIVE_DLL}")
endif()
if(EXISTS "${OPENCV_DLL}")
  list(APPEND BUNDLED_LIBS "${OPENCV_DLL}")
endif()

set(libcimbar_bundled_libraries
  ${BUNDLED_LIBS}
  PARENT_SCOPE
)
