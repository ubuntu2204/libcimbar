// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import '../interfaces/cimbar_encoder_interface.dart';
import '../models/cimbar_config.dart';
import '../models/cimbar_frame.dart';

/// Web stub for cimbar encoder — encoding is only supported on desktop.
///
/// This stub exists solely to satisfy the conditional import system
/// and avoid pulling `dart:ffi` into web builds.
/// [CimbarPlatform.createEncoder] throws [UnsupportedError] on web
/// before this class is ever instantiated.
class CimbarEncoderFfi implements ICimbarEncoder {
  @override
  bool get isReady => false;

  UnsupportedError _unsupported() => UnsupportedError(
      'Encoding is only supported on desktop (Linux/Windows).');

  @override
  Future<void> configure(CimbarConfig config) async => throw _unsupported();

  @override
  Future<void> initEncodeSession(String filename, {int encodeId = -1}) async =>
      throw _unsupported();

  @override
  Future<int> encodeChunk(Uint8List chunk) async => throw _unsupported();

  @override
  Future<void> finishEncode() async => throw _unsupported();

  @override
  Future<CimbarFrame?> nextFrame({bool colorBalance = false}) async =>
      throw _unsupported();

  @override
  Future<void> dispose() async {}
}
