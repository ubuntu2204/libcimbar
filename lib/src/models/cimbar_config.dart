// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Configuration for cimbar encoding/decoding.
class CimbarConfig {
  /// Encoding mode identifier.
  final CimbarMode mode;

  /// Zstd compression level (0–22). 0 = no compression.
  final int compressionLevel;

  /// Reed-Solomon error correction bytes per block.
  final int eccBytes;

  /// Frame rate for animated encoding display.
  final int fps;

  /// Fixed output image size in pixels (width == height for square frames).
  /// Always 1024 — not configurable.
  final int imageSize;

  /// Optional encode ID (0–127). -1 for auto-increment.
  final int encodeId;

  const CimbarConfig({
    this.mode = CimbarMode.modeB,
    this.compressionLevel = 16,
    this.eccBytes = 30,
    this.fps = 15,
    this.encodeId = -1,
  }) : imageSize = 1024;

  /// Numeric mode value passed to the native library.
  int get modeValue => mode.value;

  CimbarConfig copyWith({
    CimbarMode? mode,
    int? compressionLevel,
    int? eccBytes,
    int? fps,
    int? encodeId,
  }) {
    return CimbarConfig(
      mode: mode ?? this.mode,
      compressionLevel: compressionLevel ?? this.compressionLevel,
      eccBytes: eccBytes ?? this.eccBytes,
      fps: fps ?? this.fps,
      encodeId: encodeId ?? this.encodeId,
    );
  }

  @override
  String toString() =>
      'CimbarConfig(mode: $mode, compression: $compressionLevel, ecc: $eccBytes, '
      'fps: $fps, imageSize: $imageSize, encodeId: $encodeId)';
}

/// Cimbar encoding modes.
///
/// | Mode   | Grid  | Description                          |
/// |--------|-------|--------------------------------------|
/// | mode4C | 16x16 | RGB + luminance, best compatibility  |
/// | modeB  | 24x24 | High color gamut, optimized speed    |
/// | modeBm | 24x24 | Monochrome, for low-light            |
/// | modeBu | 24x24 | Variant of B mode                    |
enum CimbarMode {
  /// 16x16 grid, RGB + luminance — best device compatibility.
  mode4C(4),

  /// 24x24 grid, high color gamut — default for most use cases.
  modeB(68),

  /// 24x24 grid, monochrome — for low-light environments.
  modeBm(67),

  /// 24x24 grid, variant of B mode.
  modeBu(66);

  final int value;
  const CimbarMode(this.value);

  static CimbarMode fromValue(int value) {
    return CimbarMode.values.firstWhere(
      (m) => m.value == value,
      orElse: () => CimbarMode.modeB,
    );
  }
}

/// Image pixel format for decoder input.
enum CimbarImageFormat {
  /// 3 bytes per pixel: Red, Green, Blue.
  rgb(3),

  /// 4 bytes per pixel: Red, Green, Blue, Alpha.
  rgba(4),

  /// YUV NV12 format (common camera output).
  nv12(12),

  /// YUV 4:2:0 planar format.
  yuv420(420);

  final int value;
  const CimbarImageFormat(this.value);
}
