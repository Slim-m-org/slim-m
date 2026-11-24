// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The transport replays every PUT and DELETE after a dropped socket, so a
/// route joins that set only by being listed in `replayed_routes.txt`.
library;

import 'dart:io';

import 'package:test/test.dart';

final _call = RegExp(r"""send\(\s*'(PUT|DELETE)',\s*'([^']+)'""");

String _withoutComments(String source) =>
    source.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

Set<String> _sentRoutes() {
  final found = <String>{};
  for (final file in Directory('lib/src').listSync().whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    final source = _withoutComments(file.readAsStringSync());
    for (final m in _call.allMatches(source)) {
      found.add('${m[1]} ${m[2]}');
    }
  }
  return found;
}

void main() {
  final decided = File('test/replayed_routes.txt')
      .readAsLinesSync()
      .where((l) => l.isNotEmpty)
      .toSet();

  test('every PUT and DELETE the client sends is a decided replay', () {
    expect(
      _sentRoutes().difference(decided),
      isEmpty,
      reason: 'a new PUT or DELETE is replayed after a dropped socket; show '
          'a repeat answers the same and writes nothing twice, then list it '
          'in test/replayed_routes.txt',
    );
  });

  test('the list holds no route the client no longer sends', () {
    expect(decided.difference(_sentRoutes()), isEmpty);
  });
}
