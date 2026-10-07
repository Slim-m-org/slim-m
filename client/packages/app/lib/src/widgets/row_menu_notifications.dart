// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notification and mark-unread entries a channel row and a DM row share.
///
/// The menu is dismissed before the server answers, so a refusal is said on
/// the row's own context through [runGuarded]'s sentence, which outlives it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/channel_notification_overrides_controller.dart';
import '../providers/notification_schedule_controller.dart';
import '../providers/providers.dart';
import 'app_snackbar.dart';
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

/// "Mark as unread" for [channelId].
AppMenuItem markUnreadMenuItem(
  BuildContext context,
  ProviderContainer container,
  String channelId,
  VoidCallback close,
) => AppMenuItem(
  label: 'Mark as unread',
  leading: AppIcons.unread,
  onTap: () {
    close();
    unawaited(
      _say(
        context,
        'mark this conversation unread',
        () => markChannelUnread(container, channelId),
      ),
    );
  },
);

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
