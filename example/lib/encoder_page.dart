import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:libcimbar/libcimbar.dart';
import 'package:window_manager/window_manager.dart';

import 'core/window_display.dart';

/// Encoder page (Windows / Linux) — minimal, official-style flow:
///
///   pick a file → encode to cimbar frames → display them full-size,
///   looping at the configured fps with the upstream display nudge.
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
  String _statusMessage = '初始化中…';

  CimbarConfig _config = const CimbarConfig(
    mode: CimbarMode.modeB,
    compressionLevel: 16,
    fps: 15,
  );

  /// Range of supported display rates.
  static const int _minFps = 1;
  static const int _maxFps = 60;

  // Encode input / output
  CimbarInputFile? _inputFile;
  List<CimbarFrame> _frames = [];

  // Frame counter (displayed under the player)
  int _currentFrameIndex = 0;

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
            ? '就绪。选择一个文件开始编码。'
            : '未加载原生库。请先构建 libcimbar（.dll / .so）。';
      });
    } catch (e) {
      setState(() => _statusMessage = '初始化出错：$e');
    }
  }

  // --- Pick file → encode → display ---

  Future<void> _pickFile() async {
    try {
      final input = await pickCimbarInputFile();
      if (input == null) return; // user cancelled
      setState(() {
        _inputFile = input;
        _statusMessage =
            '已选择：${input.filename}（${input.bytes.length} 字节）。点击「编码并显示」。';
      });
    } catch (e) {
      setState(() => _statusMessage = '选择文件出错：$e');
    }
  }

  Future<void> _startEncoding() async {
    if (_inputFile == null || _encoder == null || _isEncoding) return;
    _isEncoding = true; // synchronous guard against double-click

    setState(() => _statusMessage = '正在将数据编码为 cimbar 帧…');

    try {
      final frames = await _encoder!.encodeData(
        _inputFile!.bytes,
        filename: _inputFile!.filename,
      );

      if (frames.isEmpty) {
        setState(() {
          _statusMessage = '编码未生成任何帧。';
          _isEncoding = false;
        });
        return;
      }

      setState(() {
        _frames = frames;
        _currentFrameIndex = 0;
        _statusMessage = '已生成 ${frames.length} 帧 cimbar 条码，正在播放…';
      });

      // Linux: force cover mode (WM fullscreen layer) when the barcode starts
      // playing so it is guaranteed to sit above the dock/top bar for the
      // camera. Always-on-top is re-asserted inside coverTaskbar() last.
      if (!kIsWeb && Platform.isLinux && !_coveringTaskbar) {
        await coverTaskbar();
        if (mounted) setState(() => _coveringTaskbar = true);
      }
    } catch (e) {
      setState(() => _statusMessage = '编码出错：$e');
    }

    if (mounted) setState(() => _isEncoding = false);
  }

  void _stopEncoding() {
    setState(() {
      _frames = [];
      _currentFrameIndex = 0;
      _statusMessage = '已停止。';
    });
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
          // Right side: cimbar panel centered in the right area. The box is
          // the 1024 barcode plus the shake gutter, so it is never stretched.
          Positioned(
            left: 200,
            top: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black,
              child: Center(
                child: _frames.isNotEmpty
                    ? CimbarFramePlayer(
                        key: ValueKey(_frames),
                        frames: _frames,
                        fps: _config.fps,
                        onFrameChanged: (i) {
                          if (mounted) {
                            setState(() => _currentFrameIndex = i);
                          }
                        },
                      )
                    : _buildPlaceholder(),
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
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _isReady && !_isEncoding
                                ? _pickFile
                                : null,
                            icon: const Icon(Icons.folder_open, size: 18),
                            label: const Text('选择文件'),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _inputFile != null && !_isEncoding
                                ? _startEncoding
                                : null,
                            icon: const Icon(Icons.qr_code, size: 18),
                            label: const Text('编码并显示'),
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
                          if (_inputFile != null) ...[
                            _infoRow('文件名', _inputFile!.filename),
                            const SizedBox(height: 6),
                            _infoRow('大小',
                                '${(_inputFile!.bytes.length / 1024).toStringAsFixed(1)} KB'),
                            const SizedBox(height: 6),
                            _infoRow('模式', _config.mode.name),
                            const SizedBox(height: 6),
                            _fpsControl(),
                            const SizedBox(height: 6),
                            _infoRow('帧数', '${_frames.length}'),
                          ],
                          // Fixed gap instead of Spacer: inside a
                          // SingleChildScrollView the height constraints are
                          // unbounded, so a Spacer (flex child) is invalid.
                          const SizedBox(height: 20),
                          if (_frames.isNotEmpty)
                            Text(
                              '第 ${_currentFrameIndex + 1} / ${_frames.length} 帧',
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

  Widget _buildPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.upload_file_outlined,
              size: 80, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            '点击「选择文件」\n选择要传输的文件',
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

  /// FPS control: shows current display rate, lets the user adjust it
  /// via a slider. The player applies the new rate live.
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
            onChanged: (v) => setState(() {
              _config = _config.copyWith(fps: v.round().clamp(_minFps, _maxFps));
            }),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      windowManager.removeListener(this);
    }
    _encoder?.dispose();
    super.dispose();
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
