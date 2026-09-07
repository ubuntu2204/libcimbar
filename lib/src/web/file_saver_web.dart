// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Web implementation of the file saver: triggers a browser download via
// a temporary <a download> link. Selected by the conditional import in
// `cimbar_file_saver.dart`.

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<String> saveFile(Uint8List data, String filename) async {
  final safe = filename.isEmpty ? 'decoded.bin' : filename;
  // 1. Build a Blob from the bytes.
  final parts = <JSAny>[data.toJS].toJS;
  final options = web.BlobPropertyBag(type: 'application/octet-stream');
  final blob = web.Blob(parts, options);

  // 2. Mint an object URL for the Blob.
  final url = web.URL.createObjectURL(blob);

  // 3. Synthesize a click on a hidden <a download> link.
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = safe;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();

  // 4. Free the blob URL.
  web.URL.revokeObjectURL(url);
  return safe;
}
