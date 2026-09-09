## Unreleased

### Changed

- **简化示例应用（做减法）**：
  - `example` 只保留编码发送：选择文件 → 编码 → 帧播放（模式菜单 + 帧率 + 窗口控制）
  - `decode_example` 只保留扫码解码：摄像头 → 解码 → 自动保存文件
- **Windows 构建方式**：Windows 产物在 Ubuntu 上通过
  [flutter_build](https://github.com/ubuntu2610/flutter_build) 交叉编译生成，
  项目本身在 Linux 上开发与测试，不直接在 Windows 机器上构建。
- **`CimbarFrame`** 现在持有像素数据的独立拷贝（此前直接持有传入的 `Uint8List`
  引用，编码器帧缓冲被下一帧覆盖时会串帧）。

### Removed

- **Windows 屏幕截图**：Alt+A 快捷键触发区域选择的流程已从示例应用中移除，不再支持。
- **AVIF 压缩**：截图先压缩为 AVIF 再编码的流程已从示例应用中移除，不再支持。

### Fixed

- **中文（非 ASCII）文件名乱码**：
  - 编码端 `cimbare_init_encode` 的 `fnsize` 改为 UTF-8 **字节数**（此前传的是 Dart
    的 UTF-16 码元数，导致中文名被从中间截断成非法 UTF-8）
  - 网页端文件名改用 UTF-8 解码（此前 `String.fromCharCodes` 逐字节解释，等同 Latin-1）

## 0.1.0

### Initial Release

- **Core encoding**: Convert binary data into cimbar barcode frame images via dart:ffi (Windows/Linux) or MethodChannel (Android)
- **Core decoding**: Decode cimbar barcode images back into binary data using fountain codes
- **Camera scanning** (Android): CameraX integration for real-time barcode scanning
- **Web support** (WASM): JS interop bindings for Emscripten-compiled libcimbar
- **Abstract interfaces**: All APIs exposed as interfaces (`ICimbarEncoder`, `ICimbarDecoder`, `ICameraCapture`) for testability and extensibility
- **Encoding modes**: mode4C (16×16, best compatibility), modeB (24×24, default), modeBm (24×24, monochrome), modeBu (24×24, variant)
- **Example apps**: `example` (desktop encoder) and `decode_example` (Web/Android decoder)
- **Native build scripts**: CMake scripts for Windows DLL, Linux .so, Android .so, and WASM compilation
