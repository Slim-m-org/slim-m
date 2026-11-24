// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared widgets folder and `api_failure.dart` sit below the features:
/// neither imports anything under `features/`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_test_support/source_gates.dart';

List<String> _featureImports(String source) => [
  for (final uri in directiveUris(source))
    if (uri.contains('features/')) uri,
];

void main() {
  test('src/widgets and api_failure import no feature', () {
    final files = [
      ...Directory('lib/src/widgets')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
      File('lib/src/api_failure.dart'),
    ];
    final found = {
      for (final file in files)
        if (_featureImports(file.readAsStringSync()).isNotEmpty)
          file.path: _featureImports(file.readAsStringSync()),
    };
    expect(found, isEmpty, reason: 'move the file into its feature instead');
  });

  test('a double-quoted or conditional feature import is seen', () {
    expect(_featureImports('import "../features/a/b.dart";'), hasLength(1));
    expect(
      _featureImports(
        "import 'a.dart' if (dart.library.io) '../features/a/b.dart';",
      ),
      hasLength(1),
    );
    expect(_featureImports("// import '../features/a/b.dart';"), isEmpty);
  });
}
