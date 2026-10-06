// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for the suites that pump a real [HomeShell]: its
/// width-driven layout (`home_shell_test.dart`) and the canvas pane's swap
/// within it (`home_shell_canvas_test.dart`). Split out when the second of
/// those crossed this repo's 500-line hard file limit.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
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
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

/// Plays nothing: `HomeShell` watches the real controller, which builds a
/// real `AudioPlayer` reaching a platform channel with no host under
/// `tester.runAsync` - the same trap `ui_snapshot_support.dart`'s own
/// `_SilentPlayer` exists for. Ordinary pump-only tests never notice, since
/// nothing drives the channel outside real asynchrony.
class _SilentSoundPlayer implements SoundPlayer {
  @override
  Future<void> play(NotificationSound sound) async {}

  @override
  Future<void> loop(NotificationSound sound) async {}

  @override
  Future<void> stopLoop() async {}

  @override
  Future<void> dispose() async {}
}

/// Stands in for the real [SyncController], which opens a websocket to a
/// server that does not exist here. `start` is called from the base
/// constructor, but Dart dispatches virtually even there, so overriding it as
/// a no-op keeps the real one from ever touching the network.
class NoopSyncController extends SyncController {
  NoopSyncController(super.ref);

  @override
  Future<void> start() async {}
}

/// The compact tests render a real conversation, which fetches its members,
/// its pins and a window of messages on the way up. None of the three is what
/// those tests are about, so they all answer empty rather than failing: an
/// error state would still prove reachability, but it would also hide a
/// widget that only builds on success.
MockClient quietClient() => MockClient((request) async {
  final path = request.url.path;
  final Object body = switch (path) {
    '/me' => {
      'id': 'bob',
      'username': 'bob',
      'display_name': 'Bob',
      'created_at': 0,
      'permissions': 0,
    },
    // The canvas viewport, ops feed, media slots and voice roster each decode a shape; a plain list fails those casts.
    _ when path.endsWith('/canvas/objects') => const {
      'objects': <Object>[],
      'has_more': false,
      'latest_seq': 0,
    },
    _ when path.endsWith('/canvas/ops') => {
      'ops': <Object>[],
      'latest_seq': int.parse(request.url.queryParameters['after_seq'] ?? '0'),
      'has_more': false,
      'reset': false,
    },
    _ when path.endsWith('/canvas/media-slots') => const {'slots': <Object>[]},
    _ when path.endsWith('/voice/roster') => const {'participants': <Object>[]},
    // An id that is not a thread the caller can see answers all-null, the server's masked shape.
    _ when path.endsWith('/thread-parent') => const <String, Object>{
      'parent_deleted': false,
    },
    _ => const <Object>[],
  };
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
});

const tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A container wired like the app's, with the network swapped for the given
/// client (by default an always-failing one: every provider that reads it
/// already degrades to an honest loading/error state rather than crashing)
/// and the database swapped for an in-memory one this test closes itself, on
/// the same clock the test binding uses; see [teardown] for why that matters.
///
/// [extraOverrides] append after the fixed list above, so a caller needing
/// something like `voiceControllerProvider` pinned to a particular state can
/// add it without rebuilding this whole wiring by hand.
({ProviderContainer container, SlimmDatabase db}) setup({
  MockClient? httpClient,
  bool signedIn = false,
  List<Override> extraOverrides = const [],
}) {
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      // Every authenticated call refuses before it reaches the transport otherwise, which would leave the pin count reading "loading" forever.
      if (signedIn)
        sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      notificationSoundControllerProvider.overrideWith(
        (ref) => NotificationSoundController(ref, player: _SilentSoundPlayer()),
      ),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient:
              httpClient ??
              MockClient(
                (_) async => throw StateError('no network in this test'),
              ),
        );
        ref.onDispose(client.close);
        return client;
      }),
      databaseProvider.overrideWith((ref) => db),
      ...extraOverrides,
    ],
  );
  return (container: container, db: db);
}

/// Drift keeps a query stream's cache alive briefly after its last listener
/// unsubscribes, using a timer it documents itself as the reason "Flutter
/// throws an exception when timers remain after a test run". Unmounting
/// first (so the rail's `StreamBuilder`s actually unsubscribe) and pumping
/// past that timer before disposing is what keeps this test from either
/// tripping that assertion or hanging forever waiting on a timer the fake
/// test clock never advances on its own.
Future<void> teardown(
  WidgetTester tester,
  ProviderContainer container,
  SlimmDatabase db,
) async {
  await tester.pumpWidget(const SizedBox());
  // Dispose before the pump: widgets reading a channel through the autoDispose channelByIdProvider defer cancelling their drift subscription to disposal, so the pump must land after it to advance drift's cleanup timer.
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
  await db.close();
}

/// Bypasses the real app router (which redirects a signed-out session to
/// onboarding, which is not what this test is about) with a router that
/// unconditionally shows [HomeShell], nesting the conversation route under
/// the shell exactly as `router.dart` does.
GoRouter testRouter(String location) => GoRouter(
  initialLocation: location,
  routes: [
    ShellRoute(
      builder: (context, state, child) => HomeShell(child: child),
      routes: [
        GoRoute(
          path: '/channels',
          builder: (context, state) =>
              const Center(child: Text('conversation')),
          routes: [
            GoRoute(
              path: ':channelId',
              builder: (context, state) => ConversationPane(
                channelId: state.pathParameters['channelId']!,
                openChat: Routes.opensChat(state.uri),
              ),
            ),
          ],
        ),
      ],
    ),
    // A stand-in for the thread screen: tests only need to see that it was reached.
    GoRoute(
      path: Routes.threadPattern,
      builder: (context, state) =>
          Text('thread ${state.pathParameters['channelId']}'),
    ),
  ],
);

/// [reduceMotion] wraps the app in a [MediaQuery] with
/// `disableAnimations: true`, driving the real shell the way a viewer who
/// has asked for less motion actually sees it, rather than a pane pumped in
/// isolation.
Future<void> pumpAtWidth(
  WidgetTester tester,
  ProviderContainer container,
  double width, {
  String location = '/channels',
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final app = MaterialApp.router(
    theme: buildTheme(Brightness.light, AppTokens.light),
    routerConfig: testRouter(location),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: reduceMotion
          ? MediaQuery(
              data: MediaQueryData.fromView(
                tester.view,
              ).copyWith(disableAnimations: true),
              child: app,
            )
          : app,
    ),
  );
  await tester.pumpAndSettle();
}
