// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every route and every settings pane is in the design review: it names the
/// snapshots that picture it, or says why it has none.
///
/// The registry is `ui_review_coverage.txt`, one `kind|key|area|snapshots` row
/// per surface. `scripts/ui-review.sh` checks the other half, that each name
/// in it was really rendered.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';

import '../support/code_only.dart';

const _registry = 'test/gates/ui_review_coverage.txt';

typedef _Row = ({String kind, String key, String names});

List<_Row> _rows() {
  final rows = <_Row>[];
  for (final raw in File(_registry).readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split('|').map((p) => p.trim()).toList();
    if (parts.length != 4) {
      throw FormatException('want kind|key|area|snapshots', raw);
    }
    rows.add((kind: parts[0], key: parts[1], names: parts[3]));
  }
  return rows;
}

Set<String> _keys(List<_Row> rows, String kind) => {
  for (final row in rows)
    if (row.kind == kind) row.key,
};

/// The paths `router.dart` registers, resolved against `routes.dart`.
///
/// A route nested under the channel shell has a relative path.
Set<String> _routerPaths() {
  final constants = {
    for (final m in RegExp(
      r"static const (\w+) = '([^']*)';",
    ).allMatches(File('lib/src/routing/routes.dart').readAsStringSync()))
      m.group(1)!: m.group(2)!,
  };
  final source = File('lib/src/routing/router.dart').readAsStringSync();
  // Blanking keeps every index, so the path is read back from the source itself.
  final code = codeOnly(source);
  final paths = <String>{};
  for (final m in RegExp(r'GoRoute\(\s*path:').allMatches(code)) {
    final expression = source.substring(m.end, source.indexOf(',', m.end));
    var path = expression.trim();
    path = path.startsWith("'")
        ? path
              .substring(1, path.length - 1)
              .replaceAllMapped(
                RegExp(r'\$\{Routes\.(\w+)\}'),
                (r) => constants[r.group(1)]!,
              )
        : constants[path.substring('Routes.'.length)]!;
    paths.add(path.startsWith('/') ? path : '${constants['channels']}/$path');
  }
  return paths;
}

void main() {
  final rows = _rows();

  test('every route in the router has a row', () {
    final paths = _routerPaths();
    expect(paths.length, greaterThan(20), reason: 'the router was not read');
    expect(
      paths.difference(_keys(rows, 'route')),
      isEmpty,
      reason:
          'add route|<path>|<area>|<snapshot names> to $_registry, or '
          'exclude: <why> when the route has nothing to look at',
    );
  });

  test('every settings pane has a row', () {
    for (final (kind, index) in [
      ('settings', personalSettingsIndex),
      ('space', spaceSettingsIndex),
    ]) {
      expect(
        {for (final e in index) e.pane}.difference(_keys(rows, kind)),
        isEmpty,
        reason: 'add $kind|<pane>|<area>|<snapshot names> to $_registry',
      );
    }
  });

  test('no row names a route or pane that is gone', () {
    final known = {
      for (final path in _routerPaths()) 'route|$path',
      for (final e in personalSettingsIndex) 'settings|${e.pane}',
      for (final e in spaceSettingsIndex) 'space|${e.pane}',
    };
    expect([
      for (final row in rows)
        if (row.kind != 'surface' && !known.contains('${row.kind}|${row.key}'))
          '${row.kind}|${row.key}',
    ], isEmpty);
  });

  test('a surface has one row', () {
    final keys = [for (final row in rows) '${row.kind}|${row.key}'];
    expect(keys.length, keys.toSet().length);
  });

  test('a row says what covers it', () {
    expect([
      for (final row in rows)
        if (row.names.isEmpty) '${row.kind}|${row.key}',
    ], isEmpty);
  });
}
