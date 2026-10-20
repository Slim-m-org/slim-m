// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Mark as unread is gated on the newest message's age, read through the
/// channel's own cursor: a rail row's cursor lags while a channel stays
/// unread. These drive the real providers against a real store.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_latest_message_at.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

api.Message _message(String channelId, int seq, int createdAt) => api.Message(
  id: '$channelId-m$seq',
  channelId: channelId,
  authorId: 'u',
  authorDisplayName: 'U',
  seq: seq,
  content: 'hi',
  createdAt: createdAt,
  editedAt: null,
);

void main() {
  final now = DateTime(2026, 10, 19, 12);
  int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;

  test('offersMarkUnread holds at the one hour boundary', () {
    expect(offersMarkUnread(null, now), isFalse);
    expect(offersMarkUnread(ago(const Duration(minutes: 59)), now), isTrue);
    expect(offersMarkUnread(ago(const Duration(hours: 1)), now), isFalse);
  });

  group('against a real store', () {
    late SlimmDatabase db;
    late MessageStore store;
    late ProviderContainer container;

    Future<void> settle() => pumpEventQueue(times: 100);

    int? latestAt(String channelId) =>
        container.read(channelLatestMessageAtProvider(channelId)).valueOrNull;

    setUp(() async {
      db = SlimmDatabase(NativeDatabase.memory());
      store = MessageStore(db);
      await store.upsertChannels([
        for (final id in ['c1', 'c2'])
          api.Channel(id: id, name: id, kind: 'text', createdAt: 1),
      ]);
      container = ProviderContainer(
        overrides: [storeProvider.overrideWith((ref) async => store)],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('follows the newest message as it arrives', () async {
      container.listen(channelLatestMessageAtProvider('c1'), (_, _) {});
      await settle();
      expect(latestAt('c1'), isNull, reason: 'a channel with no messages');

      for (var seq = 1; seq <= 3; seq++) {
        await store.applyMessage(_message('c1', seq, seq * 1000));
        await settle();
        expect(latestAt('c1'), seq * 1000);
      }
    });

    test('an unknown channel has no newest message', () async {
      container.listen(channelLatestMessageAtProvider('nope'), (_, _) {});
      await settle();
      expect(latestAt('nope'), isNull);
    });

    test('a stale rail cursor does not hide a recent message', () async {
      container.listen(channelLatestMessageAtProvider('c1'), (_, _) {});
      final railLists = <List<Channel>>[];
      final railSub = store.watchRailChannels().listen(railLists.add);
      addTearDown(railSub.cancel);

      // The first message leaves c1 unread, so the second only moves its cursor.
      await store.applyMessage(
        _message('c1', 1, ago(const Duration(hours: 3))),
      );
      await settle();
      await store.applyMessage(
        _message('c1', 2, ago(const Duration(minutes: 5))),
      );
      await settle();

      final railRow = railLists.last.singleWhere((c) => c.id == 'c1');
      expect(railRow.cursor, 1, reason: 'the rail drops cursor-only changes');
      final staleCursorAt = (await store.messageAtSeq(
        'c1',
        railRow.cursor,
      ))?.createdAt;
      expect(
        offersMarkUnread(staleCursorAt, now),
        isFalse,
        reason: 'the stale cursor points at the old message',
      );
      expect(offersMarkUnread(latestAt('c1'), now), isTrue);
    });

    test('a new message notifies only its own channel', () async {
      final notified = <String, int>{};
      void count(String label) =>
          notified.update(label, (n) => n + 1, ifAbsent: () => 1);
      for (final id in ['c1', 'c2']) {
        await store.applyMessage(_message(id, 1, 1000));
        container.listen(channelNewestSeqProvider(id), (_, _) => count(id));
        container.listen(
          channelLatestMessageAtProvider(id),
          (_, _) => count(id),
        );
      }
      await settle();
      notified.clear();

      await store.applyMessage(_message('c1', 2, 2000));
      await settle();

      expect(notified['c1'], isNotNull);
      expect(notified['c2'], isNull, reason: 'c2 did not move');
      expect(latestAt('c1'), 2000);
      expect(latestAt('c2'), 1000);
    });
  });
}
