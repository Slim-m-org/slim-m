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

import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../../channels/providers/channel_permissions.dart';
import '../../../routing/routes.dart';
import 'admin/account_recovery_screen.dart';
import 'admin/analytics_screen.dart';
import 'admin/bots_screen.dart';
import 'admin/channel_permissions_screen.dart';
import 'admin/dock_screen.dart';
import 'admin/emoji_screen.dart';
import 'admin/invites_screen.dart';
import 'admin/performance_screen.dart';
import 'admin/space_voice_screen.dart';
import 'admin/removed_members_screen.dart';
import 'admin/reports_screen.dart';
import 'admin/roles_screen.dart';
import 'admin/server_metrics_screen.dart';
import 'admin/storage_screen.dart';
import 'admin/webhooks_screen.dart';
import '../widgets/settings_panes.dart';
import '../../../action_labels.dart';

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
  // Unlike Roles (deployment-wide), this pane also opens via one overwrite.
  final visibleChannels =
      ref.watch(myVisibleChannelsProvider).valueOrNull ?? const [];
  final access = _SpaceAccess(
    permissions,
    rolesViaOverwrite: visibleChannels.any(
      (c) => (c.permissions ?? 0).hasPermission(Perm.manageRoles),
    ),
  );

  final groups = [
    _moderationGroup(access),
    _accessGroup(access),
    _configurationGroup(access),
    _operationsGroup(access),
    _addonsGroup(access),
  ];
  return [
    for (final group in groups)
      if (group.panes.isNotEmpty) group,
  ];
}

/// The permission gates every pane group here is built from.
class _SpaceAccess {
  _SpaceAccess(this.permissions, {required this.rolesViaOverwrite});

  final int permissions;
  final bool rolesViaOverwrite;

  bool get canModerate =>
      permissions.hasPermission(Perm.manageMessages) ||
      permissions.hasPermission(Perm.viewModerationHistory);
  bool get canInvite => permissions.hasPermission(Perm.createInvite);
  bool get canManageRoles => permissions.hasPermission(Perm.manageRoles);
  bool get canManageServer => permissions.hasPermission(Perm.manageServer);
  bool get canBan => permissions.hasPermission(Perm.banMembers);
  bool get canIssueResetCodes => permissions.hasPermission(Perm.administrator);
  bool get canManageRolesAnywhere => canManageRoles || rolesViaOverwrite;
}

SettingsPaneGroup _moderationGroup(_SpaceAccess access) {
  return SettingsPaneGroup(
    label: 'Moderation',
    panes: [
      if (access.canModerate)
        SettingsPane(
          id: 'reports',
          label: 'Reports',
          icon: AppIcons.report,
          compactRoute: Routes.adminReports,
          // The queue pages its own list; see ReportsScreen's same pair.
          scrollable: false,
          builder: (_) =>
              ReportsPane(historyOnly: reportsHistoryOnly(access.permissions)),
        ),
      if (access.canBan)
        SettingsPane(
          id: 'removed-members',
          wide: true,
          label: 'Removed members',
          icon: AppIcons.signOut,
          compactRoute: Routes.adminRemovedMembers,
          builder: (_) => const RemovedMembersPane(),
        ),
    ],
  );
}

SettingsPaneGroup _accessGroup(_SpaceAccess access) {
  return SettingsPaneGroup(
    label: 'Access',
    panes: [
      // MANAGE_SERVER too: who may join lives in this pane now, gated inside.
      if (access.canInvite || access.canManageServer)
        SettingsPane(
          id: 'invites',
          wide: true,
          label: 'Invites',
          icon: AppIcons.invite,
          compactRoute: Routes.adminInvites,
          builder: (_) => const InvitesPane(),
        ),
      // ADMINISTRATOR, matching the route it opens; see AccountRecoveryPane.
      if (access.canIssueResetCodes)
        SettingsPane(
          id: 'account-recovery',
          label: 'Account recovery',
          icon: AppIcons.resetCode,
          compactRoute: Routes.adminAccountRecovery,
          builder: (_) => const AccountRecoveryPane(),
        ),
    ],
  );
}

SettingsPaneGroup _configurationGroup(_SpaceAccess access) {
  return SettingsPaneGroup(
    label: 'Configuration',
    panes: [
      if (access.canManageRoles)
        SettingsPane(
          id: 'roles',
          label: 'Roles',
          icon: AppIcons.shield,
          compactRoute: Routes.adminRoles,
          wide: true,
          // RolesPane lays out its own two panes, which a ListView cannot bound.
          scrollable: false,
          builder: (_) => const RolesPane(),
        ),
      if (access.canManageRolesAnywhere)
        SettingsPane(
          id: 'channel-permissions',
          wide: true,
          label: 'Channel permissions',
          icon: AppIcons.permissions,
          compactRoute: Routes.adminOverwrites,
          scrollable: false,
          builder: (_) => const ChannelPermissionsPane(),
        ),
      if (access.canManageServer)
        SettingsPane(
          id: 'emoji',
          wide: true,
          label: 'Emoji',
          icon: AppIcons.smile,
          compactRoute: Routes.adminEmoji,
          builder: (_) => const EmojiPane(),
        ),
    ],
  );
}

// What the Space is above; how it is running below - see the library doc.
SettingsPaneGroup _operationsGroup(_SpaceAccess access) {
  return SettingsPaneGroup(
    label: ActionLabels.operationsGroup,
    panes: [
      if (access.canManageServer)
        SettingsPane(
          id: 'space-voice',
          label: ActionLabels.spaceVoice,
          icon: AppIcons.voice,
          compactRoute: Routes.adminSpaceVoice,
          builder: (_) => const SpaceVoicePane(),
        ),
      if (access.canManageServer)
        SettingsPane(
          id: 'performance',
          label: ActionLabels.retentionAndLimits,
          icon: AppIcons.performance,
          compactRoute: Routes.adminPerformance,
          builder: (_) => const PerformancePane(),
        ),
      if (access.canManageServer)
        SettingsPane(
          id: 'analytics',
          label: 'Analytics',
          icon: AppIcons.analytics,
          compactRoute: Routes.adminAnalytics,
          builder: (_) => const AnalyticsPane(),
        ),
      if (access.canManageServer)
        SettingsPane(
          id: 'storage',
          label: 'Storage',
          icon: AppIcons.storage,
          compactRoute: Routes.adminStorage,
          builder: (_) => const StoragePane(),
        ),
      if (access.canManageServer)
        SettingsPane(
          id: 'server-metrics',
          label: 'Server metrics',
          icon: AppIcons.requestLatency,
          compactRoute: Routes.adminServerMetrics,
          builder: (_) => const ServerMetricsPane(),
        ),
    ],
  );
}

// Both extend the Space from outside it, rather than configuring it.
SettingsPaneGroup _addonsGroup(_SpaceAccess access) {
  return SettingsPaneGroup(
    label: 'Addons',
    panes: [
      if (access.canManageServer)
        SettingsPane(
          id: 'dock',
          label: 'Modules',
          icon: AppIcons.dock,
          compactRoute: Routes.adminDock,
          builder: (_) => const DockPane(),
        ),
      if (access.canManageServer)
        SettingsPane(
          id: 'bots',
          label: 'Bots',
          icon: AppIcons.botAction,
          compactRoute: Routes.adminBots,
          builder: (_) => const BotsPane(),
        ),
      if (access.canManageServer)
        SettingsPane(
          id: 'webhooks',
          label: 'Webhooks',
          icon: AppIcons.webhook,
          compactRoute: Routes.adminWebhooks,
          builder: (_) => const WebhooksPane(),
        ),
    ],
  );
}
