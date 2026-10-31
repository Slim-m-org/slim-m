// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one string that carries a server and a code.
///
/// The round trip matters more than either half: a link this app builds has
/// to be one this app reads back, or handing an invite over in person fails
/// in the least debuggable way possible.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/invite_link.dart';

void main() {
  test('a built link reads back as the server and code it was built from', () {
    final server = Uri.parse('https://slim.npc-server.top');
    final link = buildInviteLink(server: server, code: 'ABC123');

    final parsed = parseInviteLink(link);

    expect(parsed, isNotNull);
    expect(parsed!.server, server);
    expect(parsed.code, 'ABC123');
  });

  test('a port and a path survive the round trip', () {
    // Both are load-bearing for a self-hosted deployment; dropping either breaks every non-default case.
    final server = Uri.parse('https://example.test:8443/slimm');
    final parsed = parseInviteLink(buildInviteLink(server: server, code: 'XY'));

    expect(parsed!.server, server);
  });

  test('the shared form is an https invite page link', () {
    final link = buildInviteLink(
      server: Uri.parse('https://slim.npc-server.top'),
      code: 'ABC123',
    );

    expect(link, 'https://slim.npc-server.top/invite/ABC123');
  });

  test('the slimm:// form still builds and reads back', () {
    final server = Uri.parse('https://slim.npc-server.top');
    final link = buildDeepInviteLink(server: server, code: 'ABC123');

    expect(link.startsWith('slimm://join'), isTrue);
    expect(parseInviteLink(link)!.server, server);
    expect(parseInviteLink(link)!.code, 'ABC123');
  });

  test('a pasted https invite link names the server and the code', () {
    final parsed = parseInviteLink(' https://chat.example:8443/invite/abc234 ');

    expect(parsed!.server, Uri.parse('https://chat.example:8443'));
    expect(parsed.code, 'abc234');
  });

  test('an https link that is not an invite page is not one', () {
    expect(parseInviteLink('https://chat.example/invite'), isNull);
    expect(parseInviteLink('https://chat.example/invites/abc'), isNull);
    expect(parseInviteLink('https://chat.example/app/join'), isNull);
  });

  group('things that are not invite links', () {
    test('a bare code is not one', () {
      expect(parseInviteLink('ABC123'), isNull);
    });

    test('an ordinary web address is not one', () {
      expect(parseInviteLink('https://slim.npc-server.top'), isNull);
    });

    test('an empty paste is not one', () {
      expect(parseInviteLink('   '), isNull);
    });

    test('the right scheme with the wrong host is not one', () {
      expect(
        parseInviteLink('slimm://leave?server=https://a.b&code=X'),
        isNull,
      );
    });

    test('a link missing either half is not one', () {
      expect(parseInviteLink('slimm://join?code=ABC123'), isNull);
      expect(parseInviteLink('slimm://join?server=https://a.b'), isNull);
    });

    test('a server that is not a real address is not one', () {
      expect(parseInviteLink('slimm://join?server=nonsense&code=X'), isNull);
    });
  });

  test('surrounding whitespace is forgiven, as a paste often carries it', () {
    final link = buildInviteLink(
      server: Uri.parse('https://slim.npc-server.top'),
      code: 'ABC123',
    );

    expect(parseInviteLink('  $link \n'), isNotNull);
  });

  test('an http server parses, and is left for the usual checks to refuse', () {
    // requireSecureScheme owns https, and a link must not become a way past a guard typing has to clear.
    final parsed = parseInviteLink(
      'slimm://join?server=http%3A%2F%2Fplain.test&code=X',
    );

    expect(parsed, isNotNull);
    expect(parsed!.server.scheme, 'http');
  });
}
