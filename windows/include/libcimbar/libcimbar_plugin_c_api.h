// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// libcimbar_plugin_c_api.h - Public header for the libcimbar Windows plugin.
//
// This header declares the C API registration function that Flutter's
// Windows embedder calls during plugin initialization.
//
// The actual libcimbar functionality is accessed via dart:ffi, not
// platform channels. This registration exists solely to satisfy
// Flutter's plugin discovery mechanism.

#ifndef FLUTTER_PLUGIN_LIBCIMBAR_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_LIBCIMBAR_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

// Register the libcimbar plugin with the Flutter engine.
// Called automatically by Flutter's generated_plugins.cmake during
// application startup. This is a no-op for FFI-based plugins.
FLUTTER_PLUGIN_EXPORT void LibcimbarPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_LIBCIMBAR_PLUGIN_C_API_H_
