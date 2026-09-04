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
///
/// The pipeline mirrors the official Android decoder (sz3/cfc,
/// `OpencvCameraView` + `MultiThreadedDecoder`) as closely as the browser
/// allows:
///
///  1. **1080p-class capture.** cfc's `bestCameraFrameSize` only accepts
///     preview sizes whose short edge is in [960, 1080]. We request
///     1920x1080 (`ideal`) and, if the camera delivers more, downscale the
///     frame ONCE so the short edge is [maxTargetSize] (default 1080).
///     A camera that delivers less is used as-is — upscaling adds no
///     information and the interpolation blur is what used to destroy the
///     corner anchors.
///  2. **Full frame, zero cropping.** cfc hands the entire upright RGBA
///     frame to the decoder; the Scanner searches the whole frame for the
///     4 corner anchors and the Deskewer's homography normalises the
///     barcode to its fixed size (rotation, perspective AND scale). There
///     is no center-crop and no auto-crop — both could slice anchors off
///     an off-centre barcode, and every extra resampling step blurred the
///     cell grid. Verified offline against the WASM build: a 1024px
///     barcode anywhere in a 1920x1080 frame decodes, and an 800px
///     barcode still decodes (the deskew upscale handles it); ~700px is
///     the practical anchor-detection floor at 1080p.
///  3. **RGB pixels to the decoder.** The frame is read back with
///     getImageData and the alpha channel stripped in Dart — the WASM
///     build's own RGBA->RGB conversion (getUMat + cvtColor) is
///     unreliable on Emscripten, so format 3 (RGB) is the proven input.
///
/// What you see in the preview is exactly what the decoder receives.
class WebCameraCapture implements ICameraCapture {
  JSObject? _video;
  JSObject? _ctx;
  JSObject? _stream;

  /// Persistent canvas holding the RAW camera frame at native resolution.
  ///
  /// Frames are blitted here on demand (see [captureRawFramePng]), so the
  /// unprocessed image is still available AFTER the camera is stopped
  /// ([_video] is nulled on stop, which is exactly why the raw capture
  /// used to be missing whenever 截图 was pressed after stopping a scan).
  JSObject? _rawCanvas;
  JSObject? _rawCtx;
  Timer? _frameTimer;
  CameraFrameCallback? _callback;
  bool _streaming = false;
  String? _viewType;

  int _videoWidth = 0;
  int _videoHeight = 0;

  /// Decode-canvas dimensions (after the optional single downscale).
  int _canvasWidth = 0;
  int _canvasHeight = 0;

  /// Default capture cadence (~5 fps). Can be overridden via [start].
  static const int _defaultFrameIntervalMs = 200; // ~5 fps

  /// Short-edge cap for the decode input, matching cfc's camera
  /// resolution policy (preview short edge must be within [960, 1080]).
  static const int _defaultMaxShortEdge = 1080;

  /// Current capture cadence in milliseconds (driven by [start]).
  int _frameIntervalMs = _defaultFrameIntervalMs;

  /// Short-edge cap (px) for the frame handed to the decoder.
  ///
  /// Frames whose short edge exceeds this are downscaled once so the
  /// short edge equals the cap; smaller frames pass through at native
  /// resolution (never upscaled). Defaults to 1080, matching the official
  /// Android decoder. Raise it only if the scanner cannot keep up — a
  /// bigger frame costs CPU without adding decodable detail.
  int maxTargetSize = _defaultMaxShortEdge;

  /// Ignored: the web pipeline now always scans the full frame, like the
  /// official Android decoder. Kept only so existing callers (the shared
  /// decoder page writes this via `as dynamic`) do not break.
  @Deprecated('Full-frame scanning is always on (cfc-style); this is a no-op.')
  WebCaptureMode captureMode = WebCaptureMode.centerCrop;

  /// Ignored: the web pipeline no longer crops at all — the Scanner finds
  /// the barcode anywhere in the full frame. See [captureMode].
  @Deprecated('Full-frame scanning is always on (cfc-style); this is a no-op.')
  bool autoCropEnabled = true;

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

  /// Dimensions of the frame handed to the decoder (after the optional
  /// single downscale to [maxTargetSize] short edge).
  int get decoderInputWidth => _canvasWidth;
  int get decoderInputHeight => _canvasHeight;

  /// Long-edge size of the decoder input. Kept for callers that predate
  /// the full-frame pipeline (the decoder input used to be square).
  @Deprecated('Use decoderInputWidth/decoderInputHeight instead.')
  int get decoderInputSize => math.max(_canvasWidth, _canvasHeight);

  @override
  Future<void> start({
    int preferredWidth = 1920,
    int preferredHeight = 1080,
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
    // so the preview shows the ENTIRE camera frame — what you see is what
    // the decoder receives; `cover` would hide the edges and let the
    // barcode drift out of the captured frame unnoticed.
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

    // Size the decode canvas: full frame at native resolution, downscaled
    // ONCE if the short edge exceeds the cap (cfc caps its preview at
    // 1080p — more pixels only slow the scanner down). Never upscaled.
    final cap = maxTargetSize > 0 ? maxTargetSize : _defaultMaxShortEdge;
    final shortEdge = math.min(_videoWidth, _videoHeight);
    if (shortEdge > cap) {
      final scale = cap / shortEdge;
      _canvasWidth = math.max(1, (_videoWidth * scale).round());
      _canvasHeight = math.max(1, (_videoHeight * scale).round());
    } else {
      _canvasWidth = _videoWidth;
      _canvasHeight = _videoHeight;
    }
    debugPrint('[Camera] video ${_videoWidth}x$_videoHeight, '
        'decoder input ${_canvasWidth}x$_canvasHeight (full frame)');

    // Create the offscreen canvas at the chosen size.
    final canvas = _createElement('canvas');
    _setProp(canvas, 'width', _canvasWidth.toJS);
    _setProp(canvas, 'height', _canvasHeight.toJS);
    final getCtx = _reflectGet(canvas, 'getContext'.toJS) as JSFunction?;
    _ctx = getCtx?.callAsFunction(canvas, '2d'.toJS) as JSObject?;

    // Persistent raw canvas at the camera's native resolution (e.g.
    // 2176x3840). Blitted on demand so the untouched image stays
    // available for 截图 even after the camera has been stopped.
    final rawCanvas = _createElement('canvas');
    _setProp(rawCanvas, 'width', _videoWidth.toJS);
    _setProp(rawCanvas, 'height', _videoHeight.toJS);
    final rawGetCtx = _reflectGet(rawCanvas, 'getContext'.toJS) as JSFunction?;
    _rawCanvas = rawCanvas;
    _rawCtx = rawGetCtx?.callAsFunction(rawCanvas, '2d'.toJS) as JSObject?;

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

    final cw = _canvasWidth;
    final ch = _canvasHeight;
    if (cw <= 0 || ch <= 0) return;

    // Draw the FULL frame — no crop, no letterbox, aspect preserved.
    // When the canvas matches the video this is a 1:1 blit (no resampling
    // at all, exactly like cfc handing the camera Mat to its decoder);
    // otherwise it is the single downscale to the 1080p-class cap.
    final drawImage = _reflectGet(ctx, 'drawImage'.toJS) as JSFunction?;
    if (drawImage != null) {
      _reflectApply(drawImage, ctx,
          [video, 0.toJS, 0.toJS, cw.toJS, ch.toJS].toJS);
    }

    // Get pixel data
    final getImageData = _reflectGet(ctx, 'getImageData'.toJS) as JSFunction?;
    final imageData = getImageData?.callAsFunction(
        ctx, 0.toJS, 0.toJS, cw.toJS, ch.toJS) as JSObject?;
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
    final rgbaPixels = clampedArray.toDart;

    // Strip the alpha channel here and hand the decoder RGB (format 3).
    //
    // The WASM build's RGBA->RGB conversion path (getUMat + cvtColor with
    // COLOR_RGBA2RGB) is unreliable on Emscripten — the OpenCV.js backend
    // falls back to a Mat path that mangles 4-channel data, and the anchor
    // scanner then reports 0 anchors on frames that decode perfectly when
    // the same data is fed to the native FFI. The Dart loop below is the
    // only reliable way to hand RGB to WASM; at 1920x1080 it costs
    // ~30-60 ms per frame, which is acceptable at the 5 fps default
    // capture rate.
    final pixelCount = cw * ch;
    final rgbPixels = Uint8List(pixelCount * 3);
    for (int i = 0; i < pixelCount; i++) {
      rgbPixels[i * 3] = rgbaPixels[i * 4];
      rgbPixels[i * 3 + 1] = rgbaPixels[i * 4 + 1];
      rgbPixels[i * 3 + 2] = rgbaPixels[i * 4 + 2];
    }

    _callback!(CameraFrame(
      data: rgbPixels,
      width: cw,
      height: ch,
      format: 'rgb',
      timestampUs: DateTime.now().microsecondsSinceEpoch,
    ));
  }

  /// Grab the RAW camera frame exactly as the sensor delivered it — no
  /// cropping, no scaling, no RGBA→RGB conversion.
  ///
  /// This is the ground truth for "what did the camera actually see".
  /// Comparing it against the processed frame handed to the decoder is
  /// what tells you whether a failure is a framing/scale problem (the raw
  /// shot looks fine but the processed frame lost the anchors) or a
  /// genuine decode problem (the raw shot itself is blurry / too small /
  /// badly lit).
  ///
  /// Returns PNG bytes, or null if the video is not ready.
  /// Copy the current video frame into the raw canvas at native resolution.
  ///
  /// Runs at most once per grab — on demand here while the camera is live,
  /// or just before the video element is released in [stop]. Deliberately
  /// NOT per captured frame: a 2176x3840 (8.3 Mpx) drawImage on every tick
  /// drove phone memory/CPU hard enough to crash the tab.
  void _blitRawFrame(JSObject video) {
    final rawCtx = _rawCtx;
    if (rawCtx == null || _rawCanvas == null) return;
    try {
      final vw = _getIntProp(video, 'videoWidth') ?? _videoWidth;
      final vh = _getIntProp(video, 'videoHeight') ?? _videoHeight;
      if (vw <= 0 || vh <= 0) return;
      final rawDraw = _reflectGet(rawCtx, 'drawImage'.toJS) as JSFunction?;
      if (rawDraw == null) return;
      _reflectApply(
          rawDraw, rawCtx, [video, 0.toJS, 0.toJS, vw.toJS, vh.toJS].toJS);
    } catch (e) {
      debugPrint('[Camera] raw blit failed: $e');
    }
  }

  Future<Uint8List?> captureRawFramePng() async {
    // If the camera is still live, refresh the raw canvas from the video
    // first. Otherwise reuse the copy taken by [stop] — the video element
    // is gone by then, which is why the raw capture used to be missing
    // entirely whenever 截图 was pressed after a scan ended.
    final video = _video;
    if (video != null) {
      _blitRawFrame(video);
    }

    final canvas = _rawCanvas;
    if (canvas == null) {
      debugPrint('[Camera] captureRawFramePng: _rawCanvas is null '
          '(camera never started or already disposed)');
      return null;
    }
    if (_videoWidth <= 0 || _videoHeight <= 0) {
      debugPrint('[Camera] captureRawFramePng: video dims are '
          '$_videoWidth x $_videoHeight');
      return null;
    }

    final toDataURL = _reflectGet(canvas, 'toDataURL'.toJS) as JSFunction?;
    if (toDataURL == null) {
      debugPrint('[Camera] captureRawFramePng: toDataURL missing');
      return null;
    }
    try {
      final url =
          toDataURL.callAsFunction(canvas, 'image/png'.toJS) as JSString?;
      if (url == null) {
        debugPrint('[Camera] captureRawFramePng: toDataURL returned null');
        return null;
      }
      final dataUrl = url.toDart;
      final comma = dataUrl.indexOf(',');
      if (comma < 0) return null;
      final bytes = base64Decode(dataUrl.substring(comma + 1));
      debugPrint('[Camera] captureRawFramePng: ${bytes.length} bytes from '
          '${_videoWidth}x$_videoHeight} canvas');
      return bytes;
    } catch (e) {
      debugPrint('[Camera] captureRawFramePng failed: $e');
      return null;
    }
  }

  @override
  void onFrame(CameraFrameCallback callback) {
    _callback = callback;
  }

  @override
  Future<void> stop() async {
    _frameTimer?.cancel();
    _frameTimer = null;

    // Snapshot the untouched frame BEFORE the video element is torn down,
    // so 截图 can still ship the raw photo after the scan has stopped.
    final video = _video;
    if (video != null) {
      _blitRawFrame(video);
      final pauseFn = _reflectGet(video, 'pause'.toJS) as JSFunction?;
      pauseFn?.callAsFunction(video);
      _setProp(video, 'srcObject', null);
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
    // NOTE: _rawCanvas / _rawCtx are deliberately kept. They hold the
    // last untouched camera frame so 截图 can still upload the raw photo
    // after the scan has stopped. They are released in [dispose].
  }

  @override
  Future<void> dispose() async {
    _callback = null;
    await stop();
    _rawCanvas = null;
    _rawCtx = null;
  }
}

/// The single spelling `cimbar_platform.dart` instantiates.
///
/// That file is compiled once per target, so it can only name ONE type.
/// The conditional import decides what this resolves to — getUserMedia on
/// web, the `camera`-plugin implementation on native — and both sides
/// export it under this alias so every target compiles.
typedef PlatformCameraCapture = WebCameraCapture;
