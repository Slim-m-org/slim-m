// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared plumbing for the shrink-only source gates: read an allowlist of
/// `path count` lines, count a pattern per file in comment-free code, and
/// compare the two both ways.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/code_only.dart';

Map<String, int> readAllowlist(String path) => {
  for (final line in File(path).readAsLinesSync())
    if (line.trim().isNotEmpty && !line.startsWith('#'))
      line.split(' ').first: int.parse(line.split(' ').last),
};

/// Matches of [pattern] in each Dart file under [root] accepted by [include],
/// keyed by path relative to `lib/src`, files with none left out.
Map<String, int> countByFile(
  String root,
  RegExp pattern, {
  bool Function(String relative)? include,
}) {
  final found = <String, int>{};
  for (final file in Directory(root).listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.dart')) continue;
    final relative = file.path.substring('lib/src/'.length);
    if (include != null && !include(relative)) continue;
    final count = pattern.allMatches(codeOnly(file.readAsStringSync())).length;
    if (count > 0) found[relative] = count;
  }
  return found;
}

/// Fails on any file above its allowance, and on any allowance now too high.
void expectRatchet(
  Map<String, int> found,
  Map<String, int> allowed, {
  required String what,
  required String allowlist,
}) {
  final grew = {
    for (final e in found.entries)
      if (e.value > (allowed[e.key] ?? 0)) e.key: e.value,
  };
  expect(grew, isEmpty, reason: '$what: no new ones, see $allowlist');
  final stale = {
    for (final e in allowed.entries)
      if ((found[e.key] ?? 0) < e.value) e.key: found[e.key] ?? 0,
  };
  expect(stale, isEmpty, reason: 'fixed: lower or delete these in $allowlist');
}
