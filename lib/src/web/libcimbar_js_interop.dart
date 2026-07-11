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
}

/// Instance members for [CimbarModule] via extension (required by @staticInterop).
extension CimbarModuleMembers on CimbarModule {
  /// Whether the WASM runtime has finished initializing.
  external bool get calledRun;

  /// The HTML canvas element used for WebGL rendering (encoder only).
  external JSAny? get canvas;

  /// Allocate bytes in the WASM heap and return the pointer.
  ///
  /// The result is declared as [JSNumber] to avoid dart2js widening the
  /// return type to [BigInt] when the heap address exceeds 2^53. Callers
  /// should convert via `.toDart.toInt()`.
  @JS('_malloc')
  external JSNumber malloc(JSNumber size);

  /// Free previously allocated WASM heap memory.
  @JS('_free')
  external void free(JSNumber ptr);

  /// Access the WASM HEAPU8 (Uint8Array) for reading/writing memory.
  @JS('HEAPU8')
  external JSUint8Array get heapU8;

  /// Allocate bytes in the WASM heap and return an int pointer.
  ///
  /// Wraps [malloc] (which returns [JSNumber]) to give callers a normal
  /// Dart [int] suitable for use as a `Uint8List` index. The value is
  /// routed through `dartify()` to handle both regular JS numbers and
  /// the rare case where the heap address is large enough to be
  /// surfaced as a [BigInt].
  int allocate(int size) => jsNumberToInt(malloc(size.toJS));

  /// Free a pointer previously obtained from [allocate].
  void deallocate(int ptr) => free(ptr.toJS);
}

/// Convert a JS value ([JSNumber] or [JSAny]) to a Dart [int], handling
/// the case where the JS value is actually a [BigInt] (which the WASM
/// heap can surface when the pointer exceeds 2^53).
int jsNumberToInt(JSAny n) {
  final v = n.dartify();
  if (v is BigInt) return v.toInt();
  if (v is num) return v.toInt();
  return 0;
}

// ─── Encoder functions ───────────────────────────────────────────

@JS('Module._cimbare_configure')
external JSNumber cimbareConfigure(JSNumber modeVal, JSNumber compression);

@JS('Module._cimbare_init_encode')
external JSNumber cimbareInitEncode(
    JSNumber filenamePtr, JSNumber fnsize, JSNumber encodeId);

@JS('Module._cimbare_encode_bufsize')
external JSNumber cimbareEncodeBufsize();

@JS('Module._cimbare_encode')
external JSNumber cimbareEncode(JSNumber bufferPtr, JSNumber size);

@JS('Module._cimbare_next_frame')
external JSNumber cimbareNextFrame(JSNumber colorBalance);

@JS('Module._cimbare_get_frame_buff')
external JSNumber cimbareGetFrameBuff(JSNumber buffPtrPtr);

@JS('Module._cimbare_init_window')
external JSNumber cimbareInitWindow(JSNumber width, JSNumber height);

@JS('Module._cimbare_render')
external JSNumber cimbareRender();

// ─── Decoder functions ───────────────────────────────────────────

@JS('Module._cimbard_configure_decode')
external JSNumber cimbardConfigureDecode(JSNumber modeVal);

@JS('Module._cimbard_get_bufsize')
external JSNumber cimbardGetBufsize();

@JS('Module._cimbard_get_decompress_bufsize')
external JSNumber cimbardGetDecompressBufsize();

@JS('Module._cimbard_scan_extract_decode')
external JSNumber cimbardScanExtractDecode(
  JSNumber imgdataPtr,
  JSNumber imgw,
  JSNumber imgh,
  JSNumber format,
  JSNumber bufspacePtr,
  JSNumber bufsize,
);

@JS('Module._cimbard_fountain_decode')
external JSAny cimbardFountainDecode(JSNumber bufferPtr, JSNumber size);

@JS('Module._cimbard_get_filesize')
external JSNumber cimbardGetFilesize(JSNumber id);

@JS('Module._cimbard_get_filename')
external JSNumber cimbardGetFilename(
    JSNumber id, JSNumber filenamePtr, JSNumber fnsize);

@JS('Module._cimbard_decompress_read')
external JSNumber cimbardDecompressRead(
    JSNumber id, JSNumber bufferPtr, JSNumber size);

@JS('Module._cimbard_get_report')
external JSNumber cimbardGetReport(JSNumber buffPtr, JSNumber maxlen);

@JS('Module._cimbard_get_debug')
external JSNumber cimbardGetDebug(JSNumber buffPtr, JSNumber maxlen);

// ─── Helper utilities ────────────────────────────────────────────

/// Check WASM module loading status and return diagnostic information.
///
/// Returns a map with:
/// - `moduleDefined`: whether the global `Module` object exists
/// - `calledRun`: whether WASM runtime has finished initializing
/// - `scriptLoaded`: whether libcimbar.js script tag is present
/// - `ready`: overall readiness status
bool _checkWasmFileMissing() {
  try {
    return _wasmMissing == true;
  } catch (_) {
    return false;
  }
}

WasmDiagnostics checkWasmDiagnostics() {
  final moduleDefined = _checkModuleDefined();
  final calledRun = moduleDefined ? _checkCalledRun() : false;
  final wasmMissing = _checkWasmFileMissing();
  return WasmDiagnostics(
    moduleDefined: moduleDefined,
    calledRun: calledRun,
    ready: moduleDefined && calledRun,
    wasmFileMissing: wasmMissing,
  );
}

bool _checkModuleDefined() {
  try {
    return cimbarModule != null;
  } catch (_) {
    return false;
  }
}

bool _checkCalledRun() {
  // Emscripten may not expose `calledRun` directly on Module.
  // Prefer `window.__libcimbarReady` set by onRuntimeInitialized callback.
  try {
    if (_wasmRuntimeReady == true) return true;
  } catch (_) {}
  try {
    return cimbarModule?.calledRun ?? false;
  } catch (_) {
    return false;
  }
}

@JS('window.__libcimbarWasmMissing')
external bool? get _wasmMissing;

@JS('window.__libcimbarReady')
external bool? get _wasmRuntimeReady;

/// WASM module diagnostic information.
class WasmDiagnostics {
  /// Whether the global `Module` JS object exists.
  final bool moduleDefined;

  /// Whether `Module.calledRun` is true (WASM runtime initialized).
  final bool calledRun;

  /// Whether the WASM JS glue file is missing (404).
  final bool wasmFileMissing;

  /// Overall readiness.
  final bool ready;

  /// How long the wait was (if applicable).
  final Duration? waitDuration;

  const WasmDiagnostics({
    required this.moduleDefined,
    required this.calledRun,
    required this.ready,
    this.wasmFileMissing = false,
    this.waitDuration,
  });

  /// Human-readable diagnostic report.
  String toReport() {
    final lines = <String>[
      'WASM Diagnostics:',
      '  Module object exists: $moduleDefined',
      '  Module.calledRun:     $calledRun',
      '  WASM file loaded:     ${!wasmFileMissing}',
      '  Ready:                $ready',
    ];
    if (waitDuration != null) {
      lines.add('  Waited:               ${waitDuration!.inMilliseconds}ms');
    }
    if (wasmFileMissing) {
      lines.add('');
      lines.add('  Cause: libcimbar.js WASM file not found.');
      lines.add('  The WASM module has not been compiled yet.');
      lines.add('');
      lines.add('  Steps to fix:');
      lines.add('    1. Install Emscripten SDK:');
      lines
          .add('       git clone https://github.com/emscripten-core/emsdk.git');
      lines.add('       cd emsdk && ./emsdk install latest && '
          './emsdk activate latest');
      lines.add('       source emsdk_env.sh');
      lines.add('    2. Build WASM:');
      lines.add('       cd native && ./build_wasm.sh');
      lines.add('    3. Copy output:');
      lines.add('       mkdir -p ../example/web/assets/wasm/');
      lines
          .add('       cp build_wasm/libcimbar.js ../example/web/assets/wasm/');
      lines.add('       cp build_wasm/libcimbar.wasm '
          '../example/web/assets/wasm/');
      lines.add('    4. Rebuild web app:');
      lines.add('       cd ../example && flutter build web');
    } else if (!moduleDefined) {
      lines.add('');
      lines.add('  Cause: Module object not found.');
      lines.add('  Fix: Ensure index.html configures the Module object.');
    } else if (!calledRun) {
      lines.add('');
      lines.add('  Cause: Module exists but WASM runtime did not finish'
          ' initializing.');
      lines.add('  Fix: Check browser console for WASM loading errors.');
      lines.add('       The .wasm binary may be missing or corrupted.');
    }
    return lines.join('\n');
  }

  @override
  String toString() => toReport();
}

/// Wait for the WASM module to finish initializing.
///
/// Polls `Module.calledRun` at [pollInterval] until it becomes true
/// or [timeout] is reached.
///
/// Returns a [WasmDiagnostics] with `ready: true` if successful,
/// or `ready: false` if timed out.
Future<WasmDiagnostics> waitForWasmReady({
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 200),
  void Function(String status)? onStatusUpdate,
}) async {
  final stopwatch = Stopwatch()..start();

  // Quick check: already ready?
  var diag = checkWasmDiagnostics();
  if (diag.ready) {
    return WasmDiagnostics(
      moduleDefined: diag.moduleDefined,
      calledRun: diag.calledRun,
      ready: true,
      wasmFileMissing: false,
      waitDuration: stopwatch.elapsed,
    );
  }

  // Quick check: WASM file is known to be missing?
  if (diag.wasmFileMissing) {
    return WasmDiagnostics(
      moduleDefined: diag.moduleDefined,
      calledRun: false,
      ready: false,
      wasmFileMissing: true,
      waitDuration: stopwatch.elapsed,
    );
  }

  onStatusUpdate?.call('Waiting for WASM module...');

  // Poll until ready or timeout
  while (stopwatch.elapsed < timeout) {
    await Future<void>.delayed(pollInterval);
    diag = checkWasmDiagnostics();

    // WASM file confirmed missing during polling
    if (diag.wasmFileMissing) {
      return WasmDiagnostics(
        moduleDefined: diag.moduleDefined,
        calledRun: false,
        ready: false,
        wasmFileMissing: true,
        waitDuration: stopwatch.elapsed,
      );
    }

    if (!diag.moduleDefined) {
      // Module not even defined yet — no point waiting
      return WasmDiagnostics(
        moduleDefined: false,
        calledRun: false,
        ready: false,
        wasmFileMissing: false,
        waitDuration: stopwatch.elapsed,
      );
    }

    if (diag.calledRun) {
      onStatusUpdate?.call('WASM module ready.');
      return WasmDiagnostics(
        moduleDefined: true,
        calledRun: true,
        ready: true,
        wasmFileMissing: false,
        waitDuration: stopwatch.elapsed,
      );
    }

    final elapsed = stopwatch.elapsed.inMilliseconds;
    onStatusUpdate?.call(
      'Waiting for WASM runtime... (${elapsed}ms / ${timeout.inMilliseconds}ms)',
    );
  }

  // Timed out
  return WasmDiagnostics(
    moduleDefined: diag.moduleDefined,
    calledRun: diag.calledRun,
    ready: false,
    wasmFileMissing: diag.wasmFileMissing,
    waitDuration: stopwatch.elapsed,
  );
}

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
