// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A request issued by one account is never replayed under another's tokens.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _first = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _second = TokenPair(
  userId: 'user-2',
  accessToken: 'access-2',
  refreshToken: 'refresh-2',
  accessExpiresAt: 0,
);

void main() {
  test('a 401 after the account changed is not replayed as the new account',
      () async {
    final session = SessionStore(tokens: _first);
    final gate = Completer<void>();
    final seen = <String?>[];
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: session,
      httpClient: MockClient((request) async {
        seen.add(request.headers['authorization']);
        await gate.future;
        return http.Response('{"error":"expired"}', 401);
      }),
    );

    final call = api.listChannels();
    await Future<void>.delayed(Duration.zero);
    session.set(_second);
    gate.complete();

    await expectLater(call, throwsA(isA<UnauthorizedException>()));
    expect(seen, ['Bearer access-1']);
    expect(session.tokens?.accessToken, 'access-2');
  });
}
