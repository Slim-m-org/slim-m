// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A settings row is a few words, and its description is one short sentence.
///
/// The rule lives in `docs/design/wording.md`. This reads `lib/` through
/// `support/code_only.dart`, so a comment or a string that merely contains
/// `description:` never counts, and fails on any description literal or
/// toggle/select row label over the limits. Exceptions go in
/// `settings_copy_allow.txt`, one `path|start of the text` per line.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/code_only.dart';

const maxLabelWords = 5;
const maxDescriptionWords = 12;

final _literal = RegExp(r'''(?:'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*")''');
final _literalRun = RegExp('(?:${_literal.pattern}\\s*)+');
final _interpolation = RegExp(r'\$\{[^}]*\}|\$\w+');
final _sentenceEnd = RegExp(r'[.!?](?=\s|$)');

final _descriptionKey = RegExp(r'\bdescription\s*:');
final _descriptionDecl = RegExp(
  r'\b(?:const|final|String)\s+(?:get\s+)?_?\w*[dD]escription\w*\b[^=;{]*?(=>|=|\{)',
);
final _rowCall = RegExp(r'\bSettings(?:Toggle|Select)Row\s*(?:<[^>(]*>)?\s*\(');

class _Copy {
  const _Copy(this.kind, this.text);
  final String kind;
  final String text;

  int get words => text
      .replaceAll(_interpolation, 'x')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .length;

  int get sentences => _sentenceEnd.allMatches(text).length;

  String? get violation {
    final limit = kind == 'label' ? maxLabelWords : maxDescriptionWords;
    if (words > limit) return '$kind has $words words (max $limit)';
    if (kind != 'label' && sentences > 1) return '$kind is not one sentence';
    return null;
  }
}

int _closeOf(String code, int open) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    final c = code[i];
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c) && --depth == 0) return i;
  }
  return code.length;
}

/// End of the expression starting at [from]: the first `,` or closer at depth
/// zero, or `;` when [untilSemicolon].
int _expressionEnd(String code, int from, {required bool untilSemicolon}) {
  var depth = 0;
  for (var i = from; i < code.length; i++) {
    final c = code[i];
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) {
      if (depth == 0) return i;
      depth--;
    }
    if (depth == 0 && (untilSemicolon ? c == ';' : c == ',')) return i;
  }
  return code.length;
}

Iterable<String> _texts(String source, int from, int to) => _literalRun
    .allMatches(source.substring(from, to))
    .map(
      (run) => _literal
          .allMatches(run.group(0)!)
          .map((l) => l.group(0)!.substring(1, l.group(0)!.length - 1))
          .join(),
    );

List<_Copy> _copies(String source) {
  final code = codeOnly(source);
  final copies = <_Copy>[];
  for (final m in _descriptionKey.allMatches(code)) {
    final end = _expressionEnd(code, m.end, untilSemicolon: false);
    for (final t in _texts(source, m.end, end)) {
      copies.add(_Copy('description', t));
    }
  }
  for (final m in _descriptionDecl.allMatches(code)) {
    final end = m.group(1) == '{'
        ? _closeOf(code, m.end - 1)
        : _expressionEnd(code, m.end, untilSemicolon: true);
    for (final t in _texts(source, m.end, end)) {
      copies.add(_Copy('description', t));
    }
  }
  for (final m in _rowCall.allMatches(code)) {
    final open = m.end - 1;
    final close = _closeOf(code, open);
    final label = RegExp(
      r'\blabel\s*:',
    ).allMatches(code.substring(open, close));
    for (final l in label) {
      final from = open + l.end;
      if (_depthAt(code, open, from) != 1) continue;
      final end = _expressionEnd(code, from, untilSemicolon: false);
      for (final t in _texts(source, from, end)) {
        copies.add(_Copy('label', t));
      }
    }
  }
  return copies;
}

int _depthAt(String code, int open, int at) {
  var depth = 0;
  for (var i = open; i < at; i++) {
    if ('([{'.contains(code[i])) depth++;
    if (')]}'.contains(code[i])) depth--;
  }
  return depth;
}

List<String> violationsIn(String path, String source) => [
  for (final copy in _copies(source))
    if (copy.violation case final why?)
      '$path|${copy.text.split('\n').first}: $why',
];

Set<String> _allowed() => File('test/settings_copy_allow.txt')
    .readAsLinesSync()
    .where((l) => l.trim().isNotEmpty && !l.startsWith('#'))
    .toSet();

void main() {
  test('every settings description and row label is within the limits', () {
    final allowed = _allowed();
    final used = <String>{};
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      for (final hit in violationsIn(file.path, file.readAsStringSync())) {
        final key = hit.substring(0, hit.indexOf(': '));
        final entry = allowed.firstWhere(
          (a) => key.startsWith(a),
          orElse: () => '',
        );
        if (entry.isEmpty) {
          offenders.add(hit);
        } else {
          used.add(entry);
        }
      }
    }
    expect(offenders, isEmpty);
    expect(allowed.difference(used), isEmpty, reason: 'stale allowlist entry');
  });

  group('the scan itself', () {
    const wordy =
        'one two three four five six seven eight nine ten eleven '
        'twelve thirteen';

    test('catches a long description, a long label and a second sentence', () {
      expect(
        violationsIn('a.dart', "const X(description: '$wordy',);"),
        hasLength(1),
      );
      expect(
        violationsIn('a.dart', "SettingsToggleRow(label: '$wordy', value: 1);"),
        hasLength(1),
      );
      expect(
        violationsIn('a.dart', "const X(description: 'One. Two.',);"),
        hasLength(1),
      );
    });

    test('reads adjacent literals, ternary branches and named constants', () {
      expect(
        violationsIn(
          'a.dart',
          "const X(description: 'one two three four five six '\n"
              "    'seven eight nine ten eleven twelve thirteen',);",
        ),
        hasLength(1),
      );
      expect(
        violationsIn('a.dart', "X(description: a ? 'short' : '$wordy',);"),
        hasLength(1),
      );
      expect(
        violationsIn('a.dart', "const _fooDescription =\n    '$wordy';"),
        hasLength(1),
      );
    });

    test('ignores a comment, a string holding the key and a short row', () {
      expect(violationsIn('a.dart', "// description: '$wordy'"), isEmpty);
      expect(
        violationsIn('a.dart', "final s = \"description: $wordy\";"),
        isEmpty,
      );
      expect(
        violationsIn(
          'a.dart',
          "SettingsToggleRow(label: 'Short label', description: 'Short.');",
        ),
        isEmpty,
      );
    });

    test('a nested widget label is not a row label', () {
      expect(
        violationsIn(
          'a.dart',
          "SettingsSelectRow<int>(label: 'Fine', choices: [C(label: '$wordy')]);",
        ),
        isEmpty,
      );
    });
  });

  test('the wording table states the limits the gate enforces', () {
    final table = File('../../../docs/design/wording.md').readAsStringSync();
    expect(table, contains('at most $maxLabelWords words'));
    expect(table, contains('at most $maxDescriptionWords words'));
  });
}
