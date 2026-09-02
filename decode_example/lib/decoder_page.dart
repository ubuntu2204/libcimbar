import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, SystemChrome, SystemUiMode;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:libcimbar/libcimbar.dart';
// ignore: implementation_imports
import 'package:libcimbar/src/native/wasm_diagnostics_stub.dart'
    if (dart.library.js_interop) 'package:libcimbar/src/web/libcimbar_js_interop.dart';
// ignore: implementation_imports
import 'native/web_file_download_stub.dart'
    if (dart.library.js_interop) 'web/web_file_download_web.dart';
import 'package:path_provider/path_provider.dart';

import 'dart:ui' as ui;

/// A camera resolution preset requested from getUserMedia (`ideal`).
///
/// The browser picks the closest supported mode, so asking for the highest
/// value is safe — it simply falls back to whatever the device offers.
class _ResolutionPreset {
  final String label;
  final int width;
  final int height;
  const _ResolutionPreset(this.label, this.width, this.height);

  @override
  String toString() => '$label ($width×$height)';
}

/// Camera resolution presets, lowest to highest.
const List<_ResolutionPreset> _resolutions = [
  _ResolutionPreset('1080p', 1920, 1080),
  _ResolutionPreset('2K', 2560, 1440),
  _ResolutionPreset('4K', 3840, 2160),
  _ResolutionPreset('Max 4K+', 4096, 3072),
];

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
  String _statusMessage = '正在初始化解码器…';
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

  // Requested camera resolution. A barcode photographed from across the room
  // only fills a fraction of the view, so the raw camera frame must be much
  // larger than the barcode's native 1024 px — otherwise the anchor scan
  // cannot resolve it (it reports 2-3 of 4 anchors).
  int _resolutionIndex = 3; // default: Max (4K+)

  // Selected capture framing. Persists across the session so a user who
  // switches to centerCrop (for a larger barcode) can toggle back without
  // re-picking the mode every capture cycle.
  // Default: centerCrop — on a portrait phone frame it keeps the barcode at
  // ~1650px inside the 2048 decoder input versus fit's ~940px, and shrinks by
  // only ~0.94x instead of ~0.53x, so the cell grid survives resampling.
  // Switch to 'fit' in the dropdown when hand-held and the subject may drift
  // off-centre (centerCrop drops anything outside the centre square).
  String _captureModeName = 'centerCrop';

  /// Trim the wasted background (black bars, wall, desk) around the barcode
  /// before decoding. Preserves the aspect ratio — the crop is only scaled up
  /// and centred, never stretched. Turn off if the scene contains other
  /// strongly coloured objects that confuse the bounding-box scan.
  bool _autoCropEnabled = true;

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
  // Default points at the encoder machine's VPN/tailnet address, which the
  // phone can reach from anywhere on that network. Switch to 127.0.0.1 only
  // when encoder and decoder run on the SAME machine.
  final TextEditingController _debugUrlCtrl =
      TextEditingController(text: 'http://100.65.70.11:8765');
  Timer? _remoteTimer;
  bool _remotePolling = false;
  bool _remoteBusy = false;
  int _remoteFrames = 0;

  // Encoder-side state fetched over the debug link (for reports/negotiation).
  Map<String, dynamic>? _lastEncoderStatus;
  String _lastSyncResult = '（未尝试）';

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
      _remoteTimer?.cancel();
      _remoteTimer = null;
      _remotePolling = false;
      if (_isCameraActive) unawaited(_stopCamera());
      _statusMessage = 'WASM 内存损坏/耗尽（已捕获 $_fatalWasmErrors 次）— 请强制刷新浏览器'
          '页面（Ctrl+Shift+R）。Flutter 热重启不会重建 WASM 实例，'
          '只有刷新页面才能恢复。';
    } else {
      _statusMessage = 'WASM 异常 #$_fatalWasmErrors：$s';
    }
    _lastFrameError = _statusMessage;
    if (mounted) setState(() {});
    return true;
  }

  // Negotiation light: null = not attempted, true = negotiated OK (green),
  // false = unreachable / unresolved mismatch (red).
  bool? _linkOk;

  // Outcome of the Pull+Decode ground-truth test (pristine frames over LAN,
  // no camera). Recorded separately from camera errors so the report can
  // state definitively whether the decode pipeline itself is healthy.
  String _lastRemoteResult = '（未运行 - 点击「拉取解码」）';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
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
    } catch (e) {
      debugPrint('[Decoder] Initialization error: $e');
      setState(() {
        _statusMessage = '初始化出错：$e';
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

    // Immersive mode: hide the system bars so the viewfinder gets the
    // entire display while scanning (no-op on web).
    if (!kIsWeb) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    setState(() {
      _isCameraActive = true;
      _isDecoding = true;
      _statusMessage = '摄像头已开启，请对准 cimbar 条码…';
      _framesProcessed = 0;
    });

    // Best-effort negotiation: align decode mode with the encoder before
    // scanning (a silent mode mismatch fails every frame with -3).
    if (_debugBaseUrl.isNotEmpty) {
      await _syncWithEncoder();
    }
    // Fresh fountain state: drop streams possibly poisoned by earlier
    // corrupt chunks so a clean scan session can actually complete.
    try {
      await (_decoder as dynamic).resetStreams();
    } catch (_) {}

    // Request the chosen camera resolution. Higher raw resolution is what
    // gives the barcode enough pixels to anchor — but it only pays off if the
    // decoder input is allowed to stay large, so raise the input cap for
    // 4K-class captures (otherwise the extra detail is scaled straight back
    // down and the scan still fails).
    final res = _resolutions[_resolutionIndex];
    final maxTarget =
        (res.width >= 3840 || res.height >= 2160) ? 2048 : 1600;
    try {
      (_camera as dynamic).maxTargetSize = maxTarget;
      (_camera as dynamic).captureMode = _captureModeForName(_captureModeName);
      (_camera as dynamic).autoCropEnabled = _autoCropEnabled;
    } catch (_) {}

    try {
      await _camera!.start(
        preferredWidth: res.width,
        preferredHeight: res.height,
        frameIntervalMs: (1000 / _captureFps).round(),
      );
    } catch (e) {
      // Without this the exception escapes, the state stays "active" and
      // every frame-dependent control (截图, and the report upload) is left
      // grey with no explanation. The dominant cause on a phone is insecure
      // origin: getUserMedia is only allowed on HTTPS or localhost, so
      // http://<lan-ip>:8080 silently refuses the camera.
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
    // A scan just ended: if we are linked to the example client, ship the
    // diagnostic report right away. That data is the whole point of the
    // link, so it must not depend on the operator remembering to press a
    // button (the manual 上传画面 button has been removed).
    unawaited(_autoUploadReport());
  }

  int _debugFrameCount = 0;

  Future<void> _processCameraFrame(CameraFrame frame) async {
    if (!_isDecoding || _decoder == null) return;
    _lastFrame = frame;
    // Rebuild now so the frame-dependent UI (screenshot / upload, and the
    // diagnostic report's "last camera frame") reflects this frame even if
    // the decode below throws and skips the setState at the end.
    if (mounted) setState(() {});

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
            '文件已恢复："${result.filename}"（${result.data?.length ?? 0} 字节）';
        await _stopCamera();
        _saveFile();
      } else if (result.error != null) {
        _lastFrameError = result.error!;
        _statusMessage = '帧解码出错：${result.error}';
      } else {
        _statusMessage = '解码中… ${(result.progress * 100).toStringAsFixed(1)}%'
            '（已处理 $_framesProcessed 帧）';
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

  /// Save camera frame as PNG for debugging.
  ///
  /// Stores the frame locally (download on web / file on desktop) AND pushes
  /// both versions to the example (encoder) client for analysis:
  ///  * the PROCESSED frame — exactly what was handed to the decoder
  ///    (cropped, scaled, converted), saved as `*_remote_capture.png`
  ///  * the RAW camera photo — straight off the sensor with no cropping,
  ///    scaling or format conversion, saved as `*_raw_capture.png`
  ///
  /// Having both is what tells a framing/scale problem (raw looks fine but
  /// the crop lost the anchors) apart from a genuine decode problem (the
  /// raw shot itself is blurry, too small or badly lit).
  Future<void> _screenshotFrame() async {
    final frame = _lastFrame;
    if (frame == null) {
      _statusMessage = '还没有捕获到画面帧 — 请先点「启动摄像头」，'
          '等采到第一帧后再截图。';
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
        _statusMessage = '加工后的帧已下载。';
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final path =
            '${dir.path}/${_timestampPrefix()}_cimbar_frame_${frame.width}x${frame.height}.png';
        await File(path).writeAsBytes(pngBytes);
        _statusMessage = '画面帧已保存：$path';
      }
      setState(() {});

      // Push both versions to the example client for analysis.
      await _uploadProcessedAndRaw(pngBytes);
    } catch (e) {
      _statusMessage = '截图出错：$e';
      setState(() {});
    }
  }

  /// Upload the processed frame and the RAW camera photo to the example
  /// client so both end up side by side in `libcimbar_screenshots`.
  Future<void> _uploadProcessedAndRaw(Uint8List processedPng) async {
    if (_debugBaseUrl.isEmpty) {
      setState(() => _statusMessage =
          '$_statusMessage\n未填编码器地址，未上传（加工帧 + 原始帧）。');
      return;
    }

    final uploaded = <String>[];
    final failed = <String>[];

    // 1) Processed frame — what the decoder actually consumed.
    try {
      final r = await http
          .post(Uri.parse('$_debugBaseUrl/captured'),
              headers: {'Content-Type': 'application/octet-stream'},
              body: processedPng)
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        uploaded.add('加工帧');
      } else {
        failed.add('加工帧(HTTP ${r.statusCode})');
      }
    } catch (e) {
      failed.add('加工帧($e)');
    }

    // 2) RAW camera photo — unprocessed ground truth.
    //
    // Always posted (and a /raw-debug diagnostic too) so the linux side can
    // see whether [captureRawFramePng] was actually called and what it
    // returned. Without this, a silent null/throw is indistinguishable from
    // "phone never reached this line" — and that ambiguity was the whole
    // reason raw uploads looked like they never happened.
    Uint8List? rawPng;
    String? rawError;
    try {
      rawPng = await (_camera as dynamic).captureRawFramePng() as Uint8List?;
    } catch (e) {
      rawError = e.toString();
    }

    // Diagnostic ping: independent of the actual upload. Headers carry the
    // summary, body is a JSON snapshot for archival.
    try {
      await http
          .post(
            Uri.parse('$_debugBaseUrl/raw-debug'),
            headers: {
              'Content-Type': 'application/json',
              'X-Raw-Bytes': '${rawPng?.length ?? 0}',
              if (rawError != null) 'X-Raw-Error': rawError,
            },
            body: jsonEncode({
              'timestamp': DateTime.now().toIso8601String(),
              'bytes': rawPng?.length ?? 0,
              'error': rawError,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      // Diagnostic upload is best-effort — never block the actual capture.
      debugPrint('[Decoder] raw-debug POST failed: $e');
    }

    if (rawPng == null) {
      failed.add(rawError != null
          ? '原始帧($rawError)'
          : '原始帧(无法获取)');
    } else {
      try {
        final r = await http
            .post(Uri.parse('$_debugBaseUrl/raw'),
                headers: {'Content-Type': 'application/octet-stream'},
                body: rawPng)
            .timeout(const Duration(seconds: 30));
        if (r.statusCode == 200) {
          uploaded.add('原始帧');
        } else {
          failed.add('原始帧(HTTP ${r.statusCode})');
        }
      } catch (e) {
        failed.add('原始帧($e)');
      }
    }

    if (mounted) {
      setState(() {
        final buf = StringBuffer(_statusMessage);
        if (uploaded.isNotEmpty) {
          buf.write('\n已上传：${uploaded.join('、')}');
        }
        if (failed.isNotEmpty) {
          buf.write('\n上传失败：${failed.join('、')}');
        }
        _statusMessage = buf.toString();
      });
    }
  }

  /// Web implementation: trigger a real browser download via the
  /// [downloadBytesWeb] helper (defined in conditional import).
  void _downloadBytesWeb(Uint8List bytes, String filename) {
    try {
      downloadBytesWeb(bytes, filename);
      _statusMessage = '已捕获画面帧：${bytes.length} 字节。'
          '请在浏览器下载中查看 "$filename"。';
    } catch (e) {
      _statusMessage = '网页下载出错：$e';
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
      _lastSyncResult = '无法连接编码器：'
          '${_debugBaseUrl.isEmpty ? '（未填写地址）' : _debugBaseUrl}';
      _linkOk = false;
      if (mounted) setState(() {}); // refresh the negotiation light
      return _lastSyncResult;
    }
    final encMode = st['mode']?.toString() ?? '';
    if (encMode.isEmpty) {
      _lastSyncResult = '编码器可连接，但模式未知';
      _linkOk = false;
    } else if (encMode == _config.mode.name) {
      _lastSyncResult = '模式一致（$encMode）';
      _linkOk = true;
    } else {
      final target = CimbarMode.values.where((m) => m.name == encMode).toList();
      if (target.isEmpty) {
        _lastSyncResult = '模式不一致：编码器模式 "$encMode" 解码器无法识别'
            '（保持 ${_config.mode.name}）';
        _linkOk = false;
      } else {
        final old = _config.mode.name;
        _config = _config.copyWith(mode: target.first);
        await _decoder?.configure(_config);
        _lastSyncResult = '已修正不一致：解码器模式 $old -> $encMode（已重新配置）';
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
        _statusMessage = '远程解码已停止（共 $_remoteFrames 帧）。';
      });
      return;
    }
    if (_debugBaseUrl.isEmpty || _decoder == null) {
      setState(() => _statusMessage = '请填写编码器调试服务器地址'
          '（显示在编码器的状态栏，例如 http://192.168.1.5:8765）');
      return;
    }
    _remoteFrames = 0;
    _remotePolling = true;
    // Camera frames of the SAME barcode occasionally yield corrupt chunks
    // that still parse: they poison the wirehair stream permanently (the
    // block id is marked "seen", later GOOD copies get dropped — accum
    // grows past 1.0 but never assembles). Ground truth must run
    // exclusively: stop the camera and drop poisoned streams first.
    if (_isCameraActive) {
      await _stopCamera();
    }
    try {
      await (_decoder as dynamic).resetStreams();
    } catch (_) {}
    // Negotiate first: align decoder mode with the encoder before decoding.
    final sync = await _syncWithEncoder();
    _statusMessage = '远程解码 [$sync]：正在从 $_debugBaseUrl 拉取帧…';
    _remoteTimer = Timer.periodic(
        const Duration(milliseconds: 200), (_) => _pollRemoteFrame());
    setState(() {});
  }

  /// Per-frame decode telemetry exposed by the web decoder (via dynamic).
  String _decoderTelemetry() {
    try {
      final d = _decoder as dynamic;
      return 'scan=${d.lastScanBytes}B fountain=${d.lastFountainResult} '
          'accum=${d.lastFountainProgress}';
    } catch (_) {
      return '';
    }
  }

  Future<void> _pollRemoteFrame() async {
    if (_remoteBusy || _decoder == null) return;
    _remoteBusy = true;
    try {
      final resp = await http
          .get(Uri.parse('$_debugBaseUrl/frame.png'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) {
        _statusMessage = '远程帧：HTTP ${resp.statusCode} — 编码器是否'
            '处于「编码并显示」状态？';
        if (mounted) setState(() {});
        return;
      }

      // PNG -> raw RGB via pure-Dart decode (package:image). Deliberately
      // NOT the browser image pipeline (ui.decodeImageFromList): browsers may
      // color-manage PNGs, silently shifting pixel values — fatal for cimbar
      // color bits. This path is byte-exact.
      final decoded = img.decodePng(resp.bodyBytes);
      if (decoded == null) {
        _statusMessage = '远程帧：PNG 解码失败';
        if (mounted) setState(() {});
        return;
      }
      final w = decoded.width, h = decoded.height;
      final rgb = decoded.getBytes(order: img.ChannelOrder.rgb);

      final result = await _decoder!.decodeFrame(
        rgb,
        width: w,
        height: h,
        format: CimbarImageFormat.rgb,
      );
      if (!mounted) return;

      _remoteFrames++;
      _framesProcessed++;
      _progress = result.progress;
      if (result.isComplete) {
        _recoveredData = result.data;
        _recoveredFilename = result.filename;
        _lastRemoteResult = '完成："${result.filename}"'
            '（${result.data?.length ?? 0} 字节，$_remoteFrames 帧）'
            '-> WASM 解码链路正常';
        _statusMessage = '远程解码完成："${result.filename}"'
            '（${result.data?.length ?? 0} 字节，$_remoteFrames 帧）。'
            'WASM 解码链路正常 — 剩余问题出在摄像头采集。';
        _toggleRemoteDecode(); // stop polling
        _saveFile();
      } else if (result.error != null) {
        _lastFrameError = result.error!;
        _lastRemoteResult = '第 $_remoteFrames 帧失败：${result.error}';
        _statusMessage = '远程帧 #$_remoteFrames：${result.error}';
      } else {
        _lastRemoteResult = '进行中（$_remoteFrames 帧）'
            '${_decoderTelemetry()}';
        _statusMessage = '远程解码中…（$_remoteFrames 帧）'
            '${_decoderTelemetry()}';
      }
      setState(() {});
    } catch (e) {
      if (_noteFatalWasmError(e)) return;
      _statusMessage = '远程拉取出错：$e';
      if (mounted) setState(() {});
    } finally {
      _remoteBusy = false;
    }
  }

  /// Push the diagnostic report to the example (encoder) client without any
  /// user interaction.
  ///
  /// Called automatically when a scan stops. The report is the whole point
  /// of the debug link — it carries the anchor counts, stream progress and
  /// brightness stats that explain why the phone could or could not decode —
  /// so it must not depend on the operator remembering to press a button.
  ///
  /// No-ops when no encoder address is configured, or when the client is
  /// not actually reachable (so stopping a scan offline stays silent rather
  /// than showing a spurious upload error).
  Future<void> _autoUploadReport() async {
    if (_debugBaseUrl.isEmpty) return;

    try {
      // Only ship it when the client is really there: a quick /status probe.
      final st = await _fetchEncoderStatus();
      if (st == null) return; // not linked — nothing to do

      final r = await http
          .post(Uri.parse('$_debugBaseUrl/report'),
              headers: {'Content-Type': 'text/plain; charset=utf-8'},
              body: utf8.encode(_buildDiagnosticReport()))
          .timeout(const Duration(seconds: 10));

      if (mounted) {
        setState(() {
          _statusMessage = r.statusCode == 200
              ? '$_statusMessage\n报告已自动上传到 example 客户端。'
              : '$_statusMessage\n报告自动上传失败'
                  '（HTTP ${r.statusCode}）。';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
            () => _statusMessage = '$_statusMessage\n报告自动上传失败：$e');
      }
    }
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

  /// Map the user-visible capture mode name to the underlying enum value.
  ///
  /// `WebCaptureMode` is exported from `package:libcimbar/libcimbar.dart` so
  /// the page can convert its string-backed dropdown state to the actual
  /// enum the capture expects.
  WebCaptureMode _captureModeForName(String name) {
    for (final m in WebCaptureMode.values) {
      if (m.name == name) return m;
    }
    return WebCaptureMode.centerCrop; // matches the UI default
  }

  /// How much of the frame the barcode must cover to still reach its native
  /// 1024 px, given the decoder input size.
  ///
  /// The barcode is only part of the view (it shrinks as the phone moves
  /// away), so a larger decoder input buys real headroom: at 1080 px input
  /// the barcode has to fill ~95% of the frame, at 2048 px only ~50%.
  String _barcodeHeadroom(int? vw, int? vh, int? input) {
    if (input == null || input <= 0) return 'unknown (camera not started)';
    const native = 1024;
    final pctForNative = (100 * native / input).round();
    if (pctForNative <= 40) {
      return 'GOOD — barcode reaches $native px while covering only '
          '$pctForNative% of the frame';
    }
    if (pctForNative <= 70) {
      return 'TIGHT — barcode must cover >= $pctForNative% of the frame to '
          'reach $native px; move closer or raise resolution';
    }
    return 'LOW — barcode must fill >= $pctForNative% of the frame; '
        'raise the camera resolution';
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
      ..writeln(
          '  Polling          : $_remotePolling ($_remoteFrames frames pulled)')
      ..writeln('  Last result      : $_lastRemoteResult')
      ..writeln()
      ..writeln('[Decoder engine]');
    try {
      final d = _decoder as dynamic;
      final heap = (d.heapBytes as int?) ?? 0;
      final dbuf = (d.decodeBufSize as int?) ?? 0;
      b
        ..writeln('  WASM heap        : $heap bytes '
            '(${(heap / (1024 * 1024)).toStringAsFixed(0)} MB)')
        ..writeln('  Decode buffer    : $dbuf B '
            '(= chunks_per_frame x fountain_chunk_size)')
        ..writeln('  Last scan        : ${d.lastScanBytes} B '
            '(>0 payload, 0 no payload, <0 error code)')
        ..writeln('  Last fountain    : ${d.lastFountainResult} '
            '(0 accepted/incomplete, >0 file id = DONE, <0 rejected)')
        ..writeln('  Stream accum     : ${d.lastFountainProgress} '
            '(received/required per stream; ~1.0 -> completes; '
            '>1.0 -> blocks corrupt: enough received but never assembles)');
    } catch (_) {
      b.writeln('  (telemetry unavailable on this platform)');
    }
    b
      ..writeln()
      ..writeln('[Camera]')
      ..writeln('  Requested        : ${_resolutions[_resolutionIndex].width} x '
          '${_resolutions[_resolutionIndex].height} '
          '(${_resolutions[_resolutionIndex].label})')
      ..writeln('  Video resolution : ${vw ?? '?'} x ${vh ?? '?'} '
          '(actual from getUserMedia)')
      ..writeln('  Capture mode     : ${capMode ?? '?'}')
      ..writeln('  Decoder input    : ${input ?? '?'} x ${input ?? '?'} px')
      ..writeln('  Barcode headroom : ${_barcodeHeadroom(vw, vh, input)}')
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
      ..writeln('  found 1-3 anchors -> barcode partially cropped, '
          'off-center, or too few pixels: center it, keep all 4 corners in '
          'view, and raise 摄像头分辨率 (needs >= ~1024 px of barcode)')
      ..writeln('  accum > 1.0       -> stream poisoned by corrupt chunks '
          '(typically camera frames of the same barcode); Pull+Decode now '
          'auto-stops the camera and resets streams first')
      ..writeln('  re-encode restarts the fountain stream: do NOT click '
          'Encode & Display while pulling/scanning');
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
        _statusMessage = '报告已下载：$filename';
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final path = '${dir.path}/$filename';
        await File(path).writeAsString(content);
        _statusMessage = '报告已保存：$path';
      }
    } catch (e) {
      _statusMessage = '报告出错：$e';
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
        _statusMessage = '文件解码成功！正式版本将自动开始下载。';
        return;
      }

      final dir = await getApplicationDocumentsDirectory();
      final filename =
          _recoveredFilename.isNotEmpty ? _recoveredFilename : 'decoded.bin';
      savePath = '${dir.path}/$filename';

      final file = File(savePath);
      await file.writeAsBytes(_recoveredData!);

      setState(() {
        _statusMessage = '文件已保存到：$savePath';
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

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: const Text('libcimbar 解码器'),
      actions: [
        // Mode selector
        PopupMenuButton<CimbarMode>(
          icon: const Icon(Icons.settings),
          tooltip: '条码模式',
          onSelected: (mode) async {
            _config = _config.copyWith(mode: mode);
            await _decoder?.configure(_config);
          },
          itemBuilder: (_) => CimbarMode.values
              .map((m) => PopupMenuItem(
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
                  ))
              .toList(),
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
                          _statusMessage.contains('Error') ||
                          _statusMessage.contains('出错') ||
                          _statusMessage.contains('失败'))
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          tooltip: '复制错误信息',
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: _statusMessage));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('错误信息已复制到剪贴板'),
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
                        label: Text('模式：${_config.mode.name}'),
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

          // Capture FPS control, single compact row so the camera preview
          // below gets as much height as possible.
          Row(
            children: [
              Text('采集帧率', style: Theme.of(context).textTheme.labelSmall),
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

          // Camera resolution: the barcode must occupy >= ~1024 px in the
          // raw frame, so request the highest mode the device offers.
          Row(
            children: [
              Text('摄像头分辨率',
                  style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<int>(
                  isDense: true,
                  isExpanded: true,
                  value: _resolutionIndex,
                  items: [
                    for (int i = 0; i < _resolutions.length; i++)
                      DropdownMenuItem<int>(
                        value: i,
                        child: Text(
                          '${_resolutions[i].label} '
                          '(${_resolutions[i].width}×${_resolutions[i].height})',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                  onChanged: (v) =>
                      setState(() => _resolutionIndex = v ?? _resolutionIndex),
                ),
              ),
            ],
          ),

          // Capture framing: how the camera frame maps into the square
          // decoder input. `fit` is the safe default (always keeps all 4
          // anchors in view); `centerCrop` gives a bigger barcode when the
          // subject is reliably centered; `alternate` mixes both.
          Row(
            children: [
              Text('取景模式',
                  style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  isDense: true,
                  isExpanded: true,
                  value: _captureModeName,
                  items: const [
                    DropdownMenuItem<String>(
                      value: 'centerCrop',
                      child: Text('Center crop（默认，条码最大需居中）',
                          style: TextStyle(fontSize: 13)),
                    ),
                    DropdownMenuItem<String>(
                      value: 'fit',
                      child: Text('Fit（整帧入框，不裁切）',
                          style: TextStyle(fontSize: 13)),
                    ),
                    DropdownMenuItem<String>(
                      value: 'alternate',
                      child: Text('Alternate（交替）',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _captureModeName = v);
                    // Apply immediately so the next captured frame uses
                    // the new framing.
                    try {
                      (_camera as dynamic).captureMode = _captureModeForName(v);
                    } catch (_) {}
                  },
                ),
              ),
            ],
          ),

          // Auto-crop toggle: trims wasted background around the barcode.
          // Off = keep the raw framing exactly as the camera delivered it.
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text('自动裁剪',
                        style: Theme.of(context).textTheme.labelSmall),
                    const SizedBox(width: 4),
                    Tooltip(
                      message: '裁掉条码周围的黑边/无用背景后等比放大（不变形）。'
                          '若画面有其他鲜艳物体干扰检测，可关闭。',
                      child: Icon(Icons.info_outline,
                          size: 14,
                          color: Theme.of(context).colorScheme.outline),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _autoCropEnabled,
                onChanged: (v) {
                  setState(() => _autoCropEnabled = v);
                  try {
                    (_camera as dynamic).autoCropEnabled = v;
                  } catch (_) {}
                },
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Camera controls: 2x2 grid of buttons — a single row of four
          // does not fit narrow phone screens.
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
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  // Always enabled: a disabled (grey) button gave no clue
                  // why it could not be pressed. With no frame yet the
                  // handler tells the user what to do instead.
                  onPressed: _screenshotFrame,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('截图'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saveDiagnosticReport,
                  icon: const Icon(Icons.description),
                  label: const Text('报告'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Network debug link: pull pristine frames from the encoder's
          // debug server / push our camera view back to it. Split into two
          // rows (URL on top, actions below) so it fits phone widths.
          Row(
            children: [
              // Negotiation light: green = link up & modes aligned.
              Tooltip(
                message: '模式协商：$_lastSyncResult',
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
                    labelText: '编码器调试服务器',
                    hintText: 'http://<encoder-ip>:8765',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // The 上传画面 button was removed: the report now ships itself
          // automatically when a scan stops (see [_autoUploadReport]), and
          // camera frames are pushed by 截图 (processed + raw).
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _toggleRemoteDecode,
                  icon:
                      Icon(_remotePolling ? Icons.stop : Icons.cloud_download),
                  label: Text(_remotePolling ? '停止' : '拉取解码'),
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
  /// screen, with a floating status strip on top and a minimal control bar
  /// at the bottom.
  Widget _buildScanningLayout() {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildCameraPreview(fullBleed: true, overlayBottomInset: 80),
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
                  color: Colors.greenAccent,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Minimal control bar under the viewfinder while scanning.
  Widget _buildScanningControls() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        color: Colors.black.withValues(alpha: 0.55),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                // Always enabled, same as the panel 截图 button: a greyed
                // button gives no clue why it cannot be pressed. With no
                // frame captured yet the handler explains what to do.
                onPressed: _screenshotFrame,
                icon: const Icon(Icons.camera_alt),
                label: const Text('截图'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                onPressed: _stopCamera,
                icon: const Icon(Icons.stop),
                label: const Text('停止扫描'),
              ),
            ),
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

  /// [fullBleed] renders the preview edge-to-edge (scanning layout);
  /// [overlayBottomInset] lifts the hint text above the floating control bar.
  Widget _buildCameraPreview(
      {bool fullBleed = false, double overlayBottomInset = 0}) {
    final vType = _cameraViewType;
    if (_isCameraActive && vType != null) {
      // Show camera preview with scanning frame overlay
      final stack = Stack(
        fit: StackFit.expand,
        children: [
          // Camera video stream
          HtmlElementView(viewType: vType),
          // Scanning frame overlay
          _buildScanningOverlay(bottomInset: overlayBottomInset),
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

  /// Scanning frame overlay: dark surroundings with a clear center frame
  /// and animated corner brackets. [bottomInset] lifts the hint text above
  /// the floating control bar in the full-screen scanning layout.
  Widget _buildScanningOverlay({double bottomInset = 0}) {
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
              bottom: 10 + bottomInset,
              child: Text(
                '将整个条码放入取景框内（四个角都可见）',
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
                  '文件已恢复',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('文件名：$_recoveredFilename'),
            Text('大小：${_recoveredData!.length} 字节'),
            Text('帧数：$_framesProcessed'),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _saveFile,
              icon: const Icon(Icons.save),
              label: const Text('保存文件'),
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
