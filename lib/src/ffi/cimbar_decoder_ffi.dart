// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import '../interfaces/cimbar_decoder_interface.dart';
import '../models/cimbar_config.dart';
import '../models/decode_result.dart';
import '../utils/fountain_progress.dart';
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

  /// Last known per-stream progress from the fountain sink report
  /// (`[ p1,p2,... ]`) — the list cfc's drawProgress renders every frame.
  /// Kept across frames that don't refresh the report (scan misses), so
  /// the bars stay on screen instead of blinking off.
  List<double> _streamProgress = const [];

  /// Mode value applied by the last [configure] — kept so [resetStreams]
  /// can bounce it (see there).
  int _modeVal = 68;

  /// Official Auto mode (recv.js `modeVals` rotation; the glue equivalent
  /// of cfc's modeVal=0, because the cimbard C API clamps
  /// `cimbard_configure_decode(0)` to 68): rotate the scan mode every
  /// frame until one yields payload, then LOCK. Same mechanism, same
  /// place as the official web receiver — in the caller.
  static const List<int> _autoModeVals = [66, 68, 67, 4];
  bool _autoMode = false;
  int _autoCounter = 0;

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

  /// Grow the decode buffer if the (newly configured) mode needs more
  /// than the current allocation — the official Sink.allocate() rule.
  void _ensureDecodeBuffer() {
    final needed = _native.decodeBufsize;
    if (needed > _decodeBufferSize) {
      if (_decodeBuffer != null) calloc.free(_decodeBuffer!);
      _decodeBufferSize = needed;
      _decodeBuffer = calloc<Uint8>(_decodeBufferSize);
    }
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
    _modeVal = modeVal;
    _autoMode = config.autoDetect;
  }

  /// Discard ALL accumulated fountain streams.
  ///
  /// Same rationale as the web decoder: a single corrupt-but-RS-passing
  /// chunk can poison a stream for the rest of the session, and the C
  /// sink is only reset on a mode CHANGE — so bounce to a different mode
  /// and back. Called by the decoder UI when starting a fresh scan.
  Future<void> resetStreams() async {
    _checkReady();
    final bounce = _modeVal == 67 ? 68 : 67;
    _native.configureDecode(bounce);
    _native.configureDecode(_modeVal);
    _progress = 0.0;
    _streamProgress = const [];
  }

  @override
  Future<DecodeResult> decodeFrame(
    Uint8List imageData, {
    required int width,
    required int height,
    CimbarImageFormat format = CimbarImageFormat.rgb,
  }) async {
    _checkReady();

    // Official Auto: rotate the scan mode per frame (recv.js:
    // `mode = _mode || modeVals[_counter % modeVals.length]`).
    // configure_decode applies Config::update and — on change — resets the
    // fountain sink. That reset is harmless pre-lock (a wrong-mode scan
    // never yields payload, so the sink is still empty) and stops
    // happening entirely once the mode locks below.
    int? detectedMode;
    int scanMode = _modeVal;
    if (_autoMode) {
      scanMode = _autoModeVals[_autoCounter++ % _autoModeVals.length];
      _native.configureDecode(scanMode);
      _ensureDecodeBuffer();
    }

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
        return DecodeResult.error(
          'scan_extract_decode failed: $bytesDecoded',
          streamProgress: _streamProgress,
        );
      }

      if (bytesDecoded == 0) {
        return DecodeResult.inProgress(progress: _progress,
            streamProgress: _streamProgress);
      }

      if (_autoMode && bytesDecoded > 0) {
        // First frame with payload locks the mode — recv.js setMode().
        // The scan above already applied it (Config::update), so the sink
        // is created lazily with the detected mode's chunk size.
        _autoMode = false;
        _modeVal = scanMode;
        detectedMode = scanMode;
      }

      // Step 2: Feed decoded chunks into the fountain decoder.
      // scan_extract_decode returns buffers_in_use * fountain_chunk_size,
      // which is already chunk-aligned for the active mode — pass it through
      // verbatim. (A former hardcoded 930-byte alignment corrupted modeB,
      // whose real chunk size is 625: 7500 -> 7440 gets rejected with -5.)
      final fileId = _native.fountainDecode(_decodeBuffer!, bytesDecoded);

      // fountain_decode refreshes the native report with the per-stream
      // progress ("[ p1,p2,... ]") — the same source the official
      // receivers render (recv.js progress bars / cfc drawProgress).
      // A former fake increment (+0.02 per frame, clamped at 0.99) is why
      // the progress bar used to freeze at 99% forever.
      _refreshProgressFromReport();

      if (fileId < 0) {
        return DecodeResult.error(
          'fountain_decode error: $fileId',
          frameBytesDecoded: bytesDecoded,
          frameCapacity: _decodeBufferSize,
          streamProgress: _streamProgress,
        );
      }

      _framesProcessed++;

      if (fileId == 0) {
        // Decode in progress — real progress from the fountain sink.
        return DecodeResult.inProgress(
          progress: _progress,
          framesDecoded: _framesProcessed,
          frameBytesDecoded: bytesDecoded,
          frameCapacity: _decodeBufferSize,
          detectedMode: detectedMode,
          streamProgress: _streamProgress,
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
        detectedMode: detectedMode,
      );
    } finally {
      calloc.free(imgBuffer);
    }
  }

  /// Pull the fountain sink's real per-stream progress out of the native
  /// report and keep the most-complete stream as our headline progress.
  /// Non-bracket report strings (scan diagnostics) leave it untouched.
  void _refreshProgressFromReport() {
    final streams = parseFountainProgress(_native.getReport());
    if (streams.isNotEmpty) {
      _progress = maxFountainProgress(streams);
      _streamProgress = streams;
    }
  }

  @override
  Future<Uint8List?> recoverFile(int fileId) async {    _checkReady();

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
      final why = CimbarNative.lastLoadError;
      throw StateError(
        'CimbarDecoder is not ready: ${CimbarNative.expectedLibraryName} '
        'could not be loaded${why == null ? '' : ' ($why)'}. On Android it is '
        'bundled inside the package (lib/<abi>/); on desktop it must sit next '
        'to the executable.',
      );
    }
  }
}
