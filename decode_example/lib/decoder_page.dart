import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
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

  /// Save camera frame as PNG for debugging
  Future<void> _screenshotFrame() async {
    final frame = _lastFrame;
    if (frame == null) {
      _statusMessage = 'No frame captured yet.';
      setState(() {});
      return;
    }
    try {
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
      if (byteData == null) return;
      final pngBytes = byteData.buffer.asUint8List();

      if (kIsWeb) {
        // On web, trigger download via JS
        _downloadBytesWeb(
            pngBytes, 'cimbar_frame_${frame.width}x${frame.height}.png');
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final path =
            '${dir.path}/cimbar_frame_${frame.width}x${frame.height}.png';
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
                      children: [
                        Icon(
                          _isReady ? Icons.check_circle : Icons.error,
                          color: _isReady ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: SelectableText(_statusMessage)),
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
            const SizedBox(height: 16),

            // Capture FPS control (affects how often frames are delivered
            // from the web camera; only used when starting the camera).
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Capture FPS',
                          style: Theme.of(context).textTheme.labelSmall),
                      Text(
                        '$_captureFps /s',
                        style:
                            Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                      ),
                    ],
                  ),
                  Slider(
                    value: _captureFps.toDouble(),
                    min: 1,
                    max: 30,
                    divisions: 29,
                    label: '$_captureFps fps',
                    onChanged: (v) => setState(() => _captureFps = v.round()),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

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
              ],
            ),
            const SizedBox(height: 24),

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
                'Scanning for cimbar codes...\nPoint camera at the displayed barcode',
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
        // Square frame size: 70% of the shorter dimension
        final frameSize = (size.shortestSide * 0.7).clamp(200.0, 500.0);
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
            // Scanning hint text below frame
            Positioned(
              left: 0,
              right: 0,
              top: frameRect.bottom + 16,
              child: Text(
                'Point camera at cimbar barcode',
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
