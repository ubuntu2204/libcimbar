# Contributing to libcimbar

Thank you for your interest in contributing! This document provides guidelines for contributing to the Dart/Flutter plugin for [libcimbar](https://github.com/sz3/libcimbar).

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Ensure you have Flutter 3.10+ installed
4. Run `flutter pub get` in both the root and `example/` directories

## Project Structure

```
libcimbar/
├── lib/
│   ├── libcimbar.dart              # Main library exports
│   └── src/
│       ├── interfaces/             # Abstract interfaces (ICimbarEncoder, etc.)
│       ├── ffi/                    # dart:ffi bindings (Windows/Linux/macOS)
│       ├── impl/                   # Platform-specific implementations
│       ├── web/                    # JS interop (WASM)
│       ├── models/                 # Data models
│       └── cimbar_platform.dart    # Platform registry
├── android/                        # Android native plugin (Kotlin + JNI)
├── native/                         # CMake build scripts
├── test/                           # Unit and widget tests
└── example/                        # Example Flutter application
```

## Development Workflow

### Running Tests

```bash
flutter test
```

### Building the Native Library

**Linux** — the platform used for day-to-day development and testing:

```bash
cd native && mkdir -p build_linux && cd build_linux
cmake .. -DCMAKE_BUILD_TYPE=Release && cmake --build . -j$(nproc)
# Output: build_linux/libcimbar.so
```

**Windows** — cross-compiled from Ubuntu with
[flutter_build](https://github.com/ubuntu2610/flutter_build); there is no
Windows toolchain in the dev loop:

```bash
cd native
build_windows.bat /path/to/libcimbar
```

**Web (WASM)** — used by `decode_example` (the decoder app):

```bash
source /path/to/emsdk/emsdk_env.sh
cd native && bash build_wasm.sh /path/to/libcimbar
# Copy the output into decode_example/web/assets/wasm/
```

### Code Style

- Follow the [Dart style guide](https://dart.dev/effective-dart)
- Use `dart format` to format your code
- Ensure all public APIs have doc comments
- Prefer interfaces over concrete implementations

## Pull Request Process

1. Create a feature branch from `main`
2. Write tests for new functionality
3. Ensure all existing tests pass (`flutter test`)
4. Update the CHANGELOG.md with your changes
5. Submit a pull request with a clear description

## Reporting Issues

- Use GitHub Issues for bug reports and feature requests
- Include platform, Flutter version, and reproduction steps
- For issues with the upstream C++ library, report at [sz3/libcimbar](https://github.com/sz3/libcimbar/issues)

## License

By contributing, you agree that your contributions will be licensed under the [Mozilla Public License 2.0](LICENSE).
