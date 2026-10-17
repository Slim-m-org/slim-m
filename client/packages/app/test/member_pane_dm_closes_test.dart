// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A DM opened from the compact member pane left the pane floating over the
/// new channel.
///
/// The pane lives in `Scaffold.endDrawer` on a phone, and the drawer's open
/// state lives on `ScaffoldState`, not on the routed page. `HomeShell` is a
/// `ShellRoute` builder, so its `Scaffold` is reused rather than rebuilt
/// across a `go_router` navigation - only its `body` (the routed child)
/// changes. This is why the fixture below has to reproduce a `ShellRoute`
/// with a real `endDrawer` rather than swapping a plain per-route `Scaffold`,
/// which would never have shown the bug.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';

import 'support/reduced_motion_harness.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _other = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'Maya',
  createdAt: 0,
);

const _me = api.UserProfile(
  id: 'me',
  username: 'me',
  displayName: 'Me',
  createdAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

ProviderContainer _wire({List<api.UserProfile> members = const [_other]}) {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      databaseProvider.overrideWith((ref) async => db),
      membersProvider.overrideWith((ref) async => members),
      channelMembersProvider.overrideWith((ref, _) async => members),
      // Keeps the pane's keep-alive watchers from starting a real sync loop.
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path == '/me') {
              return _json({
                'id': 'me',
                'username': 'me',
                'display_name': 'Me',
                'created_at': 0,
                'permissions': 0,
              });
            }
            if (request.url.path == '/presence') return _json(const []);
            if (request.url.path == '/dms/${_other.id}') {
              return _json({
                'channel_id': 'dm-1',
                'user': {
                  'id': _other.id,
                  'username': _other.username,
                  'display_name': _other.displayName,
                  'created_at': 0,
                },
                'unread': 0,
                'created_at': 500,
              });
            }
            return http.Response('', 204);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Mirrors `HomeShell`'s compact branch: one `Scaffold` carrying the
/// `endDrawer`, wrapping whichever child the shell route below it is
/// currently showing.
Widget _shell(BuildContext context, GoRouterState state, Widget child) =>
    Scaffold(
      endDrawer: const Drawer(
        width: AppMemberPane.width,
        child: SafeArea(child: AppMemberPane(channelId: 'c1')),
      ),
      body: child,
    );

GoRouter _testRouter() => GoRouter(
  initialLocation: Routes.channels,
  routes: [
    ShellRoute(
      builder: _shell,
      routes: [
        GoRoute(
          path: Routes.channels,
          builder: (context, state) => const Center(child: Text('no channel')),
        ),
        GoRoute(
          path: Routes.channelPattern,
          builder: (context, state) =>
              const Center(child: Text('conversation')),
        ),
      ],
    ),
    GoRoute(
      path: Routes.personalSettings,
      builder: (context, state) => const Scaffold(body: Text('settings')),
    ),
  ],
);

/// Opens the compact roster and returns its [ScaffoldState], captured once
/// so a caller can still ask [ScaffoldState.isEndDrawerOpen] after
/// navigating away, when the drawer's own widget may be offstage rather
/// than gone (a route pushed on the root navigator keeps what it covers
/// mounted) and so cannot be told apart from "really closed" by presence
/// alone.
Future<ScaffoldState> _openDrawer(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    reducedMotionRouterApp(
      container: container,
      router: _testRouter(),
      size: const Size(390, 844),
    ),
  );
  await tester.pumpAndSettle();

  final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold));
  scaffold.openEndDrawer();
  await tester.pumpAndSettle();
  expect(
    find.byType(AppMemberPane),
    findsOneWidget,
    reason: 'the drawer must really be open, or this passes vacuously',
  );
  return scaffold;
}

void main() {
  testWidgets(
    'opening a DM from a member row closes the member pane along with it',
    (tester) async {
      final scaffold = await _openDrawer(tester, _wire());

      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();
      expect(find.text('Message'), findsOneWidget);

      await tester.tap(find.text('Message'));
      await tester.pumpAndSettle();

      expect(
        find.text('conversation'),
        findsOneWidget,
        reason: 'the DM navigation itself must have gone through',
      );
      expect(
        scaffold.isEndDrawerOpen,
        isFalse,
        reason:
            'the member pane must close along with the navigation, not '
            'float over the channel it opened',
      );
    },
  );

  testWidgets(
    'opening profile settings from your own row closes the member pane too',
    (tester) async {
      final scaffold = await _openDrawer(
        tester,
        _wire(members: const [_me, _other]),
      );

      await tester.tap(find.text('Me'));
      await tester.pumpAndSettle();
      expect(find.text('Profile settings'), findsOneWidget);

      await tester.tap(find.text('Profile settings'));
      await tester.pumpAndSettle();

      expect(
        find.text('settings'),
        findsOneWidget,
        reason: 'the settings navigation itself must have gone through',
      );
      expect(
        scaffold.isEndDrawerOpen,
        isFalse,
        reason:
            'this is the sibling of the Message bug: any navigation out of '
            'the member pane must close it, not just opening a DM',
      );
    },
  );
}
