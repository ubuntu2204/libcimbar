// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

/// Quality preset for image compression.
enum CompressionQuality {
  /// Fastest encoding, largest output.
  fast,

  /// Balanced speed and size.
  balanced,

  /// Best compression, slowest encoding.
  best,
}

/// Abstract interface for compressing images to AVIF format.
///
/// Platform implementations may use:
/// - Native libavif via FFI (desktop)
/// - External process invocation
/// - Pure Dart fallback (if available)
abstract class IImageCompressor {
  /// Whether this compressor is available and ready.
  bool get isAvailable;

  /// Compress raw RGBA pixel data to AVIF format.
  ///
  /// [pixels] is raw RGBA pixel data (row-major).
  /// [width] and [height] are the image dimensions.
  /// [quality] controls the compression preset.
  ///
  /// Returns the AVIF-encoded bytes.
  Future<Uint8List> compressRgba(
    Uint8List pixels, {
    required int width,
    required int height,
    CompressionQuality quality = CompressionQuality.balanced,
  });

  /// Compress raw RGB pixel data to AVIF format.
  Future<Uint8List> compressRgb(
    Uint8List pixels, {
    required int width,
    required int height,
    CompressionQuality quality = CompressionQuality.balanced,
  });

  /// Decompress AVIF bytes back to raw RGBA pixels.
  Future<DecompressedImage> decompress(Uint8List avifData);

  /// Release any native resources.
  Future<void> dispose();
}

/// Result of decompressing an image.
class DecompressedImage {
  final Uint8List pixels;
  final int width;
  final int height;

  const DecompressedImage({
    required this.pixels,
    required this.width,
    required this.height,
  });
}
