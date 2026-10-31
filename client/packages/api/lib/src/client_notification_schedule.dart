// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// The notification schedule: `/notifications/schedule` and its allow-lists
/// and snooze.
///
/// Split out of `client.dart` purely to stay under this repo's line budget.
extension SlimmApiNotificationSchedule on SlimmApi {
  /// Reads the caller's own schedule, or `null` if never configured.
  Future<NotificationSchedule?> notificationSchedule() async {
    final json = await send('GET', '/notifications/schedule');
    final raw = (json as Map<String, dynamic>)['schedule'];
    return raw == null
        ? null
        : NotificationSchedule.fromJson(raw as Map<String, dynamic>);
  }

  /// Replaces the caller's own timezone, off-hours mode and weekly windows.
  /// Never touches `snoozeUntil` or either allow-list.
  Future<NotificationSchedule> setNotificationSchedule({
    required String timezone,
    required OffHoursMode offHoursMode,
    required List<NotificationScheduleDay> days,
  }) async {
    final json = await send(
      'PUT',
      '/notifications/schedule',
      body: {
        'timezone': timezone,
        'off_hours_mode': offHoursMode.wire,
        'days': days.map((d) => d.toJson()).toList(growable: false),
      },
    );
    final raw = (json as Map<String, dynamic>)['schedule'];
    return NotificationSchedule.fromJson(raw as Map<String, dynamic>);
  }

  /// Turns the schedule off entirely, back to never configured.
  Future<void> clearNotificationSchedule() =>
      send('DELETE', '/notifications/schedule', expectNoContent: true);

  /// The member card's "notify me about this person off-hours" action.
  Future<void> addNotificationScheduleAllowedUser(String userId) => send(
        'PUT',
        '/notifications/schedule/allowed-users/$userId',
        expectNoContent: true,
      );

  Future<void> removeNotificationScheduleAllowedUser(String userId) => send(
        'DELETE',
        '/notifications/schedule/allowed-users/$userId',
        expectNoContent: true,
      );

  /// The channel menu's "notify me off-hours here" action.
  Future<void> addNotificationScheduleAllowedChannel(String channelId) => send(
        'PUT',
        '/notifications/schedule/allowed-channels/$channelId',
        expectNoContent: true,
      );

  Future<void> removeNotificationScheduleAllowedChannel(String channelId) =>
      send(
        'DELETE',
        '/notifications/schedule/allowed-channels/$channelId',
        expectNoContent: true,
      );

  /// Pauses notifications until [untilMs] (epoch milliseconds) - the
  /// concrete deadline for whichever of Slack's 30m/1h/until-tomorrow was
  /// chosen; only the caller knows the account's own local midnight for the
  /// last of those.
  Future<int?> setNotificationSnooze(int untilMs) async {
    final json = await send(
      'PUT',
      '/notifications/schedule/snooze',
      body: {'until_ms': untilMs},
    );
    return (json as Map<String, dynamic>)['snooze_until'] as int?;
  }

  /// Ends an active snooze early.
  Future<void> clearNotificationSnooze() => send(
        'DELETE',
        '/notifications/schedule/snooze',
        expectNoContent: true,
      );
}
