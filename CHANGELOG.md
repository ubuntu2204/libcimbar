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

- **桌面/移动构建不再打包 WASM 资源**：移除了插件 `pubspec.yaml` 里的
  `assets: - assets/wasm/`。WASM 只被 Web 端当作**静态文件**加载（应用自己的
  `web/assets/wasm/`，由 `index.html` 的 `<script>` 与 worker 的 `importScripts()`
  引用），没有任何代码走 Flutter 资源包；这条声明只会让 Windows/Linux/Android 的
  `flutter_assets/packages/libcimbar/assets/wasm/` 多出约 4 MB 用不到的
  `.js`/`.wasm`。**注意**：旧的构建产物不会被自动清理，需手动删掉该目录或重新构建。

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
