// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The beta report: a thread docked beside #beta-lounge stayed open, still
/// titled for that channel, after moving to another one. A docked thread
/// belongs to the channel it was opened beside, and each channel remembers its own.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/threads.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/messages/screens/thread_screen.dart';
import 'package:slimm_data/data.dart';

import '../../support/async_wait.dart';
import '../settings/home_shell_harness.dart';

final _threadPane = find.byWidgetPredicate((w) => w is ThreadScreen);

Future<void> _go(WidgetTester tester, String location) async {
  GoRouter.of(
    tester.element(find.byWidgetPredicate((w) => w is ChannelRail)),
  ).go(location);
  await pumpFrames(tester, frames: 40);
}

void main() {
  testWidgets('a docked thread stays with its channel', (tester) async {
    final s = setup(httpClient: quietClient(), signedIn: true);
    await MessageStore(s.db).upsertChannels([
      const api.Channel(
        id: 'c1',
        name: 'beta-lounge',
        kind: 'text',
        createdAt: 0,
      ),
      const api.Channel(id: 'c2', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');

    dockThread(s.container, 'c-thread', besideChannelId: 'c1');
    await pumpFrames(tester, frames: 40);
    expect(_threadPane, findsOneWidget);

    await _go(tester, '/channels/c2');
    expect(
      _threadPane,
      findsNothing,
      reason: 'it was docked beside #beta-lounge',
    );

    await _go(tester, '/channels/c1');
    expect(_threadPane, findsOneWidget, reason: 'back beside its own channel');

    await teardown(tester, s.container, s.db);
  });

  testWidgets('each channel remembers its own docked thread', (tester) async {
    final s = setup(httpClient: quietClient(), signedIn: true);
    await MessageStore(s.db).upsertChannels([
      const api.Channel(id: 'c1', name: 'one', kind: 'text', createdAt: 0),
      const api.Channel(id: 'c2', name: 'two', kind: 'text', createdAt: 0),
    ]);
    await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');
    String shown() => tester.widget<ThreadScreen>(_threadPane).channelId;

    dockThread(s.container, 'thread-a', besideChannelId: 'c1');
    await pumpFrames(tester, frames: 40);
    await _go(tester, '/channels/c2');
    dockThread(s.container, 'thread-b', besideChannelId: 'c2');
    await pumpFrames(tester, frames: 40);
    expect(shown(), 'thread-b');

    await _go(tester, '/channels/c1');
    expect(shown(), 'thread-a', reason: 'docking beside two replaced one');

    await _go(tester, '/channels/c2');
    expect(shown(), 'thread-b');

    await teardown(tester, s.container, s.db);
  });
}
