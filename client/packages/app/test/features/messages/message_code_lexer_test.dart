// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [lexCodeBlock]: each [AppCodeRole] must trace back to the
/// right substring for a recognised language, and an unrecognised one must
/// render unhighlighted rather than guessing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_code_lexer.dart';
import 'package:slimm_design_system/design_system.dart';

/// The (text, role) pairs of one lexed line, in order, for asserting on
/// without depending on [AppCodeSpan] having value equality.
List<(String, AppCodeRole)> _spansOf(AppCodeLine line) => [
  for (final span in line.spans) (span.text, span.role),
];

void main() {
  test('an unrecognised language renders every line unhighlighted', () {
    final lines = lexCodeBlock('let x = 1; // not really rust', 'not-a-lang');
    expect(lines, hasLength(1));
    expect(_spansOf(lines.single), [
      ('let x = 1; // not really rust', AppCodeRole.plain),
    ]);
  });

  test('no language at all renders unhighlighted too', () {
    final lines = lexCodeBlock('anything', null);
    expect(_spansOf(lines.single), [('anything', AppCodeRole.plain)]);
  });

  test('a keyword, a number, an operator, and a line comment each get their '
      'own role', () {
    final lines = lexCodeBlock('let x = 1; // hi', 'rust');
    expect(_spansOf(lines.single), [
      ('let', AppCodeRole.keyword),
      (' x ', AppCodeRole.plain),
      ('=', AppCodeRole.punctuation),
      (' ', AppCodeRole.plain),
      ('1', AppCodeRole.number),
      (';', AppCodeRole.punctuation),
      (' ', AppCodeRole.plain),
      ('// hi', AppCodeRole.comment),
    ]);
  });

  test('a double-quoted string is one span, escaped quote included', () {
    final lines = lexCodeBlock(r'x = "a\"b"', 'rust');
    final spans = _spansOf(lines.single);
    expect(spans, contains((r'"a\"b"', AppCodeRole.string)));
  });

  test('a single-line block comment is one span', () {
    final lines = lexCodeBlock('/* hi */ x', 'c');
    expect(_spansOf(lines.single), [
      ('/* hi */', AppCodeRole.comment),
      (' x', AppCodeRole.plain),
    ]);
  });

  test('an unclosed block comment runs to the end of its line', () {
    final lines = lexCodeBlock('/* never closed', 'c');
    expect(_spansOf(lines.single), [('/* never closed', AppCodeRole.comment)]);
  });

  test('python uses a hash comment, not a slash one', () {
    final lines = lexCodeBlock('x = 1  # note', 'python');
    final spans = _spansOf(lines.single);
    expect(spans.last, ('# note', AppCodeRole.comment));
  });

  test('sql keywords match case-insensitively', () {
    final lines = lexCodeBlock('select * from t', 'sql');
    final spans = _spansOf(lines.single);
    expect(spans.first, ('select', AppCodeRole.keyword));
    expect(spans.any((s) => s == ('from', AppCodeRole.keyword)), isTrue);
  });

  test('a language alias resolves to the same table as its canonical name', () {
    final viaAlias = _spansOf(lexCodeBlock('const x = 1;', 'js').single);
    final viaName = _spansOf(lexCodeBlock('const x = 1;', 'javascript').single);
    expect(viaAlias, viaName);
  });

  test('language matching ignores case', () {
    final lines = lexCodeBlock('const x = 1;', 'JS');
    expect(_spansOf(lines.single).first, ('const', AppCodeRole.keyword));
  });

  test('multiple lines lex independently, one AppCodeLine per source line', () {
    final lines = lexCodeBlock('let a = 1;\nlet b = 2;', 'rust');
    expect(lines, hasLength(2));
    expect(_spansOf(lines[0]).first, ('let', AppCodeRole.keyword));
    expect(_spansOf(lines[1]).first, ('let', AppCodeRole.keyword));
  });
}
