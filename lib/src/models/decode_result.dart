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

  const DecodeResult({
    this.fileId,
    this.filename = '',
    this.data,
    this.progress = 0.0,
    this.isComplete = false,
    this.error,
    this.framesDecoded = 0,
    this.estimatedTotalFrames,
  });

  /// Create a result indicating an error occurred.
  factory DecodeResult.error(String message) => DecodeResult(
        error: message,
        progress: 0.0,
      );

  /// Create a progress-only result (decode in progress).
  factory DecodeResult.inProgress({
    required double progress,
    int framesDecoded = 0,
    int? estimatedTotalFrames,
  }) =>
      DecodeResult(
        progress: progress,
        framesDecoded: framesDecoded,
        estimatedTotalFrames: estimatedTotalFrames,
      );

  /// Create a completed result with the recovered file data.
  factory DecodeResult.complete({
    required int fileId,
    required String filename,
    required Uint8List data,
    int framesDecoded = 0,
  }) =>
      DecodeResult(
        fileId: fileId,
        filename: filename,
        data: data,
        progress: 1.0,
        isComplete: true,
        framesDecoded: framesDecoded,
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
