// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:io';

import 'package:slimm_test_support/source_gates.dart';
import 'package:test/test.dart';

String _lines(List<String> lines) => lines.join('\n');

void main() {
  group('codeOnly', () {
    test('blanks comments and string content but keeps every index', () {
      const source = "final a = 'catch (_) {}'; // catch (_) {}\n/* x */ b();";
      final code = codeOnly(source);
      expect(code.length, source.length);
      expect(code.contains('catch'), isFalse);
      expect(code, contains('final a ='));
      expect(code, endsWith('b();'));
      expect('\n'.allMatches(code).length, '\n'.allMatches(source).length);
    });

    test('a raw string ending in a backslash closes at its own quote', () {
      final code = codeOnly(r"final p = r'\'; final q = 'catch (_) {}';");
      expect(code.contains('catch'), isFalse);
      expect(code, contains('final q ='));
    });

    test('code after a raw string ending in a backslash is still code', () {
      final code = codeOnly(
        _lines([
          r"final p = path.replaceAll(r'\', '/');",
          'try {} catch (_) {}',
        ]),
      );
      expect(code, contains('catch (_) {}'));
    });

    test('an escaped quote in an ordinary string stays inside the string', () {
      final code = codeOnly(r"final s = 'it\'s a catch (_) {}'; call();");
      expect(code.contains('catch'), isFalse);
      expect(code, contains('call();'));
    });

    test('a double slash inside a string is not a comment', () {
      final code = codeOnly("final u = 'https://x.dev'; real();");
      expect(code, contains('real();'));
    });

    test('triple-quoted strings blank across lines and keep line breaks', () {
      final source =
          _lines(["final s = '''", "it's // not code", "''';", 'x();']);
      final code = codeOnly(source);
      expect(code.contains('not code'), isFalse);
      expect(code, endsWith('x();'));
      expect('\n'.allMatches(code).length, '\n'.allMatches(source).length);
    });

    test('code inside an interpolation is kept, with nested strings blanked',
        () {
      final code = codeOnly(r"final s = 'a ${m['k'] + g()} b'; done();");
      expect(code, contains('g()'));
      expect(code.contains("'k'"), isFalse);
      expect(code, contains('done();'));
    });

    test('a single-line string ends at its line break', () {
      final code = codeOnly(_lines(["final broken = 'oops;", 'real();']));
      expect(code, contains('real();'));
    });

    test('an r that ends an identifier is not a raw prefix', () {
      final code = codeOnly(r"final x = bar'\'; catch (_) {}';");
      expect(code.contains('catch'), isFalse);
    });
  });

  group('stripComments', () {
    test('blanks comments and leaves string literals as they were', () {
      final code = stripComments("call('/a/b'); // call('/c')\n/* d */ e();");
      expect(code, contains("call('/a/b');"));
      expect(code.contains('/c'), isFalse);
      expect(code, endsWith('e();'));
    });

    test('a comment marker inside a string is not a comment', () {
      expect(stripComments("f('//x'); g();"), "f('//x'); g();");
    });
  });

  group('repoRoot', () {
    test('finds the directory that holds schema/openapi.yaml', () {
      expect(File('${findRepoRoot().path}/schema/openapi.yaml').existsSync(),
          isTrue);
    });

    test('names where it looked when there is no repository above', () {
      expect(
        () => findRepoRoot(Directory.systemTemp),
        throwsA(isA<StateError>()),
      );
    });
  });
}
