// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// libcimbar_plugin.cpp - Flutter Windows plugin registration.
//
// This file is required by Flutter's build system for any plugin that
// declares a windows platform in pubspec.yaml. The pluginClass
// LibcimbarPluginCApi must export a registration function.
//
// Since libcimbar uses dart:ffi (not platform channels), the
// registration is a no-op. The actual native library (libcimbar.dll)
// is loaded at runtime via DynamicLibrary.open() in the Dart FFI code.

#include "include/libcimbar/libcimbar_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace {

// Minimal plugin class for registration purposes.
// No method channels are used - all communication happens via FFI.
class LibcimbarPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar) {
    auto plugin = std::make_unique<LibcimbarPlugin>();
    registrar->AddPlugin(std::move(plugin));
  }

  LibcimbarPlugin() = default;
  virtual ~LibcimbarPlugin() = default;

  // Disable copy/move
  LibcimbarPlugin(const LibcimbarPlugin&) = delete;
  LibcimbarPlugin& operator=(const LibcimbarPlugin&) = delete;
};

}  // namespace

// Entry point that Flutter calls to register the plugin.
// Function name must be: {pluginClass}RegisterWithRegistrar
void LibcimbarPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  LibcimbarPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
