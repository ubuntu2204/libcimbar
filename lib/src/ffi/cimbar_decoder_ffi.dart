// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import '../interfaces/cimbar_decoder_interface.dart';
import '../models/cimbar_config.dart';
import '../models/decode_result.dart';
import 'cimbar_bindings.dart';

/// Windows/Linux/macOS cimbar decoder implementation using dart:ffi.
///
/// Calls the native libcimbar C API (`cimbard_*` functions) directly.
class CimbarDecoderFfi implements ICimbarDecoder {
  late final CimbarNative _native;
  bool _ready = false;
  double _progress = 0.0;
  bool _isComplete = false;
  int _framesProcessed = 0;

  /// Pre-allocated decode buffer (sized by cimbard_get_bufsize).
  Pointer<Uint8>? _decodeBuffer;
  int _decodeBufferSize = 0;

  /// Pre-allocated decompress buffer.
  Pointer<Uint8>? _decompressBuffer;
  int _decompressBufferSize = 0;

  CimbarDecoderFfi({String? libraryPath}) {
    _native = CimbarNative(libraryPath: libraryPath);
    _ready = _native.isLoaded;
    if (_ready) {
      _allocateBuffers();
    }
  }

  void _allocateBuffers() {
    _decodeBufferSize = _native.decodeBufsize;
    _decodeBuffer = calloc<Uint8>(_decodeBufferSize);

    _decompressBufferSize = _native.decompressBufsize;
    _decompressBuffer = calloc<Uint8>(_decompressBufferSize);
  }

  @override
  bool get isReady => _ready;

  @override
  double get progress => _progress;

  @override
  bool get isComplete => _isComplete;

  @override
  Future<void> configure(CimbarConfig config) async {
    _checkReady();
    // Force-reset the process-global fountain sink. The C implementation
    // (cimbar_recv_js.cpp) only refreshes its static `_sink` when the mode
    // value CHANGES — re-configuring with the same mode leaves a completed
    // stream in place and every subsequent fountain_decode returns -1.
    // Toggling to a different mode value and back triggers two refreshes,
    // guaranteeing a clean sink for each new decode session.
    final modeVal = config.modeValue;
    final toggleVal = modeVal == 4 ? 68 : 4;
    _native.configureDecode(toggleVal);
    final result = _native.configureDecode(modeVal);
    if (result < 0) {
      throw StateError('cimbard_configure_decode failed: $result');
    }
  }

  @override
  Future<DecodeResult> decodeFrame(
    Uint8List imageData, {
    required int width,
    required int height,
    CimbarImageFormat format = CimbarImageFormat.rgb,
  }) async {
    _checkReady();

    // Copy image data to native buffer
    final imgBuffer = calloc<Uint8>(imageData.length);
    try {
      imgBuffer
          .asTypedList(imageData.length)
          .setRange(0, imageData.length, imageData);

      // Step 1: Scan, extract, and decode the barcode image
      final bytesDecoded = _native.scanExtractDecode(
        imgBuffer,
        width,
        height,
        format.value,
        _decodeBuffer!,
        _decodeBufferSize,
      );

      if (bytesDecoded < 0) {
        return DecodeResult.error('scan_extract_decode failed: $bytesDecoded');
      }

      if (bytesDecoded == 0) {
        return DecodeResult.inProgress(progress: _progress);
      }

      // Step 2: Feed decoded chunks into the fountain decoder.
      // scan_extract_decode returns buffers_in_use * fountain_chunk_size,
      // which is already chunk-aligned for the active mode — pass it through
      // verbatim. (A former hardcoded 930-byte alignment corrupted modeB,
      // whose real chunk size is 625: 7500 -> 7440 gets rejected with -5.)
      final fileId = _native.fountainDecode(_decodeBuffer!, bytesDecoded);

      if (fileId < 0) {
        return DecodeResult.error('fountain_decode error: $fileId');
      }

      _framesProcessed++;

      if (fileId == 0) {
        // Decode in progress — update rough estimate
        _progress = (_progress + 0.02).clamp(0.0, 0.99);
        return DecodeResult.inProgress(
          progress: _progress,
          framesDecoded: _framesProcessed,
        );
      }

      // Decode complete!
      _isComplete = true;
      _progress = 1.0;

      final filename = _native.getFilename(fileId);
      final data = await recoverFile(fileId);

      return DecodeResult.complete(
        fileId: fileId,
        filename: filename,
        data: data ?? Uint8List(0),
        framesDecoded: _framesProcessed,
      );
    } finally {
      calloc.free(imgBuffer);
    }
  }

  @override
  Future<Uint8List?> recoverFile(int fileId) async {
    _checkReady();

    final result = BytesBuilder();

    while (true) {
      final bytesRead = _native.decompressRead(
        fileId,
        _decompressBuffer!,
        _decompressBufferSize,
      );

      if (bytesRead <= 0) break;

      final chunk = Uint8List(bytesRead);
      for (int i = 0; i < bytesRead; i++) {
        chunk[i] = _decompressBuffer![i];
      }
      result.add(chunk);
    }

    final data = result.toBytes();
    return data.isNotEmpty ? data : null;
  }

  @override
  Future<String> recoverFilename(int fileId) async {
    _checkReady();
    return _native.getFilename(fileId);
  }

  @override
  Future<void> dispose() async {
    if (_decodeBuffer != null) {
      calloc.free(_decodeBuffer!);
      _decodeBuffer = null;
    }
    if (_decompressBuffer != null) {
      calloc.free(_decompressBuffer!);
      _decompressBuffer = null;
    }
    _ready = false;
  }

  void _checkReady() {
    if (!_ready) {
      throw StateError(
        'CimbarDecoder is not ready. '
        'Make sure libcimbar.dll is compiled and accessible.',
      );
    }
  }
}
