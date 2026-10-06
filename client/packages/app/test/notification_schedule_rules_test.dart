// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dart twin of the server's `notification_schedule.rs` tests: window,
/// midnight wrap, weekday numbering, snooze, both off-hours modes and the
/// allow-lists.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/notification_schedule_rules.dart';

api.NotificationSchedule _schedule({
  required List<api.NotificationScheduleDay> days,
  api.OffHoursMode mode = api.OffHoursMode.mentions,
  int? snoozeUntil,
}) => api.NotificationSchedule(
  timezone: 'UTC',
  days: days,
  offHoursMode: mode,
  snoozeUntil: snoozeUntil,
  allowedUserIds: const [],
  allowedChannelIds: const [],
);

api.NotificationScheduleDay _day(int weekday, int start, int end) =>
    api.NotificationScheduleDay(
      weekday: weekday,
      startMinute: start,
      endMinute: end,
    );

const _friday = 4;
const _sunday = 6;

void main() {
  group('evaluateNotificationSchedule', () {
    test('no schedule is always on hours', () {
      expect(
        evaluateNotificationSchedule(null, now: DateTime(2024, 3, 8, 3)),
        OffHoursState.onHours,
      );
    });

    test('a same-day window covers its start and not its end', () {
      final schedule = _schedule(days: [_day(_friday, 9 * 60, 17 * 60)]);
      OffHoursState at(int h, int m) => evaluateNotificationSchedule(
        schedule,
        now: DateTime(2024, 3, 8, h, m),
      );
      expect(at(9, 0), OffHoursState.onHours);
      expect(at(16, 59), OffHoursState.onHours);
      expect(at(17, 0), OffHoursState.offMentionsAndDms);
      expect(at(8, 59), OffHoursState.offMentionsAndDms);
    });

    test('a weekday with no window is off hours all day', () {
      final schedule = _schedule(days: [_day(_friday, 0, 23 * 60)]);
      expect(
        evaluateNotificationSchedule(schedule, now: DateTime(2024, 3, 10, 12)),
        OffHoursState.offMentionsAndDms,
      );
    });

    test('a window crossing midnight covers the next morning only', () {
      final schedule = _schedule(days: [_day(_friday, 22 * 60, 2 * 60)]);
      OffHoursState at(int day, int h) => evaluateNotificationSchedule(
        schedule,
        now: DateTime(2024, 3, day, h),
      );
      expect(at(8, 23), OffHoursState.onHours);
      expect(at(9, 1), OffHoursState.onHours);
      expect(at(9, 3), OffHoursState.offMentionsAndDms);
      expect(at(8, 21), OffHoursState.offMentionsAndDms);
    });

    test('a Sunday window wraps into Monday', () {
      final schedule = _schedule(days: [_day(_sunday, 23 * 60 + 30, 30)]);
      expect(
        evaluateNotificationSchedule(
          schedule,
          now: DateTime(2024, 3, 11, 0, 29),
        ),
        OffHoursState.onHours,
      );
      expect(
        evaluateNotificationSchedule(
          schedule,
          now: DateTime(2024, 3, 11, 0, 30),
        ),
        OffHoursState.offMentionsAndDms,
      );
    });

    test('yesterday is the previous weekday, not two days back', () {
      final schedule = _schedule(days: [_day(_friday, 22 * 60, 2 * 60)]);
      expect(
        evaluateNotificationSchedule(schedule, now: DateTime(2024, 3, 10, 1)),
        OffHoursState.offMentionsAndDms,
      );
    });

    test('the nothing mode is reported off hours', () {
      final schedule = _schedule(
        days: const [],
        mode: api.OffHoursMode.nothing,
      );
      expect(
        evaluateNotificationSchedule(schedule, now: DateTime(2024, 3, 8, 12)),
        OffHoursState.offNothing,
      );
    });

    test('a future snooze silences everything and an expired one does not', () {
      final now = DateTime(2024, 3, 8, 12);
      final all = [for (var d = 0; d < 7; d++) _day(d, 0, 23 * 60 + 59)];
      expect(
        evaluateNotificationSchedule(
          _schedule(days: all, snoozeUntil: now.millisecondsSinceEpoch + 60000),
          now: now,
        ),
        OffHoursState.offNothing,
      );
      expect(
        evaluateNotificationSchedule(
          _schedule(days: all, snoozeUntil: now.millisecondsSinceEpoch - 1),
          now: now,
        ),
        OffHoursState.onHours,
      );
    });
  });

  group('scheduleEarnsASound', () {
    bool earns(
      OffHoursState state, {
      bool channel = false,
      bool author = false,
      bool dm = false,
      bool mention = false,
    }) => scheduleEarnsASound(
      state: state,
      channelAllowed: channel,
      authorAllowed: author,
      isDm: dm,
      mentionsSelf: mention,
    );

    test('on hours always earns a sound', () {
      expect(earns(OffHoursState.onHours), isTrue);
    });

    test('mentions mode keeps only DMs and mentions', () {
      expect(earns(OffHoursState.offMentionsAndDms), isFalse);
      expect(earns(OffHoursState.offMentionsAndDms, dm: true), isTrue);
      expect(earns(OffHoursState.offMentionsAndDms, mention: true), isTrue);
    });

    test('nothing mode needs an allow-listed author and a mention or DM', () {
      expect(earns(OffHoursState.offNothing, dm: true), isFalse);
      expect(earns(OffHoursState.offNothing, author: true), isFalse);
      expect(earns(OffHoursState.offNothing, author: true, dm: true), isTrue);
      expect(
        earns(OffHoursState.offNothing, author: true, mention: true),
        isTrue,
      );
    });

    test('an allow-listed channel bypasses off hours entirely', () {
      expect(earns(OffHoursState.offNothing, channel: true), isTrue);
      expect(earns(OffHoursState.offMentionsAndDms, channel: true), isTrue);
    });
  });
}
