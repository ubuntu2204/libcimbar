// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// How a camera frame is mapped into the square decoder input.
///
/// Defined here (platform-neutral) rather than next to the web camera
/// implementation: the web capture file depends on `dart:js_interop`, so
/// exporting it directly would drag JS-interop types into native builds
/// (Windows/Linux/macOS) and break the kernel snapshot.
enum WebCaptureMode {
  /// Fit the *entire* video frame into the target square, preserving aspect
  /// ratio (letterboxed). Nothing is cropped, so all four cimbar anchors stay
  /// in view even when the barcode is off-center — the safe default when the
  /// phone is hand-held and the monitor is rarely centered.
  fit,

  /// Crop the largest centered square from the video frame. Yields a larger
  /// barcode when it is well-centered, but drops content (and anchors) that
  /// fall outside the center square.
  centerCrop,

  /// Alternate between [centerCrop] and [fit] on successive frames: the
  /// center-crop frames give a large, detailed barcode when it is centered,
  /// while the fit frames guarantee all four anchors stay in view. Whichever
  /// framing satisfies the 4-anchor scan first wins.
  alternate,
}
