import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:libcimbar/libcimbar.dart';
import 'package:window_manager/window_manager.dart';

import 'core/debug_server.dart';
import 'core/screenshot_capture.dart';
import 'core/window_display.dart';

/// Parsed summary of a diagnostic report pushed by the decoder (phone).
///
/// The reports are long plain-text dumps; the encoder UI only needs the
/// verdict plus the one thing the operator should DO about it.
class _ReportInfo {
  /// One-line verdict, e.g. "找到 0/4 个角标".
  final String headline;

  /// Actionable advice for the operator.
  final String hint;

  /// Secondary facts (camera resolution, stream progress...), pre-formatted.
  final String detail;

  /// True when the report signals a failure.
  final bool isError;

  /// True when a file was fully recovered.
  final bool isSuccess;

  const _ReportInfo({
    required this.headline,
    required this.hint,
    required this.detail,
    this.isError = false,
    this.isSuccess = false,
  });
}

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
  String _statusMessage = '初始化中…';

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

  /// Captures the *rendered* cimbar display (physical pixels) for the
  /// screenshot decode self-test.
  final GlobalKey _displayBoundaryKey = GlobalKey();

  /// True while the screenshot → decode loopback self-test is running.
  bool _isDecodeTesting = false;

  // Green light: lit while the decoder is actively talking to our debug
  // server (poll/upload within the last few seconds).
  Timer? _linkTimer;
  bool _decoderLinked = false;

  // Last diagnostic report pushed by the decoder (phone) via POST /report,
  // parsed down to a headline + actionable hint so the encoder side can see
  // WHY the phone cannot decode, instead of the report silently landing in
  // the documents folder.
  _ReportInfo? _lastReport;
  DateTime? _lastReportAt;

  // Last camera frame the decoder uploaded (POST /captured).
  String? _lastRemoteCapturePath;

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
        _statusMessage = '错误：编码仅支持 Windows/Linux 桌面端。';
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

      // Register Alt+D hotkey for the screenshot decode self-test: capture
      // the rendered barcode and decode it locally, verifying the whole
      // encode→display→decode chain without a phone/web camera.
      await hotKeyManager.register(
        HotKey(
          key: LogicalKeyboardKey.keyD,
          modifiers: [HotKeyModifier.alt],
        ),
        keyDownHandler: (_) => _runDecodeTest(),
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
        }
        ..onDecodeTest = () async {
          // Script-driven loop (POST /decode-test): screenshot decode
          // self-test, returns the PASS/FAIL summary.
          return _runDecodeTest();
        }
        ..onReportReceived = (text) {
          // The phone pushed a diagnostic report: surface it in the UI.
          final info = _parseReport(text);
          if (mounted) {
            setState(() {
              _lastReport = info;
              _lastReportAt = DateTime.now();
            });
          }
          _announceReport(info);
        }
        ..onCaptureReceived = (path) {
          if (mounted) setState(() => _lastRemoteCapturePath = path);
        };
      final debugUrl = await DebugServer.instance.start();

      setState(() {
        _isReady = _encoder!.isReady;
        _statusMessage = _isReady
            ? '就绪。按 Alt+A 截取屏幕。'
                '${debugUrl != null ? '\n调试服务器：$debugUrl' : ''}'
            : '未加载原生库。请先构建 libcimbar.dll。';
      });
    } catch (e) {
      setState(() => _statusMessage = '初始化出错：$e');
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
          _statusMessage = result.error ?? '已取消截取';
          _isCapturing = false;
        });
        return;
      }

      _capturedWidth = result.width;
      _capturedHeight = result.height;

      // Compress to AVIF (or PNG fallback)
      _statusMessage = '正在压缩为 AVIF…';
      if (mounted) setState(() {});

      _compressedData = await _compressor!.compressRgba(
        result.pixels!,
        width: result.width,
        height: result.height,
        quality: CompressionQuality.balanced,
      );

      _statusMessage = '已截取 ${result.width}x${result.height}，'
          '压缩后 ${_compressedData!.length} 字节，可开始编码。';
    } catch (e) {
      _statusMessage = '截取出错：$e';
    }

    if (mounted) setState(() => _isCapturing = false);
  }

  /// Debug helper: save a full-screen screenshot (window kept visible) so the
  /// displayed cimbar frames can be inspected outside the app. Useful for
  /// diagnosing decode failures. The saved path is shown in the status text
  /// (which is selectable, so it can be copied).
  Future<void> _saveDebugScreenshot() async {
    if (mounted) {
      setState(() => _statusMessage = '正在保存全屏截图…');
    }
    final path = await ScreenshotCapture.instance.captureFullScreenToFile();
    if (!mounted) return;
    setState(() {
      _statusMessage = path != null
          ? '已保存全屏截图：\n$path'
          : '全屏截图失败。';
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
      _statusMessage = '测试数据已就绪：${data.length} 字节随机数据。'
          '点击「编码并显示」。';
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
          () => _statusMessage = '还没有条码 - 请先「编码并显示」。');
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
          ? '${pass ? '通过' : '未通过'} - 质量报告已保存：\n$path'
          : '质量报告保存失败。';
    });
  }

  // --- Decoder (phone) report handling ---

  /// Compact card showing the latest decoder (phone) report verdict.
  Widget _reportCard(_ReportInfo info) {
    final cs = Theme.of(context).colorScheme;
    final Color accent = info.isSuccess
        ? Colors.green
        : (info.isError ? Colors.redAccent : Colors.blueGrey);
    final ts = _lastReportAt;
    final time = ts == null
        ? ''
        : '${ts.hour.toString().padLeft(2, '0')}:'
            '${ts.minute.toString().padLeft(2, '0')}:'
            '${ts.second.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                info.isSuccess
                    ? Icons.check_circle
                    : (info.isError ? Icons.error_outline : Icons.info_outline),
                size: 14,
                color: accent,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '手机报告${time.isEmpty ? '' : ' · $time'}',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: accent),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            info.headline,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 3),
          Text(
            info.hint,
            style: TextStyle(fontSize: 10, color: cs.onSurface.withValues(alpha: 0.8)),
          ),
          const SizedBox(height: 3),
          Text(
            info.detail,
            style: TextStyle(fontSize: 9, color: cs.onSurface.withValues(alpha: 0.55)),
          ),
          if (_lastRemoteCapturePath != null) ...[
            const SizedBox(height: 3),
            Text(
              '摄像头画面：${_lastRemoteCapturePath!.split(RegExp(r'[\\/]')).last}',
              style: TextStyle(fontSize: 9, color: cs.onSurface.withValues(alpha: 0.45)),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  /// Reduce a decoder diagnostic report to a headline + one actionable hint.
  ///
  /// The phone pushes these via POST /report; without this the operator only
  /// sees a file appear in the documents folder and has to open it manually
  /// to learn why the scan is failing.
  _ReportInfo _parseReport(String text) {
    String? grab(String key, {String section = ''}) {
      // Report lines pad the key with spaces before the colon, e.g.
      // "Stream accum     : [ 0.6 ]" or "Recovered file   : (none)",
      // so match on `key` + any whitespace + ':' rather than an exact prefix.
      final re = RegExp('^${RegExp.escape(key)}\\s*:\\s*(.*)\$');
      for (final line in text.split('\n')) {
        final m = re.firstMatch(line.trim());
        if (m != null) return m.group(1)!.trim();
      }
      return null;
    }

    final errLine = grab('scan_extract_decode failed') ??
        (text.contains('[Last decode error]')
            ? text
                .split('[Last decode error]')
                .last
                .split('[')
                .first
                .trim()
            : null);
    final recovered = grab('Recovered file') ?? '(none)';
    final accum = grab('Stream accum') ?? '';
    final videoRes = grab('Video resolution') ?? '?';
    final headroom = grab('Barcode headroom') ?? '';
    final progress = grab('Progress') ?? '0.0%';
    final frames = grab('Frames processed') ?? '0';

    // "Stream accum : [ 0.614458 ] (received/required ...)" -> 0.614458
    final accNum = RegExp(r'\[\s*([\d.]+)').firstMatch(accum)?.group(1);
    final accText = accNum != null ? '累积 ${(double.parse(accNum) * 100).toStringAsFixed(0)}%' : '累积 —';
    final detail = '摄像头 $videoRes ｜ $accText ｜ 已处理 $frames 帧';

    // 1) Success — a file came back.
    if (!recovered.contains('(none)') && recovered.isNotEmpty) {
      return _ReportInfo(
        headline: '解码成功：$recovered',
        hint: '手机端已完整恢复文件。',
        detail: detail,
        isSuccess: true,
      );
    }

    // 2) Anchor problems — the dominant real-world failure.
    final anchorMatch =
        RegExp(r'found (\d+) anchor', caseSensitive: false).firstMatch(
      errLine ?? text,
    );
    if (anchorMatch != null) {
      final n = int.tryParse(anchorMatch.group(1)!) ?? 0;
      if (n == 0) {
        return _ReportInfo(
          headline: '手机端找不到角标（0/4）',
          hint: '条码在画面里太小/模糊：请让手机靠近、把条码填满画面，'
              '并确认对焦与反光正常。',
          detail: detail,
          isError: true,
        );
      }
      return _ReportInfo(
        headline: '手机端只找到 $n/4 个角标',
        hint: '条码被裁切或偏离中心：请把四个角都收进画面（取景模式建议选 Fit），'
            '并确认条码像素 ≥ 1024。',
        detail: detail,
        isError: true,
      );
    }

    // 3) Accumulation overshoot — corrupt chunks mixed in.
    final accVal = double.tryParse(accNum ?? '');
    if (accVal != null && accVal > 1.0) {
      return _ReportInfo(
        headline: '喷泉流被污染（accum $accVal > 1.0）',
        hint: '收到足够的块却无法组装：通常是同一条码的摄像头帧混入了坏块。'
            '请停止扫描后重新编码再试。',
        detail: detail,
        isError: true,
      );
    }

    // 4) Still working — report progress.
    if (errLine == null || errLine.isEmpty) {
      return _ReportInfo(
        headline: '手机端解码进行中（$progress）',
        hint: headroom.startsWith('LOW') || headroom.startsWith('TIGHT')
            ? '注意：$headroom'
            : '继续扫描直到累积进度达到 1.0。',
        detail: detail,
      );
    }

    return _ReportInfo(
      headline: '手机端解码失败',
      hint: errLine,
      detail: detail,
      isError: true,
    );
  }

  /// Show a transient snackbar so a report arriving is impossible to miss
  /// even when the side panel is scrolled out of view.
  void _announceReport(_ReportInfo info) {
    if (!mounted) return;
    final ctx = context;
    final color = info.isSuccess
        ? Colors.green
        : (info.isError ? Colors.redAccent : Colors.blueGrey);
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              info.isSuccess
                  ? Icons.check_circle
                  : (info.isError ? Icons.error_outline : Icons.info_outline),
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(info.headline)),
          ],
        ),
        backgroundColor: color,
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // --- Screenshot → decode loopback self-test ---

  /// Screenshot → decode loopback self-test.
  ///
  /// Captures the *rendered* cimbar display (exactly what is on screen,
  /// including any scaling/interpolation) frame by frame, feeds each capture
  /// to the native FFI decoder, and verifies the recovered data is
  /// byte-identical to the payload that was encoded.
  ///
  /// This runs the full pipeline — encode → display → screenshot → scan →
  /// fountain decode → decompress — so bugs anywhere in the chain are caught
  /// locally, without a phone/web camera. A detailed report (and the first
  /// capture as PNG) is saved next to the quality reports, pinpointing the
  /// failing stage:
  /// - capture missing / no anchors → compare the sample PNG, run Alt+Q
  /// - per-frame decode errors → native scan/fountain issue
  /// - complete but data mismatch → compression/format issue
  ///
  /// Returns the final PASS/FAIL summary (also shown in the status area and
  /// served by the debug server's POST /decode-test endpoint).
  Future<String> _runDecodeTest() async {
    if (_isDecodeTesting) return '解码自检正在进行中。';
    if (_frames.isEmpty || _compressedData == null) {
      setState(
          () => _statusMessage = '还没有条码 - 请先「编码并显示」。');
      return '还没有条码 - 请先「编码并显示」。';
    }

    _isDecodeTesting = true;
    final wasAnimating = _frameAnimationController != null &&
        _frameAnimationController!.isAnimating;
    _frameAnimationController?.stop();

    final report = StringBuffer()
      ..writeln('libcimbar encoder - screenshot decode self-test')
      ..writeln('Generated  : ${DateTime.now().toIso8601String()}')
      ..writeln('Mode       : ${_config.mode.name} '
          '(compression ${_config.compressionLevel})')
      ..writeln('Frames     : ${_frames.length} '
          '(${_frames.first.width}x${_frames.first.height} native)')
      ..writeln('Payload    : ${_compressedData!.length} bytes');

    int framesTried = 0;
    bool complete = false;
    DecodeResult? lastResult;
    bool pass = false;
    String? samplePath;
    String summary = '';

    try {
      setState(() => _statusMessage = '解码自检：正在创建解码器…');
      final decoder = await _platform.createDecoder();
      try {
        if (!decoder.isReady) {
          throw StateError(
              'Decoder not ready - native library not loaded?');
        }
        await decoder.configure(_config);

        final views = WidgetsBinding.instance.platformDispatcher.views;
        final dpr = views.isNotEmpty ? views.first.devicePixelRatio : 1.0;
        report
          ..writeln('Capture DPR: ${dpr.toStringAsFixed(3)}')
          ..writeln('');

        for (int i = 0; i < _frames.length && !complete; i++) {
          // Seek the display to frame i and wait until it is painted.
          if (mounted) setState(() => _currentFrameIndex = i);
          await Future<void>.delayed(Duration.zero);
          await WidgetsBinding.instance.endOfFrame;
          await Future<void>.delayed(const Duration(milliseconds: 16));

          // Screenshot the rendered barcode (physical pixels, raw RGBA).
          final boundary = _displayBoundaryKey.currentContext
              ?.findRenderObject() as RenderRepaintBoundary?;
          if (boundary == null) {
            report.writeln('frame ${i + 1}: capture boundary missing');
            continue;
          }
          final image = await boundary.toImage(pixelRatio: dpr);
          final capW = image.width;
          final capH = image.height;
          final rgba =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          if (i == 0) {
            // Keep the first capture as PNG for offline inspection.
            final png =
                await image.toByteData(format: ui.ImageByteFormat.png);
            if (png != null) {
              samplePath = await ScreenshotCapture.instance
                  .saveCapturePng(png.buffer.asUint8List());
            }
          }
          image.dispose();
          if (rgba == null) {
            report.writeln('frame ${i + 1}: capture failed (no bytes)');
            continue;
          }

          final result = await decoder.decodeFrame(
            rgba.buffer.asUint8List(),
            width: capW,
            height: capH,
            format: CimbarImageFormat.rgba,
          );
          framesTried++;
          lastResult = result;

          if (result.isComplete) {
            complete = true;
            report.writeln('frame ${i + 1}: ${capW}x$capH -> COMPLETE');
          } else if (result.error != null) {
            report.writeln(
                'frame ${i + 1}: ${capW}x$capH -> ERROR ${result.error}');
          } else {
            report.writeln('frame ${i + 1}: ${capW}x$capH -> ok '
                '(progress ${(result.progress * 100).toStringAsFixed(0)}%)');
          }
        }
      } finally {
        await decoder.dispose();
      }

      // ── Verdict ──
      final original = _compressedData!;
      report.writeln('');
      if (complete && lastResult?.data != null) {
        final decoded = lastResult!.data!;
        pass = decoded.length == original.length;
        int firstDiff = -1;
        if (pass) {
          for (int b = 0; b < original.length; b++) {
            if (decoded[b] != original[b]) {
              firstDiff = b;
              pass = false;
              break;
            }
          }
        }
        report
          ..writeln('[Result]')
          ..writeln('  Frames tried : $framesTried / ${_frames.length}')
          ..writeln('  Filename     : "${lastResult.filename}"')
          ..writeln('  Decoded size : ${decoded.length} bytes')
          ..writeln('  Payload size : ${original.length} bytes')
          ..writeln('  Byte-exact   : ${pass ? 'YES' : 'NO'}');
        if (pass) {
          report
            ..writeln('')
            ..writeln('Verdict: PASS - encode -> display -> screenshot -> '
                'decode roundtrip is byte-exact.');
        } else {
          report
            ..writeln('  First diff   : ${firstDiff >= 0 ? 'offset $firstDiff' : (decoded.length == original.length ? 'content mismatch' : 'size mismatch')}')
            ..writeln('')
            ..writeln('Verdict: FAIL - decoded data differs from the encoded '
                'payload.');
        }
      } else {
        report
          ..writeln('[Result]')
          ..writeln('  Frames tried : $framesTried / ${_frames.length}')
          ..writeln('  Complete     : NO'
              '${lastResult?.error != null ? ' (last error: ${lastResult!.error})' : ''}')
          ..writeln('')
          ..writeln('Verdict: FAIL - the fountain stream never completed. If '
              'every frame stays at 0% progress, the capture is missing the '
              'corner anchors - inspect the sample PNG and run Check quality '
              '(Alt+Q). If frames error out, the native scan/fountain stage '
              'is the culprit.');
      }
    } catch (e) {
      report
        ..writeln('')
        ..writeln('EXCEPTION: $e')
        ..writeln('')
        ..writeln('Verdict: FAIL - unexpected error (see exception above).');
    } finally {
      final reportPath = await ScreenshotCapture.instance
          .saveDebugReport(report.toString(), name: 'decode_test_report');
      summary =
          '${pass ? '通过' : '未通过'} - 解码自检：$framesTried/'
              '${_frames.length} 帧'
              '${complete ? '，恢复 ${lastResult?.data?.length ?? 0} 字节' : '，未完成'}。'
              '\n报告：$reportPath'
              '${samplePath != null ? '\n截图样本：$samplePath' : ''}';
      if (mounted) {
        setState(() => _statusMessage = summary);
      }
      if (wasAnimating && _frameAnimationController != null) {
        _frameAnimationController!.forward();
      }
      _isDecodeTesting = false;
    }
    return summary;
  }

  // --- Encoding flow ---

  Future<void> _startEncoding() async {
    if (_compressedData == null || _encoder == null || _isEncoding) return;
    _isEncoding = true; // synchronous guard against double-click

    setState(() {
      _statusMessage = '正在将数据编码为 cimbar 帧…';
    });

    try {
      _frames = await _encoder!.encodeData(
        _compressedData!,
        filename: 'screenshot.avif',
      );

      if (_frames.isEmpty) {
        _statusMessage = '编码未生成任何帧。';
        setState(() => _isEncoding = false);
        return;
      }

      // Decode RGB frames to ui.Image for display
      _statusMessage = '正在生成 ${_frames.length} 帧显示图像…';
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
          '已生成 ${_frames.length} 帧 cimbar 条码，正在播放…';

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
      _statusMessage = '编码出错：$e';
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
      _statusMessage = '已停止。';
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

  /// Chinese description of each barcode mode, shown in the mode menu.
  String _modeDescription(CimbarMode mode) => switch (mode) {
        CimbarMode.mode4C => '16x16 网格，兼容性最好',
        CimbarMode.modeB => '24x24 网格，彩色大容量（默认）',
        CimbarMode.modeBm => '24x24 网格，黑白单色，适合暗环境',
        CimbarMode.modeBu => '24x24 网格，B 模式变体',
      };

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
                  child: RepaintBoundary(
                    key: _displayBoundaryKey,
                    child: _frames.isNotEmpty
                        ? _buildFrameDisplay()
                        : _buildPlaceholder(),
                  ),
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
                                  ? '窗口模式'
                                  : '覆盖任务栏（铺满屏幕）',
                              onPressed: _toggleCoverTaskbar,
                            ),
                            _WindowButton(
                              icon: Icons.remove,
                              tooltip: '最小化',
                              onPressed: () => windowManager.minimize(),
                            ),
                            _WindowButton(
                              icon: Icons.close,
                              tooltip: '关闭',
                              onPressed: () => windowManager.close(),
                              isClose: true,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        PopupMenuButton<CimbarMode>(
                          tooltip: '选择条码模式',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.settings, size: 18),
                              const SizedBox(width: 6),
                              Text('模式 ${_config.mode.name}'),
                            ],
                          ),
                          onSelected: (mode) async {
                            _config = _config.copyWith(mode: mode);
                            await _encoder?.configure(_config);
                          },
                          itemBuilder: (_) => CimbarMode.values
                              .map((m) => PopupMenuItem(
                                    value: m,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(m.name,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600)),
                                        Text(
                                          _modeDescription(m),
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: 0.7)),
                                        ),
                                      ],
                                    ),
                                  ))
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
                                  ? '解码器已连接'
                                  : '解码器未连接',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        // Latest report pushed by the decoder (phone): the
                        // verdict + the one thing to do about it.
                        if (_lastReport != null) ...[
                          const SizedBox(height: 8),
                          _reportCard(_lastReport!),
                        ],
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
                              ? '截取中…'
                              : '截取屏幕 (Alt+A)'),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _compressedData != null && !_isEncoding
                              ? _startEncoding
                              : null,
                          icon: const Icon(Icons.qr_code, size: 18),
                          label: const Text('编码并显示'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _isReady ? _useTestPayload : null,
                          icon: const Icon(Icons.science, size: 18),
                          label: const Text('测试数据 (200KB)'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _saveDebugScreenshot,
                          icon: const Icon(Icons.bug_report, size: 18),
                          label: const Text('调试截图 (Alt+S)'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed:
                              _frames.isNotEmpty ? _checkBarcodeQuality : null,
                          icon: const Icon(Icons.high_quality, size: 18),
                          label: const Text('质量检查 (Alt+Q)'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _frames.isNotEmpty && !_isDecodeTesting
                              ? _runDecodeTest
                              : null,
                          icon: const Icon(Icons.fact_check, size: 18),
                          label: Text(_isDecodeTesting
                              ? '测试中…'
                              : '解码自检 (Alt+D)'),
                        ),
                        if (_frames.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _stopEncoding,
                            icon: const Icon(Icons.stop, size: 18),
                            label: const Text('停止'),
                          ),
                        ],
                        const SizedBox(height: 20),
                        if (_compressedData != null) ...[
                          _infoRow(
                              '截图尺寸', '${_capturedWidth}x$_capturedHeight'),
                          const SizedBox(height: 6),
                          _infoRow('压缩后大小',
                              '${((_compressedData?.length ?? 0) / 1024).toStringAsFixed(1)} KB'),
                          const SizedBox(height: 6),
                          _infoRow('模式', _config.mode.name),
                          const SizedBox(height: 6),
                          _fpsControl(),
                          const SizedBox(height: 6),
                          _infoRow('帧数', '${_frames.length}'),
                        ],
                        const Spacer(),
                        if (_frames.isNotEmpty)
                          Text(
                            '第 ${_currentFrameIndex + 1} / ${_frames.length} 帧',
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
            '按 Alt+A 或点击「截取屏幕」\n框选要编码的屏幕区域',
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
              Text('显示帧率',
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
