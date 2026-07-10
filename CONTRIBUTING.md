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

### Building the Native Library (Windows)

```bash
cd native
build_windows.bat C:\project\libcimbar\libcimbar
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
