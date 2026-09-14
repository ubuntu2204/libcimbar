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
```

Windows 的 `libcimbar.dll` 见下文 [Windows](#windows) 一节（由 flutter_build
工作流交叉编译，仓库内 `windows/libcimbar.dll` 已是预编译产物）。

### Linux

```bash
flutter run -d linux
```

### Windows

Windows 产物**完全在 Ubuntu 上交叉编译**（不在 Windows 机器上构建），
使用 [flutter_build](https://github.com/ubuntu2610/flutter_build)：

```bash
# 1. 获取 flutter_build 并全局安装（Dart SDK 随 Flutter 提供）
git clone https://github.com/ubuntu2610/flutter_build
cd flutter_build
dart pub global activate --source path .
export PATH="$PATH:$HOME/.pub-cache/bin"   # 按 pub 提示加入 PATH

# 2. （仅修改 native/ 下的 C++ 代码后需要）重新交叉编译 libcimbar.dll，
#    替换仓库根的 windows/libcimbar.dll
#    见下文「交叉编译 libcimbar.dll」

# 3. 构建 example 的 Windows 版
cd /path/to/libcimbar/example
flutter_build windows --release
# 产物：example/build/win_cross/release/libcimbar_example/
#       （libcimbar_example.exe + flutter_windows.dll + data/ + libcimbar.dll）
```

首次运行会自动下载 LLVM-MinGW 工具链到 `~/.flutter_build/toolchains/`
（也可用 `--toolchain-path` 指向已装好的目录）。依赖：`wine64`、`cmake`、
`ninja-build`（`sudo apt install wine64 cmake ninja-build`）。

不指定 flavor 默认 `--release`；也可用 `flutter_build windows --debug`。
没有 `flutter_build` 命令时可用 `dart run flutter_build windows` 替代。

#### 交叉编译 libcimbar.dll

`windows/libcimbar.dll` 是静态产物（静态链接 OpenCV 与 C++ runtime，
运行时只依赖 Windows 系统自带 DLL，无需单独分发 OpenCV）。修改 `native/`
下的 C++ 代码后按下面两步重编：

```bash
# flutter_build 首次运行时已下载的 LLVM-MinGW 工具链：
export TC="$(ls -d ~/.flutter_build/toolchains/llvm-mingw-*/bin | tail -1)"

# 1) llvm-mingw 静态编译 OpenCV（MSVC 的 opencv .lib 与 GNU ABI 不兼容，
#    不能直接链 import lib，必须从源码编）
cmake -S /path/to/opencv -B /tmp/opencv_mingw -G Ninja \
  -DCMAKE_SYSTEM_NAME=Windows \
  -DCMAKE_C_COMPILER=$TC/x86_64-w64-mingw32-clang \
  -DCMAKE_CXX_COMPILER=$TC/x86_64-w64-mingw32-clang++ \
  -DCMAKE_RC_COMPILER=$TC/x86_64-w64-mingw32-windres \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_LIST=core,imgproc,imgcodecs -DBUILD_opencv_apps=OFF \
  -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF \
  -DWITH_IPP=OFF -DWITH_OPENCL=OFF -DWITH_ITT=OFF -DWITH_TBB=OFF -DWITH_EIGEN=OFF

# 2) 编 libcimbar.dll 并替换 windows/libcimbar.dll
cmake -S ../native -B /tmp/cimbar_win_build -G Ninja \
  -DCMAKE_SYSTEM_NAME=Windows \
  -DCMAKE_C_COMPILER=$TC/x86_64-w64-mingw32-clang \
  -DCMAKE_CXX_COMPILER=$TC/x86_64-w64-mingw32-clang++ \
  -DCMAKE_RC_COMPILER=$TC/x86_64-w64-mingw32-windres \
  -DCMAKE_BUILD_TYPE=Release -DOpenCV_DIR=/tmp/opencv_mingw \
  -DCMAKE_SHARED_LINKER_FLAGS="-static"
cmake --build /tmp/cimbar_win_build -j$(nproc)
cp /tmp/cimbar_win_build/Release/libcimbar.dll ../windows/libcimbar.dll
```

**注意**：flutter_build 组装产物时，若 bundle 目录里已有同名 DLL 会跳过
拷贝——更新 `windows/libcimbar.dll` 后，需手动替换（或删除）已有 bundle
里的 `libcimbar.dll` 再运行，否则仍是旧版。原生库版本过旧会导致播放到
一定帧数后停止（缺少官方无限喷泉语义），应用状态栏会给出提示。

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
- Windows：确认 `libcimbar.dll` 与 exe 同目录（flutter_build 产物已自动带上；
  它静态链接 OpenCV，不需要额外的 OpenCV DLL）
- 修改原生代码后必须重新编译并复制到上述目录

**编码一直卡在 0 帧**
- 检查控制台是否报 `cimbare_init_encode failed`
- 文件名含非 ASCII 字符是支持的（fnsize 按 UTF-8 字节数传递）
