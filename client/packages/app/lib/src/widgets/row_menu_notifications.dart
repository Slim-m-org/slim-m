// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notification and read-state entries a channel row and a DM row share.
///
/// The menu is dismissed before the server answers, so a refusal is said on
/// the row's own context through [runGuarded]'s sentence, which outlives it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/channel_notification_overrides_controller.dart';
import '../providers/notification_schedule_controller.dart';
import '../providers/dms.dart' show dmChannelKind;
import '../providers/providers.dart';
import 'app_snackbar.dart';
import 'mark_read_action.dart';
import 'mark_unread_action.dart';
import 'run_guarded.dart';

Future<void> _say(
  BuildContext context,
  String whatFailed,
  Future<void> Function() action,
) async {
  final failure = await runGuarded(whatFailed: whatFailed, action: action);
  if (failure != null && context.mounted) showAppSnackbar(context, failure);
}

/// "Mark as read" while [channel] shows a badge, otherwise "Mark as unread".
///
/// One slot, never both: the entry that would change nothing is not offered.
AppMenuItem markReadStateMenuItem(
  BuildContext context,
  ProviderContainer container,
  Channel channel,
  VoidCallback close, {
  required bool isDm,
}) {
  final showsUnread = channelShowsUnread(
    channel,
    container
        .read(channelNotificationOverridesProvider)
        .overrideFor(channel.id),
    isDm: isDm,
  );
  return AppMenuItem(
    label: showsUnread ? 'Mark as read' : 'Mark as unread',
    leading: showsUnread ? AppIcons.check : AppIcons.unread,
    onTap: () {
      close();
      unawaited(
        _say(
          context,
          showsUnread
              ? 'mark this conversation read'
              : 'mark this conversation unread',
          () => showsUnread
              ? markChannelsRead(container, [channel.id])
              : markChannelUnread(container, channel.id),
        ),
      );
    },
  );
}

/// "Mark all as read" over [channels], or null when none of them shows a badge.
///
/// One request for the lot, and one failure sentence rather than one per channel.
AppMenuItem? markAllReadMenuItem(
  BuildContext context,
  ProviderContainer container,
  Iterable<Channel> channels,
  VoidCallback close,
) {
  final overrides = container.read(channelNotificationOverridesProvider);
  final unreadIds = [
    for (final channel in channels)
      if (channelShowsUnread(
        channel,
        overrides.overrideFor(channel.id),
        isDm: false,
      ))
        channel.id,
  ];
  if (unreadIds.isEmpty) return null;
  return AppMenuItem(
    label: 'Mark all as read',
    leading: AppIcons.check,
    onTap: () {
      close();
      unawaited(
        _say(
          context,
          'mark these channels read',
          () => markChannelsRead(container, unreadIds),
        ),
      );
    },
  );
}

/// The space menu's Mark all as read. Always offered: the channels are read
/// when it is chosen, not watched while the menu is drawn, so the menu holds no
/// live query of every channel.
AppMenuItem markSpaceReadMenuItem(
  BuildContext context,
  ProviderContainer container,
  VoidCallback close,
) {
  return AppMenuItem(
    label: 'Mark all as read',
    leading: AppIcons.check,
    onTap: () {
      close();
      unawaited(
        _say(context, 'mark these channels read', () async {
          final store = await container.read(storeProvider.future);
          final channels = await store.watchRailChannels().first;
          final overrides = container.read(
            channelNotificationOverridesProvider,
          );
          final unreadIds = [
            for (final channel in channels)
              if (channel.kind != dmChannelKind &&
                  channelShowsUnread(
                    channel,
                    overrides.overrideFor(channel.id),
                    isDm: false,
                  ))
                channel.id,
          ];
          if (unreadIds.isNotEmpty) {
            await markChannelsRead(container, unreadIds);
          }
        }),
      );
    },
  );
}

/// Mute, mentions only and off-hours entries for [channelId].
///
/// Read fresh when the menu opens rather than watched: the row itself already
/// rebuilds on a live change, and an open menu need not react to one landing.
List<AppMenuItem> notificationMenuItems(
  BuildContext context,
  ProviderContainer container,
  String channelId,
  VoidCallback close, {
  required String muteLabel,
}) {
  final current = container
      .read(channelNotificationOverridesProvider)
      .overrideFor(channelId);
  final allowedOffHours =
      container
          .read(notificationScheduleProvider)
          .valueOrNull
          ?.allowedChannelIds
          .contains(channelId) ??
      false;

  void toggle(api.NotificationPreference preference) {
    close();
    final notifier = container.read(
      channelNotificationOverridesProvider.notifier,
    );
    unawaited(
      _say(
        context,
        'change this conversation\'s notifications',
        () => current == preference
            ? notifier.clear(channelId)
            : preference == api.NotificationPreference.nothing
            ? notifier.mute(channelId)
            : notifier.mentionsOnly(channelId),
      ),
    );
  }

  void toggleOffHours() {
    close();
    final client = container.read(apiProvider);
    unawaited(
      _say(
        context,
        'change off-hours notifications for this conversation',
        () async {
          await (allowedOffHours
              ? client.removeNotificationScheduleAllowedChannel(channelId)
              : client.addNotificationScheduleAllowedChannel(channelId));
          container.invalidate(notificationScheduleProvider);
        },
      ),
    );
  }

  return [
    AppMenuItem(
      label: muteLabel,
      leading: AppIcons.notificationsOff,
      selected: current == api.NotificationPreference.nothing,
      onTap: () => toggle(api.NotificationPreference.nothing),
    ),
    AppMenuItem(
      label: 'Mentions only',
      leading: AppIcons.mentions,
      selected: current == api.NotificationPreference.mentions,
      onTap: () => toggle(api.NotificationPreference.mentions),
    ),
    AppMenuItem(
      label: 'Notify me off hours',
      leading: AppIcons.notificationsOn,
      selected: allowedOffHours,
      onTap: toggleOffHours,
    ),
  ];
}
