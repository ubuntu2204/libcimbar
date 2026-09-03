import 'package:flutter/widgets.dart';

/// The per-frame display nudge used by upstream cimbar, plus the geometry it
/// needs around the barcode.
///
/// Ported from `gl_2d_display::computeShakePos` (upstream
/// `src/lib/gui/gl_2d_display.h`), which cycles the texture through 4
/// positions offset by `8.0 / dim` (dim = 1080).
///
/// Why bother: a static barcode burns in, and — the part that matters for
/// decoding — a still image lets the screen↔camera interference pattern
/// (moiré) sit perfectly still, so the phone never gets a clean frame to
/// lock onto. Upstream's demo visibly drifts for exactly this reason.
class BarcodeShake {
  const BarcodeShake._();

  /// Native size of the barcode, and the size it must always be painted at.
  static const double displayDim = 1024.0;

  /// Nudge distance: upstream's `8.0 / 1080`, scaled to our display (~7.6px).
  static const double stepPx = 8.0 / 1080.0 * displayDim;

  /// The 4 positions from `computeShakePos`:
  /// centre, down-left, centre, up-right.
  static const List<double> offsets = <double>[
    0.0,
    -stepPx,
    0.0,
    stepPx,
  ];

  /// Black gutter kept around the barcode so the nudge cannot crop it.
  ///
  /// NOT cosmetic. cimbar's 4 corner anchors sit near the image edge, so
  /// translating a 1024px barcode inside a 1024px box shears part of them off
  /// and the frame stops decoding entirely. Measured against the official
  /// decoder: a 7px shift with no gutter FAILS, the same shift with a 16px
  /// gutter passes. Upstream is unaffected because it nudges in GL texture
  /// space rather than moving a same-size image inside its own box.
  static const double margin = 16.0;

  /// Size of the widget box: barcode plus the gutter on each side.
  static const double boxDim = displayDim + 2 * margin;
}

/// Positions [child] at one step of [BarcodeShake].
///
/// The child is ALWAYS given the same tight [BarcodeShake.displayDim] size.
/// That invariant is the whole point of this widget: the barcode painter
/// sizes itself from `size.shortestSide`, so if any step let the child fill
/// the outer [BarcodeShake.boxDim] box instead, the barcode would visibly
/// pulse between two sizes rather than slide. That regression already
/// happened once — see `test/barcode_shake_test.dart`.
class ShakenBarcode extends StatelessWidget {
  const ShakenBarcode({
    super.key,
    required this.offset,
    required this.child,
  });

  /// Current nudge, taken from [BarcodeShake.offsets].
  final double offset;

  /// The barcode painter.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Transform.translate(
        offset: Offset(offset, offset),
        child: SizedBox(
          width: BarcodeShake.displayDim,
          height: BarcodeShake.displayDim,
          child: child,
        ),
      ),
    );
  }
}
