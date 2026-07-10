// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';
import '../models/cimbar_config.dart';
import '../models/decode_result.dart';

/// Abstract interface for cimbar decoding.
///
/// Implementations may use FFI (Windows/desktop), MethodChannel (Android),
/// or JS interop (Web/WASM).
abstract class ICimbarDecoder {
  /// Whether the underlying native library is loaded and ready.
  bool get isReady;

  /// Apply decoding configuration. Must match the encoder's config.
  Future<void> configure(CimbarConfig config);

  /// Feed a single image frame into the fountain decoder.
  ///
  /// [imageData] is raw pixel data in the specified [format].
  /// [width] and [height] are the image dimensions.
  ///
  /// Returns a [DecodeResult] indicating progress or completion.
  Future<DecodeResult> decodeFrame(
    Uint8List imageData, {
    required int width,
    required int height,
    CimbarImageFormat format = CimbarImageFormat.rgb,
  });

  /// Recover the fully decoded file data after [decodeFrame] reports
  /// [DecodeResult.isComplete] == true.
  ///
  /// [fileId] is the identifier from [DecodeResult.fileId].
  Future<Uint8List?> recoverFile(int fileId);

  /// Recover the original filename embedded in the cimbar stream.
  Future<String> recoverFilename(int fileId);

  /// Current decoding progress (0.0 – 1.0).
  double get progress;

  /// Whether a complete file has been decoded and is ready to retrieve.
  bool get isComplete;

  /// Release native resources.
  Future<void> dispose();
}
