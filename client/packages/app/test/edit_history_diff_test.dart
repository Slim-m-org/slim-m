// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pure diff-engine coverage for `edit_history_diff.dart`: word tokens that
/// keep a whitespace-free run (a mention, a URL) intact instead of splitting
/// it mid-token, and block alignment that treats a fenced code block as one
/// atomic unit rather than diffing it line by line.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/edit_history_diff.dart';

List<(String, DiffKind)> _shape(List<DiffSpan> spans) => [
  for (final s in spans) (s.text, s.kind),
];

void main() {
  group('diffWords', () {
    test('marks a removed word without touching the words around it', () {
      final spans = diffWords('im very sorry lol', 'im sorry lol');
      expect(_shape(spans), [
        ('im ', DiffKind.equal),
        ('very ', DiffKind.removed),
        ('sorry lol', DiffKind.equal),
      ]);
    });

    test('marks an added word', () {
      final spans = diffWords('sorry lol', 'im sorry lol');
      expect(_shape(spans), [
        ('im ', DiffKind.added),
        ('sorry lol', DiffKind.equal),
      ]);
    });

    test('a mention changes as one token, never split mid-word', () {
      final spans = diffWords('hey @alice look', 'hey @bob look');
      expect(_shape(spans), [
        ('hey ', DiffKind.equal),
        ('@alice', DiffKind.removed),
        ('@bob', DiffKind.added),
        (' look', DiffKind.equal),
      ]);
    });

    test('a bare link changes as one token', () {
      final spans = diffWords(
        'see https://old.example/a for it',
        'see https://new.example/b for it',
      );
      expect(spans.where((s) => s.kind != DiffKind.equal).map((s) => s.text), [
        'https://old.example/a',
        'https://new.example/b',
      ]);
    });

    test('identical text is all equal', () {
      final spans = diffWords('same text', 'same text');
      expect(_shape(spans), [('same text', DiffKind.equal)]);
    });
  });

  group('diffMessage', () {
    test('an unchanged fenced code block renders as one equal block', () {
      const oldText = 'before\n```dart\nvar x = 1;\n```\nafter';
      const newText = 'before now\n```dart\nvar x = 1;\n```\nafter';
      final blocks = diffMessage(oldText, newText);
      final code = blocks.whereType<DiffCodeBlock>().single;
      expect(code.kind, DiffKind.equal);
      expect(code.code, 'var x = 1;');
    });

    test(
      'a changed fenced code block is a whole removal plus a whole addition, '
      'never a line diff',
      () {
        const oldText = '```dart\nvar x = 1;\nvar y = 2;\n```';
        const newText = '```dart\nvar x = 1;\nvar y = 3;\n```';
        final blocks = diffMessage(oldText, newText);
        final code = blocks.whereType<DiffCodeBlock>().toList();
        expect(code.map((b) => (b.code, b.kind)).toList(), [
          ('var x = 1;\nvar y = 2;', DiffKind.removed),
          ('var x = 1;\nvar y = 3;', DiffKind.added),
        ]);
      },
    );

    test('prose around an unchanged code block is still word-diffed', () {
      const oldText = 'a very long intro\n```\ncode\n```\nend';
      const newText = 'a long intro\n```\ncode\n```\nend';
      final blocks = diffMessage(oldText, newText);
      final intro = blocks.whereType<DiffTextBlock>().first;
      expect(
        intro.spans.any(
          (s) => s.kind == DiffKind.removed && s.text.contains('very'),
        ),
        isTrue,
        reason: 'the code fence must not have swallowed the surrounding diff',
      );
    });
  });

  group('plainBlocks', () {
    test('everything is equal with nothing to compare against', () {
      final blocks = plainBlocks('just some text');
      final text = blocks.whereType<DiffTextBlock>().single;
      expect(_shape(text.spans), [('just some text', DiffKind.equal)]);
    });
  });
}
