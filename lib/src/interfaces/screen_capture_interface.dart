// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';
import 'dart:ui' show Rect;

/// Abstract interface for capturing a region of the screen.
///
/// Platform implementations:
/// - Windows: Win32 GDI APIs via FFI
/// - macOS: CGWindowListCreateImage via FFI (future)
/// - Linux: X11/Wayland via FFI (future)
abstract class IScreenCapture {
  /// Whether screen capture is supported on this platform.
  bool get isSupported;

  /// Capture a rectangular region of the screen.
  ///
  /// Returns raw RGBA pixel data for the specified [region].
  /// The [region] is in logical screen coordinates.
  Future<ScreenCaptureResult> captureRegion(Rect region);

  /// Capture the entire primary display.
  Future<ScreenCaptureResult> captureFullScreen();

  /// Release any native resources held by the capture backend.
  Future<void> dispose();
}

/// Result of a screen capture operation.
class ScreenCaptureResult {
  /// Raw RGBA pixel data (row-major).
  final Uint8List pixels;

  /// Width of the captured region in pixels.
  final int width;

  /// Height of the captured region in pixels.
  final int height;

  const ScreenCaptureResult({
    required this.pixels,
    required this.width,
    required this.height,
  });

  /// Bytes per row (stride = width * 4 for RGBA).
  int get stride => width * 4;
}
