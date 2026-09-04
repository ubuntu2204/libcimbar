#!/usr/bin/env node
// Headless regression test for the cimbar WASM decoder.
//
// Feeds lossless RGB frames (produced by dump_frames from the encoder's own
// buffer) straight into the WASM build — the same `cimbard_*` C API the
// browser calls, with format 3 (RGB), but run in Node.
//
// Why this exists: it isolates "the WASM build is broken" from "the web
// capture chain is broken". Both were indistinguishable from the browser
// console, and the distinction is what found the auto-crop upscale bug
// (smooth interpolation -> sharpness drops to ~5% -> scan fails with -3).
//
// Usage:
//   node wasm_decode_test.js [--wasm DIR] [--frames DIR] [--scale N]
//                            [--width W] [--height H] [--verbose]
//
// Exit codes:
//   0  decoded successfully
//   1  NOT decoded (this is the regression signal)
//   2  setup problem (missing wasm / frames / node)
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

// ─── Args ────────────────────────────────────────────────────────
function arg(name, fallback) {
  const i = process.argv.indexOf('--' + name);
  return (i >= 0 && i + 1 < process.argv.length) ? process.argv[i + 1] : fallback;
}
const flag = (name) => process.argv.includes('--' + name);

const HERE = __dirname;
const PROJECT_ROOT = path.resolve(HERE, '..', '..');
const WASM_DIR = path.resolve(arg('wasm',
  path.join(PROJECT_ROOT, 'decode_example', 'web', 'assets', 'wasm')));
const FRAME_DIR = path.resolve(arg('frames',
  path.join(os.tmpdir(), 'libcimbar_wasm_frames')));
const SCALE = parseInt(arg('scale', '1'), 10);
const SRC_W = parseInt(arg('width', process.env.FRAME_W || '1024'), 10);
const SRC_H = parseInt(arg('height', process.env.FRAME_H || '1024'), 10);
const VERBOSE = flag('verbose');

function fail(exitCode, msg) {
  process.stderr.write(msg + '\n');
  process.exit(exitCode);
}

// ─── Preflight ───────────────────────────────────────────────────
const jsGlue = path.join(WASM_DIR, 'libcimbar.js');
const wasmBin = path.join(WASM_DIR, 'cimbar_js.wasm');
if (!fs.existsSync(jsGlue)) fail(2, 'missing JS glue: ' + jsGlue);
if (!fs.existsSync(wasmBin)) fail(2, 'missing wasm binary: ' + wasmBin);
if (!fs.existsSync(FRAME_DIR)) {
  fail(2, 'missing frame dir: ' + FRAME_DIR + '\nRun run.sh (it generates ' +
          'frames via dump_frames) or pass --frames DIR');
}

// ─── Load the emscripten module ──────────────────────────────────
// The generated glue does `var Module = typeof Module!=="undefined"?Module:{}`,
// so we inject through a global and evaluate it in a function scope that
// supplies a Node-ish `require`.
const M = {
  wasmBinary: fs.readFileSync(wasmBin),
  locateFile: (p) => path.join(WASM_DIR, p),
  print: (s) => { if (VERBOSE) console.log('[wasm] ' + s); },
  printErr: (s) => process.stderr.write('[wasm] ' + s + '\n'),
};
let code = fs.readFileSync(jsGlue, 'utf8')
  .replace('var Module=typeof Module!="undefined"?Module:{}',
           'var Module=globalThis.__M');
globalThis.__M = M;
new Function('require', '__dirname', '__filename', 'module', 'exports', code)(
  require, WASM_DIR, jsGlue, { exports: {} }, {});

function readReport() {
  const p = M._malloc(4096);
  const len = M._cimbard_get_report(p, 4096);
  let s = '';
  if (len > 0) s = Buffer.from(M.HEAPU8.subarray(p, p + len)).toString('utf8');
  M._free(p);
  return s.trim();
}

// ─── Wait for the runtime, then run ──────────────────────────────
let waited = 0;
const timer = setInterval(() => {
  if (typeof M._cimbard_get_bufsize === 'function') {
    clearInterval(timer);
    let ok = false;
    try { ok = run(); }
    catch (e) { console.log('TRAP:', e && (e.stack || e)); process.exit(1); }
    process.exit(ok ? 0 : 1);
  }
  if (++waited > 800) {
    console.log('TIMEOUT waiting for wasm runtime');
    process.exit(1);
  }
}, 25);

// Nearest-neighbour upscale: tests the SIZE effect without introducing blur,
// which is what separates a real size limit from an interpolation problem.
function upscale(raw, w, h, scale) {
  const dw = w * scale, dh = h * scale;
  const out = Buffer.alloc(dw * dh * 3);
  for (let y = 0; y < dh; y++) {
    const sy = (y / scale) | 0;
    for (let x = 0; x < dw; x++) {
      const sx = (x / scale) | 0;
      const s = (sy * w + sx) * 3, d = (y * dw + x) * 3;
      out[d] = raw[s]; out[d + 1] = raw[s + 1]; out[d + 2] = raw[s + 2];
    }
  }
  return out;
}

function run() {
  const files = fs.readdirSync(FRAME_DIR)
    .filter((f) => f.endsWith('.rgb')).sort();
  if (files.length === 0) {
    fail(2, 'no .rgb frames in ' + FRAME_DIR);
  }
  console.log('wasm      : ' + WASM_DIR);
  console.log('frames    : ' + files.length + ' @ ' +
    (SRC_W * SCALE) + 'x' + (SRC_H * SCALE) + ' RGB (scale ' + SCALE + ')');

  // Toggle the mode first: the native sink only refreshes when the mode value
  // changes, so re-configuring with the same value would leave a completed
  // stream in place. 4 is the legacy mode; 68 is mode B.
  M._cimbard_configure_decode(4);
  if (M._cimbard_configure_decode(68) < 0) {
    console.log('configure_decode(68) failed');
    return false;
  }

  const bufsize = M._cimbard_get_bufsize();
  const buf = M._malloc(bufsize);

  let fileId = 0;
  let withPayload = 0;
  let worstMs = 0;

  for (let i = 0; i < files.length && fileId === 0; i++) {
    let raw = fs.readFileSync(path.join(FRAME_DIR, files[i]));
    let dw = SRC_W, dh = SRC_H;
    if (SCALE > 1) {
      raw = upscale(raw, SRC_W, SRC_H, SCALE);
      dw = SRC_W * SCALE;
      dh = SRC_H * SCALE;
    }
    const expected = dw * dh * 3;
    if (raw.length !== expected) {
      console.log(`frame ${i}: size ${raw.length} != expected ${expected}`);
      continue;
    }

    const img = M._malloc(raw.length);
    M.HEAPU8.set(raw, img);
    const t0 = Date.now();
    const n = M._cimbard_scan_extract_decode(img, dw, dh, 3, buf, bufsize);
    const ms = Date.now() - t0;
    M._free(img);
    if (ms > worstMs) worstMs = ms;

    if (n > 0) {
      withPayload++;
      const fid = M._cimbard_fountain_decode(buf, n);
      if (fid > 0) {
        fileId = fid;
        console.log(`frame ${i}: COMPLETE (file id ${fid})`);
      } else if (fid < 0) {
        console.log(`frame ${i}: fountain error ${fid}`);
      }
    } else if (n < 0) {
      // -3 is the common one: fewer than 4 corner anchors found.
      console.log(`frame ${i}: scan_extract_decode error ${n}` +
        (VERBOSE ? ' | ' + readReport() : ''));
    }
    if (VERBOSE || i < 3) {
      console.log(`frame ${i}: scanned=${n} in ${ms}ms | ${readReport()}`);
    }
  }
  M._free(buf);

  console.log('---');
  console.log('frames with payload : ' + withPayload);
  console.log('slowest frame       : ' + worstMs + 'ms');
  console.log('final report        : ' + readReport());
  console.log(fileId > 0 ? 'RESULT: DECODED ✓' : 'RESULT: NOT DECODED ✗');
  return fileId > 0;
}
