import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:libcimbar/libcimbar.dart';
import 'package:window_manager/window_manager.dart';

import 'core/window_display.dart';

/// Encoder page (Windows / Linux) — a port of the official encoder UI
/// (`third_party/libcimbar/web/index.html` + `send.js`), minus the web-only
/// bits:
///
///   * one-step flow: picking a file starts encoding immediately and the
///     barcode starts playing (official `importFile` → `Report.setActive`);
///   * the barcode plays from an *infinite* fountain stream, one frame
///     produced per tick ([ICimbarEncoder.nextFrame]), exactly like
///     upstream `send.js nextFrame()`;
///   * Mode buttons B / Bm / Bu / 4C (official nav `modesel` row) — a mode
///     switch reconfigures the encoder and clears the current stream, the
///     way `cimbare_configure` throws out an incompatible stream;
///   * Framerate slider 5–20 step 5, default 15 (official range input);
///   * press-and-hold on the barcode pauses playback for 15 frames — the
///     official `Send.togglePause` autofocus cooldown, fired on
///     touchstart/touchend upstream.
///
/// All real logic (encoding, frame playback, shake) lives in the
/// `libcimbar` package; this page only wires it to buttons and status text.
class EncoderPage extends StatefulWidget {
  const EncoderPage({super.key});

  @override
  State<EncoderPage> createState() => _EncoderPageState();
}

class _EncoderPageState extends State<EncoderPage> with WindowListener {
  final CimbarPlatform _platform = CimbarPlatform.instance;

  ICimbarEncoder? _encoder;

  bool _isReady = false;
  bool _isEncoding = false;
  // Windows starts windowed (still topmost); Linux starts in cover mode
  // (fullscreen layer) — see main.dart — so the toggle state must match.
  bool _coveringTaskbar = !kIsWeb && Platform.isLinux;

  // Official `Report.setActive` state: a fountain stream is ready and the
  // barcode is on screen.
  bool _hasStream = false;
  // The player runs unless paused (official `Send.isPaused`).
  bool _playerPlaying = false;

  String _statusMessage = '初始化中…';

  // Official defaults: mode B (68), compression = Config default (16),
  // fps = 15 — see send.cpp options and send.js _interval = 66.
  CimbarConfig _config = const CimbarConfig();

  /// Official framerate range: `index.html` uses min=5 max=20 step=5.
  static const int _minFps = 5;
  static const int _maxFps = 20;
  static const int _fpsStep = 5;

  // Encode input
  CimbarInputFile? _inputFile;

  // Displayed frame counter ("第 N 帧").
  int _currentFrameIndex = 0;

  // Bumped on every new encode so the player restarts its shake/loop state.
  int _streamKey = 0;

  // Official pause cooldown: togglePause(true) stalls rendering for 15
  // frames so the camera can refocus, then playback resumes by itself.
  Timer? _pauseCooldown;
  static const int _pauseCooldownFrames = 15;

  @override
  void initState() {
    super.initState();
    // Project rule: the encoder window must stay frontmost (always-on-top).
    // Listen for focus changes so we can re-assert it (see [onWindowBlur]).
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      windowManager.addListener(this);
    }
    _initialize();
  }

  /// Project rule: the encoder window must always stay on top / frontmost,
  /// so the displayed cimbar is never occluded. Whenever the window loses
  /// focus, re-assert topmost so it can never fall behind other windows.
  @override
  void onWindowBlur() {
    windowManager.setAlwaysOnTop(true);
  }

  /// Toggle between covering the taskbar (topmost, full-screen size) and a
  /// normal centered windowed size. Both stay topmost (above the taskbar);
  /// neither uses fullscreen mode.
  ///
  /// This is this app's analogue of the official `Main.toggleFullscreen`
  /// (which also fires `togglePause(true)` — we do the same via
  /// [_pauseForRefocus]).
  Future<void> _toggleCoverTaskbar() async {
    try {
      _pauseForRefocus();
      if (_coveringTaskbar) {
        await restoreWindowed();
      } else {
        await coverTaskbar();
      }
      if (mounted) setState(() => _coveringTaskbar = !_coveringTaskbar);
    } catch (_) {}
  }

  Future<void> _initialize() async {
    // Guard: encoder runs on desktop (Windows / Linux).
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux)) {
      setState(() {
        _statusMessage = '错误：编码仅支持 Windows/Linux 桌面端。';
      });
      return;
    }

    try {
      _encoder = await _platform.createEncoder();
      await _encoder!.configure(_config);

      setState(() {
        _isReady = _encoder!.isReady;
        _statusMessage = _isReady
            ? '就绪。选择一个文件开始传输。'
            : '未加载原生库。请先构建 libcimbar（.dll / .so）。';
      });
    } catch (e) {
      setState(() => _statusMessage = '初始化出错：$e');
    }
  }

  // ─── Official send.js flow: importFile → encode_init → encode_bytes ──

  /// Official one-step flow (`send.js importFile`): pick a file, init the
  /// encode session, feed the file in slices, flush — then start playing
  /// (`Report.setActive`). There is no separate "encode" button upstream.
  Future<void> _pickAndEncode() async {
    if (_encoder == null || _isReady == false || _isEncoding) return;

    final CimbarInputFile input;
    try {
      final picked = await pickCimbarInputFile();
      if (picked == null) return; // user cancelled
      input = picked;
    } catch (e) {
      setState(() => _statusMessage = '选择文件出错：$e');
      return;
    }

    setState(() {
      _inputFile = input;
      _hasStream = false;
      _playerPlaying = false;
      _currentFrameIndex = 0;
      _isEncoding = true;
      _statusMessage = '正在将 ${input.filename}（${_formatBytes(input.length)}）编码为 cimbar 帧…';
    });

    try {
      // Official `Send.encode_init(filename)` — embeds the name in the
      // stream header and auto-increments the encode id (-1).
      await _encoder!.initEncodeSession(input.filename);

      // Official `Send.importFile`: read the file in slices and feed each
      // one (`Send.encode_bytes`).
      await for (final chunk in input.readChunks()) {
        final status = await _encoder!.encodeChunk(chunk);
        if (status < 0) {
          throw StateError('cimbare_encode failed with code $status');
        }
      }

      // Official fallback flush: `cimbare_encode(nullptr, 0)`.
      await _encoder!.finishEncode();

      // Official `Report.setActive()`: the stream is live — start rendering.
      setState(() {
        _streamKey++;
        _hasStream = true;
        _playerPlaying = true;
        _currentFrameIndex = 0;
        _statusMessage = '正在播放：${input.filename}';
      });

      // Linux: force cover mode (WM fullscreen layer) when the barcode starts
      // playing so it is guaranteed to sit above the dock/top bar for the
      // camera. Always-on-top is re-asserted inside coverTaskbar() last.
      if (!kIsWeb && Platform.isLinux && !_coveringTaskbar) {
        await coverTaskbar();
        if (mounted) setState(() => _coveringTaskbar = true);
      }
    } catch (e) {
      setState(() {
        _hasStream = false;
        _playerPlaying = false;
        _statusMessage = '编码出错：$e';
      });
    }

    if (mounted) setState(() => _isEncoding = false);
  }

  // ─── Official send.js pause cooldown ─────────────────────────────────

  /// Official `Send.togglePause`: a 15-frame cooldown that freezes the
  /// barcode so the camera can refocus, resuming by itself. Upstream fires
  /// it on touchstart (pointer down here) and cancels it on touchend.
  void _onBarcodePointerDown(bool down) {
    if (!_hasStream) return;
    if (down) {
      _pauseForRefocus();
    } else {
      _resume();
    }
  }

  void _pauseForRefocus() {
    _pauseCooldown?.cancel();
    if (_playerPlaying) setState(() => _playerPlaying = false);
    _pauseCooldown = Timer(
      Duration(milliseconds: _pauseCooldownFrames * (1000 ~/ _config.fps)),
      _resume,
    );
  }

  void _resume() {
    _pauseCooldown?.cancel();
    _pauseCooldown = null;
    if (_hasStream && !_playerPlaying && mounted) {
      setState(() => _playerPlaying = true);
    }
  }

  // ─── Official main.js setMode ─────────────────────────────────────────

  /// Official `Main.setMode` → `cimbare_configure(mode_val, -1)`: switching
  /// mode keeps no compression override (-1 resets it to the Config
  /// default) and throws out a stream whose chunk size no longer matches
  /// (upstream clears the canvas). Picking a file again restarts the flow.
  Future<void> _setMode(CimbarMode mode) async {
    if (mode == _config.mode) return;
    final newConfig = CimbarConfig(mode: mode);
    try {
      await _encoder?.configure(newConfig);
      setState(() {
        _config = newConfig;
        _hasStream = false;
        _playerPlaying = false;
        _currentFrameIndex = 0;
        _statusMessage = '模式已切换为 ${_modeLabel(mode)}，重新选择文件开始传输。';
      });
    } catch (e) {
      setState(() => _statusMessage = '切换模式出错：$e');
    }
  }

  /// Official `Main.setFPS` → `Send.setFPS`: `interval = floor(1000 / val)`.
  /// The player re-arms its timer when the fps prop changes.
  void _setFps(int fps) {
    if (fps == _config.fps) return;
    setState(() => _config = _config.copyWith(fps: fps));
  }

  // ─── UI helpers ────────────────────────────────────────────────────────

  /// Official nav labels: B / Bm / Bu / 4C.
  String _modeLabel(CimbarMode mode) =>
      mode == CimbarMode.mode4C ? '4C' : mode.name.substring(4);

  /// Chinese description of each barcode mode (mode menu tooltips).
  String _modeDescription(CimbarMode mode) => switch (mode) {
        CimbarMode.mode4C => '16x16 网格，兼容性最好',
        CimbarMode.modeB => '24x24 网格，彩色大容量（默认）',
        CimbarMode.modeBm => '24x24 网格，黑白单色，适合暗环境',
        CimbarMode.modeBu => '24x24 网格，B 模式变体',
      };

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes 字节';
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  // ─── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          // Right side: the barcode canvas, centered, keeping its aspect
          // ratio — the official `Main.scaleCanvas` behaviour.
          Positioned(
            left: 200,
            top: 0,
            right: 0,
            bottom: 0,
            child: Listener(
              // Official touchstart/touchend pause cooldown.
              onPointerDown: (e) => _onBarcodePointerDown(true),
              onPointerUp: (e) => _onBarcodePointerDown(false),
              onPointerCancel: (e) => _onBarcodePointerDown(false),
              child: Container(
                color: Colors.black,
                child: Center(
                  child: _hasStream
                      ? FittedBox(
                          fit: BoxFit.contain,
                          child: CimbarFramePlayer(
                            key: ValueKey(_streamKey),
                            frameSupplier: () => _encoder!.nextFrame(),
                            fps: _config.fps,
                            playing: _playerPlaying,
                            onFrameChanged: (i) {
                              if (mounted) {
                                setState(() => _currentFrameIndex = i);
                              }
                            },
                          ),
                        )
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
                    // Extra top inset so the window control buttons sit a
                    // little lower and easy to reach.
                    padding: const EdgeInsets.fromLTRB(10, 32, 10, 10),
                    child: SingleChildScrollView(
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
                          // Official nav "current-file" line.
                          Text(
                            _inputFile?.filename ?? '未选择文件',
                            style: Theme.of(context).textTheme.labelSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _isReady && !_isEncoding
                                ? _pickAndEncode
                                : null,
                            icon: const Icon(Icons.folder_open, size: 18),
                            label: const Text('选择文件'),
                          ),
                          const SizedBox(height: 12),
                          // Official modesel row: B / Bm / Bu / 4C flat buttons.
                          _modeButtons(),
                          const SizedBox(height: 12),
                          // Official Framerate range: min 5 max 20 step 5.
                          _fpsControl(),
                          const SizedBox(height: 12),
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
                                    // Selectable so users can copy error text.
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
                          if (_inputFile != null) ...[
                            const SizedBox(height: 16),
                            _infoRow('大小', _formatBytes(_inputFile!.length)),
                            const SizedBox(height: 6),
                            _infoRow('模式', _modeLabel(_config.mode)),
                          ],
                          const SizedBox(height: 20),
                          if (_hasStream)
                            Text(
                              _playerPlaying
                                  ? '第 ${_currentFrameIndex + 1} 帧'
                                  : '已暂停（松开恢复）',
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                        ],
                      ),
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

  /// Official nav modesel row: four flat mode buttons.
  Widget _modeButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final mode in CimbarMode.values)
          _ModeButton(
            label: _modeLabel(mode),
            description: _modeDescription(mode),
            selected: mode == _config.mode,
            onPressed: _isEncoding ? null : () => _setMode(mode),
          ),
      ],
    );
  }

  Widget _buildPlaceholder() {
    // Official drop-message copy: a "start" hint plus the photosensitivity
    // warning that upstream shows before any barcode is on screen.
    final outline = Theme.of(context).colorScheme.outline;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.upload_file_outlined, size: 80, color: outline),
        const SizedBox(height: 16),
        Text(
          '⌜ 点击「选择文件」开始 ⌟',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(color: outline),
        ),
        const SizedBox(height: 24),
        Text(
          '⚠️⚡ 光敏性警告！',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: outline,
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          '光敏性癫痫 + 闪烁光源 = 发作风险！\n注意安全！',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: outline),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  /// Official Framerate control: `min=5 max=20 step=5 value=15`.
  Widget _fpsControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('帧率', style: Theme.of(context).textTheme.labelSmall),
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
          divisions: (_maxFps - _minFps) ~/ _fpsStep,
          label: '${_config.fps} fps',
          onChanged: (v) => _setFps(v.round()),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _pauseCooldown?.cancel();
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      windowManager.removeListener(this);
    }
    _encoder?.dispose();
    super.dispose();
  }
}

/// One flat mode button (official nav `modesel` links).
class _ModeButton extends StatelessWidget {
  final String label;
  final String description;
  final bool selected;
  final VoidCallback? onPressed;

  const _ModeButton({
    required this.label,
    required this.description,
    required this.selected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: description,
      child: SizedBox(
        width: 40,
        height: 32,
        child: FilledButton.tonal(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            padding: EdgeInsets.zero,
            backgroundColor: selected
                ? scheme.primary.withValues(alpha: 0.25)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            foregroundColor:
                selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.7),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
          child: Text(label),
        ),
      ),
    );
  }
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
