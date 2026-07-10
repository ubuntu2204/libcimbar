import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libcimbar/src/models/decode_result.dart';

void main() {
  group('DecodeResult', () {
    test('default constructor creates empty result', () {
      const result = DecodeResult();

      expect(result.fileId, isNull);
      expect(result.filename, '');
      expect(result.data, isNull);
      expect(result.progress, 0.0);
      expect(result.isComplete, isFalse);
      expect(result.error, isNull);
      expect(result.framesDecoded, 0);
      expect(result.estimatedTotalFrames, isNull);
    });

    test('constructor with all fields set', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final result = DecodeResult(
        fileId: 42,
        filename: 'test.avif',
        data: data,
        progress: 0.75,
        isComplete: true,
        framesDecoded: 15,
        estimatedTotalFrames: 20,
      );

      expect(result.fileId, 42);
      expect(result.filename, 'test.avif');
      expect(result.data, data);
      expect(result.progress, 0.75);
      expect(result.isComplete, isTrue);
      expect(result.error, isNull);
      expect(result.framesDecoded, 15);
      expect(result.estimatedTotalFrames, 20);
    });

    group('error factory', () {
      test('creates error result with message', () {
        final result = DecodeResult.error('something went wrong');

        expect(result.error, 'something went wrong');
        expect(result.progress, 0.0);
        expect(result.isComplete, isFalse);
        expect(result.fileId, isNull);
        expect(result.data, isNull);
        expect(result.filename, '');
      });

      test('creates error result with empty message', () {
        final result = DecodeResult.error('');

        expect(result.error, '');
        expect(result.isComplete, isFalse);
      });
    });

    group('inProgress factory', () {
      test('creates progress result with required fields', () {
        final result = DecodeResult.inProgress(progress: 0.5);

        expect(result.progress, 0.5);
        expect(result.isComplete, isFalse);
        expect(result.fileId, isNull);
        expect(result.data, isNull);
        expect(result.error, isNull);
        expect(result.framesDecoded, 0);
      });

      test('creates progress result with all optional fields', () {
        final result = DecodeResult.inProgress(
          progress: 0.33,
          framesDecoded: 5,
          estimatedTotalFrames: 15,
        );

        expect(result.progress, 0.33);
        expect(result.framesDecoded, 5);
        expect(result.estimatedTotalFrames, 15);
      });

      test('progress at 0.0', () {
        final result = DecodeResult.inProgress(progress: 0.0);
        expect(result.progress, 0.0);
      });

      test('progress at 0.99 (not yet complete)', () {
        final result = DecodeResult.inProgress(progress: 0.99);
        expect(result.progress, 0.99);
        expect(result.isComplete, isFalse);
      });
    });

    group('complete factory', () {
      test('creates complete result with all fields', () {
        final data = Uint8List.fromList([10, 20, 30]);
        final result = DecodeResult.complete(
          fileId: 100,
          filename: 'photo.avif',
          data: data,
          framesDecoded: 25,
        );

        expect(result.fileId, 100);
        expect(result.filename, 'photo.avif');
        expect(result.data, data);
        expect(result.data!.length, 3);
        expect(result.progress, 1.0);
        expect(result.isComplete, isTrue);
        expect(result.error, isNull);
        expect(result.framesDecoded, 25);
      });

      test('complete result has progress 1.0', () {
        final result = DecodeResult.complete(
          fileId: 1,
          filename: 'test.bin',
          data: Uint8List(0),
        );

        expect(result.progress, 1.0);
        expect(result.isComplete, isTrue);
      });

      test('complete result with empty data', () {
        final result = DecodeResult.complete(
          fileId: 1,
          filename: 'empty.bin',
          data: Uint8List(0),
        );

        expect(result.data!.isEmpty, isTrue);
        expect(result.isComplete, isTrue);
      });

      test('complete result with empty filename', () {
        final result = DecodeResult.complete(
          fileId: 1,
          filename: '',
          data: Uint8List.fromList([1]),
        );

        expect(result.filename, '');
        expect(result.isComplete, isTrue);
      });
    });

    group('toString', () {
      test('completed result shows filename, size and frame count', () {
        final result = DecodeResult.complete(
          fileId: 1,
          filename: 'test.avif',
          data: Uint8List(1024),
          framesDecoded: 10,
        );

        final str = result.toString();
        expect(str, contains('complete'));
        expect(str, contains('test.avif'));
        expect(str, contains('1024 bytes'));
        expect(str, contains('10 frames'));
      });

      test('error result shows error message', () {
        final result = DecodeResult.error('decode failed');

        final str = result.toString();
        expect(str, contains('error'));
        expect(str, contains('decode failed'));
      });

      test('in-progress result shows percentage and frame count', () {
        final result = DecodeResult.inProgress(
          progress: 0.456,
          framesDecoded: 7,
        );

        final str = result.toString();
        expect(str, contains('45.6%'));
        expect(str, contains('7 frames'));
      });

      test('zero progress shows 0.0%', () {
        final result = DecodeResult.inProgress(progress: 0.0);

        final str = result.toString();
        expect(str, contains('0.0%'));
      });

      test('near-complete progress shows correct percentage', () {
        final result = DecodeResult.inProgress(progress: 0.999);

        final str = result.toString();
        expect(str, contains('99.9%'));
      });
    });

    group('state transitions', () {
      test('result can represent initial state', () {
        const result = DecodeResult();

        expect(result.progress, 0.0);
        expect(result.isComplete, isFalse);
        expect(result.error, isNull);
      });

      test('result can represent mid-decode state', () {
        final result = DecodeResult.inProgress(
          progress: 0.5,
          framesDecoded: 5,
          estimatedTotalFrames: 10,
        );

        expect(result.progress, 0.5);
        expect(result.isComplete, isFalse);
        expect(result.error, isNull);
      });

      test('result can represent error state', () {
        final result = DecodeResult.error('fountain decode failed');

        expect(result.isComplete, isFalse);
        expect(result.error, isNotNull);
      });

      test('result can represent completion state', () {
        final result = DecodeResult.complete(
          fileId: 42,
          filename: 'output.avif',
          data: Uint8List.fromList([1, 2, 3]),
          framesDecoded: 20,
        );

        expect(result.isComplete, isTrue);
        expect(result.progress, 1.0);
        expect(result.data, isNotNull);
      });
    });
  });
}
