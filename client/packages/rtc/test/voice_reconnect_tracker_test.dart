// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  late DateTime now;
  late List<String> log;
  late ReconnectTracker tracker;

  setUp(() {
    now = DateTime(2026, 11, 1, 12);
    log = [];
    tracker = ReconnectTracker(log: log.add, clock: () => now);
  });

  tearDown(() => tracker.dispose());

  void pass(Duration by) => now = now.add(by);

  test('a resume is active from its start to its end and is timed', () {
    tracker.started(ReconnectKind.resume);
    expect(tracker.active.value, isTrue);
    pass(const Duration(milliseconds: 250));

    tracker.ended('reconnected');

    expect(tracker.active.value, isFalse);
    expect(log, [
      'Call transport: reconnecting (resume)',
      'Call transport: reconnected after 250 ms',
    ]);
  });

  test('a resume that escalates is one blip timed from the first event', () {
    tracker.started(ReconnectKind.resume);
    pass(const Duration(seconds: 1));
    tracker.started(ReconnectKind.restart);
    pass(const Duration(seconds: 2));
    tracker.ended('reconnected');

    expect(tracker.stats.count, 1);
    expect(tracker.stats.total, const Duration(seconds: 3));
    expect(log, [
      'Call transport: reconnecting (resume)',
      'Call transport: reconnected after 3000 ms (then a restart at 1000 ms)',
    ]);
  });

  test('retries during an episode are told once, when it ends', () {
    tracker.started(ReconnectKind.resume);
    for (var attempt = 1; attempt <= 3; attempt++) {
      pass(const Duration(milliseconds: 100));
      tracker.attempted(attempt, 10, 300);
    }
    tracker.ended('reconnected');

    expect(log, [
      'Call transport: reconnecting (resume)',
      'Call transport: reconnected after 300 ms (3 attempts)',
    ]);
  });

  test('counts and totals accumulate, and the longest is kept', () {
    for (final ms in [300, 4000, 1200]) {
      tracker.started(ReconnectKind.resume);
      pass(Duration(milliseconds: ms));
      tracker.ended('reconnected');
    }

    final stats = tracker.stats;
    expect(stats.count, 3);
    expect(stats.total, const Duration(milliseconds: 5500));
    expect(stats.longest, const Duration(milliseconds: 4000));
    expect(
      stats.line,
      '[voice-health] call summary transport blips=3 total=5500ms '
      'longest=4000ms',
    );
  });

  test('a call that never blipped has no summary line', () {
    expect(tracker.stats.line, isNull);
  });

  test('ending when nothing was active counts nothing', () {
    tracker.ended('reconnected');

    expect(tracker.stats.count, 0);
    expect(log, isEmpty);
  });

  test('an attempt alone marks the reconnect and logs the retry', () {
    tracker.attempted(2, 10, 300);
    tracker.attempted(3, 10, 600);

    expect(tracker.active.value, isTrue);
    expect(log.single, contains('attempt 2 of 10'));
    expect(log.single, contains('next retry in 300 ms'));
  });

  test('resetting the counts keeps an episode in flight', () {
    tracker.started(ReconnectKind.resume);
    pass(const Duration(seconds: 1));
    tracker.ended('reconnected');
    tracker.started(ReconnectKind.resume);

    tracker.resetStats();

    expect(tracker.stats.count, 0);
    expect(tracker.active.value, isTrue);
  });

  test('a reconnect the SDK never reports as finished is released', () {
    fakeAsync((async) {
      final stuck = ReconnectTracker(
        log: log.add,
        clock: () => now,
        quiet: const Duration(seconds: 30),
      );
      stuck.started(ReconnectKind.restart);
      async.elapse(const Duration(seconds: 29));
      expect(stuck.active.value, isTrue);

      now = now.add(const Duration(seconds: 30));
      async.elapse(const Duration(seconds: 2));

      expect(stuck.active.value, isFalse);
      expect(log.last, contains('no reconnect event for 30 s'));
      stuck.dispose();
    });
  });

  test('every retry attempt postpones the release', () {
    fakeAsync((async) {
      final retrying = ReconnectTracker(
        clock: () => now,
        quiet: const Duration(seconds: 30),
      );
      retrying.started(ReconnectKind.restart);
      for (var attempt = 1; attempt <= 3; attempt++) {
        async.elapse(const Duration(seconds: 20));
        retrying.attempted(attempt, 10, 7000);
      }

      expect(retrying.active.value, isTrue);
      retrying.dispose();
    });
  });

  test('events after dispose are ignored', () {
    final released = ReconnectTracker(clock: () => now)..dispose();

    released.started(ReconnectKind.resume);
    released.ended('reconnected');
  });

  group('the call summary', () {
    test('carries the blips, even for a call with no audio samples', () {
      final health = VoiceHealth();
      addTearDown(health.dispose);
      health.reconnect.started(ReconnectKind.resume);
      health.reconnect.ended('reconnected');

      final lines = health.finish();

      expect(lines.single, contains('transport blips=1'));
      expect(health.reconnect.stats.count, 0,
          reason: 'the next call starts from zero');
    });

    test('stays out of the log when the transport held', () {
      final health = VoiceHealth();
      addTearDown(health.dispose);

      expect(health.finish(), isEmpty);
    });
  });
}
