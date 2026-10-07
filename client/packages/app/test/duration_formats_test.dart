// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two duration labels with no test between them: `formatCallDuration` on a
/// call recap card, and `formatRemaining` on a member's timeout. Both turn on
/// thresholds and one pluralizes, which is exactly where an off-by-one hides -
/// "1 hrs", or a timeout that reads "60m" at the hour instead of "1h".
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/format.dart';
import 'package:slimm_app/src/widgets/call_recap_card.dart';

void main() {
  group('formatCallDuration', () {
    test('under a minute reads in seconds, including zero', () {
      expect(formatCallDuration(Duration.zero), '0 sec');
      expect(formatCallDuration(const Duration(seconds: 59)), '59 sec');
    });

    test('a minute or more, under an hour, reads in minutes', () {
      expect(formatCallDuration(const Duration(minutes: 1)), '1 min');
      expect(formatCallDuration(const Duration(minutes: 45)), '45 min');
    });

    test('an hour or more carries the minutes and pluralizes the hour', () {
      expect(formatCallDuration(const Duration(hours: 1)), '1 hr 0 min');
      expect(
        formatCallDuration(const Duration(hours: 1, minutes: 30)),
        '1 hr 30 min',
      );
      expect(
        formatCallDuration(const Duration(hours: 2, minutes: 5)),
        '2 hrs 5 min',
      );
    });
  });

  group('formatRemaining', () {
    test('an elapsed deadline reads as moments, not a negative value', () {
      expect(formatRemaining(const Duration(seconds: -5)), 'moments');
    });

    test('it steps down through days, hours, minutes, seconds', () {
      expect(formatRemaining(const Duration(days: 3)), '3d');
      expect(formatRemaining(const Duration(hours: 23)), '23h');
      expect(formatRemaining(const Duration(minutes: 59)), '59m');
      expect(formatRemaining(const Duration(seconds: 30)), '30s');
    });

    test('each threshold flips exactly at its boundary', () {
      expect(formatRemaining(const Duration(hours: 24)), '1d');
      expect(formatRemaining(const Duration(minutes: 60)), '1h');
      expect(formatRemaining(const Duration(minutes: 1)), '1m');
    });
  });
}
