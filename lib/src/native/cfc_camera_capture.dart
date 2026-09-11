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
/// Backpressure is cfc's, verbatim in spirit: the Kotlin side forwards
/// EVERY camera frame (no throttle), and while the decoder is chewing on
/// one frame the newest arrival simply OVERWRITES the pending slot —
/// older frames are dropped, never queued, and the decode rate settles at
/// whatever the decoder sustains. That is exactly cfc's CameraWorker +
/// double-buffered mFrameChain: the worker always takes the latest
/// completed frame and anything faster than it is lost.
///
/// The preview is the camera's own SurfaceTexture exposed as a Flutter
/// texture: `textureId` for the Texture widget, `rotation` for the
/// RotatedBox that orients it (cfc rotates via OpenCV's frameRotation).
class CfcCameraCapture implements ICameraCapture {
  static const MethodChannel _channel = MethodChannel('libcimbar/cfc_camera');
  static const EventChannel _frames =
      EventChannel('libcimbar/cfc_camera/frames');

  /// Kept for the [ICameraCapture.start] signature only — cfc has no
  /// cadence knob and neither do we: every frame is forwarded, and the
  /// decoder's throughput is the only pacing (busy → drop newest-wins).
  static const int frameIntervalMs = 0;

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

  /// The newest undecoded frame — cfc's double-buffered `mFrameChain`
  /// slot. While a decode is running, the camera keeps overwriting this
  /// and older frames are DROPPED (never queued): the newest always wins.
  Uint8List? _pendingNv21;

  /// Guards the one-decode-at-a-time pump.
  bool _pumpScheduled = false;

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
    // frameIntervalMs is deliberately ignored — cfc decodes every frame
    // it can and drops the rest (see the class doc).
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
    // Newest-wins: store the frame and schedule one decode if none is
    // queued/running. Frames arriving while a decode blocks this isolate
    // just overwrite the slot — cfc's CameraWorker takes the latest
    // mFrameChain entry and the older one is lost, never queued.
    _pendingNv21 = raw;
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(_pumpLatest);
  }

  /// The CameraWorker loop, Dart edition: take the newest frame, convert
  /// to I420, hand it to the decoder. The decode (synchronous FFI) blocks
  /// the isolate for its full duration; frames arriving in that window
  /// only overwrite [_pendingNv21], so the effective decode rate is
  /// whatever the decoder sustains — everything faster is dropped.
  void _pumpLatest() {
    _pumpScheduled = false;
    final raw = _pendingNv21;
    final cb = _onFrame;
    if (raw == null || cb == null) return;
    _pendingNv21 = null;

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
      timestampUs: DateTime.now().microsecondsSinceEpoch,
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

/// The single spelling `cimbar_platform.dart` instantiates.
///
/// That file is compiled once per target, so it can only name ONE type. The
/// conditional import decides what this resolves to — this cfc-style capture
/// (Camera1 + `bestCameraFrameSize`) on native, the getUserMedia one on web —
/// and both sides export it under this alias so every target compiles.
typedef PlatformCameraCapture = CfcCameraCapture;
