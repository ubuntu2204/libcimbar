// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Integration test against the real desktop libcimbar.so — the full
// official sender flow (send.js importFile → nextFrame):
//
//   configure → initEncodeSession → encodeChunk* → finishEncode → nextFrame*
//
// Skips automatically when the shared library has not been built yet.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libcimbar/src/ffi/cimbar_encoder_ffi.dart';
import 'package:libcimbar/src/interfaces/cimbar_encoder_interface.dart';
import 'package:libcimbar/src/models/cimbar_config.dart';
import 'package:libcimbar/src/utils/cimbar_file_loader.dart';

void main() {
  final so = File('native/build_linux/libcimbar.so');
  if (!so.existsSync()) {
    test('encoder stream (build libcimbar.so first)', () {});
    return;
  }

  late ICimbarEncoder encoder;

  setUpAll(() async {
    encoder = CimbarEncoderFfi(libraryPath: so.absolute.path);
  });

  tearDownAll(() async {
    await encoder.dispose();
  });

  test('official send.js flow: configure → init → chunks → frames forever',
      () async {
    // Official defaults: mode B, compression 16.
    await encoder.configure(const CimbarConfig(mode: CimbarMode.modeB));

    // Official encode_init: filename goes into the stream header, -1
    // auto-increments the encode id.
    await encoder.initEncodeSession('stream_test_payload.bin',
        encodeId: 100);

    // Official importFile: feed the file in slices.
    final payload = Uint8List.fromList(
        List.generate(60 * 1024, (i) => (i * 7 + 3) & 0xFF));
    const chunkSize = CimbarInputFile.defaultChunkSize;
    for (var off = 0; off < payload.length; off += chunkSize) {
      final end = (off + chunkSize) < payload.length
          ? (off + chunkSize)
          : payload.length;
      final status = await encoder.encodeChunk(
          Uint8List.sublistView(payload, off, end));
      expect(status, greaterThanOrEqualTo(0),
          reason: 'cimbare_encode failed at offset $off');
    }
    // Official null flush.
    await encoder.finishEncode();

    // The stream is infinite: nextFrame() must keep producing frames.
    // 60 KB at mode B restarts every ~8 frames; 30 frames proves the loop
    // survives at least one restart.
    const wantFrames = 30;
    final seenIndexes = <int>[];
    for (var i = 0; i < wantFrames; i++) {
      final frame = await encoder.nextFrame();
      expect(frame, isNotNull, reason: 'frame $i was not produced');
      expect(frame!.width, 1024);
      expect(frame.height, 1024);
      expect(frame.pixels.length, 1024 * 1024 * 3);
      // Not a blank frame: the barcode grid carries non-black pixels
      // (the outer border rows are black, so scan the whole frame).
      expect(frame.pixels.any((b) => b != 0), isTrue);
      seenIndexes.add(frame.index);
    }
    // Indexes increase monotonically and wrap back to 0 after a restart.
    for (var i = 1; i < seenIndexes.length; i++) {
      final prev = seenIndexes[i - 1];
      final cur = seenIndexes[i];
      expect(cur == prev + 1 || (prev > cur && cur == 0), isTrue,
          reason: 'non-monotonic index sequence: $seenIndexes');
    }
  });

  // NOTE: there is no "fresh encoder" test — the cimbare C API keeps ONE
  // encoder per process (upstream cimbar_js.cpp holds `_fes` in a global),
  // exactly like one wasm Module in the official web sender.
}
