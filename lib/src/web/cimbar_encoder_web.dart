// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:js_interop';
import 'dart:typed_data';

import '../interfaces/cimbar_encoder_interface.dart';
import '../models/cimbar_config.dart';
import '../models/cimbar_frame.dart';
import 'libcimbar_js_interop.dart';

/// Web (Flutter WASM) cimbar encoder using JS interop.
///
/// Calls the Emscripten-compiled libcimbar WASM module via
/// [libcimbar_js_interop.dart] bindings.
///
/// ## Prerequisites
///
/// The WASM module (`libcimbar.js` + `libcimbar.wasm`) must be loaded
/// before using this encoder. Add to your `web/index.html`:
///
/// ```html
/// <script src="assets/wasm/libcimbar.js"></script>
/// ```
class CimbarEncoderWeb implements ICimbarEncoder {
  bool _ready = false;

  CimbarEncoderWeb() {
    _ready = cimbarModule != null && cimbarModule!.calledRun;
  }

  @override
  bool get isReady => _ready;

  @override
  Future<void> configure(CimbarConfig config) async {
    _checkReady();
    final result = cimbareConfigure(config.modeValue, config.compressionLevel);
    if (result < 0) {
      throw StateError('cimbare_configure failed: $result');
    }
  }

  @override
  Future<List<CimbarFrame>> encodeData(
    Uint8List data, {
    String filename = 'data.bin',
  }) async {
    _checkReady();
    final module = cimbarModule!;

    // Encode filename into WASM heap
    final fnBytes = Uint8List.fromList(filename.codeUnits);
    final fnPtr = module.malloc(fnBytes.length + 1);
    copyToWasmHeap(module, fnBytes, fnPtr);
    // Null-terminate
    module.heapU8.toDart[fnPtr + fnBytes.length] = 0;

    // Init encode
    final initResult = cimbareInitEncode(fnPtr, fnBytes.length, -1);
    module.free(fnPtr);
    if (initResult < 0) {
      throw StateError('cimbare_init_encode failed: $initResult');
    }

    // Feed data in chunks
    final chunkSize = cimbareEncodeBufsize();
    final bufPtr = module.malloc(chunkSize);

    try {
      int offset = 0;
      while (offset < data.length) {
        final remaining = data.length - offset;
        final copyLen = remaining < chunkSize ? remaining : chunkSize;
        copyToWasmHeap(module, data.sublist(offset, offset + copyLen), bufPtr);

        final result = cimbareEncode(bufPtr, copyLen);
        if (result < 0) {
          throw StateError('cimbare_encode failed at offset $offset');
        }
        offset += copyLen;
      }

      // Flush
      final flushResult = cimbareEncode(bufPtr, 0);
      if (flushResult < 0) {
        throw StateError('cimbare_encode flush failed');
      }
    } finally {
      module.free(bufPtr);
    }

    // Extract frames
    final frames = <CimbarFrame>[];
    final buffPtrPtr = module.malloc(4); // pointer to pointer

    try {
      int frameIndex = 0;
      while (true) {
        final frameCount = cimbareNextFrame(false);
        if (frameCount <= 0) break;

        final size = cimbareGetFrameBuff(buffPtrPtr);
        if (size < 0) break;

        // Read the frame pointer from WASM memory
        final heap = module.heapU8.toDart;
        final framePtr = heap[buffPtrPtr] |
            (heap[buffPtrPtr + 1] << 8) |
            (heap[buffPtrPtr + 2] << 16) |
            (heap[buffPtrPtr + 3] << 24);

        final pixels = copyFromWasmHeap(module, framePtr, size);
        final imageSize = size ~/ 3;
        final width = _isqrt(imageSize);
        final height = imageSize ~/ width;

        frames.add(CimbarFrame(
          index: frameIndex++,
          pixels: pixels,
          width: width,
          height: height,
          totalFrames: frameCount > 0 ? frameCount : null,
        ));

        if (frameIndex > 10000) break;
      }
    } finally {
      module.free(buffPtrPtr);
    }

    return frames;
  }

  @override
  Future<List<CimbarFrame>> encodeFile(String filePath) async {
    throw UnsupportedError(
      'encodeFile is not supported on web. Use encodeData with file bytes.',
    );
  }

  @override
  Future<void> dispose() async {
    _ready = false;
  }

  void _checkReady() {
    if (!_ready) {
      throw StateError(
        'Web encoder not ready. Ensure libcimbar.js is loaded in index.html.',
      );
    }
  }

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
