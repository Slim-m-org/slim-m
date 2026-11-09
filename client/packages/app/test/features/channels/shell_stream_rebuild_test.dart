// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The wide shell, its member pane slot and the rail hold their drift streams
/// across rebuilds: a message in another channel rebuilds none of them, and a
/// rebuild of the rail builds its list once rather than once more when drift
/// replays a snapshot into a resubscribed stream.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_participant_drag.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/screens/home_shell_pane_slots.dart';
import 'package:slimm_data/data.dart';

import '../settings/home_shell_harness.dart';

api.Message _message(String channelId, int seq) => api.Message(
  id: '$channelId-m$seq',
  channelId: channelId,
  authorId: 'u',
  authorDisplayName: 'U',
  seq: seq,
  content: 'hi',
  createdAt: seq * 1000,
  editedAt: null,
);

void main() {
  late List<String> rebuilt;

  setUp(() => rebuilt = []);
  tearDown(() => debugOnRebuildDirtyWidget = null);

  // Drift answers in real time and riverpod resolves on the fake clock, so each needs its turn.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
  }

  testWidgets('a message in another channel rebuilds no shell widget', (
    tester,
  ) async {
    final s = setup(httpClient: quietClient(), signedIn: true);
    final store = MessageStore(s.db);
    await tester.runAsync(() async {
      await store.upsertChannels(const [
        api.Channel(id: 'c1', name: 'one', kind: 'text', createdAt: 0),
        api.Channel(id: 'c2', name: 'two', kind: 'text', createdAt: 1),
      ]);
      // Already unread, so the next message flips nothing the rail draws.
      await store.applyMessage(_message('c2', 1));
    });
    await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');
    await settle(tester);

    debugOnRebuildDirtyWidget = (element, _) {
      final widget = element.widget;
      if (widget is HomeShell) rebuilt.add('shell');
      if (widget is ChannelRail) rebuilt.add('rail');
      if (widget is MemberPaneSlot) rebuilt.add('member pane slot');
    };
    await tester.runAsync(() => store.applyMessage(_message('c2', 2)));
    await settle(tester);

    expect(rebuilt, isEmpty);

    debugOnRebuildDirtyWidget = null;
    await teardown(tester, s.container, s.db);
  });

  testWidgets('rebuilding the rail builds its channel list once', (
    tester,
  ) async {
    final s = setup(httpClient: quietClient(), signedIn: true);
    await tester.runAsync(
      () => MessageStore(s.db).upsertChannels(const [
        api.Channel(id: 'c1', name: 'one', kind: 'text', createdAt: 0),
      ]),
    );
    await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');
    await settle(tester);

    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is StreamBuilder<List<Channel>>) {
        rebuilt.add('channel list');
      }
    };
    s.container.read(railMoveFailureProvider.notifier).state = 'Could not move';
    await settle(tester);

    expect(rebuilt, ['channel list']);

    debugOnRebuildDirtyWidget = null;
    await teardown(tester, s.container, s.db);
  });
}
