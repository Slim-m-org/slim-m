// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/composer_code_fence.dart';
import 'package:slimm_app/src/widgets/composer_code_guess.dart';

TextEditingValue _at(String text, [int? caret]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: caret ?? text.length),
);

TextEditingValue _selecting(String text, int start, int end) =>
    TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end),
    );

void main() {
  group('caretInOpenFence', () {
    test('after an opening fence, and on its own line', () {
      expect(caretInOpenFence(_at('```py')), isTrue);
      expect(caretInOpenFence(_at('```py\nprint(1)')), isTrue);
      expect(caretInOpenFence(_at('text\n  ```\nx')), isTrue);
    });

    test('not before a fence, after a closed one, or for a one-line block', () {
      expect(caretInOpenFence(_at('hello')), isFalse);
      expect(caretInOpenFence(_at('```\nx\n```')), isFalse);
      expect(caretInOpenFence(_at('```x```\nmore')), isFalse);
      expect(caretInOpenFence(_at('see ```this``` here')), isFalse);
      expect(caretInOpenFence(_at('```\nx\n```', 0)), isFalse);
    });

    test('an invalid selection is never inside', () {
      expect(
        caretInOpenFence(
          const TextEditingValue(
            text: '```',
            selection: TextSelection.collapsed(offset: -1),
          ),
        ),
        isFalse,
      );
    });
  });

  group('insertCodeFence', () {
    test('an empty field gets a block with the caret on its middle line', () {
      final out = insertCodeFence(_at(''), language: 'python');
      expect(out.text, '```python\n\n```');
      expect(out.selection.baseOffset, '```python\n'.length);
    });

    test('mid-line, the fences still sit on lines of their own', () {
      final out = insertCodeFence(_at('before after', 6), language: 'go');
      expect(out.text, 'before\n```go\n\n```\n after');
      expect(
        out.text.substring(0, out.selection.baseOffset),
        'before\n```go\n',
      );
    });

    test('a selection becomes the body and the caret lands after it', () {
      final out = insertCodeFence(_selecting('x = 1\ny = 2', 0, 11));
      expect(out.text, '```\nx = 1\ny = 2\n```');
      expect(out.selection.baseOffset, out.text.length);
    });

    test('a selection already ending in a newline gains no blank line', () {
      final out = insertCodeFence(_selecting('a\nb\n', 0, 4), language: 'c');
      expect(out.text, '```c\na\nb\n```');
    });
  });

  test('newlineInFence keeps the current line indent', () {
    final out = newlineInFence(_at('```\n  if (x) {'));
    expect(out.text, '```\n  if (x) {\n  ');
    expect(out.selection.baseOffset, out.text.length);
  });

  group('guessPastedCode', () {
    const code = <String, String>{
      'fn main() {\n    let mut x = 1;\n    x += 1;\n}': 'rust',
      'package main\n\nfunc main() {\n\tfmt.Println("hi")\n}': 'go',
      'def add(a, b):\n    return a + b\n\nprint(add(1, 2))': 'python',
      '#include <stdio.h>\nint main() {\n  return 0;\n}': 'c',
      '#include <vector>\nstd::vector<int> v;\nv.push_back(1);': 'cpp',
      'const x = 1;\nconsole.log(x);\n': 'javascript',
      'interface User {\n  name: string;\n}\n': 'typescript',
      '#!/bin/bash\necho hi\nls -la': 'bash',
      '{\n  "a": 1,\n  "b": [true, null]\n}': 'json',
      'SELECT id, name\nFROM users\nWHERE id = 1;': 'sql',
      'void main() {\n  runApp(const App());\n}': 'dart',
      'foo {\n  bar;\n  baz;\n}': '',
    };
    for (final MapEntry(key: text, value: language) in code.entries) {
      test('reads as ${language.isEmpty ? 'unknown code' : language}', () {
        expect(guessPastedCode(text), language);
      });
    }

    const prose = <String>[
      'one line of code();',
      'Hello there.\nHow are you today?\nSee you soon!',
      '- milk\n- eggs\n  - free range\n- bread',
      'Steps:\n1. open it\n2. close it',
      'already fenced\n```\nx;\n```',
      'Dear team,\nThe meeting moved (again).\nThanks, Sam',
    ];
    for (final text in prose) {
      test('prose stays prose: ${text.split('\n').first}', () {
        expect(guessPastedCode(text), isNull);
      });
    }
  });
}
