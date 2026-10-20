// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel created private carries `restricted: true` on both the create
/// response and the live `channel.created` event, and the local store keeps
/// it, so the rail draws the lock without waiting for a reload.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = TokenPair(
  userId: 'alice',
  accessToken: 'access-alice',
  refreshToken: 'refresh-alice',
  accessExpiresAt: 0,
);

Map<String, dynamic> _privateChannel() => {
  'id': 'c-secret',
  'name': 'secret',
  'kind': 'text',
  'topic': null,
  'created_at': 1000,
  'restricted': true,
};

({ProviderContainer container, MessageStore store}) _harness(
  Future<http.Response> Function(http.Request) handle,
) {
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
  addTearDown(container.dispose);
  addTearDown(db.close);
  return (container: container, store: store);
}

void main() {
  test('the create response says the channel is restricted', () async {
    final h = _harness((request) async {
      expect(jsonDecode(request.body), containsPair('restricted', true));
      return http.Response(
        jsonEncode(_privateChannel()),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final created = await h.container
        .read(apiProvider)
        .createChannel(name: 'secret', restricted: true);
    await h.store.upsertChannels([created]);

    expect(created.restricted, isTrue);
    final stored = (await h.store.allChannels()).single;
    expect(stored.restricted, isTrue);
  });

  test('a channel.created frame keeps restricted in the local store', () async {
    final h = _harness(
      (request) async => http.Response('unexpected call', 500),
    );
    final event = ServerEvent.parse(
      jsonEncode({'type': 'channel.created', 'channel': _privateChannel()}),
    );

    expect(event, isA<ChannelCreated>());
    await h.container
        .read(syncControllerProvider.notifier)
        .applyServerEventForTest(event!);

    final stored = (await h.store.allChannels()).single;
    expect(stored.id, 'c-secret');
    expect(stored.restricted, isTrue);
  });
}
