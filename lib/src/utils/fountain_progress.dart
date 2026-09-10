// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Parsing of the fountain decoder's progress report.
///
/// `cimbard_fountain_decode` refreshes the native report string (read back
/// via `cimbard_get_report`) with the per-stream accumulation list:
/// `"[ 0.333333,0.5 ]"` — one 0..1 value per in-flight fountain stream
/// (`progress() / blocks_required()`, see `fountain_decoder_sink.h`).
///
/// This is the exact source the official receivers render: recv.js draws
/// one progress bar per stream from it, and cfc's `drawProgress()` gets
/// the same values from `concurrent_fountain_decoder_sink::get_progress()`.
library;

/// Parse a report like `"[ 0.333333,0.5 ]"` into `[0.333333, 0.5]`.
///
/// The report string is REUSED for scan diagnostics (e.g.
/// `"sce: 5.2, imgdec: 11.3"` after `scan_extract_decode`) — anything that
/// is not bracket-shaped is not progress and yields an empty list, so the
/// caller can keep the last known value instead of clobbering it.
List<double> parseFountainProgress(String report) {
  final trimmed = report.trim();
  if (trimmed.length < 2 ||
      !trimmed.startsWith('[') ||
      !trimmed.endsWith(']')) {
    return const [];
  }
  final inner = trimmed.substring(1, trimmed.length - 1).trim();
  if (inner.isEmpty) return const [];
  final values = <double>[];
  for (final part in inner.split(',')) {
    final v = double.tryParse(part.trim());
    if (v == null) return const [];
    values.add(v.clamp(0.0, 1.0));
  }
  return values;
}

/// Headline progress for a single progress bar: the most-complete
/// in-flight stream.
double maxFountainProgress(List<double> streams) {
  if (streams.isEmpty) return 0.0;
  return streams.reduce((a, b) => a > b ? a : b);
}
