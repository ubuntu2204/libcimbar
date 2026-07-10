// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';
import '../models/cimbar_config.dart';
import '../models/cimbar_frame.dart';

/// Abstract interface for cimbar encoding.
///
/// Implementations may use FFI (Windows/desktop), MethodChannel (Android),
/// or JS interop (Web/WASM).
abstract class ICimbarEncoder {
  /// Whether the underlying native library is loaded and ready.
  bool get isReady;

  /// Apply encoding configuration. Must be called before [encodeData].
  Future<void> configure(CimbarConfig config);

  /// Encode [data] into a sequence of cimbar barcode frames.
  ///
  /// [filename] is embedded in the cimbar stream header so the receiver
  /// can reconstruct the original file with its name.
  ///
  /// Returns the list of generated [CimbarFrame]s (raw RGB pixel data).
  Future<List<CimbarFrame>> encodeData(
    Uint8List data, {
    String filename = 'data.bin',
  });

  /// Encode a file from disk path into cimbar frames.
  Future<List<CimbarFrame>> encodeFile(String filePath);

  /// Release native resources.
  Future<void> dispose();
}
