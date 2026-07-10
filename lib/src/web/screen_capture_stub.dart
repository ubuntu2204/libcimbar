// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../interfaces/screen_capture_interface.dart';

/// Web stub for screen capture — not supported on web.
class WindowsScreenCapture implements IScreenCapture {
  @override
  bool get isSupported => false;

  @override
  Future<ScreenCaptureResult> captureRegion(dynamic region) async {
    throw UnsupportedError('Screen capture is not available on web.');
  }

  @override
  Future<ScreenCaptureResult> captureFullScreen() async {
    throw UnsupportedError('Screen capture is not available on web.');
  }

  @override
  Future<void> dispose() async {}
}
