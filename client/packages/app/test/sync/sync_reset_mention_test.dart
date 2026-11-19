// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scope reset drops every cached message and refetches only the newest
/// page, so the mention cursor comes back from the server's own marker: an
/// unread mention older than that page still lights the channel.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';
import '../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// The channel row after a sign-in whose catch-up resets `c1`, with the
/// server naming [mentionedSeq] as its newest mention, or no marker at all.
Future<Channel> _afterReset({int? mentionedSeq}) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      storeProvider.overrideWith((ref) async => store),
      mockApiOverride((request) async {
        switch (request.url.path) {
          case '/channels':
            return _json([
              {'id': 'c1', 'name': 'busy', 'kind': 'text', 'created_at': 0},
            ]);
          case '/categories':
          case '/dms':
            return _json(<Object>[]);
          case '/read-states':
            return _json([
              {
                'channel_id': 'c1',
                'last_read_seq': 80,
                'unread': 1000,
                'manually_unread': false,
              },
            ]);
          case '/sync':
            return _json({
              'scopes': [
                {
                  'channel_id': 'c1',
                  'messages': <Object>[],
                  'has_more': true,
                  'reset': true,
                  'ops': <Object>[],
                  'op_latest_seq': 0,
                  'ops_has_more': false,
                  'mentioned_seq': ?mentionedSeq,
                },
              ],
            });
          case '/channels/c1/messages':
            return _json([
              {
                'id': 'm1200',
                'channel_id': 'c1',
                'author_id': 'u1',
                'seq': 1200,
                'content': 'the newest page mentions nobody',
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
  return (await store.allChannels()).single;
}

void main() {
  test(
    'an unread mention older than the refetched page keeps its badge',
    () async {
      final channel = await _afterReset(mentionedSeq: 90);
      expect(channel.cursor, 1200, reason: 'the reset did refetch the page');
      expect(channel.mentionedSeq, 90);
      expect(channel.mentionedSeq > channel.lastReadSeq, isTrue);
    },
  );

  test('a server with no mention marker leaves the reset as it was', () async {
    final channel = await _afterReset();
    expect(channel.cursor, 1200);
    expect(channel.mentionedSeq, 0);
  });
}
