// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi';
import 'dart:io' show File, Platform;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../interfaces/cimbar_encoder_interface.dart';
import '../models/cimbar_config.dart';
import '../models/cimbar_frame.dart';
import 'cimbar_bindings.dart';

/// Windows/Linux/macOS cimbar encoder implementation using dart:ffi.
///
/// Calls the native libcimbar C API (`cimbare_*` functions) directly.
/// Requires `libcimbar.dll` / `libcimbar.so` / `libcimbar.dylib` to be
/// compiled and placed in the appropriate library search path.
class CimbarEncoderFfi implements ICimbarEncoder {
  late final CimbarNative _native;
  bool _ready = false;

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
  Future<List<CimbarFrame>> encodeData(
    Uint8List data, {
    String filename = 'data.bin',
  }) async {
    _checkReady();

    // Step 1: Initialize encoding session
    final initResult = _native.initEncode(filename, -1);
    if (initResult < 0) {
      throw StateError('cimbare_init_encode failed with code $initResult');
    }

    final chunkSize = _native.encodeBufsize;
    final frames = <CimbarFrame>[];

    // Step 2: Feed data in chunks
    final nativeBuffer = calloc<Uint8>(chunkSize);
    try {
      int offset = 0;
      while (offset < data.length) {
        final remaining = data.length - offset;
        final copyLen = remaining < chunkSize ? remaining : chunkSize;

        // Copy chunk to native buffer
        final src =
            data.buffer.asUint8List(data.offsetInBytes + offset, copyLen);
        nativeBuffer.asTypedList(chunkSize).setRange(0, copyLen, src);

        final result = _native.encode(nativeBuffer, copyLen);
        if (result < 0) {
          throw StateError('cimbare_encode failed at offset $offset: $result');
        }
        offset += copyLen;
      }

      // Flush remaining data
      final flushResult = _native.encode(nativeBuffer, 0);
      if (flushResult < 0) {
        throw StateError('cimbare_encode flush failed: $flushResult');
      }
    } finally {
      calloc.free(nativeBuffer);
    }

    // Step 3: Extract all generated frames
    int frameIndex = 0;
    debugPrint('[cimbar-ffi] Collecting frames...');
    while (true) {
      final frameCount = _native.nextFrame();
      debugPrint('[cimbar-ffi] nextFrame returned: $frameCount');
      if (frameCount <= 0) break;

      final result = _native.getFrameBuffer();
      final size = result.size;
      final ptr = result.ptr;

      // size = width * height * 3 (RGB), default 1024x1024
      final imageSize = size ~/ 3;
      final width = _isqrt(imageSize);
      final height = imageSize ~/ width;

      // Efficient bulk copy via asTypedList (creates a view, then copies)
      final pixels = Uint8List.fromList(ptr.asTypedList(size));

      frames.add(CimbarFrame(
        index: frameIndex++,
        pixels: pixels,
        width: width,
        height: height,
        totalFrames: frameCount > 0 ? frameCount : null,
      ));

      if (frameIndex % 10 == 0) {
        debugPrint('[cimbar-ffi] Collected $frameIndex frames...');
      }

      // Safety: don't loop forever
      if (frameIndex > 500) break;
    }
    debugPrint('[cimbar-ffi] Done: ${frames.length} frames collected');

    return frames;
  }

  @override
  Future<List<CimbarFrame>> encodeFile(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final filename = filePath.split(Platform.pathSeparator).last;
    return encodeData(bytes, filename: filename);
  }

  @override
  Future<void> dispose() async {
    _ready = false;
  }

  void _checkReady() {
    if (!_ready) {
      throw StateError(
        'CimbarEncoder is not ready. '
        'Make sure libcimbar.dll is compiled and accessible.',
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
