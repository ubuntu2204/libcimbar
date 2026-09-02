// End-to-end simulation of the WEB capture pipeline, run offline against a
// real raw camera photo, sweeping the auto-crop PADDING.
//
// The web pipeline is: raw frame -> fit into 2048 square -> scan for the
// saturated bbox -> pad -> crop -> scale back to 2048 -> decoder.
// This tool replays exactly those steps in Dart (using the same stride and
// threshold as web_camera_capture.dart) so the padding parameter can be
// tuned against the real decoder instead of guessed.
//
// Usage:
//   dart run tool/pipeline_pad_sweep.dart <raw-png> [so-path]

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:libcimbar/src/ffi/cimbar_decoder_ffi.dart';
import 'package:libcimbar/src/models/cimbar_config.dart';

const String kDefaultSo =
    '/home/ubuntu/project/libcimbar/native/build_linux/libcimbar.so';

/// Mirrors [WebCaptureMode.fit]: letterbox the whole frame into a square.
img.Image fitIntoSquare(img.Image src, int size) {
  final canvas = img.Image(width: size, height: size);
  img.fill(canvas, color: img.ColorRgb8(0, 0, 0));
  final scale = size / math.max(src.width, src.height);
  final dw = (src.width * scale).round().clamp(1, size);
  final dh = (src.height * scale).round().clamp(1, size);
  final resized = img.copyResize(src,
      width: dw, height: dh, interpolation: img.Interpolation.average);
  img.compositeImage(canvas, resized,
      dstX: (size - dw) ~/ 2, dstY: (size - dh) ~/ 2);
  return canvas;
}

/// Mirrors [WebCaptureMode.centerCrop]: take the largest centred square and
/// scale it to fill the target.
img.Image centerCropToSquare(img.Image src, int size) {
  final crop = math.min(src.width, src.height);
  final squared = img.copyCrop(src,
      x: (src.width - crop) ~/ 2,
      y: (src.height - crop) ~/ 2,
      width: crop,
      height: crop);
  return img.copyResize(squared,
      width: size, height: size, interpolation: img.Interpolation.average);
}

/// Row/column projection bbox — see decode_raw_file.dart for why a plain
/// min/max over every saturated pixel is not good enough.
({int x, int y, int w, int h})? findCimbarBbox(
  img.Image im, {
  int stride = 16,
  int satThresh = 100,
  double peakFrac = 0.35,
}) {
  final rows = (im.height + stride - 1) ~/ stride;
  final cols = (im.width + stride - 1) ~/ stride;
  final rowCounts = List<int>.filled(rows, 0);
  final colCounts = List<int>.filled(cols, 0);

  for (var ri = 0; ri < rows; ri++) {
    final y = ri * stride;
    if (y >= im.height) break;
    for (var ci = 0; ci < cols; ci++) {
      final x = ci * stride;
      if (x >= im.width) break;
      final p = im.getPixel(x, y);
      final r = p.r.toInt();
      final g = p.g.toInt();
      final b = p.b.toInt();
      final mx = math.max(r, math.max(g, b));
      final mn = math.min(r, math.min(g, b));
      if (mx - mn >= satThresh) {
        rowCounts[ri]++;
        colCounts[ci]++;
      }
    }
  }
  var rowPeak = 0;
  var colPeak = 0;
  for (final c in rowCounts) {
    if (c > rowPeak) rowPeak = c;
  }
  for (final c in colCounts) {
    if (c > colPeak) colPeak = c;
  }
  if (rowPeak == 0 || colPeak == 0) return null;
  final rowThresh = (rowPeak * peakFrac).round();
  final colThresh = (colPeak * peakFrac).round();

  int minRi = -1, maxRi = -1;
  for (var i = 0; i < rows; i++) {
    if (rowCounts[i] >= rowThresh) {
      if (minRi < 0) minRi = i;
      maxRi = i;
    }
  }
  int minCi = -1, maxCi = -1;
  for (var i = 0; i < cols; i++) {
    if (colCounts[i] >= colThresh) {
      if (minCi < 0) minCi = i;
      maxCi = i;
    }
  }
  if (minRi < 0 || minCi < 0) return null;
  final y0 = minRi * stride;
  final y1 = (((maxRi + 1) * stride).clamp(0, im.height)) - 1;
  final x0 = minCi * stride;
  final x1 = (((maxCi + 1) * stride).clamp(0, im.width)) - 1;
  return (x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1);
}

Uint8List imageToRgb(img.Image im) {
  final out = Uint8List(im.width * im.height * 3);
  var o = 0;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final p = im.getPixel(x, y);
      out[o++] = p.r.toInt();
      out[o++] = p.g.toInt();
      out[o++] = p.b.toInt();
    }
  }
  return out;
}

Future<void> main(List<String> args) async {
  final raw = img.decodePng(await File(args[0]).readAsBytes());
  if (raw == null) {
    stderr.writeln('PNG decode failed');
    exitCode = 1;
    return;
  }
  final soPath = args.length > 1 ? args[1] : kDefaultSo;
  final decoder = CimbarDecoderFfi(libraryPath: soPath);
  if (!decoder.isReady) {
    stderr.writeln('decoder not ready');
    exitCode = 1;
    return;
  }
  await decoder.configure(const CimbarConfig(mode: CimbarMode.modeB));

  stdout.writeln('raw: ${raw.width} x ${raw.height}');

  // Run both framings back to back so the default choice is backed by the
  // decoder's own verdict rather than by pixel-count arithmetic.
  for (final mode in ['centerCrop', 'fit']) {
    await _runMode(decoder, raw, mode);
  }

  await decoder.dispose();
}

Future<void> _runMode(
    CimbarDecoderFfi decoder, img.Image raw, String mode) async {
  const int target = 2048;
  stdout.writeln('');
  stdout.writeln('═══ mode=$mode ═══');

  // Step 1 — build the 2048 canvas the way each capture mode does.
  final canvas = mode == 'fit'
      ? fitIntoSquare(raw, target)
      : centerCropToSquare(raw, target);
  stdout.writeln('after $mode->$target: ${canvas.width} x ${canvas.height}');

  // Step 2 — detect the bbox exactly as the web code does (stride 16).
  final bbox = findCimbarBbox(canvas);
  if (bbox == null) {
    stdout.writeln('no saturated bbox found in the $mode canvas');
    return;
  }
  stdout.writeln('bbox in canvas: ${bbox.w} x ${bbox.h} at (${bbox.x},${bbox.y})'
      ' = ${(bbox.w * bbox.h * 100) ~/ target ~/ target}% of canvas');
  stdout.writeln('');
  stdout.writeln('padding sweep:');

  for (final pad in [0, 16, 32, 48, 64, 96, 128]) {
    final x0 = (bbox.x - pad).clamp(0, canvas.width - 1);
    final y0 = (bbox.y - pad).clamp(0, canvas.height - 1);
    final x1 = (bbox.x + bbox.w + pad).clamp(0, canvas.width);
    final y1 = (bbox.y + bbox.h + pad).clamp(0, canvas.height);
    final cropped = img.copyCrop(canvas,
        x: x0, y: y0, width: x1 - x0, height: y1 - y0);
    // Step 3 — scale the crop back up to the decoder input, as the web code does.
    final finalImg = fitIntoSquare(cropped, target);
    final rgb = imageToRgb(finalImg);
    final result = await decoder.decodeFrame(rgb,
        width: finalImg.width, height: finalImg.height);
    final verdict = result.isComplete
        ? 'COMPLETE'
        : (result.error ?? 'scan ok, 0 bytes payload');
    final flag = (result.error == null) ? ' <-- anchors found' : '';
    stdout.writeln(
        '  pad=$pad: crop ${x1 - x0}x${y1 - y0} -> ${finalImg.width}x${finalImg.height}'
        ' => $verdict$flag');
  }
}
