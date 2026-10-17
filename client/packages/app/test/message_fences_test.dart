// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [splitMessageBlocks]: fenced code must be recognised only when
/// its markers occupy a whole line, and every edge case a real message can
/// hand it (unterminated, empty, unlabelled, inline) must degrade sanely
/// rather than crash or swallow the rest of the message.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_fences.dart';

void main() {
  test('a message with no fence is a single text block', () {
    final blocks = splitMessageBlocks('just some text');
    expect(blocks, hasLength(1));
    expect(blocks.single, isA<TextBlock>());
    expect((blocks.single as TextBlock).text, 'just some text');
  });

  test('text, a labelled fence, and more text split into three blocks', () {
    final blocks = splitMessageBlocks(
      'before\n```dart\nfinal x = 1;\n```\nafter',
    );
    expect(blocks, hasLength(3));
    expect((blocks[0] as TextBlock).text, 'before');
    final code = blocks[1] as CodeBlock;
    expect(code.language, 'dart');
    expect(code.code, 'final x = 1;');
    expect((blocks[2] as TextBlock).text, 'after');
  });

  test('a fence with no language yields a null language', () {
    final blocks = splitMessageBlocks('```\necho hi\n```');
    final code = blocks.single as CodeBlock;
    expect(code.language, isNull);
    expect(code.code, 'echo hi');
  });

  test('an empty fence yields empty code rather than throwing', () {
    final blocks = splitMessageBlocks('```\n```');
    final code = blocks.single as CodeBlock;
    expect(code.language, isNull);
    expect(code.code, '');
  });

  test('a multi-line fenced body is preserved with its internal newlines', () {
    final blocks = splitMessageBlocks('```\nline one\nline two\n```');
    final code = blocks.single as CodeBlock;
    expect(code.code, 'line one\nline two');
  });

  test('an unterminated fence has nowhere to end, so it renders as plain text '
      'instead of swallowing the rest of the message', () {
    final blocks = splitMessageBlocks('hi\n```js\nconsole.log(1)');
    expect(blocks, hasLength(1));
    final text = blocks.single as TextBlock;
    expect(text.text, 'hi\n```js\nconsole.log(1)');
  });

  test('a fence marker embedded in a line of prose (as inline code might '
      'contain) does not start a fence, since it does not occupy its own '
      'line', () {
    final blocks = splitMessageBlocks('before `a ```b` after');
    expect(blocks, hasLength(1));
    expect(blocks.single, isA<TextBlock>());
    expect((blocks.single as TextBlock).text, 'before `a ```b` after');
  });

  test('a language token may contain digits and punctuation', () {
    final blocks = splitMessageBlocks('```c++\nint x;\n```');
    final code = blocks.single as CodeBlock;
    expect(code.language, 'c++');
  });

  test('trailing whitespace after the fence markers is tolerated', () {
    final blocks = splitMessageBlocks('```dart  \nx\n```  ');
    final code = blocks.single as CodeBlock;
    expect(code.language, 'dart');
  });
}
