// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

// Conditional import — resolved at compile time:
//   Web    → browser download (JS interop)
//   Native → path_provider file write
import 'file_saver_native.dart'
    if (dart.library.js_interop) '../web/file_saver_web.dart' as impl;

/// Save a file recovered by the cimbar decoder.
///
/// - **Web**: triggers a browser download of [filename].
/// - **Android / desktop**: writes the bytes into the app documents
///   directory (e.g. Documents on Android).
///
/// Returns a human-readable description of where the data went: the
/// saved file path on native platforms, or the downloaded filename on web.
///
/// ```dart
/// if (result.isComplete && result.data != null) {
///   final path = await saveRecoveredFile(result.data!, result.filename);
/// }
/// ```
Future<String> saveRecoveredFile(Uint8List data, String filename) =>
    impl.saveFile(data, filename);
