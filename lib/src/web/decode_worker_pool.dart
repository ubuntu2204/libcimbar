// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

@JS('Reflect.get')
external JSAny? _reflectGet(JSObject target, JSString key);

@JS('Reflect.set')
external void _reflectSet(JSObject target, JSString key, JSAny? value);

@JS('Reflect.apply')
external JSAny? _reflectApply(
    JSFunction fn, JSObject thisArg, JSArray<JSAny?> args);

@JS('Reflect.construct')
external JSObject _reflectConstruct(JSFunction ctor, JSArray<JSAny?> args);

@JS('navigator')
external JSObject get _navigator;

@JS('Object')
external JSObject _newObject();

/// One decode result from a worker.
typedef WorkerDecodeResult = ({int len, Uint8List? bytes, String? report});

/// A pool of Web Workers, each running its own libcimbar WASM instance and
/// performing the heavy per-frame work (`cimbard_scan_extract_decode`).
///
/// This is the official receiver's architecture (recv.html + recv-worker.js,
/// 4 workers) taken one step further: the worker count scales with the
/// machine (`hardwareConcurrency`, clamped to 4–6), and the main thread —
/// which keeps the fountain sink and reassembly on its own wasm instance —
/// stays free for capture and UI.
///
/// Frames are posted with a **transferred** pixel buffer (zero copy); the
/// reply carries at most `cimbard_get_bufsize()` bytes (7.5KB in modeB) of
/// fountain chunks, transferred back the same way.
///
/// The pool degrades gracefully: if workers cannot be spawned, error out,
/// or time out repeatedly, [isOk] flips false and the caller falls back to
/// decoding on the main thread (the pre-worker behavior).
class DecodeWorkerPool {
  /// Web Worker script URL, relative to the page — the same directory as
  /// the wasm glue it importScripts()es.
  static const String workerUrl = 'assets/wasm/decode_worker.js';

  /// Give up on a single decode after this long (a wedged worker would
  /// otherwise leak one pending slot per frame forever).
  static const Duration _requestTimeout = Duration(seconds: 2);

  /// Disable the pool after this many consecutive failed/timed-out decodes.
  static const int _maxConsecutiveFailures = 5;

  /// Mirrors the official receiver's stall threshold (recv.js stalls the
  /// feed when more than 20 frames are in flight).
  static const int _maxInFlight = 20;

  final List<JSObject> _workers = [];
  final Set<int> _readyWorkers = {};
  final Map<int, Completer<WorkerDecodeResult>> _pending = {};

  int _seq = 0;
  int _nextWorker = 0;
  int _consecutiveFailures = 0;
  bool _broken = false;

  /// Number of decodes awaiting a worker reply.
  int get pending => _pending.length;

  /// False when the pool is unusable — callers should decode on the main
  /// thread instead.
  bool get isOk => !_broken && _workers.isNotEmpty;

  DecodeWorkerPool() {
    _spawn();
  }

  void _spawn() {
    JSFunction? workerCtor;
    try {
      workerCtor = _reflectGet(globalContext, 'Worker'.toJS) as JSFunction?;
    } catch (_) {}
    if (workerCtor == null) {
      debugPrint('[WorkerPool] Worker constructor unavailable — '
          'main-thread decode only');
      return;
    }

    // Official recv.html hardcodes 4. Scale modestly with the machine so
    // many-core desktops decode in parallel beyond the official setup,
    // while phones (typically 8 hardwareConcurrency) stay at a sane
    // memory footprint — every worker holds its own wasm instance.
    int cores = 4;
    try {
      final hc = _reflectGet(_navigator, 'hardwareConcurrency'.toJS);
      if (hc is JSNumber) cores = hc.toDartInt;
    } catch (_) {}
    final count = cores.clamp(4, 6);

    for (int i = 0; i < count; i++) {
      try {
        final w = _reflectConstruct(
            workerCtor, <JSAny?>[workerUrl.toJS].toJS);
        _reflectSet(
            w,
            'onmessage'.toJS,
            ((JSAny? ev) => _onWorkerMessage(i, ev)).toJS);
        _reflectSet(
            w,
            'onerror'.toJS,
            ((JSAny? ev) {
              debugPrint('[WorkerPool] worker $i error: '
                  '${(_reflectGet(ev as JSObject, 'message'.toJS) as JSString?)?.toDart ?? "?"} — disabling pool');
              _markBroken();
            }).toJS);
        _workers.add(w);
      } catch (e) {
        debugPrint('[WorkerPool] failed to spawn worker $i: $e');
      }
    }
    if (_workers.isEmpty) {
      _broken = true;
      return;
    }
    debugPrint('[WorkerPool] ${_workers.length} decode worker(s) spawned '
        '(hardwareConcurrency=$cores), waiting for wasm init');
  }

  void _onWorkerMessage(int workerId, JSAny? ev) {
    final data = _reflectGet(ev as JSObject, 'data'.toJS) as JSObject?;
    if (data == null) return;
    final type = _reflectGet(data, 't'.toJS);
    if (type is JSString && type.toDart == 'ready') {
      _readyWorkers.add(workerId);
      return;
    }
    if (type is JSString && type.toDart == 'res') {
      final seq = (_reflectGet(data, 'seq'.toJS) as JSNumber?)?.toDartInt ?? -1;
      final completer = _pending.remove(seq);
      if (completer == null || completer.isCompleted) return;

      final len = (_reflectGet(data, 'len'.toJS) as JSNumber?)?.toDartInt ?? -1;
      Uint8List? bytes;
      if (len > 0) {
        final buf = _reflectGet(data, 'buf'.toJS);
        if (buf is JSUint8Array) bytes = buf.toDart;
      }
      String? report;
      final rpt = _reflectGet(data, 'rpt'.toJS);
      if (rpt is JSString) report = rpt.toDart;

      if (len > 0 || len == 0 || len == -3) {
        // 0 = anchors found but no payload; -3 = anchors not found. Both
        // are NORMAL outcomes, not failures.
        _consecutiveFailures = 0;
      } else {
        if (++_consecutiveFailures >= _maxConsecutiveFailures) {
          debugPrint('[WorkerPool] $_consecutiveFailures consecutive decode '
              'failures — disabling pool');
          _markBroken();
        }
      }
      completer.complete((len: len, bytes: bytes, report: report));
    }
  }

  void _markBroken() {
    _broken = true;
    // Fail every in-flight request so waiters do not hang until timeout.
    for (final c in _pending.values.toList()) {
      if (!c.isCompleted) {
        c.complete((len: -100, bytes: null, report: 'pool-disabled'));
      }
    }
    _pending.clear();
    terminate();
  }

  /// Tell every worker the active decode mode. Cheap: the worker-side
  /// configure is a no-op unless the value changed.
  void configure(int modeVal) {
    if (_broken) return;
    for (final w in _workers) {
      try {
        final post = _reflectGet(w, 'postMessage'.toJS) as JSFunction?;
        if (post == null) continue;
        final msg = _newObject();
        _reflectSet(msg, 't'.toJS, 'cfg'.toJS);
        _reflectSet(msg, 'mode'.toJS, modeVal.toJS);
        _reflectApply(post, w, <JSAny?>[msg].toJS);
      } catch (_) {}
    }
  }

  /// Post one frame to the next worker (round-robin, like recv.js).
  ///
  /// [pixels] is consumed: its underlying buffer is TRANSFERRED to the
  /// worker. Do not touch it after this call.
  ///
  /// Returns null when the pool is saturated (mirrors the official
  /// "stalling, worker queues are full" frame drop) or not yet usable.
  Future<WorkerDecodeResult?> decode(
      Uint8List pixels, int width, int height, int formatCode, int modeVal) {
    if (_broken || _pending.length >= _maxInFlight) return Future.value(null);

    // Not a single worker has finished wasm init yet — let the caller
    // decode this one on the main thread rather than dropping it.
    if (_readyWorkers.isEmpty) return Future.value(null);

    // The Dart Uint8List is backed by a JS Uint8Array in dart2js; .toJS
    // hands back that view, whose buffer we can transfer zero-copy.
    final JSUint8Array view;
    try {
      view = pixels.toJS;
    } catch (_) {
      return Future.value(null);
    }
    final buffer = _reflectGet(view, 'buffer'.toJS);
    if (buffer == null) return Future.value(null);

    final seq = ++_seq;
    final completer = Completer<WorkerDecodeResult>();
    _pending[seq] = completer;

    // Fallback timer: a wedged worker must not leak the pending slot.
    Timer(_requestTimeout, () {
      final c = _pending.remove(seq);
      if (c != null && !c.isCompleted) {
        debugPrint('[WorkerPool] decode #$seq timed out');
        c.complete((len: -100, bytes: null, report: 'timeout'));
        if (++_consecutiveFailures >= _maxConsecutiveFailures) {
          _markBroken();
        }
      }
    });

    try {
      final w = _workers[_nextWorker];
      _nextWorker = (_nextWorker + 1) % _workers.length;

      final msg = _newObject();
      _reflectSet(msg, 't'.toJS, 'dec'.toJS);
      _reflectSet(msg, 'seq'.toJS, seq.toJS);
      _reflectSet(msg, 'px'.toJS, view);
      _reflectSet(msg, 'fmt'.toJS, formatCode.toJS);
      _reflectSet(msg, 'w'.toJS, width.toJS);
      _reflectSet(msg, 'h'.toJS, height.toJS);
      _reflectSet(msg, 'mode'.toJS, modeVal.toJS);

      final post = _reflectGet(w, 'postMessage'.toJS) as JSFunction?;
      if (post == null) throw StateError('worker postMessage missing');
      // postMessage(msg, transfer): the transfer list MUST be a JS array
      // of the buffers to detach — passing the ArrayBuffer itself makes
      // Chrome throw "The object must have a callable @@iterator".
      _reflectApply(
          post, w, <JSAny?>[msg, <JSAny?>[buffer].toJS].toJS);
    } catch (e) {
      // postMessage failed — the buffer was NOT transferred, so the pixels
      // are still valid for a main-thread fallback decode.
      _pending.remove(seq);
      debugPrint('[WorkerPool] postMessage failed: $e');
      return Future.value(null);
    }

    return completer.future;
  }

  /// Terminate every worker. The pool is unusable afterwards.
  void terminate() {
    for (final w in _workers) {
      try {
        final term = _reflectGet(w, 'terminate'.toJS) as JSFunction?;
        term?.callAsFunction(w);
      } catch (_) {}
    }
    _workers.clear();
    _readyWorkers.clear();
  }
}
