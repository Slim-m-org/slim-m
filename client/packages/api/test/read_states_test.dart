// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `GET /read-states` and the rate-limit wait a 429 carries.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Uri get _base => Uri.parse('http://localhost:8080');

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

void main() {
  group('listReadStates', () {
    test('parses every channel marker from one GET /read-states', () async {
      final requests = <String>[];
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens),
        httpClient: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          return http.Response(
            jsonEncode([
              {
                'channel_id': 'c1',
                'last_read_seq': 4,
                'unread': 2,
                'manually_unread': true,
              },
              {'channel_id': 'c2', 'last_read_seq': 0, 'unread': 0},
            ]),
            200,
          );
        }),
      );

      final states = await api.listReadStates();

      expect(requests, ['GET /read-states']);
      expect(states.map((s) => s.channelId), ['c1', 'c2']);
      expect(states[0].state.lastReadSeq, 4);
      expect(states[0].state.manuallyUnread, isTrue);
      expect(states[1].state.manuallyUnread, isFalse);
    });
  });

  group('429 wait', () {
    Future<void> expectRetryAfter(
      http.Response response,
      Duration expected,
    ) async {
      final api = SlimmApi(
        baseUrl: _base,
        httpClient: MockClient((_) async => response),
      );
      await expectLater(
        api.version,
        throwsA(
          isA<RateLimitedException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            expected,
          ),
        ),
      );
    }

    test('comes from the body when no header does', () async {
      await expectRetryAfter(
        http.Response('{"error":"rate limited","retry_after_seconds":3}', 429),
        const Duration(seconds: 3),
      );
    });

    test('prefers the Retry-After header over the body', () async {
      await expectRetryAfter(
        http.Response(
          '{"error":"x","retry_after_seconds":9}',
          429,
          headers: {'retry-after': '2'},
        ),
        const Duration(seconds: 2),
      );
    });
  });

  group('listUsers', () {
    test('splits a long id list at the server cap of 100', () async {
      final sizes = <int>[];
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens),
        httpClient: MockClient((request) async {
          sizes.add(request.url.queryParameters['ids']!.split(',').length);
          return http.Response('[]', 200);
        }),
      );

      await api.listUsers([for (var i = 0; i < 230; i++) 'u$i']);

      expect(sizes..sort(), [30, 100, 100]);
    });

    test('asks nothing for no ids and once for a repeated one', () async {
      var requests = 0;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens),
        httpClient: MockClient((_) async {
          requests++;
          return http.Response('[]', 200);
        }),
      );

      await api.listUsers(const []);
      expect(requests, 0);
      await api.listUsers(['a', 'a', 'a']);
      expect(requests, 1);
    });
  });
}
