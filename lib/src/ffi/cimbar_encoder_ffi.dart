// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../interfaces/cimbar_encoder_interface.dart';
import '../models/cimbar_config.dart';
import '../models/cimbar_frame.dart';
import 'cimbar_bindings.dart';

/// Windows/Linux/macOS cimbar encoder implementation using dart:ffi.
///
/// A faithful port of the official sender flow (`web/send.js` /
/// `src/exe/cimbar_send/send.cpp`): init_encode → encode chunks → next_frame
/// forever. The fountain stream never ends — see [nextFrame].
class CimbarEncoderFfi implements ICimbarEncoder {
  late final CimbarNative _native;
  bool _ready = false;

  /// Reusable native staging buffer for [encodeChunk] (official send.js
  /// keeps one `_compressBuff` for the same reason).
  Pointer<Uint8>? _staging;
  int _stagingSize = 0;

  CimbarEncoderFfi({String? libraryPath}) {
    _native = CimbarNative(libraryPath: libraryPath);
    _ready = _native.isLoaded;
  }

  @override
  bool get isReady => _ready;

  @override
  Future<void> configure(CimbarConfig config) async {
    _checkReady();
    final result = _native.configure(config.modeValue, config.compressionLevel);
    if (result < 0) {
      throw StateError('cimbare_configure failed with code $result');
    }
  }

  @override
  Future<void> initEncodeSession(String filename, {int encodeId = -1}) async {
    _checkReady();
    final result = _native.initEncode(filename, encodeId);
    if (result < 0) {
      throw StateError('cimbare_init_encode failed with code $result');
    }
  }

  @override
  Future<int> encodeChunk(Uint8List chunk) async {
    _checkReady();
    if (chunk.isEmpty) return _encode(null, 0);

    final ptr = _stagingFor(chunk.length);
    ptr.asTypedList(chunk.length).setAll(0, chunk);
    return _encode(ptr, chunk.length);
  }

  @override
  Future<void> finishEncode() async {
    _checkReady();
    // Official send.cpp: `cimbare_encode(nullptr, 0)` is the fallback flush;
    // send.js: "this null call is functionally a flush()".
    final result = _encode(null, 0);
    if (result < 0) {
      throw StateError('cimbare_encode flush failed: $result');
    }
  }

  int _encode(Pointer<Uint8>? ptr, int size) {
    // Official flush passes nullptr (`cimbare_encode(nullptr, 0)`).
    return _native.encode(ptr ?? nullptr, size);
  }

  Pointer<Uint8> _stagingFor(int length) {
    final existing = _staging;
    if (existing != null && _stagingSize >= length) return existing;
    if (existing != null) calloc.free(existing);
    _staging = calloc<Uint8>(length);
    _stagingSize = length;
    return _staging!;
  }

  @override
  Future<CimbarFrame?> nextFrame({bool colorBalance = false}) async {
    _checkReady();

    // Port of the official frame production loop:
    //   - EncoderPlus::encode_fountain(): skip frames that fail the decoder's
    //     own anchor scan ("some % of generated frames ... will produce random
    //     patterns that falsely match as corner anchors"), at most 4 in a row
    //     before emitting anyway — "we gotta make forward progress. And it's
    //     probably a bug?"
    //   - send.js nextFrame(): a null frame just means "keep showing the
    //     current one" (render() returns 0, the loop carries on).
    // The attempt cap is the one thing upstream does not have; it only ever
    // triggers if the native side is misbehaving, and prevents an infinite
    // Dart loop in that case.
    int consecutiveBad = 0;
    int attempts = 0;
    while (true) {
      if (++attempts > 1000) {
        debugPrint('[cimbar-ffi] nextFrame: attempt limit reached');
        return null;
      }

      final frameCount = _native.nextFrame(colorBalance: colorBalance);
      if (frameCount <= 0) return null;

      final scanCheck = _native.willItScan();
      if (scanCheck == 0) {
        if (++consecutiveBad < 5) continue;
        debugPrint('[cimbar-ffi] generated $consecutiveBad bad frames in a '
            'row. This really shouldn\'t happen, maybe report a bug. :(');
      }
      consecutiveBad = 0;

      // Snapshot the frame: the native buffer is reused for the next call.
      final result = _native.getFrameBuffer();
      final size = result.size;
      final ptr = result.ptr;

      // size = width * height * 3 (RGB), default 1024x1024
      final imageSize = size ~/ 3;
      final width = _isqrt(imageSize);
      final height = imageSize ~/ width;

      return CimbarFrame(
        index: frameCount - 1,
        pixels: ptr.asTypedList(size),
        width: width,
        height: height,
      );
    }
  }

  @override
  Future<void> dispose() async {
    _ready = false;
    if (_staging != null) {
      calloc.free(_staging!);
      _staging = null;
    }
    _stagingSize = 0;
  }

  void _checkReady() {
    if (!_ready) {
      final why = CimbarNative.lastLoadError;
      throw StateError(
        'CimbarEncoder is not ready: ${CimbarNative.expectedLibraryName} '
        'could not be loaded${why == null ? '' : ' ($why)'}. On Android it is '
        'bundled inside the package (lib/<abi>/); on desktop it must sit next '
        'to the executable.',
      );
    }
  }

  /// Integer square root.
  int _isqrt(int n) {
    if (n < 0) return 0;
    int x = n;
    int y = (x + 1) >> 1;
    while (y < x) {
      x = y;
      y = (x + n ~/ x) >> 1;
    }
    return x;
  }
}
