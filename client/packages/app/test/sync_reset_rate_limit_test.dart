// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A catch-up that tells a scope to reset refetches its newest page, and that
/// refetch is a background read: a 429 on it waits out the server's hint and
/// tries again instead of failing the whole connect.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/rate_limit_retry.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';
import 'support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'a rate-limited reset refetch is retried after the named wait',
    () async {
      final waits = <Duration>[];
      var messageRequests = 0;
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MessageStore(db);
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          liveEventsProvider.overrideWithValue(const Stream.empty()),
          storeProvider.overrideWith((ref) async => store),
          rateLimitWaitProvider.overrideWithValue((d) async => waits.add(d)),
          mockApiOverride((request) async {
            switch (request.url.path) {
              case '/channels':
                return _json([
                  {'id': 'c1', 'name': 'busy', 'kind': 'text', 'created_at': 0},
                ]);
              case '/categories':
              case '/dms':
              case '/read-states':
                return _json(<Object>[]);
              case '/sync':
                return _json({
                  'scopes': [
                    {
                      'channel_id': 'c1',
                      'messages': <Object>[],
                      'has_more': false,
                      'reset': true,
                      'ops': <Object>[],
                      'op_latest_seq': 0,
                      'ops_has_more': false,
                    },
                  ],
                });
              case '/channels/c1/messages':
                messageRequests++;
                if (messageRequests == 1) {
                  return _json({
                    'error': 'rate limited',
                    'retry_after_seconds': 2,
                  }, 429);
                }
                return _json([
                  {
                    'id': 'm1',
                    'channel_id': 'c1',
                    'author_id': 'u1',
                    'seq': 7,
                    'content': 'hello',
                    'created_at': 1,
                  },
                ]);
            }
            return http.Response('unavailable', 503);
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(syncControllerProvider.notifier).start();

      expect(messageRequests, 2, reason: 'refused once, then asked again');
      expect(waits, [const Duration(seconds: 2)]);
      expect((await store.allCursors()).single.afterSeq, 7);
    },
  );
}
