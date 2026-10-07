// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a phone, a voice channel's chat swaps in over the call. Back used to
/// leave for the channel list; it now closes the chat and shows the call, and
/// only a second back leaves.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/voice_text_pane.dart';
import 'package:slimm_app/src/widgets/compact_drawer_scaffold.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

Channel _channel(String kind) => Channel(
  id: 'c1',
  name: 'voice',
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

class _Body extends ConsumerWidget {
  const _Body();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Text(ref.watch(voiceChatPaneVisibleProvider) ? 'chat' : 'call');
}

Future<(ProviderContainer, GoRouter)> _pump(
  WidgetTester tester,
  String kind,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore()),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      channelByIdProvider.overrideWith(
        (ref, id) => Stream.value(_channel(kind)),
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: Routes.channel('c1'),
    routes: [
      GoRoute(
        path: Routes.channels,
        builder: (_, _) => const Scaffold(body: Text('channel list')),
      ),
      GoRoute(
        path: '/channels/:id',
        builder: (_, state) => CompactDrawerScaffold(
          channelId: state.pathParameters['id']!,
          body: const _Body(),
          showAppBar: true,
          showRail: false,
          showMembers: false,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  container.read(voiceChatPaneVisibleProvider.notifier).state = true;
  await tester.pump();
  return (container, router);
}

String _location(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

void main() {
  testWidgets('back in a voice channel chat returns to the call, then leaves', (
    tester,
  ) async {
    final (_, router) = await _pump(tester, 'voice');
    expect(find.text('chat'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to call'));
    await tester.pumpAndSettle();
    expect(find.text('call'), findsOneWidget);
    expect(_location(router), Routes.channel('c1'));

    await tester.tap(find.byTooltip('Back to channels'));
    await tester.pumpAndSettle();
    expect(find.text('channel list'), findsOneWidget);
  });

  testWidgets('system back in a voice channel chat also returns to the call', (
    tester,
  ) async {
    final (_, router) = await _pump(tester, 'voice');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('call'), findsOneWidget);
    expect(_location(router), Routes.channel('c1'));
  });

  testWidgets('a text channel still goes straight back to the channel list', (
    tester,
  ) async {
    await _pump(tester, 'text');

    await tester.tap(find.byTooltip('Back to channels'));
    await tester.pumpAndSettle();
    expect(find.text('channel list'), findsOneWidget);
  });
}
