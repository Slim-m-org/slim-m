// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `openThreadPresenting`, the trigger half of UX1: dock the thread beside the
/// transcript where the pane fits, otherwise push the modal `/thread/:id`
/// route. `home_shell_test.dart` proves the shell reacts to
/// `openThreadProvider`; this proves the trigger sets it at a wide-enough width
/// and falls back to the route below one, the branch a future refactor could
/// break without either suite noticing on its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/features/channels/providers/threads.dart';
import 'package:slimm_app/src/features/channels/screens/channel_message_actions.dart';

Future<BuildContext> _pumpAtWidth(
  WidgetTester tester,
  ProviderContainer container,
  double width,
) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  late BuildContext captured;
  final router = GoRouter(
    initialLocation: '/channels/c-general',
    routes: [
      GoRoute(
        path: '/channels/c-general',
        builder: (context, state) {
          captured = context;
          return const Scaffold(body: Text('channel'));
        },
      ),
      GoRoute(
        path: '/thread/:channelId',
        builder: (context, state) => const Scaffold(body: Text('thread route')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  testWidgets(
    'at a width that fits the pane, opening a thread docks it through the '
    'provider rather than pushing the modal route',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final context = await _pumpAtWidth(tester, container, 1400);

      openThreadPresenting(context, container, 'c-thread');
      await tester.pumpAndSettle();

      expect(container.read(openThreadProvider), 'c-thread');
      expect(
        find.text('thread route'),
        findsNothing,
        reason: 'docked beside the transcript, not stacked over it as a route',
      );
    },
  );

  testWidgets(
    'below the width that fits the pane, opening a thread pushes the modal '
    'route and does not dock',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final context = await _pumpAtWidth(tester, container, 500);

      openThreadPresenting(context, container, 'c-thread');
      await tester.pumpAndSettle();

      expect(
        container.read(openThreadProvider),
        isNull,
        reason: 'compact keeps the deep-link modal route, so nothing docks',
      );
      expect(find.text('thread route'), findsOneWidget);
    },
  );
}
