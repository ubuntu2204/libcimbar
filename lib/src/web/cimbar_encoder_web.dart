// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import '../interfaces/cimbar_encoder_interface.dart';
import '../models/cimbar_config.dart';
import '../models/cimbar_frame.dart';

/// Web stub for cimbar encoder — encoding is only supported on Windows.
///
/// This stub exists solely to satisfy the conditional import system
/// and avoid pulling `dart:ffi` into web builds.
/// [CimbarPlatform.createEncoder] throws [UnsupportedError] on web
/// before this class is ever instantiated.
class CimbarEncoderFfi implements ICimbarEncoder {
  @override
  bool get isReady => false;

  @override
  Future<void> configure(CimbarConfig config) async {
    throw UnsupportedError('Encoding is only supported on Windows.');
  }

  @override
  Future<List<CimbarFrame>> encodeData(
    Uint8List data, {
    String filename = 'data.bin',
  }) async {
    throw UnsupportedError('Encoding is only supported on Windows.');
  }

  @override
  Future<List<CimbarFrame>> encodeFile(String filePath) async {
    throw UnsupportedError('Encoding is only supported on Windows.');
  }

  @override
  Future<void> dispose() async {}
}
