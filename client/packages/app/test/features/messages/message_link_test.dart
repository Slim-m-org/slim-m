// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Building, parsing and scoping a message link.
///
/// The parse cases matter more than the build ones: a link arrives from a paste,
/// so every one of them is a string this app did not write. The rule is the same
/// as `parseInviteLink`'s - anything that is not a well-formed message link is
/// null, because the caller's response to all of them is identical.
///
/// `messageLinkIsHere` is the security-relevant half. A link to another
/// deployment is not followed, and these cases pin both that it refuses a
/// genuinely different server and that it does not refuse this one over a
/// spelling difference.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/message_link.dart';

void main() {
  group('round trip', () {
    test('a built link parses back to what went in', () {
      final link = buildMessageLink(
        server: Uri.parse('https://slim.example.top'),
        channelId: 'c1',
        messageId: 'm1',
      );

      final parsed = parseMessageLink(link);

      expect(parsed, isNotNull);
      expect(parsed!.server, Uri.parse('https://slim.example.top'));
      expect(parsed.channelId, 'c1');
      expect(parsed.messageId, 'm1');
    });

    test('a port survives, because a self-hosted deployment may need one', () {
      final link = buildMessageLink(
        server: Uri.parse('https://slim.example.top:8443'),
        channelId: 'c1',
        messageId: 'm1',
      );

      expect(parseMessageLink(link)!.server.port, 8443);
    });

    test('the link is a slimm scheme, never http', () {
      final link = buildMessageLink(
        server: Uri.parse('https://slim.example.top'),
        channelId: 'c1',
        messageId: 'm1',
      );

      expect(link, startsWith('slimm://message?'));
    });
  });

  group('a paste that is not a message link is null', () {
    test('an invite link is not one', () {
      expect(
        parseMessageLink('slimm://join?server=https%3A%2F%2Fa.top&code=abc'),
        isNull,
        reason:
            'the host distinguishes them; one flow must not accept the other',
      );
    });

    test('a web address is not one', () {
      expect(parseMessageLink('https://slim.example.top/channels/c1'), isNull);
    });

    test('a bare word, empty text and whitespace are not one', () {
      expect(parseMessageLink('hello'), isNull);
      expect(parseMessageLink(''), isNull);
      expect(parseMessageLink('   '), isNull);
    });

    test('a message link missing any part is not one', () {
      const server = 'server=https%3A%2F%2Fa.top';
      expect(parseMessageLink('slimm://message?$server&channel=c1'), isNull);
      expect(parseMessageLink('slimm://message?$server&id=m1'), isNull);
      expect(parseMessageLink('slimm://message?channel=c1&id=m1'), isNull);
      expect(parseMessageLink('slimm://message'), isNull);
    });

    test('a server that is not a usable address is not one', () {
      expect(
        parseMessageLink('slimm://message?server=nonsense&channel=c1&id=m1'),
        isNull,
        reason: 'no scheme, so nothing could be reached',
      );
      expect(
        parseMessageLink(
          'slimm://message?server=https%3A%2F%2F&channel=c1&id=m1',
        ),
        isNull,
        reason: 'no host',
      );
    });

    test('surrounding whitespace is tolerated', () {
      final link = buildMessageLink(
        server: Uri.parse('https://a.top'),
        channelId: 'c1',
        messageId: 'm1',
      );

      expect(parseMessageLink('  $link  '), isNotNull);
    });
  });

  group('scoping to this deployment', () {
    MessageLink linkTo(String server) =>
        (server: Uri.parse(server), channelId: 'c1', messageId: 'm1');

    test('the same server is here', () {
      expect(
        messageLinkIsHere(
          linkTo('https://slim.example.top'),
          Uri.parse('https://slim.example.top'),
        ),
        isTrue,
      );
    });

    test('a different host is not', () {
      expect(
        messageLinkIsHere(
          linkTo('https://elsewhere.example.top'),
          Uri.parse('https://slim.example.top'),
        ),
        isFalse,
        reason:
            'following it would be a server switch, which a link cannot decide',
      );
    });

    test('a different port on the same host is not', () {
      expect(
        messageLinkIsHere(
          linkTo('https://slim.example.top:8443'),
          Uri.parse('https://slim.example.top'),
        ),
        isFalse,
      );
    });

    test('a different scheme is not, even on the same host', () {
      expect(
        messageLinkIsHere(
          linkTo('http://slim.example.top'),
          Uri.parse('https://slim.example.top'),
        ),
        isFalse,
      );
    });

    group('but a spelling difference does not make this server foreign', () {
      test('a trailing slash', () {
        expect(
          messageLinkIsHere(
            linkTo('https://slim.example.top/'),
            Uri.parse('https://slim.example.top'),
          ),
          isTrue,
        );
      });

      test('a default port written out', () {
        expect(
          messageLinkIsHere(
            linkTo('https://slim.example.top:443'),
            Uri.parse('https://slim.example.top'),
          ),
          isTrue,
        );
      });

      test('a differently cased host', () {
        expect(
          messageLinkIsHere(
            linkTo('https://SLIM.Example.Top'),
            Uri.parse('https://slim.example.top'),
          ),
          isTrue,
        );
      });
    });
  });
}
