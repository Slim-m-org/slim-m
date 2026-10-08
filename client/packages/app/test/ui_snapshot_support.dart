// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fixture the UI snapshot matrix renders: real fonts, a seeded session,
/// a seeded local store, and a container wired like the app's.
///
/// Kept out of the test file so the matrix there stays a list of sizes.
///
/// **Every PNG this writes is rasterised in software** (`flutter test` has
/// no GPU), which used to lie about a `BoxShadow`: `support/real_shadows.
/// dart`'s own doc comment tells the whole story, now closed here by
/// [withRealShadows] after misleading five review passes into reading the
/// floating dock's shadow as a hard-edged defect (see CLAUDE.md). A thin
/// diagonal stroke can still appear broken or dotted even when the
/// underlying geometry is correct - see `visual_render_support.dart`'s own
/// doc comment in the voice_canvas package for that one, which is a real,
/// unrelated antialiasing limit rather than a fixable framework flag.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/providers/message_extras.dart';
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/screens/admin/account_recovery_screen.dart';
import 'package:slimm_app/src/screens/admin/analytics_screen.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_screen.dart';
import 'package:slimm_app/src/screens/admin/emoji_screen.dart';
import 'package:slimm_app/src/screens/admin/invites_screen.dart';
import 'package:slimm_app/src/screens/admin/performance_screen.dart';
import 'package:slimm_app/src/screens/admin/removed_members_screen.dart';
import 'package:slimm_app/src/screens/admin/reports_screen.dart';
import 'package:slimm_app/src/screens/admin/roles_screen.dart';
import 'package:slimm_app/src/screens/debug_log_screen.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/screens/onboarding_screen.dart';
import 'package:slimm_app/src/screens/personal_settings_screen.dart';
import 'package:slimm_app/src/screens/sign_in_screen.dart';
import 'package:slimm_app/src/routing/settings_pages.dart';
import 'package:slimm_app/src/screens/thread_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mid_flight_capture.dart';
import 'support/real_shadows.dart';
import 'ui_snapshot_channel_settings.dart';
import 'ui_snapshot_dock.dart';
import 'ui_snapshot_fixture_data.dart';

export 'ui_snapshot_fonts.dart'
    show emojiFontPath, loadEmojiFont, loadFontFamily, loadRealFonts;
export 'ui_snapshot_fixture_data.dart'
    show
        fixtureAnalyticsEnabled,
        fixtureCategories,
        fixtureChannels,
        fixtureClient,
        fixtureResponse,
        fixtureMessages;

/// The widths that take a different branch, not a catalogue of devices.
///
/// The five named ones are device shapes, kept for general coverage.
/// The rest are pairs straddling one specific pixel a real layout branches
/// on - `kCompactWidth`, `LayoutClass`'s own second boundary, and three more
/// local to `onboarding_shell.dart` and `settings_panes.dart` - a width one
/// round number away from a boundary can sit entirely on one side of it and
/// never prove the other side renders at all.
const viewports = <String, Size>{
  'phone-portrait': Size(390, 844),
  'phone-landscape': Size(844, 390),
  'tablet-portrait': Size(834, 1194),
  'desktop-narrow': Size(900, 600),
  'desktop': Size(1400, 880),
  // kCompactWidth (design_system/app_metrics.dart): touch density and modal presentation.
  'compact-599': Size(599, 844),
  'compact-600': Size(600, 844),
  // LayoutClass.medium/expanded (routing/breakpoints.dart): the member pane.
  'expanded-999': Size(999, 844),
  'expanded-1000': Size(1000, 844),
  // onboarding_shell's brand-panel floor (900).
  'onboarding-899': Size(899, 844),
  'onboarding-900': Size(900, 844),
  // onboarding_shell's stepper label threshold (420 of content width, window less padding).
  'stepper-467': Size(467, 844),
  'stepper-468': Size(468, 844),
  // settings_panes's two-pane floor (800).
  'settings-799': Size(799, 844),
  'settings-800': Size(800, 844),
};

/// A phone and a desktop render: the pair every standalone screen samples by
/// default, adding only the breakpoint pair its own layout actually owns.
const phoneAndDesktop = ['phone-portrait', 'desktop'];

/// Straddles `kCompactWidth`, the touch-density and modal-presentation
/// boundary every settings and admin screen shares.
const compactBracket = ['compact-599', 'compact-600'];

/// Where PNGs land. Gitignored: these are for looking at, not for diffing.
const snapshotDir = 'build/ui-snapshots';

/// Set SLIMM_UI_SNAPSHOTS=1 to write them. Unset, the matrix still runs and
/// still asserts no overflow, which is the part that belongs in CI.
bool get writingSnapshots => Platform.environment['SLIMM_UI_SNAPSHOTS'] == '1';

const fixtureTokens = api.TokenPair(
  userId: 'user-nick',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Real [SyncController] opens a socket to a server that is not there.
class _NoopSyncController extends SyncController {
  _NoopSyncController(super.ref);

  @override
  Future<void> start() async {}
}

/// [_NoopSyncController] pinned to a chosen [SyncStatus] rather than left at
/// the constructor's own offline default, for a surface that needs to prove
/// the connecting/live transcript states rather than the offline one.
class FixedSyncController extends SyncController {
  FixedSyncController(super.ref, SyncStatus status) {
    state = status;
  }

  @override
  Future<void> start() async {}
}

/// A container wired like the app's, with the network and database swapped.
///
/// [extraOverrides] layers on top for a test that needs one more provider
/// swapped (a fake voice call, say) without duplicating this whole setup.
Future<({ProviderContainer container, SlimmDatabase db})> fixtureContainer({
  List<Override> extraOverrides = const [],
  List<api.Message>? messages,
}) async {
  final resolvedMessages = messages ?? fixtureMessages;
  // The voice settings screen reads SharedPreferences, which is a platform
  // channel with no host in a test; empty mock values are its real defaults.
  SharedPreferences.setMockInitialValues(const {});
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: fixtureTokens),
      ),
      syncControllerProvider.overrideWith(_NoopSyncController.new),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: fixtureClient(),
        );
        ref.onDispose(client.close);
        return client;
      }),
      databaseProvider.overrideWith((ref) => db),
      // HomeShell watches this, so the real AudioPlayers player is built for
      // every surface. Ordinary widget tests never notice, because nothing
      // drives the platform channel; the SLIMM_UI_SNAPSHOTS render path does,
      // through tester.runAsync, and the channel has no host in a test.
      notificationSoundControllerProvider.overrideWith(
        (ref) => NotificationSoundController(ref, player: _SilentPlayer()),
      ),
      ...extraOverrides,
    ],
  );
  final store = await container.read(storeProvider.future);
  await store.upsertChannels(fixtureChannels);
  await store.replaceCategories(fixtureCategories);
  await store.applyMessages(resolvedMessages);
  // Reactions, attachments and polls live in an in-memory controller rather
  // than the store, so seeding the store alone renders none of them.
  container
      .read(messageExtrasProvider.notifier)
      .applyMessages(resolvedMessages);
  return (container: container, db: db);
}

/// Whether the real app reaches [location] by pushing it over the channel
/// shell, rather than it being a destination of its own.
///
/// Every settings and administration route is reached this way: a member
/// opens one from inside the app, never cold. [fixtureRouter] starts there
/// at the channel shell instead, and `ui_snapshot_test.dart` pushes the real
/// target on top of it after the first frame, so [modalPage]'s
/// `Navigator.of(context).canPop()` reads true exactly as it would in the
/// app - floating shadow, scrim and all - rather than the "opened cold"
/// presentation a bare `initialLocation` at the route itself would produce.
/// A thread is pushed the same way, over the parent channel, from the
/// message context menu.
bool isModalFixtureRoute(String location) =>
    location.startsWith('/settings') || location.startsWith('/thread/');

/// The shell, on the real routes, at [location].
///
/// The settings and admin routes use the app's own [modalPage]; see
/// [isModalFixtureRoute] for how this router is primed so a desktop render
/// shows the real floating presentation rather than the cold-open one.
/// Onboarding and sign-in stand alone, exactly as the real router mounts
/// them.
GoRouter fixtureRouter(String location) => GoRouter(
  initialLocation: isModalFixtureRoute(location)
      ? '/channels/c-general'
      : location,
  routes: [
    GoRoute(
      path: '/join',
      builder: (context, state) =>
          OnboardingScreen(onServerChosen: (server, invite) {}),
    ),
    GoRoute(
      path: '/sign-in',
      builder: (context, state) => const SignInScreen(),
    ),
    GoRoute(
      path: '/settings',
      pageBuilder: (context, state) =>
          modalPage(context, const PersonalSettingsScreen()),
    ),
    GoRoute(path: '/settings/space', pageBuilder: spaceSettingsPage),
    GoRoute(
      path: '/settings/reports',
      pageBuilder: (context, state) =>
          modalPage(context, const ReportsScreen()),
    ),
    GoRoute(
      path: '/settings/invites',
      pageBuilder: (context, state) =>
          modalPage(context, const InvitesScreen()),
    ),
    GoRoute(
      path: '/settings/roles',
      pageBuilder: (context, state) => modalPage(context, const RolesScreen()),
    ),
    channelSettingsFixtureRoute,
    GoRoute(
      path: '/settings/permissions',
      pageBuilder: (context, state) =>
          modalPage(context, const ChannelPermissionsScreen()),
    ),
    GoRoute(
      path: '/settings/emoji',
      pageBuilder: (context, state) => modalPage(context, const EmojiScreen()),
    ),
    GoRoute(
      path: '/settings/removed-members',
      pageBuilder: (context, state) =>
          modalPage(context, const RemovedMembersScreen()),
    ),
    GoRoute(
      path: '/settings/analytics',
      pageBuilder: (context, state) =>
          modalPage(context, const AnalyticsScreen()),
    ),
    GoRoute(
      path: '/settings/performance',
      pageBuilder: (context, state) =>
          modalPage(context, const PerformanceScreen()),
    ),
    GoRoute(
      path: '/settings/account-recovery',
      pageBuilder: (context, state) =>
          modalPage(context, const AccountRecoveryScreen()),
    ),
    ...dockFixtureRoutes,
    GoRoute(
      path: '/settings/debug-log',
      pageBuilder: (context, state) =>
          modalPage(context, const DebugLogScreen()),
    ),
    GoRoute(
      path: '/thread/:channelId',
      pageBuilder: (context, state) => modalPage(
        context,
        ThreadScreen(channelId: state.pathParameters['channelId']!),
      ),
    ),
    ShellRoute(
      builder: (context, state, child) => HomeShell(child: child),
      routes: [
        GoRoute(
          path: '/channels',
          // The real route renders NoChannelSelected here, not a placeholder.
          builder: (context, state) => const NoChannelSelected(),
          routes: [
            GoRoute(
              path: ':channelId',
              builder: (context, state) => ConversationPane(
                channelId: state.pathParameters['channelId']!,
              ),
            ),
          ],
        ),
      ],
    ),
  ],
);

/// Key on the boundary the PNG is taken from.
const snapshotBoundary = Key('ui_snapshot_boundary');

/// Rasterising is engine work the test's fake clock never completes, so it
/// has to run in the real zone or the test hangs holding a finished image.
Future<void> writeSnapshot(WidgetTester tester, String name) async {
  if (!writingSnapshots) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(snapshotBoundary),
  );
  await withRealShadows(tester, boundary, () async {
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(snapshotDir).createSync(recursive: true);
      File(
        '$snapshotDir/$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}

/// Disposing before unmounting is what stops a pending debounce (the member
/// roster's, the read marker's) from outliving the test and hanging it.
Future<void> teardownFixture(
  WidgetTester tester,
  ProviderContainer container,
  SlimmDatabase db,
) async {
  container.dispose();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  await db.close();
}

/// Builds the router at [route], pumps two frames to settle on-mount
/// animations, writes the snapshot and asserts no overflow. Shared by every
/// surface table across every `ui_snapshot_*_test.dart` file, so a surface
/// added in one file renders exactly the way the rest of the matrix does.
///
/// [settleJoinTransition] is for a controller whose *outcome* (not its
/// initial state) is what the snapshot wants, `AttemptedJoinVoiceController`'s
/// own shape: its first build still shows `VoiceScreen`'s 'joining' stage,
/// and the real terminal state only lands from a post-frame callback fired
/// during the first `pump()` below, one frame after `AppFadeIn` remounts
/// under a new key for the new stage. That remount's own entrance ticker
/// has not been given a frame to start on yet - the same t=0 trap the
/// two-pump comment below already names, one layer later - so it needs a
/// third pump to settle rather than the usual two. Confirmed by looking:
/// without this, `voice-rejoin-*` and `who-is-here-*` rendered a fully
/// blank body, not merely an unsettled fade.
///
/// [settleNestedResolve] is for a widget whose own `initState` fires a
/// *second*, nested async resolve after it mounts - `ReportCard`'s own
/// shape (see PR #545 ("report card overflow")) - which the two
/// pumps above do not reach: they settle the list that creates the widget,
/// not what that widget goes on to do once it exists. One further bare
/// pump is what [expectSettled] itself proved sufficient to let it land, so
/// this is that same pump, run before anything is captured or asserted
/// rather than after, so the capture shows the resolve rather than the
/// placeholder ahead of it.
/// [knownTransient] is for a surface where [expectSettled] finding a real
/// difference is not a defect - two valid states along one loading
/// sequence, never a placeholder standing in for content - see that
/// function's own doc for the one surface this is true of today.
/// [allowNoText] passes straight through to [expectSettled]'s own blank
/// check, for the rare surface that is genuinely text-free.
/// [textScaler] layers a scale over the ambient one (a copy of it, one field
/// changed - the same shape `design_system`'s `surfaces_test.dart` already
/// uses and is allowlisted for) rather than replacing it, so dark/light and
/// platform brightness stay whatever the ambient `MediaQueryData` says;
/// `ui_snapshot_text_scale_test.dart` is what actually sets it.
///
/// The last timed pump below exists for the fade-behind-the-capture shape:
/// `AppAsyncView` mounts resolved content inside an `AppFadeIn` whose ticker
/// starts when the DATA mounts, so a fetch resolving on the budget's final
/// frame put a whole admin pane on screen at opacity zero - present in the
/// tree, absent from the pixels, and stable enough to pass a bare-pump
/// settle check. Four of five probed admin routes were captured that way
/// (2026-09-03). The frame is 350ms, past `AppMotion.slow`'s 280ms ceiling,
/// and [expectSettled]'s own timed pumps now fail anything still later.
Future<void> renderSurface(
  WidgetTester tester,
  String route,
  String viewportName,
  String theme,
  String snapshotName, {
  List<Override> overrides = const [],
  bool settleJoinTransition = false,
  bool settleNestedResolve = false,
  bool knownTransient = false,
  bool allowNoText = false,
  TextScaler? textScaler,
  Future<void> Function(WidgetTester tester)? afterSettle,
}) async {
  tester.view.physicalSize = viewports[viewportName]!;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer(extraOverrides: overrides);
  final router = fixtureRouter(route);
  final app = MaterialApp.router(
    debugShowCheckedModeBanner: false,
    theme: theme == 'dark'
        ? buildTheme(Brightness.dark, AppTokens.dark)
        : buildTheme(Brightness.light, AppTokens.light),
    routerConfig: router,
    // The same wrapper main.dart ships, so density matches the app.
    builder: appChromeBuilder,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: textScaler == null
            ? app
            : Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                  child: app,
                ),
              ),
      ),
    ),
  );
  if (isModalFixtureRoute(route)) {
    // Settle at the base first, then push: see isModalFixtureRoute's doc.
    await tester.pump();
    unawaited(router.push(route));
  }
  // Two pumps settle on-mount entrance animations (a ticker's first frame is its own t=0) without pumpAndSettle, which would hang on the states that show a perpetual spinner.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  if (settleJoinTransition) {
    await tester.pump(const Duration(milliseconds: 350));
  }
  if (settleNestedResolve) {
    await tester.pump();
  }
  // A fetch landing on the final frame above mounts its fade at t=0; one more timed frame lets it land - see this function's own doc.
  await tester.pump(const Duration(milliseconds: 350));
  if (afterSettle != null) {
    await afterSettle(tester);
    await tester.pump(const Duration(milliseconds: 350));
  }
  // Before writeSnapshot: its own extra pumps could mask what this looks for.
  await expectSettled(
    tester,
    snapshotName,
    knownTransient: knownTransient,
    allowNoText: allowNoText,
  );

  await writeSnapshot(tester, snapshotName);

  // pumpWidget already rethrows an overflow, so reaching here is the assertion.
  expect(tester.takeException(), isNull);

  await teardownFixture(tester, fixture.container, fixture.db);
}

/// Plays nothing: a snapshot render is about pixels, and the real player
/// reaches a platform channel with no host under `tester.runAsync`.
class _SilentPlayer implements SoundPlayer {
  @override
  Future<void> play(NotificationSound sound) async {}
  @override
  Future<void> loop(NotificationSound sound) async {}
  @override
  Future<void> stopLoop() async {}
  @override
  Future<void> dispose() async {}
}
