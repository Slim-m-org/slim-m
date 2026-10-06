// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Routing.
///
/// A shell route wraps the signed-in surfaces so the channel list stays mounted
/// while the conversation changes, rather than the whole tree rebuilding on each
/// navigation. Paths come from [Routes]; no string literals appear at call sites.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' show TokenPair;

import '../providers/providers.dart';
import '../providers/threads.dart';
import '../screens/not_found_screen.dart';
import '../screens/admin/account_recovery_screen.dart';
import '../screens/admin/analytics_screen.dart';
import '../screens/admin/bots_screen.dart';

import 'package:slimm_data/data.dart' show Channel;

import '../screens/admin/channel_permissions_screen.dart';
import '../screens/admin/dock_module_access_screen.dart';
import '../screens/admin/dock_module_screen.dart';
import '../screens/admin/dock_screen.dart';
import '../screens/admin/emoji_screen.dart';
import '../screens/admin/invites_screen.dart';
import '../screens/admin/performance_screen.dart';
import '../screens/admin/reports_screen.dart';
import '../screens/admin/removed_members_screen.dart';
import '../screens/admin/role_detail_screen.dart';
import '../screens/admin/roles_screen.dart';
import '../screens/admin/server_metrics_screen.dart';
import '../screens/admin/storage_screen.dart';
import '../screens/admin/webhooks_screen.dart';
import '../screens/channel_settings_screen.dart';
import '../screens/home_shell.dart';
import '../screens/message_deep_link.dart';
import '../screens/debug_log_screen.dart';
import '../screens/onboarding_screen.dart';
import '../screens/sign_in_screen.dart';
import '../screens/thread_screen.dart';
import '../widgets/mobile_boot_gate.dart';
import 'breakpoints.dart';
import 'modal_page.dart';
import 'page_transitions.dart';
import 'routes.dart';
import 'settings_pages.dart';

/// The app's router.
///
/// Redirection is driven by two facts, not one. The session decides whether the
/// signed-in surfaces are reachable, so a revoked session lands the user on the
/// join flow wherever they were. Which end of that flow they land on is decided
/// by whether a server has ever been chosen: someone who already has one is
/// signed out, not new, and sending them to onboarding asks them to retype an
/// address the app is holding.
final routerProvider = Provider<GoRouter>((ref) {
  // Settings and administration are pushed over the app so they can float as
  // modals with it still visible behind. Without this the address bar would
  // keep saying /channels while a modal is open, so the URL could not be
  // copied, shared or reloaded, and browser back would not close it.
  GoRouter.optionURLReflectsImperativeAPIs = true;
  final session = ref.watch(sessionProvider);

  // Read, not watched: main() awaits restoreSession before the router is
  // built, so a remembered server is already in place by this point.
  String signedOutHome() => ref.read(chosenServerProvider) == null
      ? Routes.onboarding
      : Routes.signIn;

  return GoRouter(
    initialLocation: signedOutHome(),
    // Rebuilds the redirect whenever the session changes, which is what makes
    // sign-out and revocation take effect immediately.
    refreshListenable: _SessionListenable(ref),
    redirect: (context, state) {
      final signedIn = session.isSignedIn;
      final location = state.matchedLocation;
      final onJoinFlow =
          location == Routes.signIn || location == Routes.onboarding;
      // Anywhere in the join flow is left alone, so a signed-out user can walk
      // back to onboarding to pick a different server or redeem an invite.
      if (!signedIn) return onJoinFlow ? null : signedOutHome();
      if (onJoinFlow) return Routes.channels;
      return null;
    },
    errorBuilder: (context, state) => const NotFoundScreen(),
    routes: [
      // The join flow fades through like the shell's own pages, so signing in hands off into the app as one motion.
      GoRoute(
        path: Routes.onboarding,
        pageBuilder: (context, state) => fadeThroughPage(
          context,
          OnboardingScreen(
            onServerChosen: (server, invite) {
              ref.read(chosenServerProvider.notifier).choose(server);
              ref.read(pendingInviteProvider.notifier).state = invite;
              context.go(Routes.signIn);
            },
          ),
          key: const ValueKey('onboarding'),
        ),
      ),
      GoRoute(
        path: Routes.signIn,
        pageBuilder: (context, state) => fadeThroughPage(
          context,
          const SignInScreen(),
          key: const ValueKey('sign-in'),
        ),
      ),
      GoRoute(path: Routes.personalSettings, pageBuilder: personalSettingsPage),
      GoRoute(path: Routes.spaceSettings, pageBuilder: spaceSettingsPage),
      GoRoute(
        path: Routes.adminReports,
        pageBuilder: (context, state) =>
            modalPage(context, const ReportsScreen()),
      ),
      GoRoute(
        path: Routes.adminInvites,
        pageBuilder: (context, state) =>
            modalPage(context, const InvitesScreen()),
      ),
      GoRoute(
        path: Routes.adminRoles,
        pageBuilder: (context, state) =>
            modalPage(context, const RolesScreen()),
      ),
      GoRoute(
        path: '${Routes.adminRoles}/:roleId',
        pageBuilder: (context, state) => modalPage(
          context,
          RoleDetailScreen(roleId: state.pathParameters['roleId']!),
        ),
      ),
      GoRoute(
        path: Routes.adminBots,
        pageBuilder: (context, state) => modalPage(context, const BotsScreen()),
      ),
      GoRoute(
        path: Routes.adminWebhooks,
        pageBuilder: (context, state) =>
            modalPage(context, const WebhooksScreen()),
      ),
      GoRoute(
        path: Routes.adminAccountRecovery,
        pageBuilder: (context, state) =>
            modalPage(context, const AccountRecoveryScreen()),
      ),
      GoRoute(
        path: Routes.adminRemovedMembers,
        pageBuilder: (context, state) =>
            modalPage(context, const RemovedMembersScreen()),
      ),
      GoRoute(
        path: Routes.adminOverwrites,
        // `extra` pre-selects a channel when opened from its own menu; absent from Space settings, where the picker leads.
        pageBuilder: (context, state) => modalPage(
          context,
          ChannelPermissionsScreen(initialChannel: state.extra as Channel?),
        ),
      ),
      GoRoute(
        path: Routes.channelSettings,
        // `extra` carries the channel and whether it was open; null on a cold pasted URL.
        pageBuilder: (context, state) => modalPage(
          context,
          ChannelSettingsScreen(args: state.extra as ChannelSettingsRouteArgs?),
        ),
      ),
      GoRoute(
        path: Routes.adminEmoji,
        pageBuilder: (context, state) =>
            modalPage(context, const EmojiScreen()),
      ),
      GoRoute(
        path: Routes.adminAnalytics,
        pageBuilder: (context, state) =>
            modalPage(context, const AnalyticsScreen()),
      ),
      GoRoute(
        path: Routes.adminPerformance,
        pageBuilder: (context, state) =>
            modalPage(context, const PerformanceScreen()),
      ),
      GoRoute(
        path: Routes.adminStorage,
        pageBuilder: (context, state) =>
            modalPage(context, const StorageScreen()),
      ),
      GoRoute(
        path: Routes.adminServerMetrics,
        pageBuilder: (context, state) =>
            modalPage(context, const ServerMetricsScreen()),
      ),
      GoRoute(
        path: Routes.adminDock,
        pageBuilder: (context, state) => modalPage(context, const DockScreen()),
      ),
      GoRoute(
        path: '${Routes.adminDock}/:moduleId',
        pageBuilder: (context, state) => modalPage(
          context,
          DockModuleScreen(
            moduleId: state.pathParameters['moduleId']!,
            source: state.uri.queryParameters['source'],
          ),
        ),
      ),
      GoRoute(
        path: '${Routes.adminDock}/:moduleId/access',
        pageBuilder: (context, state) => modalPage(
          context,
          DockModuleAccessScreen(
            moduleId: state.pathParameters['moduleId']!,
            source: state.uri.queryParameters['source'],
          ),
        ),
      ),
      GoRoute(
        path: Routes.debugLog,
        pageBuilder: (context, state) =>
            modalPage(context, const DebugLogScreen()),
      ),
      GoRoute(
        path: Routes.threadPattern,
        pageBuilder: (context, state) {
          final threadId = state.pathParameters['channelId']!;
          final width = MediaQuery.sizeOf(context).width;
          // A cold-opened thread - deep link, reload, notification - docks beside its parent at widths that fit the pane, the same as an in-app open (UX1); below that it stays the modal.
          if (LayoutClass.fromWidth(width).fitsThreadPane(width)) {
            return NoTransitionPage<void>(
              child: _ThreadDockRedirect(threadId: threadId),
            );
          }
          return modalPage(context, ThreadScreen(channelId: threadId));
        },
      ),
      // The shell keeps the channel list alive across conversation changes;
      // the child pages fade through so switching one for another reads as a
      // navigation rather than an instant swap.
      ShellRoute(
        builder: (context, state, child) =>
            MobileBootGate(child: HomeShell(child: child)),
        routes: [
          GoRoute(
            path: Routes.channels,
            pageBuilder: (context, state) => fadeThroughPage(
              context,
              const NoChannelSelected(),
              key: const ValueKey('no-channel'),
            ),
            routes: [
              GoRoute(
                path: ':channelId',
                pageBuilder: (context, state) {
                  final channelId = state.pathParameters['channelId']!;
                  // Generously over a uuid's 36; see client_transport.dart.
                  if (channelId.length > 128) {
                    return fadeThroughPage(
                      context,
                      const NoChannelSelected(),
                      key: const ValueKey('no-channel'),
                    );
                  }
                  return fadeThroughPage(
                    context,
                    ConversationPane(
                      channelId: channelId,
                      openChat: Routes.opensChat(state.uri),
                    ),
                    key: ValueKey('channel-$channelId'),
                  );
                },
              ),
              GoRoute(
                path: Routes.messagePattern,
                pageBuilder: (context, state) {
                  final channelId = state.pathParameters['channelId']!;
                  final messageId = state.pathParameters['messageId']!;
                  // Same bound as the channel route above.
                  if (channelId.length > 128 || messageId.length > 128) {
                    return fadeThroughPage(
                      context,
                      const NoChannelSelected(),
                      key: const ValueKey('no-channel'),
                    );
                  }
                  // One page key per channel, so moving between a channel and its links swaps the child, not the page.
                  return fadeThroughPage(
                    context,
                    MessageDeepLink(channelId: channelId, messageId: messageId),
                    key: ValueKey('channel-$channelId'),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

/// Bridges the session stream to a Listenable, which is what GoRouter's
/// refresh hook takes.
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(Ref ref) {
    _subscription = ref.watch(sessionProvider).changes.listen((_) {
      notifyListeners();
    });
    ref.onDispose(() => _subscription.cancel());
  }

  late final StreamSubscription<TokenPair?> _subscription;
}

/// The wide-width landing for a cold-opened `/thread/:id`: resolve its parent
/// channel, then hand off to the shell with the thread docked rather than
/// showing the modal (UX1). A spinner covers the one-frame resolve; if the
/// parent cannot be resolved (offline, or a thread whose parent is gone) it
/// falls back to the thread on its own, exactly what the modal route showed.
class _ThreadDockRedirect extends ConsumerWidget {
  const _ThreadDockRedirect({required this.threadId});

  final String threadId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(threadParentProvider(threadId))
        .when(
          loading: () => const _RedirectSpinner(),
          error: (_, _) => ThreadScreen(channelId: threadId),
          data: (parent) {
            final parentChannelId = parent.parentChannelId;
            if (parentChannelId == null) {
              return ThreadScreen(channelId: threadId);
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              dockThread(
                ProviderScope.containerOf(context, listen: false),
                threadId,
              );
              context.go(Routes.channel(parentChannelId));
            });
            return const _RedirectSpinner();
          },
        );
  }
}

class _RedirectSpinner extends StatelessWidget {
  const _RedirectSpinner();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
