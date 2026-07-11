import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:libcimbar/libcimbar.dart';
import 'package:window_manager/window_manager.dart';

import 'core/screenshot_capture.dart';

/// Encoder page -- Windows only.
///
/// Screen capture -> AVIF compression -> cimbar encoding.
/// This page should only be accessible on Windows.
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
    // Guard: encoder is Windows-only
    if (kIsWeb || !Platform.isWindows) {
      setState(() {
        _statusMessage = 'Error: Encoding is only supported on Windows.';
      });
      return;
    }

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

      _statusMessage = 'Captured ${result.width}x${result.height}, '
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
          rgba,
          frame.width,
          frame.height,
          ui.PixelFormat.rgba8888,
          (image) => completer.complete(image),
        );
        _decodedFrames.add(await completer.future);
      }
      debugPrint('[Frames] ${_frames.length} frames, '
          'first: ${_frames[0].width}x${_frames[0].height}');
      debugPrint(
          '[UI Images] first: ${_decodedFrames[0].width}x${_decodedFrames[0].height}');

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
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          // Right side: cimbar panel centered in the right area (1024x1024, no stretch)
          Positioned(
            left: 200,
            top: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black,
              child: Center(
                child: SizedBox(
                  width: 1024,
                  height: 1024,
                  child: _frames.isNotEmpty
                      ? _buildFrameDisplay()
                      : _buildPlaceholder(),
                ),
              ),
            ),
          ),
          // Left panel: fixed 200px width
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 200,
            child: Container(
              color: Theme.of(context).colorScheme.surface,
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Window controls (minimize, close)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _WindowButton(
                        icon: Icons.remove,
                        tooltip: 'Minimize',
                        onPressed: () => windowManager.minimize(),
                      ),
                      _WindowButton(
                        icon: Icons.close,
                        tooltip: 'Close',
                        onPressed: () => windowManager.close(),
                        isClose: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  PopupMenuButton<CimbarMode>(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.settings, size: 18),
                        const SizedBox(width: 6),
                        Text(_config.mode.name),
                      ],
                    ),
                    onSelected: (mode) async {
                      _config = _config.copyWith(mode: mode);
                      await _encoder?.configure(_config);
                    },
                    itemBuilder: (_) => CimbarMode.values
                        .map(
                            (m) => PopupMenuItem(value: m, child: Text(m.name)))
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        _isReady ? Icons.check_circle : Icons.error,
                        size: 16,
                        color: _isReady ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _statusMessage,
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed:
                        _isReady && !_isCapturing ? _startScreenCapture : null,
                    icon: const Icon(Icons.screenshot, size: 18),
                    label:
                        Text(_isCapturing ? 'Capturing...' : 'Capture (Alt+A)'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _compressedData != null && !_isEncoding
                        ? _startEncoding
                        : null,
                    icon: const Icon(Icons.qr_code, size: 18),
                    label: const Text('Encode & Display'),
                  ),
                  if (_frames.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _stopEncoding,
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('Stop'),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (_compressedData != null) ...[
                    _infoRow('Capture', '${_capturedWidth}x$_capturedHeight'),
                    const SizedBox(height: 6),
                    _infoRow('Compressed',
                        '${((_compressedData?.length ?? 0) / 1024).toStringAsFixed(1)} KB'),
                    const SizedBox(height: 6),
                    _infoRow('Mode', _config.mode.name),
                    const SizedBox(height: 6),
                    _infoRow('Frames', '${_frames.length}'),
                  ],
                  const Spacer(),
                  if (_frames.isNotEmpty)
                    Text(
                      'Frame ${_currentFrameIndex + 1} / ${_frames.length}',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFrameDisplay() {
    if (_decodedFrames.isEmpty || _currentFrameIndex >= _decodedFrames.length) {
      return const SizedBox.shrink();
    }
    return CustomPaint(
      painter: _CimbarPainter(
        image: _decodedFrames[_currentFrameIndex],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.screenshot_monitor_outlined,
              size: 80, color: Theme.of(context).colorScheme.outline),
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
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
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

/// Paints a ui.Image stretched to fill the entire canvas.
class _CimbarPainter extends CustomPainter {
  final ui.Image image;
  _CimbarPainter({required this.image});

  @override
  void paint(Canvas canvas, Size size) {
    debugPrint('[Painter] canvas size: ${size.width}x${size.height}, '
        'image: ${image.width}x${image.height}');
    final paint = Paint()..filterQuality = FilterQuality.high;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CimbarPainter old) => old.image != image;
}

/// Small window control button (minimize/close).
class _WindowButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isClose;

  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isClose = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 28,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onPressed,
          hoverColor:
              isClose ? Colors.red : Colors.white.withValues(alpha: 0.1),
          child: Icon(icon, size: 16, color: Colors.white70),
        ),
      ),
    );
  }
}
