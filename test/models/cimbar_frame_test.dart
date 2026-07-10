import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libcimbar/src/models/cimbar_frame.dart';

void main() {
  group('CimbarFrame', () {
    late Uint8List testPixels;

    setUp(() {
      // 2x2 RGB image = 2 * 2 * 3 = 12 bytes
      testPixels = Uint8List.fromList(List.generate(12, (i) => i * 20));
    });

    test('constructor sets all required fields', () {
      final frame = CimbarFrame(
        index: 0,
        pixels: testPixels,
        width: 2,
        height: 2,
      );

      expect(frame.index, 0);
      expect(frame.pixels, testPixels);
      expect(frame.width, 2);
      expect(frame.height, 2);
      expect(frame.totalFrames, isNull);
    });

    test('constructor sets optional totalFrames', () {
      final frame = CimbarFrame(
        index: 3,
        pixels: testPixels,
        width: 2,
        height: 2,
        totalFrames: 10,
      );

      expect(frame.totalFrames, 10);
    });

    test('stride is width * 3 for RGB', () {
      final frame = CimbarFrame(
        index: 0,
        pixels: testPixels,
        width: 1024,
        height: 1024,
      );

      expect(frame.stride, 3072);
    });

    test('stride with small width', () {
      final frame = CimbarFrame(
        index: 0,
        pixels: testPixels,
        width: 1,
        height: 1,
      );

      expect(frame.stride, 3);
    });

    test('byteLength equals pixel data length', () {
      final frame = CimbarFrame(
        index: 0,
        pixels: testPixels,
        width: 2,
        height: 2,
      );

      expect(frame.byteLength, testPixels.length);
      expect(frame.byteLength, 12);
    });

    test('byteLength for large frame', () {
      final largePixels = Uint8List(1024 * 1024 * 3);
      final frame = CimbarFrame(
        index: 0,
        pixels: largePixels,
        width: 1024,
        height: 1024,
      );

      expect(frame.byteLength, 1024 * 1024 * 3);
    });

    test('toString without totalFrames shows "unknown total"', () {
      final frame = CimbarFrame(
        index: 5,
        pixels: testPixels,
        width: 100,
        height: 200,
      );

      final str = frame.toString();
      expect(str, contains('CimbarFrame'));
      expect(str, contains('index: 5'));
      expect(str, contains('100x200'));
      expect(str, contains('unknown total'));
    });

    test('toString with totalFrames shows total count', () {
      final frame = CimbarFrame(
        index: 2,
        pixels: testPixels,
        width: 50,
        height: 50,
        totalFrames: 8,
      );

      final str = frame.toString();
      expect(str, contains('CimbarFrame'));
      expect(str, contains('index: 2'));
      expect(str, contains('50x50'));
      expect(str, contains('8 total'));
    });

    test('pixels are independent copies', () {
      final original = Uint8List.fromList([255, 0, 0, 0, 255, 0]);
      final frame = CimbarFrame(
        index: 0,
        pixels: original,
        width: 2,
        height: 1,
      );

      // Modify original array
      original[0] = 0;

      // Frame pixels should still hold the original values
      expect(frame.pixels[0], 255);
    });

    test('empty pixel data', () {
      final emptyPixels = Uint8List(0);
      final frame = CimbarFrame(
        index: 0,
        pixels: emptyPixels,
        width: 0,
        height: 0,
      );

      expect(frame.byteLength, 0);
      expect(frame.stride, 0);
    });

    test('const constructor produces consistent instances', () {
      final pixels = Uint8List.fromList([1, 2, 3]);
      final a = CimbarFrame(
        index: 1,
        pixels: pixels,
        width: 1,
        height: 1,
      );
      final b = CimbarFrame(
        index: 1,
        pixels: pixels,
        width: 1,
        height: 1,
      );

      expect(a.index, b.index);
      expect(a.width, b.width);
      expect(a.height, b.height);
      expect(a.pixels, b.pixels);
    });
  });
}
