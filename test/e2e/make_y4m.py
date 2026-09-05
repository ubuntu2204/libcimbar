#!/usr/bin/env python3
"""Generate a cimbar Y4M video for Chrome's fake video capture.

Composites the raw RGB frames produced by test/wasm's dump_frames
(1024x1024, barcode at native size) onto the centre of a black
1920x1080 canvas — mimicking a phone filming a fullscreen cimbar — and
converts to I420 Y4M, the exact bytes Chrome's fake camera then serves.

Frames are LOOPED so the fountain decoder sees the whole stream multiple
times. Default fps is 16 on purpose: the app's capture timer runs at
5 fps, and a 15 fps video would alias 1:3 with it (every capture landing
on the same 5 of 15 frames), which starves fountain coverage. 16 fps
drifts across all frames within seconds.

The RGB->YUV conversion is full-range BT.601 — the same coefficients
OpenCV (and the decoder's COLOR_YUV420p2RGB) uses, so the decoder sees
pixel-equivalent frames to the raw RGB originals.
"""

import argparse
import os
import sys


def rgb_to_i420(canvas, cw, ch):
    y_size = cw * ch
    c_size = (cw // 2) * (ch // 2)
    Y = bytearray(y_size)
    U = bytearray(c_size)
    V = bytearray(c_size)
    for y in range(ch):
        for x in range(cw):
            s = (y * cw + x) * 3
            r, g, b = canvas[s], canvas[s + 1], canvas[s + 2]
            Y[y * cw + x] = max(0, min(255,
                round(0.299 * r + 0.587 * g + 0.114 * b)))
            if y % 2 == 0 and x % 2 == 0:
                ci = (y // 2) * (cw // 2) + (x // 2)
                U[ci] = max(0, min(255,
                    round(-0.169 * r - 0.331 * g + 0.5 * b + 128)))
                V[ci] = max(0, min(255,
                    round(0.5 * r - 0.419 * g - 0.081 * b + 128)))
    return bytes(Y) + bytes(U) + bytes(V)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--frames', default='/tmp/libcimbar_wasm_frames',
                    help='dir with frame_NNN.rgb files')
    ap.add_argument('--out', default='/tmp/libcimbar_e2e_feed.y4m')
    ap.add_argument('--width', type=int, default=1024)
    ap.add_argument('--height', type=int, default=1024)
    ap.add_argument('--canvas', default='1920x1080',
                    help='output canvas WxH (default 1920x1080)')
    ap.add_argument('--fps', type=int, default=16)
    ap.add_argument('--loops', type=int, default=10)
    args = ap.parse_args()

    w, h = args.width, args.height
    cw, ch = (int(v) for v in args.canvas.lower().split('x'))
    if w > cw or h > ch:
        print(f'ERROR: frame {w}x{h} larger than canvas {cw}x{ch}')
        return 2

    frames = []
    for f in sorted(os.listdir(args.frames)):
        if f.endswith('.rgb'):
            d = open(os.path.join(args.frames, f), 'rb').read()
            if len(d) == w * h * 3:
                frames.append(d)
    if not frames:
        print(f'ERROR: no {w}x{h} .rgb frames in {args.frames}\n'
              '  generate them with test/wasm/run.sh (or run.sh here)')
        return 2

    ox, oy = (cw - w) // 2, (ch - h) // 2
    with open(args.out, 'wb') as out:
        out.write(f'YUV4MPEG2 W{cw} H{ch} F{args.fps}:1 Ip A1:1 C420\n'
                  .encode())
        for _ in range(args.loops):
            for d in frames:
                canvas = bytearray(cw * ch * 3)
                for y in range(h):
                    s0 = y * w * 3
                    d0 = ((oy + y) * cw + ox) * 3
                    canvas[d0:d0 + w * 3] = d[s0:s0 + w * 3]
                out.write(b'FRAME\n')
                out.write(rgb_to_i420(canvas, cw, ch))
    print(f'wrote {len(frames) * args.loops} frames '
          f'({len(frames)} unique x {args.loops}) -> {args.out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
