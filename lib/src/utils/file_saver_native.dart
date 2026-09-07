// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Native implementation of the file saver. The web build replaces this
// file via the `if (dart.library.js_interop)` conditional import in
// `cimbar_file_saver.dart`.

import 'dart:io' show File;
import 'dart:typed_data' show Uint8List;

import 'package:path_provider/path_provider.dart';

Future<String> saveFile(Uint8List data, String filename) async {
  final dir = await getApplicationDocumentsDirectory();
  final safe = filename.isEmpty ? 'decoded.bin' : filename;
  final file = File('${dir.path}/$safe');
  await file.writeAsBytes(data);
  return file.path;
}
