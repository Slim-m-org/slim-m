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
import '../../voice/providers/voice_notification_controller.dart';
import '../../settings/providers/notification_schedule_controller.dart';
import '../providers/dms.dart' show dmChannelKind;
import '../../../providers/providers.dart';
import '../../../widgets/app_snackbar.dart';
import '../../messages/widgets/mark_read_action.dart';
import '../../messages/widgets/mark_unread_action.dart';
import '../../../widgets/run_guarded.dart';
import '../providers/channel_latest_message_at.dart';
import '../../settings/providers/settings_actions.dart';

Future<void> _say(
  BuildContext context,
  String whatFailed,
  Future<void> Function() action,
) async {
  final failure = await runGuarded(whatFailed: whatFailed, action: action);
  if (failure != null && context.mounted) showAppSnackbar(context, failure);
}

/// "Mark as read" while [channel] shows a badge, otherwise "Mark as unread" (only when the newest message is under an hour old); never both.
AppMenuItem? markReadStateMenuItem(
  BuildContext context,
  ProviderContainer container,
  Channel channel,
  VoidCallback close, {
  required bool isDm,
}) {
  final showsUnread = channelShowsUnread(
    channel,
    container.read(channelNotificationOverridesProvider).effectiveFor(channel),
    isDm: isDm,
  );
  final latestAt = container
      .read(channelLatestMessageAtProvider(channel.id))
      .valueOrNull;
  final now = container.read(markUnreadClockProvider)();
  // Marking a quiet channel unread brings back nothing worth returning to.
  if (!showsUnread && !offersMarkUnread(latestAt, now)) return null;
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
        overrides.effectiveFor(channel),
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
                    overrides.effectiveFor(channel),
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

Future<void> _set(
  ChannelNotificationOverridesController notifier,
  String channelId,
  api.NotificationPreference preference,
) => switch (preference) {
  api.NotificationPreference.nothing => notifier.mute(channelId),
  api.NotificationPreference.mentions => notifier.mentionsOnly(channelId),
  api.NotificationPreference.everything => notifier.everything(channelId),
};

/// "Default (Mentions)" style wording for a channel's own default level.
String channelDefaultMenuLabel(api.NotificationPreference level) =>
    switch (level) {
      api.NotificationPreference.nothing => 'Default (Muted)',
      api.NotificationPreference.mentions => 'Default (Mentions)',
      api.NotificationPreference.everything => 'Default (All messages)',
    };

/// Mute, mentions only, all messages and off-hours entries for [channelId], led by the channel's own default ([channelDefault]) which clears this account's choice.
/// Read when the menu opens, not watched; the row already rebuilds on live changes.
List<Widget> notificationMenuItems(
  BuildContext context,
  ProviderContainer container,
  String channelId,
  VoidCallback close, {
  required String muteLabel,
  api.NotificationPreference? channelDefault,
  bool voiceChannel = false,
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
            : _set(notifier, channelId, preference),
      ),
    );
  }

  void toggleOffHours() {
    close();
    final client = container.read(settingsActionsProvider);
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
    if (channelDefault != null)
      AppMenuItem(
        label: channelDefaultMenuLabel(channelDefault),
        leading: channelDefault == api.NotificationPreference.nothing
            ? AppIcons.notificationsOff
            : AppIcons.notificationsOn,
        selected: current == null,
        onTap: () {
          close();
          if (current == null) return;
          final notifier = container.read(
            channelNotificationOverridesProvider.notifier,
          );
          unawaited(
            _say(
              context,
              'change this conversation\'s notifications',
              () => notifier.clear(channelId),
            ),
          );
        },
      ),
    AppMenuItem(
      label: 'All messages',
      leading: AppIcons.notificationsOn,
      selected: current == api.NotificationPreference.everything,
      onTap: () => toggle(api.NotificationPreference.everything),
    ),
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
    if (voiceChannel)
      ...voiceNotificationMenuItems(context, container, channelId, close),
  ];
}

/// Opt-in notices for a voice channel's call: when it starts, on every join, when someone streams.
/// Choosing the one already on turns it off.
List<Widget> voiceNotificationMenuItems(
  BuildContext context,
  ProviderContainer container,
  String channelId,
  VoidCallback close,
) {
  final choice = container
      .read(voiceNotificationProvider)
      .forChannel(channelId);

  void change(Future<void> Function(VoiceNotificationController) action) {
    close();
    final notifier = container.read(voiceNotificationProvider.notifier);
    unawaited(
      _say(
        context,
        'change this channel\'s call notifications',
        () => action(notifier),
      ),
    );
  }

  AppMenuItem joins(String label, api.VoiceJoinMode mode) => AppMenuItem(
    label: label,
    leading: AppIcons.voice,
    selected: choice.joins == mode,
    onTap: () => change(
      (n) => n.setJoins(
        channelId,
        choice.joins == mode ? api.VoiceJoinMode.off : mode,
      ),
    ),
  );

  return [
    const AppMenuDivider(),
    joins('Notify when a call starts', api.VoiceJoinMode.first),
    joins('Notify on every join', api.VoiceJoinMode.every),
    AppMenuItem(
      label: 'Notify when someone streams',
      leading: AppIcons.screenShare,
      selected: choice.streams,
      onTap: () =>
          change((n) => n.setStreams(channelId, streams: !choice.streams)),
    ),
  ];
}
