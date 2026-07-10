// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// # libcimbar
///
/// A Flutter plugin wrapping [libcimbar](https://github.com/sz3/libcimbar) —
/// Color Icon Matrix Barcodes for air-gapped data transfer.
///
/// ## Features
///
/// - **Encode**: Convert binary data into cimbar barcode frame images
/// - **Decode**: Decode cimbar barcode images back into binary data
/// - **Screen Capture** (Windows): Hotkey-triggered region capture
/// - **Camera Capture** (Android / Web): Real-time camera barcode scanning
/// - **AVIF Compression**: Compress screenshots to AVIF before encoding
///
/// ## Architecture
///
/// All functionality is exposed through abstract interfaces in
/// `lib/src/interfaces/`. Platform-specific implementations are selected
/// automatically at runtime:
///
/// | Platform | Encoder (FFI/Native) | Decoder (FFI/Native) |
/// |----------|---------------------|---------------------|
/// | Windows  | dart:ffi → libcimbar.dll | dart:ffi → libcimbar.dll |
/// | Android  | MethodChannel → JNI | MethodChannel → JNI + Camera |
/// | Web      | JS interop → WASM | JS interop → WASM + Camera |
///
/// ## Quick Start
///
/// ```dart
/// import 'package:libcimbar/libcimbar.dart';
///
/// // Encode data into cimbar frames
/// final encoder = await CimbarPlatform.instance.createEncoder();
/// await encoder.configure(CimbarConfig(mode: CimbarMode.modeB));
/// final frames = await encoder.encodeData(avifBytes, filename: 'screen.avif');
///
/// // Decode cimbar frames from camera
/// final decoder = await CimbarPlatform.instance.createDecoder();
/// await decoder.configure(CimbarConfig(mode: CimbarMode.modeB));
/// final result = await decoder.decodeFrame(imageBytes, width: 1024, height: 1024);
/// if (result.isComplete) {
///   final data = await decoder.recoverFile(result.fileId!);
/// }
/// ```
library libcimbar;

// Models
export 'src/models/cimbar_config.dart';
export 'src/models/cimbar_frame.dart';
export 'src/models/decode_result.dart';

// Interfaces
export 'src/interfaces/cimbar_encoder_interface.dart';
export 'src/interfaces/cimbar_decoder_interface.dart';
export 'src/interfaces/screen_capture_interface.dart';
export 'src/interfaces/camera_capture_interface.dart';
export 'src/interfaces/image_compressor_interface.dart';

// Platform interface (auto-selects implementation)
export 'src/cimbar_platform.dart';

// Implementations (for direct use or testing)
export 'src/impl/avif_compressor.dart';
