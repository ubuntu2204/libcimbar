// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';

/// Raw FFI bindings to the libcimbar C API.
///
/// These map 1:1 to the `extern "C"` functions defined in:
/// - `src/lib/cimbar_js/cimbar_js.h`   (encoder)
/// - `src/lib/cimbar_js/cimbar_recv_js.h` (decoder)
///
/// The shared library (`libcimbar.dll` / `libcimbar.so`) must be compiled
/// from the C++ source using the CMake scripts in the `native/` directory.
class CimbarNative {
  final DynamicLibrary _lib;

  // ─── Encoder function typedefs ────────────────────────────────────

  late final int Function(int modeVal, int compression) _configure;
  late final int Function(Pointer<Utf8> filename, int fnsize, int encodeId)
      _initEncode;
  late final int Function() _encodeBufsize;
  late final int Function(Pointer<Uint8> buffer, int size) _encode;
  late final int Function(bool colorBalance) _nextFrame;
  late final int Function(Pointer<Pointer<Uint8>> buff) _getFrameBuff;
  late final int Function() _render;
  late final int Function(int width, int height) _initWindow;
  late final int Function(bool rotate) _rotateWindow;
  late final int Function(int padding) _autoScaleWindow;
  late final double Function() _getAspectRatio;

  // ─── Decoder function typedefs ────────────────────────────────────

  late final int Function(int modeVal) _configureDecode;
  late final int Function() _getBufsize;
  late final int Function() _getDecompressBufsize;
  late final int Function(
    Pointer<Uint8> imgdata,
    int imgw,
    int imgh,
    int format,
    Pointer<Uint8> bufspace,
    int bufsize,
  ) _scanExtractDecode;
  late final int Function(Pointer<Uint8> buffer, int size) _fountainDecode;
  late final int Function(int id) _getFilesize;
  late final int Function(int id, Pointer<Utf8> filename, int fnsize)
      _getFilename;
  late final int Function(int id, Pointer<Uint8> buffer, int size)
      _decompressRead;
  late final int Function(Pointer<Uint8> buff, int maxlen) _getReport;
  late final int Function(Pointer<Uint8> buff, int maxlen) _getDebug;

  /// Whether the native library was loaded successfully.
  final bool isLoaded;

  /// Load the libcimbar shared library and resolve all symbols.
  ///
  /// [libraryPath] allows overriding the default library location.
  /// If null, the platform default is used:
  /// - Windows: `libcimbar.dll`
  /// - Linux: `libcimbar.so`
  /// - macOS: `libcimbar.dylib`
  CimbarNative({String? libraryPath})
      : _lib = _loadLibrary(libraryPath),
        isLoaded = _loadLibrary(libraryPath) != DynamicLibrary.process() {
    if (!isLoaded) return;
    _bindAll();
  }

  static DynamicLibrary _loadLibrary(String? path) {
    try {
      if (path != null) return DynamicLibrary.open(path);
      if (Platform.isWindows) return DynamicLibrary.open('libcimbar.dll');
      if (Platform.isLinux) return DynamicLibrary.open('libcimbar.so');
      if (Platform.isMacOS) return DynamicLibrary.open('libcimbar.dylib');
    } catch (_) {}
    return DynamicLibrary.process(); // fallback, will fail on lookups
  }

  void _bindAll() {
    // ── Encoder ──
    _configure = _lib
        .lookup<NativeFunction<_configure_t>>('cimbare_configure')
        .asFunction();
    _initEncode = _lib
        .lookup<NativeFunction<_init_encode_t>>('cimbare_init_encode')
        .asFunction();
    _encodeBufsize = _lib
        .lookup<NativeFunction<_encode_bufsize_t>>('cimbare_encode_bufsize')
        .asFunction();
    _encode = _lib
        .lookup<NativeFunction<_encode_t>>('cimbare_encode')
        .asFunction();
    _nextFrame = _lib
        .lookup<NativeFunction<_next_frame_t>>('cimbare_next_frame')
        .asFunction();
    _getFrameBuff = _lib
        .lookup<NativeFunction<_get_frame_buff_t>>('cimbare_get_frame_buff')
        .asFunction();
    _render = _lib
        .lookup<NativeFunction<_render_t>>('cimbare_render')
        .asFunction();
    _initWindow = _lib
        .lookup<NativeFunction<_init_window_t>>('cimbare_init_window')
        .asFunction();
    _rotateWindow = _lib
        .lookup<NativeFunction<_rotate_window_t>>('cimbare_rotate_window')
        .asFunction();
    _autoScaleWindow = _lib
        .lookup<NativeFunction<_auto_scale_window_t>>(
            'cimbare_auto_scale_window')
        .asFunction();
    _getAspectRatio = _lib
        .lookup<NativeFunction<_get_aspect_ratio_t>>(
            'cimbare_get_aspect_ratio')
        .asFunction();

    // ── Decoder ──
    _configureDecode = _lib
        .lookup<NativeFunction<_configure_decode_t>>(
            'cimbard_configure_decode')
        .asFunction();
    _getBufsize = _lib
        .lookup<NativeFunction<_get_bufsize_t>>('cimbard_get_bufsize')
        .asFunction();
    _getDecompressBufsize = _lib
        .lookup<NativeFunction<_get_decompress_bufsize_t>>(
            'cimbard_get_decompress_bufsize')
        .asFunction();
    _scanExtractDecode = _lib
        .lookup<NativeFunction<_scan_extract_decode_t>>(
            'cimbard_scan_extract_decode')
        .asFunction();
    _fountainDecode = _lib
        .lookup<NativeFunction<_fountain_decode_t>>(
            'cimbard_fountain_decode')
        .asFunction();
    _getFilesize = _lib
        .lookup<NativeFunction<_get_filesize_t>>('cimbard_get_filesize')
        .asFunction();
    _getFilename = _lib
        .lookup<NativeFunction<_get_filename_t>>('cimbard_get_filename')
        .asFunction();
    _decompressRead = _lib
        .lookup<NativeFunction<_decompress_read_t>>(
            'cimbard_decompress_read')
        .asFunction();
    _getReport = _lib
        .lookup<NativeFunction<_get_report_t>>('cimbard_get_report')
        .asFunction();
    _getDebug = _lib
        .lookup<NativeFunction<_get_debug_t>>('cimbard_get_debug')
        .asFunction();
  }

  // ─── Encoder public API ─────────────────────────────────────────

  /// Configure encoding mode and compression level.
  /// [modeVal]: 68 (modeB), 67 (modeBm), 66 (modeBu), 4/8 (legacy).
  /// [compression]: zstd level 0–22.
  int configure(int modeVal, int compression) =>
      _configure(modeVal, compression);

  /// Initialize encoding for a file.
  /// [encodeId]: 0–127, or -1 for auto-increment.
  int initEncode(String filename, int encodeId) {
    final cFilename = filename.toNativeUtf8();
    try {
      return _initEncode(cFilename, filename.length, encodeId);
    } finally {
      calloc.free(cFilename);
    }
  }

  /// Size of each data chunk expected by [encode] (zstd CHUNK_SIZE = 0x4000).
  int get encodeBufsize => _encodeBufsize();

  /// Feed a chunk of input data.
  /// Call with [size] == 0 to flush remaining data.
  /// Returns: 1 = more data expected, 0 = ready, <0 = error.
  int encode(Pointer<Uint8> buffer, int size) => _encode(buffer, size);

  /// Generate the next cimbar frame.
  /// Returns frame count on success, -1 on error.
  int nextFrame({bool colorBalance = false}) => _nextFrame(colorBalance);

  /// Get a pointer to the raw RGB pixel data of the current frame.
  /// Returns [bufferSize, pointer] or throws on error.
  ({int size, Pointer<Uint8> ptr}) getFrameBuffer() {
    final ptrPtr = calloc<Pointer<Uint8>>();
    try {
      final size = _getFrameBuff(ptrPtr);
      if (size < 0) {
        throw StateError('cimbare_get_frame_buff failed: $size');
      }
      return (size: size, ptr: ptrPtr.value);
    } finally {
      calloc.free(ptrPtr);
    }
  }

  /// Render the current frame to the GLFW window.
  int render() => _render();

  /// Initialize a GLFW window for animated display.
  int initWindow(int width, int height) => _initWindow(width, height);

  int rotateWindow(bool rotate) => _rotateWindow(rotate);
  int autoScaleWindow(int padding) => _autoScaleWindow(padding);
  double getAspectRatio() => _getAspectRatio();

  // ─── Decoder public API ─────────────────────────────────────────

  /// Configure decoding mode. [modeVal] must match the encoder's mode.
  int configureDecode(int modeVal) => _configureDecode(modeVal);

  /// Required buffer size for scan_extract_decode output.
  int get decodeBufsize => _getBufsize();

  /// Required buffer size for decompression output.
  int get decompressBufsize => _getDecompressBufsize();

  /// Decode a single image frame.
  /// [format]: 3=RGB, 4=RGBA, 12=NV12, 420=YUV420p.
  /// Returns bytes written to [bufspace] (>0), or <0 on error.
  int scanExtractDecode(
    Pointer<Uint8> imgdata,
    int imgw,
    int imgh,
    int format,
    Pointer<Uint8> bufspace,
    int bufsize,
  ) =>
      _scanExtractDecode(imgdata, imgw, imgh, format, bufspace, bufsize);

  /// Feed decoded chunks into the fountain decoder.
  /// Returns file_id (>0) when complete, 0 = in progress, <0 = error.
  int fountainDecode(Pointer<Uint8> buffer, int size) =>
      _fountainDecode(buffer, size);

  /// Get the compressed file size for a decoded file.
  int getFilesize(int id) => _getFilesize(id);

  /// Get the original filename for a decoded file.
  String getFilename(int id) {
    final buffer = calloc<Uint8>(256);
    try {
      final len = _getFilename(id, buffer.cast<Utf8>(), 256);
      if (len <= 0) return '';
      return buffer.cast<Utf8>().toDartString(length: len);
    } finally {
      calloc.free(buffer);
    }
  }

  /// Read decompressed data for a decoded file.
  /// Call repeatedly until it returns 0 (done) or <0 (error).
  int decompressRead(int id, Pointer<Uint8> buffer, int size) =>
      _decompressRead(id, buffer, size);

  /// Get a human-readable status report.
  String getReport() {
    final buffer = calloc<Uint8>(4096);
    try {
      final len = _getReport(buffer, 4096);
      if (len <= 0) return '';
      return buffer.cast<Utf8>().toDartString(length: len);
    } finally {
      calloc.free(buffer);
    }
  }

  /// Get debug information.
  String getDebug() {
    final buffer = calloc<Uint8>(4096);
    try {
      final len = _getDebug(buffer, 4096);
      if (len <= 0) return '';
      return buffer.cast<Utf8>().toDartString(length: len);
    } finally {
      calloc.free(buffer);
    }
  }
}

// ─── Native function type definitions ─────────────────────────────

// Encoder
typedef _configure_t = Int32 Function(Int32 modeVal, Int32 compression);
typedef _init_encode_t = Int32 Function(
    Pointer<Utf8> filename, Uint32 fnsize, Int32 encodeId);
typedef _encode_bufsize_t = Int32 Function();
typedef _encode_t = Int32 Function(Pointer<Uint8> buffer, Uint32 size);
typedef _next_frame_t = Int32 Function(Bool colorBalance);
typedef _get_frame_buff_t = Int32 Function(Pointer<Pointer<Uint8>> buff);
typedef _render_t = Int32 Function();
typedef _init_window_t = Int32 Function(Int32 width, Int32 height);
typedef _rotate_window_t = Int32 Function(Bool rotate);
typedef _auto_scale_window_t = Int32 Function(Uint32 padding);
typedef _get_aspect_ratio_t = Float Function();

// Decoder
typedef _configure_decode_t = Int32 Function(Int32 modeVal);
typedef _get_bufsize_t = Int32 Function();
typedef _get_decompress_bufsize_t = Int32 Function();
typedef _scan_extract_decode_t = Int32 Function(
    Pointer<Uint8> imgdata,
    Uint32 imgw,
    Uint32 imgh,
    Int32 format,
    Pointer<Uint8> bufspace,
    Uint32 bufsize);
typedef _fountain_decode_t = Int64 Function(
    Pointer<Uint8> buffer, Uint32 size);
typedef _get_filesize_t = Int32 Function(Uint32 id);
typedef _get_filename_t = Int32 Function(
    Uint32 id, Pointer<Utf8> filename, Uint32 fnsize);
typedef _decompress_read_t = Int32 Function(
    Uint32 id, Pointer<Uint8> buffer, Uint32 size);
typedef _get_report_t = Uint32 Function(
    Pointer<Uint8> buff, Uint32 maxlen);
typedef _get_debug_t = Uint32 Function(
    Pointer<Uint8> buff, Uint32 maxlen);
