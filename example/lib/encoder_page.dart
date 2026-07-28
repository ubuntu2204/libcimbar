import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:libcimbar/libcimbar.dart';
import 'package:window_manager/window_manager.dart';

import 'core/debug_server.dart';
import 'core/screenshot_capture.dart';
import 'core/window_display.dart';

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
    with TickerProviderStateMixin, WindowListener {
  final CimbarPlatform _platform = CimbarPlatform.instance;

  ICimbarEncoder? _encoder;
  IImageCompressor? _compressor;

  bool _isReady = false;
  bool _isEncoding = false;
  bool _isCapturing = false;
  // Windows starts windowed (still topmost); Linux starts in cover mode
  // (fullscreen layer) — see main.dart — so the toggle state must match.
  bool _coveringTaskbar = !kIsWeb && Platform.isLinux;
  String _statusMessage = 'Initializing...';

  CimbarConfig _config = const CimbarConfig(
    mode: CimbarMode.modeB,
    compressionLevel: 16,
    fps: 15,
  );

  /// Range of supported display rates.
  static const int _minFps = 1;
  static const int _maxFps = 60;

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

  // Measures the on-screen size of the cimbar display (for the quality check).
  final GlobalKey _displayKey = GlobalKey();

  // Green light: lit while the decoder is actively talking to our debug
  // server (poll/upload within the last few seconds).
  Timer? _linkTimer;
  bool _decoderLinked = false;

  @override
  void initState() {
    super.initState();
    // Project rule: the encoder window must stay frontmost (always-on-top).
    // Listen for focus changes so we can re-assert it (see [onWindowBlur]).
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      windowManager.addListener(this);
      // Refresh the "decoder linked" light from the debug server's last-seen
      // timestamp (green while the decoder polled/uploaded within ~6s).
      _linkTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        final last = DebugServer.instance.lastPeerRequestAt;
        final ok =
            last != null && DateTime.now().difference(last).inSeconds < 6;
        if (ok != _decoderLinked && mounted) {
          setState(() => _decoderLinked = ok);
        }
      });
    }
    _initialize();
  }

  /// Project rule (.qoder/rules): the encoder window must always stay on top /
  /// frontmost, so the displayed cimbar is never occluded. Whenever the window
  /// loses focus, re-assert topmost so it can never fall behind other windows.
  /// Skipped during the region-capture flow, which intentionally toggles the
  /// window state and restores it afterwards.
  @override
  void onWindowBlur() {
    if (_isCapturing) return;
    windowManager.setAlwaysOnTop(true);
  }

  /// Toggle between covering the taskbar (topmost, full-screen size) and a
  /// normal centered windowed size. Both stay topmost (above the taskbar);
  /// neither uses fullscreen mode.
  Future<void> _toggleCoverTaskbar() async {
    try {
      if (_coveringTaskbar) {
        await restoreWindowed();
      } else {
        await coverTaskbar();
      }
      if (mounted) setState(() => _coveringTaskbar = !_coveringTaskbar);
    } catch (_) {}
  }

  Future<void> _initialize() async {
    // Guard: encoder runs on desktop (Windows: full feature set incl. screen
    // capture; Linux: encode/display + test payload + debug server).
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux)) {
      setState(() {
        _statusMessage = 'Error: Encoding is only supported on '
            'Windows/Linux desktop.';
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

      // Register Alt+S hotkey for the debug full-screen screenshot.
      await hotKeyManager.register(
        HotKey(
          key: LogicalKeyboardKey.keyS,
          modifiers: [HotKeyModifier.alt],
        ),
        keyDownHandler: (_) => _saveDebugScreenshot(),
      );

      // Register Alt+Q hotkey for the barcode quality check.
      await hotKeyManager.register(
        HotKey(
          key: LogicalKeyboardKey.keyQ,
          modifiers: [HotKeyModifier.alt],
        ),
        keyDownHandler: (_) => _checkBarcodeQuality(),
      );

      // Start the LAN debug server: the decoder can pull the pristine frame
      // being displayed (/frame.png) and push back its camera view, so the
      // two ends can be aligned in real time instead of debugging blind.
      DebugServer.instance
        ..frameProvider = (() => _frames.isEmpty
            ? null
            : _frames[_currentFrameIndex % _frames.length])
        ..statusProvider = (() => <String, Object?>{
              'ready': _isReady,
              'mode': _config.mode.name,
              'displayFps': _config.fps,
              'frames': _frames.length,
              'currentFrame': _currentFrameIndex,
              'nativeWidth': _frames.isEmpty ? 0 : _frames.first.width,
              'nativeHeight': _frames.isEmpty ? 0 : _frames.first.height,
            })
        ..onEncodeTest = () async {
          // Script-driven loop (POST /encode-test): test payload -> encode.
          _useTestPayload();
          await _startEncoding();
          return '${_frames.length} frames';
        };
      final debugUrl = await DebugServer.instance.start();

      setState(() {
        _isReady = _encoder!.isReady;
        _statusMessage = _isReady
            ? 'Ready. Press Alt+A to capture screen.'
                '${debugUrl != null ? '\nDebug server: $debugUrl' : ''}'
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

  /// Debug helper: save a full-screen screenshot (window kept visible) so the
  /// displayed cimbar frames can be inspected outside the app. Useful for
  /// diagnosing decode failures. The saved path is shown in the status text
  /// (which is selectable, so it can be copied).
  Future<void> _saveDebugScreenshot() async {
    if (mounted) {
      setState(() => _statusMessage = 'Saving full-screen screenshot...');
    }
    final path = await ScreenshotCapture.instance.captureFullScreenToFile();
    if (!mounted) return;
    setState(() {
      _statusMessage = path != null
          ? 'Saved full-screen screenshot:\n$path'
          : 'Full-screen screenshot failed.';
    });
  }

  /// Fill the encode input with deterministic random bytes — no screen
  /// capture needed. This is the data source on Linux (where the Windows
  /// capture tool is unavailable) and a quick loopback payload everywhere.
  void _useTestPayload() {
    final rnd = math.Random(42);
    final data = Uint8List.fromList(
        List<int>.generate(200 * 1024, (_) => rnd.nextInt(256)));
    _compressedData = data;
    _capturedWidth = 0;
    _capturedHeight = 0;
    setState(() {
      _statusMessage = 'Test payload ready: ${data.length} bytes of random '
          'data. Click "Encode & Display".';
    });
  }

  /// Analyze whether the generated cimbar is presented with enough pixels to be
  /// decodable, and save a plain-text report for later analysis.
  ///
  /// "Enough pixels" means the on-screen cimbar is rendered at >= its native
  /// resolution in *physical* pixels. If the window is small or DPI scaling
  /// shrinks it, the barcode is downscaled and the decoder fails.
  Future<void> _checkBarcodeQuality() async {
    if (_frames.isEmpty) {
      setState(
          () => _statusMessage = 'No barcode yet - encode & display first.');
      return;
    }

    final int nativeW = _frames.first.width;
    final int nativeH = _frames.first.height;

    // Actual on-screen render size of the cimbar (logical px).
    final RenderBox? box =
        _displayKey.currentContext?.findRenderObject() as RenderBox?;
    final Size logical = (box != null && box.hasSize) ? box.size : Size.zero;

    // Windows display scaling (device pixel ratio).
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final double dpr = views.isNotEmpty ? views.first.devicePixelRatio : 1.0;

    final int physW = (logical.width * dpr).round();
    final int physH = (logical.height * dpr).round();
    final double scaleW = nativeW == 0 ? 0.0 : physW / nativeW;
    final double scaleH = nativeH == 0 ? 0.0 : physH / nativeH;

    final bool passW = physW >= nativeW;
    final bool passH = physH >= nativeH;
    final bool pass = passW && passH;

    final report = StringBuffer()
      ..writeln('libcimbar encoder - barcode quality report')
      ..writeln('Generated  : ${DateTime.now().toIso8601String()}')
      ..writeln('Mode       : ${_config.mode.name}')
      ..writeln('Display FPS: ${_config.fps}')
      ..writeln('Frames     : ${_frames.length}')
      ..writeln('')
      ..writeln('[Generated barcode]')
      ..writeln('  Native resolution : $nativeW x $nativeH px')
      ..writeln('')
      ..writeln('[On-screen display]')
      ..writeln('  DPI scale (DPR)   : ${dpr.toStringAsFixed(3)}')
      ..writeln('  Logical size      : '
          '${logical.width.toStringAsFixed(1)} x ${logical.height.toStringAsFixed(1)}')
      ..writeln('  Physical size     : $physW x $physH px')
      ..writeln('  Scale vs native   : '
          '${scaleW.toStringAsFixed(2)}x by ${scaleH.toStringAsFixed(2)}x')
      ..writeln('')
      ..writeln('[Verdict - enough pixels?]')
      ..writeln('  Horizontal : ${passW ? 'PASS' : 'FAIL'} '
          '($physW ${passW ? '>=' : '<'} $nativeW)')
      ..writeln('  Vertical   : ${passH ? 'PASS' : 'FAIL'} '
          '($physH ${passH ? '>=' : '<'} $nativeH)')
      ..writeln('  OVERALL    : ${pass ? 'PASS' : 'FAIL'}')
      ..writeln('');
    if (pass) {
      report.writeln('Displayed at >= 1:1 of native resolution - enough pixels '
          'for decoding.');
      if (dpr != 1.0 || (scaleW - scaleW.roundToDouble()).abs() > 0.001) {
        report.writeln('Note: non-integer scale with FilterQuality.high means '
            'the cimbar is interpolated (slightly blurred). If decoding still '
            'fails, render at an integer scale with FilterQuality.none.');
      }
    } else {
      report.writeln('Displayed BELOW native resolution - the cimbar is '
          'downscaled and likely undecodable. Enlarge the window / cimbar area '
          'so the display is at least $nativeW x $nativeH physical pixels '
          '(currently $physW x $physH).');
    }

    final path =
        await ScreenshotCapture.instance.saveDebugReport(report.toString());
    if (!mounted) return;
    setState(() {
      _statusMessage = path != null
          ? '${pass ? 'PASS' : 'FAIL'} - quality report saved:\n$path'
          : 'Quality report failed to save.';
    });
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

      // Linux: force cover mode (WM fullscreen layer) when the barcode starts
      // playing so it is guaranteed to sit above the dock/top bar for the
      // camera. Always-on-top is re-asserted inside coverTaskbar() last.
      if (!kIsWeb && Platform.isLinux && !_coveringTaskbar) {
        await coverTaskbar();
        if (mounted) setState(() => _coveringTaskbar = true);
      }

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

  /// Update display FPS and restart the animation controller so the new
  /// period takes effect immediately.
  void _setFps(int newFps) {
    final clamped = newFps.clamp(_minFps, _maxFps);
    if (clamped == _config.fps) return;
    setState(() {
      _config = _config.copyWith(fps: clamped);
    });
    // Restart the controller with the new period.
    final controller = _frameAnimationController;
    if (controller != null && _frames.isNotEmpty) {
      controller
        ..stop()
        ..duration = Duration(milliseconds: 1000 ~/ clamped)
        ..forward();
    }
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
                  key: _displayKey,
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
              child: Stack(
                children: [
                  // Press-and-drag on any empty part of the left panel to move
                  // the frameless window. Interactive controls sit above this
                  // layer, so they still receive their own taps and drags.
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => windowManager.startDragging(),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  Padding(
                    // Extra top inset so the window control buttons (fullscreen
                    // / minimize / close) sit a little lower and easy to reach.
                    padding: const EdgeInsets.fromLTRB(10, 32, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Window controls (fullscreen toggle, minimize, close)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            _WindowButton(
                              icon: _coveringTaskbar
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                              tooltip: _coveringTaskbar
                                  ? 'Windowed mode'
                                  : 'Cover taskbar',
                              onPressed: _toggleCoverTaskbar,
                            ),
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
                              .map((m) =>
                                  PopupMenuItem(value: m, child: Text(m.name)))
                              .toList(),
                        ),
                        const SizedBox(height: 12),
                        // Debug-link status: green once the decoder has
                        // connected (negotiation/pull/upload traffic seen).
                        Row(
                          children: [
                            Icon(Icons.circle,
                                size: 10,
                                color: _decoderLinked
                                    ? Colors.greenAccent
                                    : Colors.grey),
                            const SizedBox(width: 6),
                            Text(
                              _decoderLinked
                                  ? 'Decoder linked'
                                  : 'Decoder not connected',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              _isReady ? Icons.check_circle : Icons.error,
                              size: 16,
                              color: _isReady ? Colors.green : Colors.red,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxHeight: 120),
                                child: SingleChildScrollView(
                                  // Selectable so users can copy error / status text.
                                  child: SelectableText(
                                    _statusMessage,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _isReady && !_isCapturing
                              ? _startScreenCapture
                              : null,
                          icon: const Icon(Icons.screenshot, size: 18),
                          label: Text(_isCapturing
                              ? 'Capturing...'
                              : 'Capture (Alt+A)'),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _compressedData != null && !_isEncoding
                              ? _startEncoding
                              : null,
                          icon: const Icon(Icons.qr_code, size: 18),
                          label: const Text('Encode & Display'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _isReady ? _useTestPayload : null,
                          icon: const Icon(Icons.science, size: 18),
                          label: const Text('Test payload (200KB)'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _saveDebugScreenshot,
                          icon: const Icon(Icons.bug_report, size: 18),
                          label: const Text('Debug shot (Alt+S)'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed:
                              _frames.isNotEmpty ? _checkBarcodeQuality : null,
                          icon: const Icon(Icons.high_quality, size: 18),
                          label: const Text('Check quality (Alt+Q)'),
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
                          _infoRow(
                              'Capture', '${_capturedWidth}x$_capturedHeight'),
                          const SizedBox(height: 6),
                          _infoRow('Compressed',
                              '${((_compressedData?.length ?? 0) / 1024).toStringAsFixed(1)} KB'),
                          const SizedBox(height: 6),
                          _infoRow('Mode', _config.mode.name),
                          const SizedBox(height: 6),
                          _fpsControl(),
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

  /// FPS control: shows current display rate, lets the user adjust it
  /// via a slider. The new rate is applied live via [_setFps].
  Widget _fpsControl() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Display FPS',
                  style: Theme.of(context).textTheme.labelSmall),
              Text(
                '${_config.fps} /s',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
          Slider(
            value: _config.fps.toDouble(),
            min: _minFps.toDouble(),
            max: _maxFps.toDouble(),
            divisions: _maxFps - _minFps,
            label: '${_config.fps} fps',
            onChanged: (v) => _setFps(v.round()),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _linkTimer?.cancel();
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      windowManager.removeListener(this);
    }
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

/// Paints a cimbar [ui.Image] as a centered square, uniformly scaled (never
/// distorted) and with no interpolation, so the tile grid stays crisp and
/// decodable.
class _CimbarPainter extends CustomPainter {
  final ui.Image image;
  _CimbarPainter({required this.image});

  @override
  void paint(Canvas canvas, Size size) {
    // Largest centered square that fits - keeps the barcode square even if the
    // canvas is not (e.g. a slightly short window), instead of stretching it.
    final double side = size.shortestSide;
    final double dx = (size.width - side) / 2;
    final double dy = (size.height - side) / 2;
    // FilterQuality.none: nearest-neighbour, so tiles are not blurred by
    // interpolation (critical for decoding, especially at DPI scale != 1).
    final paint = Paint()..filterQuality = FilterQuality.none;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(dx, dy, side, side),
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
