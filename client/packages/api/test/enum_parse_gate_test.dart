// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Forbids `values.byName`, and a wire-enum switch whose default arm throws,
/// anywhere under `packages/api/lib`.
///
/// `byName` throws a bare `ArgumentError` on a value it does not recognise,
/// and that is not an `ApiException`, so it escapes every `on ApiException`
/// handler in the app and surfaces as an unhandled error. That breaks this
/// repo's additive-only wire contract, which promises a client keeps working
/// against a server that has grown a value it has never heard of. Every wire
/// enum needs its own tolerant `parse` instead, in the shape of
/// `JoinPolicy.parse`: a plain function that maps an unrecognised value to a
/// deliberately chosen, documented fallback rather than throwing. A `parse`
/// whose default arm throws is the same bug by another route: the history
/// feed lost its whole page, and spun forever, on the first audit action it
/// had no case for.
///
/// A Dart test here, rather than a shell grep in `hygiene.yml`, because the
/// concern is scoped to this one package's source, the same way
/// `schema_coverage_test.dart` already reads this package's own files rather
/// than reaching for a repo-wide gate; it also runs on every local `flutter
/// test` in this package, not only in CI.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Matches `Foo.values.byName(...)`, not the unrelated `byName` identifier
/// `packages/app` uses as a `Comparator` name (no `.values.` before it).
final RegExp _byNameCall = RegExp(r'\.values\.byName\(');

/// Matches a switch default that throws, in either the arm (`_ => throw`) or
/// the statement (`default: throw`) form, across line breaks.
final RegExp _throwingDefault = RegExp(r'(?:\b_\s*=>|\bdefault\s*:)\s*throw\b');

void main() {
  final repoRoot = _findRepoRoot(Directory.current);
  final libDir = Directory('${repoRoot.path}/client/packages/api/lib');

  test('no source under packages/api/lib parses an enum with values.byName',
      () {
    final hits = _scan(libDir);
    expect(
      hits,
      isEmpty,
      reason: '\nvalues.byName throws ArgumentError on an unrecognised wire '
          'value, which escapes every `on ApiException` handler in the app. '
          'Give the enum a tolerant `parse` instead (see JoinPolicy.parse):'
          '\n\n${hits.join('\n')}\n',
    );
  });

  test('no wire enum under packages/api/lib throws from its default arm', () {
    final hits = _scanThrowingDefault(libDir);
    expect(
      hits,
      isEmpty,
      reason: '\na switch default that throws turns a value the server grew '
          'into an unhandled error. Map it to a documented fallback value '
          'instead (see JoinPolicy.parse):\n\n${hits.join('\n')}\n',
    );
  });

  test('the throwing-default scanner catches both forms and ignores comments',
      () {
    final tmp = Directory.systemTemp.createTempSync('throw_gate_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/arm.dart').writeAsStringSync(
      "final a = switch (w) {\n  'x' => 1,\n  _ =>\n      throw FormatException('no'),\n};\n",
    );
    File('${tmp.path}/stmt.dart').writeAsStringSync(
      "int f(String w) {\n  switch (w) {\n    default:\n      throw StateError('no');\n  }\n}\n",
    );
    File('${tmp.path}/fine.dart').writeAsStringSync(
      "// _ => throw FormatException('in a comment')\nfinal b = switch (w) { _ => 0 };\n",
    );

    expect(_scanThrowingDefault(tmp), hasLength(2));
  });

  // Proves the gate above can actually say no, not pass vacuously.
  test('the scanner catches values.byName when it is actually present', () {
    final tmp = Directory.systemTemp.createTempSync('byname_gate_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/offender.dart').writeAsStringSync(
      "final x = SomeEnum.values.byName(json['field'] as String);\n",
    );

    expect(_scan(tmp), isNotEmpty);
  });

  test('the scanner does not flag the unrelated byName identifier', () {
    final tmp = Directory.systemTemp.createTempSync('byname_gate_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/comparator.dart').writeAsStringSync(
      'int byName(Profile a, Profile b) => a.name.compareTo(b.name);\n',
    );

    expect(_scan(tmp), isEmpty);
  });
}

/// Walks upward from [start] looking for schema/openapi.yaml, the same
/// repo-root anchor `schema_coverage_test.dart` uses, so this test does not
/// depend on which directory `dart test` or `flutter test` was invoked from.
Directory _findRepoRoot(Directory start) {
  var dir = start.absolute;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/schema/openapi.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    'could not find schema/openapi.yaml walking up from ${start.path}; is '
    'this test running from somewhere inside the slim-m repo?',
  );
}

/// Returns one `path:line: content` string per `values.byName` call found
/// under [dir], recursively, in any `.dart` file.
List<String> _scan(Directory dir) {
  final hits = <String>[];
  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));

  for (final file in files) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (_byNameCall.hasMatch(lines[i])) {
        hits.add('${file.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
  }
  return hits;
}

/// Returns one `path:line` string per switch default that throws under
/// [dir], with `//` comments blanked first so prose cannot trip the match.
List<String> _scanThrowingDefault(Directory dir) {
  final hits = <String>[];
  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));

  for (final file in files) {
    final code = file
        .readAsStringSync()
        .replaceAllMapped(RegExp(r'//[^\n]*'), (m) => ' ' * m[0]!.length);
    for (final match in _throwingDefault.allMatches(code)) {
      final line = '\n'.allMatches(code.substring(0, match.start)).length + 1;
      hits.add('${file.path}:$line');
    }
  }
  return hits;
}
