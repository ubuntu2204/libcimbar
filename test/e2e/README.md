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

Standalone use against an already-running app:

```bash
python3 headless_e2e.py --url http://127.0.0.1:8903/?autostart=1 \
    --y4m /tmp/libcimbar_e2e_feed.y4m --seconds 45
```

## Notes

- The `?autostart=1` hook lives in `decoder_page.dart` (starts the camera
  after init; Flutter's canvas UI is impractical to click from
  automation).
- The Y4M defaults to **16 fps** on purpose: the app captures at 5 fps,
  and a 15 fps video aliases 1:3 with the capture timer so only 5 of the
  15 unique frames ever get sampled (fountain coverage starves at ~0.6).
- RGB->YUV uses full-range BT.601 — the inverse of the decoder's
  `COLOR_YUV420p2RGB`, so frames arrive pixel-equivalent to the raw RGB.
- Expected healthy run: `via VideoFrame: I420 ... -> yuv420` in the log,
  a positive `fountain_decode => <id>` after ~9 scanned frames, then
  `decompress_read` chunks totalling the payload size. A `CANVAS
  FALLBACK` line means the VideoFrame path broke again — treat as a bug.
