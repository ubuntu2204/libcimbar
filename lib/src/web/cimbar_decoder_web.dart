// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../interfaces/cimbar_decoder_interface.dart';
import '../models/cimbar_config.dart';
import '../models/decode_result.dart';
import 'libcimbar_js_interop.dart';

/// Web (Flutter WASM) cimbar decoder using JS interop.
///
/// Calls the Emscripten-compiled libcimbar WASM module to decode
/// cimbar barcode images received from a camera or file upload.
///
/// On web, the conditional import in `cimbar_platform.dart` resolves
/// `CimbarDecoderFfi` to this class. On native platforms, it resolves
/// to the FFI implementation in `ffi/cimbar_decoder_ffi.dart`.
class CimbarDecoderFfi implements ICimbarDecoder {
  bool _ready = false;
  double _progress = 0.0;
  bool _isComplete = false;

  /// WASM heap pointer for the decode buffer.
  int _decodeBufPtr = 0;
  int _decodeBufSize = 0;

  /// WASM heap pointer for the decompress buffer.
  int _decompressBufPtr = 0;
  int _decompressBufSize = 0;

  /// Last diagnostic snapshot (for debugging).
  WasmDiagnostics? diagnostics;

  CimbarDecoderFfi() {
    diagnostics = checkWasmDiagnostics();
    _ready = diagnostics!.ready;
    if (!_ready) {
      // Fallback: also check window.__libcimbarReady directly
      _ready = _isWasmReadyByAnyMeans();
    }
    if (_ready) {
      _allocateBuffers();
    }
  }

  /// Check WASM readiness through multiple detection methods.
  bool _isWasmReadyByAnyMeans() {
    // Method 1: checkWasmDiagnostics (checks window.__libcimbarReady + calledRun)
    try {
      final diag = checkWasmDiagnostics();
      if (diag.ready) return true;
    } catch (_) {}
    // Method 2: check window.__libcimbarReady via JS interop
    try {
      final diag2 = checkWasmDiagnostics();
      if (diag2.ready) return true;
    } catch (_) {}
    // Method 3: check Module.calledRun
    try {
      if (cimbarModule != null && cimbarModule!.calledRun) return true;
    } catch (_) {}
    return false;
  }

  void _allocateBuffers() {
    final module = cimbarModule!;
    _decodeBufSize = jsNumberToInt(cimbardGetBufsize());
    _decodeBufPtr = module.allocate(_decodeBufSize);
    debugPrint('[Decoder] _allocateBuffers: '
        'decodeBufPtr=$_decodeBufPtr (size=$_decodeBufSize), '
        'runtimeType=${_decodeBufPtr.runtimeType}');

    _decompressBufSize = jsNumberToInt(cimbardGetDecompressBufsize());
    _decompressBufPtr = module.allocate(_decompressBufSize);
    debugPrint('[Decoder] _allocateBuffers: '
        'decompressBufPtr=$_decompressBufPtr (size=$_decompressBufSize), '
        'runtimeType=${_decompressBufPtr.runtimeType}');
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
    final result = jsNumberToInt(cimbardConfigureDecode(config.modeValue.toJS));
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
    final module = cimbarModule!;

    // Copy image data to WASM heap
    final imgPtr = module.allocate(imageData.length);
    debugPrint('[Decoder] decodeFrame($width'
        'x$height, fmt=${format.value}, '
        'data=${imageData.length}B): '
        'imgPtr=$imgPtr, _decodeBufPtr=$_decodeBufPtr');
    try {
      copyToWasmHeap(module, imageData, imgPtr);

      // Scan, extract, decode
      final bytesDecoded = jsNumberToInt(cimbardScanExtractDecode(
        imgPtr.toJS,
        width.toJS,
        height.toJS,
        format.value.toJS,
        _decodeBufPtr.toJS,
        _decodeBufSize.toJS,
      ));
      debugPrint('[Decoder] scan_extract_decode => $bytesDecoded '
          '(runtimeType=${bytesDecoded.runtimeType})');

      if (bytesDecoded < 0) {
        debugPrint('[Decoder] scan_extract_decode($width'
            'x$height, fmt=${format.value}, '
            'buf=${imageData.length}B) => $bytesDecoded');
        return DecodeResult.error('scan_extract_decode failed: $bytesDecoded');
      }
      if (bytesDecoded == 0) {
        return DecodeResult.inProgress(progress: _progress);
      }

      // Feed into fountain decoder
      // Align to chunk size
      const chunkSize = 930; // approximate fountain_chunk_size
      final alignedSize = (bytesDecoded ~/ chunkSize) * chunkSize;
      if (alignedSize <= 0) {
        return DecodeResult.inProgress(progress: _progress);
      }

      final fileId = jsNumberToInt(
          cimbardFountainDecode(_decodeBufPtr.toJS, alignedSize.toJS));
      debugPrint('[Decoder] fountain_decode => $fileId '
          '(runtimeType=${fileId.runtimeType})');

      if (fileId < 0) {
        return DecodeResult.error('fountain_decode error: $fileId');
      }
      if (fileId == 0) {
        return DecodeResult.inProgress(progress: _progress);
      }

      // Complete!
      _isComplete = true;
      _progress = 1.0;

      final filename = _recoverFilename(fileId);
      final data = await recoverFile(fileId);

      return DecodeResult.complete(
        fileId: fileId,
        filename: filename,
        data: data ?? Uint8List(0),
      );
    } catch (e, stack) {
      debugPrint('[Decoder] decodeFrame FAILED: $e');
      debugPrint('[Decoder] stack:\n$stack');
      rethrow;
    } finally {
      module.deallocate(imgPtr);
    }
  }

  @override
  Future<Uint8List?> recoverFile(int fileId) async {
    _checkReady();
    final module = cimbarModule!;

    final result = BytesBuilder();

    while (true) {
      final bytesRead = jsNumberToInt(cimbardDecompressRead(
        fileId.toJS,
        _decompressBufPtr.toJS,
        _decompressBufSize.toJS,
      ));
      debugPrint('[Decoder] decompress_read(id=$fileId) => $bytesRead '
          '(runtimeType=${bytesRead.runtimeType})');
      if (bytesRead <= 0) break;

      final chunk = copyFromWasmHeap(module, _decompressBufPtr, bytesRead);
      result.add(chunk);
    }

    final data = result.toBytes();
    return data.isNotEmpty ? data : null;
  }

  @override
  Future<String> recoverFilename(int fileId) async {
    return _recoverFilename(fileId);
  }

  String _recoverFilename(int fileId) {
    _checkReady();
    final module = cimbarModule!;
    final fnPtr = module.allocate(256);
    try {
      final len =
          jsNumberToInt(cimbardGetFilename(fileId.toJS, fnPtr.toJS, 256.toJS));
      debugPrint('[Decoder] get_filename(id=$fileId) => $len '
          '(runtimeType=${len.runtimeType})');
      if (len <= 0) return '';
      final bytes = copyFromWasmHeap(module, fnPtr, len);
      return String.fromCharCodes(bytes);
    } finally {
      module.deallocate(fnPtr);
    }
  }

  @override
  Future<void> dispose() async {
    if (_ready && cimbarModule != null) {
      final module = cimbarModule!;
      if (_decodeBufPtr != 0) module.deallocate(_decodeBufPtr);
      if (_decompressBufPtr != 0) module.deallocate(_decompressBufPtr);
    }
    _ready = false;
  }

  void _checkReady() {
    if (!_ready) {
      // Last chance: re-check readiness via all available methods
      if (_isWasmReadyByAnyMeans()) {
        _ready = true;
        _allocateBuffers();
        return;
      }
      final diag = diagnostics ?? checkWasmDiagnostics();
      throw StateError(
        'Web decoder not ready.\n${diag.toReport()}',
      );
    }
  }
}
