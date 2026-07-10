import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libcimbar/src/impl/avif_compressor.dart';
import 'package:libcimbar/src/interfaces/image_compressor_interface.dart';

void main() {
  group('AvifCompressor', () {
    late AvifCompressor compressor;

    setUp(() {
      compressor = AvifCompressor();
    });

    test('isAvailable after construction', () {
      expect(compressor.isAvailable, isTrue);
    });

    test('isNativeAvif is false without native library', () {
      expect(compressor.isNativeAvif, isFalse);
    });

    test('implements IImageCompressor', () {
      expect(compressor, isA<IImageCompressor>());
    });

    group('compressRgba (PNG fallback)', () {
      test('produces valid PNG output', () async {
        // 2x2 RGBA image
        final pixels = Uint8List.fromList([
          255, 0, 0, 255, // red
          0, 255, 0, 255, // green
          0, 0, 255, 255, // blue
          255, 255, 0, 255, // yellow
        ]);

        final result = await compressor.compressRgba(
          pixels,
          width: 2,
          height: 2,
        );

        expect(result, isNotEmpty);
        // Check PNG signature
        expect(result[0], 0x89);
        expect(result[1], 0x50); // 'P'
        expect(result[2], 0x4E); // 'N'
        expect(result[3], 0x47); // 'G'
      });

      test('produces output for 1x1 pixel', () async {
        final pixels = Uint8List.fromList([128, 64, 32, 255]);

        final result = await compressor.compressRgba(
          pixels,
          width: 1,
          height: 1,
        );

        expect(result, isNotEmpty);
        expect(result[0], 0x89); // PNG signature
      });

      test('output contains IHDR chunk', () async {
        final pixels = Uint8List.fromList([255, 0, 0, 255]);

        final result = await compressor.compressRgba(
          pixels,
          width: 1,
          height: 1,
        );

        // Find IHDR in the PNG data
        final ihdrFound = _findChunkType(result, 'IHDR');
        expect(ihdrFound, isTrue);
      });

      test('output contains IDAT chunk', () async {
        final pixels = Uint8List.fromList([255, 0, 0, 255]);

        final result = await compressor.compressRgba(
          pixels,
          width: 1,
          height: 1,
        );

        final idatFound = _findChunkType(result, 'IDAT');
        expect(idatFound, isTrue);
      });

      test('output contains IEND chunk', () async {
        final pixels = Uint8List.fromList([255, 0, 0, 255]);

        final result = await compressor.compressRgba(
          pixels,
          width: 1,
          height: 1,
        );

        final iendFound = _findChunkType(result, 'IEND');
        expect(iendFound, isTrue);
      });

      test('larger image produces larger output', () async {
        final smallPixels = Uint8List(4 * 4 * 4); // 4x4
        final largePixels = Uint8List(32 * 32 * 4); // 32x32

        final smallResult = await compressor.compressRgba(
          smallPixels,
          width: 4,
          height: 4,
        );
        final largeResult = await compressor.compressRgba(
          largePixels,
          width: 32,
          height: 32,
        );

        expect(largeResult.length, greaterThan(smallResult.length));
      });

      test('with fast quality preset', () async {
        final pixels = Uint8List(4 * 4 * 4);
        final result = await compressor.compressRgba(
          pixels,
          width: 4,
          height: 4,
          quality: CompressionQuality.fast,
        );

        expect(result, isNotEmpty);
      });

      test('with best quality preset', () async {
        final pixels = Uint8List(4 * 4 * 4);
        final result = await compressor.compressRgba(
          pixels,
          width: 4,
          height: 4,
          quality: CompressionQuality.best,
        );

        expect(result, isNotEmpty);
      });
    });

    group('compressRgb (RGB → RGBA conversion)', () {
      test('converts RGB to RGBA and produces PNG', () async {
        // 2x2 RGB image
        final pixels = Uint8List.fromList([
          255, 0, 0, // red
          0, 255, 0, // green
          0, 0, 255, // blue
          255, 255, 0, // yellow
        ]);

        final result = await compressor.compressRgb(
          pixels,
          width: 2,
          height: 2,
        );

        expect(result, isNotEmpty);
        expect(result[0], 0x89); // PNG signature
      });

      test('RGB data is smaller input than RGBA', () async {
        const width = 10;
        const height = 10;
        final rgbPixels = Uint8List(width * height * 3);

        final result = await compressor.compressRgb(
          rgbPixels,
          width: width,
          height: height,
        );

        expect(result, isNotEmpty);
      });
    });

    group('PNG encoding internals', () {
      test('PNG signature is correct', () async {
        final pixels = Uint8List.fromList([0, 0, 0, 255]);
        final png = await compressor.compressRgba(
          pixels,
          width: 1,
          height: 1,
        );

        // PNG magic bytes
        expect(png[0], 0x89);
        expect(png[1], 0x50); // P
        expect(png[2], 0x4E); // N
        expect(png[3], 0x47); // G
        expect(png[4], 0x0D);
        expect(png[5], 0x0A);
        expect(png[6], 0x1A);
        expect(png[7], 0x0A);
      });

      test('IHDR chunk appears before IDAT', () async {
        final pixels = Uint8List.fromList([128, 128, 128, 255]);
        final png = await compressor.compressRgba(
          pixels,
          width: 1,
          height: 1,
        );

        final ihdrPos = _findChunkPosition(png, 'IHDR');
        final idatPos = _findChunkPosition(png, 'IDAT');

        expect(ihdrPos, isNotNull);
        expect(idatPos, isNotNull);
        expect(ihdrPos!, lessThan(idatPos!));
      });

      test('IDAT chunk appears before IEND', () async {
        final pixels = Uint8List.fromList([128, 128, 128, 255]);
        final png = await compressor.compressRgba(
          pixels,
          width: 1,
          height: 1,
        );

        final idatPos = _findChunkPosition(png, 'IDAT');
        final iendPos = _findChunkPosition(png, 'IEND');

        expect(idatPos, isNotNull);
        expect(iendPos, isNotNull);
        expect(idatPos!, lessThan(iendPos!));
      });

      test('all-white image produces valid PNG', () async {
        final pixels = Uint8List(8 * 8 * 4);
        for (int i = 0; i < pixels.length; i++) {
          pixels[i] = 255;
        }

        final result = await compressor.compressRgba(
          pixels,
          width: 8,
          height: 8,
        );

        expect(result[0], 0x89);
        expect(_findChunkType(result, 'IHDR'), isTrue);
        expect(_findChunkType(result, 'IDAT'), isTrue);
        expect(_findChunkType(result, 'IEND'), isTrue);
      });

      test('all-black image produces valid PNG', () async {
        final pixels = Uint8List(8 * 8 * 4);
        // Set alpha to 255
        for (int i = 3; i < pixels.length; i += 4) {
          pixels[i] = 255;
        }

        final result = await compressor.compressRgba(
          pixels,
          width: 8,
          height: 8,
        );

        expect(result[0], 0x89);
        expect(result.length, greaterThan(0));
      });
    });

    group('dispose', () {
      test('dispose completes without error', () async {
        await expectLater(compressor.dispose(), completes);
      });

      test('can call dispose multiple times', () async {
        await compressor.dispose();
        await compressor.dispose();
        // No exception expected
      });
    });
  });
}

// ─── PNG parsing helpers ─────────────────────────────────────────

/// Check if a PNG chunk of the given type exists in the data.
bool _findChunkType(Uint8List png, String chunkType) {
  return _findChunkPosition(png, chunkType) != null;
}

/// Find the byte position of a chunk type in PNG data.
int? _findChunkPosition(Uint8List png, String chunkType) {
  final typeBytes = chunkType.codeUnits;
  // Start after PNG signature (8 bytes)
  int offset = 8;

  while (offset + 8 <= png.length) {
    // Read chunk length (4 bytes big-endian)
    final length = (png[offset] << 24) |
        (png[offset + 1] << 16) |
        (png[offset + 2] << 8) |
        png[offset + 3];

    // Read chunk type (4 bytes)
    if (offset + 8 + length + 4 > png.length) break;

    final ct = String.fromCharCodes([
      png[offset + 4],
      png[offset + 5],
      png[offset + 6],
      png[offset + 7],
    ]);

    if (ct == chunkType) return offset;

    // Move to next chunk: length + type(4) + data(length) + crc(4)
    offset += 12 + length;
  }

  return null;
}
