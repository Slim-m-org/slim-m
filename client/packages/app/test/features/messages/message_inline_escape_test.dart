// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Backslash escapes in [parseInline]: `\*` is a literal asterisk, never a
/// delimiter, the same rule the server's mention scanner follows for `\@`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_inline.dart';

String _text(List<InlineNode> nodes) => nodes
    .map(
      (n) => switch (n) {
        InlineText(:final text) => text,
        _ => '<${n.runtimeType}>',
      },
    )
    .join();

void main() {
  test('escaped asterisks are literal text, not italic', () {
    final nodes = parseInline(r'\*escaped\*');
    expect(nodes, [isA<InlineText>()]);
    expect(_text(nodes), '*escaped*');
  });

  test('every delimiter the grammar owns can be escaped', () {
    expect(_text(parseInline(r'\**x\**')), '**x**');
    expect(_text(parseInline(r'\_x\_')), '_x_');
    expect(_text(parseInline(r'\~~x\~~')), '~~x~~');
    expect(_text(parseInline(r'\||x\||')), '||x||');
    expect(_text(parseInline(r'\`x\`')), '`x`');
    expect(_text(parseInline(r'\:smile:')), ':smile:');
  });

  test('an escaped @ is not a mention', () {
    final nodes = parseInline(r'hi \@bob and \@[Core Team]');
    expect(nodes.whereType<InlineMention>(), isEmpty);
    expect(nodes.whereType<InlineRoleMention>(), isEmpty);
    expect(_text(nodes), 'hi @bob and @[Core Team]');
  });

  test('an escaped closer does not close a run', () {
    final nodes = parseInline(r'*a\*b*');
    final italic = nodes.single as InlineItalic;
    expect(_text(italic.children), 'a*b');
  });

  test('a doubled backslash is one literal backslash', () {
    expect(_text(parseInline(r'a\\b')), r'a\b');
    final nodes = parseInline(r'\\*x*');
    expect(nodes.whereType<InlineItalic>(), hasLength(1));
  });

  test('a backslash before an ordinary character stays', () {
    expect(_text(parseInline(r'C:\Users\me')), r'C:\Users\me');
    expect(_text(parseInline(r'trailing\')), r'trailing\');
  });

  test('a backslash inside a url stays part of it', () {
    final nodes = parseInline(r'see https://x.test/a\_b ok');
    expect(nodes.whereType<InlineLink>().single.url, r'https://x.test/a\_b');
  });
}
