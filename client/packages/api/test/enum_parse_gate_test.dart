// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Forbids every throwing enum lookup (`values.byName`, `values[i]`,
/// `values.firstWhere` with no `orElse`, `values.singleWhere`) and a wire-enum
/// switch whose default arm throws, anywhere under `packages/api/lib`.
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

import 'package:slimm_test_support/source_gates.dart';
import 'package:test/test.dart';

final _lookups = <String, RegExp>{
  'values.byName': RegExp(r'\.values\s*\.\s*byName\s*\('),
  'values[index]': RegExp(r'\.values\s*\['),
  'values.singleWhere': RegExp(r'\.values\s*\.\s*singleWhere\s*\('),
};

/// Matches a `firstWhere(` call on `.values`; its own arguments are checked for `orElse`.
final _firstWhere = RegExp(r'\.values\s*\.\s*firstWhere\s*\(');

/// Matches a switch default that throws, in the arm (`_ => throw`), statement
/// (`default: throw`) or wildcard-case (`case _: throw`) form, across lines.
final _throwingDefault = RegExp(
  r'(?:\b_\s*=>|\bdefault\s*:|\bcase\s+_\s*:)\s*throw\b',
);

void main() {
  final repoRoot = findRepoRoot();
  final libDir = Directory('${repoRoot.path}/client/packages/api/lib');

  test('no source under packages/api/lib does a throwing enum lookup', () {
    final hits = _scan(libDir);
    expect(
      hits,
      isEmpty,
      reason: '\nvalues.byName, values[i], values.singleWhere and values.'
          'firstWhere without orElse throw on an unrecognised wire value, '
          'which escapes every `on ApiException` handler in the app. '
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

  test('the throwing-default scanner catches every form and ignores comments',
      () {
    final tmp = Directory.systemTemp.createTempSync('throw_gate_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/arm.dart').writeAsStringSync(
      "final a = switch (w) {\n  'x' => 1,\n  _ =>\n      throw FormatException('no'),\n};\n",
    );
    File('${tmp.path}/stmt.dart').writeAsStringSync(
      "int f(String w) {\n  switch (w) {\n    default:\n      throw StateError('no');\n  }\n}\n",
    );
    File('${tmp.path}/case.dart').writeAsStringSync(
      "int f(String w) {\n  switch (w) {\n    case _:\n      throw StateError('no');\n  }\n}\n",
    );
    File('${tmp.path}/after_url.dart').writeAsStringSync(
      "final a = switch (w) { 'https://x' => 1, _ => throw StateError('no') };\n",
    );
    File('${tmp.path}/fine.dart').writeAsStringSync(
      "// _ => throw FormatException('in a comment')\nfinal b = switch (w) { _ => 0 };\n",
    );

    expect(_scanThrowingDefault(tmp), hasLength(4));
  });

  // Proves the gate above can actually say no, not pass vacuously.
  test('the scanner catches each throwing lookup when it is present', () {
    final tmp = Directory.systemTemp.createTempSync('byname_gate_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final offenders = {
      'by_name': "final x = SomeEnum.values.byName(json['field'] as String);\n",
      'split': 'final x = SomeEnum.values\n    .byName(raw);\n',
      'index': "final x = SomeEnum.values[json['x'] as int];\n",
      'first': 'final x = SomeEnum.values.firstWhere((e) => e.name == raw);\n',
      'single':
          'final x = SomeEnum.values.singleWhere((e) => e.name == raw);\n',
    };
    offenders.forEach(
      (name, text) => File('${tmp.path}/$name.dart').writeAsStringSync(text),
    );

    expect(_scan(tmp), hasLength(offenders.length));
  });

  test('the scanner ignores comments, strings, orElse and the byName name', () {
    final tmp = Directory.systemTemp.createTempSync('byname_gate_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/fine.dart').writeAsStringSync(
      '// SomeEnum.values.byName(raw) and SomeEnum.values[0] in a comment\n'
      "final s = 'SomeEnum.values.singleWhere(x)';\n"
      'final ok = SomeEnum.values.firstWhere(\n'
      '  (e) => e.name == raw,\n'
      '  orElse: () => SomeEnum.other,\n'
      ');\n'
      'int byName(Profile a, Profile b) => a.name.compareTo(b.name);\n',
    );

    expect(_scan(tmp), isEmpty);
  });
}

Iterable<File> _dartFiles(Directory dir) => dir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

int _lineOf(String code, int offset) =>
    '\n'.allMatches(code.substring(0, offset)).length + 1;

/// Returns one `path:line: label` string per throwing enum lookup found under
/// [dir], read through the shared comment and string scrubber.
List<String> _scan(Directory dir) {
  final hits = <String>[];
  for (final file in _dartFiles(dir)) {
    final code = codeOnly(file.readAsStringSync());
    for (final MapEntry(:key, :value) in _lookups.entries) {
      for (final match in value.allMatches(code)) {
        hits.add('${file.path}:${_lineOf(code, match.start)}: $key');
      }
    }
    for (final match in _firstWhere.allMatches(code)) {
      final args = callArguments(code, match.end - 1);
      if (args == null || !args.contains('orElse')) {
        hits.add(
          '${file.path}:${_lineOf(code, match.start)}: values.firstWhere '
          'without orElse',
        );
      }
    }
  }
  return hits;
}

/// Returns one `path:line` string per switch default that throws under [dir].
List<String> _scanThrowingDefault(Directory dir) {
  final hits = <String>[];
  for (final file in _dartFiles(dir)) {
    final code = codeOnly(file.readAsStringSync());
    for (final match in _throwingDefault.allMatches(code)) {
      hits.add('${file.path}:${_lineOf(code, match.start)}');
    }
  }
  return hits;
}
