# libcimbar

[![pub.dev](https://img.shields.io/pub/v/libcimbar.svg)](https://pub.dev/packages/libcimbar)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-blue.svg)](https://opensource.org/licenses/MPL-2.0)
[![Flutter](https://img.shields.io/badge/Flutter-3.10%2B-blue?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows%20%7C%20Android%20%7C%20Web-lightgrey)]()

**English** | [中文](#中文说明)

A Dart/Flutter plugin for [Color Icon Matrix Barcodes (cimbar)](https://github.com/sz3/libcimbar) — a high-density 2D barcode format that enables **air-gapped data transfer at ~850 kbps** using only a monitor and a camera.

Encode files into animated color barcode sequences on one screen, and decode them from camera frames on another device — **no WiFi, Bluetooth, or NFC required**.

## Features

- **Encode** any file into cimbar barcode frames (raw RGB pixel data)
- **Decode** cimbar barcode frames back into the original file via fountain codes
- **Camera Scanning** (Android / Web): real-time camera-based barcode decoding
- **Cross-platform**: desktop (native FFI), Android (JNI), Web (WASM)
- **Clean interface design**: all APIs exposed as abstract interfaces for testability

## Platform Support

| Platform   | Encoder | Decoder | Camera |
|------------|---------|---------|--------|
| Windows    | ✅ FFI  | ✅ FFI  | —      |
| Linux      | ✅ FFI  | ✅ FFI  | —      |
| Android    | —       | ✅ FFI (`libcimbar_jni.so`) | ✅ Camera1 (native, cfc port) |
| Web (WASM) | —       | ✅ JS interop | ✅ getUserMedia |

Windows builds are produced by cross-compiling on Ubuntu with
[flutter_build](https://github.com/ubuntu2610/flutter_build); Linux is the
platform used for day-to-day development and testing.

## Quick Start

### 1. Add dependency

```yaml
dependencies:
  libcimbar: ^0.1.0
```

### 2. Build the native library

The plugin requires the libcimbar C++ core to be compiled as a shared library.

**Windows:** cross-compiled on Ubuntu with
[flutter_build](https://github.com/ubuntu2610/flutter_build) (the project is
developed and tested on Linux; no Windows toolchain is used directly):
```bash
cd native
build_windows.bat /path/to/libcimbar
```

**Linux:**
```bash
cd native && mkdir -p build_linux && cd build_linux
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . -j$(nproc)
# Output: build_linux/libcimbar.so
```

**Android:** (handled automatically by the Flutter build system via CMake)

**Web:**
```bash
source /path/to/emsdk/emsdk_env.sh
cd native
bash build_wasm.sh /path/to/libcimbar
# Copy output to decode_example/web/assets/wasm/
```

### 3. Encode data

```dart
import 'package:libcimbar/libcimbar.dart';

final encoder = await CimbarPlatform.instance.createEncoder();
await encoder.configure(const CimbarConfig(mode: CimbarMode.modeB));

// One encode session per file; the filename goes into the stream header.
await encoder.initEncodeSession('photo.png');

// Feed the file in slices (official send.js importFile).
await for (final chunk in inputFile.readChunks()) {
  await encoder.encodeChunk(chunk);
}
await encoder.finishEncode();

// Pull frames and play them at 15 fps for the receiver to scan; the
// fountain stream loops forever (it restarts after 8x the required blocks,
// exactly like upstream cimbar_js.cpp).
CimbarFramePlayer(
  frameSupplier: () => encoder.nextFrame(),
  fps: 15, // frame.pixels contains raw RGB data
);
```

### 4. Decode data

```dart
final decoder = await CimbarPlatform.instance.createDecoder();
await decoder.configure(const CimbarConfig(mode: CimbarMode.modeB));

// Feed camera frames one at a time
for (final cameraFrame in cameraStream) {
  final result = await decoder.decodeFrame(
    cameraFrame.data,
    width: cameraFrame.width,
    height: cameraFrame.height,
  );

  if (result.isComplete) {
    print('File recovered: ${result.filename} (${result.data!.length} bytes)');
    break;
  }
  print('Progress: ${(result.progress * 100).toStringAsFixed(1)}%');
}
```

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│                    Example Application                     │
│  ┌─────────────────┐    ┌──────────────────────────────┐  │
│  │  Encoder Page    │    │       Decoder Page           │  │
│  │  (Desktop)       │    │  (Android / Web)             │  │
│  │  Pick file →     │    │  Camera → Scan → Save        │  │
│  │  Encode → Play   │    │                              │  │
│  └────────┬─────────┘    └──────────────┬───────────────┘  │
│           │                             │                   │
│  ┌────────▼─────────────────────────────▼───────────────┐  │
│  │              Abstract Interfaces                      │  │
│  │  ICimbarEncoder · ICimbarDecoder · ICameraCapture     │  │
│  └────────┬──────────────────────────────┬──────────────┘  │
│           │                              │                  │
│  ┌────────▼──────────┐   ┌──────────────▼───────────────┐  │
│  │   Desktop / FFI    │   │   Android / Web              │  │
│  │   dart:ffi         │   │   FFI / JS interop           │  │
│  │   libcimbar.so|dll │   │   Camera1 (cfc) / getUserMedia │  │
│  └────────┬──────────┘   └──────────────┬───────────────┘  │
│           │                              │                  │
│  ┌────────▼──────────────────────────────▼───────────────┐  │
│  │              libcimbar C++ Core                        │  │
│  │  Encoder: zstd → fountain → Reed-Solomon → tile grid  │  │
│  │  Decoder: tile grid → Reed-Solomon → fountain → zstd  │  │
│  └───────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
```

## API Reference

### Core Interfaces

All functionality is exposed through abstract interfaces, enabling easy mocking and testing.

#### `ICimbarEncoder`

Mirrors the official `cimbare_*` C API / `send.js` flow:

```dart
abstract class ICimbarEncoder {
  bool get isReady;
  Future<void> configure(CimbarConfig config);
  Future<void> initEncodeSession(String filename, {int encodeId = -1});
  Future<int> encodeChunk(Uint8List chunk); // 1 more / 0 ready / <0 error
  Future<void> finishEncode();              // official nullptr flush
  Future<CimbarFrame?> nextFrame({bool colorBalance = false});
  Future<void> dispose();
}
```

#### `ICimbarDecoder`

```dart
abstract class ICimbarDecoder {
  bool get isReady;
  double get progress;
  bool get isComplete;
  Future<void> configure(CimbarConfig config);
  Future<DecodeResult> decodeFrame(Uint8List imageData, {int width, int height, CimbarImageFormat format});
  Future<Uint8List?> recoverFile(int fileId);
  Future<String> recoverFilename(int fileId);
  Future<void> dispose();
}
```

#### `ICameraCapture`

```dart
abstract class ICameraCapture {
  bool get isSupported;
  bool get isStreaming;
  Future<void> start({
    int preferredWidth = 1920,
    int preferredHeight = 1080,
    int frameIntervalMs = 200, // ~5 fps
  });
  void onFrame(CameraFrameCallback callback);
  Future<void> stop();
  Future<void> dispose();
}
```

### Configuration

```dart
const config = CimbarConfig(
  mode: CimbarMode.modeB,    // Encoding mode
  compressionLevel: 16,       // zstd level (0–22)
  eccBytes: 30,               // Reed-Solomon ECC bytes
  fps: 15,                    // Animation frame rate
  // imageSize is fixed at 1024x1024
  encodeId: -1,               // Auto-increment
);
```

### Encoding Modes

| Mode   | Grid  | Description                          |
|--------|-------|--------------------------------------|
| `mode4C` | 16×16 | RGB + luminance, best compatibility  |
| `modeB`  | 24×24 | High color gamut, default mode       |
| `modeBm` | 24×24 | Monochrome, for low-light            |
| `modeBu` | 24×24 | Variant of B mode                    |

## Building Native Libraries

### Prerequisites

- [libcimbar source](https://github.com/sz3/libcimbar) cloned locally
- CMake 3.22+
- OpenCV 4.5+
- **Windows**: cross-compiled from Ubuntu via
  [flutter_build](https://github.com/ubuntu2610/flutter_build) (no local
  Windows toolchain needed)
- **Android**: Android NDK r25+
- **Web**: Emscripten SDK

### Windows

Windows binaries are **not** built on a Windows machine — this project is
developed on Ubuntu and cross-compiled with
[flutter_build](https://github.com/ubuntu2610/flutter_build):

```bash
cd native
build_windows.bat /path/to/libcimbar

# Output: build_windows/Release/libcimbar.dll
# Copy to: example/build/windows/x64/runner/Release/
```

### Linux

```bash
sudo apt install libopencv-dev libglfw3-dev
cd native && mkdir -p build_linux && cd build_linux
cmake .. -DCMAKE_BUILD_TYPE=Release && cmake --build . -j$(nproc)

# Output: build_linux/libcimbar.so
# Copy to: example/build/linux/x64/debug/bundle/lib/
```

### Android

The Android native library (`libcimbar_jni.so`) is built automatically by the Flutter build system using the CMakeLists.txt in `android/src/main/cpp/`.

Set these in `local.properties`:
```properties
libcimbar.src.path=/path/to/libcimbar
opencv.android.sdk=/path/to/opencv-android-sdk
```

### Web (WASM)

```bash
source /path/to/emsdk/emsdk_env.sh
cd native
bash build_wasm.sh /path/to/libcimbar

# Copy output to the WEB DECODER app (not `example`, which is the encoder):
# decode_example/web/assets/wasm/libcimbar.js
# decode_example/web/assets/wasm/libcimbar.wasm
# decode_example/web/assets/wasm/cimbar_js.wasm
```

## Example Apps

The project provides two separate example applications:

### `example` — Desktop Encoder (发送端)

桌面编码发送端（Linux 日常开发调试，Windows 版本由 flutter_build 在 Ubuntu 上交叉构建）。
左侧 200px 控制面板 + 右侧最大化显示 cimbar 编码图像。

- 选择文件 → 编码为 cimbar 条码帧 → 按设定 fps 循环播放（含官方的画面抖动 shake）
- 可切换编码模式、调节帧率；不包含解码功能

```bash
cd example
flutter run -d linux      # 日常开发
flutter run -d windows    # Windows 版，需 flutter_build 交叉构建
```

### `decode_example` — Web/Android Decoder (接收端)

Web 和 Android 平台的解码接收端。通过摄像头扫描 cimbar 条码并恢复原始文件。

- Opens camera → scans cimbar barcodes → recovers the original file → saves it

```bash
cd decode_example

# Run on Web
flutter run -d chrome

# Run on Android
flutter run -d <android-device-id>
```

## Technical Details

cimbar encodes data into a grid of colored tiles where each tile carries **6 bits**: 4 bits from symbol selection (which 8×8 pixel icon) and 2 bits from color (which of 4 colors). The pipeline:

1. **Compression**: Input file → zstd compression
2. **Fountain Codes**: Compressed data → Wirehair fountain encoding (allows reconstruction from any N+1 frames)
3. **Error Correction**: Each chunk → Reed-Solomon ECC with interleaving
4. **Tile Mapping**: Data → colored tile grid → rendered as an image

A standard 1024×1024 frame holds **12,400 data tiles** = **~9,300 bytes** of payload.

## Testing

```bash
# Run unit tests
flutter test

# Run specific test file
flutter test test/models/
flutter test test/impl/
flutter test test/ffi/
flutter test test/interfaces/
```

## Related Projects

- [libcimbar](https://github.com/sz3/libcimbar) — The original C++ implementation
- [cimbar.org](https://cimbar.org) — Web-based cimbar encoder (WASM)
- [cfc](https://github.com/sz3/cfc) — Android cimbar receiver app

## License

This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

This project is licensed under the [Mozilla Public License 2.0](LICENSE), the same license as the upstream [libcimbar](https://github.com/sz3/libcimbar) project. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution of third-party dependencies.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## 中文说明

**Dart/Flutter 插件**，封装 [Color Icon Matrix Barcode (cimbar)](https://github.com/sz3/libcimbar) — 一种高密度二维码格式，能利用屏幕和摄像头实现 **~850 kbps 的无网络数据传输**（无需 WiFi、蓝牙或 NFC）。

### 功能特性

- 将任意文件编码为 cimbar 条形码帧图像（RGB 像素数据）
- 从摄像头帧中解码 cimbar 条形码，恢复原始文件
- 摄像头扫描：Android 和 Web 平台实时解码
- 跨平台支持：桌面 Linux/Windows（FFI）、Android（JNI）、Web（WASM）
- 接口化设计：所有 API 以抽象接口暴露，方便测试和扩展

### 快速开始

```yaml
dependencies:
  libcimbar: ^0.1.0
```

```dart
import 'package:libcimbar/libcimbar.dart';

// 编码（官方 send.js 流式流程）
final encoder = await CimbarPlatform.instance.createEncoder();
await encoder.configure(const CimbarConfig(mode: CimbarMode.modeB));
await encoder.initEncodeSession('photo.png');
await for (final chunk in inputFile.readChunks()) {
  await encoder.encodeChunk(chunk);
}
await encoder.finishEncode();
final frame = await encoder.nextFrame(); // 无限喷泉流，逐帧拉取

// 解码
final decoder = await CimbarPlatform.instance.createDecoder();
await decoder.configure(const CimbarConfig(mode: CimbarMode.modeB));
final result = await decoder.decodeFrame(imageData, width: 1024, height: 1024);
if (result.isComplete) {
  final fileData = result.data; // 恢复的文件数据
}
```

### 编译原生库

需要先编译 libcimbar C++ 核心库：

```bash
# Windows（在 Ubuntu 上用 flutter_build 交叉构建）
native/build_windows.bat /path/to/libcimbar

# Linux
cd native && mkdir -p build_linux && cd build_linux
cmake .. -DCMAKE_BUILD_TYPE=Release && cmake --build . -j$(nproc)

# Web (WASM)
bash native/build_wasm.sh /path/to/libcimbar
```

Android 原生库通过 Flutter 构建系统自动编译。

### 示例应用

项目提供两个独立的示例应用：

- **`example`** — 桌面编码发送端（选择文件 → cimbar 编码 → 动画显示）
- **`decode_example`** — Web/Android 解码接收端（摄像头扫描 → cimbar 解码 → 文件恢复）

> Windows 版本不在 Windows 机器上构建：本项目在 Ubuntu 上开发，Windows 产物由
> [flutter_build](https://github.com/ubuntu2610/flutter_build) 交叉编译生成。

```bash
# Linux 发送端（日常开发）
cd example && flutter run -d linux

# Windows 发送端（flutter_build 交叉构建）
cd example && flutter run -d windows

# Web 接收端
cd decode_example && flutter run -d chrome

adb reverse tcp:8080 tcp:8080
手机访问localhost:8080

# Android 接收端
cd decode_example && flutter run -d <android-device-id>
```

详细 API 文档和架构说明请参考上方的英文部分。
