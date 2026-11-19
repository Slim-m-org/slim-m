// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Swapping a channel's held rows for a fresh page: what the page no longer
/// lists goes, and what is not the page's to judge stays.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.Message _message(int seq, {String content = 'text'}) => api.Message(
      id: 'm$seq',
      channelId: 'c1',
      authorId: 'user-1',
      authorDisplayName: 'User One',
      seq: seq,
      content: content,
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
  });

  tearDown(() => db.close());

  Future<List<String>> held() async =>
      [for (final m in await store.channelSnapshot('c1')) m.id]..sort();

  test('a row the page no longer lists is dropped', () async {
    await store.applyMessages([_message(1), _message(2), _message(3)]);

    await store.replaceHeld('c1', [_message(1), _message(3)],
        from: 0, through: 3);

    expect(await held(), ['m1', 'm3']);
  });

  test('a row that arrived after the page was read is kept', () async {
    await store.applyMessages([_message(1), _message(2), _message(3)]);

    await store.replaceHeld('c1', [_message(1), _message(2)],
        from: 0, through: 2);

    expect(await held(), ['m1', 'm2', 'm3']);
    expect(await store.cursorFor('c1'), 3);
  });

  test('an unsent message is kept', () async {
    await store.applyMessage(_message(1));
    await store.addPending(
      id: 'draft',
      channelId: 'c1',
      authorId: 'user-1',
      content: 'not sent yet',
    );

    await store.replaceHeld('c1', [_message(1)], from: 0, through: 1);

    expect(await held(), ['draft', 'm1']);
  });

  test('the standing seq falls back when the newest row goes', () async {
    await store.applyMessages([_message(1), _message(2)]);

    await store.replaceHeld('c1', [_message(1)], from: 0, through: 2);

    expect((await store.channelRow('c1'))!.standingSeq, 1);
  });

  test('a row older than the span the page covers is kept', () async {
    await store
        .applyMessages([for (var seq = 1; seq <= 6; seq++) _message(seq)]);

    await store.replaceHeld(
      'c1',
      [_message(4), _message(6)],
      from: 4,
      through: 6,
    );

    expect(await held(), ['m1', 'm2', 'm3', 'm4', 'm6']);
  });

  test('a span of more rows than one statement binds is swapped whole',
      () async {
    final rows = [for (var seq = 1; seq <= 1200; seq++) _message(seq)];
    await store.applyMessages(rows.take(700));

    await store.replaceHeld('c1', rows.skip(1).toList(),
        from: 0, through: 1200);

    expect(await store.channelSnapshot('c1', limit: 2000), hasLength(1199));
    expect(await store.hasMessage('c1', 'm1'), isFalse);
  });

  test(
      'rows below a cursor that another store on this database started are '
      'stored, not read as deleted', () async {
    await store.applyMessage(_message(1000));
    final restarted = MessageStore(db);

    await restarted.replaceHeld(
      'c1',
      [_message(998), _message(999), _message(1000)],
      from: 998,
      through: 1000,
    );

    expect(await held(), ['m1000', 'm998', 'm999']);
  });
}
