// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message the server deleted, or a channel it dropped, takes its cached images off disk.
library;

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/providers/media_disk_caches.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_test_support/slimm_test_support.dart' show pollUntil;

import '../../support/memory_byte_cache.dart';

api.Message _message(String id, String channel, String attachment) =>
    api.Message.fromJson({
      'id': id,
      'channel_id': channel,
      'author_id': 'u',
      'author_display_name': 'U',
      'seq': 1,
      'content': 'pic',
      'created_at': 1000,
      'edited_at': null,
      'attachments': [
        {
          'id': attachment,
          'filename': 'a.png',
          'content_type': 'image/png',
          'size': 3,
        },
      ],
    });

void main() {
  late MemoryByteCache previews;
  late MemoryByteCache originals;
  late ProviderContainer container;
  late MessageStore store;
  late Uri server;

  setUp(() async {
    previews = MemoryByteCache();
    originals = MemoryByteCache();
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) async => db),
        attachmentPreviewCacheProvider.overrideWithValue(previews),
        attachmentOriginalCacheProvider.overrideWithValue(originals),
      ],
    );
    addTearDown(container.dispose);
    server = container.read(serverUrlProvider);
    store = await container.read(storeProvider.future);
    await store.upsertChannels(const [
      api.Channel(id: 'c1', name: 'one', kind: 'text', createdAt: 0),
      api.Channel(id: 'c2', name: 'two', kind: 'text', createdAt: 0),
    ]);
    for (final m in [
      _message('m1', 'c1', 'att1'),
      _message('m2', 'c2', 'att2'),
    ]) {
      await store.applyMessage(m);
      container.read(messageExtrasProvider.notifier).applyMessage(m);
    }
    for (final id in ['att1', 'att2']) {
      previews.entries[serverScopedKey(server, '$id-640')] = Uint8List(1);
      originals.entries[serverScopedKey(server, id)] = Uint8List(1);
    }
  });

  Future<void> expectGone(String id) => pollUntil(
    () =>
        !previews.entries.keys.any((k) => k.contains(id)) &&
        !originals.entries.keys.any((k) => k.contains(id)),
    timeout: const Duration(seconds: 3),
    interval: const Duration(milliseconds: 20),
    reason: 'the cached files of $id were still on disk',
  );

  test('a deleted message is not served from disk afterwards', () async {
    await store.discard('m1');

    await expectGone('att1');
    expect(previews.entries.keys.any((k) => k.contains('att2')), isTrue);
  });

  test('a removed channel takes its messages\' images with it', () async {
    await store.removeChannel('c2');

    await expectGone('att2');
    expect(originals.entries.keys.any((k) => k.contains('att1')), isTrue);
  });

  test('a channel pruned by a refresh does too', () async {
    await store.replaceChannels(const [
      api.Channel(id: 'c1', name: 'one', kind: 'text', createdAt: 0),
    ]);

    await expectGone('att2');
  });
}
