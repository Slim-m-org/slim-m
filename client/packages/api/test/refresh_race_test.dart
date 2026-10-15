// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A rotation still in flight when the session changes must not put the old
/// session back (issue 2021).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

TokenPair _tokens(String refresh) => TokenPair(
      userId: 'user-1',
      accessToken: 'access-$refresh',
      refreshToken: refresh,
      accessExpiresAt: 0,
    );

/// A client whose first protected call 401s and whose refresh answer waits for [release].
SlimmApi _client(SessionStore session, Completer<void> release,
        {int refreshStatus = 200}) =>
    SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: session,
      httpClient: MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          await release.future;
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
        if (request.url.path == '/auth/logout') return http.Response('', 204);
        return http.Response('{"error":"expired"}', 401);
      }),
    );

void main() {
  test('signing out while a refresh is in flight stays signed out', () async {
    final session = SessionStore(tokens: _tokens('refresh-1'));
    final release = Completer<void>();
    final api = _client(session, release);

    final call = api.listChannels().then((_) {}, onError: (_) {});
    await Future<void>.delayed(Duration.zero);
    session.clear();
    release.complete();
    await call;

    expect(session.isSignedIn, isFalse,
        reason: 'the late refresh answer is dropped');
  });

  test('a sign-in to another account during a refresh keeps the new account',
      () async {
    final session = SessionStore(tokens: _tokens('refresh-1'));
    final release = Completer<void>();
    final api = _client(session, release, refreshStatus: 401);

    final call = api.listChannels().then((_) {}, onError: (_) {});
    await Future<void>.delayed(Duration.zero);
    session.set(_tokens('someone-else'));
    release.complete();
    await call;

    expect(session.tokens?.refreshToken, 'someone-else',
        reason: 'a stale 401 does not sign the new account out');
  });
}
