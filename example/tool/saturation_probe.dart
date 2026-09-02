// Diagnostic: where exactly are the "saturated" pixels that the auto-crop
// detector is picking up?
//
// The offline decode probe showed the bbox spanning ~64% of the frame, which
// is far larger than the cimbar itself — meaning background (wood, book,
// monitor edges) is passing the saturation test. This tool prints a coarse
// band profile (rows and columns) plus representative pixel samples so the
// threshold can be set from real numbers instead of guesswork.
//
// Usage:
//   dart run tool/saturation_probe.dart <png> [stride]

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

Future<void> main(List<String> args) async {
  final path = args[0];
  final stride = args.length > 1 ? int.parse(args[1]) : 8;

  final src = img.decodePng(await File(path).readAsBytes());
  if (src == null) {
    stderr.writeln('PNG decode failed: $path');
    exitCode = 1;
    return;
  }
  stdout.writeln('image: ${src.width} x ${src.height}  (stride $stride)');
  stdout.writeln('');

  // For each sampled pixel record (row, col, saturation).
  // We bucket saturation into bands so the dominant background level shows up.
  const thresholds = [50, 100, 150, 200];
  final counts = {for (final t in thresholds) t: 0};
  final rowsHit = {for (final t in thresholds) t: <int>[]};
  final colsHit = {for (final t in thresholds) t: <int>[]};

  const int rowBands = 24;
  const int colBands = 12;
  final rowBandHits =
      List.generate(thresholds.length, (_) => List<int>.filled(rowBands, 0));
  final colBandHits =
      List.generate(thresholds.length, (_) => List<int>.filled(colBands, 0));
  final rowBandTotal = List<int>.filled(rowBands, 0);
  final colBandTotal = List<int>.filled(colBands, 0);

  int samples = 0;
  for (var y = 0; y < src.height; y += stride) {
    final rb = (y * rowBands ~/ src.height).clamp(0, rowBands - 1);
    for (var x = 0; x < src.width; x += stride) {
      final cb = (x * colBands ~/ src.width).clamp(0, colBands - 1);
      final p = src.getPixel(x, y);
      final r = p.r.toInt();
      final g = p.g.toInt();
      final b = p.b.toInt();
      final mn = math.min(r, math.min(g, b));
      final mx = math.max(r, math.max(g, b));
      final sat = mx - mn;
      samples++;
      rowBandTotal[rb]++;
      colBandTotal[cb]++;
      for (var ti = 0; ti < thresholds.length; ti++) {
        if (sat >= thresholds[ti]) {
          counts[thresholds[ti]] = counts[thresholds[ti]]! + 1;
          rowBandHits[ti][rb]++;
          colBandHits[ti][cb]++;
        }
      }
      if (sat >= 100) {
        rowsHit[100]!.add(y);
        colsHit[100]!.add(x);
      }
    }
  }

  stdout.writeln('saturation vs threshold (of $samples samples):');
  for (final t in thresholds) {
    final c = counts[t]!;
    stdout.writeln('  sat >= $t : $c  (${(c * 1000 ~/ samples) / 10}%)');
  }
  stdout.writeln('');

  void printBands(String label, List<int> totals, List<List<int>> hits,
      int bands, int extent, String axis) {
    stdout.writeln('$label (each row = one horizontal/vertical band):');
    for (var i = 0; i < bands; i++) {
      if (totals[i] == 0) continue;
      final pct100 = hits[thresholds.indexOf(100)][i] * 100 ~/ totals[i];
      final pct150 = hits[thresholds.indexOf(150)][i] * 100 ~/ totals[i];
      final bar = '#' * (pct100 ~/ 4);
      stdout.writeln(
          '  $axis ${(i * extent ~/ bands).toString().padLeft(4)}-'
          '${(((i + 1) * extent ~/ bands) - 1).toString().padLeft(4)}: '
          'sat>=100 ${pct100.toString().padLeft(3)}%  '
          'sat>=150 ${pct150.toString().padLeft(3)}%  $bar');
    }
    stdout.writeln('');
  }

  printBands('SATURATION BY ROW', rowBandTotal, rowBandHits, rowBands,
      src.height, 'y');
  printBands('SATURATION BY COLUMN', colBandTotal, colBandHits, colBands,
      src.width, 'x');

  if (rowsHit[100]!.isNotEmpty) {
    stdout.writeln('sat>=100 pixel extent: '
        'x ${colsHit[100]!.reduce(math.min)}..${colsHit[100]!.reduce(math.max)}, '
        'y ${rowsHit[100]!.reduce(math.min)}..${rowsHit[100]!.reduce(math.max)}');
  }
}
