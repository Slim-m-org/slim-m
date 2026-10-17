// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// #2021: a token refresh that lands after the session moved on (signed out,
/// or signed in as someone else) never puts the old account back.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

const _old = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _someoneElse = TokenPair(
  userId: 'user-2',
  accessToken: 'access-9',
  refreshToken: 'refresh-9',
  accessExpiresAt: 0,
);

/// An API whose first protected call 401s and whose refresh waits on [gate],
/// answering [refreshStatus].
SlimmApi _api(Completer<void> gate, {int refreshStatus = 200}) => SlimmApi(
      baseUrl: _base,
      session: SessionStore(tokens: _old),
      httpClient: MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          await gate.future;
          if (refreshStatus != 200) {
            return http.Response('{"error":"revoked"}', refreshStatus);
          }
          return http.Response(
            jsonEncode({
              'user_id': 'user-1',
              'access_token': 'access-2',
              'refresh_token': 'refresh-2',
              'access_expires_at': 99,
            }),
            200,
          );
        }
        return http.Response('{"error":"expired"}', 401);
      }),
    );

void main() {
  test('signing out during a refresh stays signed out', () async {
    final gate = Completer<void>();
    final api = _api(gate);
    final call = api.listChannels();
    await Future<void>.delayed(Duration.zero);

    api.session.clear();
    gate.complete();

    await expectLater(call, throwsA(isA<UnauthorizedException>()));
    expect(api.session.tokens, isNull);
  });

  test('signing in as someone else during a refresh keeps them', () async {
    final gate = Completer<void>();
    final api = _api(gate);
    final call = api.listChannels();
    await Future<void>.delayed(Duration.zero);

    api.session.set(_someoneElse);
    gate.complete();

    await expectLater(call, throwsA(isA<UnauthorizedException>()));
    expect(api.session.tokens, _someoneElse);
  });

  test('a refused refresh does not sign out the account that replaced it',
      () async {
    final gate = Completer<void>();
    final api = _api(gate, refreshStatus: 401);
    final call = api.listChannels();
    await Future<void>.delayed(Duration.zero);

    api.session.set(_someoneElse);
    gate.complete();

    await expectLater(call, throwsA(isA<UnauthorizedException>()));
    expect(api.session.tokens, _someoneElse);
  });
}
