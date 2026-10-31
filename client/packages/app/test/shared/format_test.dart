// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `formatDateTime` renders the timestamps a report, an invite, a role or a
/// timeout shows. The one place it was used from a test built its expected
/// string with the function itself and only ever in 24-hour mode, so the
/// 12-hour path - and its midnight/noon boundary, the classic `0:00 AM` bug -
/// went unchecked.
///
/// Epochs are built from a local [DateTime] and read back as local time, so
/// these hold regardless of the machine's timezone.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/format.dart';

int _ms(int y, int mo, int d, int h, int min) =>
    DateTime(y, mo, d, h, min).millisecondsSinceEpoch;

void main() {
  test('24-hour zero-pads every field', () {
    expect(
      formatDateTime(_ms(2026, 1, 3, 9, 7), use24Hour: true),
      '2026-01-03 09:07',
    );
    expect(
      formatDateTime(_ms(2026, 3, 7, 0, 0), use24Hour: true),
      '2026-03-07 00:00',
    );
    expect(
      formatDateTime(_ms(2026, 12, 31, 23, 59), use24Hour: true),
      '2026-12-31 23:59',
    );
  });

  test('12-hour shows midnight and noon as 12, not 0', () {
    expect(
      formatDateTime(_ms(2026, 3, 7, 0, 5), use24Hour: false),
      '2026-03-07 12:05\u00A0AM',
    );
    expect(
      formatDateTime(_ms(2026, 3, 7, 12, 0), use24Hour: false),
      '2026-03-07 12:00\u00A0PM',
    );
  });

  test('12-hour picks AM before noon and PM after, hour unpadded', () {
    expect(
      formatDateTime(_ms(2026, 3, 7, 9, 7), use24Hour: false),
      '2026-03-07 9:07\u00A0AM',
    );
    expect(
      formatDateTime(_ms(2026, 3, 7, 13, 45), use24Hour: false),
      '2026-03-07 1:45\u00A0PM',
    );
    expect(
      formatDateTime(_ms(2026, 3, 7, 23, 9), use24Hour: false),
      '2026-03-07 11:09\u00A0PM',
    );
  });

  group('formatRelativeAge', () {
    String age(Duration d, {bool seconds = false, bool weeks = false}) =>
        formatRelativeAge(d, seconds: seconds, weeks: weeks);

    test('one threshold table: just now, minutes, hours, days', () {
      expect(age(const Duration(seconds: 59)), 'just now');
      expect(age(const Duration(seconds: 60)), '1m ago');
      expect(age(const Duration(minutes: 59, seconds: 59)), '59m ago');
      expect(age(const Duration(hours: 1)), '1h ago');
      expect(age(const Duration(hours: 23, minutes: 59)), '23h ago');
      expect(age(const Duration(days: 1)), '1d ago');
      expect(age(const Duration(days: 20)), '20d ago');
    });

    test('the seconds tier starts after thirty seconds', () {
      expect(age(const Duration(seconds: 29), seconds: true), 'just now');
      expect(age(const Duration(seconds: 30), seconds: true), '30s ago');
      expect(age(const Duration(seconds: 60), seconds: true), '1m ago');
    });

    test('the weeks tier replaces days from seven days', () {
      expect(age(const Duration(days: 6), weeks: true), '6d ago');
      expect(age(const Duration(days: 15), weeks: true), '2w ago');
    });

    test('a future time reads as just now', () {
      expect(age(const Duration(seconds: -5)), 'just now');
    });
  });

  test('formatPlaybackTime is m:ss, h:mm:ss from an hour, clamped at zero', () {
    expect(formatPlaybackTime(const Duration(seconds: -1)), '0:00');
    expect(formatPlaybackTime(Duration.zero), '0:00');
    expect(formatPlaybackTime(const Duration(seconds: 7)), '0:07');
    expect(formatPlaybackTime(const Duration(minutes: 3, seconds: 7)), '3:07');
    expect(formatPlaybackTime(const Duration(hours: 1)), '1:00:00');
    expect(
      formatPlaybackTime(const Duration(hours: 1, minutes: 23, seconds: 45)),
      '1:23:45',
    );
  });
}
