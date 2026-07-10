// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'interfaces/cimbar_encoder_interface.dart';
import 'interfaces/cimbar_decoder_interface.dart';
import 'interfaces/screen_capture_interface.dart';
import 'interfaces/camera_capture_interface.dart';
import 'interfaces/image_compressor_interface.dart';
import 'models/cimbar_config.dart';
import 'models/decode_result.dart';

import 'impl/avif_compressor.dart';
import 'impl/windows_screen_capture.dart'
    if (dart.library.js_interop) 'web/screen_capture_stub.dart';

// Conditional imports — resolved at compile time:
//   Native (Windows) → FFI implementations
//   Web              → stubs / JS interop implementations
//
// Platform responsibilities:
//   Windows  → Encoder (FFI), Screen Capture (Win32 GDI), Image Compressor
//   Android  → Decoder (MethodChannel/JNI), Camera Capture
//   Web      → Decoder (JS interop/WASM), Camera Capture
import 'ffi/cimbar_encoder_ffi.dart'
    if (dart.library.js_interop) 'web/cimbar_encoder_web.dart';
import 'ffi/cimbar_decoder_ffi.dart'
    if (dart.library.js_interop) 'web/cimbar_decoder_web.dart';

/// Central registry that provides platform-appropriate implementations
/// of all cimbar interfaces.
///
/// ## Platform Responsibilities
///
/// | Feature           | Windows | Android | Web |
/// |-------------------|---------|---------|-----|
/// | Encoder           | FFI     | --      | --  |
/// | Decoder           | --      | JNI     | WASM|
/// | Screen Capture    | Win32   | --      | --  |
/// | Camera Capture    | --      | plugin  | getUserMedia |
/// | Image Compressor  | AVIF    | --      | --  |
///
/// Usage:
/// ```dart
/// // Windows only:
/// final encoder = await CimbarPlatform.instance.createEncoder();
///
/// // Web / Android only:
/// final decoder = await CimbarPlatform.instance.createDecoder();
/// ```
class CimbarPlatform {
  CimbarPlatform._();

  static final CimbarPlatform _instance = CimbarPlatform._();

  /// Singleton access to the platform registry.
  static CimbarPlatform get instance => _instance;

  /// Create a cimbar encoder (Windows only).
  ///
  /// Throws [UnsupportedError] on Web and Android — encoding is
  /// only supported on Windows via FFI to the native libcimbar library.
  Future<ICimbarEncoder> createEncoder() async {
    if (kIsWeb) {
      throw UnsupportedError('Encoding is only supported on Windows.');
    }
    if (Platform.isAndroid) {
      throw UnsupportedError('Encoding is only supported on Windows.');
    }
    // Windows → FFI
    return CimbarEncoderFfi();
  }

  /// Create a cimbar decoder (Web and Android only).
  ///
  /// Throws [UnsupportedError] on Windows — decoding is handled by
  /// the receiving platforms (Web via WASM, Android via JNI).
  Future<ICimbarDecoder> createDecoder() async {
    if (kIsWeb) {
      return CimbarDecoderFfi();
    }
    if (Platform.isAndroid) {
      return _MethodChannelDecoder();
    }
    throw UnsupportedError(
      'Decoding is only supported on Web and Android. '
      'Windows is the encoding platform.',
    );
  }

  /// Create a screen capture implementation (Windows only).
  Future<IScreenCapture> createScreenCapture() async {
    if (kIsWeb) {
      throw UnsupportedError('Screen capture is not available on web.');
    }
    if (Platform.isWindows) {
      return WindowsScreenCapture();
    }
    throw UnsupportedError(
      'Screen capture is only supported on Windows.',
    );
  }

  /// Create a camera capture implementation (Web and Android only).
  Future<ICameraCapture> createCameraCapture() async {
    if (kIsWeb) {
      return _WebCameraCapture();
    }
    if (Platform.isAndroid) {
      return _AndroidCameraCapture();
    }
    throw UnsupportedError(
      'Camera capture is only supported on Web and Android.',
    );
  }

  /// Create an AVIF image compressor (Windows only).
  Future<IImageCompressor> createImageCompressor() async {
    if (kIsWeb) {
      throw UnsupportedError(
        'Image compression is only supported on Windows.',
      );
    }
    return AvifCompressor();
  }
}

// =================================================================
// MethodChannel decoder stub for Android
// =================================================================

class _MethodChannelDecoder implements ICimbarDecoder {
  @override
  bool get isReady => false;

  @override
  double get progress => 0.0;

  @override
  bool get isComplete => false;

  @override
  Future<void> configure(CimbarConfig config) async {
    throw UnimplementedError(
      'Android decoder requires the native JNI library. '
      'Run native/build_android.sh to compile.',
    );
  }

  @override
  Future<DecodeResult> decodeFrame(
    Uint8List imageData, {
    required int width,
    required int height,
    CimbarImageFormat format = CimbarImageFormat.rgb,
  }) async {
    throw UnimplementedError('Android decoder not yet wired up.');
  }

  @override
  Future<Uint8List?> recoverFile(int fileId) async {
    throw UnimplementedError('Android decoder not yet wired up.');
  }

  @override
  Future<String> recoverFilename(int fileId) async {
    throw UnimplementedError('Android decoder not yet wired up.');
  }

  @override
  Future<void> dispose() async {}
}

// =================================================================
// Camera capture stubs (Web + Android)
// =================================================================

class _AndroidCameraCapture implements ICameraCapture {
  @override
  bool get isSupported => true;

  @override
  bool get isStreaming => false;

  @override
  Future<void> start({
    int preferredWidth = 1920,
    int preferredHeight = 1080,
  }) async {
    throw UnimplementedError(
      'Android camera uses the camera plugin. '
      'See example/lib/decoder_page.dart.',
    );
  }

  @override
  void onFrame(CameraFrameCallback callback) {
    throw UnimplementedError('Android camera not yet wired up.');
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _WebCameraCapture implements ICameraCapture {
  @override
  bool get isSupported => true;

  @override
  bool get isStreaming => false;

  @override
  Future<void> start({
    int preferredWidth = 1920,
    int preferredHeight = 1080,
  }) async {
    throw UnimplementedError(
      'Web camera uses getUserMedia. '
      'See example/lib/decoder_page.dart.',
    );
  }

  @override
  void onFrame(CameraFrameCallback callback) {
    throw UnimplementedError('Web camera not yet wired up.');
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
