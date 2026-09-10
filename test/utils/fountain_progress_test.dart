// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:libcimbar/src/utils/fountain_progress.dart';

void main() {
  group('parseFountainProgress', () {
    test('parses the native per-stream progress list', () {
      // Format produced by cimbar_recv_js.cpp after fountain_decode:
      // fmt::format("[ {} ]", turbo::str::join(_sink->get_progress(), ','))
      expect(parseFountainProgress('[ 0.333333,0.5 ]'),
          closeToList([0.333333, 0.5]));
      expect(parseFountainProgress('[0.333333]'), closeToList([0.333333]));
      expect(parseFountainProgress('[ 1 ]'), closeToList([1.0]));
    });

    test('empty stream list (no in-flight streams)', () {
      expect(parseFountainProgress('[ ]'), isEmpty);
      expect(parseFountainProgress('[]'), isEmpty);
    });

    test('scan diagnostics are not progress and must be ignored', () {
      // The report string is reused by scan_extract_decode for
      // "sce: ..., imgdec: ..." — callers keep the last known progress
      // when the shape does not match.
      expect(parseFountainProgress('sce: 5.2, imgdec: 11.3'), isEmpty);
      expect(parseFountainProgress(''), isEmpty);
      expect(parseFountainProgress('fountain decode res is 1190133760'),
          isEmpty);
    });

    test('malformed bracket contents yield no progress', () {
      expect(parseFountainProgress('[ abc ]'), isEmpty);
      expect(parseFountainProgress('[ 0.5, ]'), isEmpty);
      // Unbalanced brackets.
      expect(parseFountainProgress('[ 0.5'), isEmpty);
      expect(parseFountainProgress(' 0.5 ]'), isEmpty);
    });

    test('values outside 0..1 are clamped', () {
      expect(parseFountainProgress('[ 1.2,-0.5 ]'), closeToList([1.0, 0.0]));
    });
  });

  group('maxFountainProgress', () {
    test('picks the most-complete stream', () {
      expect(maxFountainProgress([0.2, 0.9, 0.5]), 0.9);
      expect(maxFountainProgress([0.25]), 0.25);
    });

    test('empty means zero', () {
      expect(maxFountainProgress(const []), 0.0);
    });
  });
}

/// listEquals with tolerance, for the parsed doubles.
Matcher closeToList(List<double> expected) => _CloseToList(expected);

class _CloseToList extends Matcher {
  final List<double> _expected;
  _CloseToList(this._expected);

  @override
  bool matches(dynamic item, Map matchState) {
    if (item is! List || item.length != _expected.length) return false;
    for (var i = 0; i < _expected.length; i++) {
      final v = item[i];
      if (v is! num || (v - _expected[i]).abs() > 1e-9) return false;
    }
    return true;
  }

  @override
  Description describe(Description description) =>
      description.add('equals within 1e-9: $_expected');

  @override
  Description describeMismatch(
      dynamic item, Description mismatchDescription, Map matchState, bool verbose) {
    if (item is! List) {
      return mismatchDescription.add('is not a List');
    }
    return mismatchDescription.add('was $item');
  }
}
