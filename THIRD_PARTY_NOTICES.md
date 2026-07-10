# Third-Party Notices

This project includes or depends on the following third-party software.

## libcimbar (C++ Core)

- **Source**: https://github.com/sz3/libcimbar
- **License**: Mozilla Public License 2.0 (MPL-2.0)
- **Copyright**: Copyright (c) 2020-2024, Sam Zen (sz3)
- **Usage**: The C++ encoding/decoding core is compiled as a shared library
  and loaded at runtime via FFI (Windows), JNI (Android), or WASM (Web).

## zstd (Zstandard Compression)

- **Source**: https://github.com/facebook/zstd
- **License**: BSD 3-Clause / GPLv2 (dual-licensed)
- **Copyright**: Copyright (c) Meta Platforms, Inc. and affiliates.
- **Usage**: Statically linked into the libcimbar shared library for data
  compression in the cimbar encoding pipeline.

## Wirehair (Fountain Codes)

- **Source**: https://github.com/catid/wirehair
- **License**: BSD 3-Clause
- **Copyright**: Copyright (c) 2012-2020, Christopher A. Taylor
- **Usage**: Statically linked for fountain code encoding/decoding, enabling
  data recovery from any N+1 received frames.

## libcorrect (Reed-Solomon Error Correction)

- **Source**: https://github.com/quiet/libcorrect
- **License**: BSD 3-Clause
- **Copyright**: Copyright (c) 2016, quiet/libcorrect authors
- **Usage**: Statically linked for Reed-Solomon error correction with
  interleaving in the cimbar tile grid.

## OpenCV (Computer Vision Library)

- **Source**: https://github.com/opencv/opencv
- **License**: Apache License 2.0
- **Copyright**: Copyright (c) 2000-2024, Intel Corporation / OpenCV authors
- **Usage**: Runtime dependency for image processing operations (tile rendering,
  color space conversion, image resizing).

## cxxopts (C++ Command-Line Option Parser)

- **Source**: https://github.com/jarro2783/cxxopts
- **License**: MIT
- **Copyright**: Copyright (c) 2014-2023, Jarryd Beck
- **Usage**: Header-only library included in the libcimbar source tree.

## base91

- **Source**: http://base91.sourceforge.net/
- **License**: BSD-style
- **Copyright**: Copyright (c) 2000-2006 Joachim Henke
- **Usage**: Header-only library for compact binary-to-text encoding.

## libpopcnt

- **Source**: https://github.com/kimwalisch/libpopcnt
- **License**: BSD 2-Clause
- **Copyright**: Copyright (c) 2016-2023, Kim Walisch
- **Usage**: Header-only library for fast population count (popcount) operations.

---

## Dart/Flutter Dependencies (via pub.dev)

The following Dart packages are declared as dependencies in `pubspec.yaml`
and are resolved at build time. Each is governed by its own license:

| Package | License |
|---------|---------|
| `flutter` (SDK) | BSD 3-Clause |
| `ffi` | BSD 3-Clause |
| `plugin_platform_interface` | BSD 3-Clause |
| `camera` | BSD 3-Clause |
| `image` | MIT |
| `hotkey_manager` | MIT |
| `screen_retriever` | MIT |
| `js` | BSD 3-Clause |
| `flutter_test` (SDK) | BSD 3-Clause |
| `flutter_lints` | BSD 3-Clause |
| `ffigen` | BSD 3-Clause |

For full license texts of these packages, refer to their respective
repositories or the LICENSE files included in each package on pub.dev.
