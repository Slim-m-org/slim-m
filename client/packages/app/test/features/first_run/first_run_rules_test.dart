// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who is owed first-run setup, and which channel it lands on.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/first_run/providers/first_run_rules.dart';
import 'package:slimm_data/data.dart' show Channel;

final _now = DateTime.utc(2026, 10, 18, 12);

bool _due({
  bool done = false,
  Duration age = const Duration(minutes: 5),
  bool messages = false,
}) => firstRunDue(
  done: done,
  accountCreatedAtMs: _now.subtract(age).millisecondsSinceEpoch,
  hasOwnMessages: messages,
  now: _now,
);

Channel _channel(
  String id,
  String kind,
  int cursor, {
  int position = 0,
  int createdAt = 0,
}) => Channel(
  id: id,
  name: id,
  kind: kind,
  createdAt: createdAt,
  position: position,
  cursor: cursor,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

void main() {
  group('firstRunDue', () {
    test('a brand-new account is owed setup', () => expect(_due(), isTrue));

    test('an account past a day is not', () {
      expect(_due(age: const Duration(hours: 25)), isFalse);
      expect(_due(age: const Duration(hours: 23)), isTrue);
    });

    test('an account that has written something is not', () {
      expect(_due(messages: true), isFalse);
    });

    test('finished or skipped setup is never owed again', () {
      expect(_due(done: true), isFalse);
    });
  });

  test('flags are keyed per account and per space', () {
    expect(
      firstRunDoneKey('https://a.test', 'u1'),
      isNot(firstRunDoneKey('https://b.test', 'u1')),
    );
    expect(
      firstRunDoneKey('https://a.test', 'u1'),
      isNot(firstRunDoneKey('https://a.test', 'u2')),
    );
  });

  group('pickLandingChannel', () {
    test('takes the Space\'s first text channel, not the busiest', () {
      final picked = pickLandingChannel([
        _channel('history', 'text', 900, createdAt: 30),
        _channel('general', 'text', 4, createdAt: 10),
        _channel('random', 'text', 20, createdAt: 20),
      ]);
      expect(picked?.id, 'general');
    });

    test('never picks a voice channel or a DM, however old', () {
      final picked = pickLandingChannel([
        _channel('lobby', 'voice', 500, createdAt: 1),
        _channel('friend', 'dm', 400, createdAt: 2),
        _channel('general', 'text', 1, createdAt: 3),
      ]);
      expect(picked?.id, 'general');
    });

    test('keeps rail order on a tie', () {
      final picked = pickLandingChannel([
        _channel('first', 'text', 5),
        _channel('second', 'text', 9),
      ]);
      expect(picked?.id, 'first');
    });

    test('is null when there is no text channel', () {
      expect(pickLandingChannel([_channel('lobby', 'voice', 9)]), isNull);
      expect(pickLandingChannel(const []), isNull);
    });
  });
}
