// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A schedule remembers how far the server clock is from the device's, so a
/// snooze is judged on the clock that set it.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, dynamic> _json({int? serverNow, int? snoozeUntil}) => {
      'timezone': 'UTC',
      'days': <Object>[],
      'off_hours_mode': 'mentions',
      'snooze_until': snoozeUntil,
      'allowed_user_ids': <String>[],
      'allowed_channel_ids': <String>[],
      if (serverNow != null) 'server_now': serverNow,
    };

void main() {
  test('a snooze still running on the server clock is active on a fast device',
      () {
    final deviceNow = DateTime.now().millisecondsSinceEpoch;
    const hour = 3600 * 1000;
    final schedule = NotificationSchedule.fromJson(
      _json(serverNow: deviceNow - hour, snoozeUntil: deviceNow - hour + 60000),
    );

    expect(schedule.isSnoozed, isTrue);
  });

  test('a server that sends no clock leaves the device clock in charge', () {
    final past = DateTime.now().millisecondsSinceEpoch - 1000;
    final schedule = NotificationSchedule.fromJson(_json(snoozeUntil: past));

    expect(schedule.clockOffsetMs, 0);
    expect(schedule.isSnoozed, isFalse);
  });
}
