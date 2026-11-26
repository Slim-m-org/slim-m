// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A browser tab never stores a refresh token where page script can read it (decision 0141).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/web_session.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

/// What a cookie session holds after a sign-in: no refresh token.
const _webPair = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: '',
  accessExpiresAt: 0,
);

const _serverUrl = 'https://chat.example';

/// Remembers every value written, so a test can look for a token anywhere, not only under one handle.
class _RecordingKeyStore extends InMemoryKeyStore {
  final written = <String>[];

  @override
  Future<KeyHandle> put(String name, String secret) {
    written.add(secret);
    return super.put(name, secret);
  }
}

ProviderContainer _container(
  KeyStore keys,
  WebSessionMode mode, {
  List<http.Request>? seen,
  int status = 200,
  String? bodyRefreshToken,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(keys),
      webSessionModeProvider.overrideWithValue(mode),
      if (seen != null)
        apiProvider.overrideWith(
          (ref) => SlimmApi(
            baseUrl: Uri.parse(_serverUrl),
            session: ref.read(sessionProvider),
            webSession: true,
            httpClient: MockClient((request) async {
              seen.add(request);
              return http.Response(
                status != 200
                    ? '{}'
                    : jsonEncode({
                        'user_id': 'user-1',
                        'access_token': 'access-2',
                        'access_expires_at': 9,
                        'refresh_token': ?bodyRefreshToken,
                      }),
                status,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({hasLaunchedBeforeKey: true}),
  );

  group('webSessionModeFor', () {
    final page = Uri.parse('https://chat.example/app/');
    WebSessionMode modeFor(String server, {Uri? at, bool web = true}) =>
        webSessionModeFor(Uri.parse(server), isWeb: web, page: at ?? page);

    test('the real build reads its own platform and page', () {
      expect(
        webSessionModeFor(Uri.base),
        kIsWeb ? WebSessionMode.memory : WebSessionMode.native,
        reason: 'a test page is plain-http loopback, which keeps no cookie',
      );
    });

    test('desktop and phones keep the platform key store', () {
      expect(modeFor(_serverUrl, web: false), WebSessionMode.native);
    });

    test('a browser on its own https server uses the cookie', () {
      expect(modeFor(_serverUrl), WebSessionMode.cookie);
    });

    test(
      'plain-http loopback stores nothing: Safari drops its Secure cookie',
      () {
        expect(
          modeFor(
            'http://localhost:8080',
            at: Uri.parse('http://localhost:8080/app/'),
          ),
          WebSessionMode.memory,
        );
      },
    );

    test('a plain-http LAN server stores nothing', () {
      expect(
        modeFor(
          'http://10.0.0.5:8080',
          at: Uri.parse('http://10.0.0.5:8080/app/'),
        ),
        WebSessionMode.memory,
      );
    });

    test(
      'another origin stores nothing: a Strict cookie never travels there',
      () {
        expect(modeFor('https://other.example'), WebSessionMode.memory);
      },
    );
  });

  group('in cookie mode', () {
    test('a sign-in stores the account id and no credential', () async {
      final keys = _RecordingKeyStore();
      final container = _container(keys, WebSessionMode.cookie);

      container.read(sessionProvider).set(_webPair);
      await container.read(sessionProvider).settled;

      expect(jsonDecode(await keys.read(sessionTokenHandle) ?? 'null'), {
        'user_id': 'user-1',
      });
      final everything = keys.written.join('\n');
      expect(everything, isNot(contains('access-1')));
      expect(everything, isNot(contains('refresh-1')));
    });

    test('a reload resumes signed in with no token to present', () async {
      final keys = _RecordingKeyStore();
      await keys.put(sessionTokenHandle, jsonEncode({'user_id': 'user-1'}));
      await keys.put(serverUrlHandle, _serverUrl);
      final container = _container(keys, WebSessionMode.cookie);

      await restoreSession(container);

      final tokens = container.read(sessionProvider).tokens!;
      expect(tokens.userId, 'user-1');
      expect(tokens.accessToken, isEmpty);
      expect(tokens.refreshToken, isEmpty);
    });

    test('a pair stored before the cookie is spent into it, and only then '
        'replaced by the account id', () async {
      final keys = _RecordingKeyStore();
      await keys.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
      await keys.put(serverUrlHandle, _serverUrl);
      final seen = <http.Request>[];
      final container = _container(keys, WebSessionMode.cookie, seen: seen);

      await restoreSession(container);
      await pumpEventQueue(times: 100);
      await container.read(sessionProvider).settled;

      expect(jsonDecode(seen.single.body)['refresh_token'], 'refresh-1');
      expect(seen.single.headers['x-slimm-web-session'], 'cookie');
      expect(container.read(sessionProvider).tokens!.accessToken, 'access-2');
      expect(container.read(sessionProvider).tokens!.refreshToken, isEmpty);
      expect(jsonDecode((await keys.read(sessionTokenHandle))!), {
        'user_id': 'user-1',
      }, reason: 'the old refresh token is gone once the cookie holds it');
    });

    test('a server that still answers with a refresh token is stored natively, '
        'never keeping the spent legacy pair', () async {
      final keys = _RecordingKeyStore();
      await keys.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
      await keys.put(serverUrlHandle, _serverUrl);
      final container = _container(
        keys,
        WebSessionMode.cookie,
        seen: <http.Request>[],
        bodyRefreshToken: 'refresh-2',
      );

      await restoreSession(container);
      await pumpEventQueue(times: 100);
      await container.read(sessionProvider).settled;

      expect(
        jsonDecode((await keys.read(sessionTokenHandle))!)['refresh_token'],
        'refresh-2',
      );
    });

    test(
      'a migration refresh that fails keeps the stored pair for the next load',
      () async {
        final keys = _RecordingKeyStore();
        await keys.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
        await keys.put(serverUrlHandle, _serverUrl);
        final seen = <http.Request>[];
        final container = _container(
          keys,
          WebSessionMode.cookie,
          seen: seen,
          status: 503,
        );

        await restoreSession(container);
        await pumpEventQueue(times: 100);
        await container.read(sessionProvider).settled;

        expect(seen, isNotEmpty);
        expect(
          jsonDecode((await keys.read(sessionTokenHandle))!)['refresh_token'],
          'refresh-1',
          reason: 'a network failure must not lose the only copy of the token',
        );
      },
    );

    test('signing out deletes what is stored', () async {
      final keys = _RecordingKeyStore();
      final container = _container(keys, WebSessionMode.cookie);
      final session = container.read(sessionProvider);
      session.set(_webPair);
      await session.settled;

      session.clear();
      await session.settled;

      expect(await keys.read(sessionTokenHandle), isNull);
    });
  });

  group('in memory mode', () {
    test('a sign-in stores nothing', () async {
      final keys = _RecordingKeyStore();
      final container = _container(keys, WebSessionMode.memory);

      container.read(sessionProvider).set(_tokens);
      await container.read(sessionProvider).settled;

      expect(await keys.read(sessionTokenHandle), isNull);
      expect(keys.written.join('\n'), isNot(contains('refresh-1')));
    });

    test('a pair left by an older build is deleted and not restored', () async {
      final keys = _RecordingKeyStore();
      await keys.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
      await keys.put(serverUrlHandle, _serverUrl);
      final container = _container(keys, WebSessionMode.memory);

      await restoreSession(container);

      expect(container.read(sessionProvider).isSignedIn, isFalse);
      expect(await keys.read(sessionTokenHandle), isNull);
    });

    test('another tab writing to storage does not sign this tab out', () async {
      final keys = _RecordingKeyStore();
      final container = _container(keys, WebSessionMode.memory);
      final session = container.read(sessionProvider);
      session.set(_tokens);

      await session.reloadFromStorage();

      expect(session.tokens, _tokens);
    });
  });

  group('in native mode', () {
    test('the whole pair is stored as before', () async {
      final keys = _RecordingKeyStore();
      final container = _container(keys, WebSessionMode.native);

      container.read(sessionProvider).set(_tokens);
      await container.read(sessionProvider).settled;

      expect(
        jsonDecode((await keys.read(sessionTokenHandle))!),
        _tokens.toJson(),
      );
    });
  });
}
