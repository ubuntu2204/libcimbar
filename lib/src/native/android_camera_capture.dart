// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:camera/camera.dart';

import '../interfaces/camera_capture_interface.dart';
import 'yuv420_to_i420.dart';

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

    // The official decoder asks for FOCUS_MODE_CONTINUOUS_VIDEO. The plugin
    // only exposes auto/locked, and `auto` is its default — set it
    // explicitly so we don't inherit a locked focus from elsewhere.
    try {
      await controller.setFocusMode(FocusMode.auto);
    } catch (_) {
      // Not all devices/backends support changing focus mode.
    }

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
  ///
  /// The official android decoder (cfc, `OpencvCameraView.bestCameraFrameSize`)
  /// only accepts preview sizes whose **short** side is 960..1080, and falls
  /// back to a plain "best fit" otherwise. 1080p is the ceiling here for the
  /// same reason: the decoder only needs the barcode to span enough pixels
  /// (~512 already decodes), while a 4K frame costs several times as much to
  /// move across the JNI boundary and scan, for no decoding benefit.
  ResolutionPreset _presetFor(int width, int height) {
    final shortSide = width < height ? width : height;
    if (shortSide >= 1000) return ResolutionPreset.veryHigh; // 1080p
    if (shortSide >= 700) return ResolutionPreset.high; // 720p
    if (shortSide >= 400) return ResolutionPreset.medium; // 480p
    return ResolutionPreset.low;
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

    final converted = yuv420ToI420(
      image.width,
      image.height,
      [
        for (final p in image.planes)
          YuvPlane(
            bytes: p.bytes,
            rowStride: p.bytesPerRow,
            pixelStride: p.bytesPerPixel ?? 1,
          ),
      ],
      cropToSquare: _autoCropEnabled,
    );
    if (converted == null) return;

    callback(CameraFrame(
      data: converted.bytes,
      width: converted.width,
      height: converted.height,
      // CimbarImageFormat.yuv420 -> native cv::COLOR_YUV420p2RGB
      format: 'yuv420',
      timestampUs: DateTime.now().microsecondsSinceEpoch,
    ));
  }
}

/// The single spelling `cimbar_platform.dart` instantiates.
///
/// That file is compiled once per target, so it can only name ONE type. The
/// conditional import decides what this resolves to — the `camera`-plugin
/// implementation on native, the getUserMedia one on web — and both sides
/// export it under this alias so every target compiles.
typedef PlatformCameraCapture = AndroidCameraCapture;
