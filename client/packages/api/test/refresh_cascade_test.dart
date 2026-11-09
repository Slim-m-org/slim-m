// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('https://slim.test');

/// A server that, like prod, drops every older access token on a rotation.
class _RotatingServer {
  _RotatingServer({this.slowPath = '/channels'});

  /// The path whose first call answers late, after the other call's rotation has landed.
  final String slowPath;
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
    if (request.url.path == slowPath && slowCalls++ == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    if (sent != liveAccess) {
      return http.Response('{"error":"invalid credentials"}', 401);
    }
    return http.Response('[]', 200);
  }
}

SlimmApi _staleApi(_RotatingServer server) => SlimmApi(
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

void main() {
  test(
      'a 401 that lands after another call already rotated replays with the '
      'new token instead of rotating again and voiding it', () async {
    final server = _RotatingServer();
    final api = _staleApi(server);

    await Future.wait([api.listChannels(), api.listChannels()]);

    expect(server.refreshes, 1);
  });

  // Each byte route had its own copy of the rotate-on-401 rule, and only send() compared tokens.
  final lateRoutes = <String, Future<Object?> Function(SlimmApi)>{
    'fetchBytes': (api) => api.fetchAttachment('a'),
    'openDownload': (api) async {
      final download = await api.openAttachmentDownload('a');
      await download.body.drain<void>();
      return download;
    },
    'sendStreamed': (api) => api.sendStreamed(
          'POST',
          '/attachments',
          open: () => Stream.value([1, 2, 3]),
          length: 3,
        ),
  };
  for (final MapEntry(:key, :value) in lateRoutes.entries) {
    test('$key replays a late 401 without rotating a second time', () async {
      final path = key == 'sendStreamed' ? '/attachments' : '/attachments/a';
      final server = _RotatingServer(slowPath: path);
      final api = _staleApi(server);

      await Future.wait([value(api), api.listChannels()]);

      expect(server.refreshes, 1);
    });
  }
}
