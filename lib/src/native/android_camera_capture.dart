// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:camera/camera.dart';

import '../interfaces/camera_capture_interface.dart';

/// Camera capture for Android (and iOS), backed by the `camera` plugin.
///
/// Frames are handed to the decoder as **I420** — the exact layout cimbar's
/// native `get_rgb()` understands (`cv::COLOR_YUV420p2RGB`, format code 420).
/// That matters: converting YUV to RGB in Dart costs a full-frame pass over
/// every pixel, whereas letting the native side do it keeps the conversion in
/// OpenCV (and off the Dart heap).
///
/// The plugin gives us a `CameraImage` in YUV_420_888, whose UV planes may be
/// fully planar (pixelStride 1) or interleaved (pixelStride 2, i.e. NV21)
/// depending on the device, and whose rows can carry padding. Both are
/// normalised to tightly-packed I420 here.
class AndroidCameraCapture implements ICameraCapture {
  CameraController? _controller;
  CameraFrameCallback? _onFrame;

  bool _streaming = false;

  /// Minimum gap between delivered frames. The camera's own stream rate is
  /// much higher; decoding every frame would just burn battery and saturate
  /// the decoder queue.
  int _frameIntervalMs = 200;
  DateTime _lastDelivered = DateTime.fromMillisecondsSinceEpoch(0);

  /// Square crop around the frame centre, applied in YUV space.
  ///
  /// The barcode has to occupy as many pixels as possible for the decoder's
  /// anchors to resolve, so throwing away the letterboxed margins is worth
  /// far more than keeping the full field of view.
  bool _autoCropEnabled = true;

  // ─── ICameraCapture ────────────────────────────────────────────

  @override
  bool get isSupported => Platform.isAndroid || Platform.isIOS;

  @override
  bool get isStreaming => _streaming;

  @override
  Future<void> start({
    int preferredWidth = 1920,
    int preferredHeight = 1080,
    int frameIntervalMs = 200,
  }) async {
    if (_streaming) return;
    _frameIntervalMs = frameIntervalMs;

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('未找到可用摄像头（availableCameras 返回空）。');
    }

    // Back camera is the sensible default for pointing a phone at a screen.
    CameraDescription selected = cameras.first;
    for (final c in cameras) {
      if (c.lensDirection == CameraLensDirection.back) {
        selected = c;
        break;
      }
    }

    // Honour the UI's target cap: asking for more pixels than we intend to
    // decode just wastes capture time and memory.
    var width = preferredWidth;
    var height = preferredHeight;
    final cap = _maxTargetSize;
    if (cap != null) {
      final longSide = width > height ? width : height;
      if (longSide > cap) {
        final scale = cap / longSide;
        width = (width * scale).round();
        height = (height * scale).round();
      }
    }

    final controller = CameraController(
      selected,
      _presetFor(width, height),
      enableAudio: false,
      // yuv420 keeps the plugin from doing its own (slower) conversions.
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    _controller = controller;

    await controller.initialize();
    await controller.startImageStream(_onCameraImage);
    _streaming = true;
  }

  @override
  void onFrame(CameraFrameCallback callback) => _onFrame = callback;

  @override
  Future<void> stop() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {
      // Already stopped, or the controller was disposed underneath us.
    }
    _streaming = false;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _controller?.dispose();
    _controller = null;
    _onFrame = null;
  }

  // ─── Tuning, set dynamically by the decoder UI ─────────────────
  //
  // The UI assigns these through `as dynamic` (they are web-side concepts
  // that the shared decoder page writes unconditionally), so they have to
  // exist here or the writes silently no-op.

  int? _maxTargetSize;

  /// Upper bound for the decoded frame's long side, applied on next start.
  set maxTargetSize(int? v) => _maxTargetSize = v;

  /// Enable/disable the centred square crop.
  set autoCropEnabled(bool v) => _autoCropEnabled = v;

  /// Accepts the web-side `WebCaptureMode` enum without importing it (that
  /// type only exists in the web build). "fit" keeps the whole frame;
  /// anything else crops to a centred square.
  set captureMode(dynamic mode) {
    final name = mode?.toString().toLowerCase() ?? '';
    _autoCropEnabled = name.contains('fit') ? false : true;
  }

  /// Grab a still picture for diagnostics (the counterpart of the web
  /// implementation's raw-frame dump).
  Future<Uint8List?> captureRawFramePng() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;
    try {
      final file = await controller.takePicture();
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  // ─── Internals ─────────────────────────────────────────────────

  /// Map a requested capture size onto the nearest plugin preset.
  ResolutionPreset _presetFor(int width, int height) {
    final longSide = width > height ? width : height;
    if (longSide >= 3000) return ResolutionPreset.ultraHigh;
    if (longSide >= 1900) return ResolutionPreset.veryHigh;
    if (longSide >= 1200) return ResolutionPreset.high;
    return ResolutionPreset.medium;
  }

  void _onCameraImage(CameraImage image) {
    final callback = _onFrame;
    if (callback == null) return;

    // Throttle: the camera stream runs far faster than we need to decode.
    final now = DateTime.now();
    if (now.difference(_lastDelivered).inMilliseconds < _frameIntervalMs) {
      return;
    }
    _lastDelivered = now;

    final converted = _toI420(image, cropToSquare: _autoCropEnabled);
    if (converted == null) return;
    final bytes = converted.$1;
    final w = converted.$2;
    final h = converted.$3;

    callback(CameraFrame(
      data: bytes,
      width: w,
      height: h,
      // CimbarImageFormat.yuv420 -> native cv::COLOR_YUV420p2RGB
      format: 'yuv420',
      timestampUs: DateTime.now().microsecondsSinceEpoch,
    ));
  }

  /// Normalise a `CameraImage` to tightly-packed I420, optionally cropping
  /// to a centred square.
  ///
  /// Returns (bytes, width, height) or null when the image cannot be used.
  (Uint8List, int, int)? _toI420(
    CameraImage image, {
    required bool cropToSquare,
  }) {
    final planes = image.planes;
    if (planes.length < 3) return null;

    final fullW = image.width;
    final fullH = image.height;
    if (fullW <= 0 || fullH <= 0) return null;

    // Crop region (in luma pixels), kept even so the chroma planes stay
    // whole — an odd offset would sample the wrong UV pair.
    int cropX = 0, cropY = 0, cropW = fullW, cropH = fullH;
    if (cropToSquare && fullW != fullH) {
      final side = (fullW < fullH ? fullW : fullH) & ~1;
      cropW = side;
      cropH = side;
      cropX = ((fullW - side) ~/ 2) & ~1;
      cropY = ((fullH - side) ~/ 2) & ~1;
    }
    // Chroma is subsampled 2:1 in both directions.
    final chromaW = cropW ~/ 2;
    final chromaH = cropH ~/ 2;
    if (chromaW <= 0 || chromaH <= 0) return null;

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

    return (out, cropW, cropH);
  }

  /// Copy a [plane] region into [dst], handling both row padding
  /// (`bytesPerRow`) and interleaved chroma (`bytesPerPixel` > 1).
  ///
  /// For semi-planar input (NV21), planes[1] and planes[2] describe the same
  /// interleaved buffer at different phases, so sampling every
  /// `bytesPerPixel`-th byte is what separates U from V.
  void _copyPlane(
    Plane plane,
    Uint8List dst, {
    required int dstOffset,
    required int dstRowStride,
    required int srcX,
    required int srcY,
    required int width,
    required int height,
  }) {
    final src = plane.bytes;
    final rowStride = plane.bytesPerRow;
    final pixelStride = plane.bytesPerPixel ?? 1;
    if (rowStride <= 0) return;

    var o = dstOffset;
    for (var y = 0; y < height; y++) {
      final rowStart = (srcY + y) * rowStride;
      for (var x = 0; x < width; x++) {
        final srcIndex = rowStart + (srcX + x) * pixelStride;
        if (srcIndex < src.length) {
          dst[o + x] = src[srcIndex];
        }
      }
      o += dstRowStride;
    }
  }
}

/// The single spelling `cimbar_platform.dart` instantiates.
///
/// That file is compiled once per target, so it can only name ONE type. The
/// conditional import decides what this resolves to — the `camera`-plugin
/// implementation on native, the getUserMedia one on web — and both sides
/// export it under this alias so every target compiles.
typedef PlatformCameraCapture = AndroidCameraCapture;
