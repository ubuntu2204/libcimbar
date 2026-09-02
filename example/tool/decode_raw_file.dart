// Offline decode probe: feed a captured PNG (e.g. the phone's raw camera
// photo uploaded by POST /raw) straight into the native FFI decoder and
// report whether it can find the anchors and pull fountain chunks.
//
// The point is to separate "the camera never saw the barcode properly" from
// "the capture pipeline mangled a good frame": the decoder here runs on the
// file as-is, with none of the web capture's live cropping in the way.
//
// Usage:
//   dart run tool/decode_raw_file.dart <path-to-png> [path-to-libcimbar.so]
//
// It tries several pre-processing variants and prints which one(s) the
// decoder accepts, so the capture pipeline can be tuned to match.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:libcimbar/src/ffi/cimbar_decoder_ffi.dart';
import 'package:libcimbar/src/models/cimbar_config.dart';

const String kDefaultSo =
    '/home/ubuntu/project/libcimbar/native/build_linux/libcimbar.so';

/// Flatten an [img.Image] to tightly packed RGB (3 bytes/pixel).
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

/// Bounding box from row/column saturation PROFILES rather than from the
/// global extremes of every saturated pixel.
///
/// Why profiles: a plain min/max bbox is hijacked by any small saturated
/// object in the scene. Measured on the real capture, the cimbar occupies
/// y≈1040..2880 (~40% of sampled pixels saturated per row) while a small red
/// book near the bottom edge contributes only ~9% per row — yet it dragged
/// the global bbox all the way to y=3832, i.e. ~1000px of useless desk.
///
/// Projecting onto each axis and keeping only rows/columns that reach
/// [peakFrac] of the peak count drops such isolated objects cleanly.
({int x, int y, int w, int h})? findCimbarBbox(
  img.Image im, {
  int stride = 8,
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

/// Scale [src] into a black square of side [size], preserving aspect ratio
/// and centring the result (letterbox) — same as the web capture's crop path.
///
/// [Interpolation.average] matters: the default is `nearest`, which aliases
/// a fine pattern like cimbar into unreadable mush when downscaling. The
/// browser's canvas drawImage smooths by default, so an offline probe using
/// nearest would report false failures.
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

Future<void> tryVariant(
  CimbarDecoderFfi decoder,
  String label,
  img.Image im, {
  bool save = false,
  String tag = '',
}) async {
  final sw = Stopwatch()..start();
  final rgb = imageToRgb(im);
  final prepMs = sw.elapsedMilliseconds;
  sw.reset();
  final result = await decoder.decodeFrame(
    rgb,
    width: im.width,
    height: im.height,
    format: CimbarImageFormat.rgb,
  );
  final decodeMs = sw.elapsedMilliseconds;
  final verdict = result.isComplete
      ? 'COMPLETE fileId=${result.fileId}'
      : (result.error ?? 'progress=${result.progress} (scan ok, no chunk yet)');
  stdout.writeln('  $label: ${im.width}x${im.height} '
      '(prep ${prepMs}ms, decode ${decodeMs}ms) -> $verdict');
  if (save && tag.isNotEmpty) {
    final out = '/tmp/probe_$tag.png';
    await File(out).writeAsBytes(img.encodePng(im));
    stdout.writeln('      saved $out');
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/decode_raw_file.dart <png> [so-path]');
    exitCode = 1;
    return;
  }
  final pngPath = args[0];
  final soPath = args.length > 1 ? args[1] : kDefaultSo;

  final src = img.decodePng(await File(pngPath).readAsBytes());
  if (src == null) {
    stderr.writeln('failed to decode PNG: $pngPath');
    exitCode = 1;
    return;
  }
  stdout.writeln('source PNG: ${src.width} x ${src.height}');

  if (!File(soPath).existsSync()) {
    stderr.writeln('native library not found: $soPath');
    exitCode = 1;
    return;
  }
  final decoder = CimbarDecoderFfi(libraryPath: soPath);
  if (!decoder.isReady) {
    stderr.writeln('decoder failed to load $soPath');
    exitCode = 1;
    return;
  }
  stdout.writeln('decoder ready (mode B = 24x24 grid, native barcode 1024px)');
  await decoder.configure(const CimbarConfig(mode: CimbarMode.modeB));
  stdout.writeln('');

  // 1: the raw photo exactly as the sensor produced it.
  await tryVariant(decoder, '1 raw as-is           ', src);

  // 2: largest centred square (centerCrop mode).
  final crop = math.min(src.width, src.height);
  await tryVariant(
      decoder,
      '2 centre square      ',
      img.copyCrop(src,
          x: (src.width - crop) ~/ 2,
          y: (src.height - crop) ~/ 2,
          width: crop,
          height: crop));

  // 3: whole frame letterboxed into 2048 (fit mode, no auto-crop).
  await tryVariant(
      decoder, '3 fit->2048          ', fitIntoSquare(src, 2048),
      save: true, tag: 'fit2048');

  // 4+: profile-based auto-crop at a range of PADDINGS, then fitted to 2048.
  //
  // Padding is the variable under test. The saturated-pixel bbox hugs the
  // *cells* — cimbar's dark border and its four corner anchors are
  // low-saturation, so a tight crop slices them off and the scan reports
  // "found 0 anchors". Sweeping the padding shows how much margin is needed
  // before the anchors survive.
  final bbox = findCimbarBbox(src);
  if (bbox == null) {
    stdout.writeln('  profile bbox: no saturated pixels found');
  } else {
    stdout.writeln('  profile bbox: ${bbox.w} x ${bbox.h} at (${bbox.x},${bbox.y})'
        ' = ${(bbox.w * bbox.h * 100) ~/ (src.width * src.height)}% of frame'
        '  (global min/max bbox was 1929x2793 = 64%)');
    for (final pad in [0, 60, 120, 200, 320]) {
      final x0 = (bbox.x - pad).clamp(0, src.width - 1);
      final y0 = (bbox.y - pad).clamp(0, src.height - 1);
      final x1 = (bbox.x + bbox.w + pad).clamp(0, src.width);
      final y1 = (bbox.y + bbox.h + pad).clamp(0, src.height);
      final padded = img.copyCrop(src,
          x: x0, y: y0, width: x1 - x0, height: y1 - y0);
      await tryVariant(decoder, '4 crop pad=$pad ->2048  ',
          fitIntoSquare(padded, 2048),
          save: pad == 200, tag: 'crop_pad200');
    }
    // Scale sweep at the padding that keeps the anchors alive. The question
    // here is whether ANY size lets the scan pull an actual payload: the
    // pristine (camera-free) frames used by Pull+Decode report 7500B per
    // frame, so a non-zero result is the bar for "this photo is readable".
    final px0 = (bbox.x - 200).clamp(0, src.width - 1);
    final py0 = (bbox.y - 200).clamp(0, src.height - 1);
    final px1 = (bbox.x + bbox.w + 200).clamp(0, src.width);
    final py1 = (bbox.y + bbox.h + 200).clamp(0, src.height);
    final padded =
        img.copyCrop(src, x: px0, y: py0, width: px1 - px0, height: py1 - py0);

    await tryVariant(decoder, '5 crop pad=200 native ',
        padded);
    for (final size in [1024, 1500, 2048, 3072]) {
      await tryVariant(
          decoder, '6 crop pad=200 ->$size   ', fitIntoSquare(padded, size));
    }
  }

  await decoder.dispose();
}
