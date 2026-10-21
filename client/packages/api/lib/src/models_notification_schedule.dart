// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notification schedule (`docs/decisions/0033-notification-schedule.md`): a per-weekday
/// on-hours window, an off-hours policy, two allow-lists and an optional snooze.
library;

/// What breaks through during an off-hours window.
enum OffHoursMode {
  /// Mentions and DMs still notify - the default, and what a quiet-hours
  /// account migrated to this schedule keeps on upgrade.
  mentions,

  /// Nothing notifies at all off hours, including a mention or a DM, unless
  /// an allow-list says otherwise.
  nothing;

  String get wire => name;

  static OffHoursMode parse(String value) => switch (value) {
        'nothing' => OffHoursMode.nothing,
        _ => OffHoursMode.mentions,
      };
}

/// One weekday's on-hours window, in the schedule's own local time.
/// [weekday] is 0 (Monday) to 6 (Sunday), jiff's own numbering, matched here
/// so the wire and the server never need a translation table.
class NotificationScheduleDay {
  const NotificationScheduleDay({
    required this.weekday,
    required this.startMinute,
    required this.endMinute,
  });

  final int weekday;
  final int startMinute;
  final int endMinute;

  factory NotificationScheduleDay.fromJson(Map<String, dynamic> json) =>
      NotificationScheduleDay(
        weekday: json['weekday'] as int,
        startMinute: json['start_minute'] as int,
        endMinute: json['end_minute'] as int,
      );

  Map<String, dynamic> toJson() => {
        'weekday': weekday,
        'start_minute': startMinute,
        'end_minute': endMinute,
      };
}

/// The caller's own full schedule, or `null` if never configured - distinct
/// from a schedule with every weekday empty, which is a real, reachable
/// state (see `store/notification_schedule.rs`'s own doc comment).
class NotificationSchedule {
  const NotificationSchedule({
    required this.timezone,
    required this.days,
    required this.offHoursMode,
    required this.snoozeUntil,
    required this.allowedUserIds,
    required this.allowedChannelIds,
  });

  final String timezone;
  final List<NotificationScheduleDay> days;
  final OffHoursMode offHoursMode;
  final int? snoozeUntil;
  final List<String> allowedUserIds;
  final List<String> allowedChannelIds;

  /// [days] indexed by weekday, `null` for a day with no on-hours window.
  List<NotificationScheduleDay?> get byWeekday {
    final slots = List<NotificationScheduleDay?>.filled(7, null);
    for (final day in days) {
      slots[day.weekday] = day;
    }
    return slots;
  }

  bool get isSnoozed =>
      snoozeUntil != null &&
      snoozeUntil! > DateTime.now().millisecondsSinceEpoch;

  factory NotificationSchedule.fromJson(Map<String, dynamic> json) =>
      NotificationSchedule(
        timezone: json['timezone'] as String,
        days: (json['days'] as List<dynamic>)
            .map(
              (e) =>
                  NotificationScheduleDay.fromJson(e as Map<String, dynamic>),
            )
            .toList(growable: false),
        offHoursMode: OffHoursMode.parse(json['off_hours_mode'] as String),
        snoozeUntil: json['snooze_until'] as int?,
        allowedUserIds:
            (json['allowed_user_ids'] as List<dynamic>).cast<String>(),
        allowedChannelIds:
            (json['allowed_channel_ids'] as List<dynamic>).cast<String>(),
      );
}
