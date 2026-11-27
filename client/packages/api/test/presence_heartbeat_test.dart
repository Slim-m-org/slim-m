// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The REST presence heartbeat binding sends only what was asked and parses the expiry.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

TokenPair _tokens() => const TokenPair(
      userId: 'u1',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 0,
    );

void main() {
  group('presence heartbeat', () {
    test('heartbeatPresence sends only what was asked and parses the expiry',
        () async {
      http.Request? seen;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({'ttl_seconds': 90, 'expires_at': 1700000090000}),
            200,
          );
        }),
      );
      final beat = await api.heartbeatPresence(status: 'dnd', ttlSeconds: 90);
      expect(seen!.method, 'PUT');
      expect(seen!.url.path, '/presence/heartbeat');
      expect(jsonDecode(seen!.body), {'status': 'dnd', 'ttl_seconds': 90});
      expect(beat.ttlSeconds, 90);
      expect(beat.expiresAt.millisecondsSinceEpoch, 1700000090000);
    });

    test('endPresenceHeartbeat deletes the heartbeat', () async {
      http.Request? seen;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response('', 204);
        }),
      );
      await api.endPresenceHeartbeat();
      expect(seen!.method, 'DELETE');
      expect(seen!.url.path, '/presence/heartbeat');
    });
  });
}
