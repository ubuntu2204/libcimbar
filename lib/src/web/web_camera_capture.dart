// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert' show base64Decode;
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

  /// The offscreen canvas itself (not just its context).
  ///
  /// Needed as the *source* when re-drawing a cropped region back into the
  /// canvas: `ctx.drawImage(...)` accepts only image sources (canvas/video/
  /// image elements), never a 2D context.
  JSObject? _canvas;
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
    _canvas = canvas;

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
    if (imageData == null) {
      // Without this the frame is dropped in silence and the UI just says
      // "no frame captured yet" while the preview looks perfectly fine.
      debugPrint('[Camera] getImageData returned null — frame dropped');
      return;
    }

    final jsData = _reflectGet(imageData, 'data'.toJS);
    if (jsData == null) {
      debugPrint('[Camera] imageData.data missing — frame dropped');
      return;
    }

    final clampedArray = jsData as JSUint8ClampedArray;
    final rgbaPixels = Uint8List.fromList(clampedArray.toDart);

    // ----- Auto-crop to the cimbar region -----
    //
    // The raw camera frame often has a lot of wasted background (e.g. a
    // portrait phone photographing a monitor on a desk: large black bars
    // on the sides, the wall above, the desk below). Without cropping, all
    // that space gets upscaled into the 2048x2048 decoder input — the
    // cimbar ends up at ~30% of the frame and the scanner's anchor search
    // window has to traverse thousands of useless black pixels.
    //
    // A quick stride scan for saturated/colored pixels (the cimbar's
    // bright cells) finds the actual barcode bounding box. If that box is
    // much smaller than the canvas, we redraw only the cropped + upscaled
    // content into the canvas, then proceed as before.
    //
    // At stride=16, a 2048x2048 canvas samples ~16K pixels — well under
    // a frame budget.
    Uint8List rgbaForDecoder = rgbaPixels;
    int frameW = targetSize, frameH = targetSize;
    // The whole auto-crop step is best-effort. It is only an optimisation,
    // so any failure here must never stop the frame from reaching the
    // decoder — a thrown exception used to silently kill every capture.
    try {
      const int stride = 16;
      const int satThresh = 50;
      int minX = targetSize, minY = targetSize, maxX = -1, maxY = -1;
      for (int y = 0; y < targetSize; y += stride) {
        final rowBase = y * targetSize * 4;
        for (int x = 0; x < targetSize; x += stride) {
          final i = rowBase + x * 4;
          final r = rgbaPixels[i];
          final g = rgbaPixels[i + 1];
          final b = rgbaPixels[i + 2];
          final int mn = r < g
              ? (r < b ? r : b)
              : (g < b ? g : b);
          final int mx = r > g
              ? (r > b ? r : b)
              : (g > b ? g : b);
          if (mx - mn >= satThresh) {
            if (x < minX) minX = x;
            if (y < minY) minY = y;
            if (x > maxX) maxX = x;
            if (y > maxY) maxY = y;
          }
        }
      }
      if (maxX >= minX && maxY >= minY) {
        // Pad the bbox by one stride in each direction so the upscaled
        // crop preserves a few pixels of dark margin around the barcode
        // (helps the Otsu threshold near the edges).
        minX = (minX - stride).clamp(0, targetSize - 1);
        minY = (minY - stride).clamp(0, targetSize - 1);
        maxX = (maxX + stride).clamp(0, targetSize - 1);
        maxY = (maxY + stride).clamp(0, targetSize - 1);
        final bboxW = maxX - minX + 1;
        final bboxH = maxY - minY + 1;
        final bboxArea = bboxW * bboxH;
        final canvasArea = targetSize * targetSize;
        // Only crop when the bbox is meaningfully smaller than the canvas —
        // for a tightly framed capture the bbox spans most of the canvas
        // and cropping would lose no overhead.
        if (bboxArea < canvasArea * 7 ~/ 10 &&
            _canvas != null &&
            drawImage != null) {
          // Redraw the cropped + upscaled region back into the canvas.
          //
          // The first argument must be an *image source* (here the canvas
          // element itself) — passing the 2D context instead makes the
          // browser throw a TypeError, which used to abort the whole
          // capture so no frame ever reached the decoder (the camera
          // preview still showed a picture, so it looked like it worked).
          final drawArgs = [
            _canvas!,
            minX.toJS, minY.toJS, bboxW.toJS, bboxH.toJS,
            0.toJS, 0.toJS, targetSize.toJS, targetSize.toJS,
          ].toJS;
          _reflectApply(drawImage, ctx, drawArgs);
          // Re-read the canvas.
          final imageData2 = getImageData?.callAsFunction(
              ctx, 0.toJS, 0.toJS, targetSize.toJS, targetSize.toJS)
              as JSObject?;
          if (imageData2 != null) {
            final jsData2 = _reflectGet(imageData2, 'data'.toJS);
            if (jsData2 != null) {
              rgbaForDecoder = Uint8List.fromList(
                  (jsData2 as JSUint8ClampedArray).toDart);
            }
          }
        }
      }
    } catch (e) {
      // Auto-crop is purely an optimisation — never let it stop a frame
      // from reaching the decoder. Fall back to the uncropped pixels so
      // capture keeps working even if this path breaks.
      debugPrint('[Camera] auto-crop failed, using full frame: $e');
      rgbaForDecoder = rgbaPixels;
    }

    // Strip the alpha channel here and hand the decoder RGB (format 3).
    //
    // The WASM build's RGBA->RGB conversion path (getUMat + cvtColor with
    // COLOR_RGBA2RGB) is unreliable on Emscripten — the OpenCV.js backend
    // falls back to a Mat path that mangles 4-channel data, and the anchor
    // scanner then reports 0 anchors on frames that decode perfectly when
    // the same data is fed to the native FFI. The Dart loop below is the
    // only reliable way to hand RGB to WASM; at 2048x2048 it costs ~50-80 ms
    // per frame, which is acceptable at the 5 fps default capture rate.
    final pixelCount = frameW * frameH;
    final rgbPixels = Uint8List(pixelCount * 3);
    for (int i = 0; i < pixelCount; i++) {
      rgbPixels[i * 3] = rgbaForDecoder[i * 4];
      rgbPixels[i * 3 + 1] = rgbaForDecoder[i * 4 + 1];
      rgbPixels[i * 3 + 2] = rgbaForDecoder[i * 4 + 2];
    }

    _callback!(CameraFrame(
      data: rgbPixels,
      width: frameW,
      height: frameH,
      format: 'rgb',
      timestampUs: DateTime.now().microsecondsSinceEpoch,
    ));
  }

  /// Grab the RAW camera frame exactly as the sensor delivered it — no
  /// cropping, no scaling, no RGBA→RGB conversion, no auto-crop.
  ///
  /// This is the ground truth for "what did the camera actually see".
  /// Comparing it against the processed frame handed to the decoder is what
  /// tells you whether a failure is a framing/scale problem (the raw shot
  /// looks fine but the crop cut the anchors) or a genuine decode problem
  /// (the raw shot itself is blurry / too small / badly lit).
  ///
  /// Returns PNG bytes, or null if the video is not ready.
  Future<Uint8List?> captureRawFramePng() async {
    final video = _video;
    if (video == null) return null;
    final vw = _getIntProp(video, 'videoWidth') ?? _videoWidth;
    final vh = _getIntProp(video, 'videoHeight') ?? _videoHeight;
    if (vw <= 0 || vh <= 0) return null;

    // Canvas at the camera's native resolution (e.g. 2176x3840).
    final canvas = _createElement('canvas');
    _setProp(canvas, 'width', vw.toJS);
    _setProp(canvas, 'height', vh.toJS);
    final getCtx = _reflectGet(canvas, 'getContext'.toJS) as JSFunction?;
    final ctx = getCtx?.callAsFunction(canvas, '2d'.toJS) as JSObject?;
    if (ctx == null) return null;

    final drawImage = _reflectGet(ctx, 'drawImage'.toJS) as JSFunction?;
    if (drawImage == null) return null;
    _reflectApply(
        drawImage, ctx, [video, 0.toJS, 0.toJS, vw.toJS, vh.toJS].toJS);

    final toDataURL = _reflectGet(canvas, 'toDataURL'.toJS) as JSFunction?;
    if (toDataURL == null) return null;
    final url = toDataURL.callAsFunction(canvas, 'image/png'.toJS) as JSString?;
    if (url == null) return null;
    final dataUrl = url.toDart;
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return null;
    return base64Decode(dataUrl.substring(comma + 1));
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
    _canvas = null;
    _viewType = null;
    _streaming = false;
  }

  @override
  Future<void> dispose() async {
    _callback = null;
    await stop();
  }
}
