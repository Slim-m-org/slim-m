// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('https://slim.test');

/// A server that, like prod, drops every older access token on a rotation.
class _RotatingServer {
  int rotation = 1;
  int refreshes = 0;
  int slowCalls = 0;

  String get liveAccess => 'access-$rotation';

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path == '/auth/refresh') {
      refreshes++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      rotation++;
      return http.Response(
        jsonEncode({
          'user_id': 'user-1',
          'access_token': liveAccess,
          'refresh_token': 'refresh-$rotation',
          'access_expires_at': 99,
        }),
        200,
      );
    }
    final sent = request.headers['authorization']?.substring('Bearer '.length);
    // The first call answers late, after the other call's rotation has landed.
    if (slowCalls++ == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    if (sent != liveAccess) {
      return http.Response('{"error":"invalid credentials"}', 401);
    }
    return http.Response('[]', 200);
  }
}

void main() {
  test(
      'a 401 that lands after another call already rotated replays with the '
      'new token instead of rotating again and voiding it', () async {
    final server = _RotatingServer();
    final api = SlimmApi(
      baseUrl: _base,
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'user-1',
          accessToken: 'stale',
          refreshToken: 'refresh-1',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(server.handle),
    );

    await Future.wait([api.listChannels(), api.listChannels()]);

    expect(server.refreshes, 1);
  });
}
