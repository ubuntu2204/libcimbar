import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:libcimbar_example/core/barcode_shake.dart';

void main() {
  group('BarcodeShake', () {
    test('offsets cycle through the 4 upstream positions', () {
      expect(BarcodeShake.offsets.length, 4);
      // centre, down-left, centre, up-right
      expect(BarcodeShake.offsets[0], 0.0);
      expect(BarcodeShake.offsets[1], lessThan(0.0));
      expect(BarcodeShake.offsets[2], 0.0);
      expect(BarcodeShake.offsets[3], greaterThan(0.0));
      // symmetric
      expect(BarcodeShake.offsets[3], -BarcodeShake.offsets[1]);
    });

    test('gutter is wide enough for the nudge', () {
      // The gutter exists so the nudge cannot crop the corner anchors.
      // Measured: a 7px shift with no gutter fails to decode, with a 16px
      // gutter it passes.
      expect(BarcodeShake.margin, greaterThanOrEqualTo(BarcodeShake.stepPx));
    });

    test('box holds the barcode plus both gutters', () {
      expect(BarcodeShake.boxDim,
          BarcodeShake.displayDim + 2 * BarcodeShake.margin);
    });
  });

  group('ShakenBarcode', () {
    /// Regression guard for a bug where the zero-offset step returned the
    /// bare child, letting it fill the outer gutter box (1056) while the
    /// offset steps stayed at 1024. Because the barcode painter sizes itself
    /// from `size.shortestSide`, that made the barcode visibly pulse between
    /// two sizes on every cycle instead of sliding.
    testWidgets('child size is identical at every shake offset',
        (WidgetTester tester) async {
      // The default test surface is 800x600, which would clamp the 1056
      // gutter box and give the child 800 — an artefact of the test
      // environment, not of the widget. Make the surface big enough that the
      // box gets its requested size.
      tester.view.physicalSize = const Size(2000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final sizes = <double>[];

      for (final offset in BarcodeShake.offsets) {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(size: Size(2000, 2000)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: SizedBox(
                width: BarcodeShake.boxDim,
                height: BarcodeShake.boxDim,
                child: ShakenBarcode(
                  offset: offset,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      sizes.add(constraints.maxWidth);
                      return const SizedBox.expand();
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      }

      // Every step must constrain the child to the native barcode size.
      expect(sizes, hasLength(BarcodeShake.offsets.length));
      for (final s in sizes) {
        expect(s, BarcodeShake.displayDim);
      }
      // ...and specifically NOT the outer gutter box.
      expect(sizes.any((s) => s == BarcodeShake.boxDim), isFalse);
    });

    testWidgets('only the translation changes between steps',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(2000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      Future<Offset> translationFor(double offset) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: BarcodeShake.boxDim,
              height: BarcodeShake.boxDim,
              child: ShakenBarcode(
                offset: offset,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
        final transform = tester.widget<Transform>(find.byType(Transform));
        final v = transform.transform.getTranslation();
        return Offset(v.x, v.y);
      }

      final t0 = await translationFor(BarcodeShake.offsets[0]);
      final t1 = await translationFor(BarcodeShake.offsets[1]);
      final t3 = await translationFor(BarcodeShake.offsets[3]);

      // centre step does not move
      expect(t0, Offset.zero);
      // the two live steps move in opposite directions
      expect(t1.dx, lessThan(0));
      expect(t3.dx, greaterThan(0));
      expect(t1.dx, -t3.dx);
      expect(t1.dy, t1.dx); // moves diagonally, per upstream
    });
  });
}
