// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A personal space removed from the rail (`personal_space_menu_test.dart`
/// covers the removal itself) must still be reachable. This is the round
/// trip the "Remove from list" notice promises, driven the way a person
/// actually would: open the command palette, type their own name, pick
/// the result, and see the rail row itself come back.
///
/// Split out of `command_palette_test.dart` rather than added to it, which
/// would have crossed that file's 500-line hard budget.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/settings/providers/personal_space_visibility.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _me = const api.Me(
  id: 'self',
  username: 'self',
  displayName: 'Self',
  createdAt: 0,
  permissions: 0,
);

const _personalChannel = Channel(
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

/// `watchChannels` overridden to a canned, synchronous stream rather than a
/// live drift query. The rail and the palette each open their own separate
/// `store.watchChannels()` subscription, and a real one needs actual native
/// query execution to deliver its first batch - work a fake-pumped widget
/// test's clock cannot reliably wait out (this is a property of the drift
/// integration these two widgets already share, not of anything this test
/// is checking). This test is about the hide-then-find round trip, which
/// needs a channel list that is simply *there*, not the store's own
/// plumbing, so it substitutes one.
class _FakeStore extends MessageStore {
  _FakeStore(super.db);

  @override
  Stream<List<Channel>> watchChannels() => Stream.value([_personalChannel]);

  // The rail reads watchRailChannels (CP8), not watchChannels; same canned row.
  @override
  Stream<List<Channel>> watchRailChannels() => Stream.value([_personalChannel]);
}

/// Only `/blocks` is ever hit: `blocksProvider` fetches it as soon as
/// `HomeShell` mounts, and nothing else in this test opens the personal
/// space over the network - it is already in the local store, and
/// selecting the hidden one un-hides it locally rather than calling
/// `openDirectMessage`.
http.Client _fakeClient() =>
    MockClient((request) async => http.Response('[]', 200));

({ProviderContainer container, SlimmDatabase db}) _setup() {
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: _fakeClient(),
        );
        ref.onDispose(client.close);
        return client;
      }),
      databaseProvider.overrideWith((ref) => db),
      storeProvider.overrideWith((ref) async => _FakeStore(db)),
      meProvider.overrideWith((ref) async => _me),
      membersProvider.overrideWith((ref) async => const []),
    ],
  );
  return (container: container, db: db);
}

GoRouter _testRouter() => GoRouter(
  initialLocation: '/channels',
  routes: [
    GoRoute(
      path: '/channels',
      builder: (context, state) =>
          const HomeShell(child: Center(child: Text('conversation'))),
    ),
    GoRoute(
      path: Routes.channelPattern,
      builder: (context, state) =>
          const HomeShell(child: Center(child: Text('conversation'))),
    ),
  ],
);

/// See `home_shell_test.dart` for why unmounting and pumping past Drift's
/// stream-cache timer, before disposing, is required here.
Future<void> _teardown(
  WidgetTester tester,
  ProviderContainer container,
  SlimmDatabase db,
) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
  await db.close();
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: _testRouter(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pressCtrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// A channel or member name the palette shows can also be on screen behind
/// it (the rail), so this scopes to the palette's own floating card, the
/// same reason `command_palette_test.dart` does.
Finder _inPalette(String text) =>
    find.descendant(of: find.byType(AppMenu), matching: find.text(text));

void main() {
  testWidgets(
    'a hidden personal space is absent from a blank-query browse, but '
    'searching the caller\'s own name finds it and reopening it restores '
    'the rail row',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        personalSpaceHiddenKey('self'): true,
      });
      final setup = _setup();
      addTearDown(setup.container.dispose);
      await _pump(tester, setup.container);

      expect(
        find.text(personalSpaceName),
        findsNothing,
        reason: 'hidden from the rail row it would otherwise pin',
      );

      await _pressCtrlK(tester);
      expect(
        _inPalette(personalSpaceName),
        findsNothing,
        reason: 'a blank query browses everything, which defeats hiding it',
      );

      await tester.enterText(
        find.byKey(const Key('command-palette-input')),
        'Self',
      );
      await tester.pumpAndSettle();
      expect(_inPalette(personalSpaceName), findsOneWidget);

      await tester.tap(_inPalette(personalSpaceName));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('command-palette-input')), findsNothing);
      final context = tester.element(find.text('conversation').first);
      expect(GoRouterState.of(context).uri.path, '/channels/dm-self');
      expect(
        find.text(personalSpaceName),
        findsOneWidget,
        reason: 'selecting it is also how it comes back onto the rail',
      );

      await _teardown(tester, setup.container, setup.db);
    },
  );
}
