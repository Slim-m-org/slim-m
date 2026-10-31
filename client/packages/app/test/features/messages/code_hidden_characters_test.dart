// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hidden-character set is one JSON fixture, read here and by the server's
/// `hidden_chars.rs` test, so the two classifiers cannot disagree about any
/// code point. Tab, line feed and carriage return are layout inside a code
/// block, so the client alone exempts them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/code_hidden_characters.dart';

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  while (!File('${dir.path}/schema/openapi.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('repo root not found');
    dir = parent;
  }
  return dir;
}

int _hex(Object? value) => int.parse(value! as String, radix: 16);

void main() {
  final fixture =
      jsonDecode(
            File(
              '${_repoRoot().path}/crates/slimm-server/tests/fixtures/hidden_chars.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final ranges = [
    for (final r in (fixture['hidden'] as List).cast<Map<String, dynamic>>())
      (_hex(r['from']), _hex(r['to'])),
  ];
  final exempt = {
    for (final c in fixture['code_layout_exempt'] as List) _hex(c),
  };

  test('every code point agrees with the shared fixture', () {
    final wrong = <String>[];
    for (var c = 0; c <= 0x10FFFF; c++) {
      if (c >= 0xD800 && c <= 0xDFFF) continue;
      final listed = ranges.any((r) => c >= r.$1 && c <= r.$2);
      final expected = listed && !exempt.contains(c);
      if (isHiddenCodeCharacter(c) != expected) {
        wrong.add('U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}');
      }
    }
    expect(wrong, isEmpty, reason: 'disagree with hidden_chars.json');
  });

  test('ordinary text and the emoji variation selector stay visible', () {
    for (final c in fixture['plain'] as List) {
      expect(isHiddenCodeCharacter(_hex(c)), isFalse, reason: '$c');
    }
  });
}
