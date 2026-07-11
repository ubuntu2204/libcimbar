// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Stub for non-web platforms. The web build replaces this file via
// the `if (dart.library.js_interop)` conditional import in
// `decoder_page.dart`.

import 'dart:typed_data';

void downloadBytesWeb(Uint8List bytes, String filename) {
  // No-op on native platforms. Native code should use
  // path_provider + File.writeAsBytes instead.
}
