// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [runRetentionSweep] is where CD2 (the store) and CS4 (`message_extras`)
/// meet the registry: it caps the store, then treats whatever survives for
/// an open channel as the reachability answer `message_extras.dart`'s own
/// doc says it never had. The one case that matters is the first: a
/// still-open channel's window and its extras must come through a sweep
/// unharmed, or this ships the exact visible bug (reactions vanishing off a
/// message on screen) the file's own doc comment warns against.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/providers/retention_sweep.dart';
import 'package:slimm_data/data.dart';

api.Message _message(
  String channelId,
  int seq, {
  List<api.ReactionSummary> reactions = const [],
}) => api.Message(
  id: '$channelId-m$seq',
  channelId: channelId,
  authorId: 'user-1',
  authorDisplayName: 'User One',
  seq: seq,
  content: 'message $seq',
  createdAt: seq * 1000,
  editedAt: null,
  reactions: reactions,
);

Future<MessageStore> _store(List<String> channelIds) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await store.upsertChannels([
    for (final id in channelIds)
      api.Channel(id: id, name: id, kind: 'text', createdAt: 0),
  ]);
  return store;
}

const _reaction = [
  api.ReactionSummary(emoji: 'thumb', count: 1, reacted: false),
];

void main() {
  test(
    "a still-open channel's newest window and its extras survive the sweep",
    () async {
      final store = await _store(['c1']);
      await store.applyMessages([
        for (var s = 1; s <= 10; s++) _message('c1', s, reactions: _reaction),
      ]);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final extras = container.read(messageExtrasProvider.notifier)
        ..applyMessages([
          for (var s = 1; s <= 10; s++) _message('c1', s, reactions: _reaction),
        ]);

      await runRetentionSweep(store, extras, {'c1'}, ceiling: 4);

      final survivors = await store.reachableMessageIds(['c1']);
      expect(survivors, {'c1-m7', 'c1-m8', 'c1-m9', 'c1-m10'});
      for (final id in survivors) {
        expect(
          container.read(messageExtrasProvider)[id]?.reactions,
          _reaction,
          reason:
              '$id is in the still-open channel window and must keep '
              'its reactions',
        );
      }
    },
  );

  test('a channel with nobody looking is capped to the same ceiling', () async {
    final store = await _store(['closed']);
    await store.applyMessages([
      for (var s = 1; s <= 10; s++) _message('closed', s),
    ]);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final extras = container.read(messageExtrasProvider.notifier);

    await runRetentionSweep(store, extras, const {}, ceiling: 4);

    expect(await store.reachableMessageIds(['closed']), {
      'closed-m7',
      'closed-m8',
      'closed-m9',
      'closed-m10',
    });
  });

  test(
    'extras for a channel nobody has open are dropped, not kept forever',
    () async {
      final store = await _store(['open', 'closed']);
      await store.applyMessages([_message('open', 1), _message('closed', 1)]);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final extras = container.read(messageExtrasProvider.notifier)
        ..applyMessages([
          _message('open', 1, reactions: _reaction),
          _message('closed', 1, reactions: _reaction),
        ]);

      await runRetentionSweep(store, extras, {'open'}, ceiling: 1000);

      final map = container.read(messageExtrasProvider);
      expect(map.containsKey('open-m1'), isTrue);
      expect(map.containsKey('closed-m1'), isFalse);
    },
  );

  test(
    'a message id belonging to no channel at all (already deleted) is dropped',
    () async {
      final store = await _store(['c1']);
      await store.applyMessages([_message('c1', 1)]);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final extras = container.read(messageExtrasProvider.notifier)
        ..applyMessages([_message('c1', 1)]);
      // A reaction on a message deleted server-side before this sweep ran.
      extras.applyLocalReactionToggle('ghost-message', 'thumb', true);

      await runRetentionSweep(store, extras, {'c1'}, ceiling: 1000);

      expect(
        container.read(messageExtrasProvider).containsKey('ghost-message'),
        isFalse,
      );
    },
  );
}
