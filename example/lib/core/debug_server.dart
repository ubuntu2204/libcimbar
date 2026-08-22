// Network debug interface for real-time encoder/decoder alignment.
//
// Repeated "camera can't find anchors" sessions are hard to debug blind:
// we cannot tell whether the fault is in the decode pipeline or in the
// camera capture. This tiny HTTP server lets the decoder talk to the
// encoder directly over LAN:
//
//   GET  /status      -> encoder state as JSON (mode, fps, frame count...)
//   GET  /frame.png   -> the CURRENTLY DISPLAYED cimbar frame, lossless PNG.
//                        The decoder can decode these pristine frames to
//                        verify the whole WASM pipeline without any camera.
//   POST /captured    -> decoder uploads its captured camera frame (PNG);
//                        saved date-prefixed for side-by-side comparison.
//   POST /report      -> decoder uploads its diagnostic report (text).
//   POST /encode-test -> encode the deterministic test payload (async).
//   POST /decode-test -> run the screenshot decode self-test; the response
//                        carries the final PASS/FAIL summary. Lets scripts
//                        verify the full encode→display→capture→decode
//                        roundtrip with zero UI interaction.
//
// All responses carry permissive CORS headers so the Flutter-web decoder
// (different origin) can call them. Windows Firewall may prompt once to
// allow inbound connections on the port.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart' show Uint8List, debugPrint;
import 'package:image/image.dart' as img;
import 'package:libcimbar/libcimbar.dart' show CimbarFrame;
import 'package:path_provider/path_provider.dart';

class DebugServer {
  DebugServer._();
  static final DebugServer instance = DebugServer._();

  HttpServer? _server;

  /// Supplies the frame currently on screen (null until encode & display).
  CimbarFrame? Function()? frameProvider;

  /// Supplies the /status JSON payload.
  Map<String, Object?> Function()? statusProvider;

  /// Starts a test-payload encode when POST /encode-test is called — lets
  /// scripts drive the whole encode->pull->decode loop with no UI clicks.
  /// Returns a short human-readable result.
  Future<String> Function()? onEncodeTest;

  /// Runs the screenshot decode self-test when POST /decode-test is called —
  /// scripts can verify the whole encode→display→capture→decode roundtrip
  /// (byte-exact) with no UI interaction. Returns the final PASS/FAIL
  /// summary. May take a while: it captures and decodes frames until the
  /// fountain stream completes.
  Future<String> Function()? onDecodeTest;

  // PNG cache: polls are usually faster than the display frame rate, so
  // avoid re-encoding the same frame over and over.
  int _cachedIndex = -1;
  Uint8List? _cachedPng;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;

  /// When the decoder last talked to us (any request except CORS preflight).
  /// Drives the encoder-side "decoder linked" green light.
  DateTime? lastPeerRequestAt;

  /// Bind on all IPv4 interfaces. Returns the reachable URL(s), or null on
  /// failure (e.g. port already in use).
  Future<String?> start({int port = 8765}) async {
    if (_server != null) return describeEndpoints();
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server!.listen(_handle,
          onError: (Object e) => debugPrint('[DebugServer] listen error: $e'));
      final eps = await describeEndpoints();
      debugPrint('[DebugServer] listening on $eps');
      return eps;
    } catch (e) {
      debugPrint('[DebugServer] bind failed: $e');
      return null;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// URL(s) the decoder can reach, e.g. `http://192.168.1.5:8765`.
  /// Localhost first: when the decoder runs on the same machine (the local
  /// Linux debug loop) it should always use 127.0.0.1.
  Future<String> describeEndpoints() async {
    final srv = _server;
    if (srv == null) return '(not running)';
    final urls = <String>['http://127.0.0.1:${srv.port}'];
    try {
      final ifaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final ni in ifaces) {
        for (final a in ni.addresses) {
          if (!a.isLoopback) urls.add('http://${a.address}:${srv.port}');
        }
      }
    } catch (_) {}
    return urls.join('  ');
  }

  // ─── Request handling ─────────────────────────────────────────

  void _cors(HttpResponse res) {
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.headers.set('Access-Control-Allow-Headers', 'Content-Type');
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    _cors(res);
    if (req.method != 'OPTIONS') lastPeerRequestAt = DateTime.now();
    try {
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
      } else if (req.method == 'GET' && req.uri.path == '/status') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(
            statusProvider?.call() ?? <String, Object?>{'ready': false}));
      } else if (req.method == 'GET' && req.uri.path == '/frame.png') {
        final png = _currentFramePng();
        if (png == null) {
          res.statusCode = HttpStatus.notFound;
          res.write('no frame yet - encode & display first');
        } else {
          res.headers.contentType = ContentType('image', 'png');
          res.headers.set('Cache-Control', 'no-store');
          res.add(png);
        }
      } else if (req.method == 'POST' && req.uri.path == '/captured') {
        final path =
            await _saveUpload('_remote_capture.png', await _readBody(req));
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'saved': path}));
      } else if (req.method == 'POST' && req.uri.path == '/report') {
        final path = await _saveUpload(
            '_remote_decode_report.txt', await _readBody(req));
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'saved': path}));
      } else if (req.method == 'POST' && req.uri.path == '/encode-test') {
        final hook = onEncodeTest;
        if (hook == null) {
          res.statusCode = HttpStatus.serviceUnavailable;
          res.write('encoder page not ready');
        } else {
          // Fire and forget: encoding 200 frames takes a while; callers poll
          // GET /status until `frames` > 0.
          unawaited(hook().then(
              (r) => debugPrint('[DebugServer] encode-test done: $r'),
              onError: (Object e) =>
                  debugPrint('[DebugServer] encode-test failed: $e')));
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'started': true}));
        }
      } else if (req.method == 'POST' && req.uri.path == '/decode-test') {
        final hook = onDecodeTest;
        if (hook == null) {
          res.statusCode = HttpStatus.serviceUnavailable;
          res.write('encoder page not ready');
        } else {
          // Awaited: the response carries the final PASS/FAIL summary.
          // Capturing + decoding takes seconds to a minute depending on
          // frame count.
          final summary = await hook();
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'result': summary}));
        }
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } catch (e) {
      debugPrint('[DebugServer] handler error: $e');
      try {
        res.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<Uint8List> _readBody(HttpRequest req) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in req) {
      b.add(chunk);
    }
    return b.takeBytes();
  }

  /// Encode the currently displayed frame to PNG (lossless ground truth).
  Uint8List? _currentFramePng() {
    final frame = frameProvider?.call();
    if (frame == null) return null;
    if (frame.index == _cachedIndex && _cachedPng != null) return _cachedPng;
    final im = img.Image.fromBytes(
      width: frame.width,
      height: frame.height,
      bytes: frame.pixels.buffer,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );
    _cachedPng = Uint8List.fromList(img.encodePng(im));
    _cachedIndex = frame.index;
    return _cachedPng;
  }

  /// Save an uploaded artifact with the project's date-first naming.
  Future<String?> _saveUpload(String suffix, Uint8List body) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = '${appDir.path}/libcimbar_screenshots';
      await Directory(dir).create(recursive: true);
      final n = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final ts = '${n.year}${two(n.month)}${two(n.day)}_'
          '${two(n.hour)}${two(n.minute)}${two(n.second)}';
      final path = '$dir/$ts$suffix';
      await File(path).writeAsBytes(body);
      debugPrint('[DebugServer] saved upload: $path (${body.length} bytes)');
      return path;
    } catch (e) {
      debugPrint('[DebugServer] saveUpload failed: $e');
      return null;
    }
  }
}
