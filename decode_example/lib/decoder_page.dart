import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show SystemChrome, SystemUiMode;
import 'package:libcimbar/libcimbar.dart';
// ignore: implementation_imports
import 'package:libcimbar/src/native/wasm_diagnostics_stub.dart'
    if (dart.library.js_interop) 'package:libcimbar/src/web/libcimbar_js_interop.dart';

/// Camera resolution requested on startup, following the official Android
/// decoder (cfc): its `bestCameraFrameSize` only accepts preview sizes
/// whose short edge is in [960, 1080], because the decoder needs no more
/// than ~1080p — the Scanner searches the full frame for anchors and the
/// Deskewer's homography normalises the barcode to its fixed size. Both
/// the web capture (getUserMedia `ideal`) and the Android capture
/// (cfc picks its own preview size) treat this as a request, not a
/// guarantee.
const int kPreferredCameraWidth = 1920;
const int kPreferredCameraHeight = 1080;

/// Camera frames fed to the decoder per second.
///
/// 15 matches the official receivers: recv.js asks getUserMedia for
/// `frameRate: {ideal: 15}` and schedules per video frame; cfc decodes
/// every camera frame it is handed. Fountain assembly throughput scales
/// (roughly) linearly with good frames per second, so sampling at 5 fps
/// made transfers take 3x as long as the official apps.
///
/// This is a REQUEST, not a guarantee: the captures have backpressure —
/// web drops ticks while busy; Android (cfc-verbatim) forwards every
/// camera frame and the newest-wins slot drops whatever the decoder
/// cannot keep up with — so the effective rate settles at whatever the
/// decoder can sustain.
const int kCaptureFps = 15;

/// Decoder page — receive cimbar barcodes via camera and decode them.
///
/// Minimal, official-style flow: scan → decode → save.
///
/// Supported platforms:
/// - **Android**: Uses the device camera via the cfc viewfinder port
///   (Camera1 + SurfaceTexture preview — no camera plugin)
/// - **Web (WASM)**: Uses getUserMedia for camera access
///
/// The decoder processes each camera frame, feeding it into the
/// fountain decoder until the complete file is recovered, then saves it
/// (download on web / app documents directory on Android).
class DecoderPage extends StatefulWidget {
  const DecoderPage({super.key});

  @override
  State<DecoderPage> createState() => _DecoderPageState();
}

class _DecoderPageState extends State<DecoderPage> with WidgetsBindingObserver {
  // ─── State ────────────────────────────────────────────────────

  final CimbarPlatform _platform = CimbarPlatform.instance;

  ICimbarDecoder? _decoder;
  ICameraCapture? _camera;

  bool _isReady = false;
  bool _isDecoding = false;
  bool _isCameraActive = false;
  String _statusMessage = '正在初始化解码器…';
  double _progress = 0.0;

  CimbarConfig _config = const CimbarConfig(
    mode: CimbarMode.modeB,
    compressionLevel: 16,
    // Official default (recv.html / cfc): Auto — rotate [66,68,67,4] per
    // frame and lock on the first frame that yields payload.
    autoDetect: true,
  );

  /// Mode the Auto rotation locked onto (recv.js setMode / cfc
  /// detected_mode). Null while still rotating.
  int? _detectedMode;

  // Decode result
  Uint8List? _recoveredData;
  String _recoveredFilename = '';
  String _savedTo = '';

  // Frame counter
  int _framesProcessed = 0;

  // ─── Transfer health (cfc's drawGuidance status machine) ─────────
  //
  // The official Android decoder colors its guide brackets by whether the
  // last ~32-frame window saw progress: white = nothing decoding, light
  // blue = some frames yield payload, green = payload AND high-quality
  // frames are both flowing. (jni.cpp: _transferStatus, drawGuidance.)
  int _callCount = 0; // every frame handed to the decoder (cfc `_calls`)
  int _decodedFrames = 0; // frames that yielded fountain payload (`decoded`)
  int _perfectFrames = 0; // payload >= 70% of frame capacity (`perfect`)
  int _frameDecodeSnapshot = 0;
  int _frameSuccessSnapshot = 0;

  /// 0 = idle (white), 1 = payload flowing (light blue), 2 = healthy (green).
  int _transferStatus = 0;

  /// Aspect ratio (long side / short side, always >= 1) of the frame the
  /// camera actually delivers. The viewfinder window follows it so the
  /// whole captured frame stays visible — the field of view is then as
  /// wide as the sensor allows instead of being cropped twice (once by the
  /// capture, once by a hard-coded window shape).
  double get _captureAspect {
    // What the DECODER receives (after the 4:3 trim on Android), not the
    // raw capture size — the window must show exactly the scanned area.
    try {
      final cam = _camera;
      if (cam != null) {
        final a = (cam as dynamic).decodedAspect as double?;
        if (a != null && a > 0) return a;
      }
    } catch (_) {}
    return 4 / 3; // cfc's window shape, before the real size is known
  }

  /// Guide color, mirroring cfc's drawGuidance() as it actually renders:
  /// cfc draws on an **RGBA** Mat (frame.rgba()), so its cv::Scalar is
  /// interpreted in R,G,B order — Scalar(255,244,94) shows as YELLOW, not
  /// the sky-blue a BGR reading would suggest.
  /// - white — no decode activity in the last window (bad/error frames
  ///   don't count, so a misaligned camera settles back to white)
  /// - yellow — partial decode: only one of decoded/perfect grew
  /// - green — decoded AND perfect frames are both accumulating
  Color get _guideColor => switch (_transferStatus) {
        2 => const Color(0xFF00FF00),
        1 => const Color(0xFFFFF45E),
        _ => Colors.white,
      };

  /// Human-readable transfer health, cfc's `#: perfect / decoded / scanned`
  /// line condensed for the status strip.
  String get _healthLine =>
      '$_perfectFrames 完美/$_decodedFrames 有效/$_callCount 帧';

  // Consecutive fatal WASM traps (corrupted/exhausted heap).
  int _fatalWasmErrors = 0;

  /// WASM traps (memory corruption / OOM) are unrecoverable within this
  /// page: the Module instance SURVIVES Flutter hot restarts, so only a full
  /// browser reload creates a fresh heap. Detect them, stop hammering the
  /// dead runtime, and tell the user exactly what to do.
  bool _noteFatalWasmError(Object e) {
    final s = e.toString();
    if (!s.contains('memory access out of bounds') &&
        !s.contains('WASM malloc')) {
      return false;
    }
    _fatalWasmErrors++;
    if (_fatalWasmErrors >= 3) {
      if (_isCameraActive) unawaited(_stopCamera());
      _statusMessage = 'WASM 内存损坏/耗尽（已捕获 $_fatalWasmErrors 次）— 请强制刷新浏览器'
          '页面（Ctrl+Shift+R）。Flutter 热重启不会重建 WASM 实例，'
          '只有刷新页面才能恢复。';
    } else {
      _statusMessage = 'WASM 异常 #$_fatalWasmErrors：$s';
    }
    if (mounted) setState(() {});
    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      // WASM is a web-only concern. Android talks to the same native C++
      // core as desktop — via FFI into libcimbar_jni.so — so waiting on the
      // WASM runtime here would just fail with "WASM module failed to load"
      // on a platform that never needed it.
      if (kIsWeb) {
        debugPrint('[Decoder] Waiting for WASM module...');
        setState(() {
          _statusMessage = '正在等待 WASM 模块初始化…';
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
            _statusMessage = 'WASM 模块初始化失败。\n\n${wasmDiag.toReport()}';
          });
          return;
        }

        debugPrint(
            '[Decoder] WASM ready (${wasmDiag.waitDuration?.inMilliseconds}ms). Creating decoder...');
      } else {
        setState(() => _statusMessage = '正在初始化原生解码库…');
      }

      _decoder = await _platform.createDecoder();
      await _decoder!.configure(_config);

      setState(() {
        _isReady = _decoder!.isReady;
        _statusMessage = _isReady
            ? '解码器就绪。启动摄像头开始扫描。'
            : '解码器已创建但未就绪。\n\n${_getDiagnostics()}';
      });

      // Try to initialize camera
      try {
        _camera = await _platform.createCameraCapture();
      } catch (e) {
        debugPrint('Camera init failed: $e');
      }

      // E2E/headless test hook: ?autostart=1 begins scanning as soon as
      // everything is ready, without needing to tap 启动摄像头 (Flutter's
      // canvas UI is awkward to drive from browser automation).
      if (kIsWeb && Uri.base.queryParameters.containsKey('autostart')) {
        debugPrint('[Decoder] autostart hook: starting camera');
        await _startCamera();
      }
    } catch (e) {
      debugPrint('[Decoder] Initialization error: $e');
      setState(() {
        _statusMessage = '初始化出错：$e';
      });
    }
  }

  /// Diagnostics for whichever backend this platform actually uses:
  /// WASM on web, the native shared library everywhere else.
  String _getDiagnostics() {
    if (kIsWeb) {
      try {
        return checkWasmDiagnostics().toReport();
      } catch (_) {
        return 'WASM module not available.';
      }
    }
    // Android/desktop load the same C++ core via FFI; probing WASM here
    // would report a failure that is irrelevant (and misleading) on these
    // platforms, so report the native state instead.
    final lib = Platform.isAndroid
        ? 'libcimbar_jni.so'
        : Platform.isWindows
            ? 'libcimbar.dll'
            : Platform.isMacOS
                ? 'libcimbar.dylib'
                : 'libcimbar.so';
    return '原生解码库：$lib\n'
        'isReady：${_decoder?.isReady}\n'
        'mode：${_config.mode.name}';
  }

  // ─── Camera flow ──────────────────────────────────────────────

  Future<void> _startCamera() async {
    if (_camera == null || !_isReady || _isDecoding) return;

    // Immersive mode: hide the system bars so the viewfinder gets the
    // entire display while scanning (no-op on web).
    if (!kIsWeb) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    setState(() {
      _isCameraActive = true;
      _isDecoding = true;
      _statusMessage = '摄像头已开启，请对准 cimbar 条码…';
      _detectedMode = null;
      _framesProcessed = 0;
      _callCount = 0;
      _decodedFrames = 0;
      _perfectFrames = 0;
      _frameDecodeSnapshot = 0;
      _frameSuccessSnapshot = 0;
      _transferStatus = 0;
    });

    // Fresh fountain state: drop streams possibly poisoned by earlier
    // corrupt chunks so a clean scan session can actually complete.
    try {
      await (_decoder as dynamic).resetStreams();
    } catch (_) {}

    // Fixed 1080p-class request, per the official Android decoder (cfc):
    // the full frame goes to the decoder at (at most) 1080p short edge —
    // no cropping, no mode-dependent framing. The Scanner searches the
    // whole frame for the 4 corner anchors and the Deskewer normalises
    // whatever it finds, so a bigger/cropped input buys nothing.
    try {
      await _camera!.start(
        preferredWidth: kPreferredCameraWidth,
        preferredHeight: kPreferredCameraHeight,
        frameIntervalMs: (1000 / kCaptureFps).round(),
      );
    } catch (e) {
      // Without this the exception escapes, the state stays "active" and
      // every frame-dependent control is left grey with no explanation.
      // The dominant cause on a phone is insecure origin: getUserMedia is
      // only allowed on HTTPS or localhost, so http://<lan-ip>:8080
      // silently refuses the camera.
      if (mounted) {
        setState(() {
          _isCameraActive = false;
          _isDecoding = false;
          _statusMessage = _cameraStartError(e);
        });
      }
      return;
    }

    _camera!.onFrame((frame) {
      _processCameraFrame(frame);
    });
    // Baseline for the orientation-change restart (see didChangeMetrics).
    if (mounted) {
      _lastOrientation = MediaQuery.of(context).orientation;
    }
  }

  /// Explain why the camera could not start, with the insecure-origin case
  /// called out explicitly because it is by far the most common on phones.
  String _cameraStartError(Object e) {
    if (kIsWeb) {
      final scheme = Uri.base.scheme.toLowerCase();
      final host = Uri.base.host.toLowerCase();
      final isLocalhost = host == 'localhost' || host == '127.0.0.1';
      if (scheme != 'https' && !isLocalhost) {
        return '浏览器拒绝了摄像头：当前页面来源不安全'
            '（$scheme://$host）。\n'
            'getUserMedia（摄像头）仅在 HTTPS 或 localhost 下可用，'
            '用 http://$host 访问时会被静默拒绝。\n'
            '解决办法（任选一）：\n'
            '  1) USB 连电脑执行 adb reverse tcp:8080 tcp:8080，'
            '然后手机访问 http://localhost:8080\n'
            '  2) 改用 HTTPS 访问';
      }
    }
    return '摄像头启动失败：$e';
  }

  Future<void> _stopCamera() async {
    await _camera?.stop();
    if (!kIsWeb) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    setState(() {
      _isCameraActive = false;
      _isDecoding = false;
      _statusMessage = '摄像头已停止。';
    });
  }

  // ─── Orientation-change camera restart ────────────────────────
  //
  // The capture orientation is fixed when the camera controller is
  // created. Rotating the phone mid-scan (orientation follows the device,
  // unlike cfc's locked landscape) would otherwise leave the preview in
  // the old orientation — a portrait image letterboxed into a landscape
  // screen. Restart the capture so it re-targets the new display
  // rotation; the decoder's fountain state is untouched by this.
  Orientation? _lastOrientation;
  bool _restartingCamera = false;

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!_isCameraActive || _restartingCamera || !mounted) return;
    final orientation = MediaQuery.of(context).orientation;
    if (_lastOrientation == null) {
      _lastOrientation = orientation;
      return;
    }
    if (orientation != _lastOrientation) {
      _lastOrientation = orientation;
      unawaited(_restartCameraForOrientation());
    }
  }

  Future<void> _restartCameraForOrientation() async {
    _restartingCamera = true;
    try {
      await _camera?.dispose();
      _camera = await _platform.createCameraCapture();
      await _camera!.start(
        preferredWidth: kPreferredCameraWidth,
        preferredHeight: kPreferredCameraHeight,
        frameIntervalMs: (1000 / kCaptureFps).round(),
      );
      _camera!.onFrame((frame) => _processCameraFrame(frame));
      if (mounted) setState(() {});
      debugPrint('[Decoder] camera restarted after orientation change');
    } catch (e) {
      debugPrint('[Decoder] camera restart after rotation failed: $e');
    } finally {
      _restartingCamera = false;
    }
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

      // cfc guidance status machine: count decoded/perfect frames, then
      // every 32 frames compare against the last snapshot. Green requires
      // BOTH counters to have grown in the window (stable transfer); light
      // blue means at least payload is trickling through; white means the
      // decoder saw nothing usable for ~2 seconds.
      _callCount++;
      final frameBytes = result.frameBytesDecoded;
      final frameCapacity = result.frameCapacity;
      if (frameBytes > 0) _decodedFrames++;
      if (frameCapacity > 0 && frameBytes >= frameCapacity * 0.7) {
        _perfectFrames++;
      }
      if ((_callCount & 31) == 1) {
        _transferStatus = (_perfectFrames > _frameSuccessSnapshot ? 1 : 0) +
            (_decodedFrames > _frameDecodeSnapshot ? 1 : 0);
        _frameDecodeSnapshot = _decodedFrames;
        _frameSuccessSnapshot = _perfectFrames;
      }

      _progress = result.progress;
      final detected = result.detectedMode;
      if (detected != null) _detectedMode = detected;

      if (result.isComplete) {
        _recoveredData = result.data;
        _recoveredFilename = result.filename;
        _statusMessage =
            '文件已恢复："${result.filename}"（${result.data?.length ?? 0} 字节）';
        await _stopCamera();
        await _saveFile();
      } else {
        // Error frames get NO message: like cfc, a frame that fails to
        // decode (anchors not found, fountain rejects) simply doesn't
        // count — the white guide color is the feedback. Flashing an
        // error per frame was noise: scan_extract_decode returns -3 on
        // every frame while the camera is merely not pointed at a code.
        _statusMessage = '解码中… ${(result.progress * 100).toStringAsFixed(1)}%'
            '（$_healthLine）';
      }

      setState(() {});
    } catch (e, stack) {
      if (_noteFatalWasmError(e)) return;
      debugPrint('Frame decode error: $e');
      debugPrint('Frame decode stack:\n$stack');
      debugPrint('Frame info: ${frame.width}x${frame.height}, '
          'format=${frame.format}, data=${frame.data.length} bytes');
      // Keep the UI in sync: the frame exists, so surface that it failed
      // instead of leaving the status and controls stale.
      if (mounted) setState(() => _statusMessage = '帧解码异常：$e');
    }
  }

  // ─── Save recovered file ──────────────────────────────────────

  /// Save the recovered file: browser download on web, app documents
  /// directory on Android (via the libcimbar package helper).
  Future<void> _saveFile() async {
    if (_recoveredData == null) return;

    try {
      final filename =
          _recoveredFilename.isNotEmpty ? _recoveredFilename : 'decoded.bin';
      final target = await saveRecoveredFile(_recoveredData!, filename);
      setState(() {
        _savedTo = target;
        _statusMessage = '文件已保存到：$target';
      });
    } catch (e) {
      setState(() {
        _statusMessage = '保存出错：$e';
      });
    }
  }

  /// Chinese description of each barcode mode, shown in the mode menu.
  String _modeDescription(CimbarMode mode) => switch (mode) {
        CimbarMode.mode4C => '16x16 网格，兼容性最好',
        CimbarMode.modeB => '24x24 网格，彩色大容量（默认）',
        CimbarMode.modeBm => '24x24 网格，黑白单色，适合暗环境',
        CimbarMode.modeBu => '24x24 网格，B 模式变体',
      };

  // ─── UI ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Scanning is full-screen (no app bar) so the viewfinder gets almost
      // the entire display, like a QR scanner app.
      appBar: _isCameraActive ? null : _buildAppBar(),
      body: SafeArea(
        child: _isCameraActive ? _buildScanningLayout() : _buildIdleLayout(),
      ),
    );
  }

  /// Chip/menu label — recv.html semantics: Auto until a mode locks, then
  /// "Auto → <detected>"; a manual selection shows the mode outright.
  String get _modeLabel {
    if (!_config.autoDetect) return _config.mode.name;
    if (_detectedMode != null) {
      return 'Auto → ${CimbarMode.fromValue(_detectedMode!).name}';
    }
    return 'Auto（检测中）';
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: const Text('libcimbar 解码器'),
      actions: [
        // Mode selector — recv.html's Auto + per-mode entries.
        PopupMenuButton<Object>(
          icon: const Icon(Icons.settings),
          tooltip: '条码模式',
          onSelected: (sel) async {
            setState(() {
              _detectedMode = null;
              if (sel is CimbarMode) {
                _config = _config.copyWith(mode: sel, autoDetect: false);
              } else {
                // Official Auto: rotate [66,68,67,4], lock on first payload.
                _config = _config.copyWith(autoDetect: true);
              }
            });
            await _decoder?.configure(_config);
          },
          itemBuilder: (_) => [
            PopupMenuItem<Object>(
              value: 'auto',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Auto（官方默认）',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '每帧轮换 66/68/67/4，命中即锁定',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7)),
                  ),
                ],
              ),
            ),
            ...CimbarMode.values.map((m) => PopupMenuItem<Object>(
                  value: m,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.name,
                          style:
                              const TextStyle(fontWeight: FontWeight.w600)),
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
                )),
          ],
        ),
      ],
    );
  }

  /// Idle control panel: settings and buttons in a scrollable column so
  /// narrow phone screens never squeeze them (the viewfinder gets the whole
  /// screen while scanning — see [_buildScanningLayout]).
  Widget _buildIdleLayout() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
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
                      // between short progress lines and long diagnostics;
                      // a variable-height text box would make the whole
                      // layout jump around while decoding.
                      Expanded(
                        child: SizedBox(
                          height: 72,
                          child: SingleChildScrollView(
                            child: SelectableText(_statusMessage),
                          ),
                        ),
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
                        label: Text('模式：$_modeLabel'),
                      ),
                      if (_framesProcessed > 0)
                        Chip(
                          avatar: const Icon(Icons.photo_camera, size: 16),
                          label: Text('$_framesProcessed 帧'),
                        ),
                      if (_recoveredData != null)
                        Chip(
                          avatar: const Icon(Icons.check_circle, size: 16),
                          label: Text(
                            _recoveredFilename.isNotEmpty
                                ? _recoveredFilename
                                : '已恢复',
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
                      '已处理 $_framesProcessed 帧',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Camera controls
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isReady && !_isCameraActive ? _startCamera : null,
                  icon: const Icon(Icons.videocam),
                  label: const Text('启动摄像头'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isCameraActive ? _stopCamera : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('停止'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Preview placeholder: fixed height here; the whole screen is
          // used by the preview while scanning.
          SizedBox(height: 220, child: _buildCameraPreview()),

          // Recovered file info
          if (_recoveredData != null) ...[
            const SizedBox(height: 12),
            _buildResultPanel(),
          ],
        ],
      ),
    );
  }

  /// Full-screen scanning layout: the camera viewfinder fills the entire
  /// screen with the cfc-style 4:3 window overlay, a floating status strip
  /// on top, and a compact stop button at the bottom-right corner (the
  /// spot cfc uses for its mode toggle).
  Widget _buildScanningLayout() {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildCameraPreview(fullBleed: true),
        _buildScanningStatusBar(),
        _buildScanningControls(),
      ],
    );
  }

  /// Floating status strip over the viewfinder (message + progress).
  Widget _buildScanningStatusBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        color: Colors.black.withValues(alpha: 0.55),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _isReady ? Icons.check_circle : Icons.error,
                  size: 16,
                  color: _isReady ? Colors.greenAccent : Colors.redAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusMessage,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
            if (_progress > 0 && _progress < 1.0) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 6,
                  color: _guideColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${(_progress * 100).toStringAsFixed(1)}% — $_healthLine',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Compact stop control at the bottom-right corner — the position cfc
  /// uses for its mode toggle. A full-width bottom bar would cover the
  /// bottom of the 4:3 decode window (where the barcode's bottom anchors
  /// live), so the button stays small and out of the window.
  Widget _buildScanningControls() {
    return Positioned(
      right: 16,
      bottom: 16,
      child: GestureDetector(
        onTap: _stopCamera,
        child: Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white24),
          ),
          child: const Icon(Icons.stop_rounded, color: Colors.white70, size: 30),
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

  /// The Flutter texture id of the CfcCameraCapture preview (Android),
  /// or null when another capture backend is active.
  int? get _cfcTextureId {
    try {
      final id = (_camera as dynamic).textureId as int?;
      return (id != null && id >= 0) ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// Rotation the cfc capture reported for the current display.
  int get _cfcRotation {
    try {
      return ((_camera as dynamic).rotation as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// [fullBleed] renders the preview edge-to-edge (scanning layout);
  /// otherwise it is clipped into the idle layout's preview card.
  Widget _buildCameraPreview({bool fullBleed = false}) {
    final vType = _cameraViewType;
    if (_isCameraActive && vType != null) {
      // Show camera preview with scanning frame overlay
      final stack = Stack(
        fit: StackFit.expand,
        children: [
          // Camera video stream
          HtmlElementView(viewType: vType),
          // Scanning frame overlay
          _buildScanningOverlay(),
        ],
      );
      if (fullBleed) return stack;
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: stack,
      );
    }

    // CfcCameraCapture (Android): preview via a Flutter texture fed by the
    // camera's SurfaceTexture. The texture content is the sensor-direction
    // 4:3 frame; RotatedBox orients it for the current display, exactly
    // like cfc's frameRotation. If the preview texture is not available
    // (no permission / camera error) the "scanning blind" card below shows.
    final cfcId = _cfcTextureId;
    if (_isCameraActive && cfcId != null) {
      final portrait =
          MediaQuery.of(context).size.height >= MediaQuery.of(context).size.width;
      final displayAspect = portrait ? 1 / _captureAspect : _captureAspect;
      final stack = Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          Center(
            child: AspectRatio(
              aspectRatio: displayAspect,
              child: RotatedBox(
                quarterTurns: (_cfcRotation ~/ 90) % 4,
                child: Texture(textureId: cfcId),
              ),
            ),
          ),
          _buildScanningOverlay(),
        ],
      );
      if (fullBleed) return stack;
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: stack,
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
                '正在扫描 cimbar 条码…\n'
                '请让完整条码（四个角）都在画面内',
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
              '启动摄像头以扫描 cimbar 条码',
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

  /// Scanning overlay with cfc's EXACT window geometry (measured against
  /// a real cfc screenshot): a 4:3 window filling the view's short side,
  /// centered, with OPAQUE black letterbox bars on the remaining sides;
  /// guidance brackets at the WINDOW corners in cfc's drawGuidance
  /// proportions (black outline under the white/yellow/green state
  /// color); hint text at the window's bottom edge.
  ///
  /// The Scanner still searches the FULL camera frame — the bars are
  /// presentation only, exactly like cfc (whose OpenCV mScale letterbox
  /// affects drawing, never the decode input). A barcode just outside
  /// the window still decodes.
  Widget _buildScanningOverlay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // The window tracks the CAMERA's frame aspect (whatever the device
        // actually delivers after the top/bottom trim), filling the view's
        // short side and centred — cfc's mScale rule, generalised. Showing
        // the whole captured frame is what makes the field of view as
        // large as the sensor allows; a fixed 4:3 window over a wider
        // capture would silently hide the left/right margins.
        final camAspect = _captureAspect; // >= 1, long side / short side
        final s = size.shortestSide;
        final portrait = size.height >= size.width;
        final frameW = portrait ? s : s * camAspect;
        final frameH = portrait ? s * camAspect : s;
        final mScale = math.min(size.width / frameW, size.height / frameH);
        final drawW = frameW * mScale;
        final drawH = frameH * mScale;
        final window = Rect.fromLTWH(
          (size.width - drawW) / 2,
          (size.height - drawH) / 2,
          drawW,
          drawH,
        );

        return Stack(
          children: [
            // Opaque black outside the window — cfc's bars are pure black
            // (nothing is drawn there at all), which is what makes the
            // window read as crisp and full-size.
            CustomPaint(
              size: size,
              painter: _DarkOverlayPainter(frameRect: window),
            ),
            // Guidance brackets at the WINDOW corners, cfc drawGuidance
            // proportions, black outline under the status color.
            CustomPaint(
              size: size,
              painter: _CornerBracketsPainter(
                frameRect: window,
                color: _guideColor,
              ),
            ),
            // Hint at the bottom edge of the window, colored by state.
            Positioned(
              left: window.left,
              width: window.width,
              bottom: size.height - window.bottom + 14,
              child: Text(
                '对准 cimbar 条码（四个角都可见）',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: _guideColor.withValues(alpha: 0.9),
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
                  '文件已恢复',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('文件名：$_recoveredFilename'),
            Text('大小：${_recoveredData!.length} 字节'),
            Text('帧数：$_framesProcessed'),
            if (_savedTo.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '保存位置：$_savedTo',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _saveFile,
              icon: const Icon(Icons.save),
              label: const Text('再次保存'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    _decoder?.dispose();
    super.dispose();
  }
}

// ─── Scanning frame painters ────────────────────────────────────

/// Opaque black outside the 4:3 window, square corners — a pixel-for-
/// pixel match of cfc's OpenCV letterbox bars (pure black, sharp edges).
/// The dimmed regions still go to the Scanner; only the eye is guided.
class _DarkOverlayPainter extends CustomPainter {
  final Rect frameRect;

  _DarkOverlayPainter({required this.frameRect});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black;
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(frameRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_DarkOverlayPainter old) =>
      old.frameRect != frameRect;
}

/// Guidance brackets at the four corners of the 4:3 window, in cfc's
/// drawGuidance proportions (jni.cpp): with `minsz` the window's short
/// side,
///   stroke   = minsz >> 7      (~8px at 1080)
///   outline  = stroke + minsz >> 8
///   length   = stroke << 3     (~68px)
///   offset   = minsz >> 5      (~34px inside the window corner)
/// A black outline is drawn under the status color (white / yellow /
/// green) so the brackets stay visible over bright camera content.
class _CornerBracketsPainter extends CustomPainter {
  final Rect frameRect;
  final Color color;

  _CornerBracketsPainter({
    required this.frameRect,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final minsz = math.min(frameRect.width, frameRect.height);
    final guideWidth = (minsz / 128).clamp(5.0, 14.0);
    final outlineWidth = guideWidth + (minsz / 256).clamp(3.0, 10.0);
    final guideLength = guideWidth * 8;
    final guideOffset = (minsz / 32).clamp(20.0, 60.0);

    final outlinePaint = Paint()
      ..color = Colors.black
      ..strokeWidth = outlineWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    final colorPaint = Paint()
      ..color = color
      ..strokeWidth = guideWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;

    // Corner anchors, inset from the window corners (cfc guideOffset).
    final cx = frameRect.center.dx;
    final cy = frameRect.center.dy;
    final anchors = [
      Offset(frameRect.left + guideOffset, frameRect.top + guideOffset),
      Offset(frameRect.right - guideOffset, frameRect.top + guideOffset),
      Offset(frameRect.left + guideOffset, frameRect.bottom - guideOffset),
      Offset(frameRect.right - guideOffset, frameRect.bottom - guideOffset),
    ];

    for (final a in anchors) {
      // Horizontal + vertical arm along the window edges (inward).
      final h = Offset(
          a.dx + (a.dx < cx ? guideLength : -guideLength), a.dy);
      final v = Offset(
          a.dx, a.dy + (a.dy < cy ? guideLength : -guideLength));
      canvas.drawLine(a, h, outlinePaint);
      canvas.drawLine(a, v, outlinePaint);
      canvas.drawLine(a, h, colorPaint);
      canvas.drawLine(a, v, colorPaint);
    }
  }

  @override
  bool shouldRepaint(_CornerBracketsPainter old) =>
      old.frameRect != frameRect || old.color != color;
}
