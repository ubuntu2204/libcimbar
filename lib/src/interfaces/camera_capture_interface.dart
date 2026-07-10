// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

/// Callback invoked for each camera frame.
typedef CameraFrameCallback = void Function(CameraFrame frame);

/// Abstract interface for camera-based barcode capture.
///
/// Platform implementations:
/// - Android: Camera2 API via MethodChannel
/// - Web: getUserMedia via dart:js_interop
abstract class ICameraCapture {
  /// Whether camera capture is supported on this platform.
  bool get isSupported;

  /// Whether the camera is currently streaming frames.
  bool get isStreaming;

  /// Start the camera preview and begin delivering frames.
  ///
  /// [preferredResolution] hints at the desired capture resolution.
  /// The actual resolution may differ based on device capabilities.
  Future<void> start({
    int preferredWidth = 1920,
    int preferredHeight = 1080,
  });

  /// Register a callback to receive raw camera frames.
  ///
  /// Frames are delivered as raw pixel data (format depends on platform).
  void onFrame(CameraFrameCallback callback);

  /// Stop the camera preview and stop delivering frames.
  Future<void> stop();

  /// Release camera resources.
  Future<void> dispose();
}

/// A single camera frame.
class CameraFrame {
  /// Raw pixel data.
  final Uint8List data;

  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// Pixel format identifier (e.g., 'rgba', 'nv12', 'yuv420').
  final String format;

  /// Timestamp in microseconds since epoch.
  final int timestampUs;

  const CameraFrame({
    required this.data,
    required this.width,
    required this.height,
    required this.format,
    required this.timestampUs,
  });
}
