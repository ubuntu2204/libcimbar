# WASM decoder regression test

Headless test for the cimbar **WASM** decoder, run in Node.

## Why

When the web app cannot decode, there are two very different suspects:

1. the WASM build itself is broken, or
2. the web capture chain (camera → canvas → RGB) is degrading the frames.

From the browser console these look identical. This test settles it, because
it feeds **lossless** frames — taken straight from the encoder's own buffer —
into the WASM decoder, bypassing the camera entirely.

It is what found the auto-crop upscale bug: the web code was enlarging a
~944px barcode to a 2048 canvas (~2.2x) with smooth interpolation, which
dropped sharpness to ~5% of the original and made `scan_extract_decode` fail
with `-3` (fewer than 4 corner anchors found). Nearest-neighbour scaling
keeps the frames decodable.

## Requirements

- `node`
- `g++` (or set `CXX`) — only to build `dump_frames`
- `native/build_linux/libcimbar.so` — only to generate the test frames

## Run

```bash
./run.sh                  # standard
./run.sh --scale 2        # also verify at 2x (nearest-neighbour upscale)
./run.sh --verbose        # per-frame detail
```

Exit code `0` = decoded, `1` = **not decoded** (the regression signal),
`2` = setup problem.

## Run directly

```bash
node wasm_decode_test.js --frames /path/to/frames [--scale N] [--verbose]
```

| Flag | Meaning |
|---|---|
| `--wasm DIR` | wasm assets dir (default `decode_example/web/assets/wasm`) |
| `--frames DIR` | dir containing `frame_NNN.rgb` |
| `--scale N` | nearest-neighbour upscale factor, tests size without blur |
| `--width/--height` | source frame dimensions (default 1024x1024) |
| `--verbose` | per-frame scan time and native report |

## Real-video test

`decode_video.sh` runs the same decoder against frames extracted from a
**real recorded video** (e.g. a phone filming the encoder screen) — no
browser needed, finishes in seconds:

```bash
./decode_video.sh                      # default fixture (test/74c1430d...mp4)
./decode_video.sh /path/to/clip.mp4    # any video
./decode_video.sh clip.mp4 --every 3 --verbose
```

Requires `ffmpeg`/`ffprobe` and `node`. The default fixture is a 720x1280
phone recording that decodes on its first sampled frame. For the full
in-browser end-to-end run (also drives a video through Chrome's fake
camera into the actual app), see `test/e2e/` — much slower, so prefer
this script for routine checks.

## Files

| File | Role |
|---|---|
| `run.sh` | builds `dump_frames`, generates frames, runs the test |
| `decode_video.sh` | decodes frames extracted from a real video (ffmpeg) |
| `dump_frames.cpp` | encodes a payload, dumps raw RGB frames |
| `wasm_decode_test.js` | drives `cimbard_*` via the emscripten module |

`dump_frames` writes frames from the encoder buffer with no resampling, so a
failure here is unambiguously a decoder problem. It generates its own
deterministic payload (fixed seed) when no input file is given.

## Notes

- The decoder is configured with a mode toggle (`4` then `68`): the native
  fountain sink only refreshes when the mode value changes, so configuring
  twice with the same value would leave a completed stream in place.
- Frames land in `${TMPDIR:-/tmp}/libcimbar_wasm_frames` (~3 MB each at
  1024x1024 RGB).
- `run.sh` cleans that directory before each run.
