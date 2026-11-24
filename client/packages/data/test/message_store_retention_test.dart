// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// CD2: the local store had no retention at all - every delivered row ever
/// synced or paged in stayed for the life of the install. These pin the two
/// rules a sweep leans on: [MessageStore.pruneToRetentionCeiling] never
/// drops more than the oldest-past-the-ceiling delivered rows of any one
/// channel, and never touches a pending or failed send regardless of how
/// old it is; [MessageStore.reachableMessageIds] is a plain read of whatever
/// survived that for the channels asked about.
library;

import 'dart:io';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_data/src/message_store_retention.dart'
    show reclaimFreedPages;

api.Message _message(String channelId, int seq) => api.Message(
      id: '$channelId-m$seq',
      channelId: channelId,
      authorId: 'user-1',
      authorDisplayName: 'User One',
      seq: seq,
      content: 'message $seq',
      createdAt: seq * 1000,
      editedAt: null,
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

/// Every seq currently held for [channelId], including pending/failed rows
/// (`seq` 0), oldest first. Deliberately not capped: a real cap is exactly
/// what these tests are proving [pruneToRetentionCeiling] enforces.
Future<List<int>> _seqsOf(MessageStore store, String channelId) async {
  final rows = await store.watchChannel(channelId, limit: 10000).first;
  return rows.map((r) => r.seq).toList();
}

void main() {
  test('a channel past the ceiling keeps only its newest rows', () async {
    final store = await _store(['c1']);
    await store
        .applyMessages([for (var s = 1; s <= 10; s++) _message('c1', s)]);

    await store.pruneToRetentionCeiling(4);

    expect(await _seqsOf(store, 'c1'), [7, 8, 9, 10]);
  });

  test('a channel at or under the ceiling is left untouched', () async {
    final store = await _store(['c1']);
    await store.applyMessages([for (var s = 1; s <= 3; s++) _message('c1', s)]);

    await store.pruneToRetentionCeiling(5);

    expect(await _seqsOf(store, 'c1'), [1, 2, 3]);
  });

  test('a channel with exactly the ceiling many rows is left untouched',
      () async {
    final store = await _store(['c1']);
    await store.applyMessages([for (var s = 1; s <= 5; s++) _message('c1', s)]);

    await store.pruneToRetentionCeiling(5);

    expect(await _seqsOf(store, 'c1'), [1, 2, 3, 4, 5]);
  });

  test('a pending or failed send never gets pruned, no matter how old',
      () async {
    final store = await _store(['c1']);
    await store
        .applyMessages([for (var s = 1; s <= 10; s++) _message('c1', s)]);
    await store.addPending(
      id: 'queued',
      channelId: 'c1',
      authorId: 'user-1',
      content: 'not sent yet',
    );
    await store.addPending(
      id: 'doomed',
      channelId: 'c1',
      authorId: 'user-1',
      content: 'will fail',
    );
    await store.markFailed('doomed', reason: 'offline');

    await store.pruneToRetentionCeiling(4);

    final ids = (await store.watchChannel('c1', limit: 10000).first)
        .map((r) => r.id)
        .toSet();
    expect(ids.containsAll(['queued', 'doomed']), isTrue);
    // Newest 4 delivered, then the two pending/failed rows (`seq` 0) last.
    expect(await _seqsOf(store, 'c1'), [7, 8, 9, 10, 0, 0]);
  });

  test('each channel is capped independently of the others', () async {
    final store = await _store(['c1', 'c2']);
    await store
        .applyMessages([for (var s = 1; s <= 10; s++) _message('c1', s)]);
    await store.applyMessages([for (var s = 1; s <= 2; s++) _message('c2', s)]);

    await store.pruneToRetentionCeiling(3);

    expect(await _seqsOf(store, 'c1'), [8, 9, 10]);
    expect(await _seqsOf(store, 'c2'), [1, 2]);
  });

  test('reachableMessageIds reads whatever pruning already left', () async {
    final store = await _store(['c1', 'c2']);
    await store
        .applyMessages([for (var s = 1; s <= 10; s++) _message('c1', s)]);
    await store.applyMessages([for (var s = 1; s <= 2; s++) _message('c2', s)]);
    await store.pruneToRetentionCeiling(3);

    final reachable = await store.reachableMessageIds(['c1']);

    expect(reachable, {'c1-m8', 'c1-m9', 'c1-m10'});
  });

  test('reachableMessageIds ignores channels not asked about', () async {
    final store = await _store(['c1', 'c2']);
    await store.applyMessages([_message('c1', 1), _message('c2', 1)]);

    expect(await store.reachableMessageIds(['c1']), {'c1-m1'});
    expect(await store.reachableMessageIds([]), isEmpty);
  });

  test('a large prune returns the freed pages to disk, not just the free list',
      () async {
    final dir = await Directory.systemTemp.createTemp('slimm-vacuum-test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/store.sqlite');
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'c1', kind: 'text', createdAt: 0),
    ]);

    // ~4 MiB of history, well past the vacuum's ~2 MiB floor once pruned.
    final big = 'x' * 2048;
    await store.applyMessages([
      for (var s = 1; s <= 2000; s++)
        api.Message(
          id: 'c1-m$s',
          channelId: 'c1',
          authorId: 'user-1',
          authorDisplayName: 'User One',
          seq: s,
          content: big,
          createdAt: s * 1000,
          editedAt: null,
        ),
    ]);
    final before = await file.length();

    await store.pruneToRetentionCeiling(50);
    final after = await file.length();

    expect(await _seqsOf(store, 'c1'), hasLength(50));
    expect(
      after,
      lessThan(before),
      reason: 'the vacuum should hand the pruned pages back to the OS',
    );
  });

  test('the vacuum builds its copy on disk and puts the setting back',
      () async {
    final dir = await Directory.systemTemp.createTemp('slimm-vacuum-pragma');
    addTearDown(() => dir.delete(recursive: true));
    final statements = <String>[];
    final db = SlimmDatabase(
      NativeDatabase(File('${dir.path}/s.sqlite'))
          .interceptWith(_Recorder(statements)),
    );
    addTearDown(db.close);
    await db.customStatement('PRAGMA temp_store = MEMORY');
    await db.customStatement('CREATE TABLE junk (a TEXT)');
    for (var i = 0; i < 600; i++) {
      await db.customStatement('INSERT INTO junk VALUES (?)', ['x' * 4000]);
    }
    await db.customStatement('DROP TABLE junk');

    await reclaimFreedPages(db);

    final order = statements
        .where((s) => s == 'VACUUM' || s.startsWith('PRAGMA temp_store ='))
        .skip(1)
        .toList();
    expect(order, [
      'PRAGMA temp_store = FILE',
      'VACUUM',
      'PRAGMA temp_store = 2',
    ]);
  });
}

class _Recorder extends QueryInterceptor {
  _Recorder(this.log);
  final List<String> log;

  @override
  Future<void> runCustom(
      QueryExecutor e, String statement, List<Object?> args) {
    log.add(statement);
    return e.runCustom(statement, args);
  }
}
