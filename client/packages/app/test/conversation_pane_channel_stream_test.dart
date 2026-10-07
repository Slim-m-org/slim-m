// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The conversation pane resolves its channel through the shared one-row
/// provider, so a rebuild neither reopens a stream nor watches the whole table.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/screens/conversation_pane.dart';
import 'package:slimm_app/src/screens/unlisted_channel.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'home_shell_harness.dart';

class _CountingStore extends MessageStore {
  _CountingStore(super.db);
  int watchChannelsCalls = 0;
  int watchChannelRowCalls = 0;

  @override
  Stream<List<Channel>> watchChannels() {
    watchChannelsCalls++;
    return super.watchChannels();
  }

  @override
  Stream<Channel?> watchChannelRow(String channelId) {
    watchChannelRowCalls++;
    return super.watchChannelRow(channelId);
  }
}

Future<(_CountingStore, Future<void> Function() close)> _pump(
  WidgetTester tester, {
  required String channelId,
}) async {
  late _CountingStore store;
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      initialSyncCompleteProvider.overrideWith((ref) => true),
      storeProvider.overrideWith((ref) async => store),
    ],
  );
  store = _CountingStore(s.db);
  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: s.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: ConversationPane(channelId: channelId)),
      ),
    ),
  );
  await tester.runAsync(() => s.container.read(storeProvider.future));
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();
  return (store, () => teardown(tester, s.container, s.db));
}

void main() {
  testWidgets('a window resize does not reopen the channel query', (
    tester,
  ) async {
    final (store, close) = await _pump(tester, channelId: 'c1');
    final before = store.watchChannelRowCalls;

    tester.view.physicalSize = const Size(1300, 900);
    await tester.pump();
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pump();

    expect(store.watchChannelRowCalls, before);
    expect(
      store.watchChannelsCalls,
      0,
      reason: 'the whole channels table is never watched from this pane',
    );
    await close();
  });

  testWidgets('a channel the store holds is not shown as unlisted', (
    tester,
  ) async {
    final (_, close) = await _pump(tester, channelId: 'c1');

    expect(find.byType(UnlistedChannel), findsNothing);
    await close();
  });

  testWidgets('an id the store lacks, after the first sync, is unlisted', (
    tester,
  ) async {
    final (_, close) = await _pump(tester, channelId: 'missing');

    expect(find.byType(UnlistedChannel), findsOneWidget);
    await close();
  });
}
