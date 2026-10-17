// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The day-divider rules: when a message opens a new calendar day (so the
/// divider lands exactly once at each boundary), and how that day reads to a
/// person - "Today", "Yesterday", or an absolute date, with the year only when
/// it differs from now.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript_dividers.dart';

import 'message_row_harness.dart';

int _ms(int year, int month, int day, [int hour = 12]) =>
    DateTime(year, month, day, hour).millisecondsSinceEpoch;

void main() {
  group('isNewDay', () {
    test('the oldest loaded message anchors its own day once history is '
        'known', () {
      expect(
        isNewDay(
          message(createdAt: _ms(2026, 7, 28)),
          null,
          historyKnown: true,
        ),
        isTrue,
      );
    });

    test('the oldest loaded message does not anchor before history is '
        'known, or an optimistic send racing catch-up would flash one '
        '(docs/BACKLOG.md)', () {
      expect(
        isNewDay(
          message(createdAt: _ms(2026, 7, 28)),
          null,
          historyKnown: false,
        ),
        isFalse,
      );
    });

    test('two messages on the same day share it, hours apart or not', () {
      final morning = message(createdAt: _ms(2026, 7, 28, 9));
      final night = message(createdAt: _ms(2026, 7, 28, 21));
      expect(isNewDay(night, morning, historyKnown: true), isFalse);
    });

    test('a message just across midnight opens a new day', () {
      final before = message(createdAt: _ms(2026, 7, 28, 23));
      final after = message(createdAt: _ms(2026, 7, 29, 0));
      expect(isNewDay(after, before, historyKnown: true), isTrue);
    });
  });

  group('formatMessageDay', () {
    final now = DateTime(2026, 7, 29, 15, 30);

    test('the current day reads as Today', () {
      expect(formatMessageDay(_ms(2026, 7, 29, 8), now: now), 'Today');
    });

    test('the day before reads as Yesterday', () {
      expect(formatMessageDay(_ms(2026, 7, 28, 8), now: now), 'Yesterday');
    });

    test('an earlier day this year drops the year', () {
      expect(formatMessageDay(_ms(2026, 3, 4, 8), now: now), 'March 4');
    });

    test('a day in another year keeps the year', () {
      expect(
        formatMessageDay(_ms(2025, 12, 31, 8), now: now),
        'December 31, 2025',
      );
    });
  });
}
