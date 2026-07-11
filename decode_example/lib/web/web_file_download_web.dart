// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Real web implementation. Replaces the stub on the web build via
// the `if (dart.library.js_interop)` conditional import in
// `decoder_page.dart`.

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Trigger a browser download of [bytes] saved as [filename].
///
/// Creates a temporary `<a download>` link, clicks it, and revokes the
/// underlying blob URL. Safe to call from the event handler of a
/// Flutter `OutlinedButton.icon`.
void downloadBytesWeb(Uint8List bytes, String filename) {
  // 1. Build a Blob from the bytes.
  final parts = <JSAny>[bytes.buffer.asUint8List().toJS].toJS;
  final options = web.BlobPropertyBag(type: 'image/png');
  final blob = web.Blob(parts, options);

  // 2. Mint an object URL for the Blob.
  final url = web.URL.createObjectURL(blob);

  // 3. Synthesize a click on a hidden <a download> link.
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();

  // 4. Free the blob URL.
  web.URL.revokeObjectURL(url);
}
