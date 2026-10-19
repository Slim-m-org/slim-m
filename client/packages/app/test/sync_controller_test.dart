// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression test for a DM's first message never appearing live: the
/// recipient's SyncController applied a MessageCreated frame straight to the
/// store even for a channel it had never fetched, so nothing downstream (the
/// rail, the cursor, unread state) ever noticed. See sync_controller.dart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = TokenPair(
  userId: 'bob',
  accessToken: 'access-bob',
  refreshToken: 'refresh-bob',
  accessExpiresAt: 0,
);

Map<String, dynamic> _dmJson(String channelId) => {
  'channel_id': channelId,
  'user': {
    'id': 'alice',
    'username': 'alice',
    'display_name': 'Alice',
    'created_at': 0,
  },
  'unread': 1,
  'created_at': 1000,
};

Map<String, dynamic> _messageJson({
  required String id,
  required String channelId,
  required int seq,
}) => {
  'id': id,
  'channel_id': channelId,
  'author_id': 'alice',
  'author_display_name': 'Alice',
  'seq': seq,
  'content': 'hey',
  'created_at': 1000,
  'edited_at': null,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// Builds a container whose SyncController never auto-starts (its own
/// session stays signed out), while its api client carries a separately
/// signed-in session, so [SyncController.applyServerEventForTest] can be
/// driven directly without a real socket or a background [SyncController.start].
({ProviderContainer container, MessageStore store}) _harness({
  required Future<http.Response> Function(http.Request) handle,
}) {
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore()),
      storeProvider.overrideWith((ref) async => store),
      apiProvider.overrideWith((ref) {
        final api = testApi(handle, session: SessionStore(tokens: _tokens));
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );

  return (container: container, store: store);
}

void main() {
  test('a MessageCreated for a channel this client has never fetched '
      'materialises the channel before applying the message', () async {
    var dmsResponse = <Map<String, dynamic>>[];

    final harness = _harness(
      handle: (request) async {
        if (request.method == 'GET' && request.url.path == '/channels') {
          return _json(<Object>[]);
        }
        if (request.method == 'GET' && request.url.path == '/categories') {
          return _json(<Object>[]);
        }
        if (request.method == 'GET' && request.url.path == '/dms') {
          return _json(dmsResponse);
        }
        if (request.url.path.endsWith('/read')) {
          return _json({'last_read_seq': 0, 'unread': 1});
        }
        return http.Response('not found', 404);
      },
    );
    addTearDown(harness.container.dispose);
    final store = harness.store;
    addTearDown(store.db.close);

    final controller = harness.container.read(syncControllerProvider.notifier);

    // The store starts exactly like a first-contact DM recipient's does:
    // no row for the channel at all.
    expect(await store.hasChannel('dm-1'), isFalse);

    // The server already knows about the DM by the time the live frame
    // reaches this listener, since the sender's send created it.
    dmsResponse = [_dmJson('dm-1')];

    await controller.applyServerEventForTest(
      MessageCreated(
        Message.fromJson(_messageJson(id: 'm1', channelId: 'dm-1', seq: 1)),
      ),
    );

    expect(
      await store.hasChannel('dm-1'),
      isTrue,
      reason: 'the channel row must be materialised, not just the message',
    );
    final rows = await store.watchChannel('dm-1').first;
    expect(rows.single.id, 'm1');
    final channel = (await store.allChannels()).firstWhere(
      (c) => c.id == 'dm-1',
    );
    expect(
      channel.cursor,
      1,
      reason: 'the cursor must advance so unread state comes out right',
    );
    expect(
      channel.cursor > channel.lastReadSeq,
      isTrue,
      reason: 'this is what puts the unread badge on the new DM',
    );
  });

  test(
    'a burst of frames for the same unknown channel shares one refresh',
    () async {
      var refreshes = 0;
      final gate = Completer<void>();
      final dmsResponse = [_dmJson('dm-1')];

      final harness = _harness(
        handle: (request) async {
          if (request.method == 'GET' && request.url.path == '/channels') {
            return _json(<Object>[]);
          }
          if (request.method == 'GET' && request.url.path == '/categories') {
            return _json(<Object>[]);
          }
          if (request.method == 'GET' && request.url.path == '/dms') {
            refreshes++;
            // Held open so both frames below are guaranteed to see the channel
            // as still unknown before either refresh can possibly have landed.
            await gate.future;
            return _json(dmsResponse);
          }
          if (request.url.path.endsWith('/read')) {
            return _json({'last_read_seq': 0, 'unread': 0});
          }
          return http.Response('not found', 404);
        },
      );
      addTearDown(harness.container.dispose);
      final store = harness.store;
      addTearDown(store.db.close);

      final controller = harness.container.read(
        syncControllerProvider.notifier,
      );

      final first = controller.applyServerEventForTest(
        MessageCreated(
          Message.fromJson(_messageJson(id: 'm1', channelId: 'dm-1', seq: 1)),
        ),
      );
      final second = controller.applyServerEventForTest(
        MessageEdited(
          Message.fromJson(_messageJson(id: 'm1', channelId: 'dm-1', seq: 1)),
        ),
      );

      // Both frames have reached (and are blocked inside) the GET /dms mock by
      // now, so releasing the gate exercises the dedupe rather than a race.
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait([first, second]);

      expect(
        refreshes,
        1,
        reason:
            'a burst of frames for one unknown channel must not fan out '
            'into a GET /channels + GET /dms pair per frame',
      );
    },
  );
}
