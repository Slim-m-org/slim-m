// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The wiring [MountedChannels] actually depends on: a mounted [ChannelScreen]
/// must register its channel id, and a torn-down one must give it back up -
/// the pure registry tests in `mounted_channels_test.dart` cannot see this
/// half, since nothing there ever builds a real screen.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/mounted_channels.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'channel_history_harness.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _emptyList() => http.Response(
  jsonEncode(const <Object>[]),
  200,
  headers: {'content-type': 'application/json'},
);

/// Unmounting deliberately, with a few more pumps, rather than leaving it to
/// flutter_test's teardown; see `channel_screen_test.dart` for why drift's
/// deferred stream cleanup needs this.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets('a mounted channel screen registers its channel as open', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: [1],
      seededSeqs: [1],
    );

    expect(harness.container.read(mountedChannelsProvider).openChannelIds, {
      'c1',
    });

    await _unmount(tester);
  });

  testWidgets('tearing the screen down closes the channel again', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: [1],
      seededSeqs: [1],
    );

    await _unmount(tester);

    expect(
      harness.container.read(mountedChannelsProvider).openChannelIds,
      isEmpty,
    );
  });

  testWidgets(
    'switching channels in place unregisters the old one and registers the new',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = SlimmDatabase(NativeDatabase.memory());
      final store = MessageStore(db);
      await store.upsertChannels([
        const api.Channel(id: 'c1', name: 'first', kind: 'text', createdAt: 0),
        const api.Channel(id: 'c2', name: 'second', kind: 'text', createdAt: 1),
      ]);
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          storeProvider.overrideWith((ref) async => store),
          syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
          apiProvider.overrideWith((ref) {
            final client = api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async => _emptyList()),
            );
            ref.onDispose(client.close);
            return client;
          }),
        ],
      );
      addTearDown(container.dispose);

      // A ValueNotifier reuses the State so didUpdateWidget fires, matching `channel_screen_rehydrate_test.dart`.
      final channelId = ValueNotifier<String>('c1');
      addTearDown(channelId.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: ValueListenableBuilder<String>(
                valueListenable: channelId,
                builder: (context, id, _) => ChannelScreen(channelId: id),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(container.read(mountedChannelsProvider).openChannelIds, {'c1'});

      channelId.value = 'c2';
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(
        container.read(mountedChannelsProvider).openChannelIds,
        {'c2'},
        reason:
            'c1 must be unregistered on the switch, not left open '
            'alongside c2',
      );

      await _unmount(tester);
      await db.close();
    },
  );
}
