// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scope reset drops every cached message and refetches only the newest
/// page, so the mention cursor comes back from the server's own marker: an
/// unread mention older than that page still lights the channel. A cursor left
/// on a message never held asks for the marker on later syncs, so it heals
/// once that message is deleted or edited away.
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

Map<String, Object?> _message(int seq, {bool mentionsMe = false}) => {
  'id': 'm$seq',
  'channel_id': 'c1',
  'author_id': 'u1',
  'seq': seq,
  'content': 'message $seq',
  'created_at': 1,
  'mentions_me': mentionsMe,
};

/// `c1`'s delta, answering [cursor] (the scope the client sent).
typedef _Delta = Map<String, Object?> Function(Map<String, dynamic> cursor);

Map<String, Object?> _scope({
  bool reset = false,
  List<Object> messages = const [],
  List<Object> ops = const [],
  int? mentionedSeq,
}) => {
  'channel_id': 'c1',
  'messages': messages,
  'has_more': reset,
  'reset': reset,
  'ops': ops,
  'op_latest_seq': 0,
  'ops_has_more': false,
  'mentioned_seq': ?mentionedSeq,
};

/// One sign-in's catch-up of `c1` (read up to seq 80) into [store]; the
/// channel row after it.
Future<Channel> _catchUp(
  MessageStore store, {
  required _Delta delta,
  List<Object> page = const [],
}) async {
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
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final cursors = (body['scopes'] as List)
                .cast<Map<String, dynamic>>();
            return _json({
              'scopes': [
                for (final cursor in cursors)
                  if (cursor['channel_id'] == 'c1') delta(cursor),
              ],
            });
          case '/channels/c1/messages':
            return _json(page);
        }
        return http.Response('unavailable', 503);
      }),
    ],
  );
  addTearDown(container.dispose);
  await container.read(syncControllerProvider.notifier).start();
  return (await store.allChannels()).single;
}

MessageStore _store() {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return MessageStore(db);
}

/// The channel row after a sign-in whose catch-up resets `c1`, with the
/// server naming [mentionedSeq] as its newest mention, or no marker at all.
Future<Channel> _afterReset(MessageStore store, {int? mentionedSeq}) =>
    _catchUp(
      store,
      delta: (_) => _scope(reset: true, mentionedSeq: mentionedSeq),
      page: [_message(1200)],
    );

/// Answers like the server: the marker only for a scope that asked.
_Delta _answersWhenAsked(int newest, {required List<bool> asked}) => (cursor) {
  final asking = cursor['check_mention'] == true;
  asked.add(asking);
  return _scope(mentionedSeq: asking ? newest : null);
};

void main() {
  test(
    'an unread mention older than the refetched page keeps its badge',
    () async {
      final channel = await _afterReset(_store(), mentionedSeq: 90);
      expect(channel.cursor, 1200, reason: 'the reset did refetch the page');
      expect(channel.mentionedSeq, 90);
      expect(channel.mentionedSeq > channel.lastReadSeq, isTrue);
    },
  );

  test('a server with no mention marker leaves the reset as it was', () async {
    final channel = await _afterReset(_store());
    expect(channel.cursor, 1200);
    expect(channel.mentionedSeq, 0);
  });

  test('a marked mention deleted later stops lighting the channel', () async {
    final store = _store();
    await _afterReset(store, mentionedSeq: 90);
    final asked = <bool>[];
    final channel = await _catchUp(
      store,
      delta: _answersWhenAsked(0, asked: asked),
    );
    expect(asked, [true], reason: 'the cursor names a message never held');
    expect(channel.mentionedSeq, 0);
  });

  test('a held mention is never lowered by an older marker', () async {
    final store = _store();
    await _afterReset(store, mentionedSeq: 90);
    await _catchUp(
      store,
      delta: (_) => _scope(messages: [_message(1201, mentionsMe: true)]),
    );
    final asked = <bool>[];
    final channel = await _catchUp(
      store,
      delta: (cursor) {
        asked.add(cursor['check_mention'] == true);
        return _scope(mentionedSeq: 90);
      },
    );
    expect(asked, [false], reason: 'the newest mention is held');
    expect(channel.mentionedSeq, 1201);
  });

  test('a reset the client starts itself keeps its mention cursor', () async {
    final store = _store();
    await _catchUp(
      store,
      delta: (_) => _scope(messages: [_message(1250, mentionsMe: true)]),
    );
    final channel = await _catchUp(
      store,
      delta: (_) => _scope(
        ops: [
          {
            'seq': 1,
            'kind': 'from_a_newer_server',
            'message_id': 'm1250',
            'created_at': 1,
          },
        ],
      ),
      page: [_message(1300)],
    );
    expect(channel.cursor, 1300, reason: 'the unknown op did reset');
    expect(channel.mentionedSeq, 1250);
  });
}
