// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Captures of the two rail states the owner reported from the real iOS app on
/// 2026-09-30: the rail with no channel list to show, and the footer's own
/// status line in each presence state.
///
/// Its own harness rather than [renderSurface], because both states are exactly
/// the ones [fixtureContainer] cannot produce: it opens the local store and
/// seeds it, and these need a store that will not open at all, or one that
/// opens empty.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/providers/sync_failure.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_platform/testing.dart';

import 'ui_snapshot_support.dart';
import 'support/fake_sync.dart';

ProviderContainer _container(List<Override> overrides) => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: fixtureTokens)),
    syncControllerProvider.overrideWith(StubSyncController.new),
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

/// The rail alone at the viewport's height, which is what the owner screenshot
/// shows: nothing beside it is what the failure's size has to be judged against.
Future<void> _capture(
  WidgetTester tester,
  String viewport,
  String theme,
  String name,
  Widget body, {
  List<Override> overrides = const [],
}) async {
  // A platform channel with no host in a test; empty is its real default.
  SharedPreferences.setMockInitialValues(const {});
  tester.view.physicalSize = viewports[viewport]!;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = _container(overrides);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: theme == 'dark'
              ? buildTheme(Brightness.dark, AppTokens.dark)
              : buildTheme(Brightness.light, AppTokens.light),
          routerConfig: GoRouter(
            initialLocation: Routes.channel('c-general'),
            routes: [
              GoRoute(
                path: Routes.channelPattern,
                builder: (context, state) => Scaffold(body: body),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);

  container.dispose();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

Override _storeFails() => databaseProvider.overrideWith(
  (ref) => throw const LocalDatabaseKeyUnavailable('keychain locked'),
);

Override _storeEmpty() => databaseProvider.overrideWith((ref) {
  final db = SlimmDatabase(NativeDatabase.memory());
  ref.onDispose(db.close);
  return db;
});

/// The width the rail actually gets: Material's own Drawer default on a phone,
/// where `CompactChannelRailDrawer` mounts it, and the design's measured width
/// at every docked layout.
double _railWidth(String viewport) =>
    viewport == 'desktop' ? ChannelRail.expandedWidth : 304;

Widget _railInLayout(String viewport) =>
    SizedBox(width: _railWidth(viewport), child: const ChannelRail());

void main() {
  setUpAll(loadRealFonts);

  for (final theme in const ['dark', 'light']) {
    for (final viewport in phoneAndDesktop) {
      testWidgets('rail failure, local store locked, at $viewport ($theme)', (
        tester,
      ) async {
        await _capture(
          tester,
          viewport,
          theme,
          'rail-failure-store-$viewport-$theme',
          _railInLayout(viewport),
          overrides: [_storeFails()],
        );
      });

      testWidgets('rail failure, session refused, at $viewport ($theme)', (
        tester,
      ) async {
        await _capture(
          tester,
          viewport,
          theme,
          'rail-failure-refused-$viewport-$theme',
          _railInLayout(viewport),
          overrides: [
            _storeEmpty(),
            syncFailureProvider.overrideWith((ref) => SyncFailure.refused),
          ],
        );
      });

      testWidgets('rail failure, server unreachable, at $viewport ($theme)', (
        tester,
      ) async {
        await _capture(
          tester,
          viewport,
          theme,
          'rail-failure-unreachable-$viewport-$theme',
          _railInLayout(viewport),
          overrides: [
            _storeEmpty(),
            syncFailureProvider.overrideWith((ref) => SyncFailure.unreachable),
          ],
        );
      });

      for (final (label, visibility) in const [
        ('unknown', null),
        ('online', api.PresenceVisibility.online),
        ('away', api.PresenceVisibility.away),
        ('dnd', api.PresenceVisibility.dnd),
        ('hidden', api.PresenceVisibility.hidden),
      ]) {
        testWidgets('rail footer, $label, at $viewport ($theme)', (
          tester,
        ) async {
          await _capture(
            tester,
            viewport,
            theme,
            'rail-footer-$label-$viewport-$theme',
            SizedBox(
              width: _railWidth(viewport),
              child: const Column(
                children: [RailHeader(), Spacer(), RailUserFooter()],
              ),
            ),
            overrides: [
              _storeEmpty(),
              presenceVisibilityDisplayProvider.overrideWith(
                (ref) => visibility,
              ),
            ],
          );
        });
      }
    }
  }
}
