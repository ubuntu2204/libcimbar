import 'package:flutter_test/flutter_test.dart';
import 'package:libcimbar/src/models/cimbar_config.dart';

void main() {
  group('CimbarConfig', () {
    test('default constructor creates config with expected defaults', () {
      const config = CimbarConfig();

      expect(config.mode, CimbarMode.modeB);
      expect(config.compressionLevel, 16);
      expect(config.eccBytes, 30);
      expect(config.fps, 15);
      expect(config.imageSize, 1024);
      expect(config.encodeId, -1);
    });

    test('custom constructor sets all fields correctly', () {
      const config = CimbarConfig(
        mode: CimbarMode.mode4C,
        compressionLevel: 10,
        eccBytes: 20,
        fps: 30,
        encodeId: 42,
      );

      expect(config.mode, CimbarMode.mode4C);
      expect(config.compressionLevel, 10);
      expect(config.eccBytes, 20);
      expect(config.fps, 30);
      expect(config.imageSize, 1024);
      expect(config.encodeId, 42);
    });

    test('modeValue returns correct integer for each mode', () {
      expect(const CimbarConfig(mode: CimbarMode.mode4C).modeValue, 4);
      expect(const CimbarConfig(mode: CimbarMode.modeB).modeValue, 68);
      expect(const CimbarConfig(mode: CimbarMode.modeBm).modeValue, 67);
      expect(const CimbarConfig(mode: CimbarMode.modeBu).modeValue, 66);
    });

    test('copyWith creates a new instance with overridden values', () {
      const original = CimbarConfig();
      final modified = original.copyWith(
        mode: CimbarMode.mode4C,
        compressionLevel: 5,
      );

      expect(modified.mode, CimbarMode.mode4C);
      expect(modified.compressionLevel, 5);
      // Unchanged fields retain original values
      expect(modified.eccBytes, original.eccBytes);
      expect(modified.fps, original.fps);
      expect(modified.imageSize, original.imageSize);
      expect(modified.encodeId, original.encodeId);
    });

    test('copyWith with no arguments returns equivalent config', () {
      const original = CimbarConfig(
        mode: CimbarMode.modeBm,
        compressionLevel: 8,
        eccBytes: 25,
        fps: 20,
        encodeId: 10,
      );
      final copy = original.copyWith();

      expect(copy.mode, original.mode);
      expect(copy.compressionLevel, original.compressionLevel);
      expect(copy.eccBytes, original.eccBytes);
      expect(copy.fps, original.fps);
      expect(copy.imageSize, original.imageSize);
      expect(copy.encodeId, original.encodeId);
    });

    test('toString produces human-readable output', () {
      const config = CimbarConfig();
      final str = config.toString();

      expect(str, contains('CimbarConfig'));
      expect(str, contains('modeB'));
      expect(str, contains('compression: 16'));
      expect(str, contains('ecc: 30'));
      expect(str, contains('fps: 15'));
      expect(str, contains('imageSize: 1024'));
      expect(str, contains('encodeId: -1'));
    });

    test('const constructor produces equal instances', () {
      const a = CimbarConfig();
      const b = CimbarConfig();

      expect(a.mode, b.mode);
      expect(a.compressionLevel, b.compressionLevel);
      expect(a.eccBytes, b.eccBytes);
      expect(a.fps, b.fps);
      expect(a.imageSize, b.imageSize);
      expect(a.encodeId, b.encodeId);
    });

    test('compression level boundary values', () {
      const minConfig = CimbarConfig(compressionLevel: 0);
      expect(minConfig.compressionLevel, 0);

      const maxConfig = CimbarConfig(compressionLevel: 22);
      expect(maxConfig.compressionLevel, 22);
    });

    test('encodeId boundary values', () {
      const autoConfig = CimbarConfig(encodeId: -1);
      expect(autoConfig.encodeId, -1);

      const minConfig = CimbarConfig(encodeId: 0);
      expect(minConfig.encodeId, 0);

      const maxConfig = CimbarConfig(encodeId: 127);
      expect(maxConfig.encodeId, 127);
    });
  });

  group('CimbarMode', () {
    test('all modes have unique integer values', () {
      final values = CimbarMode.values.map((m) => m.value).toSet();
      expect(values.length, CimbarMode.values.length);
    });

    test('fromValue returns correct mode for known values', () {
      expect(CimbarMode.fromValue(4), CimbarMode.mode4C);
      expect(CimbarMode.fromValue(68), CimbarMode.modeB);
      expect(CimbarMode.fromValue(67), CimbarMode.modeBm);
      expect(CimbarMode.fromValue(66), CimbarMode.modeBu);
    });

    test('fromValue returns modeB as default for unknown values', () {
      expect(CimbarMode.fromValue(0), CimbarMode.modeB);
      expect(CimbarMode.fromValue(999), CimbarMode.modeB);
      expect(CimbarMode.fromValue(-1), CimbarMode.modeB);
    });

    test('each mode has a positive integer value', () {
      for (final mode in CimbarMode.values) {
        expect(mode.value, greaterThan(0));
      }
    });
  });

  group('CimbarImageFormat', () {
    test('all formats have unique integer values', () {
      final values = CimbarImageFormat.values.map((f) => f.value).toSet();
      expect(values.length, CimbarImageFormat.values.length);
    });

    test('rgb format has value 3', () {
      expect(CimbarImageFormat.rgb.value, 3);
    });

    test('rgba format has value 4', () {
      expect(CimbarImageFormat.rgba.value, 4);
    });

    test('nv12 format has value 12', () {
      expect(CimbarImageFormat.nv12.value, 12);
    });

    test('yuv420 format has value 420', () {
      expect(CimbarImageFormat.yuv420.value, 420);
    });

    test('enum has exactly 4 values', () {
      expect(CimbarImageFormat.values.length, 4);
    });
  });
}
