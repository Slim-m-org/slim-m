// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `message.link_previews_removed` frame is a message op: it is stored,
/// and it moves the channel's op cursor so the next op is not read as a gap.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _channelJson({required String id}) => {
  'id': id,
  'name': 'general',
  'kind': 'text',
  'created_at': 0,
  'position': 0,
};

({ProviderContainer container, MessageStore store}) _harness() {
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore()),
      storeProvider.overrideWith((ref) async => store),
      apiProvider.overrideWith((ref) {
        final api = testApi(
          (request) async => http.Response(jsonEncode({}), 200),
          session: SessionStore(tokens: _tokens),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  return (container: container, store: store);
}

void main() {
  late ({ProviderContainer container, MessageStore store}) harness;

  setUp(() async {
    harness = _harness();
    addTearDown(harness.container.dispose);
    addTearDown(harness.store.db.close);
    await harness.store.upsertChannels([
      Channel.fromJson(_channelJson(id: 'c1')),
    ]);
    await harness.store.applyMessage(
      const Message(
        id: 'm1',
        channelId: 'c1',
        authorId: 'user-1',
        authorDisplayName: 'U',
        seq: 1,
        content: 'see https://example.com',
        createdAt: 1,
        editedAt: null,
      ),
    );
    await harness.store.setOpCursor('c1', 4);
  });

  Future<void> deliver(int? opSeq) => harness.container
      .read(syncControllerProvider.notifier)
      .applyServerEventForTest(
        MessageLinkPreviewsRemoved(
          channelId: 'c1',
          messageId: 'm1',
          opSeq: opSeq,
        ),
      );

  Future<bool> removed() async =>
      (await harness.store.watchChannel('c1').first).single.linkPreviewsRemoved;

  test('the next op is stored and advances the cursor', () async {
    await deliver(5);

    expect(await removed(), isTrue);
    expect(await harness.store.opCursorFor('c1'), 5);
  });

  test('a frame from an older server with no op_seq is still stored', () async {
    await deliver(null);

    expect(await removed(), isTrue);
    expect(await harness.store.opCursorFor('c1'), 4);
  });

  test('a gap is not applied and does not move the cursor', () async {
    await deliver(9);

    expect(await removed(), isFalse);
    expect(await harness.store.opCursorFor('c1'), 4);
  });
}
