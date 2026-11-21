// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fixture's "yesterday" call reads as yesterday just after midnight too,
/// when the 12-minutes-ago call has already started on the previous day.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_history_rows.dart';

import '../../support/call_details_fixture.dart';

void main() {
  test('the yesterday call is labelled yesterday at 00:05', () {
    final now = DateTime(2026, 11, 21, 0, 5).millisecondsSinceEpoch;
    expect(callDayLabel(yesterdayNoonMs(now), now: now), 'yesterday');
  });

  test('anchoring on the call started 12 minutes ago breaks at 00:05', () {
    final now = DateTime(2026, 11, 21, 0, 5).millisecondsSinceEpoch;
    final started = now - 12 * 60 * 1000;
    expect(
      callDayLabel(yesterdayNoonMs(started), now: now),
      isNot('yesterday'),
    );
  });
}
