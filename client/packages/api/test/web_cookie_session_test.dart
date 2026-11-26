// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A web client keeps no refresh token: the server holds it in an HttpOnly cookie (decision 0141).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('https://chat.example');

const _noRefreshBody = {
  'user_id': 'user-1',
  'access_token': 'fresh-access',
  'access_expires_at': 7,
};

SlimmApi _api(
  List<http.Request> seen,
  http.Response Function(http.Request) respond, {
  required bool webSession,
  SessionStore? session,
}) {
  return SlimmApi(
    baseUrl: _base,
    session: session,
    webSession: webSession,
    httpClient: MockClient((request) async {
      seen.add(request);
      return respond(request);
    }),
  );
}

SessionStore _hint() => SessionStore(
      tokens: const TokenPair(
        userId: 'user-1',
        accessToken: '',
        refreshToken: '',
        accessExpiresAt: 0,
      ),
    );

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

void main() {
  group('a web session', () {
    test('login names the cookie flow and parses a reply with no refresh token',
        () async {
      final seen = <http.Request>[];
      final api = _api(seen, (_) => _json(_noRefreshBody), webSession: true);

      final outcome = await api.login(
          username: 'ada', password: 'pw', deviceName: 'browser');

      expect(seen.single.headers['x-slimm-web-session'], 'cookie');
      final tokens = (outcome as SignedIn).tokens;
      expect(tokens.refreshToken, isEmpty);
      expect(api.session.tokens?.accessToken, 'fresh-access');
    });

    test('a reload refreshes with no token in the body, naming the account',
        () async {
      final seen = <http.Request>[];
      final api = _api(seen, (_) => _json(_noRefreshBody),
          webSession: true, session: _hint());

      final tokens = await api.refresh();

      final request = seen.single;
      expect(request.url.path, '/auth/refresh');
      expect(request.headers['x-slimm-web-session'], 'cookie');
      expect(request.headers['x-slimm-account'], 'user-1');
      expect(jsonDecode(request.body), isNot(contains('refresh_token')));
      expect(tokens.accessToken, 'fresh-access');
      expect(api.session.tokens?.refreshToken, isEmpty);
    });

    test('a request with an empty access token is refreshed, then replayed',
        () async {
      final seen = <http.Request>[];
      final api = _api(seen, (request) {
        if (request.url.path == '/auth/refresh') return _json(_noRefreshBody);
        final bearer = request.headers['authorization'];
        return bearer == 'Bearer fresh-access'
            ? _json(<Object>[])
            : _json({'error': 'unauthorized'}, 401);
      }, webSession: true, session: _hint());

      expect(await api.listChannels(), isEmpty);
      expect(seen.map((r) => r.url.path),
          ['/channels', '/auth/refresh', '/channels']);
    });

    test('a rejected cookie ends the session', () async {
      final api = _api([], (_) => _json({'error': 'unauthorized'}, 401),
          webSession: true, session: _hint());

      await expectLater(api.refresh(), throwsA(isA<UnauthorizedException>()));
      expect(api.session.isSignedIn, isFalse);
    });

    test('a refreshed pair for another account is refused and ends the session',
        () async {
      final api = _api(
          [],
          (_) => _json({
                'user_id': 'someone-else',
                'access_token': 'theirs',
                'access_expires_at': 7,
              }),
          webSession: true,
          session: _hint());

      await expectLater(api.refresh(), throwsA(isA<UnauthorizedException>()));

      expect(api.session.isSignedIn, isFalse);
    });

    test('a pre-cookie refresh token is sent once, to move it into the cookie',
        () async {
      final seen = <http.Request>[];
      final session = SessionStore(
        tokens: const TokenPair(
          userId: 'user-1',
          accessToken: 'old',
          refreshToken: 'legacy-refresh',
          accessExpiresAt: 0,
        ),
      );
      final api = _api(seen, (_) => _json(_noRefreshBody),
          webSession: true, session: session);

      await api.refresh();

      expect(jsonDecode(seen.single.body)['refresh_token'], 'legacy-refresh');
      expect(session.tokens?.refreshToken, isEmpty);
    });

    test('logout names the cookie flow so the server clears it', () async {
      final seen = <http.Request>[];
      final api = _api(seen, (_) => http.Response('', 204),
          webSession: true, session: _hint());

      await api.logout();

      expect(seen.single.headers['x-slimm-web-session'], 'cookie');
      expect(api.session.isSignedIn, isFalse);
    });
  });

  group('every other client', () {
    test('sends no cookie-flow header and still carries its refresh token',
        () async {
      final seen = <http.Request>[];
      final session = SessionStore(
        tokens: const TokenPair(
          userId: 'user-1',
          accessToken: 'a',
          refreshToken: 'r1',
          accessExpiresAt: 0,
        ),
      );
      final api = _api(
          seen,
          (_) => _json({
                'user_id': 'user-1',
                'access_token': 'a2',
                'refresh_token': 'r2',
                'access_expires_at': 7,
              }),
          webSession: false,
          session: session);

      await api.refresh();

      expect(seen.single.headers.containsKey('x-slimm-web-session'), isFalse);
      expect(seen.single.headers.containsKey('x-slimm-account'), isFalse);
      expect(jsonDecode(seen.single.body)['refresh_token'], 'r1');
      expect(session.tokens?.refreshToken, 'r2');
    });
  });

  group('two tabs restored from the same pre-cookie pair', () {
    test('the second never sends the spent legacy token in the body', () async {
      final seen = <http.Request>[];
      // Tab 1 already migrated: storage holds the hint, and no announcement reached this tab.
      final session = SessionStore(
        tokens: const TokenPair(
          userId: 'user-1',
          accessToken: 'dead',
          refreshToken: 'legacy',
          accessExpiresAt: 0,
        ),
        sync: _StoredSync(TokenPair.signedInHint('user-1')),
      );
      final api = _api(seen, (_) => _json(_noRefreshBody),
          webSession: true, session: session);

      await api.refresh();

      expect(jsonDecode(seen.single.body), isNot(contains('refresh_token')));
      expect(session.tokens?.accessToken, 'fresh-access');
    });
  });

  group('a shared stored hint', () {
    test('blanks the legacy token a tab still holds, as it is spent', () async {
      final session = SessionStore(
        tokens: const TokenPair(
          userId: 'user-1',
          accessToken: 'old',
          refreshToken: 'legacy',
          accessExpiresAt: 0,
        ),
        sync: _StoredSync(TokenPair.signedInHint('user-1')),
      );

      expect(await session.adoptStoredRotation(), isNull);
      expect(session.tokens?.refreshToken, isEmpty);
      expect(session.tokens?.accessToken, 'old');
    });

    test('is taken up when another tab signed in as someone else', () async {
      final session = SessionStore(
        tokens: _hint().tokens,
        sync: _StoredSync(TokenPair.signedInHint('user-2')),
      );

      final adopted = await session.adoptStoredRotation();

      expect(adopted?.userId, 'user-2');
      expect(session.tokens?.userId, 'user-2');
    });
  });
}

class _StoredSync implements SessionSync {
  _StoredSync(this._stored);

  final TokenPair? _stored;

  @override
  Future<T> exclusive<T>(Future<T> Function() body) => body();

  @override
  Future<TokenPair?> readStored() async => _stored;
}
