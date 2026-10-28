// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared widgets folder and `api_failure.dart` sit below the features:
/// neither imports anything under `features/`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Directives start a line, so a commented-out import never matches.
final _directive = RegExp(r"^(?:import|export) '([^']+)'", multiLine: true);

List<String> _featureImports(File file) => [
  for (final match in _directive.allMatches(file.readAsStringSync()))
    if (match.group(1)!.contains('features/')) match.group(1)!,
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
        if (_featureImports(file).isNotEmpty) file.path: _featureImports(file),
    };
    expect(found, isEmpty, reason: 'move the file into its feature instead');
  });
}
