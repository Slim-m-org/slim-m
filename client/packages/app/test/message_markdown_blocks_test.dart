// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [splitMarkdownBlocks]: headings, quotes and lists are line-level
/// structure, and every one of them must stay inert unless it starts a line.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_markdown_blocks.dart';

void main() {
  test('plain text with no markers is a single paragraph, unchanged', () {
    final blocks = splitMarkdownBlocks('hello there\nsecond line');
    expect(blocks, [isA<ParagraphBlock>()]);
    expect((blocks.single as ParagraphBlock).text, 'hello there\nsecond line');
  });

  test(
    'a blank line inside otherwise-plain text stays inside one paragraph',
    () {
      final blocks = splitMarkdownBlocks('one\n\ntwo');
      expect(blocks, [isA<ParagraphBlock>()]);
      expect((blocks.single as ParagraphBlock).text, 'one\n\ntwo');
    },
  );

  test('#, ## and ### each become a heading at the matching level', () {
    final blocks = splitMarkdownBlocks('# One\n## Two\n### Three');
    expect(blocks, hasLength(3));
    expect((blocks[0] as HeadingBlock).level, 1);
    expect((blocks[0] as HeadingBlock).text, 'One');
    expect((blocks[1] as HeadingBlock).level, 2);
    expect((blocks[2] as HeadingBlock).level, 3);
  });

  test('a hash with no following space is not a heading', () {
    final blocks = splitMarkdownBlocks('#nope');
    expect(blocks, [isA<ParagraphBlock>()]);
    expect((blocks.single as ParagraphBlock).text, '#nope');
  });

  test('consecutive quote lines merge into one quote block', () {
    final blocks = splitMarkdownBlocks('> line one\n> line two');
    expect(blocks, [isA<QuoteBlock>()]);
    expect((blocks.single as QuoteBlock).text, 'line one\nline two');
  });

  test('a doubly-quoted line (a forward of a forward) strips every leading '
      '>, not just the outermost', () {
    final blocks = splitMarkdownBlocks('> > hello there');
    expect(blocks, [isA<QuoteBlock>()]);
    expect((blocks.single as QuoteBlock).text, 'hello there');
  });

  test('a > that is not at the start of a line is not a quote', () {
    final blocks = splitMarkdownBlocks('see the diagram: a -> b');
    expect(blocks, [isA<ParagraphBlock>()]);
    expect((blocks.single as ParagraphBlock).text, 'see the diagram: a -> b');
  });

  test(
    'a paragraph before and after a quote stays split into three blocks',
    () {
      final blocks = splitMarkdownBlocks('before\n> quoted\nafter');
      expect(blocks, hasLength(3));
      expect(blocks[0], isA<ParagraphBlock>());
      expect(blocks[1], isA<QuoteBlock>());
      expect(blocks[2], isA<ParagraphBlock>());
    },
  );

  test('dash and star bullets both produce an unordered list', () {
    final blocks = splitMarkdownBlocks('- one\n* two');
    final list = blocks.single as ListBlock;
    expect(list.ordered, isFalse);
    expect(list.items.map((i) => i.text), ['one', 'two']);
  });

  test('a numbered list is ordered, regardless of the digits typed', () {
    final blocks = splitMarkdownBlocks('1. first\n5. second');
    final list = blocks.single as ListBlock;
    expect(list.ordered, isTrue);
    expect(list.items.map((i) => i.text), ['first', 'second']);
  });

  test('a two-space indent nests one level per step, to three levels', () {
    final blocks = splitMarkdownBlocks(
      '- top\n  - nested\n    - deeper\n- top again',
    );
    final list = blocks.single as ListBlock;
    expect(list.items.map((i) => i.depth), [0, 1, 2, 0]);
  });

  test('indent beyond the third level stays at the third', () {
    final list = splitMarkdownBlocks('- a\n     - far').single as ListBlock;
    expect(list.items.map((i) => i.depth), [0, 2]);
  });

  test('a bullet nested under a number stays in the same list', () {
    final blocks = splitMarkdownBlocks('1. a\n  - b\n2. c');
    final list = blocks.single as ListBlock;
    expect(list.items.map((i) => i.ordered), [true, false, true]);
  });

  test('switching from bullets to numbers starts a new list block', () {
    final blocks = splitMarkdownBlocks('- one\n1. two');
    expect(blocks, hasLength(2));
    expect((blocks[0] as ListBlock).ordered, isFalse);
    expect((blocks[1] as ListBlock).ordered, isTrue);
  });

  test('a paragraph, a list and a heading in one message split into three '
      'blocks in order', () {
    final blocks = splitMarkdownBlocks('intro text\n- one\n- two\n# done');
    expect(blocks, hasLength(3));
    expect(blocks[0], isA<ParagraphBlock>());
    expect(blocks[1], isA<ListBlock>());
    expect(blocks[2], isA<HeadingBlock>());
  });

  test('a blank line between a quote and a list carries no phantom empty '
      'paragraph block', () {
    final blocks = splitMarkdownBlocks('> quoted\n\n- one\n- two');
    expect(blocks, [isA<QuoteBlock>(), isA<ListBlock>()]);
  });

  test('a blank line between a list and a heading carries no phantom empty '
      'paragraph block', () {
    final blocks = splitMarkdownBlocks('- one\n- two\n\n# done');
    expect(blocks, [isA<ListBlock>(), isA<HeadingBlock>()]);
  });

  test('a blank line between two headings carries no phantom empty paragraph '
      'block', () {
    final blocks = splitMarkdownBlocks('# one\n\n# two');
    expect(blocks, [isA<HeadingBlock>(), isA<HeadingBlock>()]);
  });
}
