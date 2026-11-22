// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Dock panel in the real shell at 1280 (decision 0131): it docks in the
/// third pane beside the chat, keeps its scene across a channel switch and a
/// close and reopen, and a failing module shows the error state, not a blank.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/threads.dart';
import 'package:slimm_app/src/features/modules/providers/module_panels.dart';
import 'package:slimm_app/src/features/modules/widgets/module_panel_slot.dart';
import 'package:slimm_app/src/routing/breakpoints.dart';
import 'package:slimm_data/data.dart';

import '../settings/home_shell_harness.dart';
import 'module_panel_fixture.dart';

typedef _Shell = ({ProviderContainer container, Future<void> Function() done});

Future<_Shell> _shell(WidgetTester tester, BoardServer server) async {
  final s = setup(httpClient: server.client(), signedIn: true);
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    const api.Channel(id: 'c2', name: 'random', kind: 'text', createdAt: 0),
  ]);
  await pumpAtWidth(tester, s.container, 1280, location: '/channels/c1');
  s.container.read(openModulePanelProvider.notifier).state = boardPanel;
  await _settle(tester);
  return (
    container: s.container,
    done: () => teardown(tester, s.container, s.db),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

Future<void> _go(WidgetTester tester, String location) async {
  GoRouter.of(tester.element(find.text('Board'))).go(location);
  await _settle(tester);
}

void main() {
  testWidgets(
    'at 1280 the panel docks beside the chat, in place of the roster',
    (tester) async {
      final s = await _shell(tester, BoardServer());
      final pane = tester.getRect(find.byKey(ModulePanelSlot.paneKey));
      expect(pane.right, 1280);
      expect(pane.width, kThreadPaneWidth);
      expect(find.text('Count 0'), findsOneWidget);
      expect(find.textContaining('MEMBERS'), findsNothing);
      await s.done();
    },
  );

  testWidgets('the scene survives a channel switch and a close and reopen', (
    tester,
  ) async {
    final server = BoardServer();
    final s = await _shell(tester, server);
    await tester.tap(find.bySemanticsLabel('Step forward'));
    await _settle(tester);
    expect(find.text('Count 1'), findsOneWidget);

    await _go(tester, '/channels/c2');
    expect(find.text('Count 1'), findsOneWidget);
    await _go(tester, '/channels/c1');
    expect(find.text('Count 1'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Close Board'));
    await _settle(tester);
    expect(find.byKey(ModulePanelSlot.paneKey), findsNothing);
    expect(find.textContaining('MEMBERS'), findsOneWidget);
    s.container.read(openModulePanelProvider.notifier).state = boardPanel;
    await _settle(tester);
    expect(find.text('Count 1'), findsOneWidget);
    expect(server.firstRuns, 1, reason: 'the first frame is fetched once');
    await s.done();
  });

  testWidgets('a docked thread takes the slot and gives it back', (
    tester,
  ) async {
    final s = await _shell(tester, BoardServer());
    s.container.read(dockedThreadsProvider.notifier).state = {'c1': 't1'};
    await _settle(tester);
    expect(find.byKey(ModulePanelSlot.paneKey), findsNothing);

    closeDockedThread(s.container.read(dockedThreadsProvider.notifier), 'c1');
    await _settle(tester);
    expect(find.text('Count 0'), findsOneWidget);
    await s.done();
  });

  testWidgets('a module that fails shows the error state with a retry', (
    tester,
  ) async {
    final server = BoardServer(fails: true);
    final s = await _shell(tester, server);
    expect(find.text('module timed out'), findsOneWidget);

    server.fails = false;
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(find.text('Count 0'), findsOneWidget);
    await s.done();
  });
}
