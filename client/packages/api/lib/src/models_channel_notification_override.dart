// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A per-(caller, channel) override of the account-wide notification
/// preference (`NotificationPreference`, `models_notification_preference.dart`):
/// mute one channel, narrow it to mentions only, or ask for every message, while every other
/// channel keeps following the account default.
///
/// Split out of models.dart purely to stay under this repo's line budget.
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
