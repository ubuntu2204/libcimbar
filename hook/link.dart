// Link hook for libcimbar.
//
// Why this exists: the Dart side loads the native library through
// `DynamicLibrary.open('libcimbar.so')` (see CimbarNative._loadLibrary) rather
// than through `@Native` external functions. Dart 3.13 tree-shakes code assets
// by *recorded usage*, so a build with no `@Native` references gets its asset
// dropped from the bundle — the build hook would compile libcimbar and the
// linker would then throw it away.
//
// Until the bindings are migrated to `@Native` (which restores real
// tree-shaking), this link hook simply keeps every code asset.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await link(args, (input, output) async {
    output.assets.code.addAll(input.assets.code);
  });
}
