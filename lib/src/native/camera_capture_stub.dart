// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../interfaces/camera_capture_interface.dart';

/// Native stub for camera capture — not used on native platforms.
///
/// On native, `createCameraCapture()` in `cimbar_platform.dart` either
/// returns `_AndroidCameraCapture` (Android) or throws `UnsupportedError`.
/// This stub exists solely to satisfy the conditional import system.
class WebCameraCapture implements ICameraCapture {
  @override
  bool get isSupported => false;

  @override
  bool get isStreaming => false;

  @override
  Future<void> start({
    int preferredWidth = 1920,
    int preferredHeight = 1080,
    int frameIntervalMs = 200,
  }) async {
    throw UnsupportedError(
      'Web camera is only available on web platform.',
    );
  }

  @override
  void onFrame(CameraFrameCallback callback) {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
