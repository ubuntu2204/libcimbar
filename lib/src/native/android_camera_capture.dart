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

  // ─── ICameraCapture ────────────────────────────────────────────

  @override
  bool get isSupported => Platform.isAndroid || Platform.isIOS;

  @override
  bool get isStreaming => _streaming;

  /// The underlying controller, for apps that render a preview.
  ///
  /// A caller that only consumes frames never needs this, but the decoder UI
  /// does: without rendering it the user is scanning blind, with no way to
  /// aim the camera at the barcode. Returns null before [start].
  CameraController? get controller => _controller;

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

    final controller = CameraController(
      selected,
      _presetFor(preferredWidth, preferredHeight),
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

  // ─── Tuning ─────────────────────────────────────────────────────
  // NOTE: the former maxTargetSize / autoCropEnabled / captureMode
  // setters (written via `as dynamic` by an older shared decoder page)
  // are gone. The official-style pipeline needs none of them: the FULL
  // frame goes to the decoder (cfc scans the whole frame for the corner
  // anchors), and the resolution is fixed by [_presetFor].

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

  /// The frame handed to the decoder is trimmed to the OFFICIAL frame
  /// shape — cfc's `bestCameraFrameSize` lands on a 4:3 frame with a
  /// 960..1080 short side (1440x1080 on this device), i.e. full height
  /// with margins on the sides.
  ///
  /// Pixels are never resampled: interpolation measurably destroys the
  /// corner anchors, so the surplus is cut away instead of scaled.
  static const double kCaptureAspect = 4 / 3;

  /// The decoded frame, for the viewfinder window (which must show exactly
  /// what the decoder receives).
  double get decodedAspect => kCaptureAspect;

  /// Map a requested capture size onto the nearest plugin preset.
  ///
  /// veryHigh = 1920x1080, the preset whose short side (1080) matches the
  /// official decoder's 960..1080 window. The capture itself is 16:9 (the
  /// plugin pins every preset but `low` to 16:9), so [kCaptureAspect]
  /// trims it back to the official 4:3 shape afterwards.
  ResolutionPreset _presetFor(int width, int height) =>
      ResolutionPreset.veryHigh;

  void _onCameraImage(CameraImage image) {
    final callback = _onFrame;
    if (callback == null) return;

    // Throttle: the camera stream runs far faster than we need to decode.
    final now = DateTime.now();
    if (now.difference(_lastDelivered).inMilliseconds < _frameIntervalMs) {
      return;
    }
    _lastDelivered = now;

    // Full WIDTH, surplus rows trimmed — the official pipeline (cfc) feeds
    // every pixel of its capture to the Scanner, and so do we. No centre
    // crop (that was measured as a much lower decode rate: an off-centre
    // barcode loses its anchors entirely), and no downscaling either —
    // only the top/bottom band that carries no barcode is dropped.
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
      cropAspect: kCaptureAspect,
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
