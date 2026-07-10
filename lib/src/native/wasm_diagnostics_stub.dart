// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Native stub for WASM diagnostics — not applicable on native platforms.
class WasmDiagnostics {
  final bool moduleDefined = false;
  final bool calledRun = false;
  final bool wasmFileMissing = false;
  final bool ready = false;
  final Duration? waitDuration;

  const WasmDiagnostics({this.waitDuration});

  String toReport() => 'WASM diagnostics not available on native platforms.';

  @override
  String toString() => toReport();
}

/// Stub: always returns not-available on native.
WasmDiagnostics checkWasmDiagnostics() => const WasmDiagnostics();

/// Stub: immediately returns not-ready on native (no WASM to wait for).
Future<WasmDiagnostics> waitForWasmReady({
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 200),
  void Function(String status)? onStatusUpdate,
}) async =>
    const WasmDiagnostics();
