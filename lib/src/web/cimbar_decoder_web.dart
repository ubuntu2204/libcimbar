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

  /// Per-frame decode telemetry (readable by the app for reports):
  /// bytes returned by the last scan, the last fountain_decode result, and
  /// the native per-stream accumulation progress ("[ n, m, ... ]").
  int lastScanBytes = 0;
  int lastFountainResult = 0;
  String lastFountainProgress = '';

  /// Current WASM linear-memory size in bytes (for reports).
  int get heapBytes {
    try {
      return cimbarModule!.heapU8.toDart.length;
    } catch (_) {
      return 0;
    }
  }

  /// Size of the native decode buffer (chunks_per_frame x chunk_size).
  int get decodeBufSize => _decodeBufSize;

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
    // Same sink-reset dance as the FFI decoder: the WASM module's
    // cimbard_configure_decode only resets its fountain state when the
    // mode value CHANGES (see cimbar_recv_js.cpp). Without the toggle, a
    // second decode session in the same page fails with -1 on every frame.
    final modeVal = config.modeValue;
    final toggleVal = modeVal == 4 ? 68 : 4;
    jsNumberToInt(cimbardConfigureDecode(toggleVal.toJS));
    final result = jsNumberToInt(cimbardConfigureDecode(modeVal.toJS));
    if (result < 0) {
      throw StateError('cimbard_configure_decode failed: $result');
    }
    _modeVal = config.modeValue;
  }

  /// Active mode value (for [resetStreams]'s bounce trick).
  int _modeVal = 68;

  /// Discard ALL accumulated fountain streams.
  ///
  /// Needed because a single corrupt-but-RS-passing chunk (e.g. from a bad
  /// camera frame of the same barcode) permanently poisons the wirehair
  /// codec for that stream AND marks its block id as seen, so later good
  /// copies are ignored — accum grows past 1.0 but never assembles.
  /// cimbard_configure_decode only resets the sink on a mode CHANGE, so
  /// bounce to a different mode and back.
  Future<void> resetStreams() async {
    _checkReady();
    final bounce = _modeVal == 67 ? 68 : 67;
    cimbardConfigureDecode(bounce.toJS);
    cimbardConfigureDecode(_modeVal.toJS);
    debugPrint('[Decoder] fountain streams reset (mode bounce '
        '$_modeVal->$bounce->$_modeVal)');
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

      if (bytesDecoded < 0) {
        lastScanBytes = bytesDecoded;
        // Pull the native diagnostic (anchor counts, brightness/contrast) so
        // the *reason* for the failure is visible, not just the error code.
        //  -1 = bad image dims, -2 = decode buffer too small,
        //  -3 = fewer than 4 corner anchors found (barcode not located).
        final report = _readReport();
        _diag('scan_extract_decode => $bytesDecoded '
            '(${width}x$height, fmt=${format.value}, ${imageData.length}B) — '
            '$report');
        return DecodeResult.error(
            'scan_extract_decode failed: $bytesDecoded — $report');
      }
      if (bytesDecoded == 0) {
        lastScanBytes = 0;
        // Barcode located but no payload recovered from this frame yet.
        _diag('scan_extract_decode => 0 bytes (anchors found, no payload) — '
            '${_readReport()}');
        return DecodeResult.inProgress(progress: _progress);
      }
      _diag('scan_extract_decode => $bytesDecoded bytes — ${_readReport()}',
          force: true);

      // Feed into the fountain decoder. scan_extract_decode returns
      // buffers_in_use * fountain_chunk_size, i.e. the value is ALREADY
      // chunk-aligned for the active mode — pass it through verbatim.
      //
      // (A former hardcoded 930-byte "alignment" was wrong for modeB, whose
      // real chunk is 625 (frame = 12 x 625 = 7500): it truncated 7500 -> 7440,
      // which cimbard_fountain_decode rejects outright (-5) — so decode
      // progress stayed at 0% forever even on pristine frames.)
      lastScanBytes = bytesDecoded;
      final fileId = jsNumberToInt(
          cimbardFountainDecode(_decodeBufPtr.toJS, bytesDecoded.toJS));
      lastFountainResult = fileId;
      // fountain_decode refreshes the native report with the per-stream
      // chunk-accumulation list — capture it for diagnostics.
      lastFountainProgress = _readReport();
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

  // Throttle diagnostic logging so a live camera stream (many fps) does not
  // flood the console with the same failure. Successful/complete decodes pass
  // force:true so they are always logged.
  DateTime _lastDiagLog = DateTime.fromMillisecondsSinceEpoch(0);

  void _diag(String msg, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastDiagLog).inMilliseconds < 1000) return;
    _lastDiagLog = now;
    debugPrint('[Decoder] $msg');
  }

  /// Read the native decoder's latest diagnostic report (populated by
  /// `cimbard_scan_extract_decode`). Includes anchor counts and image
  /// brightness/contrast stats, e.g. "scan FAIL: found 0 anchor(s) ...".
  /// Returns '' if unavailable.
  String _readReport() {
    final module = cimbarModule;
    if (module == null) return '';
    const maxLen = 512;
    final ptr = module.allocate(maxLen);
    try {
      final len = jsNumberToInt(cimbardGetReport(ptr.toJS, maxLen.toJS));
      if (len <= 0) return '';
      final bytes = copyFromWasmHeap(module, ptr, len);
      return String.fromCharCodes(bytes);
    } catch (e) {
      return '(report unavailable: $e)';
    } finally {
      module.deallocate(ptr);
    }
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
