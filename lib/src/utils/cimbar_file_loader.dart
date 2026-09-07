// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

/// A user-picked input file, ready to be fed to [ICimbarEncoder.encodeData].
class CimbarInputFile {
  /// Raw file contents.
  final Uint8List bytes;

  /// File name (without directory), embedded into the cimbar stream header
  /// so the decoder can restore the original file name.
  final String filename;

  const CimbarInputFile({required this.bytes, required this.filename});

  @override
  String toString() => 'CimbarInputFile("$filename", ${bytes.length} bytes)';
}

/// Open the system file picker and read the selected file into memory.
///
/// Returns `null` when the user cancels the dialog.
///
/// Typical encoder flow:
/// ```dart
/// final input = await pickCimbarInputFile();
/// if (input != null) {
///   final frames = await encoder.encodeData(input.bytes, filename: input.filename);
/// }
/// ```
Future<CimbarInputFile?> pickCimbarInputFile() async {
  final xfile = await openFile();
  if (xfile == null) return null;
  return CimbarInputFile(
    bytes: await xfile.readAsBytes(),
    filename: xfile.name,
  );
}
