// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Web plugin registration for libcimbar.
///
/// Registered automatically by Flutter's web plugin registrant
/// (see pubspec.yaml → flutter.plugin.platforms.web).
class LibcimbarWeb {
  /// Called by the Flutter web plugin system during app initialization.
  static void registerWith(Registrar registrar) {
    // No MethodChannel handlers needed — web uses JS interop directly
    // via the WASM module loaded in index.html.
  }
}
