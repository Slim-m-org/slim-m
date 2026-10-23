// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two tabs of one browser profile sharing a stored session: the second to
/// notice an expired access token must adopt the first one's rotation, because
/// refreshing with the spent token would make the server revoke the family.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

TokenPair _pair(int n) => TokenPair(
      userId: 'user-1',
      accessToken: 'access$n',
      refreshToken: 'refresh$n',
      accessExpiresAt: 0,
    );

/// The browser's shared storage plus a lock every tab queues on.
class _Browser {
  TokenPair? stored = _pair(1);
  Future<void> _tail = Future.value();
  final writes = StreamController<void>.broadcast(sync: true);

  Future<void> write(TokenPair? tokens) async {
    stored = tokens;
    writes.add(null);
  }
}

class _TabSync implements SessionSync {
  _TabSync(this._browser);

  final _Browser _browser;

  @override
  Future<T> exclusive<T>(Future<T> Function() body) {
    final turn = _browser._tail.then((_) => body());
    _browser._tail = turn.then((_) {}, onError: (_) {});
    return turn;
  }

  @override
  Future<TokenPair?> readStored() async => _browser.stored;
}

/// One server whose refresh token is single-use, like the real one.
class _Server {
  var current = 'refresh1';
  var version = 1;
  var revoked = false;
  final refreshes = <String>[];

  http.Response handle(http.Request request) {
    if (request.url.path != '/auth/refresh') return http.Response('{}', 200);
    final sent = (jsonDecode(request.body) as Map)['refresh_token'] as String;
    refreshes.add(sent);
    if (revoked || sent != current) {
      revoked = true;
      return http.Response('{"error":"unauthorized"}', 401);
    }
    version++;
    current = 'refresh$version';
    return http.Response(jsonEncode(_pair(version).toJson()), 200);
  }
}

class _Tab {
  _Tab(_Browser browser, _Server server)
      : session = SessionStore(
          tokens: browser.stored,
          onChange: browser.write,
          sync: _TabSync(browser),
        ) {
    api = SlimmApi(
      baseUrl: _base,
      session: session,
      httpClient: MockClient((request) async => server.handle(request)),
    );
  }

  final SessionStore session;
  late final SlimmApi api;
}

void main() {
  test('a second tab adopts the first tab rotation instead of refreshing',
      () async {
    final browser = _Browser();
    final server = _Server();
    final a = _Tab(browser, server);
    final b = _Tab(browser, server);

    await a.api.refresh();
    final adopted = await b.api.refresh();

    expect(server.refreshes, ['refresh1']);
    expect(adopted.refreshToken, 'refresh2');
    expect(b.session.tokens?.refreshToken, 'refresh2');
    expect(server.revoked, isFalse);
  });

  test('both tabs stay signed in through several alternating rotations',
      () async {
    final browser = _Browser();
    final server = _Server();
    final a = _Tab(browser, server);
    final b = _Tab(browser, server);

    for (var round = 0; round < 4; round++) {
      await a.api.refresh();
      await b.api.refresh();
      await b.api.refresh();
      await a.api.refresh();
    }

    expect(server.revoked, isFalse);
    expect(a.session.tokens?.refreshToken, b.session.tokens?.refreshToken);
  });

  test('tabs refreshing at once rotate once', () async {
    final browser = _Browser();
    final server = _Server();
    final a = _Tab(browser, server);
    final b = _Tab(browser, server);

    await Future.wait([a.api.refresh(), b.api.refresh()]);

    expect(server.refreshes, ['refresh1']);
    expect(server.revoked, isFalse);
  });

  test(
      'a replayed spent token with nothing newer stored still reaches the '
      'server', () async {
    final browser = _Browser();
    final server = _Server()..current = 'refresh9';
    final thief = _Tab(browser, server);

    await expectLater(
        thief.api.refresh(), throwsA(isA<UnauthorizedException>()));

    expect(server.refreshes, ['refresh1']);
    expect(server.revoked, isTrue);
    expect(thief.session.isSignedIn, isFalse);
  });

  test('a sign-out in one tab reaches the other when storage changes',
      () async {
    final browser = _Browser();
    final server = _Server();
    final a = _Tab(browser, server);
    final b = _Tab(browser, server);
    final ended = b.session.endings.first;

    a.session.clear();
    await a.session.settled;
    await b.session.reloadFromStorage();

    expect(b.session.isSignedIn, isFalse);
    expect(await ended, 'signed out in another tab');
    expect(server.refreshes, isEmpty);
  });

  test('a rotation in one tab reaches the other when storage changes',
      () async {
    final browser = _Browser();
    final server = _Server();
    final a = _Tab(browser, server);
    final b = _Tab(browser, server);

    await a.api.refresh();
    await b.session.reloadFromStorage();

    expect(b.session.tokens?.refreshToken, 'refresh2');
    expect(server.refreshes, ['refresh1']);
  });

  test('adopting another tab state is not written back to storage', () async {
    final browser = _Browser();
    final server = _Server();
    final a = _Tab(browser, server);
    final b = _Tab(browser, server);
    await a.api.refresh();
    var writes = 0;
    browser.writes.stream.listen((_) => writes++);

    await b.session.reloadFromStorage();
    await b.session.settled;

    expect(writes, 0);
  });
}
