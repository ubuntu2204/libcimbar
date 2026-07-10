## 0.1.0

### Initial Release

- **Core encoding**: Convert binary data into cimbar barcode frame images via dart:ffi (Windows) or MethodChannel (Android)
- **Core decoding**: Decode cimbar barcode images back into binary data using fountain codes
- **Screen capture** (Windows): Win32 GDI-based screen region capture with Alt+A hotkey
- **AVIF compression**: Compress screenshots to AVIF format before encoding (with PNG fallback)
- **Camera scanning** (Android): CameraX integration for real-time barcode scanning
- **Web support** (WASM): JS interop bindings for Emscripten-compiled libcimbar
- **Abstract interfaces**: All APIs exposed as interfaces (`ICimbarEncoder`, `ICimbarDecoder`, `IScreenCapture`, `ICameraCapture`, `IImageCompressor`) for testability and extensibility
- **Encoding modes**: mode4C (16×16, best compatibility), modeB (24×24, default), modeBm (24×24, monochrome), modeBu (24×24, variant)
- **Example app**: Complete Flutter example with encoder page (Windows) and decoder page (Android/Web)
- **Native build scripts**: CMake scripts for Windows DLL, Android .so, and WASM compilation
