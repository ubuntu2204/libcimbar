# Headless end-to-end test (decode_example web)

Proves that the **whole web app** decodes what its own camera pipeline
delivers — not just that the WASM decoder works on lossless input (that
is what `test/wasm/` covers).

## Why

The web app's decode failures twice turned out to live in the page layer,
invisible to every wasm-level test:

1. `JSFunction.callAsFunction(thisArg, argsArray)` does **not** spread the
   argument array — `VideoFrame.copyTo` received a JSArray instead of the
   buffer, so the whole WebCodecs capture path silently fell back to
   canvas. (Fixed: multi-arg calls go through `Reflect.apply`.)
2. Emscripten returns `int64_t` results (the fountain file id) as a JS
   **BigInt**, which dart2js cannot `dartify()` — files completed inside
   wasm but the id read back as `0` ("incomplete") forever. (Fixed in
   `jsNumberToInt`.)

This test reproduces the full chain in headless Chromium: a generated
cimbar video is fed through Chrome's fake camera
(`--use-file-for-fake-video-capture`) into the app, opened with
`?autostart=1` so scanning starts without UI interaction. The console is
then watched for a completed file (`fountain_decode => <positive id>` +
`decompress_read`).

## Requirements

- `python3` with playwright: `pip install playwright && playwright install chromium`
- `flutter` (for the app build)
- `g++` and `native/build_linux/libcimbar.so` (only to generate frames;
  reuses `test/wasm/.build/dump_frames` when present)

## Run

```bash
./run.sh                  # full run: frames -> Y4M -> build web -> serve -> test
./run.sh --skip-build     # reuse decode_example/build/web
./run.sh --seconds 60     # longer budget
./run.sh --verbose        # dump every console line
```

Exit code `0` = decoded, `1` = **not decoded** (the regression signal),
`2` = setup problem.

## Pieces

| File | Role |
|---|---|
| `run.sh` | one-click driver (frames, video, build, server, test) |
| `make_y4m.py` | composites dump_frames RGB frames onto a 1920x1080 canvas, converts to I420 Y4M |
| `headless_e2e.py` | playwright driver + console verdict; can run standalone against any served app |
| `compare_web.py` | **official recv.html vs decode_example** benchmark on a real video — see below |

## Official-vs-app comparison (`compare_web.py`)

Benchmarks the **official** wasm receiver (recv.html, 4 Web Workers,
per-frame rVFC capture) against **decode_example** on the same input:
`test/test.mp4` (a real phone recording of a playing barcode) fed through
Chrome's fake camera. Both pages request near-identical getUserMedia
constraints, so both receive the SAME adapted stream (Chrome crops the
720x1280 video to 720x1080 to satisfy the `height: ideal 1080` request) —
the comparison isolates the decoders, not the capture.

```bash
python3 compare_web.py                     # default: test/test.mp4, 60s budget
python3 compare_web.py --runs 3            # stability check
python3 compare_web.py --video other.mp4
```

Requirements: the official wasm package at `~/下载/cimbar.wasm/` and a
current `decode_example/build/web` (rebuild with `flutter build web`).

Reference result (2026-09-10, 3 runs, all stable):

| metric | official | decode_example |
|---|---|---|
| first payload frame | 10.0–10.1s | **3.8–3.9s** |
| file complete | **10.0–10.1s** | 12.6–12.7s |
| payload frames until complete | 1 | 3–5 |
| camera frames fed until complete | ~183 (15fps, every frame) | 101 (~8fps, busy-dropped) |

Both decode the file. The app reaches payload faster (modeB locked from
the start; the official Auto mode rotates [66,68,67,4] so only 1 in 4
frames even tries mode B before the first success locks it in), while the
official completes a hair sooner overall and feeds every camera frame
(4 parallel workers vs our single main-thread wasm).

Standalone use against an already-running app:

```bash
python3 headless_e2e.py --url http://127.0.0.1:8903/?autostart=1 \
    --y4m /tmp/libcimbar_e2e_feed.y4m --seconds 45
```

## Notes

- The `?autostart=1` hook lives in `decoder_page.dart` (starts the camera
  after init; Flutter's canvas UI is impractical to click from
  automation).
- The Y4M defaults to **16 fps** on purpose: it must run at least as fast
  as the app's capture cadence (15 fps since the official-alignment fix;
  it was 5 fps originally, and a 15 fps video aliased 1:3 with that timer
  so most unique frames were never sampled).
- RGB->YUV uses full-range BT.601 — the inverse of the decoder's
  `COLOR_YUV420p2RGB`, so frames arrive pixel-equivalent to the raw RGB.
- Expected healthy run: `via VideoFrame: I420 ... -> yuv420` in the log,
  a positive `fountain_decode => <id>` after ~9 scanned frames, then
  `decompress_read` chunks totalling the payload size. A `CANVAS
  FALLBACK` line means the VideoFrame path broke again — treat as a bug.
