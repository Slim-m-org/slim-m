// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The requests `login`, `logout`, `deleteAccount` and the push calls build,
/// pinned at the HTTP boundary because the app suites only see fakes of them.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

const _tokenBody = {
  'user_id': 'user-1',
  'access_token': 'a',
  'refresh_token': 'r',
  'access_expires_at': 0,
};

class _Seen {
  final requests = <http.Request>[];

  Map<String, dynamic> get body =>
      jsonDecode(requests.last.body) as Map<String, dynamic>;
}

SlimmApi _api(_Seen seen, http.Response Function(http.Request) respond,
    {SessionStore? session}) {
  return SlimmApi(
    baseUrl: _base,
    session: session,
    httpClient: MockClient((request) async {
      seen.requests.add(request);
      return respond(request);
    }),
  );
}

SessionStore _signedIn() => SessionStore(
      tokens: const TokenPair(
        userId: 'user-1',
        accessToken: 'access',
        refreshToken: 'refresh',
        accessExpiresAt: 0,
      ),
    );

void main() {
  group('login', () {
    test('a 200 opens the session and sends only what it was given', () async {
      final seen = _Seen();
      final api = _api(seen, (_) => http.Response(jsonEncode(_tokenBody), 200));

      final outcome = await api.login(
        username: 'ada',
        password: 'pw',
        deviceName: 'laptop',
      );

      expect(outcome, isA<SignedIn>());
      expect(api.session.tokens?.accessToken, 'a');
      expect(seen.requests.single.method, 'POST');
      expect(seen.requests.single.url.path, '/auth/login');
      expect(seen.body, {
        'username': 'ada',
        'password': 'pw',
        'device_name': 'laptop',
      });
    });

    test('a 202 is a challenge and leaves the session empty', () async {
      final seen = _Seen();
      final api = _api(
        seen,
        (_) => http.Response(
          jsonEncode({'totp_challenge': 'ch', 'expires_at': 7}),
          202,
        ),
      );

      final outcome = await api.login(
        username: 'ada',
        password: 'pw',
        deviceName: 'laptop',
      );

      expect(outcome, isA<SignInChallenged>());
      expect(api.session.tokens, isNull);
    });

    test('a 401 is unauthorized and is not retried through refresh', () async {
      final seen = _Seen();
      final api = _api(seen, (_) => http.Response('{"error":"no"}', 401));

      await expectLater(
        api.login(username: 'ada', password: 'bad', deviceName: 'laptop'),
        throwsA(isA<UnauthorizedException>()),
      );
      expect(seen.requests.map((r) => r.url.path), ['/auth/login']);
    });
  });

  group('logout', () {
    test('posts to /auth/logout and clears the session', () async {
      final seen = _Seen();
      final api = _api(
        seen,
        (_) => http.Response('', 204),
        session: _signedIn(),
      );

      await api.logout();

      expect(seen.requests.single.method, 'POST');
      expect(seen.requests.single.url.path, '/auth/logout');
      expect(api.session.tokens, isNull);
    });
  });

  group('deleteAccount', () {
    test('sends the password and the code, then clears the session', () async {
      final seen = _Seen();
      final api = _api(
        seen,
        (_) => http.Response('', 204),
        session: _signedIn(),
      );

      await api.deleteAccount(password: 'pw', code: '123456');

      expect(seen.requests.single.method, 'DELETE');
      expect(seen.requests.single.url.path, '/account');
      expect(seen.body, {'password': 'pw', 'code': '123456'});
      expect(api.session.tokens, isNull);
    });

    test('omits the code when none is given', () async {
      final seen = _Seen();
      final api = _api(
        seen,
        (_) => http.Response('', 204),
        session: _signedIn(),
      );

      await api.deleteAccount(password: 'pw');

      expect(seen.body, {'password': 'pw'});
    });

    test('keeps the session when the server refuses', () async {
      final seen = _Seen();
      final api = _api(
        seen,
        (_) => http.Response('{"error":"bad password"}', 403),
        session: _signedIn(),
      );

      await expectLater(
        api.deleteAccount(password: 'bad'),
        throwsA(isA<ApiException>()),
      );
      expect(api.session.tokens, isNotNull);
    });
  });

  group('push', () {
    test('registerPush puts the device and only flags a chosen preview',
        () async {
      final seen = _Seen();
      final api = _api(
        seen,
        (_) => http.Response('', 204),
        session: _signedIn(),
      );

      await api.registerPush(
        platform: 'fcm',
        pushToken: 'tok',
        pushPublicKey: 'pk',
      );
      expect(seen.requests.last.method, 'PUT');
      expect(seen.requests.last.url.path, '/push');
      expect(seen.body.containsKey('include_content'), isFalse);

      await api.registerPush(
        platform: 'fcm',
        pushToken: 'tok',
        pushPublicKey: 'pk',
        includeContent: false,
      );
      expect(seen.body['include_content'], false);
      expect(seen.body['include_content_chosen'], true);
    });

    test('unregisterPush deletes /push', () async {
      final seen = _Seen();
      final api = _api(
        seen,
        (_) => http.Response('', 204),
        session: _signedIn(),
      );

      await api.unregisterPush();

      expect(seen.requests.single.method, 'DELETE');
      expect(seen.requests.single.url.path, '/push');
    });

    test('the preview choice reads from and writes to /push/preview', () async {
      final seen = _Seen();
      final api = _api(
        seen,
        (request) => request.method == 'GET'
            ? http.Response('{"include_content":true}', 200)
            : http.Response('', 204),
        session: _signedIn(),
      );

      expect(await api.pushPreview(), isTrue);
      await api.setPushPreview(false);

      expect(seen.requests.last.method, 'PUT');
      expect(seen.requests.last.url.path, '/push/preview');
      expect(seen.body, {'include_content': false});
    });
  });
}
