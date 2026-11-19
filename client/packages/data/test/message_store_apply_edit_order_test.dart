// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An op-stream edit never goes back over a newer one, whichever store on the
/// database wrote the newer one.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

const _message = api.Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'user-1',
  authorDisplayName: 'User One',
  seq: 1,
  content: 'first',
  createdAt: 1000,
  editedAt: null,
);

void main() {
  late SlimmDatabase db;
  late MessageStore store;

  setUp(() async {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 1),
    ]);
    await store.applyMessage(_message);
  });

  tearDown(() => db.close());

  Future<String> content() async =>
      (await store.channelSnapshot('c1')).single.content;

  test('an older edit does not replace a newer one already applied', () async {
    await store.applyEdit('m1', 'newer', 3000);

    await store.applyEdit('m1', 'older', 2000);

    expect(await content(), 'newer');
  });

  test('nor one that another store on this database applied', () async {
    await MessageStore(db).applyEdit('m1', 'newer', 3000);

    await store.applyEdit('m1', 'older', 2000);

    expect(await content(), 'newer');
  });

  test('a newer edit still replaces an older one', () async {
    await store.applyEdit('m1', 'older', 2000);

    await store.applyEdit('m1', 'newer', 3000);

    expect(await content(), 'newer');
  });

  test('an edit with the same stamp is applied again', () async {
    await store.applyEdit('m1', 'one', 2000);

    await store.applyEdit('m1', 'two', 2000);

    expect(await content(), 'two');
  });
}
