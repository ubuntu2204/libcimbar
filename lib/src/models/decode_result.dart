// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

/// Result of a cimbar decode operation.
class DecodeResult {
  /// Unique file identifier assigned by the fountain decoder.
  final int? fileId;

  /// Original filename embedded in the cimbar stream (may be empty).
  final String filename;

  /// Decoded file data (populated when [isComplete] is true).
  final Uint8List? data;

  /// Decoding progress from 0.0 (just started) to 1.0 (complete).
  final double progress;

  /// Whether all fountain blocks have been received and the file is ready.
  final bool isComplete;

  /// Human-readable error message, or null if no error.
  final String? error;

  /// Number of frames successfully decoded so far.
  final int framesDecoded;

  /// Estimated total frames needed (if known).
  final int? estimatedTotalFrames;

  /// Fountain payload bytes recovered from THIS frame (0 when the frame
  /// located the barcode but yielded no payload).
  ///
  /// Mirrors cfc's per-frame `decodeRes` — the value its guidance
  /// status machine feeds on (`decoded` grows when this is > 0).
  final int frameBytesDecoded;

  /// Full-frame fountain payload capacity (chunks per frame x chunk size,
  /// i.e. `cimbard_get_bufsize()`), the denominator cfc uses for its
  /// "perfect frame" test (`decodeRes >= capacity * 0.7`).
  final int frameCapacity;

  /// Mode value the Auto rotation locked onto on THIS frame (recv.js
  /// `setMode` / cfc `detected_mode`). Null = no lock happened; non-null
  /// means every following frame is scanned with this mode.
  final int? detectedMode;

  /// Per-stream fountain progress, one 0..1 value per in-flight stream —
  /// the exact list the official receivers render: cfc's
  /// `drawProgress(get_progress())` and recv.js's `render_progress(report)`
  /// both draw ONE bar per entry, updated every frame.
  ///
  /// Empty when the sink holds no in-flight streams (nothing drawn — the
  /// official behaviour too: cfc returns early on an empty list).
  final List<double> streamProgress;

  const DecodeResult({
    this.fileId,
    this.filename = '',
    this.data,
    this.progress = 0.0,
    this.isComplete = false,
    this.error,
    this.framesDecoded = 0,
    this.estimatedTotalFrames,
    this.frameBytesDecoded = 0,
    this.frameCapacity = 0,
    this.detectedMode,
    this.streamProgress = const [],
  });

  /// Create a result indicating an error occurred.
  ///
  /// [streamProgress] carries the sink's last known per-stream state: cfc
  /// draws `get_progress()` every frame regardless of whether THIS frame
  /// decoded, so the bars never blink off on a bad frame.
  factory DecodeResult.error(String message, {int frameBytesDecoded = 0,
      int frameCapacity = 0, List<double> streamProgress = const []}) =>
      DecodeResult(
        error: message,
        progress: 0.0,
        frameBytesDecoded: frameBytesDecoded,
        frameCapacity: frameCapacity,
        streamProgress: streamProgress,
      );

  /// Create a progress-only result (decode in progress).
  factory DecodeResult.inProgress({
    required double progress,
    int framesDecoded = 0,
    int? estimatedTotalFrames,
    int frameBytesDecoded = 0,
    int frameCapacity = 0,
    int? detectedMode,
    List<double> streamProgress = const [],
  }) =>
      DecodeResult(
        progress: progress,
        framesDecoded: framesDecoded,
        estimatedTotalFrames: estimatedTotalFrames,
        frameBytesDecoded: frameBytesDecoded,
        frameCapacity: frameCapacity,
        detectedMode: detectedMode,
        streamProgress: streamProgress,
      );

  /// Create a completed result with the recovered file data.
  factory DecodeResult.complete({
    required int fileId,
    required String filename,
    required Uint8List data,
    int framesDecoded = 0,
    int? detectedMode,
  }) =>
      DecodeResult(
        fileId: fileId,
        filename: filename,
        data: data,
        progress: 1.0,
        isComplete: true,
        framesDecoded: framesDecoded,
        detectedMode: detectedMode,
      );

  @override
  String toString() {
    if (isComplete) {
      return 'DecodeResult(complete, file: "$filename", '
          '${data?.length ?? 0} bytes, $framesDecoded frames)';
    }
    if (error != null) return 'DecodeResult(error: $error)';
    return 'DecodeResult(progress: ${(progress * 100).toStringAsFixed(1)}%, '
        '$framesDecoded frames)';
  }
}
