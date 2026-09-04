// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'interfaces/cimbar_encoder_interface.dart';
import 'interfaces/cimbar_decoder_interface.dart';
import 'interfaces/screen_capture_interface.dart';
import 'interfaces/camera_capture_interface.dart';
import 'interfaces/image_compressor_interface.dart';

import 'impl/avif_compressor.dart';
import 'impl/windows_screen_capture.dart'
    if (dart.library.js_interop) 'web/screen_capture_stub.dart';
import 'native/android_camera_capture.dart'
    if (dart.library.js_interop) 'web/web_camera_capture.dart';

// Conditional imports — resolved at compile time:
//   Native (Windows) → FFI implementations
//   Web              → stubs / JS interop implementations
//
// Platform responsibilities:
//   Windows  → Encoder (FFI), Screen Capture (Win32 GDI), Image Compressor
//   Android  → Decoder (FFI into libcimbar_jni.so), Camera Capture
//   Web      → Decoder (JS interop/WASM), Camera Capture
//
// Android deliberately uses the same FFI path as desktop. The native core is
// identical; only the library name differs. WASM is web-only.
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

  /// Create a cimbar decoder.
  ///
  /// - Web: WASM decoder via JS interop
  /// - Android / Windows / Linux / macOS: native FFI decoder against the
  ///   `cimbard_*` C API. Android loads `libcimbar_jni.so` — the same C++
  ///   core, just packaged for the platform — so every native platform uses
  ///   one code path and one dependency (OpenCV + libcimbar), rather than
  ///   also requiring a WASM build.
  Future<ICimbarDecoder> createDecoder() async {
    if (kIsWeb) {
      return CimbarDecoderFfi();
    }
    if (Platform.isAndroid ||
        Platform.isWindows ||
        Platform.isLinux ||
        Platform.isMacOS) {
      return CimbarDecoderFfi();
    }
    throw UnsupportedError(
      'Decoding is not supported on this platform.',
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
      return WebCameraCapture();
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return AndroidCameraCapture();
    }
    throw UnsupportedError(
      'Camera capture is only supported on Web, Android and iOS.',
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
// Camera capture stubs (Web + Android)
// =================================================================

// (The former `_AndroidCameraCapture` stub is gone — Android/iOS now use
// [AndroidCameraCapture], which is a real implementation on top of the
// `camera` plugin.)
