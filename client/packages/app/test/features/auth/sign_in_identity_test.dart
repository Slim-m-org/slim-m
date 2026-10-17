// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The install id sent at sign-in: made once, kept across sign-ins, and
/// carried on the sign-in and second-factor requests.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/auth/providers/sign_in_identity.dart';
import 'package:slimm_platform/platform.dart';

class _BrokenStore extends InMemoryKeyStore {
  @override
  Future<String?> read(KeyHandle handle) async => throw StateError('no store');
}

String get _tokens => jsonEncode({
  'user_id': 'u',
  'access_token': 'a',
  'refresh_token': 'r',
  'access_expires_at': 0,
});

void main() {
  test(
    'the install id is made once and is the same on every sign-in',
    () async {
      final store = InMemoryKeyStore();
      final first = await loadInstallId(store);
      final second = await loadInstallId(store);

      expect(first, isNotNull);
      expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(second, first);
      expect(await store.read(installIdHandle), first);
    },
  );

  test('two installs do not share an id', () async {
    expect(
      await loadInstallId(InMemoryKeyStore()),
      isNot(await loadInstallId(InMemoryKeyStore())),
    );
  });

  test('a store that cannot be read sends no id rather than failing', () async {
    expect(await loadInstallId(_BrokenStore()), isNull);
  });

  test(
    'login and the second factor both carry the stored install id',
    () async {
      final bodies = <String, Map<String, dynamic>>{};
      final client = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: api.SessionStore(),
        httpClient: MockClient((request) async {
          bodies[request.url.path] =
              jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            _tokens,
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final id = await loadInstallId(InMemoryKeyStore());

      await client.login(
        username: 'alice',
        password: 'pw',
        deviceName: 'Linux - fedora',
        installId: id,
      );
      await client.verifyTotpChallenge(
        challenge: 'c',
        code: '123456',
        installId: id,
      );
      await client.login(username: 'alice', password: 'pw', deviceName: 'x');

      expect(bodies['/auth/totp/verify']!['install_id'], id);
      expect(
        bodies['/auth/login']!.containsKey('install_id'),
        isFalse,
        reason: 'the last login sent none, so the key is absent',
      );
    },
  );
}
