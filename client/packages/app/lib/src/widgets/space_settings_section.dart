// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everything that changes the Space rather than the person: the reports
/// queue, invites, roles, channel permission overwrites, who can join, and
/// the Space's custom emoji - as the pane groups [SpaceSettingsScreen]'s
/// nav-and-pane scaffold renders.
///
/// This used to be a single scroll of chevron rows, each pushing a separate
/// admin route, which read as a different app from personal settings'
/// nav-and-pane split and cost a full navigation to glance at any one area.
/// The panes embed the same admin surfaces beside the nav on a wide window;
/// each still names its route as [SettingsPane.compactRoute], so a phone
/// keeps the real, deep-linkable screens and the routes stay reachable.
///
/// Configuration used to also carry Performance, Analytics, Storage and
/// Server metrics, which mixed what the Space *is* with how it is *running*
/// under one heading (owner backlog request). Those four now sit under
/// their own `Server` heading instead; every one of them is gated on
/// MANAGE_SERVER, so the group appears and disappears as a unit exactly the
/// way Addons already does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../permissions.dart';
import '../providers/admin_providers.dart';
import '../providers/channel_permissions.dart';
import '../routing/routes.dart';
import '../screens/admin/account_recovery_screen.dart';
import '../screens/admin/analytics_screen.dart';
import '../screens/admin/bots_screen.dart';
import '../screens/admin/channel_permissions_screen.dart';
import '../screens/admin/dock_screen.dart';
import '../screens/admin/emoji_screen.dart';
import '../screens/admin/invites_screen.dart';
import '../screens/admin/performance_screen.dart';
import '../screens/admin/removed_members_screen.dart';
import '../screens/admin/reports_screen.dart';
import '../screens/admin/roles_screen.dart';
import '../screens/admin/server_metrics_screen.dart';
import '../screens/admin/storage_screen.dart';
import '../screens/admin/webhooks_screen.dart';
import 'settings_panes.dart';
import '../action_labels.dart';

/// Whether [permissions] carries any of the bits that gate a pane here.
/// Shared with the rail's Space menu, which must hide its own entry point on
/// exactly this condition rather than open onto a screen with nothing on it.
bool spaceSettingsReachable(int permissions) =>
    permissions.hasPermission(Perm.manageMessages) ||
    permissions.hasPermission(Perm.viewModerationHistory) ||
    permissions.hasPermission(Perm.createInvite) ||
    permissions.hasPermission(Perm.manageRoles) ||
    permissions.hasPermission(Perm.manageServer) ||
    permissions.hasPermission(Perm.manageChannels) ||
    permissions.hasPermission(Perm.banMembers);

/// Each pane is gated on the server bit its surface requires, per `GET /me`'s
/// base permissions, rather than shown and left to answer 403: a member
/// without MANAGE_ROLES should not see role editing exists at all.
/// A group with none of its panes visible is dropped whole.
List<SettingsPaneGroup> spaceSettingsPaneGroups(
  BuildContext context,
  WidgetRef ref,
) {
  final permissions = ref.watch(myPermissionsProvider);
  final canModerate =
      permissions.hasPermission(Perm.manageMessages) ||
      permissions.hasPermission(Perm.viewModerationHistory);
  final canInvite = permissions.hasPermission(Perm.createInvite);
  final canManageRoles = permissions.hasPermission(Perm.manageRoles);
  final canManageServer = permissions.hasPermission(Perm.manageServer);
  final canBan = permissions.hasPermission(Perm.banMembers);
  final canIssueResetCodes = permissions.hasPermission(Perm.administrator);
  // Unlike Roles (deployment-wide), this pane also opens via one overwrite.
  final visibleChannels =
      ref.watch(myVisibleChannelsProvider).valueOrNull ?? const [];
  final canManageRolesAnywhere =
      canManageRoles ||
      visibleChannels.any(
        (c) => (c.permissions ?? 0).hasPermission(Perm.manageRoles),
      );

  final groups = [
    SettingsPaneGroup(
      label: 'Moderation',
      panes: [
        if (canModerate)
          SettingsPane(
            id: 'reports',
            label: 'Reports',
            icon: AppIcons.report,
            compactRoute: Routes.adminReports,
            // The queue pages its own list; see ReportsScreen's same pair.
            scrollable: false,
            padding: EdgeInsets.zero,
            builder: (_) =>
                ReportsPane(historyOnly: reportsHistoryOnly(permissions)),
          ),
        if (canBan)
          SettingsPane(
            id: 'removed-members',
            label: 'Removed members',
            icon: AppIcons.signOut,
            compactRoute: Routes.adminRemovedMembers,
            builder: (_) => const RemovedMembersPane(),
          ),
      ],
    ),
    SettingsPaneGroup(
      label: 'Access',
      panes: [
        // MANAGE_SERVER too: who may join lives in this pane now, gated inside.
        if (canInvite || canManageServer)
          SettingsPane(
            id: 'invites',
            label: 'Invites',
            icon: AppIcons.invite,
            compactRoute: Routes.adminInvites,
            builder: (_) => const InvitesPane(),
          ),
        // ADMINISTRATOR, matching the route it opens; see AccountRecoveryPane.
        if (canIssueResetCodes)
          SettingsPane(
            id: 'account-recovery',
            label: 'Account recovery',
            icon: AppIcons.resetCode,
            compactRoute: Routes.adminAccountRecovery,
            builder: (_) => const AccountRecoveryPane(),
          ),
      ],
    ),
    SettingsPaneGroup(
      label: 'Configuration',
      panes: [
        if (canManageRoles)
          SettingsPane(
            id: 'roles',
            label: 'Roles',
            icon: AppIcons.shield,
            compactRoute: Routes.adminRoles,
            actions: [rolesPaneCreateAction(context)],
            // RolesPane lays out its own two panes, which a ListView cannot bound.
            scrollable: false,
            builder: (_) => const RolesPane(),
          ),
        if (canManageRolesAnywhere)
          SettingsPane(
            id: 'channel-permissions',
            label: 'Channel permissions',
            icon: AppIcons.permissions,
            compactRoute: Routes.adminOverwrites,
            scrollable: false,
            builder: (_) => const ChannelPermissionsPane(),
          ),
        if (canManageServer)
          SettingsPane(
            id: 'emoji',
            label: 'Emoji',
            icon: AppIcons.smile,
            compactRoute: Routes.adminEmoji,
            builder: (_) => const EmojiPane(),
          ),
      ],
    ),
    // What the Space is above; how it is running below - see the library doc.
    SettingsPaneGroup(
      label: ActionLabels.operationsGroup,
      panes: [
        if (canManageServer)
          SettingsPane(
            id: 'performance',
            label: ActionLabels.retentionAndLimits,
            icon: AppIcons.performance,
            compactRoute: Routes.adminPerformance,
            builder: (_) => const PerformancePane(),
          ),
        if (canManageServer)
          SettingsPane(
            id: 'analytics',
            label: 'Analytics',
            icon: AppIcons.analytics,
            compactRoute: Routes.adminAnalytics,
            builder: (_) => const AnalyticsPane(),
          ),
        if (canManageServer)
          SettingsPane(
            id: 'storage',
            label: 'Storage',
            icon: AppIcons.storage,
            compactRoute: Routes.adminStorage,
            builder: (_) => const StoragePane(),
          ),
        if (canManageServer)
          SettingsPane(
            id: 'server-metrics',
            label: 'Server metrics',
            icon: AppIcons.requestLatency,
            compactRoute: Routes.adminServerMetrics,
            builder: (_) => const ServerMetricsPane(),
          ),
      ],
    ),
    // Both extend the Space from outside it, rather than configuring it.
    SettingsPaneGroup(
      label: 'Addons',
      panes: [
        if (canManageServer)
          SettingsPane(
            id: 'dock',
            label: 'Dock',
            icon: AppIcons.dock,
            compactRoute: Routes.adminDock,
            builder: (_) => const DockPane(),
          ),
        if (canManageServer)
          SettingsPane(
            id: 'bots',
            label: 'Bots',
            icon: AppIcons.code,
            compactRoute: Routes.adminBots,
            builder: (_) => const BotsPane(),
          ),
        if (canManageServer)
          SettingsPane(
            id: 'webhooks',
            label: 'Webhooks',
            icon: AppIcons.webhook,
            compactRoute: Routes.adminWebhooks,
            builder: (_) => const WebhooksPane(),
          ),
      ],
    ),
  ];
  return [
    for (final group in groups)
      if (group.panes.isNotEmpty) group,
  ];
}
