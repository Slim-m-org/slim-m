// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drafts in the local store: the round trip that makes a draft survive a
/// restart, and the wipe that stops one outliving its account.
///
/// This table is the only one here that is not a cache of server state. Nobody
/// else has these words, so the cases worth holding are the two where that
/// matters: they come back after the process is gone, and they do not come back
/// for the next account.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_data/src/database.dart' show ChannelsCompanion;

Future<MessageStore> _store() async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return MessageStore(db);
}

void main() {
  test('a saved draft reads back', () async {
    final store = await _store();

    await store.saveDraft('c1', 'half a thought', now: 10);

    expect(await store.drafts(), {'c1': 'half a thought'});
  });

  test('saving again replaces rather than duplicating', () async {
    final store = await _store();

    await store.saveDraft('c1', 'first', now: 10);
    await store.saveDraft('c1', 'second', now: 20);

    expect(await store.drafts(), {'c1': 'second'});
  });

  test('each channel keeps its own', () async {
    final store = await _store();

    await store.saveDraft('c1', 'one', now: 10);
    await store.saveDraft('c2', 'two', now: 10);

    expect(await store.drafts(), {'c1': 'one', 'c2': 'two'});
  });

  test('saving an empty draft deletes the row rather than storing a blank',
      () async {
    final store = await _store();
    await store.saveDraft('c1', 'something', now: 10);

    await store.saveDraft('c1', '', now: 20);

    expect(
      await store.drafts(),
      isEmpty,
      reason: 'no draft and an empty draft have to read the same way',
    );
    expect(
      await store.db.select(store.db.channelDrafts).get(),
      isEmpty,
      reason: 'and a member who opens every channel empty grows no rows',
    );
  });

  test('clearing one leaves the others', () async {
    final store = await _store();
    await store.saveDraft('c1', 'one', now: 10);
    await store.saveDraft('c2', 'two', now: 10);

    await store.saveDraft('c1', '', now: 20);

    expect(await store.drafts(), {'c2': 'two'});
  });

  test('clearing a channel with no draft is not an error', () async {
    final store = await _store();

    await store.saveDraft('never-typed-in', '', now: 20);

    expect(await store.drafts(), isEmpty);
  });

  /// The whole reason the row is worth writing: it is still there after the
  /// process that wrote it is gone.
  test('drafts outlive the store that wrote them', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await MessageStore(db).saveDraft('c1', 'survives', now: 10);

    // A fresh store over the same database is what a restart looks like here.
    expect(await MessageStore(db).drafts(), {'c1': 'survives'});
  });

  /// And the reason it has to be wiped: nobody else has these words, so leaving
  /// them for the next account hands over something real.
  test('signing out takes the drafts with everything else', () async {
    final store = await _store();
    await store.saveDraft('c1', 'mine', now: 10);
    await store.db.into(store.db.channels).insert(
          ChannelsCompanion.insert(
            id: 'c1',
            name: 'general',
            kind: 'text',
            createdAt: 0,
          ),
        );

    await store.clear();

    expect(await store.drafts(), isEmpty);
    expect(await store.db.select(store.db.channels).get(), isEmpty);
  });

  test('signing out takes the cached categories too', () async {
    final store = await _store();
    await store.replaceCategories([
      const api.ChannelCategory(
          id: 'cat-a', name: 'Alpha', position: 0, createdAt: 1),
    ]);

    await store.clear();

    expect(await store.allCategories(), isEmpty);
  });

  test('removing a channel takes its draft with it', () async {
    final store = await _store();
    await _seedChannels(store, ['c1', 'c2']);
    await store.saveDraft('c1', 'gone', now: 10);
    await store.saveDraft('c2', 'kept', now: 10);

    await store.removeChannel('c1');

    expect(await store.drafts(), {'c2': 'kept'});
  });

  test('a channel pruned by a full refresh takes its draft with it', () async {
    final store = await _store();
    await _seedChannels(store, ['c1', 'c2']);
    await store.saveDraft('c1', 'gone', now: 10);
    await store.saveDraft('c2', 'kept', now: 10);

    await store.replaceChannels([
      const api.Channel(id: 'c2', name: 'c2', kind: 'text', createdAt: 0),
    ]);

    expect(await store.drafts(), {'c2': 'kept'});
  });
}

Future<void> _seedChannels(MessageStore store, List<String> ids) =>
    store.upsertChannels([
      for (final id in ids)
        api.Channel(id: id, name: id, kind: 'text', createdAt: 0),
    ]);
