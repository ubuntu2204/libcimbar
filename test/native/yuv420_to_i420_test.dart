import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:libcimbar/src/native/yuv420_to_i420.dart';

void main() {
  group('yuv420ToI420', () {
    test('rejects malformed input', () {
      final ok = [
        YuvPlane(bytes: Uint8List(64), rowStride: 8),
        YuvPlane(bytes: Uint8List(16), rowStride: 4),
        YuvPlane(bytes: Uint8List(16), rowStride: 4),
      ];
      // too few planes
      expect(yuv420ToI420(8, 8, ok.sublist(0, 2)), isNull);
      // degenerate dimensions
      expect(yuv420ToI420(0, 8, ok), isNull);
      expect(yuv420ToI420(8, 0, ok), isNull);
    });

    test('planar input: Y/U/V are copied through unchanged', () {
      const w = 4;
      const h = 4;
      // Luma 0..15 in a 4x4 grid.
      final y = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
      // Chroma is 2x2 per plane for 4:2:0.
      final u = Uint8List.fromList([201, 202, 203, 204]);
      final v = Uint8List.fromList([101, 102, 103, 104]);

      final frame = yuv420ToI420(w, h, [
        YuvPlane(bytes: y, rowStride: 4, pixelStride: 1),
        YuvPlane(bytes: u, rowStride: 2, pixelStride: 1),
        YuvPlane(bytes: v, rowStride: 2, pixelStride: 1),
      ], cropToSquare: false);

      expect(frame, isNotNull);
      expect(frame!.width, w);
      expect(frame.height, h);
      // Y (16) + U (4) + V (4)
      expect(frame.bytes.length, 24);
      expect(
          frame.bytes.sublist(0, 16), equals(List<int>.generate(16, (i) => i + 1)));
      expect(frame.bytes.sublist(16, 20), equals([201, 202, 203, 204]));
      expect(frame.bytes.sublist(20, 24), equals([101, 102, 103, 104]));
    });

    test('semi-planar (NV21-style) input: U and V are de-interleaved', () {
      const w = 4;
      const h = 4;
      final y = Uint8List.fromList(List<int>.generate(16, (i) => 1));

      // Interleaved chroma. Per the plugin, plane 1's buffer is positioned
      // so sampling at pixelStride yields U, and plane 2's starts one byte
      // later so the same sampling yields V.
      //
      // Underlying NV21 layout: V0 U0 V1 U1 V2 U2 V3 U3
      const interleaved = [10, 20, 11, 21, 12, 22, 13, 23]; // V,U pairs
      final uPlaneBytes = Uint8List.fromList(interleaved.sublist(1)); // U first
      final vPlaneBytes = Uint8List.fromList(interleaved); // V first

      final frame = yuv420ToI420(w, h, [
        YuvPlane(bytes: y, rowStride: 4, pixelStride: 1),
        YuvPlane(bytes: uPlaneBytes, rowStride: 4, pixelStride: 2),
        YuvPlane(bytes: vPlaneBytes, rowStride: 4, pixelStride: 2),
      ], cropToSquare: false);

      expect(frame, isNotNull);
      // U must be 20,21,22,23 and V must be 10,11,12,13 — if the two planes
      // were treated identically the chroma would collapse and colours would
      // come out swapped.
      expect(frame!.bytes.sublist(16, 20), equals([20, 21, 22, 23]));
      expect(frame.bytes.sublist(20, 24), equals([10, 11, 12, 13]));
      // Guard against the classic bug: U == V.
      expect(frame.bytes.sublist(16, 20),
          isNot(equals(frame.bytes.sublist(20, 24))));
    });

    test('row padding is stripped', () {
      const w = 4;
      const h = 4;
      // Row stride 6 for a 4-wide image -> 2 padding bytes per row.
      final y = Uint8List(6 * 4);
      for (var row = 0; row < 4; row++) {
        for (var x = 0; x < 4; x++) {
          y[row * 6 + x] = row * 10 + x;
        }
        y[row * 6 + 4] = 0xFF; // padding
        y[row * 6 + 5] = 0xFF;
      }
      final u = Uint8List.fromList([1, 2, 3, 4]);
      final v = Uint8List.fromList([5, 6, 7, 8]);

      final frame = yuv420ToI420(w, h, [
        YuvPlane(bytes: y, rowStride: 6, pixelStride: 1),
        YuvPlane(bytes: u, rowStride: 2, pixelStride: 1),
        YuvPlane(bytes: v, rowStride: 2, pixelStride: 1),
      ], cropToSquare: false);

      expect(frame, isNotNull);
      expect(frame!.width, 4);
      // Packed tightly: no 0xFF padding leaked into the output.
      expect(frame.bytes.sublist(0, 16),
          equals([0, 1, 2, 3, 10, 11, 12, 13, 20, 21, 22, 23, 30, 31, 32, 33]));
      expect(frame.bytes.sublist(0, 16), isNot(contains(0xFF)));
    });

    test('square crop centres on a landscape frame', () {
      const w = 8;
      const h = 4;
      final y = Uint8List(8 * 4);
      for (var i = 0; i < y.length; i++) {
        y[i] = i;
      }
      // Distinct chroma so we can verify the chroma offset too.
      final u = Uint8List(4 * 2);
      for (var i = 0; i < u.length; i++) {
        u[i] = 200 + i;
      }
      final v = Uint8List(4 * 2);
      for (var i = 0; i < v.length; i++) {
        v[i] = 100 + i;
      }

      final frame = yuv420ToI420(w, h, [
        YuvPlane(bytes: y, rowStride: 8, pixelStride: 1),
        YuvPlane(bytes: u, rowStride: 4, pixelStride: 1),
        YuvPlane(bytes: v, rowStride: 4, pixelStride: 1),
      ], cropToSquare: true);

      expect(frame, isNotNull);
      expect(frame!.width, 4);
      expect(frame.height, 4);
      // 4x4 luma + 2x2 chroma each
      expect(frame.bytes.length, 16 + 4 + 4);
      // Centred horizontally: source columns 2..5 of each row.
      expect(
          frame.bytes.sublist(0, 4),
          equals([2, 3, 4, 5]));
      expect(
          frame.bytes.sublist(4, 8),
          equals([10, 11, 12, 13]));
    });

    test('no crop keeps the full frame', () {
      const w = 8;
      const h = 4;
      final y = Uint8List(32);
      final u = Uint8List(8);
      final v = Uint8List(8);

      final frame = yuv420ToI420(w, h, [
        YuvPlane(bytes: y, rowStride: 8, pixelStride: 1),
        YuvPlane(bytes: u, rowStride: 4, pixelStride: 1),
        YuvPlane(bytes: v, rowStride: 4, pixelStride: 1),
      ], cropToSquare: false);

      expect(frame!.width, 8);
      expect(frame.height, 4);
      expect(frame.bytes.length, 32 + 8 + 8);
    });
  });
}
