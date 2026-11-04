// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The seeded container and router the UI snapshot matrix renders against.
library;

import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'support/fake_mic_preview.dart' show quietMicPreview;
import 'package:slimm_app/src/features/settings/screens/themes_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/account_recovery_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/analytics_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/channel_permissions_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/emoji_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/invites_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/performance_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/removed_members_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/reports_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/roles_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/server_metrics_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/audit_log_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/storage_screen.dart';
import 'package:slimm_app/src/features/settings/screens/debug_log_screen.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_app/src/routing/settings_pages.dart';
import 'package:slimm_app/src/features/messages/screens/thread_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';
import 'ui_snapshot_channel_settings.dart';
import 'ui_snapshot_dock.dart';
import 'ui_snapshot_fixture_data.dart';
import 'support/fake_sync.dart';
import 'support/fake_sound_player.dart';

const fixtureTokens = api.TokenPair(
  userId: 'user-nick',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A container wired like the app's, with the network and database swapped.
///
/// [extraOverrides] layers on top for a test that needs one more provider
/// swapped (a fake voice call, say) without duplicating this whole setup.
Future<({ProviderContainer container, SlimmDatabase db})> fixtureContainer({
  List<Override> extraOverrides = const [],
  List<api.Message>? messages,
}) async {
  final resolvedMessages = messages ?? fixtureMessages;
  // Voice settings reads SharedPreferences, a platform channel with no host in a test.
  SharedPreferences.setMockInitialValues(const {});
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: fixtureTokens),
      ),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      quietMicPreview,
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
      // HomeShell builds a real AudioPlayers player, and the capture path drives its host-less channel.
      notificationSoundControllerProvider.overrideWith(
        (ref) => NotificationSoundController(ref, player: SilentSoundPlayer()),
      ),
      ...extraOverrides,
    ],
  );
  final store = await container.read(storeProvider.future);
  await store.upsertChannels(fixtureChannels);
  await store.replaceCategories(fixtureCategories);
  await store.applyMessages(resolvedMessages);
  // Reactions, attachments and polls live in a controller, not the store.
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
    GoRoute(path: '/settings', pageBuilder: personalSettingsPage),
    GoRoute(path: '/settings/space', pageBuilder: spaceSettingsPage),
    GoRoute(
      path: '/settings/themes',
      pageBuilder: (context, state) => modalPage(context, const ThemesScreen()),
    ),
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
      path: '/settings/storage',
      pageBuilder: (context, state) =>
          modalPage(context, const StorageScreen()),
    ),
    GoRoute(
      path: '/settings/audit-log',
      pageBuilder: (context, state) =>
          modalPage(context, const AuditLogScreen()),
    ),
    GoRoute(
      path: '/settings/server-metrics',
      pageBuilder: (context, state) =>
          modalPage(context, const ServerMetricsScreen()),
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
