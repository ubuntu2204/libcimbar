# decode_example

libcimbar Web/Android **解码接收端**示例应用。

## 运行

```bash
# Web
cd ~/project/libcimbar/decode_example
flutter run -d chrome

# 手机访问（同一局域网 / adb 反向代理）
flutter run -d web-server --release --web-port 8080 --web-hostname 0.0.0.0
adb reverse tcp:8080 tcp:8080
# 手机浏览器访问 http://localhost:8080

# Android
flutter run -d <android-device-id>

# eg.
flutter run -d PGJM10
```


调试钩子：在 URL 后加 `?autostart=1` 可跳过点击直接开启摄像头（端到端测试用）。

## 功能

- 通过摄像头扫描 cimbar 条码（Web 走 VideoFrame 原生 YUV 直通，Android 走 CameraX）
- 实时喷泉解码，达到阈值后自动重组文件
- 解码完成后按条码里携带的原始文件名自动保存
- 支持保存摄像头帧（含 NV12 / YUV420 灰度）用于调试

## WASM 模块

Web 端解码依赖 Emscripten 编译的 libcimbar。若 `web/assets/wasm/` 下没有文件，
页面会提示 "WASM module not available"：

```bash
# 1. 安装 Emscripten
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk && ./emsdk install latest && ./emsdk activate latest
source emsdk_env.sh

# 2. 编译 WASM
cd /home/ubuntu/project/libcimbar/native && ./build_wasm.sh

# 3. 复制到 decode_example 的 web assets
mkdir -p ../decode_example/web/assets/wasm/
cp build_wasm/libcimbar.js ../decode_example/web/assets/wasm/
cp build_wasm/libcimbar.wasm ../decode_example/web/assets/wasm/
cp build_wasm/cimbar_js.wasm ../decode_example/web/assets/wasm/

# 4. 重新构建
cd ../decode_example && flutter build web
```

Android 端**不使用** WASM：它直接 FFI 绑定 `libcimbar_jni.so`（同一套 C API、
同一个 C++ 核心，由 Flutter 构建系统用 CMake 自动编译）。
