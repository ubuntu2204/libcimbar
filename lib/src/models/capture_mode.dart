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
  /// in view even when the barcode is off-center.
  ///
  /// Costs a lot of detail: a portrait phone frame is squeezed into the
  /// square, so on a 4K capture (2176x3840) the barcode lands at ~940px
  /// inside the 2048 input versus ~1650px under [centerCrop] — and the
  /// 0.53x downscale aliases cimbar's fine cell grid. Reach for this when
  /// the phone is hand-held and the barcode may drift off-center.
  fit,

  /// Crop the largest centered square from the video frame and scale it to
  /// fill the decoder input.
  ///
  /// DEFAULT. Roughly doubles the barcode's pixel size versus [fit] on a
  /// portrait 4K frame (~1650px vs ~940px in a 2048 input) and shrinks by
  /// only ~0.94x instead of ~0.53x, so the cell grid survives resampling.
  /// Downside: content outside the centre square is dropped, so a badly
  /// off-center barcode can lose anchors — that is what [fit] and
  /// [alternate] are for.
  centerCrop,

  /// Alternate between [centerCrop] and [fit] on successive frames: the
  /// center-crop frames give a large, detailed barcode when it is centered,
  /// while the fit frames guarantee all four anchors stay in view. Whichever
  /// framing satisfies the 4-anchor scan first wins.
  alternate,
}
