// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pin made while the socket was down arrives as a frame nobody replays, so
/// an open channel's pins are asked for again once the socket is live.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/channels/providers/mounted_channels.dart';
import 'package:slimm_app/src/features/channels/providers/pins_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';

import '../support/quick_reconnect.dart';
import '../support/sync_harness.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _pin(String id) => {
  'id': id,
  'channel_id': 'c1',
  'author_id': 'alice',
  'author_display_name': 'Alice',
  'seq': 1,
  'content': 'pinned $id',
  'created_at': 0,
  'edited_at': null,
  'pinned_at': 0,
  'pinned_by': 'alice',
};

Future<void> _untilLive(ProviderContainer container, {bool live = true}) async {
  for (var i = 0; i < 200; i++) {
    if ((container.read(syncControllerProvider) == SyncStatus.live) == live) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('a reconnect rereads the pins of a channel that stayed open', (
    tester,
  ) async {
    var pins = <Map<String, Object?>>[];
    final db = SlimmDatabase(NativeDatabase.memory());
    final store = MessageStore(db);
    final server = (await tester.runAsync(SyncTestServer.start))!;
    await tester.pump();
    final router = RestRouter()
      ..on('GET', '/channels/c1/pins', (_) => jsonResponse(pins))
      ..on('POST', '/sync', (_) => jsonResponse({'scopes': <dynamic>[]}))
      ..on(
        'POST',
        '/auth/ws-ticket',
        (_) => jsonResponse({'ticket': 'tix', 'expires_at': 0}),
      );
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore()),
        storeProvider.overrideWith((ref) async => store),
        quickReconnect,
        apiProvider.overrideWith((ref) {
          final client = SlimmApi(
            baseUrl: server.baseUrl,
            session: ref.watch(sessionProvider),
            httpClient: router.build(),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    await tester.pumpWidget(const SizedBox.shrink());

    await tester.runAsync(() async {
      container.read(syncControllerProvider.notifier);
      container.read(sessionProvider).set(_tokens);
      await _untilLive(container);
      container.read(mountedChannelsProvider).register('c1');
      container.listen(pinsControllerProvider('c1'), (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(container.read(pinsControllerProvider('c1')).pinned, isEmpty);

    pins = [_pin('m1')];
    await tester.runAsync(() async {
      await server.dropSockets();
      await _untilLive(container, live: false);
      await _untilLive(container);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    expect(container.read(pinsControllerProvider('c1')).pinned, hasLength(1));

    container.dispose();
    await tester.pump();
    await tester.runAsync(server.close);
    await db.close();
  });
}
