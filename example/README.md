# libcimbar Example App

Demonstrates the full workflow of the `libcimbar` Dart/Flutter plugin.

## What This App Does

### Encoder Page (Windows Desktop)
1. Press **Alt+A** to activate screen region selection
2. Drag to select a rectangular area on screen
3. The selected region is captured as raw pixels
4. Pixels are compressed to **AVIF** format
5. AVIF data is encoded into **cimbar barcode** frames
6. Frames are displayed as an **animated sequence** on screen

### Decoder Page (Android / Web)
1. Tap "Start Camera" to open the device camera
2. Point the camera at a screen displaying cimbar barcodes
3. Frames are decoded in real-time via fountain codes
4. Progress bar shows decoding progress
5. Once complete, the original file is recovered and saved

## Running the Example

### Prerequisites

Make sure you've built the native libraries first:

```bash
# Windows (for encoder)
cd ../native
build_windows.bat C:\project\libcimbar\libcimbar
# Copy libcimbar.dll to example/build/windows/x64/runner/Release/

# Web/WASM (for web decoder)
cd ../native
bash build_wasm.sh /path/to/libcimbar
# Copy libcimbar.js and libcimbar.wasm to web/assets/wasm/
```

### Windows

```bash
flutter run -d windows
```

The app will show the **Encoder** tab by default:
- Use the "Capture Screen (Alt+A)" button or press Alt+A
- Select a screen region
- Click "Encode & Display" to generate cimbar barcode animation

### Android

```bash
flutter run -d <device-id>
```

The app will show the **Decoder** tab:
- Grant camera permission when prompted
- Tap "Start Camera"
- Point at a screen showing cimbar barcodes

### Web

```bash
flutter run -d chrome

adb reverse tcp:8080 tcp:8080
flutter run -d web-server --release --web-port 8080 --web-hostname 0.0.0.0
手机访问localhost:8080
```

Make sure the WASM files are in `web/assets/wasm/`:
- `libcimbar.js`
- `libcimbar.wasm`

## Architecture

```
┌─────────────────────────────────────┐
│           Example App               │
│                                     │
│  ┌───────────┐  ┌───────────────┐  │
│  │  Encoder   │  │   Decoder     │  │
│  │  Page      │  │   Page        │  │
│  │ (Windows)  │  │ (Android/Web) │  │
│  └─────┬─────┘  └──────┬────────┘  │
│        │               │            │
│  ┌─────▼───────────────▼─────────┐  │
│  │    libcimbar Plugin            │  │
│  │  (abstract interfaces)         │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
```

The example app only calls the abstract interfaces provided by the `libcimbar` package. It does not access native code directly.

## Source Files

| File | Description |
|------|-------------|
| `lib/main.dart` | App entry point, navigation between encoder/decoder |
| `lib/encoder_page.dart` | Screen capture → AVIF → cimbar encoding UI |
| `lib/decoder_page.dart` | Camera → cimbar decoding UI |
| `lib/screen_select_overlay.dart` | Fullscreen transparent overlay for region selection |

## Troubleshooting

**"Native library not loaded"** (Windows)
- Ensure `libcimbar.dll` is in the same directory as the executable
- Check that OpenCV DLLs are also available in PATH

**Camera not working** (Android)
- Ensure camera permission is granted
- Check that the device has a rear camera

**WASM not loading** (Web)
- Verify `libcimbar.js` and `libcimbar.wasm` exist in `web/assets/wasm/`
- Check browser console for errors
