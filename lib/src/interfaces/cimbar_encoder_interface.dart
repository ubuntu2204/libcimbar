// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import '../models/cimbar_config.dart';
import '../models/cimbar_frame.dart';

/// Abstract interface for cimbar encoding.
///
/// The API mirrors the official sender flow one-to-one — upstream
/// `web/send.js` + `src/exe/cimbar_send/send.cpp` driving the `cimbare_*`
/// C API:
///
///   1. [configure]                     → `cimbare_configure`
///   2. [initEncodeSession]             → `cimbare_init_encode` (embeds the
///                                         filename into the stream header,
///                                         auto-increments the encode id)
///   3. [encodeChunk] until done        → `cimbare_encode`
///   4. [nextFrame] in a loop, forever  → `cimbare_next_frame` +
///                                         `cimbare_get_frame_buff`
///
/// Like the official senders, the fountain stream is *infinite*:
/// [nextFrame] keeps producing frames forever (the stream restarts after
/// 8x the required symbol blocks, exactly as upstream `cimbar_js.cpp`
/// does). Playback is a loop; there is no "last frame".
abstract class ICimbarEncoder {
  /// Whether the underlying native library is loaded and ready.
  bool get isReady;

  /// Apply encoding configuration (mode + zstd compression level).
  ///
  /// Must be called before [initEncodeSession].
  Future<void> configure(CimbarConfig config);

  /// Start an encode session for one file (official `encode_init`).
  ///
  /// [filename] is embedded in the cimbar stream header so the receiver
  /// can reconstruct the original file with its name. [encodeId] follows
  /// the upstream convention: -1 auto-increments the session id (which
  /// gives the decoder a better color distribution in the first frame
  /// header it sees), 0-127 sets it explicitly.
  Future<void> initEncodeSession(String filename, {int encodeId = -1});

  /// Feed the next chunk of file data (official `encode_bytes`).
  ///
  /// Chunk size is arbitrary — the official sender reads in
  /// 16 x `cimbare_encode_bufsize()` slices (`send.js importFile`).
  ///
  /// Returns the raw upstream status: `1` = expect more data, `0` = the
  /// fountain stream is ready, `<0` = error.
  Future<int> encodeChunk(Uint8List chunk);

  /// Flush and finish the current session (official: `encode_bytes(null)`).
  ///
  /// After this resolves, [nextFrame] is ready to produce frames.
  Future<void> finishEncode();

  /// Produce the next cimbar frame (official `nextFrame` in send.js).
  ///
  /// Returns `null` if the encoder has no frame to give (the equivalent of
  /// upstream `cimbare_render()` returning 0) — the caller should simply
  /// keep the current frame on screen, exactly like the official sender.
  ///
  /// [colorBalance] matches upstream `cimbare_next_frame(bool)`: official
  /// default is disabled.
  ///
  /// Frames that would fail the decoder's own anchor scan are dropped
  /// here, mirroring upstream `EncoderPlus::encode_fountain()`: at most 4
  /// consecutive unscannable frames are skipped, then frames are emitted
  /// anyway (forward progress beats a suspected bug).
  Future<CimbarFrame?> nextFrame({bool colorBalance = false});

  /// Release native resources.
  Future<void> dispose();
}
