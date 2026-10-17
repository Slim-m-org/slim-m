// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [parseInline]: nesting, the leaf tokens it hands unresolved to
/// `message_text.dart`, and the false-positive cases a real message hits
/// often enough to be worth a test of their own.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_inline.dart';

void main() {
  test('plain text with no delimiters is a single text node', () {
    final nodes = parseInline('just some text');
    expect(nodes, [isA<InlineText>()]);
    expect((nodes.single as InlineText).text, 'just some text');
  });

  test('bold wraps its content', () {
    final nodes = parseInline('**bold**');
    expect(nodes, hasLength(1));
    final bold = nodes.single as InlineBold;
    expect(bold.children, [isA<InlineText>()]);
    expect((bold.children.single as InlineText).text, 'bold');
  });

  test('italic with asterisks wraps its content', () {
    final nodes = parseInline('*italic*');
    final italic = nodes.single as InlineItalic;
    expect((italic.children.single as InlineText).text, 'italic');
  });

  test('italic with underscores wraps its content', () {
    final nodes = parseInline('_italic_');
    final italic = nodes.single as InlineItalic;
    expect((italic.children.single as InlineText).text, 'italic');
  });

  test('strikethrough wraps its content', () {
    final nodes = parseInline('~~gone~~');
    final strike = nodes.single as InlineStrikethrough;
    expect((strike.children.single as InlineText).text, 'gone');
  });

  test('spoiler wraps its content', () {
    final nodes = parseInline('||secret||');
    final spoiler = nodes.single as InlineSpoiler;
    expect((spoiler.children.single as InlineText).text, 'secret');
  });

  test('bold with italic nested inside parses as one bold node containing '
      'plain text, an italic node, then more plain text', () {
    final nodes = parseInline('**bold with *italic* inside**');
    final bold = nodes.single as InlineBold;
    expect(bold.children, hasLength(3));
    expect((bold.children[0] as InlineText).text, 'bold with ');
    final italic = bold.children[1] as InlineItalic;
    expect((italic.children.single as InlineText).text, 'italic');
    expect((bold.children[2] as InlineText).text, ' inside');
  });

  test('italic with bold nested inside nests the other way round too', () {
    final nodes = parseInline('*italic with **bold** inside*');
    final italic = nodes.single as InlineItalic;
    expect(italic.children, hasLength(3));
    expect((italic.children[0] as InlineText).text, 'italic with ');
    final bold = italic.children[1] as InlineBold;
    expect((bold.children.single as InlineText).text, 'bold');
    expect((italic.children[2] as InlineText).text, ' inside');
  });

  test('an underscore inside a word never becomes italic, so '
      'snake_case_name stays one literal text node', () {
    final nodes = parseInline('snake_case_name');
    expect(nodes, [isA<InlineText>()]);
    expect((nodes.single as InlineText).text, 'snake_case_name');
  });

  test('a lone asterisk surrounded by spaces is not emphasis', () {
    final nodes = parseInline('2 * 3');
    expect(nodes, [isA<InlineText>()]);
    expect((nodes.single as InlineText).text, '2 * 3');
  });

  test(
    'an opening asterisk with no closer anywhere is left as literal text',
    () {
      final nodes = parseInline('a *b without a partner');
      expect(nodes, [isA<InlineText>()]);
      expect((nodes.single as InlineText).text, 'a *b without a partner');
    },
  );

  test('an asterisk immediately followed by whitespace never opens italics, '
      'even when a later lone asterisk could otherwise close it', () {
    final nodes = parseInline('* bold* rest');
    expect(nodes, [isA<InlineText>()]);
    expect((nodes.single as InlineText).text, '* bold* rest');
  });

  test('an opening underscore with a word before it does not open italics '
      'even when a later underscore could otherwise close it', () {
    final nodes = parseInline('file_name_here and _also_ this');
    // A closer scan must never treat an earlier word's underscore as an opener.
    expect(nodes, hasLength(3));
    expect((nodes[0] as InlineText).text, 'file_name_here and ');
    final italic = nodes[1] as InlineItalic;
    expect((italic.children.single as InlineText).text, 'also');
    expect((nodes[2] as InlineText).text, ' this');
  });

  test('content inside inline code is never parsed for markdown', () {
    final nodes = parseInline('`**not bold**`');
    expect(nodes, [isA<InlineCode>()]);
    expect((nodes.single as InlineCode).text, '**not bold**');
  });

  test('inline code takes priority over a delimiter that would otherwise '
      'close around it', () {
    final nodes = parseInline('**bold `code with **stars**` end**');
    final bold = nodes.single as InlineBold;
    expect(bold.children, hasLength(3));
    expect((bold.children[0] as InlineText).text, 'bold ');
    expect((bold.children[1] as InlineCode).text, 'code with **stars**');
    expect((bold.children[2] as InlineText).text, ' end');
  });

  test('inline code never crosses a newline', () {
    final nodes = parseInline('a `run\nmore` text');
    expect(nodes, [isA<InlineText>()]);
    expect((nodes.single as InlineText).text, 'a `run\nmore` text');
  });

  test('a mention is a leaf the caller resolves, unaffected by surrounding '
      'markdown', () {
    final nodes = parseInline('**@nick** said hi');
    expect(nodes, hasLength(2));
    final bold = nodes[0] as InlineBold;
    expect((bold.children.single as InlineMention).raw, '@nick');
    expect((nodes[1] as InlineText).text, ' said hi');
  });

  test('a mention keeps a hyphen or a dot as an interior separator', () {
    final nodes = parseInline('see @nick-c and @a.b.c');
    expect(nodes, hasLength(4));
    expect((nodes[0] as InlineText).text, 'see ');
    expect((nodes[1] as InlineMention).raw, '@nick-c');
    expect((nodes[2] as InlineText).text, ' and ');
    expect((nodes[3] as InlineMention).raw, '@a.b.c');
  });

  test('a sentence-final full stop is not part of the mentioned name', () {
    final nodes = parseInline('thanks @nick.');
    expect(nodes, hasLength(3));
    expect((nodes[0] as InlineText).text, 'thanks ');
    expect((nodes[1] as InlineMention).raw, '@nick');
    expect((nodes[2] as InlineText).text, '.');
  });

  test('a shortcode is a leaf the caller resolves', () {
    final nodes = parseInline('ship it :tada:');
    expect(nodes, hasLength(2));
    expect((nodes[0] as InlineText).text, 'ship it ');
    expect((nodes[1] as InlineEmoji).raw, ':tada:');
  });

  test('a clock time is not read as a shortcode, matching the digit-run rule '
      '`message_text.dart` always applied', () {
    final nodes = parseInline('standup at 10:30:45 today');
    expect(nodes, [isA<InlineText>()]);
    expect((nodes.single as InlineText).text, 'standup at 10:30:45 today');
  });

  group('links', () {
    String? onlyLink(String content) {
      final nodes = parseInline(content);
      final links = nodes.whereType<InlineLink>().toList();
      return links.length == 1 ? links.single.url : null;
    }

    test('a bare https URL becomes a link node', () {
      final nodes = parseInline('see https://example.com/x here');
      expect(nodes.whereType<InlineLink>().single.url, 'https://example.com/x');
      expect(nodes.first, isA<InlineText>());
      expect((nodes.first as InlineText).text, 'see ');
    });

    test('http is linked too', () {
      expect(onlyLink('http://a.test'), 'http://a.test');
    });

    test('trailing sentence punctuation stays out of the link', () {
      expect(onlyLink('go to https://example.com.'), 'https://example.com');
      expect(onlyLink('(see https://example.com)'), 'https://example.com');
      expect(onlyLink('really https://example.com?!'), 'https://example.com');
    });

    test('a balanced trailing paren is kept', () {
      expect(
        onlyLink('https://en.wikipedia.org/wiki/Dart_(language)'),
        'https://en.wikipedia.org/wiki/Dart_(language)',
      );
    });

    test('a URL inside inline code stays literal', () {
      final nodes = parseInline('`https://example.com`');
      expect(nodes.whereType<InlineLink>(), isEmpty);
      expect(nodes.single, isA<InlineCode>());
    });

    test('a URL inside bold still links', () {
      final nodes = parseInline('**https://example.com**');
      final bold = nodes.single as InlineBold;
      expect(
        bold.children.whereType<InlineLink>().single.url,
        'https://example.com',
      );
    });

    test('a word ending in h before ttp is not a link', () {
      expect(parseInline('ahttp://x').whereType<InlineLink>(), isEmpty);
    });

    test('a non-http scheme is not linked', () {
      expect(
        parseInline('file:///etc/passwd').whereType<InlineLink>(),
        isEmpty,
      );
      expect(parseInline('slimm://join?x=1').whereType<InlineLink>(), isEmpty);
    });
  });
}
