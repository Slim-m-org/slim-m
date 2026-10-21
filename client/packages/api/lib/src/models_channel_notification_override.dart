// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A per-(caller, channel) override of the account-wide notification preference
/// (`NotificationPreference`): mute one channel, mentions only, or every message.
library;

import 'models_notification_preference.dart';

/// One channel's override, as `GET /notification-preferences/channels`
/// lists them and `PUT .../{channelId}` returns one.
class ChannelNotificationOverride {
  const ChannelNotificationOverride({
    required this.channelId,
    required this.preference,
  });

  final String channelId;

  final NotificationPreference preference;

  factory ChannelNotificationOverride.fromJson(Map<String, dynamic> json) =>
      ChannelNotificationOverride(
        channelId: json['channel_id'] as String,
        preference: NotificationPreference.parse(
          json['preference'] as String,
        ),
      );
}
