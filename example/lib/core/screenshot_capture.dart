import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'window_ctrl.dart';

/// Result of a screenshot capture operation.
class ScreenshotResult {
  /// Raw RGBA pixel data of the cropped region.
  final Uint8List? pixels;

  /// Width of the cropped region in physical pixels.
  final int width;

  /// Height of the cropped region in physical pixels.
  final int height;

  /// Error message if capture failed, null on success.
  final String? error;

  /// The full-screen temp file path (for overlay background display).
  final String? fullScreenPath;

  /// The selected region in logical coordinates.
  final Rect? selectedRegion;

  const ScreenshotResult({
    this.pixels,
    this.width = 0,
    this.height = 0,
    this.error,
    this.fullScreenPath,
    this.selectedRegion,
  });

  bool get isSuccess => pixels != null && error == null;
}

/// Modular screenshot capture state machine.
///
/// Flow:
/// 1. Hide window ([WindowCtrl.hideForCapture])
/// 2. Capture full screen to temp PNG (C# EXE / PowerShell fallback)
/// 3. Show region selection overlay on top of the screenshot
/// 4. Restore window + crop selected region
/// 5. Return raw RGBA pixels
class ScreenshotCapture {
  ScreenshotCapture._();
  static final ScreenshotCapture instance = ScreenshotCapture._();

  bool _busy = false;
  DateTime? _lastCaptureTime;
  static const int _cooldownMs = 500;
  static const int _captureTimeoutSec = 30;
  DateTime? _captureStartTime;

  /// Global navigator key for showing dialogs without BuildContext.
  /// Must be set during app startup.
  static GlobalKey<NavigatorState>? navigatorKey;

  /// Pre-compiled native capture EXE path (Windows).
  String? _nativeCaptureExePath;

  WindowCtrl get _winCtrl => WindowCtrl.instance;

  // --- Public API ---

  /// Pre-compile the native C# screenshot tool (call on app startup).
  Future<void> ensureNativeToolReady() async {
    if (Platform.isWindows) {
      await _ensureNativeCaptureTool();
    }
  }

  /// Take a screenshot with region selection.
  ///
  /// Returns a [ScreenshotResult] with the cropped RGBA pixel data.
  Future<ScreenshotResult> takeScreenshot() async {
    // Triple protection against concurrent execution
    if (_busy) {
      if (_isCaptureStuck()) {
        await _forceRecover();
      } else {
        return const ScreenshotResult(error: 'Capture in progress');
      }
    }
    if (_lastCaptureTime != null) {
      final elapsed = DateTime.now().difference(_lastCaptureTime!).inMilliseconds;
      if (elapsed < _cooldownMs) {
        return const ScreenshotResult(error: 'Cooldown active');
      }
    }

    _busy = true;
    _captureStartTime = DateTime.now();

    try {
      return await _captureRegion();
    } catch (e) {
      debugPrint('[ScreenshotCapture] Error: $e');
      return ScreenshotResult(error: e.toString());
    } finally {
      _busy = false;
      _captureStartTime = null;
      _lastCaptureTime = DateTime.now();
    }
  }

  bool _isCaptureStuck() {
    if (_captureStartTime == null) return false;
    return DateTime.now().difference(_captureStartTime!).inSeconds > _captureTimeoutSec;
  }

  Future<void> _forceRecover() async {
    _busy = false;
    _captureStartTime = null;
    await _winCtrl.forceReset();
  }

  // --- Core capture flow ---

  Future<ScreenshotResult> _captureRegion() async {
    String? tmpPath;
    try {
      // 1. Hide window
      debugPrint('[Screenshot] [1/5] Hiding window...');
      await _winCtrl.hideForCapture();
      await Future.delayed(const Duration(milliseconds: 100));

      // 2. Capture full screen to temp file
      debugPrint('[Screenshot] [2/5] Capturing full screen...');
      final appDir = await getApplicationDocumentsDirectory();
      final toolDir = '${appDir.path}/libcimbar_screenshots';
      await Directory(toolDir).create(recursive: true);
      tmpPath = '$toolDir/tmp_capture_${DateTime.now().millisecondsSinceEpoch}.png';

      final captureOk = await _captureFullScreen(tmpPath);
      if (!captureOk) {
        await _winCtrl.restoreToNormal();
        return const ScreenshotResult(error: 'Full screen capture failed');
      }

      // 3. Enter selection mode and show overlay
      debugPrint('[Screenshot] [3/5] Showing selection overlay...');
      await _winCtrl.enterSelectionMode();
      await windowManager.show();
      await windowManager.focus();
      await Future.delayed(const Duration(milliseconds: 80));

      final selectedRect = await _showRegionSelector(tmpPath);
      if (selectedRect == null) {
        _cleanupTmpFile(tmpPath);
        await _winCtrl.restoreToNormal();
        return const ScreenshotResult(error: 'Selection cancelled');
      }

      // 4+5. Restore window + crop (parallel)
      debugPrint('[Screenshot] [4/5] Restoring window + cropping...');
      final results = await Future.wait<Object?>([
        _winCtrl.restoreToNormal(),
        _cropToPixels(tmpPath, selectedRect),
      ]);
      _cleanupTmpFile(tmpPath);

      final cropResult = results[1] as _CropResult?;
      if (cropResult == null) {
        return const ScreenshotResult(error: 'Crop failed');
      }

      return ScreenshotResult(
        pixels: cropResult.pixels,
        width: cropResult.width,
        height: cropResult.height,
        fullScreenPath: tmpPath,
        selectedRegion: selectedRect,
      );
    } catch (e) {
      debugPrint('[Screenshot] Error: $e');
      if (tmpPath != null) _cleanupTmpFile(tmpPath);
      await _winCtrl.restoreToNormal();
      return ScreenshotResult(error: e.toString());
    }
  }

  // --- Full screen capture (Windows) ---

  Future<bool> _captureFullScreen(String filePath) async {
    if (Platform.isWindows) {
      final result = await _captureWindowsFullScreen(filePath);
      return result.exitCode == 0 && await File(filePath).exists();
    }
    return false;
  }

  Future<ProcessResult> _captureWindowsFullScreen(String filePath) async {
    final exePath = await _ensureNativeCaptureTool();
    if (exePath != null) {
      return Process.run(exePath, [filePath]);
    }

    // Fallback: PowerShell
    final psPath = filePath.replaceAll("'", "''");
    final script = [
      'Add-Type -AssemblyName System.Windows.Forms,System.Drawing',
      r'$s = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds',
      r'$b = New-Object System.Drawing.Bitmap $s.Width, $s.Height',
      r'$g = [System.Drawing.Graphics]::FromImage($b)',
      r'$g.CopyFromScreen($s.Location, [System.Drawing.Point]::Empty, $s.Size)',
      "\$b.Save('$psPath')",
      r'$g.Dispose()',
      r'$b.Dispose()',
    ].join('; ');

    return Process.run('powershell', [
      '-NonInteractive', '-NoProfile', '-Command', script,
    ]);
  }

  // --- C# native capture tool ---

  static const _csSource = r'''
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;

class ScreenCapture {
    static int Main(string[] args) {
        if (args.Length < 1) { return 1; }
        try {
            var screen = Screen.PrimaryScreen.Bounds;
            using (var bmp = new Bitmap(screen.Width, screen.Height, PixelFormat.Format32bppArgb)) {
                using (var g = Graphics.FromImage(bmp)) {
                    g.CopyFromScreen(screen.Location, Point.Empty, screen.Size, CopyPixelOperation.SourceCopy);
                }
                bmp.Save(args[0], ImageFormat.Png);
            }
            return 0;
        } catch { return 1; }
    }
}
''';

  Future<String?> _ensureNativeCaptureTool() async {
    if (_nativeCaptureExePath != null &&
        await File(_nativeCaptureExePath!).exists()) {
      return _nativeCaptureExePath;
    }

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final toolDir = '${appDir.path}/libcimbar_screenshots';
      await Directory(toolDir).create(recursive: true);

      final csPath = '$toolDir/ScreenCapture.cs';
      final exePath = '$toolDir/ScreenCapture.exe';

      if (await File(exePath).exists()) {
        _nativeCaptureExePath = exePath;
        return exePath;
      }

      await File(csPath).writeAsString(_csSource);

      final cscPaths = [
        r'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
        r'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe',
      ];
      String? csc;
      for (final p in cscPaths) {
        if (await File(p).exists()) {
          csc = p;
          break;
        }
      }
      if (csc == null) {
        final r = await Process.run('where', ['csc.exe']);
        if (r.exitCode == 0) {
          csc = (r.stdout as String).trim().split('\n').first.trim();
        }
      }
      if (csc == null) return null;

      final result = await Process.run(csc, [
        '/nologo', '/target:exe',
        '/reference:System.Drawing.dll',
        '/reference:System.Windows.Forms.dll',
        '/out:$exePath', csPath,
      ]);

      if (result.exitCode != 0 || !await File(exePath).exists()) return null;

      _nativeCaptureExePath = exePath;
      return exePath;
    } catch (_) {
      return null;
    }
  }

  // --- Region selector ---

  Future<Rect?> _showRegionSelector(String backgroundImagePath) async {
    final context = navigatorKey?.currentContext;
    if (context == null || !context.mounted) return null;

    // Import is done lazily to avoid circular dependency
    return showDialog<Rect>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      builder: (context) => _RegionSelectOverlay(
        backgroundImagePath: backgroundImagePath,
      ),
    );
  }

  // --- Crop to raw pixels ---

  Future<_CropResult?> _cropToPixels(String tmpPath, Rect selection) async {
    final fullBytes = await File(tmpPath).readAsBytes();
    final decoded = img.decodeImage(fullBytes);
    if (decoded == null) return null;

    // DPI scaling: overlay coords are logical, image is physical
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final dpr = views.isNotEmpty ? views.first.devicePixelRatio : 1.0;

    final left = (selection.left * dpr).toInt().clamp(0, decoded.width);
    final top = (selection.top * dpr).toInt().clamp(0, decoded.height);
    final width = (selection.width * dpr).toInt().clamp(1, decoded.width - left);
    final height = (selection.height * dpr).toInt().clamp(1, decoded.height - top);

    final cropped = img.copyCrop(decoded, x: left, y: top, width: width, height: height);

    // Convert to raw RGBA bytes
    final rgba = cropped.getBytes(order: img.ChannelOrder.rgba);
    return _CropResult(pixels: rgba, width: width, height: height);
  }

  void _cleanupTmpFile(String path) {
    try {
      File(path).deleteSync();
    } catch (_) {}
  }
}

/// Internal crop result.
class _CropResult {
  final Uint8List pixels;
  final int width;
  final int height;
  const _CropResult({required this.pixels, required this.width, required this.height});
}

/// Region selection overlay that shows the screenshot as background.
class _RegionSelectOverlay extends StatefulWidget {
  final String backgroundImagePath;
  const _RegionSelectOverlay({required this.backgroundImagePath});

  @override
  State<_RegionSelectOverlay> createState() => _RegionSelectOverlayState();
}

class _RegionSelectOverlayState extends State<_RegionSelectOverlay> {
  Offset? _startPoint;
  Offset? _endPoint;

  Rect? get _selectionRect {
    if (_startPoint == null || _endPoint == null) return null;
    return Rect.fromPoints(_startPoint!, _endPoint!);
  }

  void _confirmSelection() {
    final rect = _selectionRect;
    if (rect != null && rect.width > 10 && rect.height > 10) {
      Navigator.of(context).pop(rect);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: FocusNode()..requestFocus(),
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop<Rect>(null);
        }
      },
      child: GestureDetector(
        onPanStart: (d) => setState(() {
          _startPoint = d.localPosition;
          _endPoint = d.localPosition;
        }),
        onPanUpdate: (d) {
          if (_startPoint != null) {
            setState(() => _endPoint = d.localPosition);
          }
        },
        onPanEnd: (_) => _confirmSelection(),
        child: Stack(
          children: [
            // Background: the actual screenshot
            Positioned.fill(
              child: Image.file(
                File(widget.backgroundImagePath),
                fit: BoxFit.cover,
              ),
            ),
            // Dimming layer
            Positioned.fill(
              child: Container(color: Colors.black.withValues(alpha: 0.15)),
            ),
            // Selection rectangle
            if (_selectionRect != null) ...[
              CustomPaint(
                size: MediaQuery.of(context).size,
                painter: _SelectionPainter(selection: _selectionRect!),
              ),
              Positioned(
                left: _selectionRect!.left,
                top: _selectionRect!.top - 28,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${_selectionRect!.width.toInt()} x ${_selectionRect!.height.toInt()}',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
            // Instructions
            Positioned(
              top: 40,
              left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Drag to select region. Release to capture. Esc to cancel.',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionPainter extends CustomPainter {
  final Rect selection;
  _SelectionPainter({required this.selection});

  @override
  void paint(Canvas canvas, Size size) {
    // Blue fill
    canvas.drawRect(
      selection,
      Paint()..color = Colors.blue.withValues(alpha: 0.2),
    );
    // White border
    canvas.drawRect(
      selection,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // Corner handles
    const handleLen = 12.0;
    final handlePaint = Paint()..color = Colors.white..strokeWidth = 3;
    for (final corner in [
      selection.topLeft, selection.topRight,
      selection.bottomLeft, selection.bottomRight,
    ]) {
      final dx = corner == selection.topLeft || corner == selection.bottomLeft ? 1.0 : -1.0;
      final dy = corner == selection.topLeft || corner == selection.topRight ? 1.0 : -1.0;
      canvas.drawLine(corner, corner.translate(handleLen * dx, 0), handlePaint);
      canvas.drawLine(corner, corner.translate(0, handleLen * dy), handlePaint);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) => old.selection != selection;
}
