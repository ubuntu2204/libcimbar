// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

@JS()
library libcimbar_web;

import 'dart:js_interop';
import 'dart:typed_data';

/// JS interop declarations for the libcimbar WASM module.
///
/// The WASM module is compiled from libcimbar C++ using Emscripten.
/// These declarations map to the `extern "C"` functions in:
/// - `cimbar_js.h` (encoder: `cimbare_*`)
/// - `cimbar_recv_js.h` (decoder: `cimbard_*`)
///
/// ## Setup
///
/// Before using these bindings, ensure the WASM module is loaded:
/// ```dart
/// await loadLibcimbarWasm('/assets/wasm/libcimbar.js');
/// ```

// ─── Module loading ──────────────────────────────────────────────

@JS('Module')
external CimbarModule? get cimbarModule;

/// The Emscripten Module object exposed by the WASM build.
@JS()
@staticInterop
class CimbarModule {
  external factory CimbarModule();

  /// Whether the WASM runtime has finished initializing.
  @JS('calledRun')
  external bool get calledRun;

  /// The HTML canvas element used for WebGL rendering (encoder only).
  @JS('canvas')
  external JSAny? get canvas;

  /// Allocate bytes in the WASM heap and return the pointer.
  @JS('_malloc')
  external int malloc(int size);

  /// Free previously allocated WASM heap memory.
  @JS('_free')
  external void free(int ptr);

  /// Access the WASM HEAPU8 (Uint8Array) for reading/writing memory.
  @JS('HEAPU8')
  external JSUint8Array get heapU8;
}

// ─── Encoder functions ───────────────────────────────────────────

@JS('Module._cimbare_configure')
external int cimbareConfigure(int modeVal, int compression);

@JS('Module._cimbare_init_encode')
external int cimbareInitEncode(int filenamePtr, int fnsize, int encodeId);

@JS('Module._cimbare_encode_bufsize')
external int cimbareEncodeBufsize();

@JS('Module._cimbare_encode')
external int cimbareEncode(int bufferPtr, int size);

@JS('Module._cimbare_next_frame')
external int cimbareNextFrame(bool colorBalance);

@JS('Module._cimbare_get_frame_buff')
external int cimbareGetFrameBuff(int buffPtrPtr);

@JS('Module._cimbare_init_window')
external int cimbareInitWindow(int width, int height);

@JS('Module._cimbare_render')
external int cimbareRender();

// ─── Decoder functions ───────────────────────────────────────────

@JS('Module._cimbard_configure_decode')
external int cimbardConfigureDecode(int modeVal);

@JS('Module._cimbard_get_bufsize')
external int cimbardGetBufsize();

@JS('Module._cimbard_get_decompress_bufsize')
external int cimbardGetDecompressBufsize();

@JS('Module._cimbard_scan_extract_decode')
external int cimbardScanExtractDecode(
  int imgdataPtr,
  int imgw,
  int imgh,
  int format,
  int bufspacePtr,
  int bufsize,
);

@JS('Module._cimbard_fountain_decode')
external int cimbardFountainDecode(int bufferPtr, int size);

@JS('Module._cimbard_get_filesize')
external int cimbardGetFilesize(int id);

@JS('Module._cimbard_get_filename')
external int cimbardGetFilename(int id, int filenamePtr, int fnsize);

@JS('Module._cimbard_decompress_read')
external int cimbardDecompressRead(int id, int bufferPtr, int size);

@JS('Module._cimbard_get_report')
external int cimbardGetReport(int buffPtr, int maxlen);

// ─── Helper utilities ────────────────────────────────────────────

/// Load the libcimbar WASM module from the given script URL.
///
/// Must be called before any `cimbare*` or `cimbard*` function.
Future<void> loadLibcimbarWasm(String scriptUrl) async {
  // Dynamically inject the <script> tag that loads the Emscripten JS glue.
  // The script sets the global `Module` object when ready.
  //
  // In a Flutter Web app, this is typically done in index.html:
  //   <script src="assets/wasm/libcimbar.js"></script>
  //
  // Or programmatically:
  //   final script = document.createElement('script');
  //   script.src = scriptUrl;
  //   document.head.appendChild(script);
  //   // Wait for Module.onRuntimeInitialized
}

/// Copy a Dart Uint8List into WASM heap memory at the given pointer.
void copyToWasmHeap(CimbarModule module, Uint8List data, int ptr) {
  final heap = module.heapU8.toDart;
  for (int i = 0; i < data.length; i++) {
    heap[ptr + i] = data[i];
  }
}

/// Copy bytes from WASM heap memory into a Dart Uint8List.
Uint8List copyFromWasmHeap(CimbarModule module, int ptr, int length) {
  final heap = module.heapU8.toDart;
  return Uint8List.fromList(heap.sublist(ptr, ptr + length));
}
