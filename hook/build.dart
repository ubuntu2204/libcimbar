// Build hook for libcimbar.
//
// Most platforms ship a prebuilt binary inside the package, so they need no
// work here:
//   Android → android/src/main/jniLibs/<abi>/libcimbar_jni.so (Gradle merges
//             it into the APK, no NDK/CMake needed)
//   Windows → windows/libcimbar.dll (copied next to the .exe by CMake)
//   Web     → assets/wasm/*.wasm (Flutter asset; not a code asset at all)
//
// Linux has no usable prebuilt (glibc/distro differences), so this hook
// compiles the vendored C++ core from `third_party/libcimbar` with CMake.
//
// OpenCV is the only external dependency. Pick it up from (in order):
//   1. hooks.user_defines.libcimbar.opencv_dir   (apps can pin their own)
//   2. `-DOpenCV_DIR` if the caller exported it (not possible here: hooks run
//      in a semi-hermetic env where only a whitelist of variables survives)
//   3. the system OpenCV (pkg-config / default CMake search paths)
//
// Configure in the app's pubspec.yaml:
//   hooks:
//     user_defines:
//       libcimbar:
//         opencv_dir: /opt/opencv/lib/cmake/opencv4
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// File name the Dart side loads on Linux (see CimbarNative._loadLibrary).
const _linuxLibraryName = 'libcimbar.so';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Web builds (and any target without code assets) have nothing to do.
    if (!input.config.buildCodeAssets) return;

    if (input.config.code.targetOS != OS.linux) {
      // Prebuilt binaries in the package cover Android/Windows; macOS/iOS are
      // not supported by this plugin.
      return;
    }

    // Opt-in. Compiling from source needs OpenCV, and as of Flutter 3.47 the
    // Linux desktop target does not bundle native assets into the app bundle
    // yet (the build hook runs and produces libcimbar.so, but the app bundle
    // does not receive it), so failing every Linux build by default would only
    // break apps that already ship the library another way.
    //
    // Enable with:
    //   hooks:
    //     user_defines:
    //       libcimbar:
    //         build: true
    //         opencv_dir: /path/to/opencv/lib/cmake/opencv4   # optional
    if (input.userDefines['build'] != true) return;

    final packageRoot = input.packageRoot;
    final nativeDir = packageRoot.resolve('native/');
    final buildDir = input.outputDirectory;

    final opencvDir = input.userDefines['opencv_dir'];
    if (opencvDir != null && opencvDir is! String) {
      throw FormatException(
        'hooks.user_defines.libcimbar.opencv_dir must be a string '
        '(or omitted), got ${opencvDir.runtimeType}.',
      );
    }

    buildDir.toFilePath(); // fail fast on a non-file URI
    Directory.fromUri(buildDir).createSync(recursive: true);

    await _run('cmake', <String>[
      '-S',
      nativeDir.toFilePath(),
      '-B',
      buildDir.toFilePath(),
      '-DCMAKE_BUILD_TYPE=Release',
      if (opencvDir case final String dir) '-DOpenCV_DIR=$dir',
    ]);
    await _run('cmake', <String>[
      '--build',
      buildDir.toFilePath(),
      '--config',
      'Release',
      '--parallel',
      '${Platform.numberOfProcessors}',
    ]);

    final library = _findLibrary(buildDir);
    if (library == null) {
      throw StateError(
        'libcimbar build finished but $_linuxLibraryName was not found under '
        '${buildDir.toFilePath()}. Check the CMake output above (a missing '
        'OpenCV is the usual cause — set '
        'hooks.user_defines.libcimbar.opencv_dir).',
      );
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/ffi/cimbar.dart',
        linkMode: DynamicLoadingBundled(),
        file: library,
      ),
    );
  });
}

/// CMake may place the library in the build root or in a config subdir,
/// depending on the generator, so search instead of assuming a path.
Uri? _findLibrary(Uri buildDir) {
  final dir = Directory.fromUri(buildDir);
  if (!dir.existsSync()) return null;
  final matches = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.uri.pathSegments.last == _linuxLibraryName)
      .toList()
    // Prefer the shallowest match (build root over nested intermediates).
    ..sort((a, b) => a.uri.pathSegments.length.compareTo(
          b.uri.pathSegments.length,
        ));
  return matches.isEmpty ? null : matches.first.uri;
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError(
      '`$executable ${arguments.join(' ')}` failed with exit code '
      '${result.exitCode}:\n${result.stdout}\n${result.stderr}',
    );
  }
}
