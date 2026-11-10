// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Proves `waitForStableDay` waits exactly where a day-straddling run could
/// happen and nowhere else, so the helper cannot pass by never waiting.
library;

import 'package:flutter_test/flutter_test.dart';

import 'day_stable_now.dart';

void main() {
  test('does not wait in the middle of the day', () {
    expect(waitForStableDay(DateTime(2026, 6, 15, 12)), Duration.zero);
    expect(waitForStableDay(DateTime(2026, 6, 15, 0, 0, 10)), Duration.zero);
    expect(waitForStableDay(DateTime(2026, 6, 15, 23, 59, 30)), Duration.zero);
  });

  test('waits out the first seconds after midnight', () {
    expect(
      waitForStableDay(DateTime(2026, 6, 15)),
      const Duration(seconds: 10),
    );
    expect(
      waitForStableDay(DateTime(2026, 6, 15, 0, 0, 4)),
      const Duration(seconds: 6),
    );
  });

  test('waits through midnight when it is a few seconds away', () {
    expect(
      waitForStableDay(DateTime(2026, 6, 15, 23, 59, 59)),
      const Duration(seconds: 11),
    );
    expect(
      waitForStableDay(DateTime(2026, 6, 15, 23, 59, 31)),
      const Duration(seconds: 39),
    );
  });

  test('lands on a clear instant after every wait', () {
    for (final start in [
      DateTime(2026, 6, 15, 23, 59, 40),
      DateTime(2026, 12, 31, 23, 59, 59),
      DateTime(2026, 6, 15, 0, 0, 1),
    ]) {
      final after = start.add(waitForStableDay(start));
      expect(waitForStableDay(after), Duration.zero, reason: '$start');
    }
  });
}
