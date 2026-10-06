// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `path` op's `d` string is chosen by the module, so the work done on it
/// is bounded here by counting code units looked at or copied, never by how
/// long a run happened to take.
///
/// A sign right after an exponent letter never ends a number, so
/// `1e-e-e-e...` keeps one number open for the whole string: the tokeniser
/// used to copy that growing buffer on every sign, which is quadratic.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/module_scene.dart';
import 'package:slimm_app/src/widgets/module_scene_path.dart';

/// Code units the tokeniser touched for [d].
int _work(String d) {
  scenePathWork = 0;
  parseScenePathData(d);
  return scenePathWork;
}

void main() {
  group('the length ceiling', () {
    test(
      'a d string over the ceiling parses to nothing and is never scanned',
      () {
        final d = 'M0 0${' L1 1' * sceneMaxPathChars}';

        expect(d.length, greaterThan(sceneMaxPathChars));
        expect(_work(d), 0);
        expect(parseScenePathData(d), isEmpty);
      },
    );

    test('a d string at the ceiling is still parsed', () {
      final d = ('M0 0 ${'L1 1 ' * sceneMaxPathChars}').substring(
        0,
        sceneMaxPathChars,
      );

      expect(d.length, sceneMaxPathChars);
      expect(parseScenePathData(d), isNotEmpty);
    });

    test('an op whose d is over the ceiling is dropped from the scene', () {
      final d = 'M0 0${' L1 1' * sceneMaxPathChars}';
      final scene = parseModuleScene(
        '{"\$slim":"scene/1","width":100,"height":100,'
        '"ops":[{"op":"path","d":"$d","stroke":"#fff"}]}',
      );

      expect(scene?.ops ?? const [], isEmpty);
    });
  });

  group('the work done on a string inside the ceiling', () {
    test(
      'an exponent chain costs no more than a few passes over the string',
      () {
        final d = 'M0 0 1e${'-e' * (sceneMaxPathChars ~/ 2 - 8)}';

        expect(d.length, lessThanOrEqualTo(sceneMaxPathChars));
        expect(_work(d), inInclusiveRange(d.length, 3 * d.length));
      },
    );

    test('work grows with the length of the string, not with its square', () {
      final small = 'M0 0 1e${'-e' * 2000}';
      final large = 'M0 0 1e${'-e' * 8000}';

      final ratio = _work(large) / _work(small);

      expect(ratio, lessThan(5), reason: 'four times the input, linear work');
    });

    test('a long run of digits and dots is also a few passes at most', () {
      final d = 'M${'1.' * (sceneMaxPathChars ~/ 2 - 2)}';

      expect(_work(d), inInclusiveRange(d.length, 3 * d.length));
    });
  });

  group('the tokeniser still reads numbers the same way', () {
    test('signs, dots and exponents separate and join numbers as before', () {
      final steps = parseScenePathData('M1-2L.5.5L1e-2+3');

      expect(steps[0].points, [1.0, -2.0]);
      expect(steps[1].points, [0.5, 0.5]);
      expect(steps[2].points, [0.01, 3.0]);
    });
  });
}
