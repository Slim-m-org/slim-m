// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The server replays these fixtures through its own theme checks, so they
/// have to be exactly what this client exports for each built-in preset.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Brightness;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

final _fixtures = Directory(
  '../../../crates/slimm-server/tests/fixtures/space_themes',
);

Map<String, dynamic> _exported(String base) => ThemeDocument.of(
      themeBases[base]!,
      name: base,
      author: 'built-in',
      base: base,
      brightness: base == 'light' ? Brightness.light : Brightness.dark,
    ).toJson();

void main() {
  test('there is a fixture for every built-in preset and no other', () {
    final names = [
      for (final f in _fixtures.listSync())
        f.uri.pathSegments.last.replaceFirst('.json', ''),
    ]..sort();
    expect(names, themeBases.keys.toList()..sort());
  });

  for (final base in themeBases.keys) {
    final file = File('${_fixtures.path}/$base.json');

    test('the $base fixture is what the client exports', () {
      expect(jsonDecode(file.readAsStringSync()), _exported(base));
    });

    test('the $base fixture passes the client checks', () {
      expect(parseThemeFile(file.readAsStringSync()).problems, isEmpty);
    });
  }
}
