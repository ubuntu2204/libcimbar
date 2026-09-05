#!/usr/bin/env python3
"""Headless end-to-end test for the decode_example web app.

Feeds a generated cimbar Y4M video through Chrome's fake camera
(`--use-file-for-fake-video-capture`) into the web app, opened with
`?autostart=1` so scanning begins without any UI interaction, and watches
the browser console until the decoder reports a completed file.

This exercises the REAL page end to end — getUserMedia constraints,
WebCodecs VideoFrame capture (or the canvas fallback), the Dart->wasm
byte path, and the fountain/reassemble/decompress flow — in a plain
headless Chromium. It is the test that pinned down the two page-layer
bugs the Node-side wasm test (test/wasm/) could never see:

  1. `JSFunction.callAsFunction(thisArg, argsArray)` does NOT spread the
     argument array, so `VideoFrame.copyTo` received a JSArray instead of
     the buffer and the whole VideoFrame path silently fell back to
     canvas (fixed: multi-arg calls go through Reflect.apply).
  2. Emscripten returns int64_t (the fountain file id) as a JS BigInt,
     which dart2js cannot dartify — the file completed but the id read
     back as 0 ("incomplete") forever.

Exit codes:
  0  decoded (a positive file id appeared AND decompress_read ran)
  1  NOT decoded within the time budget (the regression signal)
  2  environment problem (playwright/chromium/y4m missing)
"""

import argparse
import re
import sys
import time

INTERESTING = ('[Camera]', '[Decoder]', '[cimbar]', '[libcimbar]',
               '[Frame #', 'autostart', 'pageerror')


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--url', default='http://127.0.0.1:8903/?autostart=1',
                    help='app URL (must include ?autostart=1)')
    ap.add_argument('--y4m', default='/tmp/libcimbar_e2e_feed.y4m',
                    help='cimbar video fed to the fake camera')
    ap.add_argument('--seconds', type=int, default=45,
                    help='time budget in seconds')
    ap.add_argument('--verbose', action='store_true',
                    help='print every captured console line at the end')
    args = ap.parse_args()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print('ERROR: python playwright not installed.\n'
              '  pip install playwright && playwright install chromium')
        return 2
    try:
        with open(args.y4m, 'rb'):
            pass
    except OSError:
        print(f'ERROR: y4m file not found: {args.y4m}\n'
              '  generate it with make_y4m.py (or just use run.sh)')
        return 2

    logs = []
    t0 = time.time()
    completed = False
    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            args=[
                '--use-fake-ui-for-media-stream',
                '--use-fake-device-for-media-stream',
                f'--use-file-for-fake-video-capture={args.y4m}',
                '--autoplay-policy=no-user-gesture-required',
            ],
        )
        ctx = browser.new_context(permissions=['camera'])
        page = ctx.new_page()
        page.on('console', lambda m: logs.append(f'[{m.type}] {m.text}'))
        page.on('pageerror', lambda e: logs.append(f'[pageerror] {e}'))
        page.goto(args.url)

        done_re = re.compile(r'fountain_decode => ([1-9]\d*)')
        while time.time() - t0 < args.seconds:
            joined = '\n'.join(logs)
            if done_re.search(joined) and 'decompress_read' in joined:
                completed = True
                break
            time.sleep(1)
        browser.close()

    # ─── Verdict & summary ─────────────────────────────────────────
    capture_path = 'unknown'
    for line in logs:
        if 'via VideoFrame' in line:
            capture_path = line.split('[Camera]')[-1].strip()
        if 'falling back to canvas' in line:
            capture_path = 'CANVAS FALLBACK (VideoFrame failed — see log)'
    scanned = sum('scan_extract_decode =>' in l and 'error' not in l
                  for l in logs)
    file_id = None
    for line in logs:
        m = re.search(r'fountain_decode => ([1-9]\d*)', line)
        if m:
            file_id = m.group(1)

    interesting = [l for l in logs if any(k in l for k in INTERESTING)]
    print('\n'.join(interesting[-40:] if not args.verbose else logs))
    print('---')
    print(f'capture path   : {capture_path}')
    print(f'frames scanned : {scanned}')
    print(f'file id        : {file_id or "(none)"}')
    print(f'elapsed        : {time.time() - t0:.0f}s')
    print('RESULT: ' + ('DECODED ✓' if completed else 'NOT DECODED ✗'))
    return 0 if completed else 1


if __name__ == '__main__':
    sys.exit(main())
