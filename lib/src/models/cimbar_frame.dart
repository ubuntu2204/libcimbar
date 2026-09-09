// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

/// A single cimbar barcode frame (image).
class CimbarFrame {
  /// Sequential frame index (0-based).
  final int index;

  /// Raw RGB pixel data (row-major, no alpha).
  final Uint8List pixels;

  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// Total number of frames in the sequence (if known).
  final int? totalFrames;

  /// Creates a frame holding a private snapshot of [pixels].
  ///
  /// The copy is deliberate: encoders hand us a buffer that the native/wasm
  /// side keeps reusing for the next frame (see
  /// `CimbarEncoderFfi.encodeData`, which reads straight out of the encoder's
  /// frame buffer), so aliasing it would make every frame show the last one.
  CimbarFrame({
    required this.index,
    required Uint8List pixels,
    required this.width,
    required this.height,
    this.totalFrames,
  }) : pixels = Uint8List.fromList(pixels);

  /// Number of bytes per row (stride = width * 3 for RGB).
  int get stride => width * 3;

  /// Total pixel data size in bytes.
  int get byteLength => pixels.length;

  @override
  String toString() =>
      'CimbarFrame(index: $index, ${width}x$height, '
      '${totalFrames != null ? '$totalFrames total' : 'unknown total'})';
}
