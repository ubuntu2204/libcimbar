import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:libcimbar/libcimbar.dart';
import 'package:path_provider/path_provider.dart';

/// Decoder page — receive cimbar barcodes via camera and decode them.
///
/// Works on:
/// - **Android**: Uses the device camera via camera plugin
/// - **Web (WASM)**: Uses getUserMedia for camera access
/// - **Desktop**: Can also decode from image file upload
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

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _decoder = await _platform.createDecoder();
      await _decoder!.configure(_config);

      setState(() {
        _isReady = _decoder!.isReady;
        _statusMessage = _isReady
            ? 'Decoder ready. Start camera to begin scanning.'
            : 'Native library not loaded.';
      });

      // Try to initialize camera
      try {
        _camera = await _platform.createCameraCapture();
      } catch (e) {
        // Camera not available — user can still decode from files
        debugPrint('Camera init failed: $e');
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Initialization error: $e';
      });
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

    await _camera!.start(preferredWidth: 1920, preferredHeight: 1080);

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

  Future<void> _processCameraFrame(CameraFrame frame) async {
    if (!_isDecoding || _decoder == null) return;

    try {
      final imageFormat = switch (frame.format) {
        'rgba' => CimbarImageFormat.rgba,
        'nv12' => CimbarImageFormat.nv12,
        'yuv420' => CimbarImageFormat.yuv420,
        _ => CimbarImageFormat.rgb,
      };

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
    } catch (e) {
      debugPrint('Frame decode error: $e');
    }
  }

  // ─── File decode (desktop / web fallback) ─────────────────────

  Future<void> _decodeFromFile() async {
    if (!_isReady) return;

    // On desktop, open a file picker for a cimbar image
    // On web, use <input type="file">
    // For now, show a message
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'File-based decoding: select a cimbar barcode image.\n'
          'This feature requires a file picker integration.',
        ),
        duration: Duration(seconds: 3),
      ),
    );
  }

  // ─── Save recovered file ──────────────────────────────────────

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
                  child: OutlinedButton.icon(
                    onPressed: _isReady ? _decodeFromFile : null,
                    icon: const Icon(Icons.image),
                    label: const Text('From Image'),
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

  Widget _buildCameraPreview() {
    if (_isCameraActive) {
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
              'Start the camera to scan cimbar codes\n'
              'or decode from an image file',
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
