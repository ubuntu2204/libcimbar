// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../interfaces/camera_capture_interface.dart';
import 'yuv420_to_i420.dart';

/// Android capture that mirrors the OFFICIAL decoder (cfc) end to end:
/// Camera1 + cfc's `bestCameraFrameSize` (short side 960..1080, smallest
/// width -> 1440x1080, the sensor's native 4:3 with the FULL vertical
/// field of view) + NV21 frames + Flutter-texture preview.
/// The native half lives in `CfcCameraHandler.kt`.
///
/// Frames arrive as raw NV21 (sensor direction) and are re-packed into
/// I420 (format 420) — the layout cimbar's native `get_rgb()` understands —
/// with only the top/bottom band trimmed to the 4:3 decode shape. Pixels
/// are never resampled.
///
/// The preview is the camera's own SurfaceTexture exposed as a Flutter
/// texture: `textureId` for the Texture widget, `rotation` for the
/// RotatedBox that orients it (cfc rotates via OpenCV's frameRotation).
class CfcCameraCapture implements ICameraCapture {
  static const MethodChannel _channel = MethodChannel('libcimbar/cfc_camera');
  static const EventChannel _frames =
      EventChannel('libcimbar/cfc_camera/frames');

  /// Frame cadence, the official 15 fps.
  static const int frameIntervalMs = 66;

  /// Aspect (long side / short side) trimmed to — the official 4:3 shape.
  static const double decodeAspect = 4 / 3;

  /// Flutter texture id for the camera preview (-1 until open succeeds).
  int? textureId;

  /// Delivered frame dimensions (sensor direction, 4:3-cropped).
  int frameWidth = 0;
  int frameHeight = 0;

  /// Rotation (0/90/180/270) the native side computed — display only.
  int rotation = 0;

  bool _streaming = false;
  StreamSubscription? _frameSub;
  CameraFrameCallback? _onFrame;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  bool get isSupported => Platform.isAndroid;

  @override
  bool get isStreaming => _streaming;

  /// Aspect (long/short, >= 1) of the frame handed to the decoder.
  double get decodedAspect {
    if (frameWidth > 0 && frameHeight > 0) {
      final a = frameWidth / frameHeight;
      return a >= 1 ? a : 1 / a;
    }
    return decodeAspect;
  }

  @override
  Future<void> start({
    int preferredWidth = 1920,
    int preferredHeight = 1080,
    int frameIntervalMs = frameIntervalMs,
  }) async {
    if (_streaming) return;
    final res =
        await _channel.invokeMethod<Map<Object?, Object?>>('open');
    if (res == null) {
      throw StateError('cfc camera open returned null');
    }
    textureId = (res['textureId'] as num?)?.toInt() ?? -1;
    frameWidth = (res['width'] as num?)?.toInt() ?? 0;
    frameHeight = (res['height'] as num?)?.toInt() ?? 0;
    rotation = (res['rotation'] as num?)?.toInt() ?? 0;
    if (textureId == null || textureId! < 0 || frameWidth <= 0) {
      throw StateError('cfc camera open failed: $res');
    }
    _frameSub = _frames
        .receiveBroadcastStream()
        .listen(_onNativeFrame, onError: (Object e) {
      // A dropped frame must not kill the stream; the handler re-listens.
    });
    _streaming = true;
  }

  void _onNativeFrame(dynamic raw) {
    if (raw is! Uint8List || frameWidth <= 0 || frameHeight <= 0) return;
    // Throttle to the official cadence.
    final now = DateTime.now();
    if (now.difference(_lastFrame).inMilliseconds < frameIntervalMs) return;
    _lastFrame = now;

    final cb = _onFrame;
    if (cb == null) return;

    // NV21 = Y plane (w*h) + interleaved VU chroma (w*h/2). Wrap as the
    // three planes yuv420ToI420 expects: U is the VU data offset by one
    // byte, V starts at zero (zero-copy views — no extra copies).
    final ySize = frameWidth * frameHeight;
    final converted = yuv420ToI420(
      frameWidth,
      frameHeight,
      [
        YuvPlane(bytes: raw, rowStride: frameWidth, pixelStride: 1),
        YuvPlane(
          bytes: Uint8List.sublistView(raw, ySize + 1),
          rowStride: frameWidth,
          pixelStride: 2,
        ),
        YuvPlane(
          bytes: Uint8List.sublistView(raw, ySize),
          rowStride: frameWidth,
          pixelStride: 2,
        ),
      ],
      cropAspect: decodeAspect,
    );
    if (converted == null) return;

    cb(CameraFrame(
      data: converted.bytes,
      width: converted.width,
      height: converted.height,
      format: 'yuv420',
      timestampUs: now.microsecondsSinceEpoch,
    ));
  }

  @override
  void onFrame(CameraFrameCallback callback) => _onFrame = callback;

  @override
  Future<void> stop() async {
    _frameSub?.cancel();
    _frameSub = null;
    try {
      await _channel.invokeMethod('close');
    } catch (_) {}
    textureId = null;
    _streaming = false;
  }

  @override
  Future<void> dispose() => stop();
}
