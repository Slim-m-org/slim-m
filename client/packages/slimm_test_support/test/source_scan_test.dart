// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:slimm_test_support/source_gates.dart';
import 'package:test/test.dart';

void main() {
  test('directiveUris reads both quote styles and every conditional URI', () {
    final source = [
      "import 'a.dart';",
      'import "b.dart" as b;',
      "export 'c.dart' show C;",
      "import 'd_stub.dart'",
      "    if (dart.library.io) 'd_io.dart'",
      '    if (dart.library.js_interop) "d_web.dart";',
      "// import 'commented.dart';",
      '/*',
      "import 'blocked.dart';",
      '*/',
      'final s = "import \'in_string.dart\'";',
    ].join('\n');
    expect(directiveUris(source), [
      'a.dart',
      'b.dart',
      'c.dart',
      'd_stub.dart',
      'd_io.dart',
      'd_web.dart',
    ]);
  });

  test('callArguments returns the balanced argument text', () {
    const code = 'f(a, g(b, c), (d)) + h(e)';
    expect(callArguments(code, code.indexOf('(')), 'a, g(b, c), (d)');
    expect(callArguments('f(a, (b)', 1), isNull);
  });
}
