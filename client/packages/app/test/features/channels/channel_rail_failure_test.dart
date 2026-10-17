// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's failure state: its size, and whether its copy is honest about
/// what actually failed.
///
/// From the owner's own iOS screenshot, 2026-09-30: "Very ugly error, if server
/// is down how did I log in and how am I connected". Two defects in one frame.
/// The box was a red border stretched to the rail's full height around one line
/// of text, roughly 1,200 physical pixels of empty bordered sidebar. And the
/// line said "Could not load channels.", which is not what failed: this branch
/// is `storeProvider`, the local encrypted database, so nothing on it ever
/// touched the server.
///
/// Geometry, not just presence: the earlier form of this rendered exactly the
/// same widget and would have passed a findsOneWidget check.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/providers/sync_failure.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_failure.dart';
import 'package:drift/native.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../ui_snapshot_support.dart';
import '../../support/fake_sync.dart';

const _railHeight = 880.0;

Future<ProviderContainer> _pumpRail(
  WidgetTester tester, {
  required List<Override> overrides,
  double width = 248,
  bool settles = true,
}) async {
  tester.view.physicalSize = Size(width, _railHeight);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: fixtureTokens),
      ),
      syncControllerProvider.overrideWith(
        (ref) => StubSyncController(ref, SyncStatus.offline),
      ),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: fixtureClient(),
        );
        ref.onDispose(client.close);
        return client;
      }),
      ...overrides,
    ],
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: GoRouter(
          initialLocation: Routes.channel('c-general'),
          routes: [
            GoRoute(
              path: Routes.channelPattern,
              builder: (context, state) => const Scaffold(body: ChannelRail()),
            ),
          ],
        ),
      ),
    ),
  );
  // A spinner never settles, so the retrying case pumps a fixed beat instead.
  if (settles) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  return container;
}

/// Disposing before unmounting is what stops a pending debounce (the read
/// marker's, the roster's) outliving the test and hanging it; the same shape
/// `ui_snapshot_support.dart`'s own teardown uses.
Future<void> _teardown(WidgetTester tester, ProviderContainer container) async {
  container.dispose();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

/// A store that will not open, the way a locked or unreachable keychain leaves
/// it: the branch that produced the owner's screenshot.
Override _storeFails() =>
    databaseProvider.overrideWith((ref) => throw _keyUnavailable);

/// A store that opens and is genuinely empty, which is what a device that has
/// never managed a single successful refresh holds.
Override _storeEmpty() => databaseProvider.overrideWith((ref) {
  final db = SlimmDatabase(NativeDatabase.memory());
  ref.onDispose(db.close);
  return db;
});

const _keyUnavailable = LocalDatabaseKeyUnavailable('keychain locked');

void main() {
  // The rail's category sections read the collapsed-category preference.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a store that will not open shows a failure sized to its own '
      'content, near the top, leaving the rest of the rail empty', (
    tester,
  ) async {
    final container = await _pumpRail(tester, overrides: [_storeFails()]);

    final box = tester.getRect(find.byType(AppErrorState));
    expect(
      box.height,
      lessThan(_railHeight / 3),
      reason:
          'the owner saw a border around roughly 1,200px of nothing; a one '
          'line failure must never enclose the whole sidebar',
    );
    expect(
      box.top,
      lessThan(_railHeight / 3),
      reason: 'near the top, not floating in the middle of a tall column',
    );
    expect(
      box.bottom,
      lessThan(_railHeight * 0.6),
      reason: 'the rest of the rail is empty rather than enclosed',
    );
    expect(
      box.width,
      lessThanOrEqualTo(248),
      reason: 'it stays inside the rail it belongs to',
    );

    await _teardown(tester, container);
  });

  testWidgets('a store that will not open names the local cause instead of '
      'blaming the channel list', (tester) async {
    final container = await _pumpRail(tester, overrides: [_storeFails()]);

    expect(
      find.textContaining('secure storage is locked'),
      findsOneWidget,
      reason: 'this branch never reached the network, so it must not imply it',
    );
    expect(
      find.text('Could not load channels.'),
      findsNothing,
      reason:
          'the copy the owner read as the server being down while he was '
          'signed in and connected',
    );
    expect(find.text('Retry'), findsOneWidget);

    await _teardown(tester, container);
  });

  // The owner's phone showed only the bare sentence, which fit any cause at all.
  test('an unexpected failure to open the store names what failed', () {
    final failure = localStoreRailFailure(StateError('disk on fire'));

    expect(failure.message, contains('could not be opened'));
    expect(failure.message, contains('StateError'));
    expect(failure.retryable, isTrue);
  });

  testWidgets('an unreachable server and a refused session read differently, '
      'and only one of them offers a retry', (tester) async {
    final first = await _pumpRail(
      tester,
      overrides: [
        _storeEmpty(),
        syncFailureProvider.overrideWith((ref) => SyncFailure.unreachable),
      ],
    );
    expect(find.textContaining('cannot reach the server'), findsOneWidget);
    expect(
      find.text('Retry'),
      findsOneWidget,
      reason: 'asking again is exactly what fixes an unreachable server',
    );
    final unreachable = tester
        .widget<AppErrorState>(find.byType(AppErrorState))
        .message;

    await _teardown(tester, first);
    final second = await _pumpRail(
      tester,
      overrides: [
        _storeEmpty(),
        syncFailureProvider.overrideWith((ref) => SyncFailure.refused),
      ],
    );
    final refused = tester
        .widget<AppErrorState>(find.byType(AppErrorState))
        .message;

    expect(
      refused,
      isNot(unreachable),
      reason:
          'the recovery differs, so the two must never read the same; this '
          'is the whole of "how did I log in if the server is down"',
    );
    expect(find.textContaining('refused this session'), findsOneWidget);
    expect(
      find.text('Retry'),
      findsNothing,
      reason: 'a button that sends the same refused request is a false promise',
    );

    await _teardown(tester, second);
  });

  testWidgets('a refused session offers a Sign in again control that signs '
      'out, because the copy tells the reader to', (tester) async {
    final container = await _pumpRail(
      tester,
      overrides: [
        _storeEmpty(),
        syncFailureProvider.overrideWith((ref) => SyncFailure.refused),
      ],
    );
    final session = container.read(sessionProvider);
    expect(session.tokens, isNotNull);

    expect(find.text('Sign in again'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Sign in again'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(session.tokens, isNull, reason: 'the control must really sign out');

    await _teardown(tester, container);
  });

  test(
    'only a 401 means the session was refused; a 403 can be one channel',
    () {
      expect(
        syncFailureFor(const api.UnauthorizedException('expired')),
        SyncFailure.refused,
      );
      expect(
        syncFailureFor(const api.ForbiddenException('no such channel')),
        SyncFailure.unreachable,
        reason:
            'a catch-up reset of one deleted channel answers 403 and signing '
            'in again would not fix it',
      );
    },
  );

  testWidgets('while a retry is in flight the stale failure and its live '
      'Retry button are replaced by the loading state', (tester) async {
    final container = await _pumpRail(
      tester,
      settles: false,
      overrides: [
        _storeEmpty(),
        syncFailureProvider.overrideWith((ref) => SyncFailure.unreachable),
        syncControllerProvider.overrideWith(
          (ref) => StubSyncController(ref, SyncStatus.connecting),
        ),
      ],
    );

    expect(find.byType(AppErrorState), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await _teardown(tester, container);
  });

  testWidgets('a rail with channels shows no failure at all while sync is '
      'down, because the header dot already says so', (tester) async {
    final container = await _pumpRail(
      tester,
      overrides: [
        _storeEmpty(),
        syncFailureProvider.overrideWith((ref) => SyncFailure.unreachable),
      ],
    );
    final store = await container.read(storeProvider.future);
    await store.upsertChannels(fixtureChannels);
    await tester.pumpAndSettle();

    expect(
      find.byType(AppErrorState),
      findsNothing,
      reason:
          'a cached list with an offline blip is the dot\'s job; a second '
          'indicator for it is what RailConnectionBar was retired to remove',
    );

    await _teardown(tester, container);
  });
}
