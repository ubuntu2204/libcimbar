#!/usr/bin/env python3
"""Compare the OFFICIAL cimbar web receiver vs decode_example's web app.

Feeds the same video (test/test.mp4 — a real phone recording of a playing
cimbar barcode) through Chrome's fake camera
(`--use-file-for-fake-video-capture`) into BOTH web decoders, and reports
side-by-side: whether the file was recovered, how fast, and how many of
the camera frames actually yielded fountain payload.

Targets:
  official : the official wasm package (recv.html + recv-worker.js + 4
             Web Workers, WebCodecs VideoFrame capture) served as-is
  app      : decode_example/build/web (our Flutter app, VideoFrame/canvas
             capture, single-threaded wasm), started via ?autostart=1

Completion signals (console):
  official : "on decode got res <id>" with id > 0
  app      : "fountain_decode => <id>" with id > 0, plus a decompress_read

Usage:
  python3 compare_web.py                     # default: test/test.mp4
  python3 compare_web.py --video other.mp4
  python3 compare_web.py --seconds 90 --runs 2 --verbose
"""

import argparse
import functools
import http.server
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent

DEFAULT_VIDEO = ROOT / 'test' / 'test.mp4'
DEFAULT_Y4M = Path('/tmp/libcimbar_compare_feed.y4m')
OFFICIAL_DIR = Path.home() / '下载' / 'cimbar.wasm'
APP_WEB_DIR = ROOT / 'decode_example' / 'build' / 'web'
OFFICIAL_PORT = 8911
APP_PORT = 8913


# ─── Local static file servers ─────────────────────────────────────

def serve(directory: Path, port: int):
    handler = functools.partial(
        http.server.SimpleHTTPRequestHandler, directory=str(directory))
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', port), handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv


# ─── One browser session against one target ────────────────────────

class Target:
    """Console-log grammar + completion rule for one web decoder."""

    def __init__(self, name, url, done_re, done_extra=None):
        self.name = name
        self.url = url
        self.done_re = re.compile(done_re)
        self.done_extra = done_extra  # extra substring required, or None


def run_session(playwright, target: Target, y4m: Path, seconds: int):
    logs = []  # (elapsed_seconds, text)

    def on_console(msg):
        logs.append((time.time(), msg.text))

    browser = playwright.chromium.launch(
        headless=True,
        args=[
            '--use-fake-ui-for-media-stream',
            '--use-fake-device-for-media-stream',
            f'--use-file-for-fake-video-capture={y4m}',
            '--autoplay-policy=no-user-gesture-required',
        ])
    try:
        ctx = browser.new_context(permissions=['camera'])
        page = ctx.new_page()
        page.on('console', on_console)
        page.on('pageerror', lambda e: logs.append((time.time(), f'[pageerror] {e}')))
        t0 = time.time()
        page.goto(target.url)

        # NB: time.sleep() would BLOCK playwright's sync-API event loop and
        # queue all console events until the next API call — every timestamp
        # would collapse onto the session end. wait_for_timeout() pumps the
        # loop, so events are dispatched (and timestamped) in real time.
        while time.time() - t0 < seconds:
            done = any(target.done_re.search(text) for _, text in logs)
            if done and (target.done_extra is None or
                         any(target.done_extra in text for _, text in logs)):
                # let the tail settle (decompress/download logs)
                page.wait_for_timeout(2000)
                break
            page.wait_for_timeout(500)
        elapsed = time.time() - t0
    finally:
        browser.close()

    return [(t - t0, text) for t, text in logs], elapsed


# ─── Metric extraction (per-target console grammar) ─────────────────

def summarize_official(logs, elapsed):
    complete_at = None
    first_payload_at = None
    payload = 0
    fed = 0
    progress_last = ''
    for t, text in logs:
        m = re.search(r'on decode got res (\d+)', text)
        if m:
            payload += 1
            if first_payload_at is None:
                first_payload_at = t
            if int(m.group(1)) > 0 and complete_at is None:
                complete_at = t
        if 'crosshair offsets now' in text:
            fed += 1
        m = re.search(r'progress!!!!(.+)', text)
        if m:
            progress_last = m.group(1).strip()
    return {
        'completed': complete_at is not None,
        'complete_at': complete_at,
        'first_payload_at': first_payload_at,
        'payload_frames': payload,
        'frames_fed': fed,
        'last_progress': progress_last,
        'elapsed': elapsed,
    }


def summarize_app(logs, elapsed):
    complete_at = None
    first_payload_at = None
    payload = 0
    fed_max = 0
    for t, text in logs:
        m = re.search(r'fountain_decode => (\d+)', text)
        if m and int(m.group(1)) > 0 and complete_at is None:
            complete_at = t
        if re.search(r'scan_extract_decode => \d+ bytes', text):
            payload += 1
            if first_payload_at is None:
                first_payload_at = t
        m = re.search(r'\[Camera\] frame #(\d+)', text)
        if m:
            fed_max = max(fed_max, int(m.group(1)))
    return {
        'completed': complete_at is not None,
        'complete_at': complete_at,
        'first_payload_at': first_payload_at,
        'payload_frames': payload,
        'frames_fed': fed_max,  # sampled every 50 → this is the exact max
        'last_progress': '',
        'elapsed': elapsed,
    }


# ─── Main ───────────────────────────────────────────────────────────

def make_y4m(video: Path, y4m: Path) -> None:
    if y4m.exists() and y4m.stat().st_mtime >= video.stat().st_mtime:
        print(f'[1/3] Reusing {y4m}')
        return
    print(f'[1/3] {video} -> {y4m}')
    y4m.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ['ffmpeg', '-y', '-v', 'error', '-i', str(video),
         '-pix_fmt', 'yuv420p', '-f', 'yuv4mpegpipe', str(y4m)],
        check=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--video', type=Path, default=DEFAULT_VIDEO)
    ap.add_argument('--y4m', type=Path, default=DEFAULT_Y4M)
    ap.add_argument('--seconds', type=int, default=60)
    ap.add_argument('--runs', type=int, default=1,
                    help='sessions per target (reports each)')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print('ERROR: python playwright not installed.\n'
              '  pip install playwright && playwright install chromium')
        return 2
    for p, label in ((args.video, 'input video'), (OFFICIAL_DIR, 'official pkg'),
                     (APP_WEB_DIR, 'decode_example build/web')):
        if not p.exists():
            print(f'ERROR: {label} not found: {p}')
            return 2

    make_y4m(args.video, args.y4m)

    print('[2/3] Serving targets...')
    srv_o = serve(OFFICIAL_DIR, OFFICIAL_PORT)
    srv_a = serve(APP_WEB_DIR, APP_PORT)
    try:
        targets = [
            (Target('official', f'http://127.0.0.1:{OFFICIAL_PORT}/recv.html',
                    r'on decode got res ([1-9]\d*)'),
             summarize_official),
            (Target('app', f'http://127.0.0.1:{APP_PORT}/?autostart=1',
                    r'fountain_decode => ([1-9]\d*)',
                    done_extra='decompress_read'),
             summarize_app),
        ]

        results = {}
        with sync_playwright() as p:
            print(f'[3/3] Running {args.runs} session(s) per target, '
                  f'budget {args.seconds}s each...')
            for target, summarize in targets:
                runs = []
                for i in range(args.runs):
                    print(f'  -> {target.name} run {i + 1}/{args.runs}')
                    logs, elapsed = run_session(p, target, args.y4m, args.seconds)
                    stats = summarize(logs, elapsed)
                    runs.append(stats)
                    if args.verbose:
                        for t, text in logs:
                            print(f'    [{t:7.2f}s] {text}')
                    else:
                        print(f'     completed={stats["completed"]} '
                              f'complete_at={stats["complete_at"]} '
                              f'payload={stats["payload_frames"]} '
                              f'fed={stats["frames_fed"]}')
                results[target.name] = runs
    finally:
        srv_o.shutdown()
        srv_a.shutdown()

    # ─── Report ────────────────────────────────────────────────────
    print('\n================ decode comparison ================')
    print(f'input   : {args.video.name} (looped via Chrome fake camera)')
    print(f'budget  : {args.seconds}s per session')
    for name, runs in results.items():
        for i, s in enumerate(runs, 1):
            ca = f'{s["complete_at"]:.1f}s' if s['complete_at'] else '—'
            fp = f'{s["first_payload_at"]:.1f}s' if s['first_payload_at'] else '—'
            rate = (f'{s["payload_frames"] / s["frames_fed"] * 100:.0f}%'
                    if s['frames_fed'] else '—')
            print(f'{name:>8} run{i}: {"DECODED" if s["completed"] else "FAILED"} | '
                  f'1st payload {fp:>6} | complete@ {ca:>6} | '
                  f'payload {s["payload_frames"]:>3}/{s["frames_fed"]:>4} fed '
                  f'({rate})'
                  + (f' | last progress {s["last_progress"]}' if s['last_progress'] else ''))
    print('====================================================')
    ok = all(s['completed'] for runs in results.values() for s in runs)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
