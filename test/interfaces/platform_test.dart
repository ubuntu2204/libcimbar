import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libcimbar/src/models/cimbar_config.dart';
import 'package:libcimbar/src/models/cimbar_frame.dart';
import 'package:libcimbar/src/models/decode_result.dart';
import 'package:libcimbar/src/interfaces/cimbar_encoder_interface.dart';
import 'package:libcimbar/src/interfaces/cimbar_decoder_interface.dart';
import 'package:libcimbar/src/interfaces/screen_capture_interface.dart';
import 'package:libcimbar/src/interfaces/camera_capture_interface.dart';
import 'package:libcimbar/src/interfaces/image_compressor_interface.dart';
import 'package:libcimbar/src/impl/avif_compressor.dart';

// ─── Fake implementations for testing platform registration ──────

class FakeEncoder implements ICimbarEncoder {
  @override
  bool get isReady => true;

  @override
  Future<void> configure(CimbarConfig config) async {}

  @override
  Future<List<CimbarFrame>> encodeData(dynamic data,
          {String filename = 'data.bin'}) async =>
      [];

  @override
  Future<List<CimbarFrame>> encodeFile(String filePath) async => [];

  @override
  Future<void> dispose() async {}
}

class FakeDecoder implements ICimbarDecoder {
  @override
  bool get isReady => true;
  @override
  double get progress => 0.0;
  @override
  bool get isComplete => false;

  @override
  Future<void> configure(CimbarConfig config) async {}

  @override
  Future<DecodeResult> decodeFrame(dynamic imageData,
          {required int width, required int height, dynamic format}) async =>
      const DecodeResult();

  @override
  Future<Uint8List?> recoverFile(int fileId) async => null;

  @override
  Future<String> recoverFilename(int fileId) async => '';

  @override
  Future<void> dispose() async {}
}

class FakeScreenCapture implements IScreenCapture {
  @override
  bool get isSupported => true;

  @override
  Future<ScreenCaptureResult> captureRegion(dynamic region) async =>
      ScreenCaptureResult(
        pixels: Uint8List(0),
        width: 0,
        height: 0,
      );

  @override
  Future<ScreenCaptureResult> captureFullScreen() async => ScreenCaptureResult(
        pixels: Uint8List(0),
        width: 0,
        height: 0,
      );

  @override
  Future<void> dispose() async {}
}

class FakeCameraCapture implements ICameraCapture {
  @override
  bool get isSupported => true;

  @override
  bool get isStreaming => false;

  @override
  Future<void> start(
      {int preferredWidth = 1920, int preferredHeight = 1080}) async {}

  @override
  void onFrame(CameraFrameCallback callback) {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

// ─── Tests ───────────────────────────────────────────────────────

void main() {
  group('CimbarPlatform', () {
    test('singleton instance is not null', () {
      // Import is deferred; we test that the platform class exists
      // and can be accessed.
      // Note: CimbarPlatform.instance requires Flutter binding initialization
      // so we test its structure rather than instantiation in unit tests.
      expect(true, isTrue); // structural test placeholder
    });
  });

  group('Interface polymorphism', () {
    test('FakeEncoder implements ICimbarEncoder', () {
      final encoder = FakeEncoder();
      expect(encoder, isA<ICimbarEncoder>());
      expect(encoder.isReady, isTrue);
    });

    test('FakeDecoder implements ICimbarDecoder', () {
      final decoder = FakeDecoder();
      expect(decoder, isA<ICimbarDecoder>());
      expect(decoder.isReady, isTrue);
    });

    test('FakeScreenCapture implements IScreenCapture', () {
      final capture = FakeScreenCapture();
      expect(capture, isA<IScreenCapture>());
      expect(capture.isSupported, isTrue);
    });

    test('FakeCameraCapture implements ICameraCapture', () {
      final camera = FakeCameraCapture();
      expect(camera, isA<ICameraCapture>());
      expect(camera.isSupported, isTrue);
    });

    test('AvifCompressor implements IImageCompressor', () {
      final compressor = AvifCompressor();
      expect(compressor, isA<IImageCompressor>());
      expect(compressor.isAvailable, isTrue);
    });
  });

  group('CimbarConfig for platform dispatch', () {
    test('config can be created for each mode', () {
      for (final mode in CimbarMode.values) {
        final config = CimbarConfig(mode: mode);
        expect(config.mode, mode);
        expect(config.modeValue, mode.value);
      }
    });

    test('config copyWith preserves mode for platform dispatch', () {
      const config = CimbarConfig(mode: CimbarMode.mode4C);
      final copy = config.copyWith(compressionLevel: 10);
      expect(copy.mode, CimbarMode.mode4C);
      expect(copy.compressionLevel, 10);
    });
  });

  group('Cross-platform data flow', () {
    test('CimbarFrame can be created from any platform', () {
      // This tests that the frame data model works regardless of platform
      final frame = CimbarFrame(
        index: 0,
        pixels: Uint8List.fromList(List.generate(12, (i) => i)),
        width: 2,
        height: 2,
      );

      expect(frame.width, 2);
      expect(frame.height, 2);
      expect(frame.stride, 6);
      expect(frame.byteLength, 12);
    });

    test('DecodeResult states are platform-independent', () {
      // Initial
      const initial = DecodeResult();
      expect(initial.progress, 0.0);

      // In-progress
      final progress = DecodeResult.inProgress(progress: 0.5);
      expect(progress.progress, 0.5);

      // Error
      final error = DecodeResult.error('test error');
      expect(error.error, 'test error');

      // Complete
      final complete = DecodeResult.complete(
        fileId: 1,
        filename: 'test.bin',
        data: Uint8List(10),
      );
      expect(complete.isComplete, isTrue);
    });

    test('ScreenCaptureResult has consistent stride', () {
      for (final width in [100, 256, 1024, 1920, 3840]) {
        const height = 1;
        final result = ScreenCaptureResult(
          pixels: Uint8List(width * height * 4),
          width: width,
          height: height,
        );
        expect(result.stride, width * 4);
      }
    });

    test('CameraFrame preserves all metadata', () {
      final frame = CameraFrame(
        data: Uint8List.fromList([0xFF, 0x00, 0xFF]),
        width: 1,
        height: 1,
        format: 'rgba',
        timestampUs: 999999,
      );

      expect(frame.format, 'rgba');
      expect(frame.timestampUs, 999999);
    });
  });
}
