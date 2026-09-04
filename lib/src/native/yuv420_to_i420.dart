// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

/// One plane of a YUV_420_888 frame, as delivered by the `camera` plugin.
class YuvPlane {
  const YuvPlane({
    required this.bytes,
    required this.rowStride,
    this.pixelStride = 1,
  });

  final Uint8List bytes;

  /// Bytes between the start of consecutive rows. May exceed the visible
  /// width — rows can carry padding.
  final int rowStride;

  /// Bytes between consecutive samples within a row. 1 for fully planar
  /// chroma, 2 when U and V are interleaved.
  final int pixelStride;
}

/// Result of an I420 conversion: the packed bytes plus its dimensions.
class I420Frame {
  const I420Frame({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

/// Convert a YUV_420_888 frame to tightly-packed I420, optionally cropping
/// to a centred square.
///
/// Why I420: cimbar's native `get_rgb()` (see
/// `cimbar_js/cimbar_recv_js.cpp`) maps format code 420 to
/// `cv::COLOR_YUV420p2RGB`, i.e. planar Y+U+V. Handing it I420 keeps the
/// YUV→RGB conversion inside OpenCV instead of doing a full-frame pass in
/// Dart, which is several times more work per frame.
///
/// Returns null if the frame cannot be converted.
I420Frame? yuv420ToI420(
  int width,
  int height,
  List<YuvPlane> planes, {
  bool cropToSquare = true,
}) {
  if (planes.length < 3) return null;
  if (width <= 0 || height <= 0) return null;

  // Crop region in luma pixels. Offsets are forced even so the subsampled
  // chroma planes line up with whole U/V pairs.
  var cropX = 0;
  var cropY = 0;
  var cropW = width;
  var cropH = height;
  if (cropToSquare && width != height) {
    final side = (width < height ? width : height) & ~1;
    cropW = side;
    cropH = side;
    cropX = ((width - side) ~/ 2) & ~1;
    cropY = ((height - side) ~/ 2) & ~1;
  }

  // 4:2:0 -> chroma is half resolution in both directions.
  final chromaW = cropW ~/ 2;
  final chromaH = cropH ~/ 2;
  if (cropW <= 0 || cropH <= 0 || chromaW <= 0 || chromaH <= 0) return null;

  final out = Uint8List(cropW * cropH + chromaW * chromaH * 2);

  _copyPlane(
    planes[0],
    out,
    dstOffset: 0,
    dstRowStride: cropW,
    srcX: cropX,
    srcY: cropY,
    width: cropW,
    height: cropH,
  );
  _copyPlane(
    planes[1],
    out,
    dstOffset: cropW * cropH,
    dstRowStride: chromaW,
    srcX: cropX ~/ 2,
    srcY: cropY ~/ 2,
    width: chromaW,
    height: chromaH,
  );
  _copyPlane(
    planes[2],
    out,
    dstOffset: cropW * cropH + chromaW * chromaH,
    dstRowStride: chromaW,
    srcX: cropX ~/ 2,
    srcY: cropY ~/ 2,
    width: chromaW,
    height: chromaH,
  );

  return I420Frame(bytes: out, width: cropW, height: cropH);
}

/// Copy a region of [plane] into [dst], honouring row padding and
/// interleaved chroma.
///
/// Sampling every `pixelStride`-th byte is what separates U from V. That is
/// exactly what the plugin does itself: `camera_android_camerax`'s
/// `ImageProxyUtils.planesToNV21` documents the source as "YUV_420_888 (with
/// VU planes in NV21 layout)" and reads
///   planes[1] -> uBuffer, sampled by uPixelStride  => U
///   planes[2] -> vBuffer, sampled by vPixelStride  => V
/// while interleaving them the other way round (V first) to build NV21.
///
/// On the Java side each plane's ByteBuffer is copied from its own current
/// position — for interleaved input plane 2 starts one byte into the same
/// memory, which is the offset that makes U and V come out distinct.
///
/// So planes[1] sampled at pixelStride is U and planes[2] is V whether the
/// device reports planar (stride 1) or semi-planar (stride 2). Do not
/// "simplify" this by assuming a single layout.
void _copyPlane(
  YuvPlane plane,
  Uint8List dst, {
  required int dstOffset,
  required int dstRowStride,
  required int srcX,
  required int srcY,
  required int width,
  required int height,
}) {
  final src = plane.bytes;
  final rowStride = plane.rowStride;
  final pixelStride = plane.pixelStride;
  if (rowStride <= 0) return;

  var o = dstOffset;
  for (var y = 0; y < height; y++) {
    final rowStart = (srcY + y) * rowStride;
    for (var x = 0; x < width; x++) {
      final srcIndex = rowStart + (srcX + x) * pixelStride;
      if (srcIndex >= 0 && srcIndex < src.length) {
        dst[o + x] = src[srcIndex];
      }
    }
    o += dstRowStride;
  }
}
