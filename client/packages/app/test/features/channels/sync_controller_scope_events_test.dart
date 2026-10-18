// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression coverage for the role, overwrite, and channel WebSocket events:
/// before this, none of the three ever reached `SyncController`, so a channel
/// created, renamed, deleted, or whose visibility changed through a role or
/// overwrite edit stayed stale in the local store (and so in the rail) until
/// the next reconnect. See `hub::Event` and `http::ws::authorize` server-side.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/providers/last_text_channel.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = TokenPair(
  userId: 'alice',
  accessToken: 'access-alice',
  refreshToken: 'refresh-alice',
  accessExpiresAt: 0,
);

Map<String, dynamic> _channelJson({
  required String id,
  required String name,
  String kind = 'text',
  String? topic,
}) => {
  'id': id,
  'name': name,
  'kind': kind,
  'topic': topic,
  'created_at': 1000,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// Mirrors `sync_controller_test.dart`'s harness: a SyncController that never
/// auto-starts, driven directly through [SyncController.applyServerEventForTest].
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
  test(
    'channel.created adds the channel to the local list with no API call',
    () async {
      final harness = _harness(
        handle: (request) async => http.Response('unexpected call', 500),
      );
      addTearDown(harness.container.dispose);
      addTearDown(harness.store.db.close);
      final controller = harness.container.read(
        syncControllerProvider.notifier,
      );

      await controller.applyServerEventForTest(
        ChannelCreated(
          Channel.fromJson(_channelJson(id: 'c1', name: 'announcements')),
        ),
      );

      expect(await harness.store.hasChannel('c1'), isTrue);
      final rows = await harness.store.watchChannels().first;
      expect(rows.single.name, 'announcements');
    },
  );

  test(
    'channel.updated replaces the name and topic of an already-known row',
    () async {
      final harness = _harness(
        handle: (request) async => http.Response('unexpected call', 500),
      );
      addTearDown(harness.container.dispose);
      addTearDown(harness.store.db.close);
      final controller = harness.container.read(
        syncControllerProvider.notifier,
      );

      await harness.store.upsertChannels([
        Channel.fromJson(_channelJson(id: 'c1', name: 'old-name')),
      ]);

      await controller.applyServerEventForTest(
        ChannelUpdated(
          Channel.fromJson(
            _channelJson(id: 'c1', name: 'new-name', topic: 'a fresh topic'),
          ),
        ),
      );

      final rows = await harness.store.watchChannels().first;
      expect(rows.single.name, 'new-name');
      expect(rows.single.topic, 'a fresh topic');
    },
  );

  test(
    'channel.deleted drops an already-known channel from the local list',
    () async {
      final harness = _harness(
        handle: (request) async => http.Response('unexpected call', 500),
      );
      addTearDown(harness.container.dispose);
      addTearDown(harness.store.db.close);
      final controller = harness.container.read(
        syncControllerProvider.notifier,
      );

      await harness.store.upsertChannels([
        Channel.fromJson(_channelJson(id: 'c1', name: 'doomed')),
      ]);
      expect(await harness.store.hasChannel('c1'), isTrue);

      await controller.applyServerEventForTest(
        const ChannelDeleted(channelId: 'c1'),
      );

      expect(await harness.store.hasChannel('c1'), isFalse);
    },
  );

  test(
    'channel.deleted remembers the name, so an open pane can say what went',
    () async {
      final harness = _harness(
        handle: (request) async => http.Response('unexpected call', 500),
      );
      addTearDown(harness.container.dispose);
      addTearDown(harness.store.db.close);
      final controller = harness.container.read(
        syncControllerProvider.notifier,
      );
      await harness.store.upsertChannels([
        Channel.fromJson(_channelJson(id: 'c1', name: 'ticket-0004')),
      ]);

      await controller.applyServerEventForTest(
        const ChannelDeleted(channelId: 'c1'),
      );

      expect(harness.container.read(deletedChannelsProvider), {
        'c1': 'ticket-0004',
      });
      expect(harness.container.read(removedRoomsProvider), isEmpty);
    },
  );

  /// The one behaviour shared by overwrite.changed, role.changed, and
  /// member.role_changed: none say which channels changed, only that a
  /// refresh is worth doing, so this proves the refresh both adds a channel
  /// newly visible and prunes one no longer listed - the pruning half is new
  /// with this change (`MessageStore.replaceChannels`); a plain re-upsert of
  /// the server's answer would have left the stale channel behind forever.
  for (final trigger in [
    ('overwrite.changed', const OverwriteChanged(channelId: 'irrelevant')),
    ('role.changed', const RoleChanged(roleId: 'irrelevant')),
    (
      'member.role_changed',
      const MemberRoleChanged(userId: 'irrelevant', roleId: 'irrelevant'),
    ),
  ]) {
    final (label, event) = trigger;
    test('$label refreshes the channel list, adding what is newly visible '
        'and dropping what is no longer listed', () async {
      final harness = _harness(
        handle: (request) async {
          if (request.method == 'GET' && request.url.path == '/channels') {
            return _json([_channelJson(id: 'new', name: 'new-channel')]);
          }
          if (request.method == 'GET' && request.url.path == '/categories') {
            return _json(<Object>[]);
          }
          if (request.method == 'GET' && request.url.path == '/dms') {
            return _json(<Object>[]);
          }
          if (request.url.path.endsWith('/read')) {
            return _json({'last_read_seq': 0, 'unread': 0});
          }
          return http.Response('not found', 404);
        },
      );
      addTearDown(harness.container.dispose);
      addTearDown(harness.store.db.close);
      final controller = harness.container.read(
        syncControllerProvider.notifier,
      );

      // A channel the fresh answer above no longer lists, as a revoked view would.
      await harness.store.upsertChannels([
        Channel.fromJson(_channelJson(id: 'revoked', name: 'old-channel')),
      ]);

      await controller.applyServerEventForTest(event);

      expect(
        await harness.store.hasChannel('new'),
        isTrue,
        reason: 'a channel the refresh found must appear',
      );
      expect(
        await harness.store.hasChannel('revoked'),
        isFalse,
        reason:
            'a channel the refresh no longer lists must leave the rail, '
            'not linger until sign-out',
      );
    });
  }

  test('read_state.changed from another device clears the rail badge, and '
      'never moves the marker backwards', () async {
    final harness = _harness(
      handle: (request) async => http.Response('unexpected call', 500),
    );
    addTearDown(harness.container.dispose);
    addTearDown(harness.store.db.close);
    final controller = harness.container.read(syncControllerProvider.notifier);
    await harness.store.upsertChannels([
      Channel.fromJson(_channelJson(id: 'c1', name: 'general')),
    ]);
    await harness.store.applyMessage(
      Message.fromJson({
        'id': 'm3',
        'channel_id': 'c1',
        'author_id': 'bob',
        'author_display_name': 'Bob',
        'seq': 3,
        'content': 'hey',
        'created_at': 1000,
        'edited_at': null,
      }),
    );
    // The same predicate the rail row uses for its unread dot.
    Future<bool> badged() async {
      final row = (await harness.store.allChannels()).single;
      return row.cursor > row.lastReadSeq;
    }

    expect(await badged(), isTrue, reason: 'precondition: unread here');

    await controller.applyServerEventForTest(
      const ReadStateChanged(channelId: 'c1', lastReadSeq: 3),
    );
    expect(await badged(), isFalse);

    await controller.applyServerEventForTest(
      const ReadStateChanged(channelId: 'c1', lastReadSeq: 1),
    );
    expect(
      (await harness.store.allChannels()).single.lastReadSeq,
      3,
      reason: 'a late, lower marker must not un-read the channel',
    );
  });
}
