// cimbar decode worker — runs scan_extract_decode off the main thread.
//
// Mirrors the OFFICIAL receiver's worker (libcimbar/web/recv-worker.js):
// each worker loads its OWN instance of the Emscripten module and performs
// the heavy per-frame work (anchor scan + deskew + symbol decode). The
// main thread keeps the fountain sink (cimbard_fountain_decode) and the
// final reassembly, exactly like recv.html's split.
//
// Protocol (with the Dart pool in decode_worker_pool.dart):
//   main -> worker : {t:'cfg',  mode}                       configure mode
//   main -> worker : {t:'dec',  seq, px, fmt, w, h, mode}   decode a frame
//                    (px is a Uint8Array whose buffer is TRANSFERRED)
//   worker -> main : {t:'ready'}                            wasm initialized
//   worker -> main : {t:'res', seq, len, buf?, rpt?}        decode result
//                    len > 0: buf carries the fountain chunks (transferred)
//                    len <= 0: rpt carries the diagnostic report string
//
// fmt is the numeric cimbar format code (3=RGB, 4=RGBA, 12=NV12, 420=I420),
// already resolved by the caller — no string mapping here.
'use strict';

let _wasmInitialized = false;
let _imgBuff = null;      // Uint8Array view over the wasm heap (input pixels)
let _imgPtr = 0;
let _fountBuff = null;    // Uint8Array view over the wasm heap (output chunks)
let _fountPtr = 0;
let _fountSize = 0;
let _rptBuff = null;      // report string buffer
let _rptPtr = 0;

// Emscripten picks up this Module object (the glue checks for a pre-defined
// global Module, exactly like the official recv-worker.js does).
var Module = {
  print: function(text) { console.log('[cimbar-worker]', text); },
  printErr: function(text) { console.warn('[cimbar-worker]', text); },
  onRuntimeInitialized: function() {
    _wasmInitialized = true;
    self.postMessage({ t: 'ready' });
  },
};

importScripts('libcimbar.js');

function _ensureBuffers(imgSize) {
  if (_imgBuff === null || _imgBuff.length < imgSize ||
      _imgBuff.buffer !== Module.HEAPU8.buffer) {
    _imgPtr = Module._malloc(imgSize);
    _imgBuff = new Uint8Array(Module.HEAPU8.buffer, _imgPtr, imgSize);
  }
  if (_fountSize === 0) {
    _fountSize = Module._cimbard_get_bufsize();
    _fountPtr = Module._malloc(_fountSize);
    _fountBuff = new Uint8Array(Module.HEAPU8.buffer, _fountPtr, _fountSize);
  } else if (_fountBuff.buffer !== Module.HEAPU8.buffer) {
    // heap grew: rebuild the chunk-buffer view at the SAME pointer — the
    // allocation is still valid, only the view went stale.
    _fountBuff = new Uint8Array(Module.HEAPU8.buffer, _fountPtr, _fountSize);
  }
  if (_rptBuff === null || _rptBuff.buffer !== Module.HEAPU8.buffer) {
    if (!_rptPtr) _rptPtr = Module._malloc(512);
    _rptBuff = new Uint8Array(Module.HEAPU8.buffer, _rptPtr, 512);
  }
}

function _getReport() {
  const len = Module._cimbard_get_report(_rptPtr, 512);
  if (len > 0) {
    const view = new Uint8Array(Module.HEAPU8.buffer, _rptPtr, len);
    return new TextDecoder().decode(view);
  }
  return '';
}

self.onmessage = function(event) {
  const d = event.data;

  if (d.t === 'cfg') {
    if (_wasmInitialized) Module._cimbard_configure_decode(d.mode);
    return;
  }

  if (d.t === 'dec') {
    if (!_wasmInitialized) {
      self.postMessage({ t: 'res', seq: d.seq, len: -100, rpt: 'wasm-not-ready' });
      return;
    }
    try {
      // Per-frame mode configure, like the official worker: the mode
      // value only acts on change, so this is a cheap no-op most frames.
      Module._cimbard_configure_decode(d.mode);

      _ensureBuffers(d.px.length);
      _imgBuff.set(d.px, 0);

      const len = Module._cimbard_scan_extract_decode(
          _imgPtr, d.w, d.h, d.fmt, _fountPtr, _fountSize);

      if (len > 0) {
        // copy out of the wasm heap and transfer to the main thread
        const out = new Uint8Array(len);
        out.set(new Uint8Array(Module.HEAPU8.buffer, _fountPtr, len));
        self.postMessage({ t: 'res', seq: d.seq, len: len, buf: out },
            [out.buffer]);
      } else {
        self.postMessage({ t: 'res', seq: d.seq, len: len, rpt: _getReport() });
      }
    } catch (ex) {
      self.postMessage({ t: 'res', seq: d.seq, len: -101, rpt: String(ex) });
    }
    return;
  }
};
