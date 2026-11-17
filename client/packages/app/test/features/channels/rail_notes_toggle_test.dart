// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's Notes button is a toggle: a second press goes back to wherever
/// the first one left from.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_notes_button.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/async_wait.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _notes = Channel(
  id: 'dm-self',
  name: personalSpaceName,
  kind: dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: true,
);

ProviderContainer _container() => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    liveEventsProvider.overrideWithValue(const Stream.empty()),
    databaseProvider.overrideWith((ref) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      ref.onDispose(db.close);
      await db.into(db.channels).insert(_notes);
      return db;
    }),
  ],
);

GoRouter _router(String initialLocation) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(
      path: '/channels',
      builder: (context, state) => const _Page(activeChannelId: null),
    ),
    GoRoute(
      path: '/channels/:channelId',
      builder: (context, state) =>
          _Page(activeChannelId: state.pathParameters['channelId']),
      routes: [
        GoRoute(
          path: 'm/:messageId',
          builder: (context, state) =>
              _Page(activeChannelId: state.pathParameters['channelId']),
        ),
      ],
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const _Page(activeChannelId: null),
    ),
  ],
);

class _Page extends StatelessWidget {
  const _Page({required this.activeChannelId});

  final String? activeChannelId;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(child: RailNotesButton(activeChannelId: activeChannelId)),
  );
}

String _location(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

Future<void> _press(WidgetTester tester, GoRouter router, String to) async {
  await tester.tap(find.bySemanticsLabel('Notes'));
  await waitUntil(
    tester,
    () => _location(router) == to,
    timeout: const Duration(seconds: 5),
    reason: 'the Notes button never landed on $to, at ${_location(router)}',
  );
}

Future<void> _withRouter(
  WidgetTester tester,
  String start,
  Future<void> Function(GoRouter router) body,
) async {
  final container = _container();
  final router = _router(start);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await pumpFrames(tester);

  await body(router);

  await tester.pumpWidget(const SizedBox());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> _goTo(WidgetTester tester, GoRouter router, String to) async {
  router.go(to);
  await waitUntil(tester, () => _location(router) == to, reason: 'go $to');
}

Future<void> _toggleFrom(WidgetTester tester, String start) =>
    _withRouter(tester, start, (router) async {
      await _press(tester, router, '/channels/dm-self');
      await _press(tester, router, start);
    });

void main() {
  testWidgets('a second press from a channel goes back to that channel', (
    tester,
  ) async {
    await _toggleFrom(tester, '/channels/general');
  });

  testWidgets('a second press from settings goes back to that settings pane', (
    tester,
  ) async {
    await _toggleFrom(tester, '/settings?pane=profile');
  });

  testWidgets('a press on a Notes message link leaves Notes for where it was '
      'opened from', (tester) async {
    await _withRouter(tester, '/channels/general', (router) async {
      await _press(tester, router, '/channels/dm-self');
      await _goTo(tester, router, '/channels/dm-self/m/msg-1');
      await _press(tester, router, '/channels/general');
    });
  });

  testWidgets('a press on a Notes message link reached directly goes to '
      'the channels home', (tester) async {
    await _withRouter(tester, '/channels/dm-self/m/msg-1', (router) async {
      await _press(tester, router, '/channels');
    });
  });

  testWidgets('leaving Notes another way forgets where it was opened from', (
    tester,
  ) async {
    await _withRouter(tester, '/channels/general', (router) async {
      await _press(tester, router, '/channels/dm-self');
      await _goTo(tester, router, '/channels/random');
      await _goTo(tester, router, '/channels/dm-self');
      await _press(tester, router, '/channels');
    });
  });
}
