// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:typed_data' show Uint8List;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../models/cimbar_frame.dart';

/// The per-frame display nudge used by upstream cimbar, plus the geometry
/// the barcode needs around it.
///
/// Ported from `gl_2d_display::computeShakePos` (upstream
/// `src/lib/gui/gl_2d_display.h`), which cycles the texture through 4
/// positions offset by `8.0 / dim` (dim = 1080).
///
/// Why bother: a static barcode burns in, and — the part that matters for
/// decoding — a still image lets the screen↔camera interference pattern
/// (moiré) sit perfectly still, so the camera never gets a clean frame to
/// lock onto.
class CimbarShake {
  const CimbarShake._();

  /// Native size of the barcode, and the size it must always be painted at.
  static const double displayDim = 1024.0;

  /// Nudge distance: upstream's `8.0 / 1080`, scaled to the display.
  static const double stepPx = 8.0 / 1080.0 * displayDim;

  /// The 4 positions from `computeShakePos`: centre, down-left, centre,
  /// up-right.
  static const List<double> offsets = <double>[
    0.0,
    -stepPx,
    0.0,
    stepPx,
  ];

  /// Black gutter kept around the barcode so the nudge cannot crop it.
  ///
  /// NOT cosmetic. cimbar's 4 corner anchors sit near the image edge, so
  /// translating a 1024px barcode inside a 1024px box shears part of them
  /// off and the frame stops decoding entirely. Measured against the
  /// official decoder: a 7px shift with no gutter FAILS, the same shift
  /// with a 16px gutter passes.
  static const double margin = 16.0;

  /// Size of the widget box: barcode plus the gutter on each side.
  static const double boxDim = displayDim + 2 * margin;
}

/// Plays [CimbarFrame]s as the official sender does: a fixed-rate frame
/// loop (default 15 fps) with the upstream-style per-frame display nudge
/// ([CimbarShake]), rendered nearest-neighbour at >= 1:1 pixel scale so the
/// tile grid stays crisp and decodable.
///
/// Frames are decoded lazily (one [ui.Image] at a time) so arbitrarily
/// large encodings do not exhaust GPU memory; if a frame is still decoding
/// when the next tick fires, the tick is skipped — playback simply holds
/// the current frame until it is ready.
///
/// Typical use (encoder app):
/// ```dart
/// final frames = await encoder.encodeData(bytes, filename: 'file.bin');
/// CimbarFramePlayer(frames: frames, fps: 15);
/// ```
class CimbarFramePlayer extends StatefulWidget {
  const CimbarFramePlayer({
    super.key,
    required this.frames,
    this.fps = 15,
    this.playing = true,
    this.shake = true,
    this.backgroundColor = const Color(0xFF000000),
    this.onFrameChanged,
  });

  /// Frames to play, as produced by [ICimbarEncoder.encodeData].
  final List<CimbarFrame> frames;

  /// Playback rate in frames per second. The official sender default is 15.
  final int fps;

  /// Whether the frame loop is running. Pausing keeps the current frame
  /// (and the current shake step) on screen.
  final bool playing;

  /// Whether to apply the upstream-style display nudge. Should stay `true`
  /// for camera decoding (anti-moiré / burn-in); exposed so a still preview
  /// can opt out.
  final bool shake;

  /// Backdrop behind the barcode gutter.
  final Color backgroundColor;

  /// Notified after each displayed frame change.
  final ValueChanged<int>? onFrameChanged;

  @override
  State<CimbarFramePlayer> createState() => _CimbarFramePlayerState();
}

class _CimbarFramePlayerState extends State<CimbarFramePlayer> {
  Timer? _timer;

  /// Index of the frame currently *displayed* (already decoded to an image).
  int _frameIndex = 0;

  /// Index into [CimbarShake.offsets], advanced once per displayed frame.
  int _shakeStep = 0;

  /// The decoded image of frame [_frameIndex] (at most one is alive).
  ui.Image? _image;

  /// Guards against out-of-order decode callbacks and use-after-dispose.
  int _decodeToken = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _decodeAndShow(0, advanceShake: false);
    if (widget.playing) _startTimer();
  }

  @override
  void didUpdateWidget(covariant CimbarFramePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.frames, widget.frames)) {
      // New encode: restart from frame 0 with fresh state.
      if (widget.frames.isEmpty) {
        _decodeToken++;
        _stopTimer();
        setState(() {
          _image?.dispose();
          _image = null;
          _frameIndex = 0;
          _shakeStep = 0;
        });
      } else {
        // Clear the shown image first: _decodeAndShow skips when the target
        // index is unchanged and an image is displaying, which would keep
        // frame 0 of the PREVIOUS encode on screen instead of the new one.
        _decodeToken++;
        setState(() {
          _image?.dispose();
          _image = null;
          _frameIndex = 0;
          _shakeStep = 0;
        });
        _decodeAndShow(0, advanceShake: false);
      }
    }
    if (oldWidget.playing != widget.playing) {
      if (widget.playing) {
        _startTimer();
      } else {
        _stopTimer();
      }
    } else if (widget.playing &&
        (oldWidget.fps != widget.fps ||
            !identical(oldWidget.frames, widget.frames))) {
      _startTimer(); // re-arm with the new period
    }
  }

  void _startTimer() {
    _stopTimer();
    if (widget.frames.isEmpty) return;
    final fps = widget.fps <= 0 ? 1 : widget.fps;
    _timer = Timer.periodic(Duration(milliseconds: 1000 ~/ fps), (_) {
      if (!mounted || widget.frames.isEmpty) return;
      final next = (_frameIndex + 1) % widget.frames.length;
      _decodeAndShow(next);
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// Decode [index] to a [ui.Image] and swap it in (advancing the shake step
  /// together with the frame, so the two never disagree).
  void _decodeAndShow(int index, {bool advanceShake = true}) {
    if (widget.frames.isEmpty) return;
    index = index % widget.frames.length;
    if (index == _frameIndex && _image != null) return;
    final token = ++_decodeToken;
    _decodeFrame(widget.frames[index], (image) {
      if (_disposed || token != _decodeToken || !mounted) {
        image.dispose();
        return;
      }
      // Only now advance the visible state, atomically.
      setState(() {
        _frameIndex = index;
        if (advanceShake) {
          _shakeStep = (_shakeStep + 1) % CimbarShake.offsets.length;
        }
        _image?.dispose();
        _image = image;
      });
      widget.onFrameChanged?.call(index);
    });
  }

  /// RGB (3 bytes/px) -> [ui.Image].
  ///
  /// `decodeImageFromPixels` copies the buffer, so the scratch RGBA buffer
  /// can be reused for the next frame as soon as this returns.
  void _decodeFrame(CimbarFrame frame, void Function(ui.Image image) onDone) {
    final pixelCount = frame.width * frame.height;
    final rgba = _rgbaScratch(pixelCount * 4);
    final src = frame.pixels;
    final dst = rgba;
    for (int i = 0, s = 0, d = 0; i < pixelCount; i++, s += 3, d += 4) {
      dst[d] = src[s];
      dst[d + 1] = src[s + 1];
      dst[d + 2] = src[s + 2];
      dst[d + 3] = 255;
    }
    ui.decodeImageFromPixels(
      rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      onDone,
    );
  }

  // Reuses a single scratch buffer across decodes to avoid churning a 4MB
  // allocation per frame.
  Uint8List? _scratch;

  Uint8List _rgbaScratch(int length) {
    final s = _scratch;
    if (s == null || s.length < length) {
      _scratch = Uint8List(length);
      return _scratch!;
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.frames.isEmpty) {
      return SizedBox(
        width: CimbarShake.boxDim,
        height: CimbarShake.boxDim,
        child: ColoredBox(color: widget.backgroundColor),
      );
    }
    final Widget barcode = SizedBox(
      width: CimbarShake.displayDim,
      height: CimbarShake.displayDim,
      child: CustomPaint(
        painter: _CimbarImagePainter(image: _image),
      ),
    );
    final Widget body = widget.shake
        ? Transform.translate(
            offset: Offset(
              CimbarShake.offsets[_shakeStep % CimbarShake.offsets.length],
              CimbarShake.offsets[_shakeStep % CimbarShake.offsets.length],
            ),
            child: barcode,
          )
        : barcode;
    return SizedBox(
      width: CimbarShake.boxDim,
      height: CimbarShake.boxDim,
      child: ColoredBox(
        color: widget.backgroundColor,
        child: Center(child: body),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _decodeToken++;
    _stopTimer();
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}

/// Paints the current barcode image as a centered square, uniformly scaled
/// (never distorted) and with no interpolation, so the tile grid stays
/// crisp and decodable.
class _CimbarImagePainter extends CustomPainter {
  final ui.Image? image;
  _CimbarImagePainter({required this.image});

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img == null) return;
    // Largest centered square that fits - keeps the barcode square even if
    // the canvas is not, instead of stretching it.
    final double side = size.shortestSide;
    final double dx = (size.width - side) / 2;
    final double dy = (size.height - side) / 2;
    // FilterQuality.none: nearest-neighbour, so tiles are not blurred by
    // interpolation (critical for decoding, especially at DPI scale != 1).
    final paint = Paint()..filterQuality = FilterQuality.none;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(dx, dy, side, side),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CimbarImagePainter old) => old.image != image;
}
