import 'dart:async';
import 'dart:convert' show jsonDecode, utf8;
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:libcimbar/libcimbar.dart';
// ignore: implementation_imports
import 'package:libcimbar/src/native/wasm_diagnostics_stub.dart'
    if (dart.library.js_interop) 'package:libcimbar/src/web/libcimbar_js_interop.dart';
// ignore: implementation_imports
import 'native/web_file_download_stub.dart'
    if (dart.library.js_interop) 'web/web_file_download_web.dart';
import 'package:path_provider/path_provider.dart';

import 'dart:ui' as ui;

/// Decoder page — receive cimbar barcodes via camera and decode them.
///
/// Supported platforms:
/// - **Android**: Uses the device camera via camera plugin
/// - **Web (WASM)**: Uses getUserMedia for camera access
///
/// The decoder processes each camera frame, feeding it into the
/// fountain decoder until the complete file is recovered.
class DecoderPage extends StatefulWidget {
  const DecoderPage({super.key});

  @override
  State<DecoderPage> createState() => _DecoderPageState();
}

class _DecoderPageState extends State<DecoderPage> {
  // ─── State ────────────────────────────────────────────────────

  final CimbarPlatform _platform = CimbarPlatform.instance;

  ICimbarDecoder? _decoder;
  ICameraCapture? _camera;

  bool _isReady = false;
  bool _isDecoding = false;
  bool _isCameraActive = false;
  String _statusMessage = 'Initializing decoder...';
  double _progress = 0.0;

  CimbarConfig _config = const CimbarConfig(
    mode: CimbarMode.modeB,
    compressionLevel: 16,
  );

  // Decode result
  Uint8List? _recoveredData;
  String _recoveredFilename = '';

  // Frame counter
  int _framesProcessed = 0;

  // Capture frame rate (frames per second) for the web camera.
  int _captureFps = 5;

  // Last camera frame for screenshot
  CameraFrame? _lastFrame;

  // Last decode error (kept verbatim for the diagnostic report; contains the
  // native scan diagnostics: anchor counts, brightness, etc.).
  String _lastFrameError = '';

  // ─── Network debug link (encoder <-> decoder alignment) ─────
  // Talks to the encoder's DebugServer over LAN: pull the pristine frame it
  // is displaying (bypasses the camera entirely -> isolates whether the WASM
  // decode pipeline or the camera capture is at fault), and push our camera
  // view + report back for side-by-side comparison on the encoder machine.
  final TextEditingController _debugUrlCtrl =
      TextEditingController(text: 'http://100.65.70.35:8765');
  Timer? _remoteTimer;
  bool _remotePolling = false;
  bool _remoteBusy = false;
  int _remoteFrames = 0;

  // Encoder-side state fetched over the debug link (for reports/negotiation).
  Map<String, dynamic>? _lastEncoderStatus;
  String _lastSyncResult = '(not attempted)';

  // Negotiation light: null = not attempted, true = negotiated OK (green),
  // false = unreachable / unresolved mismatch (red).
  bool? _linkOk;

  // Outcome of the Pull+Decode ground-truth test (pristine frames over LAN,
  // no camera). Recorded separately from camera errors so the report can
  // state definitively whether the decode pipeline itself is healthy.
  String _lastRemoteResult = '(never run - click Pull+Decode)';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      debugPrint('[Decoder] Waiting for WASM module...');
      setState(() {
        _statusMessage = 'Waiting for WASM module to initialize...';
      });

      final wasmDiag = await waitForWasmReady(
        timeout: const Duration(seconds: 60),
        onStatusUpdate: (status) {
          debugPrint('[Decoder] $status');
          if (mounted) {
            setState(() => _statusMessage = status);
          }
        },
      );

      if (!wasmDiag.ready) {
        debugPrint('[Decoder] WASM not ready. Diagnostics:');
        debugPrint('[Decoder] ${wasmDiag.toReport()}');
        setState(() {
          _statusMessage =
              'WASM module failed to initialize.\n\n${wasmDiag.toReport()}';
        });
        return;
      }

      debugPrint(
          '[Decoder] WASM ready (${wasmDiag.waitDuration?.inMilliseconds}ms). Creating decoder...');
      _decoder = await _platform.createDecoder();
      await _decoder!.configure(_config);

      setState(() {
        _isReady = _decoder!.isReady;
        _statusMessage = _isReady
            ? 'Decoder ready. Start camera to begin scanning.'
            : 'Decoder created but not ready.\n\n${_getDiagnostics()}';
      });

      // Try to initialize camera
      try {
        _camera = await _platform.createCameraCapture();
      } catch (e) {
        debugPrint('Camera init failed: $e');
      }
    } catch (e) {
      debugPrint('[Decoder] Initialization error: $e');
      setState(() {
        _statusMessage = 'Initialization error: $e';
      });
    }
  }

  /// Get WASM diagnostic info.
  String _getDiagnostics() {
    try {
      return checkWasmDiagnostics().toReport();
    } catch (_) {
      return 'WASM module not available.';
    }
  }

  // ─── Camera flow ──────────────────────────────────────────────

  Future<void> _startCamera() async {
    if (_camera == null || !_isReady || _isDecoding) return;

    setState(() {
      _isCameraActive = true;
      _isDecoding = true;
      _statusMessage = 'Camera active. Point at a cimbar code...';
      _framesProcessed = 0;
    });

    // Best-effort negotiation: align decode mode with the encoder before
    // scanning (a silent mode mismatch fails every frame with -3).
    if (_debugBaseUrl.isNotEmpty) {
      await _syncWithEncoder();
    }

    await _camera!.start(
      preferredWidth: 1920,
      preferredHeight: 1080,
      frameIntervalMs: (1000 / _captureFps).round(),
    );

    _camera!.onFrame((frame) {
      _processCameraFrame(frame);
    });
  }

  Future<void> _stopCamera() async {
    await _camera?.stop();
    setState(() {
      _isCameraActive = false;
      _isDecoding = false;
      _statusMessage = 'Camera stopped.';
    });
  }

  int _debugFrameCount = 0;

  Future<void> _processCameraFrame(CameraFrame frame) async {
    if (!_isDecoding || _decoder == null) return;
    _lastFrame = frame;

    try {
      final imageFormat = switch (frame.format) {
        'rgba' => CimbarImageFormat.rgba,
        'nv12' => CimbarImageFormat.nv12,
        'yuv420' => CimbarImageFormat.yuv420,
        _ => CimbarImageFormat.rgb,
      };

      // Debug: log first 3 frames for troubleshooting
      _debugFrameCount++;
      if (_debugFrameCount <= 3) {
        debugPrint('[Frame #$_debugFrameCount] '
            '${frame.width}x${frame.height}, '
            'format=${frame.format}(code=${imageFormat.value}), '
            'data=${frame.data.length} bytes '
            '(expected=${frame.width * frame.height * (imageFormat.value > 4 ? 4 : 3)})');
      }

      final result = await _decoder!.decodeFrame(
        frame.data,
        width: frame.width,
        height: frame.height,
        format: imageFormat,
      );

      if (!mounted) return;

      _framesProcessed++;
      _progress = result.progress;

      if (result.isComplete) {
        _recoveredData = result.data;
        _recoveredFilename = result.filename;
        _statusMessage =
            'File recovered: "${result.filename}" (${result.data?.length ?? 0} bytes)';
        await _stopCamera();
        _saveFile();
      } else if (result.error != null) {
        _lastFrameError = result.error!;
        _statusMessage = 'Frame error: ${result.error}';
      } else {
        _statusMessage =
            'Decoding... ${(result.progress * 100).toStringAsFixed(1)}% '
            '($_framesProcessed frames)';
      }

      setState(() {});
    } catch (e, stack) {
      debugPrint('Frame decode error: $e');
      debugPrint('Frame decode stack:\n$stack');
      debugPrint('Frame info: ${frame.width}x${frame.height}, '
          'format=${frame.format}, data=${frame.data.length} bytes');
    }
  }

  // ─── Save recovered file ──────────────────────────────────────

  /// Encode the last camera frame to PNG bytes (shared by the local
  /// screenshot download and the network upload to the encoder).
  Future<Uint8List?> _lastFramePng() async {
    final frame = _lastFrame;
    if (frame == null) return null;
    // Convert RGB to RGBA
    final pixelCount = frame.width * frame.height;
    final rgba = Uint8List(pixelCount * 4);
    final isRgba = frame.format == 'rgba';
    for (int i = 0; i < pixelCount; i++) {
      if (isRgba) {
        rgba[i * 4] = frame.data[i * 4];
        rgba[i * 4 + 1] = frame.data[i * 4 + 1];
        rgba[i * 4 + 2] = frame.data[i * 4 + 2];
        rgba[i * 4 + 3] = frame.data[i * 4 + 3];
      } else {
        rgba[i * 4] = frame.data[i * 3];
        rgba[i * 4 + 1] = frame.data[i * 3 + 1];
        rgba[i * 4 + 2] = frame.data[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
      }
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (img) => completer.complete(img),
    );
    final image = await completer.future;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData?.buffer.asUint8List();
  }

  /// Save camera frame as PNG for debugging
  Future<void> _screenshotFrame() async {
    final frame = _lastFrame;
    if (frame == null) {
      _statusMessage = 'No frame captured yet.';
      setState(() {});
      return;
    }
    try {
      final pngBytes = await _lastFramePng();
      if (pngBytes == null) return;

      if (kIsWeb) {
        // On web, trigger download via JS
        _downloadBytesWeb(pngBytes,
            '${_timestampPrefix()}_cimbar_frame_${frame.width}x${frame.height}.png');
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final path =
            '${dir.path}/${_timestampPrefix()}_cimbar_frame_${frame.width}x${frame.height}.png';
        await File(path).writeAsBytes(pngBytes);
        _statusMessage = 'Frame saved: $path';
      }
      setState(() {});
    } catch (e) {
      _statusMessage = 'Screenshot error: $e';
      setState(() {});
    }
  }

  /// Web implementation: trigger a real browser download via the
  /// [downloadBytesWeb] helper (defined in conditional import).
  void _downloadBytesWeb(Uint8List bytes, String filename) {
    try {
      downloadBytesWeb(bytes, filename);
      _statusMessage = 'Frame captured: ${bytes.length} bytes. '
          'Check browser downloads for "$filename".';
    } catch (e) {
      _statusMessage = 'Web download error: $e';
    }
    setState(() {});
  }

  // ─── Network debug link ─────────────────────────────────────

  String get _debugBaseUrl {
    var s = _debugUrlCtrl.text.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Fetch the encoder's /status JSON (mode, fps, frames, native size).
  Future<Map<String, dynamic>?> _fetchEncoderStatus(
      {Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (_debugBaseUrl.isEmpty) return null;
    try {
      final r =
          await http.get(Uri.parse('$_debugBaseUrl/status')).timeout(timeout);
      if (r.statusCode == 200) {
        final m = jsonDecode(r.body);
        if (m is Map<String, dynamic>) {
          _lastEncoderStatus = m;
          return m;
        }
      }
    } catch (e) {
      debugPrint('[Decoder] encoder /status fetch failed: $e');
    }
    return null;
  }

  /// Negotiate settings with the encoder: pull its /status and align the
  /// decoder's mode with the encoder's. A silent mode mismatch makes every
  /// frame fail with -3 regardless of capture quality, so rule it out first.
  Future<String> _syncWithEncoder() async {
    final st = await _fetchEncoderStatus();
    if (st == null) {
      _lastSyncResult = 'encoder unreachable at '
          '${_debugBaseUrl.isEmpty ? '(URL not set)' : _debugBaseUrl}';
      _linkOk = false;
      if (mounted) setState(() {}); // refresh the negotiation light
      return _lastSyncResult;
    }
    final encMode = st['mode']?.toString() ?? '';
    if (encMode.isEmpty) {
      _lastSyncResult = 'encoder reachable, but mode unknown';
      _linkOk = false;
    } else if (encMode == _config.mode.name) {
      _lastSyncResult = 'mode match ($encMode)';
      _linkOk = true;
    } else {
      final target = CimbarMode.values.where((m) => m.name == encMode).toList();
      if (target.isEmpty) {
        _lastSyncResult =
            'MISMATCH: encoder mode "$encMode" unknown to decoder '
            '(decoder stays ${_config.mode.name})';
        _linkOk = false;
      } else {
        final old = _config.mode.name;
        _config = _config.copyWith(mode: target.first);
        await _decoder?.configure(_config);
        _lastSyncResult =
            'MISMATCH fixed: decoder mode $old -> $encMode (reconfigured)';
        _linkOk = true;
      }
    }
    debugPrint('[Decoder] negotiation: $_lastSyncResult');
    if (mounted) setState(() {}); // refresh the negotiation light
    return _lastSyncResult;
  }

  /// Toggle pulling pristine frames straight from the encoder's debug server
  /// and feeding them into the decoder — a camera-free ground-truth test.
  /// If this completes but camera decode never does, the decode pipeline is
  /// healthy and ONLY the camera capture needs fixing (and vice versa).
  Future<void> _toggleRemoteDecode() async {
    if (_remotePolling) {
      _remoteTimer?.cancel();
      _remoteTimer = null;
      setState(() {
        _remotePolling = false;
        _statusMessage = 'Remote decode stopped ($_remoteFrames frames).';
      });
      return;
    }
    if (_debugBaseUrl.isEmpty || _decoder == null) {
      setState(() => _statusMessage = 'Enter the encoder debug server URL '
          '(shown in the encoder status line, e.g. http://192.168.1.5:8765)');
      return;
    }
    _remoteFrames = 0;
    _remotePolling = true;
    // Negotiate first: align decoder mode with the encoder before decoding.
    final sync = await _syncWithEncoder();
    _statusMessage =
        'Remote decode [$sync]: pulling frames from $_debugBaseUrl ...';
    _remoteTimer = Timer.periodic(
        const Duration(milliseconds: 200), (_) => _pollRemoteFrame());
    setState(() {});
  }

  Future<void> _pollRemoteFrame() async {
    if (_remoteBusy || _decoder == null) return;
    _remoteBusy = true;
    try {
      final resp = await http
          .get(Uri.parse('$_debugBaseUrl/frame.png'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) {
        _statusMessage = 'Remote frame: HTTP ${resp.statusCode} — is the '
            'encoder in "Encode & Display" mode?';
        if (mounted) setState(() {});
        return;
      }

      // PNG -> raw RGBA for the decoder.
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(resp.bodyBytes, (img) => completer.complete(img));
      final image = await completer.future;
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = image.width, h = image.height;
      image.dispose();
      if (byteData == null) return;

      final result = await _decoder!.decodeFrame(
        byteData.buffer.asUint8List(),
        width: w,
        height: h,
        format: CimbarImageFormat.rgba,
      );
      if (!mounted) return;

      _remoteFrames++;
      _framesProcessed++;
      _progress = result.progress;
      if (result.isComplete) {
        _recoveredData = result.data;
        _recoveredFilename = result.filename;
        _lastRemoteResult = 'COMPLETE: "${result.filename}" '
            '(${result.data?.length ?? 0} bytes, $_remoteFrames frames) '
            '-> WASM pipeline healthy';
        _statusMessage = 'REMOTE decode COMPLETE: "${result.filename}" '
            '(${result.data?.length ?? 0} bytes, $_remoteFrames frames). '
            'WASM pipeline is healthy — remaining problem is camera capture.';
        _toggleRemoteDecode(); // stop polling
        _saveFile();
      } else if (result.error != null) {
        _lastFrameError = result.error!;
        _lastRemoteResult = 'frame #$_remoteFrames FAILED: ${result.error}';
        _statusMessage = 'REMOTE frame #$_remoteFrames: ${result.error}';
      } else {
        _lastRemoteResult = 'in progress '
            '${(result.progress * 100).toStringAsFixed(1)}% '
            '($_remoteFrames frames)';
        _statusMessage = 'REMOTE decoding... '
            '${(result.progress * 100).toStringAsFixed(1)}% '
            '($_remoteFrames frames)';
      }
      setState(() {});
    } catch (e) {
      _statusMessage = 'Remote poll failed: $e';
      if (mounted) setState(() {});
    } finally {
      _remoteBusy = false;
    }
  }

  /// Push our camera view (PNG) + diagnostic report to the encoder machine,
  /// where they are saved date-prefixed for side-by-side comparison.
  Future<void> _uploadToEncoder() async {
    if (_debugBaseUrl.isEmpty) {
      setState(() => _statusMessage = 'Enter the encoder debug server URL.');
      return;
    }
    try {
      var uploaded = 0;
      // Refresh encoder status so the uploaded report covers both ends.
      await _syncWithEncoder();
      final png = await _lastFramePng();
      if (png != null) {
        final r = await http
            .post(Uri.parse('$_debugBaseUrl/captured'),
                headers: {'Content-Type': 'application/octet-stream'},
                body: png)
            .timeout(const Duration(seconds: 5));
        if (r.statusCode == 200) uploaded++;
      }
      final r2 = await http
          .post(Uri.parse('$_debugBaseUrl/report'),
              headers: {'Content-Type': 'text/plain; charset=utf-8'},
              body: utf8.encode(_buildDiagnosticReport()))
          .timeout(const Duration(seconds: 5));
      if (r2.statusCode == 200) uploaded++;
      _statusMessage = 'Uploaded $uploaded item(s) to encoder '
          '(camera frame + report, saved in libcimbar_screenshots).';
    } catch (e) {
      _statusMessage = 'Upload failed: $e';
    }
    setState(() {});
  }

  // ─── Diagnostic report ────────────────────────────────────────

  /// Date-first timestamp for report file names, e.g. `20260727_090805`.
  String _timestampPrefix() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_'
        '${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  /// Read a camera property via dynamic access. Only [WebCameraCapture]
  /// exposes the diagnostic getters; other implementations yield null.
  T? _cameraProp<T>(T? Function(dynamic cam) getter) {
    final cam = _camera;
    if (cam == null) return null;
    try {
      return getter(cam as dynamic);
    } catch (_) {
      return null;
    }
  }

  /// Build a plain-text diagnostic report of the whole decode pipeline —
  /// camera resolution included — for troubleshooting "cannot decode" cases.
  String _buildDiagnosticReport() {
    final vw = _cameraProp<int>((c) => c.videoWidth as int?);
    final vh = _cameraProp<int>((c) => c.videoHeight as int?);
    final input = _cameraProp<int>((c) => c.decoderInputSize as int?);
    final capMode = _cameraProp<String>(
        // Enum .name is an extension getter and cannot be invoked on a
        // dynamic receiver -> use toString() and strip the type prefix.
        (c) => c.captureMode?.toString().split('.').last);
    final frame = _lastFrame;

    final b = StringBuffer()
      ..writeln('libcimbar decoder - diagnostic report')
      ..writeln('Generated  : ${DateTime.now().toIso8601String()}')
      ..writeln('Platform   : ${kIsWeb ? 'Web (WASM)' : 'native'}')
      ..writeln()
      ..writeln('[Config]')
      ..writeln('  Mode             : ${_config.mode.name} '
          '(value ${_config.modeValue})')
      ..writeln('  Capture FPS      : $_captureFps /s')
      ..writeln()
      ..writeln('[Encoder] (debug link: '
          '${_debugBaseUrl.isEmpty ? 'not set' : _debugBaseUrl})');
    final enc = _lastEncoderStatus;
    if (enc == null) {
      b.writeln('  (unreachable — decoder-side data only)');
    } else {
      b
        ..writeln('  Ready            : ${enc['ready']}')
        ..writeln('  Mode             : ${enc['mode']}')
        ..writeln('  Display FPS      : ${enc['displayFps']}')
        ..writeln('  Frames           : ${enc['frames']} '
            '(currently showing #${enc['currentFrame']})')
        ..writeln('  Native barcode   : ${enc['nativeWidth']} x '
            '${enc['nativeHeight']} px');
    }
    b
      ..writeln()
      ..writeln('[Negotiation]')
      ..writeln('  Mode sync        : $_lastSyncResult');
    if (enc != null && input != null) {
      final nw = (enc['nativeWidth'] as num?)?.toInt() ?? 0;
      b.writeln('  Size check       : native barcode $nw px vs decoder '
          'input $input px -> '
          '${nw > 0 && input >= nw ? 'OK (input can hold the barcode 1:1)' : 'input SMALLER than native barcode (must not happen)'}');
    }
    b
      ..writeln()
      ..writeln('[Ground truth (Pull+Decode, camera-free)]')
      ..writeln('  $_lastRemoteResult')
      ..writeln()
      ..writeln('[Camera]')
      ..writeln('  Video resolution : ${vw ?? '?'} x ${vh ?? '?'} '
          '(actual from getUserMedia)')
      ..writeln('  Capture mode     : ${capMode ?? '?'}')
      ..writeln('  Decoder input    : ${input ?? '?'} x ${input ?? '?'} px')
      ..writeln('  Camera active    : $_isCameraActive')
      ..writeln()
      ..writeln('[Decode session]')
      ..writeln('  Frames processed : $_framesProcessed')
      ..writeln('  Progress         : ${(_progress * 100).toStringAsFixed(1)}%')
      ..writeln(
          '  Recovered file   : ${_recoveredFilename.isEmpty ? '(none)' : '$_recoveredFilename (${_recoveredData?.length ?? 0} bytes)'}')
      ..writeln()
      ..writeln('[Last camera frame]')
      ..writeln(frame == null
          ? '  (none captured yet)'
          : '  ${frame.width} x ${frame.height}, format=${frame.format}, '
              '${frame.data.length} bytes')
      ..writeln()
      ..writeln('[Last decode error]')
      ..writeln(_lastFrameError.isEmpty ? '  (none)' : '  $_lastFrameError')
      ..writeln()
      ..writeln('[Status]')
      ..writeln('  $_statusMessage')
      ..writeln()
      ..writeln('[Hints]')
      ..writeln('  found 0 anchors   -> barcode too small/blurry in view: '
          'move closer, fill the frame, check focus/glare')
      ..writeln('  found 1-3 anchors -> barcode partially cropped or '
          'off-center: center it, keep all 4 corners in view');
    return b.toString();
  }

  /// Save the diagnostic report with a date-first filename.
  /// Web: triggers a browser download; native: writes to Documents.
  Future<void> _saveDiagnosticReport() async {
    // Refresh encoder status + mode negotiation so the report covers BOTH
    // ends (best-effort; report degrades to decoder-only when unreachable).
    await _syncWithEncoder();
    final content = _buildDiagnosticReport();
    final filename = '${_timestampPrefix()}_decode_report.txt';
    try {
      if (kIsWeb) {
        downloadBytesWeb(Uint8List.fromList(utf8.encode(content)), filename);
        _statusMessage = 'Report downloaded: $filename';
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final path = '${dir.path}/$filename';
        await File(path).writeAsString(content);
        _statusMessage = 'Report saved: $path';
      }
    } catch (e) {
      _statusMessage = 'Report error: $e';
    }
    setState(() {});
  }

  Future<void> _saveFile() async {
    if (_recoveredData == null) return;

    try {
      String savePath;
      if (kIsWeb) {
        // On web, trigger a download
        // In production, use dart:js_interop to create a Blob and download link
        _statusMessage = 'File decoded! In production, a download will start.';
        return;
      }

      final dir = await getApplicationDocumentsDirectory();
      final filename =
          _recoveredFilename.isNotEmpty ? _recoveredFilename : 'decoded.bin';
      savePath = '${dir.path}/$filename';

      final file = File(savePath);
      await file.writeAsBytes(_recoveredData!);

      setState(() {
        _statusMessage = 'File saved to: $savePath';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Save error: $e';
      });
    }
  }

  // ─── UI ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('libcimbar Decoder'),
        actions: [
          // Mode selector
          PopupMenuButton<CimbarMode>(
            icon: const Icon(Icons.settings),
            tooltip: 'Encoding mode',
            onSelected: (mode) async {
              _config = _config.copyWith(mode: mode);
              await _decoder?.configure(_config);
            },
            itemBuilder: (_) => CimbarMode.values
                .map((m) => PopupMenuItem(
                      value: m,
                      child: Text(m.name),
                    ))
                .toList(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _isReady ? Icons.check_circle : Icons.error,
                          color: _isReady ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 12),
                        // Fixed-height, scrollable status text. Messages flip
                        // between short progress lines and long scan
                        // diagnostics every frame; a variable-height text box
                        // would make the whole layout (and the camera
                        // viewfinder below) jump around while decoding.
                        Expanded(
                          child: SizedBox(
                            height: 72,
                            child: SingleChildScrollView(
                              child: SelectableText(_statusMessage),
                            ),
                          ),
                        ),
                        if (!_isReady ||
                            _statusMessage.contains('error') ||
                            _statusMessage.contains('Error'))
                          IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            tooltip: 'Copy error message',
                            onPressed: () {
                              Clipboard.setData(
                                  ClipboardData(text: _statusMessage));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content:
                                      Text('Error message copied to clipboard'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Chip(
                          avatar: const Icon(
                            Icons.settings_input_antenna,
                            size: 16,
                          ),
                          label: Text('Mode: ${_config.mode.name}'),
                        ),
                        if (_framesProcessed > 0)
                          Chip(
                            avatar: const Icon(Icons.photo_camera, size: 16),
                            label: Text('$_framesProcessed frames'),
                          ),
                        if (_recoveredData != null)
                          Chip(
                            avatar: const Icon(Icons.check_circle, size: 16),
                            label: Text(
                              _recoveredFilename.isNotEmpty
                                  ? _recoveredFilename
                                  : 'recovered',
                            ),
                          ),
                      ],
                    ),
                    if (_progress > 0 && _progress < 1.0) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _progress,
                          minHeight: 8,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${(_progress * 100).toStringAsFixed(1)}% — '
                        '$_framesProcessed frames processed',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Capture FPS control, single compact row so the camera preview
            // below gets as much height as possible.
            Row(
              children: [
                Text('Capture FPS',
                    style: Theme.of(context).textTheme.labelSmall),
                Expanded(
                  child: Slider(
                    value: _captureFps.toDouble(),
                    min: 1,
                    max: 30,
                    divisions: 29,
                    label: '$_captureFps fps',
                    onChanged: (v) => setState(() => _captureFps = v.round()),
                  ),
                ),
                Text(
                  '$_captureFps /s',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Camera controls
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        _isReady && !_isCameraActive ? _startCamera : null,
                    icon: const Icon(Icons.videocam),
                    label: const Text('Start Camera'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isCameraActive ? _stopCamera : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop Camera'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _lastFrame != null ? _screenshotFrame : null,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Screenshot'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saveDiagnosticReport,
                    icon: const Icon(Icons.description),
                    label: const Text('Report'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Network debug link: pull pristine frames from the encoder's
            // debug server / push our camera view back to it.
            Row(
              children: [
                // Negotiation light: green = link up & modes aligned.
                Tooltip(
                  message: 'Negotiation: $_lastSyncResult',
                  child: Icon(
                    Icons.circle,
                    size: 14,
                    color: _linkOk == null
                        ? Colors.grey
                        : (_linkOk! ? Colors.greenAccent : Colors.redAccent),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _debugUrlCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: 'Encoder debug server',
                      hintText: 'http://<encoder-ip>:8765',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _toggleRemoteDecode,
                  icon:
                      Icon(_remotePolling ? Icons.stop : Icons.cloud_download),
                  label: Text(_remotePolling ? 'Stop' : 'Pull+Decode'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _lastFrame != null ? _uploadToEncoder : null,
                  icon: const Icon(Icons.cloud_upload),
                  label: const Text('Upload view'),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Camera preview / placeholder
            Expanded(
              child: _buildCameraPreview(),
            ),

            // Recovered file info
            if (_recoveredData != null) ...[
              const SizedBox(height: 12),
              _buildResultPanel(),
            ],
          ],
        ),
      ),
    );
  }

  /// Get the camera view type for HtmlElementView (web only).
  String? get _cameraViewType {
    try {
      // WebCameraCapture has a viewType getter
      final cam = _camera;
      if (cam != null) {
        return (cam as dynamic).viewType as String?;
      }
    } catch (_) {}
    return null;
  }

  Widget _buildCameraPreview() {
    final vType = _cameraViewType;
    if (_isCameraActive && vType != null) {
      // Show camera preview with scanning frame overlay
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Camera video stream
            HtmlElementView(viewType: vType),
            // Scanning frame overlay
            _buildScanningOverlay(),
          ],
        ),
      );
    }

    if (_isCameraActive) {
      // Camera active but no preview available
      return Card(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.videocam,
                size: 64,
                color: Colors.green.withValues(alpha: 0.7),
              ),
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Scanning for cimbar codes...\n'
                'Keep the entire barcode (all four corners) in view',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.qr_code_scanner,
              size: 80,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'Start the camera to scan cimbar codes',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  /// Scanning frame overlay: dark surroundings with a clear center frame
  /// and animated corner brackets.
  Widget _buildScanningOverlay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // Square guide frame: 92% of the shorter dimension, no hard cap.
        // This mirrors the centered square the decoder actually captures
        // (centerCrop) — the old 500px cap made users hold the barcode far
        // too small in the camera view to ever resolve the 4 anchors.
        final frameSize = (size.shortestSide * 0.92).clamp(150.0, 4096.0);
        final frameLeft = (size.width - frameSize) / 2;
        final frameTop = (size.height - frameSize) / 2;
        final frameRect =
            Rect.fromLTWH(frameLeft, frameTop, frameSize, frameSize);

        return Stack(
          children: [
            // Dark overlay with a hole cut out for the frame
            CustomPaint(
              size: size,
              painter: _DarkOverlayPainter(
                frameRect: frameRect,
                color: Colors.black.withValues(alpha: 0.6),
              ),
            ),
            // Corner brackets
            CustomPaint(
              size: size,
              painter: _CornerBracketsPainter(
                frameRect: frameRect,
                color: Colors.white,
                bracketLength: frameSize * 0.15,
                strokeWidth: 3.0,
              ),
            ),
            // Scanning hint text pinned to the bottom of the preview (the
            // enlarged frame leaves no room below it).
            Positioned(
              left: 0,
              right: 0,
              bottom: 10,
              child: Text(
                'Fit the whole barcode inside the frame '
                '(all four corners visible)',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildResultPanel() {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 8),
                Text(
                  'File Recovered',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Filename: $_recoveredFilename'),
            Text('Size: ${_recoveredData!.length} bytes'),
            Text('Frames: $_framesProcessed'),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _saveFile,
              icon: const Icon(Icons.save),
              label: const Text('Save File'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _remoteTimer?.cancel();
    _debugUrlCtrl.dispose();
    _camera?.dispose();
    _decoder?.dispose();
    super.dispose();
  }
}

// ─── Scanning frame painters ────────────────────────────────────

/// Draws a dark overlay with a rectangular hole for the scanning frame.
class _DarkOverlayPainter extends CustomPainter {
  final Rect frameRect;
  final Color color;

  _DarkOverlayPainter({required this.frameRect, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final fullRect = Rect.fromLTWH(0, 0, size.width, size.height);

    // Draw the dark overlay
    final path = Path()
      ..addRect(fullRect)
      ..addRRect(RRect.fromRectAndRadius(frameRect, const Radius.circular(8)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_DarkOverlayPainter old) =>
      old.frameRect != frameRect || old.color != color;
}

/// Draws corner brackets at the four corners of the scanning frame.
class _CornerBracketsPainter extends CustomPainter {
  final Rect frameRect;
  final Color color;
  final double bracketLength;
  final double strokeWidth;

  _CornerBracketsPainter({
    required this.frameRect,
    required this.color,
    required this.bracketLength,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final l = bracketLength;
    const r = 8.0; // corner radius offset

    // Top-left
    canvas.drawLine(
      Offset(frameRect.left - r, frameRect.top + l),
      Offset(frameRect.left - r, frameRect.top - r),
      paint,
    );
    canvas.drawLine(
      Offset(frameRect.left - r, frameRect.top - r),
      Offset(frameRect.left + l, frameRect.top - r),
      paint,
    );

    // Top-right
    canvas.drawLine(
      Offset(frameRect.right + r, frameRect.top + l),
      Offset(frameRect.right + r, frameRect.top - r),
      paint,
    );
    canvas.drawLine(
      Offset(frameRect.right + r, frameRect.top - r),
      Offset(frameRect.right - l, frameRect.top - r),
      paint,
    );

    // Bottom-left
    canvas.drawLine(
      Offset(frameRect.left - r, frameRect.bottom - l),
      Offset(frameRect.left - r, frameRect.bottom + r),
      paint,
    );
    canvas.drawLine(
      Offset(frameRect.left - r, frameRect.bottom + r),
      Offset(frameRect.left + l, frameRect.bottom + r),
      paint,
    );

    // Bottom-right
    canvas.drawLine(
      Offset(frameRect.right + r, frameRect.bottom - l),
      Offset(frameRect.right + r, frameRect.bottom + r),
      paint,
    );
    canvas.drawLine(
      Offset(frameRect.right + r, frameRect.bottom + r),
      Offset(frameRect.right - l, frameRect.bottom + r),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CornerBracketsPainter old) => old.frameRect != frameRect;
}
