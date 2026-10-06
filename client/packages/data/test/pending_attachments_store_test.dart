// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The attachment ids a queued send carries, so a retry can send them again.
///
/// A send that fails after its upload succeeded keeps its row but used to lose
/// its files: the retry rebuilt the request from the stored message, which has
/// no attachment ids. Both ends of the lifecycle are asserted here - the ids
/// survive a failed send and a restart, and they do not outlive the send.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

Future<void> _queue(MessageStore store, String id,
        [List<String> ids = const []]) =>
    store.addPending(
      id: id,
      channelId: 'chan-1',
      authorId: 'user-1',
      content: '',
      attachmentIds: ids,
    );

void main() {
  late SlimmDatabase db;
  late MessageStore store;

  setUp(() {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  test('a queued send remembers its ids in the order they were staged',
      () async {
    await _queue(store, 'm1', ['b', 'a']);

    expect(await store.pendingAttachmentIds('m1'), ['b', 'a']);
  });

  test('a send with no attachments has none to remember', () async {
    await _queue(store, 'm1');

    expect(await store.pendingAttachmentIds('m1'), isEmpty);
  });

  test('the ids survive the send failing', () async {
    await _queue(store, 'm1', ['a1']);
    await store.markFailed('m1', reason: 'offline');

    expect(await store.pendingAttachmentIds('m1'), ['a1']);
  });

  test('queueing a retry without ids does not keep a stale list', () async {
    await _queue(store, 'm1', ['a1']);
    await _queue(store, 'm1');

    expect(await store.pendingAttachmentIds('m1'), isEmpty);
  });

  test('discarding the send forgets its ids', () async {
    await _queue(store, 'm1', ['a1']);
    await store.discard('m1');

    expect(await store.pendingAttachmentIds('m1'), isEmpty);
  });

  test('signing out forgets every send\'s ids', () async {
    await _queue(store, 'm1', ['a1']);
    await _queue(store, 'm2', ['a2']);
    await store.clear();

    expect(await store.pendingAttachmentIds('m1'), isEmpty);
    expect(await store.pendingAttachmentIds('m2'), isEmpty);
  });

  group('across a restart', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('slimm-pending-attachments');
      file = File('${dir.path}/slimm.sqlite');
    });

    tearDown(() => dir.delete(recursive: true));

    test('a failed send keeps its ids and a landed one loses them', () async {
      final first = SlimmDatabase(NativeDatabase(file));
      final firstStore = MessageStore(first);
      await _queue(firstStore, 'failed', ['a1']);
      await firstStore.markFailed('failed', reason: 'offline');
      await _queue(firstStore, 'landed', ['a2']);
      await firstStore.applyMessage(
        const api.Message(
          id: 'landed',
          channelId: 'chan-1',
          authorId: 'user-1',
          authorDisplayName: 'User',
          seq: 1,
          content: '',
          createdAt: 1,
          editedAt: null,
        ),
      );
      await first.close();

      final second = SlimmDatabase(NativeDatabase(file));
      addTearDown(second.close);
      final secondStore = MessageStore(second);

      expect(await secondStore.pendingAttachmentIds('failed'), ['a1']);
      expect(await secondStore.pendingAttachmentIds('landed'), isEmpty);
    });
  });
}
