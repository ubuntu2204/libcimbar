// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import '../interfaces/camera_capture_interface.dart';

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
  static const _targetSize = 1024;

  /// Current capture cadence in milliseconds (driven by [start]).
  int _frameIntervalMs = _defaultFrameIntervalMs;

  @override
  bool get isSupported => true;

  @override
  bool get isStreaming => _streaming;

  /// Platform view type for embedding the video element.
  String? get viewType => _viewType;

  @override
  Future<void> start({
    int preferredWidth = 1024,
    int preferredHeight = 1024,
    int frameIntervalMs = _defaultFrameIntervalMs,
  }) async {
    if (_streaming) return;

    _frameIntervalMs = frameIntervalMs <= 0 ? _defaultFrameIntervalMs : frameIntervalMs;

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
    // Style the video element to fill its container
    _setProp(video, 'style', 'width:100%;height:100%;object-fit:cover;'.toJS);
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

    // Create offscreen canvas at target size (1024x1024) from the start
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

    // Calculate square crop region from center (matching scanning overlay)
    final cropSize = vw < vh ? vw : vh;
    final sx = (vw - cropSize) ~/ 2;
    final sy = (vh - cropSize) ~/ 2;

    // Target size: 1024x1024 (optimal for cimbar decoder)
    const targetSize = _targetSize;

    // Draw cropped region scaled to target — do NOT resize canvas here
    final drawImage = _reflectGet(ctx, 'drawImage'.toJS) as JSFunction?;
    if (drawImage != null) {
      final args = [
        video,
        sx.toJS, sy.toJS, cropSize.toJS, cropSize.toJS, // source rect
        0.toJS, 0.toJS, targetSize.toJS, targetSize.toJS, // dest rect
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

    // Convert RGBA to RGB (strip alpha channel) for cimbar decoder
    const pixelCount = targetSize * targetSize;
    final rgbPixels = Uint8List(pixelCount * 3);
    for (int i = 0; i < pixelCount; i++) {
      rgbPixels[i * 3] = rgbaPixels[i * 4]; // R
      rgbPixels[i * 3 + 1] = rgbaPixels[i * 4 + 1]; // G
      rgbPixels[i * 3 + 2] = rgbaPixels[i * 4 + 2]; // B
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
