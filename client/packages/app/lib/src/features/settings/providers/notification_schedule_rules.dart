// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pure decision logic mirroring the server's
/// `notification_schedule::{Schedule::evaluate, degrade_for_off_hours}`, so
/// the foreground sound path (`notification_sound_controller.dart`) honours
/// the same off-hours policy push already enforces - kept apart from
/// Riverpod so it is testable with no provider container, the same split
/// `notification_sound_rules.dart` already uses.
///
/// Evaluated against this device's own local wall clock
/// ([DateTime.now]), not [api.NotificationSchedule.timezone]: the schedule
/// is set from the device's own zone in the first place (see
/// `docs/decisions/0033-notification-schedule.md`), and this client carries
/// no IANA time zone database to convert a *different* zone correctly. Push
/// is the authoritative, always-DST-correct answer regardless; this is only
/// ever a same-instant convenience for a chime that already landed.
library;

import 'package:slimm_api/api.dart' as api;

/// Mirrors `notification_schedule::OffHoursState` on the server.
enum OffHoursState { onHours, offMentionsAndDms, offNothing }

/// Whether `weekday`'s window (0 = Monday .. 6 = Sunday) starts today and
/// still covers `minute` - `DayWindow::covers_from_start`'s own Dart twin.
bool _coversFromStart(api.NotificationScheduleDay window, int minute) {
  if (window.startMinute < window.endMinute) {
    return minute >= window.startMinute && minute < window.endMinute;
  }
  return minute >= window.startMinute;
}

/// Whether `window`, which started the *previous* weekday, still covers
/// `minute` this morning - `DayWindow::tail_into_next_day`'s own Dart twin.
bool _tailIntoNextDay(api.NotificationScheduleDay window, int minute) {
  return window.startMinute > window.endMinute && minute < window.endMinute;
}

/// [Schedule::evaluate]'s own Dart twin, against `now` (defaults to
/// [DateTime.now]) rather than an epoch-millisecond instant converted
/// through a time zone - see this file's own doc comment for why.
OffHoursState evaluateNotificationSchedule(
  api.NotificationSchedule? schedule, {
  DateTime? now,
}) {
  if (schedule == null) return OffHoursState.onHours;
  final clock = now ?? DateTime.now();
  final snoozeUntil = schedule.snoozeUntil;
  if (snoozeUntil != null && clock.millisecondsSinceEpoch < snoozeUntil) {
    return OffHoursState.offNothing;
  }

  final byWeekday = schedule.byWeekday;
  final weekday = clock.weekday - DateTime.monday; // 0 = Monday .. 6 = Sunday
  final yesterday = (weekday + 6) % 7;
  final minute = clock.hour * 60 + clock.minute;

  final today = byWeekday[weekday];
  final onToday = today != null && _coversFromStart(today, minute);
  final priorDay = byWeekday[yesterday];
  final onFromYesterday =
      priorDay != null && _tailIntoNextDay(priorDay, minute);
  if (onToday || onFromYesterday) return OffHoursState.onHours;

  return schedule.offHoursMode == api.OffHoursMode.nothing
      ? OffHoursState.offNothing
      : OffHoursState.offMentionsAndDms;
}

/// `degrade_for_off_hours`'s own Dart twin, folded straight into a boolean
/// gate rather than a re-derived [api.NotificationPreference]: the sound
/// path's own [isDm]/[mentionsSelf] test already plays the role the
/// server's `mentioned`/`is_dm` check does, so there is no separate
/// preference value to hand back here.
///
/// ANDed with `channelEarnsASound` at the call site, never in place of it:
/// this is only the schedule's own axis (off hours, allow-lists), and an
/// explicit account or channel mute stays a stronger, separate veto exactly
/// as it is server-side.
bool scheduleEarnsASound({
  required OffHoursState state,
  required bool channelAllowed,
  required bool authorAllowed,
  required bool isDm,
  required bool mentionsSelf,
}) {
  if (channelAllowed) return true;
  return switch (state) {
    OffHoursState.onHours => true,
    OffHoursState.offMentionsAndDms => isDm || mentionsSelf,
    OffHoursState.offNothing => authorAllowed && (isDm || mentionsSelf),
  };
}
