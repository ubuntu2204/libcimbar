// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:ffi/ffi.dart';

import '../interfaces/screen_capture_interface.dart';

/// Windows screen capture implementation using Win32 GDI APIs via FFI.
///
/// Uses `GetDesktopWindow`, `GetDC`, `CreateCompatibleDC`, `BitBlt`, and
/// `GetDIBits` to capture screen regions as raw pixel data.
class WindowsScreenCapture implements IScreenCapture {
  // ─── Win32 API function pointers (resolved once on construction) ───

  late final DynamicLibrary _user32;
  late final DynamicLibrary _gdi32;

  // Dart-side function references (use Dart types: int, Pointer)
  late final _DartGetDesktopWindow _getDesktopWindow;
  late final _DartGetDC _getDC;
  late final _DartReleaseDC _releaseDC;
  late final _DartCreateCompatibleDC _createCompatibleDC;
  late final _DartDeleteDC _deleteDC;
  late final _DartCreateCompatibleBitmap _createCompatibleBitmap;
  late final _DartSelectObject _selectObject;
  late final _DartDeleteObject _deleteObject;
  late final _DartBitBlt _bitBlt;
  late final _DartGetDIBits _getDIBits;
  late final _DartGetSystemMetrics _getSystemMetrics;

  bool _initialized = false;

  WindowsScreenCapture() {
    if (!Platform.isWindows) return;
    _init();
  }

  void _init() {
    _user32 = DynamicLibrary.open('user32.dll');
    _gdi32 = DynamicLibrary.open('gdi32.dll');

    _getDesktopWindow = _user32
        .lookup<NativeFunction<_NativeGetDesktopWindow>>('GetDesktopWindow')
        .asFunction<_DartGetDesktopWindow>();
    _getDC = _user32
        .lookup<NativeFunction<_NativeGetDC>>('GetDC')
        .asFunction<_DartGetDC>();
    _releaseDC = _user32
        .lookup<NativeFunction<_NativeReleaseDC>>('ReleaseDC')
        .asFunction<_DartReleaseDC>();
    _getSystemMetrics = _user32
        .lookup<NativeFunction<_NativeGetSystemMetrics>>('GetSystemMetrics')
        .asFunction<_DartGetSystemMetrics>();

    _createCompatibleDC = _gdi32
        .lookup<NativeFunction<_NativeCreateCompatibleDC>>('CreateCompatibleDC')
        .asFunction<_DartCreateCompatibleDC>();
    _deleteDC = _gdi32
        .lookup<NativeFunction<_NativeDeleteDC>>('DeleteDC')
        .asFunction<_DartDeleteDC>();
    _createCompatibleBitmap = _gdi32
        .lookup<NativeFunction<_NativeCreateCompatibleBitmap>>(
            'CreateCompatibleBitmap')
        .asFunction<_DartCreateCompatibleBitmap>();
    _selectObject = _gdi32
        .lookup<NativeFunction<_NativeSelectObject>>('SelectObject')
        .asFunction<_DartSelectObject>();
    _deleteObject = _gdi32
        .lookup<NativeFunction<_NativeDeleteObject>>('DeleteObject')
        .asFunction<_DartDeleteObject>();
    _bitBlt = _gdi32
        .lookup<NativeFunction<_NativeBitBlt>>('BitBlt')
        .asFunction<_DartBitBlt>();
    _getDIBits = _gdi32
        .lookup<NativeFunction<_NativeGetDIBits>>('GetDIBits')
        .asFunction<_DartGetDIBits>();

    _initialized = true;
  }

  @override
  bool get isSupported => Platform.isWindows && _initialized;

  @override
  Future<ScreenCaptureResult> captureRegion(Rect region) async {
    if (!isSupported) {
      throw UnsupportedError('Screen capture not supported on this platform.');
    }

    final x = region.left.toInt();
    final y = region.top.toInt();
    final width = region.width.toInt();
    final height = region.height.toInt();

    return _captureRect(x, y, width, height);
  }

  @override
  Future<ScreenCaptureResult> captureFullScreen() async {
    if (!isSupported) {
      throw UnsupportedError('Screen capture not supported on this platform.');
    }

    // SM_CXSCREEN = 0, SM_CYSCREEN = 1
    final screenWidth = _getSystemMetrics(0);
    final screenHeight = _getSystemMetrics(1);

    return _captureRect(0, 0, screenWidth, screenHeight);
  }

  /// Core capture using Win32 GDI.
  ScreenCaptureResult _captureRect(int x, int y, int width, int height) {
    // Get desktop DC
    final hwnd = _getDesktopWindow();
    final hdcScreen = _getDC(hwnd);

    // Create memory DC and bitmap
    final hdcMem = _createCompatibleDC(hdcScreen);
    final hBitmap = _createCompatibleBitmap(hdcScreen, width, height);
    final hOldBitmap = _selectObject(hdcMem, hBitmap);

    // Copy screen region to memory DC
    // SRCCOPY = 0x00CC0020
    _bitBlt(hdcMem, 0, 0, width, height, hdcScreen, x, y, 0x00CC0020);

    // Set up BITMAPINFOHEADER for 32-bit BGRA
    const biSize = 40;
    final bi = calloc<Uint8>(biSize + 8); // extra for color masks
    final biView = bi.cast<Uint32>();
    biView[0] = biSize; // biSize
    biView[1] = width; // biWidth
    // biHeight is negative for top-down DIB
    bi.cast<Int32>()[2] = -height; // biHeight (negative = top-down)
    biView.cast<Uint16>()[6] = 1; // biPlanes
    biView.cast<Uint16>()[7] = 32; // biBitCount
    biView[4] = 0; // biCompression = BI_RGB

    // Allocate pixel buffer (BGRA, 4 bytes per pixel)
    final pixelCount = width * height;
    final pixelBytes = pixelCount * 4;
    final pixels = calloc<Uint8>(pixelBytes);

    // Read pixels from bitmap
    _getDIBits(hdcMem, hBitmap, 0, height, pixels, bi, 0);

    // Convert BGRA → RGBA (swap R and B channels)
    final rgba = Uint8List(pixelBytes);
    final src = pixels.asTypedList(pixelBytes);
    for (int i = 0; i < pixelCount; i++) {
      final offset = i * 4;
      rgba[offset] = src[offset + 2]; // R ← B
      rgba[offset + 1] = src[offset + 1]; // G ← G
      rgba[offset + 2] = src[offset]; // B ← R
      rgba[offset + 3] = src[offset + 3]; // A ← A
    }

    // Cleanup
    _selectObject(hdcMem, hOldBitmap);
    _deleteObject(hBitmap);
    _deleteDC(hdcMem);
    _releaseDC(hwnd, hdcScreen);
    calloc.free(bi);
    calloc.free(pixels);

    return ScreenCaptureResult(
      pixels: rgba,
      width: width,
      height: height,
    );
  }

  @override
  Future<void> dispose() async {
    // No persistent resources to free
  }
}

// ─── Native type aliases (for NativeFunction<>) ──────────────────
// These use FFI types (Int32, Uint32, Pointer).

typedef _NativeGetDesktopWindow = Pointer Function();
typedef _NativeGetDC = Pointer Function(Pointer hwnd);
typedef _NativeReleaseDC = Int32 Function(Pointer hwnd, Pointer hdc);
typedef _NativeGetSystemMetrics = Int32 Function(Int32 nIndex);
typedef _NativeCreateCompatibleDC = Pointer Function(Pointer hdc);
typedef _NativeDeleteDC = Int32 Function(Pointer hdc);
typedef _NativeCreateCompatibleBitmap = Pointer Function(
    Pointer hdc, Int32 width, Int32 height);
typedef _NativeSelectObject = Pointer Function(Pointer hdc, Pointer hgdiobj);
typedef _NativeDeleteObject = Int32 Function(Pointer hgdiobj);
typedef _NativeBitBlt = Int32 Function(
  Pointer hdcDest,
  Int32 xDest,
  Int32 yDest,
  Int32 width,
  Int32 height,
  Pointer hdcSrc,
  Int32 xSrc,
  Int32 ySrc,
  Uint32 rop,
);
typedef _NativeGetDIBits = Int32 Function(
  Pointer hdc,
  Pointer hbm,
  Uint32 start,
  Uint32 cLines,
  Pointer<Uint8> lpvBits,
  Pointer<Uint8> lpbmi,
  Uint32 usage,
);

// ─── Dart type aliases (for .asFunction()) ────────────────────────
// These use Dart types (int, Pointer).

typedef _DartGetDesktopWindow = Pointer Function();
typedef _DartGetDC = Pointer Function(Pointer hwnd);
typedef _DartReleaseDC = int Function(Pointer hwnd, Pointer hdc);
typedef _DartGetSystemMetrics = int Function(int nIndex);
typedef _DartCreateCompatibleDC = Pointer Function(Pointer hdc);
typedef _DartDeleteDC = int Function(Pointer hdc);
typedef _DartCreateCompatibleBitmap = Pointer Function(
    Pointer hdc, int width, int height);
typedef _DartSelectObject = Pointer Function(Pointer hdc, Pointer hgdiobj);
typedef _DartDeleteObject = int Function(Pointer hgdiobj);
typedef _DartBitBlt = int Function(
  Pointer hdcDest,
  int xDest,
  int yDest,
  int width,
  int height,
  Pointer hdcSrc,
  int xSrc,
  int ySrc,
  int rop,
);
typedef _DartGetDIBits = int Function(
  Pointer hdc,
  Pointer hbm,
  int start,
  int cLines,
  Pointer<Uint8> lpvBits,
  Pointer<Uint8> lpbmi,
  int usage,
);
