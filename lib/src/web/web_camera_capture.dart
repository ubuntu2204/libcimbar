// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;

import '../interfaces/camera_capture_interface.dart';
import '../models/capture_mode.dart';

// ─── JS interop declarations (top-level only) ───────────────────

@JS('navigator.mediaDevices.getUserMedia')
external JSPromise<JSAny?> _getUserMedia(JSAny constraints);

@JS('document.createElement')
external JSObject _createElement(String tagName);

@JS('Reflect.set')
external void _reflectSet(JSObject target, JSString key, JSAny? value);

@JS('Reflect.get')
external JSAny? _reflectGet(JSObject target, JSString key);

@JS('Reflect.apply')
external JSAny? _reflectApply(
    JSFunction fn, JSObject thisArg, JSArray<JSAny?> args);

@JS('Object')
external JSObject _newObject();

// Promise → Future bridge
Future<JSAny?> _jsAwait(JSPromise<JSAny?> promise) {
  final completer = Completer<JSAny?>();
  final thenFn = ((JSAny? value) {
    completer.complete(value);
  }).toJS;
  final catchFn = ((JSAny? error) {
    completer.completeError(error ?? 'Unknown error');
  }).toJS;
  // Call promise.then(thenFn, catchFn) via Reflect.apply
  final thenMethod =
      _reflectGet(promise as JSObject, 'then'.toJS) as JSFunction?;
  if (thenMethod != null) {
    _reflectApply(thenMethod, promise as JSObject, [thenFn, catchFn].toJS);
  } else {
    completer.completeError('Promise has no .then method');
  }
  return completer.future;
}

// ─── WebCameraCapture implementation ─────────────────────────────

/// Web camera capture using getUserMedia API.
class WebCameraCapture implements ICameraCapture {
  JSObject? _video;
  JSObject? _ctx;
  JSObject? _stream;
  Timer? _frameTimer;
  CameraFrameCallback? _callback;
  bool _streaming = false;
  String? _viewType;

  int _videoWidth = 0;
  int _videoHeight = 0;

  /// Default capture cadence (~5 fps). Can be overridden via [start].
  static const int _defaultFrameIntervalMs = 200; // ~5 fps

  /// Square size used before the camera resolution is known.
  static const int _fallbackTargetSize = 1024;

  /// Upper bound for the square decoder input, to cap per-frame CPU/memory.
  ///
  /// Raised from 1600: a barcode photographed from across the room only fills
  /// a fraction of the view, so shrinking the frame to 1600 left it below the
  /// ~1024 px needed per barcode and the anchor scan failed. 2048 keeps the
  /// barcode above that threshold while bounding per-frame cost (~12.6 MB
  /// RGBA per frame at 5 fps).
  static const int _maxTargetSize = 2048;

  /// Side length (px) of the square frame handed to the decoder.
  ///
  /// Chosen once the camera resolution is known (see [_computeTargetSize]):
  /// for [WebCaptureMode.centerCrop] it tracks the cropped square (the shorter
  /// video side) so the barcode keeps its native detail instead of being
  /// downscaled to a fixed 1024. Capped by [_maxTargetSize].
  int _targetSize = _fallbackTargetSize;

  /// Current capture cadence in milliseconds (driven by [start]).
  int _frameIntervalMs = _defaultFrameIntervalMs;

  /// How the video frame is mapped into the square decoder input.
  ///
  /// Defaults to [WebCaptureMode.fit]: the entire camera frame is letterboxed
  /// into the decoder input, so all four corner anchors are ALWAYS in view
  /// regardless of where the monitor/barcode sits in the camera view. This is
  /// the safe choice when the phone is hand-held — the monitor rarely ends up
  /// centered in the frame, and a center crop will cut the top or bottom of
  /// the barcode (losing two anchors and breaking the scan). `alternate` and
  /// `centerCrop` are kept available for setups where the subject is reliably
  /// centered and every extra pixel matters.
  WebCaptureMode captureMode = WebCaptureMode.fit;

  /// Upper bound for the square decoder input, in pixels.
  ///
  /// Higher keeps more of the barcode's detail (better anchoring when the
  /// barcode is small in frame) at the cost of per-frame CPU/memory. Lower it
  /// on devices where the scan step cannot keep up with the capture cadence.
  int maxTargetSize = _maxTargetSize;

  /// Counts delivered frames; drives the [WebCaptureMode.alternate] flip.
  int _frameCounter = 0;

  @override
  bool get isSupported => true;

  @override
  bool get isStreaming => _streaming;

  /// Platform view type for embedding the video element.
  String? get viewType => _viewType;

  /// Actual camera resolution reported by getUserMedia (0 until [start]).
  /// Useful for diagnostics: shows what the camera really delivered vs the
  /// preferred/requested size.
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;

  /// Side length (px) of the square frame handed to the decoder.
  int get decoderInputSize => _targetSize;

  @override
  Future<void> start({
    int preferredWidth = 1024,
    int preferredHeight = 1024,
    int frameIntervalMs = _defaultFrameIntervalMs,
  }) async {
    if (_streaming) return;

    _frameIntervalMs =
        frameIntervalMs <= 0 ? _defaultFrameIntervalMs : frameIntervalMs;

    // Build getUserMedia constraints
    final constraints = _buildConstraints(preferredWidth, preferredHeight);

    // Request camera access
    final stream = await _jsAwait(_getUserMedia(constraints));
    _stream = stream as JSObject;

    // Create video element
    final video = _createElement('video');
    _setProp(video, 'autoplay', true.toJS);
    _setProp(video, 'muted', true.toJS);
    _setProp(video, 'playsInline', true.toJS);
    _setProp(video, 'srcObject', stream);
    // Style the video element to fill its container. `contain` (not `cover`)
    // so the preview shows the ENTIRE camera frame — what you see is what the
    // decoder receives; `cover` would hide the edges and let the barcode
    // drift out of the captured frame unnoticed.
    _setProp(video, 'style',
        'width:100%;height:100%;object-fit:contain;background:#000;'.toJS);
    _video = video;

    // Listen for loadedmetadata
    final completer = Completer<void>();
    void onLoadedMetadata(JSObject event) {
      if (!completer.isCompleted) completer.complete();
    }

    final addListener =
        _reflectGet(video, 'addEventListener'.toJS) as JSFunction?;
    addListener?.callAsFunction(
        video, 'loadedmetadata'.toJS, onLoadedMetadata.toJS);

    // Start playback
    final playFn = _reflectGet(video, 'play'.toJS) as JSFunction?;
    playFn?.callAsFunction(video);

    // Timeout fallback
    Timer(const Duration(seconds: 10), () {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;

    // Get dimensions
    _videoWidth = _getIntProp(video, 'videoWidth') ?? preferredWidth;
    _videoHeight = _getIntProp(video, 'videoHeight') ?? preferredHeight;

    // Size the square decoder input from the actual camera resolution so we
    // don't throw away detail by hard-scaling every frame down to 1024.
    _targetSize = _computeTargetSize(_videoWidth, _videoHeight);
    debugPrint('[Camera] video ${_videoWidth}x$_videoHeight, '
        'mode=${captureMode.name}, decoder input ${_targetSize}x$_targetSize');

    // Create the offscreen canvas at the chosen target size.
    final canvas = _createElement('canvas');
    _setProp(canvas, 'width', _targetSize.toJS);
    _setProp(canvas, 'height', _targetSize.toJS);
    final getCtx = _reflectGet(canvas, 'getContext'.toJS) as JSFunction?;
    _ctx = getCtx?.callAsFunction(canvas, '2d'.toJS) as JSObject?;

    // Register video element as a Flutter platform view
    _viewType = 'libcimbar-camera-${DateTime.now().millisecondsSinceEpoch}';
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType!,
      (int viewId) => video,
    );

    _streaming = true;
    _frameTimer = Timer.periodic(
      Duration(milliseconds: _frameIntervalMs),
      (_) => _captureFrame(),
    );
  }

  JSObject _buildConstraints(int width, int height) {
    final obj = _newObject();
    final video = _newObject();

    final widthObj = _newObject();
    _setProp(widthObj, 'ideal', width.toJS);
    _setProp(video, 'width', widthObj);

    final heightObj = _newObject();
    _setProp(heightObj, 'ideal', height.toJS);
    _setProp(video, 'height', heightObj);

    _setProp(video, 'facingMode', 'environment'.toJS);
    _setProp(obj, 'video', video);
    _setProp(obj, 'audio', false.toJS);
    return obj;
  }

  /// Pick the square decoder-input size from the camera resolution.
  ///
  /// centerCrop/alternate use the largest centered square (the shorter side);
  /// pure fit maps the whole frame in, so we key off the longer side. Clamped
  /// to [_fallbackTargetSize] .. [_maxTargetSize].
  int _computeTargetSize(int vw, int vh) {
    if (vw <= 0 || vh <= 0) return _fallbackTargetSize;
    final base =
        captureMode == WebCaptureMode.fit ? math.max(vw, vh) : math.min(vw, vh);
    return base.clamp(_fallbackTargetSize, maxTargetSize);
  }

  void _setProp(JSObject obj, String key, JSAny? value) {
    _reflectSet(obj, key.toJS, value);
  }

  int? _getIntProp(JSObject obj, String key) {
    final val = _reflectGet(obj, key.toJS);
    if (val == null) return null;
    // Try converting to int
    try {
      return (val as JSNumber).toDartInt;
    } catch (_) {
      return null;
    }
  }

  void _captureFrame() {
    if (!_streaming || _callback == null || _video == null || _ctx == null) {
      return;
    }

    final video = _video!;
    final ctx = _ctx!;

    final vw = _getIntProp(video, 'videoWidth') ?? _videoWidth;
    final vh = _getIntProp(video, 'videoHeight') ?? _videoHeight;
    if (vw <= 0 || vh <= 0) return;

    // Square decoder input size (chosen from camera resolution in start()).
    final targetSize = _targetSize;

    // Resolve the effective mapping for THIS frame. In alternate mode we flip
    // between centerCrop (big barcode, may chop off-center anchors) and fit
    // (whole frame visible, smaller barcode) so at least one framing can
    // satisfy the 4-anchor scan.
    var mode = captureMode;
    if (mode == WebCaptureMode.alternate) {
      mode =
          _frameCounter.isEven ? WebCaptureMode.centerCrop : WebCaptureMode.fit;
    }
    _frameCounter++;
    if (_frameCounter % 50 == 1) {
      debugPrint('[Camera] frame #$_frameCounter mode=${mode.name} '
          '(configured=${captureMode.name}, video ${vw}x$vh -> '
          '${targetSize}x$targetSize)');
    }

    // Source rect (region of the video) and dest rect (region of the canvas).
    int sx, sy, sw, sh; // source
    int dx, dy, dw, dh; // destination
    if (mode == WebCaptureMode.centerCrop) {
      // Largest centered square, scaled to fill the whole canvas.
      final cropSize = vw < vh ? vw : vh;
      sx = (vw - cropSize) ~/ 2;
      sy = (vh - cropSize) ~/ 2;
      sw = sh = cropSize;
      dx = dy = 0;
      dw = dh = targetSize;
    } else {
      // Fit the ENTIRE frame into the square, preserving aspect ratio.
      // The whole barcode (and all four anchors) stays visible even when it
      // is not perfectly centered in the camera view.
      sx = sy = 0;
      sw = vw;
      sh = vh;
      final scale = targetSize / math.max(vw, vh);
      dw = (vw * scale).round().clamp(1, targetSize);
      dh = (vh * scale).round().clamp(1, targetSize);
      dx = (targetSize - dw) ~/ 2;
      dy = (targetSize - dh) ~/ 2;
    }

    // Clear the canvas to solid black so letterbox borders are well-defined
    // (a uniform fill won't be mistaken for cimbar anchor patterns).
    final fillRect = _reflectGet(ctx, 'fillRect'.toJS) as JSFunction?;
    if (fillRect != null) {
      _setProp(ctx, 'fillStyle', '#000000'.toJS);
      _reflectApply(fillRect, ctx,
          [0.toJS, 0.toJS, targetSize.toJS, targetSize.toJS].toJS);
    }

    // Draw the (cropped or fitted) region — do NOT resize canvas here.
    final drawImage = _reflectGet(ctx, 'drawImage'.toJS) as JSFunction?;
    if (drawImage != null) {
      final args = [
        video,
        sx.toJS, sy.toJS, sw.toJS, sh.toJS, // source rect
        dx.toJS, dy.toJS, dw.toJS, dh.toJS, // dest rect
      ].toJS;
      _reflectApply(drawImage, ctx, args);
    }

    // Get cropped pixel data
    final getImageData = _reflectGet(ctx, 'getImageData'.toJS) as JSFunction?;
    final imageData = getImageData?.callAsFunction(
        ctx, 0.toJS, 0.toJS, targetSize.toJS, targetSize.toJS) as JSObject?;
    if (imageData == null) return;

    final jsData = _reflectGet(imageData, 'data'.toJS);
    if (jsData == null) return;

    final clampedArray = jsData as JSUint8ClampedArray;
    final rgbaPixels = Uint8List.fromList(clampedArray.toDart);

    // Strip the alpha channel here and hand the decoder RGB (format 3).
    //
    // The WASM build's RGBA->RGB conversion path (getUMat + cvtColor with
    // COLOR_RGBA2RGB) is unreliable on Emscripten — the OpenCV.js backend
    // falls back to a Mat path that mangles 4-channel data, and the anchor
    // scanner then reports 0 anchors on frames that decode perfectly when
    // the same data is fed to the native FFI. The Dart loop below is the
    // only reliable way to hand RGB to WASM; at 2048x2048 it costs ~50-80 ms
    // per frame, which is acceptable at the 5 fps default capture rate.
    final pixelCount = targetSize * targetSize;
    final rgbPixels = Uint8List(pixelCount * 3);
    for (int i = 0; i < pixelCount; i++) {
      rgbPixels[i * 3] = rgbaPixels[i * 4];
      rgbPixels[i * 3 + 1] = rgbaPixels[i * 4 + 1];
      rgbPixels[i * 3 + 2] = rgbaPixels[i * 4 + 2];
    }

    _callback!(CameraFrame(
      data: rgbPixels,
      width: targetSize,
      height: targetSize,
      format: 'rgb',
      timestampUs: DateTime.now().microsecondsSinceEpoch,
    ));
  }

  @override
  void onFrame(CameraFrameCallback callback) {
    _callback = callback;
  }

  @override
  Future<void> stop() async {
    _frameTimer?.cancel();
    _frameTimer = null;

    if (_video != null) {
      final pauseFn = _reflectGet(_video!, 'pause'.toJS) as JSFunction?;
      pauseFn?.callAsFunction(_video!);
      _setProp(_video!, 'srcObject', null);
    }

    if (_stream != null) {
      try {
        final getTracks =
            _reflectGet(_stream!, 'getTracks'.toJS) as JSFunction?;
        final tracks = getTracks?.callAsFunction(_stream!) as JSObject?;
        if (tracks != null) {
          final length = _getIntProp(tracks, 'length') ?? 0;
          for (int i = 0; i < length; i++) {
            final track = _reflectGet(tracks, '$i'.toJS) as JSObject?;
            if (track != null) {
              final stopFn = _reflectGet(track, 'stop'.toJS) as JSFunction?;
              stopFn?.callAsFunction(track);
            }
          }
        }
      } catch (_) {}
      _stream = null;
    }

    _video = null;
    _ctx = null;
    _viewType = null;
    _streaming = false;
  }

  @override
  Future<void> dispose() async {
    _callback = null;
    await stop();
  }
}
