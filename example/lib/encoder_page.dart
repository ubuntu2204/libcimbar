import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:libcimbar/libcimbar.dart';

import 'core/screenshot_capture.dart';

/// Encoder page -- Windows screen capture -> AVIF compression -> cimbar encoding.
class EncoderPage extends StatefulWidget {
  const EncoderPage({super.key});

  @override
  State<EncoderPage> createState() => _EncoderPageState();
}

class _EncoderPageState extends State<EncoderPage>
    with TickerProviderStateMixin {
  final CimbarPlatform _platform = CimbarPlatform.instance;

  ICimbarEncoder? _encoder;
  IImageCompressor? _compressor;

  bool _isReady = false;
  bool _isEncoding = false;
  bool _isCapturing = false;
  String _statusMessage = 'Initializing...';

  CimbarConfig _config = const CimbarConfig(
    mode: CimbarMode.modeB,
    compressionLevel: 16,
    fps: 15,
  );

  // Frame animation
  List<CimbarFrame> _frames = [];
  int _currentFrameIndex = 0;
  AnimationController? _frameAnimationController;

  // Capture result
  Uint8List? _capturedPixels;
  int _capturedWidth = 0;
  int _capturedHeight = 0;

  // Compressed data
  Uint8List? _compressedData;

  // Pre-decoded frame images for display
  List<ui.Image> _decodedFrames = [];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _encoder = await _platform.createEncoder();
      _compressor = await _platform.createImageCompressor();
      await _encoder!.configure(_config);
      await ScreenshotCapture.instance.ensureNativeToolReady();

      // Register Alt+A hotkey
      await hotKeyManager.register(
        HotKey(
          key: LogicalKeyboardKey.keyA,
          modifiers: [HotKeyModifier.alt],
        ),
        keyDownHandler: (_) => _startScreenCapture(),
      );

      setState(() {
        _isReady = _encoder!.isReady;
        _statusMessage = _isReady
            ? 'Ready. Press Alt+A to capture screen.'
            : 'Native library not loaded. Build libcimbar.dll first.';
      });
    } catch (e) {
      setState(() => _statusMessage = 'Initialization error: $e');
    }
  }

  // --- Screen capture flow ---

  Future<void> _startScreenCapture() async {
    if (_isCapturing || !_isReady || !mounted) return;
    setState(() => _isCapturing = true);

    try {
      final result = await ScreenshotCapture.instance.takeScreenshot();

      if (!result.isSuccess || result.pixels == null) {
        setState(() {
          _statusMessage = result.error ?? 'Capture cancelled';
          _isCapturing = false;
        });
        return;
      }

      _capturedPixels = result.pixels;
      _capturedWidth = result.width;
      _capturedHeight = result.height;

      // Compress to AVIF (or PNG fallback)
      _statusMessage = 'Compressing to AVIF...';
      if (mounted) setState(() {});

      _compressedData = await _compressor!.compressRgba(
        result.pixels!,
        width: result.width,
        height: result.height,
        quality: CompressionQuality.balanced,
      );

      _statusMessage =
          'Captured ${result.width}x${result.height}, '
          'compressed: ${_compressedData!.length} bytes. Ready to encode.';
    } catch (e) {
      _statusMessage = 'Capture error: $e';
    }

    if (mounted) setState(() => _isCapturing = false);
  }

  // --- Encoding flow ---

  Future<void> _startEncoding() async {
    if (_compressedData == null || _encoder == null || _isEncoding) return;
    _isEncoding = true; // synchronous guard against double-click

    setState(() {
      _statusMessage = 'Encoding data into cimbar frames...';
    });

    try {
      _frames = await _encoder!.encodeData(
        _compressedData!,
        filename: 'screenshot.avif',
      );

      if (_frames.isEmpty) {
        _statusMessage = 'Encoding produced no frames.';
        setState(() => _isEncoding = false);
        return;
      }

      // Decode RGB frames to ui.Image for display
      _statusMessage = 'Decoding ${_frames.length} frames...';
      setState(() {});
      _decodedFrames = [];
      for (final frame in _frames) {
        final pixelCount = frame.width * frame.height;
        final rgba = Uint8List(pixelCount * 4);
        for (int i = 0; i < pixelCount; i++) {
          rgba[i * 4] = frame.pixels[i * 3];
          rgba[i * 4 + 1] = frame.pixels[i * 3 + 1];
          rgba[i * 4 + 2] = frame.pixels[i * 3 + 2];
          rgba[i * 4 + 3] = 255;
        }
        final completer = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          rgba, frame.width, frame.height, ui.PixelFormat.rgba8888,
          (image) => completer.complete(image),
        );
        _decodedFrames.add(await completer.future);
      }

      _statusMessage =
          'Generated ${_frames.length} cimbar frames. Displaying animation...';

      _currentFrameIndex = 0;
      _frameAnimationController?.dispose();
      _frameAnimationController = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 1000 ~/ _config.fps),
      )..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            _frameAnimationController?.repeat();
          }
        });

      _frameAnimationController!.addListener(() {
        if (mounted && _frames.isNotEmpty) {
          setState(() {
            _currentFrameIndex = (_currentFrameIndex + 1) % _frames.length;
          });
        }
      });

      _frameAnimationController!.forward();
    } catch (e) {
      _statusMessage = 'Encoding error: $e';
    }

    if (mounted) setState(() => _isEncoding = false);
  }

  void _stopEncoding() {
    _frameAnimationController?.stop();
    _frameAnimationController?.dispose();
    _frameAnimationController = null;
    for (final img in _decodedFrames) {
      img.dispose();
    }
    setState(() {
      _frames = [];
      _decodedFrames = [];
      _statusMessage = 'Encoding stopped.';
    });
  }

  // --- UI ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('libcimbar Encoder'),
        actions: [
          PopupMenuButton<CimbarMode>(
            icon: const Icon(Icons.settings),
            onSelected: (mode) async {
              _config = _config.copyWith(mode: mode);
              await _encoder?.configure(_config);
            },
            itemBuilder: (_) => CimbarMode.values
                .map((m) => PopupMenuItem(value: m, child: Text(m.name)))
                .toList(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status bar
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      _isReady ? Icons.check_circle : Icons.error,
                      color: _isReady ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: SelectableText(_statusMessage)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isReady && !_isCapturing
                        ? _startScreenCapture
                        : null,
                    icon: const Icon(Icons.screenshot),
                    label: Text(_isCapturing ? 'Capturing...' : 'Capture (Alt+A)'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _compressedData != null && !_isEncoding
                        ? _startEncoding
                        : null,
                    icon: const Icon(Icons.qr_code),
                    label: const Text('Encode & Display'),
                  ),
                ),
                if (_frames.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _stopEncoding,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 24),

            // Frame display
            Expanded(
              child: _frames.isNotEmpty
                  ? _buildFrameDisplay()
                  : _buildPlaceholder(),
            ),

            // Info panel
            if (_compressedData != null) ...[
              const SizedBox(height: 12),
              _buildInfoPanel(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFrameDisplay() {
    if (_decodedFrames.isEmpty || _currentFrameIndex >= _decodedFrames.length) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Frame ${_currentFrameIndex + 1} / ${_frames.length}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: Center(
              child: RawImage(
                image: _decodedFrames[_currentFrameIndex],
                width: 512,
                height: 512,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Card(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.screenshot_monitor_outlined, size: 80,
                color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'Press Alt+A or click "Capture"\nto select a screen region',
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

  Widget _buildInfoPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _infoChip('Capture', '${_capturedWidth}x$_capturedHeight'),
            _infoChip('Compressed',
                '${((_compressedData?.length ?? 0) / 1024).toStringAsFixed(1)} KB'),
            _infoChip('Mode', _config.mode.name),
            _infoChip('Frames', '${_frames.length}'),
          ],
        ),
      ),
    );
  }

  Widget _infoChip(String label, String value) {
    return Column(
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }

  @override
  void dispose() {
    _frameAnimationController?.dispose();
    for (final img in _decodedFrames) {
      img.dispose();
    }
    _encoder?.dispose();
    _compressor?.dispose();
    hotKeyManager.unregisterAll();
    super.dispose();
  }
}
