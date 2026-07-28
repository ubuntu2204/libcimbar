// Feed real frames pulled over the LOCAL debug link (Linux encoder ->
// HTTP /frame.png -> raw RGB) into the WASM decoder, mirroring the
// browser's Pull+Decode path. Verifies debug comms + decode end-to-end.
const fs = require('fs');
const path = require('path');
const WASM_DIR = '/home/ubuntu/project/libcimbar/decode_example/web/assets/wasm';
const M = {
  wasmBinary: fs.readFileSync(path.join(WASM_DIR, 'cimbar_js.wasm')),
  locateFile: (p) => path.join(WASM_DIR, p),
  print: () => {}, printErr: () => {},
};
let code = fs.readFileSync(path.join(WASM_DIR, 'libcimbar.js'), 'utf8')
  .replace('var Module=typeof Module!="undefined"?Module:{}', 'var Module=globalThis.__M');
globalThis.__M = M;
new Function('require', '__dirname', '__filename', 'module', 'exports', code)(
  require, WASM_DIR, path.join(WASM_DIR, 'libcimbar.js'), { exports: {} }, {});

let t = 0;
const timer = setInterval(() => {
  if (typeof M._cimbard_get_bufsize === 'function') {
    clearInterval(timer);
    try { run(); } catch (e) { console.log('TRAP:', e && (e.stack || e)); }
    process.exit(0);
  }
  if (++t > 400) { console.log('TIMEOUT'); process.exit(1); }
}, 25);

function readReport() {
  const p = M._malloc(512);
  const len = M._cimbard_get_report(p, 512);
  let s = '';
  for (let i = 0; i < len; i++) s += String.fromCharCode(M.HEAPU8[p + i]);
  M._free(p);
  return s;
}

function run() {
  M._cimbard_configure_decode(68);
  const bufsize = M._cimbard_get_bufsize();
  const decBuf = M._malloc(bufsize);
  const files = fs.readdirSync('/tmp/rframes').filter(f => f.endsWith('.bin')).sort();
  console.log('frames on disk:', files.length, ' bufsize:', bufsize);

  let imgPtr = 0, imgCap = 0;
  for (let i = 0; i < files.length; i++) {
    const raw = fs.readFileSync(path.join('/tmp/rframes', files[i]));
    const m = files[i].match(/_(\d+)x(\d+)\.bin$/);
    const w = +m[1], h = +m[2];
    if (raw.length > imgCap) { if (imgPtr) M._free(imgPtr); imgPtr = M._malloc(raw.length); imgCap = raw.length; }
    M.HEAPU8.set(raw, imgPtr);
    const bytes = M._cimbard_scan_extract_decode(imgPtr, w, h, 3, decBuf, bufsize);
    let fid = 0;
    if (bytes > 0) fid = Number(M._cimbard_fountain_decode(decBuf, bytes));
    if ((i + 1) % 10 === 0 || fid !== 0 || bytes <= 0)
      console.log(`frame ${i + 1}/${files.length}: scan=${bytes} fountain=${fid} ${readReport().slice(0, 60)}`);
    if (fid > 0) {
      // recover filename + contents to fully close the loop
      const fnPtr = M._malloc(256);
      const fl = M._cimbard_get_filename(fid, fnPtr, 256);
      let fn = ''; for (let j = 0; j < fl; j++) fn += String.fromCharCode(M.HEAPU8[fnPtr + j]);
      M._free(fnPtr);
      const outCap = M._cimbard_get_decompress_bufsize();
      const outPtr = M._malloc(outCap);
      let total = 0, r;
      while ((r = M._cimbard_decompress_read(fid, outPtr, outCap)) > 0) total += r;
      M._free(outPtr);
      console.log(`\n✅ DECODE COMPLETE at frame ${i + 1}: fileId=${fid} filename="${fn}" recovered=${total} bytes`);
      return;
    }
  }
  console.log('❌ not complete after all frames; last:', readReport());
}
