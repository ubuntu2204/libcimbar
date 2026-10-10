'use strict';
// 重现 screenshot 的发送序列：单块 41267B encodeChunk + finishEncode(null,0)
// 并解码恢复，检查文件完整性。
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const WASM_DIR = path.resolve(HERE, '..', '..', 'decode_example', 'web', 'assets', 'wasm');
const IMG = '/home/ubuntu/文档/screenshots/screenshot_20260915_082447_789.avif';

// ── 加载 wasm glue（同 wasm_decode_test.js）──
let jsGlue = fs.readFileSync(path.join(WASM_DIR, 'libcimbar.js'), 'utf8');
jsGlue = jsGlue
  .replace('var Module=typeof Module!="undefined"?Module:{}',
           'var Module=globalThis.__M');
globalThis.__M = { exports: {} };
new Function('require', '__dirname', '__filename', 'module', 'exports', jsGlue)(
  require, WASM_DIR, path.join(WASM_DIR, 'libcimbar.js'), { exports: {} }, {});

const M = globalThis.__M;
// Module 就绪由 glue 异步初始化——轮询 calledRun
function waitReady() {
  return new Promise((resolve) => {
    const t = setInterval(() => {
      if (M.calledRun) { clearInterval(t); resolve(); }
    }, 50);
    setTimeout(() => { clearInterval(t); resolve(); }, 15000);
  });
}

function js(v) { return typeof v === 'bigint' ? Number(v) : v; }

(async () => {
  await waitReady();

  const image = fs.readFileSync(IMG);
  const header = '{"campus":"南湖校区","location":"321321","format":"avif","category":"security"}';
  const hb = Buffer.from(header, 'utf8');
  const payload = Buffer.alloc(4 + hb.length + image.length);
  payload.writeUInt32BE(hb.length, 0);
  hb.copy(payload, 4);
  image.copy(payload, 4 + hb.length);
  console.log('payload bytes:', payload.length);

  // ── 编码序列（与 screenshot _prepareCimbar 完全一致）──
  console.log('configure:', js(M._cimbare_configure(68, 16)));
  const name = 'report_test.avif';
  const fnBuf = M._malloc(name.length + 1);
  const heap = new Uint8Array(M.HEAPU8.buffer, fnBuf, name.length + 1);
  for (let i = 0; i < name.length; i++) heap[i] = name.charCodeAt(i);
  heap[name.length] = 0;
  console.log('init_encode:', js(M._cimbare_init_encode(fnBuf, name.length + 1, -1)));

  const st1 = js(M._cimbare_encode(payload.byteOffset, payload.length));
  console.log('encodeChunk(41267) status=', st1, ' <0? ', st1 < 0);
  const st2 = js(M._cimbare_encode(null, 0));
  console.log('finishEncode(null,0) status=', st2, ' <0? ', st2 < 0);
  // 无论 finish 成败，喷泉流（若已创建）继续拉帧
  const frames = [];
  for (let i = 0; i < 40; i++) {
    const n = js(M._cimbare_next_frame(0));
    if (n <= 0) { console.log('next_frame <=0 @', i); break; }
    const buf = M._cimbare_get_frame_buff();
    const w = js(M._cimbare_get_frame_width());
    const h = js(M._cimbare_get_frame_height());
    frames.push({ buf: new Uint8Array(M.HEAPU8.buffer, buf, w * h * 3), w, h });
  }
  console.log('frames pulled:', frames.length, frames[0] ? `${frames[0].w}x${frames[0].h}` : '');
  fs.writeFileSync('/tmp/enc_frames_meta.json', JSON.stringify({
    w: frames[0] ? frames[0].w : 0, h: frames[0] ? frames[0].h : 0,
    count: frames.length,
  }));
  // 把帧数据平铺写出
  if (frames.length) {
    const out = Buffer.concat(frames.map(f => Buffer.from(f.buf)));
    fs.writeFileSync('/tmp/enc_frames.rgb', out);
    console.log('frames rgb written:', out.length);
  }
  process.exit(0);
})().catch(e => { console.error('FATAL', e); process.exit(1); });
