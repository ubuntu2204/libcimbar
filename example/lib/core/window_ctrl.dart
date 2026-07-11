import 'dart:async';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Window state phases for the capture flow.
///
/// Transitions:
/// [normal] -> [hiding] -> [hidden] -> [enteringSelection] -> [selecting] -> [restoring] -> [normal]
enum WindowPhase {
  normal,
  hiding,
  hidden,
  enteringSelection,
  selecting,
  restoring,
}

/// Window state controller - manages hide/show/restore for screenshot capture.
///
/// All window state changes must go through this class to avoid conflicts.
/// Features:
/// - Strict phase state machine ensuring correct operation order
/// - Auto-unlock on timeout ([_timeoutSec]) to prevent deadlocks
/// - Emergency recovery fallback
class WindowCtrl {
  WindowCtrl._();
  static final WindowCtrl instance = WindowCtrl._();

  WindowPhase _phase = WindowPhase.normal;
  WindowPhase get phase => _phase;

  DateTime? _opStartTime;
  static const int _timeoutSec = 15;

  Rect? _savedBounds;
  bool? _savedSkipTaskbar;
  bool _wasFullScreen = false;

  bool get _busy {
    if (_phase == WindowPhase.normal) return false;
    if (_phase == WindowPhase.selecting) return false;
    if (_opStartTime != null) {
      final elapsed = DateTime.now().difference(_opStartTime!).inSeconds;
      if (elapsed > _timeoutSec) {
        debugPrint('[WindowCtrl] Timeout auto-unlock: phase=$_phase, ${elapsed}s');
        _phase = WindowPhase.normal;
        _opStartTime = null;
        Future.microtask(_emergencyRestore);
        return false;
      }
    }
    return true;
  }

  // --- Public API ---

  /// Hide window and save state, preparing for full-screen capture.
  Future<void> hideForCapture() async {
    if (_busy && _phase != WindowPhase.normal) {
      debugPrint('[WindowCtrl] hideForCapture skipped: busy phase=$_phase');
      return;
    }

    _setPhase(WindowPhase.hiding);
    try {
      await _saveCurrentState();
      await _doHide();
      _setPhase(WindowPhase.hidden);
    } catch (e) {
      debugPrint('[WindowCtrl] hideForCapture failed: $e');
      _setPhase(WindowPhase.normal);
    }
  }

  /// Enter full-screen selection mode (transparent overlay).
  Future<void> enterSelectionMode() async {
    if (_phase == WindowPhase.selecting) return;
    if (_phase != WindowPhase.hidden && _busy) {
      debugPrint('[WindowCtrl] enterSelectionMode skipped: busy');
      return;
    }
    _setPhase(WindowPhase.enteringSelection);
    try {
      await Future.wait([
        windowManager.setFullScreen(true),
        windowManager.setAlwaysOnTop(true),
        windowManager.setSkipTaskbar(true),
        windowManager.setBackgroundColor(const Color(0x00000000)),
        _trySetFrameless(),
      ]);
      _setPhase(WindowPhase.selecting);
    } catch (e) {
      debugPrint('[WindowCtrl] enterSelectionMode failed: $e');
      await _doRestore();
    }
  }

  /// Restore window to original state.
  Future<void> restoreToNormal() async {
    if (_phase == WindowPhase.normal && !_isInIntermediateState()) return;
    _setPhase(WindowPhase.restoring);
    await _doRestore();
  }

  /// Force reset: immediately restore window regardless of state.
  Future<void> forceReset() async {
    _setPhase(WindowPhase.restoring);
    await _emergencyRestore();
  }

  bool get isInCaptureFlow =>
      _phase != WindowPhase.normal;

  // --- Internal ---

  void _setPhase(WindowPhase newPhase) {
    _phase = newPhase;
    if (newPhase == WindowPhase.normal || newPhase == WindowPhase.selecting) {
      _opStartTime = null;
    } else {
      _opStartTime ??= DateTime.now();
    }
  }

  Future<bool> _isFullScreen() async {
    try {
      return await windowManager.isFullScreen();
    } catch (_) {
      return false;
    }
  }

  bool _isInIntermediateState() => _savedBounds != null || _wasFullScreen;

  Future<void> _saveCurrentState() async {
    final results = await Future.wait([
      windowManager.getBounds(),
      windowManager.isSkipTaskbar(),
      _isFullScreen(),
    ]);
    _savedBounds = results[0] as Rect;
    _savedSkipTaskbar = results[1] as bool;
    _wasFullScreen = results[2] as bool;
  }

  Future<void> _doHide() async {
    if (_wasFullScreen) {
      await windowManager.setFullScreen(false);
    }
    await windowManager.hide();
  }

  Future<void> _doRestore() async {
    try {
      await Future.wait([
        windowManager.setFullScreen(false),
        windowManager.setAlwaysOnTop(false),
      ]);

      await Future.wait([
        if (_savedSkipTaskbar != null)
          windowManager.setSkipTaskbar(_savedSkipTaskbar!),
        _trySetTitleBar(),
        windowManager.setBackgroundColor(Colors.transparent),
      ]);

      if (_savedBounds != null) {
        await windowManager.setSize(_savedBounds!.size);
        await windowManager.setPosition(_savedBounds!.topLeft);
      } else {
        await windowManager.setSize(const Size(1100, 750));
      }

      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('[WindowCtrl] _doRestore failed: $e');
      await _emergencyRestore();
    } finally {
      _savedBounds = null;
      _savedSkipTaskbar = null;
      _wasFullScreen = false;
      _setPhase(WindowPhase.normal);
    }
  }

  Future<void> _trySetFrameless() async {
    try {
      await windowManager.setAsFrameless();
    } catch (_) {}
  }

  Future<void> _trySetTitleBar() async {
    try {
      await windowManager.setAsFrameless();
    } catch (_) {}
  }

  Future<void> _emergencyRestore() async {
    await Future.wait([
      _safeCall(() => windowManager.setFullScreen(false)),
      _safeCall(() => windowManager.setAlwaysOnTop(false)),
      _safeCall(() => windowManager.setSkipTaskbar(false)),
      _safeCall(() => windowManager.setSize(const Size(1100, 750))),
      _safeCall(() => windowManager.setBackgroundColor(Colors.transparent)),
    ]);
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
    _savedBounds = null;
    _savedSkipTaskbar = null;
    _wasFullScreen = false;
    _setPhase(WindowPhase.normal);
  }

  Future<void> _safeCall(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (_) {}
  }
}
