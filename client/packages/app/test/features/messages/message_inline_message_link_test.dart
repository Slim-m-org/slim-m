// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message link inside a message body: what the inline parser makes of one,
/// and what it deliberately does not.
///
/// The security-relevant half is what is *not* matched. `message_text.dart`
/// hands an [InlineLink] to `launchUrl` and re-checks the scheme first, precisely
/// so nothing can smuggle an app scheme past the opener. A message link takes a
/// separate route through the renderer and is navigated in-app, so the cases
/// below pin that the narrow pattern stays narrow: another `slimm://` host, an
/// invite, and a bare scheme are all left as plain text.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/message_link.dart';
import 'package:slimm_app/src/features/messages/widgets/message_inline.dart';

String _link({String server = 'https://slim.example.top'}) => buildMessageLink(
  server: Uri.parse(server),
  channelId: 'c1',
  messageId: 'm1',
);

List<InlineNode> _parse(String text) => parseInline(text);

void main() {
  test('a message link on its own becomes one node', () {
    final nodes = _parse(_link());

    expect(nodes, hasLength(1));
    expect(nodes.single, isA<InlineMessageLink>());
    expect((nodes.single as InlineMessageLink).raw, _link());
  });

  test('it is recognised in the middle of a sentence', () {
    final nodes = _parse('look at ${_link()} please');

    expect(nodes.whereType<InlineMessageLink>(), hasLength(1));
    expect(nodes.first, isA<InlineText>());
    expect(nodes.last, isA<InlineText>());
  });

  test('trailing sentence punctuation is not part of the link', () {
    final nodes = _parse('${_link()}.');

    final link = nodes.whereType<InlineMessageLink>().single;
    expect(link.raw, isNot(endsWith('.')));
    expect(parseMessageLink(link.raw), isNotNull, reason: 'still parses');
  });

  test('an http link beside one still becomes an ordinary link', () {
    final nodes = _parse('${_link()} and https://example.top/page');

    expect(nodes.whereType<InlineMessageLink>(), hasLength(1));
    expect(nodes.whereType<InlineLink>(), hasLength(1));
  });

  group('what is deliberately not matched', () {
    test('an invite link stays plain text', () {
      final nodes = _parse('slimm://join?server=https%3A%2F%2Fa.top&code=abc');

      expect(
        nodes.whereType<InlineMessageLink>(),
        isEmpty,
        reason: 'a pasted invite must still go through the join flow checks',
      );
    });

    test('another slimm host stays plain text', () {
      for (final raw in [
        'slimm://settings?x=1',
        'slimm://open?url=file:///etc/passwd',
        'slimm://messages?channel=c1&id=m1',
      ]) {
        expect(
          _parse(raw).whereType<InlineMessageLink>(),
          isEmpty,
          reason: '$raw is not a message link and must not be tappable',
        );
      }
    });

    test('a bare scheme with no query stays plain text', () {
      expect(_parse('slimm://message').whereType<InlineMessageLink>(), isEmpty);
    });

    test('a word ending in s before the scheme is not swallowed', () {
      final nodes = _parse('linksslimm://message?a=1');

      expect(
        nodes.whereType<InlineMessageLink>(),
        isEmpty,
        reason: 'a link only ever starts a token, the same rule http follows',
      );
    });

    test('a file scheme is never a link of any kind', () {
      final nodes = _parse('file:///etc/passwd');

      expect(nodes.whereType<InlineMessageLink>(), isEmpty);
      expect(nodes.whereType<InlineLink>(), isEmpty);
    });
  });

  test('a link nested in bold is still found', () {
    final nodes = _parse('**${_link()}**');

    final bold = nodes.whereType<InlineBold>().single;
    expect(bold.children.whereType<InlineMessageLink>(), hasLength(1));
  });
}
