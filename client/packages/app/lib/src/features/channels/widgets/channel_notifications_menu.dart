// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A conversation row's one Notifications entry, and the submenu it opens with
/// mute, mentions only and off hours.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/channel_notification_overrides_controller.dart';
import 'row_menu_notifications.dart';

/// The short word the Notifications entry shows beside its name.
String notificationStateLabel(api.NotificationPreference? current) =>
    switch (current) {
      api.NotificationPreference.nothing => 'Muted',
      api.NotificationPreference.mentions => 'Mentions',
      api.NotificationPreference.everything => 'All',
      null => 'Default',
    };

/// The one Notifications row, opening the mute, mentions and off-hours choices as a submenu of the row menu.
Widget notificationsMenuItem(
  BuildContext context,
  ProviderContainer container,
  String channelId,
  VoidCallback close, {
  required String muteLabel,
  api.NotificationPreference? channelDefault,
  bool voiceChannel = false,
}) {
  final tokens = Theme.of(context).extension<AppTokens>()!;
  final current = container
      .read(channelNotificationOverridesProvider)
      .overrideFor(channelId);
  return AppSubmenuItem(
    label: 'Notifications',
    leading: current == api.NotificationPreference.nothing
        ? AppIcons.notificationsOff
        : AppIcons.notificationsOn,
    trailing: Text(
      notificationStateLabel(current),
      style: AppText.caption.copyWith(color: tokens.textSecondary),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    itemsBuilder: (_) => notificationMenuItems(
      context,
      container,
      channelId,
      close,
      muteLabel: muteLabel,
      channelDefault: channelDefault,
      voiceChannel: voiceChannel,
    ),
  );
}
