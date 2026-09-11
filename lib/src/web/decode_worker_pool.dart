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

@JS('Object')
external JSObject _newObject();

/// One decode result from a worker.
typedef WorkerDecodeResult = ({int len, Uint8List? bytes, String? report});

/// A pending request awaiting its worker's reply.
class _Pending {
  final Completer<WorkerDecodeResult> completer;
  Timer? timer;

  /// Set when the request timed out and the caller was already released
  /// with a synthetic failure. The entry STAYS in the queue so the
  /// eventual reply still pops in order — it is then discarded. This
  /// keeps FIFO pairing intact without any echo field in the protocol
  /// (the official protocol has none).
  bool abandoned = false;

  _Pending(this.completer);
}

/// A pool of Web Workers running the OFFICIAL receiver's worker script
/// (`recv-worker.js`, the one recv.html spawns four of), each with its
/// own libcimbar WASM instance, performing the heavy per-frame work
/// (`cimbard_scan_extract_decode`).
///
/// The message protocol is recv.html's own, verbatim:
///   main -> worker : {type:'proc', pixels, format, width, height, mode}
///                    (pixels' buffer is TRANSFERRED, like recv.js)
///   worker -> main : {type:'startWasm', ready}            wasm initialized
///                    {mode, buff}                         chunks (transferred)
///                    {res, nodata?/failed_extract?/error?} nothing decoded
/// `format` is recv-worker.js's string spelling ("NV12"/"I420"/"RGB"/
/// "RGBA"); `mode` rides on every 'proc' message and the worker configures
/// its own wasm per frame — recv.js has no separate cfg message either.
///
/// Replies are reconciled per worker by ORDER (a FIFO per worker), which
/// is exactly how the official receiver keys them — by worker index, with
/// no request ids: each worker processes its messages serially, so replies
/// come back in posting order, and the sink treats every result as
/// context-free anyway.
///
/// Frames are posted with a **transferred** pixel buffer (zero copy); the
/// reply carries at most `cimbard_get_bufsize()` bytes (7.5KB in modeB) of
/// fountain chunks, transferred back the same way.
///
/// The pool degrades gracefully: if workers cannot be spawned, error out,
/// or time out repeatedly, [isOk] flips false and the caller falls back to
/// decoding on the main thread (the pre-worker behavior).
class DecodeWorkerPool {
  /// The official receiver's worker script, deployed next to the wasm
  /// glue it importScripts()es.
  static const String workerUrl = 'assets/wasm/recv-worker.js';

  /// Give up on a single decode after this long (a wedged worker would
  /// otherwise leak one pending slot per frame forever).
  static const Duration _requestTimeout = Duration(seconds: 2);

  /// Disable the pool after this many consecutive failed/timed-out decodes.
  static const int _maxConsecutiveFailures = 5;

  /// Mirrors the official receiver's stall threshold (recv.js stalls the
  /// feed when more than 20 frames are in flight).
  static const int _maxInFlight = 20;

  final List<JSObject> _workers = [];
  final List<List<_Pending>> _queues = [];
  final Set<int> _readyWorkers = {};

  int _seq = 0;
  int _nextWorker = 0;
  int _consecutiveFailures = 0;
  bool _broken = false;

  /// Number of decodes awaiting a worker reply.
  int get pending => _queues.fold(0, (n, q) => n + q.length);

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

    // Official recv.html hardcodes FOUR workers: `Recv.init_ww(4)`.
    const count = 4;

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
        _queues.add([]);
      } catch (e) {
        debugPrint('[WorkerPool] failed to spawn worker $i: $e');
      }
    }
    if (_workers.isEmpty) {
      _broken = true;
      return;
    }
    debugPrint('[WorkerPool] ${_workers.length} decode worker(s) spawned '
        '(official recv-worker.js, recv.html count), waiting for wasm init');
  }

  void _onWorkerMessage(int workerId, JSAny? ev) {
    final data = _reflectGet(ev as JSObject, 'data'.toJS) as JSObject?;
    if (data == null) return;

    // Official ready handshake: {type:'startWasm', ready:"ready!"}.
    final type = _reflectGet(data, 'type'.toJS);
    if (type is JSString && type.toDart == 'startWasm') {
      _readyWorkers.add(workerId);
      return;
    }

    // FIFO reconciliation, keyed by worker (recv.js keys by worker index
    // too). A reply always pairs with the OLDEST request still queued for
    // this worker; timed-out (abandoned) entries pop and are discarded.
    final q = _queues[workerId];
    if (q.isEmpty) return;
    final req = q.removeAt(0);
    req.timer?.cancel();

    int len;
    Uint8List? bytes;
    String? report;

    final buff = _reflectGet(data, 'buff'.toJS);
    if (buff is JSUint8Array) {
      // Official success reply {mode, buff}: the chunks are the fountain
      // payload; len = buff.length (there is no separate len field).
      len = buff.toDart.length;
      bytes = buff.toDart;
    } else {
      // Official failure reply {res, nodata?/failed_extract?/error?} —
      // `res` is the worker's `len + " " + errmsg` string.
      final rpt = _reflectGet(data, 'res'.toJS);
      report = rpt is JSString ? rpt.toDart : null;
      bool flag(String k) =>
          _reflectGet(data, k.toJS) is JSBoolean &&
          (_reflectGet(data, k.toJS) as JSBoolean).toDart;
      if (flag('nodata')) {
        len = 0;
      } else if (flag('failed_extract')) {
        len = -3;
      } else {
        final res = report ?? '';
        final sp = res.indexOf(' ');
        len = int.tryParse(sp > 0 ? res.substring(0, sp) : res) ?? -101;
      }
    }

    if (req.abandoned) return; // caller was already released by the timeout
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
    req.completer.complete((len: len, bytes: bytes, report: report));
  }

  void _markBroken() {
    _broken = true;
    // Fail every in-flight request so waiters do not hang until timeout.
    for (final q in _queues) {
      for (final req in q) {
        if (!req.abandoned && !req.completer.isCompleted) {
          req.abandoned = true;
          req.timer?.cancel();
          req.completer.complete((len: -100, bytes: null, report: 'pool-disabled'));
        }
      }
      q.clear();
    }
    terminate();
  }

  /// Post one frame to the next worker (round-robin, like recv.js).
  ///
  /// [pixels] is consumed: its underlying buffer is TRANSFERRED to the
  /// worker. Do not touch it after this call.
  ///
  /// [formatCode] is the cimbar numeric format (3/4/12/420); it travels as
  /// recv-worker.js's string spelling. [modeVal] rides on every message —
  /// the worker configures its own wasm per frame (official behavior).
  ///
  /// Returns null when the pool is saturated (mirrors the official
  /// "stalling, worker queues are full" frame drop) or not yet usable.
  Future<WorkerDecodeResult?> decode(
      Uint8List pixels, int width, int height, int formatCode, int modeVal) {
    if (_broken || pending >= _maxInFlight) return Future.value(null);

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
    final req = _Pending(completer);

    // Fallback timer: a wedged worker must not leak the pending slot.
    // The entry stays queued (abandoned) so the late reply — if the
    // worker ever produces one — still pops in FIFO order and is
    // discarded instead of mispairing with a newer request.
    req.timer = Timer(_requestTimeout, () {
      if (req.abandoned) return;
      req.abandoned = true;
      debugPrint('[WorkerPool] decode #$seq timed out');
      completer.complete((len: -100, bytes: null, report: 'timeout'));
      if (++_consecutiveFailures >= _maxConsecutiveFailures) {
        _markBroken();
      }
    });

    try {
      final w = _workers[_nextWorker];
      final q = _queues[_nextWorker];
      _nextWorker = (_nextWorker + 1) % _workers.length;

      // Official 'proc' message shape (recv.js on_frame):
      //   {type:'proc', pixels, format, width, height, mode}
      final msg = _newObject();
      _reflectSet(msg, 'type'.toJS, 'proc'.toJS);
      _reflectSet(msg, 'pixels'.toJS, view);
      _reflectSet(msg, 'format'.toJS, _formatName(formatCode).toJS);
      _reflectSet(msg, 'width'.toJS, width.toJS);
      _reflectSet(msg, 'height'.toJS, height.toJS);
      _reflectSet(msg, 'mode'.toJS, modeVal.toJS);

      final post = _reflectGet(w, 'postMessage'.toJS) as JSFunction?;
      if (post == null) throw StateError('worker postMessage missing');
      // postMessage(msg, transfer): the transfer list MUST be a JS array
      // of the buffers to detach — passing the ArrayBuffer itself makes
      // Chrome throw "The object must have a callable @@iterator".
      _reflectApply(
          post, w, <JSAny?>[msg, <JSAny?>[buffer].toJS].toJS);

      q.add(req);
    } catch (e) {
      // postMessage failed — the buffer was NOT transferred, so the pixels
      // are still valid for a main-thread fallback decode.
      req.timer?.cancel();
      debugPrint('[WorkerPool] postMessage failed: $e');
      return Future.value(null);
    }

    return completer.future;
  }

  /// recv-worker.js's string spelling of the cimbar format code.
  static String _formatName(int formatCode) => switch (formatCode) {
        12 => 'NV12',
        420 => 'I420',
        3 => 'RGB',
        _ => 'RGBA',
      };

  /// Terminate every worker. The pool is unusable afterwards.
  void terminate() {
    for (final w in _workers) {
      try {
        final term = _reflectGet(w, 'terminate'.toJS) as JSFunction?;
        term?.callAsFunction(w);
      } catch (_) {}
    }
    _workers.clear();
    _queues.clear();
    _readyWorkers.clear();
  }
}
