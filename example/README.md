# libcimbar Example App

桌面**编码发送端**（Linux / Windows），演示 `libcimbar` 插件的编码流程。

## What This App Does

1. 点击"选择文件"选择要发送的文件（任意类型）
2. 文件字节经 cimbar 编码为条码帧序列
   （zstd 压缩 → fountain 编码 → Reed-Solomon 纠错 → 彩色 tile 网格）
3. 帧序列按设定 fps 循环播放，并带官方 sender 的画面抖动（shake）
4. 可切换编码模式（modeB / modeBm / modeBu / mode4C）、调节帧率、控制窗口显示

本应用**不包含解码功能** —— 解码接收端在 `decode_example`。

## Running the Example

### Prerequisites

先编译原生库（`libcimbar.so` / `libcimbar.dll`）：

```bash
# Linux（日常开发）
cd ../native && mkdir -p build_linux && cd build_linux
cmake .. -DCMAKE_BUILD_TYPE=Release && cmake --build . -j$(nproc)
# 输出 build_linux/libcimbar.so
# 复制到 example/build/linux/x64/debug/bundle/lib/

# Windows（在 Ubuntu 上用 flutter_build 交叉构建）
cd ../native
build_windows.bat /path/to/libcimbar
# 输出到 example/build/windows/x64/runner/Release/
```

### Linux

```bash
flutter run -d linux
```

### Windows

Windows 产物由 [flutter_build](https://github.com/ubuntu2610/flutter_build)
在 Ubuntu 上交叉编译生成（本项目不在 Windows 机器上构建）：

```bash
flutter run -d windows
```

## Architecture

```
┌─────────────────────────────────────┐
│           Example App               │
│  ┌───────────────────────────────┐  │
│  │  Encoder Page                 │  │
│  │  选文件 → 编码 → 帧播放        │  │
│  └──────────────┬────────────────┘  │
│  ┌──────────────▼────────────────┐  │
│  │  libcimbar Plugin             │  │
│  │  ICimbarEncoder (dart:ffi)    │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
```

The example app only calls the abstract interfaces provided by the `libcimbar` package. It does not access native code directly.

## Source Files

| File | Description |
|------|-------------|
| `lib/main.dart` | App entry point |
| `lib/encoder_page.dart` | 选文件 → cimbar 编码 → 帧播放 UI |
| `lib/core/window_display.dart` | 窗口显示控制（window_manager / screen_retriever）|

## Troubleshooting

**"Native library not loaded"**
- Linux：确认 `libcimbar.so` 在 `build/linux/x64/debug/bundle/lib/` 下
- Windows：确认 `libcimbar.dll` 与 exe 同目录，且 OpenCV DLL 在 PATH 中
- 修改原生代码后必须重新编译并复制到上述目录

**编码一直卡在 0 帧**
- 检查控制台是否报 `cimbare_init_encode failed`
- 文件名含非 ASCII 字符是支持的（fnsize 按 UTF-8 字节数传递）
