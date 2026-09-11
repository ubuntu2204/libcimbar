// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

/// A user-picked input file, ready to be streamed into the encoder.
///
/// Like the official sender (`send.js importFile`), the file is NOT loaded
/// into memory up front — it is read in slices while encoding.
class CimbarInputFile {
  /// Full path on disk.
  final String path;

  /// File name (without directory), embedded into the cimbar stream header
  /// so the decoder can restore the original file name.
  final String filename;

  /// Size in bytes.
  final int length;

  const CimbarInputFile({
    required this.path,
    required this.filename,
    required this.length,
  });

  /// Official sender chunk size: `send.js importFile` slices the file into
  /// `cimbare_encode_bufsize() * 16` byte reads (0x4000 * 16 == 256 KiB).
  static const int defaultChunkSize = 0x4000 * 16;

  /// Stream the file in [chunkSize] slices — the Dart equivalent of
  /// upstream `file.slice(offset, offset + chunkSize)` + `readAsArrayBuffer`.
  Stream<Uint8List> readChunks({int chunkSize = defaultChunkSize}) async* {
    final raf = await File(path).open();
    try {
      var pos = 0;
      while (pos < length) {
        final count =
            (length - pos) < chunkSize ? (length - pos) : chunkSize;
        final bytes = await raf.read(count);
        if (bytes.isEmpty) break;
        yield bytes;
        pos += bytes.length;
      }
    } finally {
      await raf.close();
    }
  }

  @override
  String toString() => 'CimbarInputFile("$filename", $length bytes)';
}

/// Open the system file picker.
///
/// Returns `null` when the user cancels the dialog.
///
/// Typical encoder flow (official single-step: pick a file and it starts
/// playing):
/// ```dart
/// final input = await pickCimbarInputFile();
/// if (input != null) {
///   await encoder.initEncodeSession(input.filename);
///   await for (final chunk in input.readChunks()) {
///     await encoder.encodeChunk(chunk);
///   }
///   await encoder.finishEncode();
///   // → play frames from encoder.nextFrame()
/// }
/// ```
Future<CimbarInputFile?> pickCimbarInputFile() async {
  final xfile = await openFile();
  if (xfile == null) return null;
  return CimbarInputFile(
    path: xfile.path,
    filename: xfile.name,
    length: await xfile.length(),
  );
}
