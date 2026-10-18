// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings: one place for a channel's name, topic, permission
/// overwrites, and deletion, replacing the two disconnected surfaces the
/// kebab used to open separately - a "manage channel" sheet (name, topic,
/// delete) and a picker-first route into [ChannelPermissionsPane]. Reached
/// only through the channel row's own kebab/context menu
/// (`channel_row_menu.dart`), which now offers a single "Channel
/// settings..." entry gated on holding either MANAGE_CHANNELS or
/// MANAGE_ROLES rather than two separate entries each gated on its own bit.
///
/// A [modalPage] route (docs/design/desktop-vs-mobile.md rule 5, "a place
/// with its own nav or list you return to"): the permissions section alone
/// is a whole pane, well past what a sheet or dialog is meant to carry.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart' show Channel;

import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../../../routing/routes.dart';
import '../../settings/widgets/settings_notice.dart';
import '../../settings/screens/admin/channel_permissions_screen.dart';
import '../widgets/channel_settings_danger_zone.dart';
import '../widgets/channel_settings_default_notification_section.dart';
import '../widgets/channel_settings_general_section.dart';
import '../widgets/channel_settings_join_muted_section.dart';
import '../widgets/channel_settings_private_row.dart';
import '../widgets/channel_settings_retention_row.dart';
import '../widgets/channel_settings_rooms_section.dart';
import '../widgets/channel_settings_slow_mode_section.dart';
import '../../settings/screens/settings_screen_scaffold.dart';

/// What the row's kebab hands the route: the channel, and whether it was the
/// currently open one at the moment the menu opened.
///
/// [wasOpen] is captured there rather than read back out here because
/// `GoRouterState.of`/the router's own location changes to
/// [Routes.channelSettings] itself once this route is pushed - the same
/// cause, and the same fix, as `pinned_messages_sheet.dart`'s own doc
/// comment on capturing the current channel before opening.
class ChannelSettingsRouteArgs {
  const ChannelSettingsRouteArgs({
    required this.channel,
    required this.wasOpen,
  });

  final Channel channel;
  final bool wasOpen;
}

class ChannelSettingsScreen extends StatelessWidget {
  const ChannelSettingsScreen({super.key, this.args});

  /// Null only when opened cold from a pasted URL; every in-app path
  /// supplies it.
  final ChannelSettingsRouteArgs? args;

  @override
  Widget build(BuildContext context) {
    final args = this.args;
    if (args == null) {
      return const SettingsScreenScaffold(
        title: 'Channel settings',
        backTooltip: 'Back to channels',
        backFallback: Routes.channels,
        child: SettingsNotice(message: 'No channel was selected.'),
      );
    }
    return SettingsScreenScaffold(
      title: 'Channel settings',
      backTooltip: 'Back to ${args.channel.name}',
      backFallback: Routes.channel(args.channel.id),
      child: ChannelSettingsPane(channel: args.channel, wasOpen: args.wasOpen),
    );
  }
}

/// The gated section stack, top to bottom: general (name, topic) for a
/// caller holding MANAGE_CHANNELS, permission overwrites for one holding
/// MANAGE_ROLES, then a danger zone (delete) back under MANAGE_CHANNELS.
///
/// These are the same coarse, deployment-wide bits the row's own kebab
/// already gated each half on before this screen existed
/// (`channel_row_menu.dart`), so a member holding only one sees exactly the
/// section their old, separate entry point would have shown them - never an
/// empty frame, and never the other half's controls.
class ChannelSettingsPane extends ConsumerWidget {
  const ChannelSettingsPane({
    super.key,
    required this.channel,
    required this.wasOpen,
  });

  final Channel channel;
  final bool wasOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(myPermissionsProvider);
    final canManageChannels = permissions.hasPermission(Perm.manageChannels);
    final canManageRoles = permissions.hasPermission(Perm.manageRoles);
    final canManageServer = permissions.hasPermission(Perm.manageServer);

    if (!canManageChannels && !canManageRoles) {
      return const SettingsNotice(
        message: "None of your roles grant access to this channel's settings.",
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One card: the owner read three separate cards as one list of general settings.
        if (canManageChannels)
          ChannelGeneralSection(
            channel: channel,
            rows: [
              if (canManageRoles) ChannelPrivateRow(channel: channel),
              ChannelSlowModeSection(channel: channel),
              if (channel.kind != 'dm')
                ChannelDefaultNotificationSection(channel: channel),
              if (canManageServer && channel.kind != 'dm')
                ChannelRetentionRow(channelId: channel.id),
              if (channel.kind == 'voice')
                ChannelJoinMutedSection(channel: channel),
              if (channel.kind == 'voice')
                ChannelRoomsSection(channel: channel),
            ],
          ),
        if (canManageRoles)
          ChannelPermissionsPane(initialChannel: channel, lockChannel: true),
        if (canManageChannels)
          ChannelDangerZoneSection(channel: channel, wasOpen: wasOpen),
      ],
    );
  }
}
