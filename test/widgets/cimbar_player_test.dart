// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libcimbar/libcimbar.dart';

/// Small (non-1024) frames are fine: the player draws whatever it is given
/// centered in its fixed-size box.
CimbarFrame _frame(int index, {int size = 8}) {
  final pixels = Uint8List(size * size * 3);
  // Distinct first pixel per frame so tests can tell frames apart.
  pixels[0] = index;
  return CimbarFrame(
    index: index,
    pixels: pixels,
    width: size,
    height: size,
  );
}

/// Enlarges the test window so the 1056px player box is not clamped by the
/// default 800x600 test surface (Flutter test windows clamp children to the
/// surface size).
void _useLargeTestSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(2000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('CimbarShake constants (upstream port)', () {
    test('offsets cycle 0, -step, 0, +step', () {
      expect(CimbarShake.offsets.length, 4);
      expect(CimbarShake.offsets[0], 0.0);
      expect(CimbarShake.offsets[1], lessThan(0.0));
      expect(CimbarShake.offsets[2], 0.0);
      expect(CimbarShake.offsets[3], greaterThan(0.0));
      expect(CimbarShake.offsets[1], -CimbarShake.offsets[3]);
    });

    test('box keeps a gutter around the barcode', () {
      expect(CimbarShake.displayDim, 1024.0);
      expect(CimbarShake.margin, 16.0);
      expect(CimbarShake.boxDim,
          CimbarShake.displayDim + 2 * CimbarShake.margin);
      // The gutter must exceed the nudge distance, or the corner anchors
      // get sheared off (measured against the official decoder: a 7px shift
      // with no gutter FAILS).
      expect(CimbarShake.margin, greaterThan(CimbarShake.stepPx));
    });
  });

  group('CimbarFramePlayer', () {
    testWidgets('empty frames render an empty box', (tester) async {
      _useLargeTestSurface(tester);
      await tester.pumpWidget(const MaterialApp(
        home: Center(child: CimbarFramePlayer(frames: [])),
      ));
      await tester.pump();
      expect(tester.getSize(find.byType(CimbarFramePlayer)),
          const Size(CimbarShake.boxDim, CimbarShake.boxDim));
      expect(tester.takeException(), isNull);
    });

    testWidgets('player box is barcode + gutter, not stretched',
        (tester) async {
      _useLargeTestSurface(tester);
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: CimbarFramePlayer(frames: [_frame(0)]),
        ),
      ));
      await tester.pump();
      // The outer box is fixed at barcode + gutter — the barcode never
      // stretches to fill it, and the box never shrinks to the barcode.
      final size = tester.getSize(find.byType(CimbarFramePlayer));
      expect(size, const Size(CimbarShake.boxDim, CimbarShake.boxDim));
      expect(tester.takeException(), isNull);
    });

    testWidgets('first frame decodes and reports through onFrameChanged',
        (tester) async {
      _useLargeTestSurface(tester);
      var callbacks = 0;
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: CimbarFramePlayer(
            frames: [_frame(0)],
            onFrameChanged: (_) => callbacks++,
          ),
        ),
      ));
      // ui.decodeImageFromPixels is real async work: it only completes
      // inside runAsync, not in fake time.
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(callbacks, 1);
    });

    testWidgets('advances frames at the configured fps', (tester) async {
      _useLargeTestSurface(tester);
      final frames = [for (int i = 0; i < 3; i++) _frame(i)];
      var lastReported = -1;
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: CimbarFramePlayer(
            frames: frames,
            fps: 15,
            onFrameChanged: (i) => lastReported = i,
          ),
        ),
      ));
      // Initial frame decode.
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(lastReported, 0);

      // One tick at 15 fps (= 67ms) advances to the next frame.
      await tester.pump(const Duration(milliseconds: 80));
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(lastReported, 1);
    });

    testWidgets('re-encoding (new frame list) restarts at frame 0',
        (tester) async {
      _useLargeTestSurface(tester);
      var lastReported = -1;
      late StateSetter setPlayer;
      var frames = [for (int i = 0; i < 3; i++) _frame(i)];
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: StatefulBuilder(
            builder: (context, setState) {
              setPlayer = setState;
              return CimbarFramePlayer(
                frames: frames,
                fps: 15,
                playing: false,
                onFrameChanged: (i) => lastReported = i,
              );
            },
          ),
        ),
      ));
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(lastReported, 0);

      // Replace the frame list (a fresh encode): the player must decode and
      // show frame 0 of the NEW list, not keep the old image (which had the
      // same index 0).
      frames = [for (int i = 10; i < 13; i++) _frame(i)];
      setPlayer(() {});
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(lastReported, 0);
      expect(find.byType(CimbarFramePlayer), findsOneWidget);
    });

    testWidgets('pausing holds the current frame', (tester) async {
      _useLargeTestSurface(tester);
      final frames = [for (int i = 0; i < 3; i++) _frame(i)];
      var lastReported = -1;
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: CimbarFramePlayer(
            frames: frames,
            fps: 15,
            playing: false,
            onFrameChanged: (i) => lastReported = i,
          ),
        ),
      ));
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(lastReported, 0); // initial frame, then playback is paused

      // Time passes, but with playing=false the frame never advances.
      await tester.pump(const Duration(seconds: 1));
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(lastReported, 0);
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });
}
