import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libcimbar/src/interfaces/cimbar_encoder_interface.dart';
import 'package:libcimbar/src/interfaces/cimbar_decoder_interface.dart';
import 'package:libcimbar/src/interfaces/screen_capture_interface.dart';
import 'package:libcimbar/src/interfaces/camera_capture_interface.dart';
import 'package:libcimbar/src/interfaces/image_compressor_interface.dart';
import 'package:libcimbar/src/models/cimbar_config.dart';
import 'package:libcimbar/src/models/cimbar_frame.dart';
import 'package:libcimbar/src/models/decode_result.dart';

// ─── Mock implementations for interface contract testing ─────────

class MockEncoder implements ICimbarEncoder {
  bool configured = false;
  bool disposed = false;
  final List<Uint8List> encodedData = [];

  @override
  bool get isReady => true;

  @override
  Future<void> configure(CimbarConfig config) async {
    configured = true;
  }

  @override
  Future<List<CimbarFrame>> encodeData(
    Uint8List data, {
    String filename = 'data.bin',
  }) async {
    encodedData.add(data);
    return [
      CimbarFrame(
        index: 0,
        pixels: Uint8List(1024 * 1024 * 3),
        width: 1024,
        height: 1024,
        totalFrames: 1,
      ),
    ];
  }

  @override
  Future<List<CimbarFrame>> encodeFile(String filePath) async {
    return encodeData(Uint8List(0), filename: filePath);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class MockDecoder implements ICimbarDecoder {
  bool configured = false;
  bool disposed = false;
  double _progress = 0.0;
  bool _isComplete = false;

  @override
  bool get isReady => true;

  @override
  double get progress => _progress;

  @override
  bool get isComplete => _isComplete;

  @override
  Future<void> configure(CimbarConfig config) async {
    configured = true;
  }

  @override
  Future<DecodeResult> decodeFrame(
    Uint8List imageData, {
    required int width,
    required int height,
    CimbarImageFormat format = CimbarImageFormat.rgb,
  }) async {
    _progress = 0.5;
    return DecodeResult.inProgress(progress: 0.5, framesDecoded: 1);
  }

  @override
  Future<Uint8List?> recoverFile(int fileId) async {
    _isComplete = true;
    _progress = 1.0;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<String> recoverFilename(int fileId) async {
    return 'test.avif';
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class MockScreenCapture implements IScreenCapture {
  @override
  bool get isSupported => true;

  @override
  Future<ScreenCaptureResult> captureRegion(dynamic region) async {
    return ScreenCaptureResult(
      pixels: Uint8List(100 * 100 * 4),
      width: 100,
      height: 100,
    );
  }

  @override
  Future<ScreenCaptureResult> captureFullScreen() async {
    return ScreenCaptureResult(
      pixels: Uint8List(1920 * 1080 * 4),
      width: 1920,
      height: 1080,
    );
  }

  @override
  Future<void> dispose() async {}
}

class MockCameraCapture implements ICameraCapture {
  CameraFrameCallback? _callback;
  bool _streaming = false;

  @override
  bool get isSupported => true;

  @override
  bool get isStreaming => _streaming;

  @override
  Future<void> start({
    int preferredWidth = 1920,
    int preferredHeight = 1080,
  }) async {
    _streaming = true;
  }

  @override
  void onFrame(CameraFrameCallback callback) {
    _callback = callback;
  }

  @override
  Future<void> stop() async {
    _streaming = false;
    _callback = null;
  }

  @override
  Future<void> dispose() async {
    await stop();
  }

  /// Simulate a frame for testing
  void simulateFrame() {
    _callback?.call(CameraFrame(
      data: Uint8List(1920 * 1080 * 4),
      width: 1920,
      height: 1080,
      format: 'rgba',
      timestampUs: DateTime.now().microsecondsSinceEpoch,
    ));
  }
}

class MockImageCompressor implements IImageCompressor {
  @override
  bool get isAvailable => true;

  @override
  Future<Uint8List> compressRgba(
    Uint8List pixels, {
    required int width,
    required int height,
    CompressionQuality quality = CompressionQuality.balanced,
  }) async {
    // Return a minimal "compressed" result
    return Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
  }

  @override
  Future<Uint8List> compressRgb(
    Uint8List pixels, {
    required int width,
    required int height,
    CompressionQuality quality = CompressionQuality.balanced,
  }) async {
    return Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
  }

  @override
  Future<DecompressedImage> decompress(Uint8List data) async {
    return DecompressedImage(
      pixels: Uint8List(4 * 4 * 4),
      width: 4,
      height: 4,
    );
  }

  @override
  Future<void> dispose() async {}
}

// ─── Tests ───────────────────────────────────────────────────────

void main() {
  group('ICimbarEncoder interface contract', () {
    late MockEncoder encoder;

    setUp(() {
      encoder = MockEncoder();
    });

    test('isReady returns true for mock', () {
      expect(encoder.isReady, isTrue);
    });

    test('configure can be called with any CimbarConfig', () async {
      await encoder.configure(const CimbarConfig());
      expect(encoder.configured, isTrue);
    });

    test('configure can be called with specific mode', () async {
      await encoder.configure(const CimbarConfig(mode: CimbarMode.mode4C));
      expect(encoder.configured, isTrue);
    });

    test('encodeData returns a list of frames', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frames = await encoder.encodeData(data, filename: 'test.bin');

      expect(frames, isNotEmpty);
      expect(frames.first, isA<CimbarFrame>());
    });

    test('encodeData with default filename', () async {
      final data = Uint8List.fromList([1, 2, 3]);
      final frames = await encoder.encodeData(data);

      expect(frames, isNotEmpty);
    });

    test('encodeData with empty data', () async {
      final frames = await encoder.encodeData(Uint8List(0));
      expect(frames, isNotEmpty);
    });

    test('encodeFile delegates to encodeData', () async {
      final frames = await encoder.encodeFile('/path/to/file.avif');
      expect(frames, isNotEmpty);
    });

    test('dispose can be called', () async {
      await encoder.dispose();
      expect(encoder.disposed, isTrue);
    });

    test('full encode workflow', () async {
      await encoder.configure(const CimbarConfig(mode: CimbarMode.modeB));
      final frames = await encoder.encodeData(
        Uint8List.fromList(List.generate(100, (i) => i)),
        filename: 'screenshot.avif',
      );
      expect(frames.length, greaterThan(0));
      await encoder.dispose();

      expect(encoder.configured, isTrue);
      expect(encoder.disposed, isTrue);
      expect(encoder.encodedData.length, 1);
    });
  });

  group('ICimbarDecoder interface contract', () {
    late MockDecoder decoder;

    setUp(() {
      decoder = MockDecoder();
    });

    test('isReady returns true for mock', () {
      expect(decoder.isReady, isTrue);
    });

    test('initial progress is 0.0', () {
      expect(decoder.progress, 0.0);
    });

    test('initial isComplete is false', () {
      expect(decoder.isComplete, isFalse);
    });

    test('configure can be called', () async {
      await decoder.configure(const CimbarConfig());
      expect(decoder.configured, isTrue);
    });

    test('decodeFrame returns in-progress result', () async {
      final imageData = Uint8List(1024 * 1024 * 3);
      final result = await decoder.decodeFrame(
        imageData,
        width: 1024,
        height: 1024,
      );

      expect(result.isComplete, isFalse);
      expect(result.progress, greaterThan(0.0));
    });

    test('decodeFrame with different formats', () async {
      final imageData = Uint8List(100);

      for (final format in CimbarImageFormat.values) {
        final result = await decoder.decodeFrame(
          imageData,
          width: 10,
          height: 10,
          format: format,
        );
        expect(result, isA<DecodeResult>());
      }
    });

    test('recoverFile returns data after decode', () async {
      final data = await decoder.recoverFile(42);
      expect(data, isNotNull);
      expect(data!.length, greaterThan(0));
      expect(decoder.isComplete, isTrue);
    });

    test('recoverFilename returns filename', () async {
      final filename = await decoder.recoverFilename(42);
      expect(filename, isNotEmpty);
    });

    test('dispose can be called', () async {
      await decoder.dispose();
      expect(decoder.disposed, isTrue);
    });

    test('full decode workflow', () async {
      await decoder.configure(const CimbarConfig(mode: CimbarMode.modeB));

      final imageData = Uint8List(1024 * 1024 * 3);
      final result = await decoder.decodeFrame(
        imageData,
        width: 1024,
        height: 1024,
      );

      expect(result, isA<DecodeResult>());
      await decoder.dispose();
      expect(decoder.disposed, isTrue);
    });
  });

  group('IScreenCapture interface contract', () {
    late MockScreenCapture capture;

    setUp(() {
      capture = MockScreenCapture();
    });

    test('isSupported returns true for mock', () {
      expect(capture.isSupported, isTrue);
    });

    test('captureRegion returns ScreenCaptureResult', () async {
      final result = await capture.captureRegion(null);

      expect(result.pixels, isNotEmpty);
      expect(result.width, 100);
      expect(result.height, 100);
      expect(result.stride, 400); // 100 * 4
    });

    test('captureFullScreen returns ScreenCaptureResult', () async {
      final result = await capture.captureFullScreen();

      expect(result.pixels, isNotEmpty);
      expect(result.width, 1920);
      expect(result.height, 1080);
    });

    test('ScreenCaptureResult stride calculation', () {
      final result = ScreenCaptureResult(
        pixels: Uint8List(0),
        width: 256,
        height: 256,
      );

      expect(result.stride, 1024); // 256 * 4
    });

    test('dispose can be called', () async {
      await capture.dispose();
      // No exception means success
    });
  });

  group('ICameraCapture interface contract', () {
    late MockCameraCapture camera;

    setUp(() {
      camera = MockCameraCapture();
    });

    test('isSupported returns true for mock', () {
      expect(camera.isSupported, isTrue);
    });

    test('initial state is not streaming', () {
      expect(camera.isStreaming, isFalse);
    });

    test('start sets streaming state', () async {
      await camera.start();
      expect(camera.isStreaming, isTrue);
    });

    test('start with custom resolution', () async {
      await camera.start(preferredWidth: 3840, preferredHeight: 2160);
      expect(camera.isStreaming, isTrue);
    });

    test('stop clears streaming state', () async {
      await camera.start();
      expect(camera.isStreaming, isTrue);

      await camera.stop();
      expect(camera.isStreaming, isFalse);
    });

    test('onFrame registers callback', () async {
      CameraFrame? receivedFrame;

      camera.onFrame((frame) {
        receivedFrame = frame;
      });

      await camera.start();
      camera.simulateFrame();

      expect(receivedFrame, isNotNull);
      expect(receivedFrame!.width, 1920);
      expect(receivedFrame!.height, 1080);
      expect(receivedFrame!.format, 'rgba');
    });

    test('CameraFrame has correct properties', () {
      final frame = CameraFrame(
        data: Uint8List(100),
        width: 10,
        height: 10,
        format: 'rgb',
        timestampUs: 12345678,
      );

      expect(frame.data.length, 100);
      expect(frame.width, 10);
      expect(frame.height, 10);
      expect(frame.format, 'rgb');
      expect(frame.timestampUs, 12345678);
    });

    test('dispose stops streaming', () async {
      await camera.start();
      await camera.dispose();
      expect(camera.isStreaming, isFalse);
    });
  });

  group('IImageCompressor interface contract', () {
    late MockImageCompressor compressor;

    setUp(() {
      compressor = MockImageCompressor();
    });

    test('isAvailable returns true for mock', () {
      expect(compressor.isAvailable, isTrue);
    });

    test('compressRgba returns compressed data', () async {
      final pixels = Uint8List(4 * 4 * 4); // 4x4 RGBA
      final result = await compressor.compressRgba(
        pixels,
        width: 4,
        height: 4,
      );

      expect(result, isNotEmpty);
    });

    test('compressRgb returns compressed data', () async {
      final pixels = Uint8List(4 * 4 * 3); // 4x4 RGB
      final result = await compressor.compressRgb(
        pixels,
        width: 4,
        height: 4,
      );

      expect(result, isNotEmpty);
    });

    test('compressRgba with quality presets', () async {
      final pixels = Uint8List(4 * 4 * 4);

      for (final quality in CompressionQuality.values) {
        final result = await compressor.compressRgba(
          pixels,
          width: 4,
          height: 4,
          quality: quality,
        );
        expect(result, isNotEmpty);
      }
    });

    test('decompress returns DecompressedImage', () async {
      final compressed = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      final result = await compressor.decompress(compressed);

      expect(result.pixels, isNotEmpty);
      expect(result.width, greaterThan(0));
      expect(result.height, greaterThan(0));
    });

    test('DecompressedImage has correct properties', () {
      final img = DecompressedImage(
        pixels: Uint8List(0),
        width: 100,
        height: 200,
      );

      expect(img.width, 100);
      expect(img.height, 200);
      expect(img.pixels.length, 0);
    });

    test('dispose can be called', () async {
      await compressor.dispose();
      // No exception means success
    });
  });
}
