// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

const _timing = MicRecoveryTiming(
  quietNote: Duration(seconds: 120),
  restartCooldown: Duration(seconds: 30),
  maxRestarts: 3,
  recoveredAfter: Duration(minutes: 2),
);

class _Rig {
  _Rig() {
    dog = MicStallWatchdog(
      timing: _timing,
      now: () => clock,
      onStalled: () => restarts++,
      onGaveUp: () => gaveUp++,
      onRecovered: () => recovered++,
      onQuiet: () => quiet++,
    );
  }

  late final MicStallWatchdog dog;
  var clock = DateTime(2026);
  var restarts = 0;
  var gaveUp = 0;
  var recovered = 0;
  var quiet = 0;

  void tick() => clock = clock.add(const Duration(seconds: 1));

  /// Feeds a counter verdict once a second for [seconds].
  void feed(bool? advancing, int seconds) {
    for (var i = 0; i < seconds; i++) {
      tick();
      dog.observeProgress(advancing: advancing, active: true);
    }
  }

  /// Feeds [level] once a second, with the counter advancing, for [seconds].
  void feedLevel(double level, int seconds) {
    for (var i = 0; i < seconds; i++) {
      tick();
      dog.observe(level, active: true);
      dog.observeProgress(advancing: true, active: true);
    }
  }
}

void main() {
  group('digital silence', () {
    test('never restarts or gives up while the counter advances', () {
      final rig = _Rig()..feedLevel(kInputFloorDb, 3600);

      expect(rig.restarts, 0);
      expect(rig.gaveUp, 0);
    });

    test('is noted once per stretch, after the quiet span', () {
      final rig = _Rig()..feedLevel(kInputFloorDb, 119);
      expect(rig.quiet, 0);
      rig.feedLevel(kInputFloorDb, 600);
      expect(rig.quiet, 1);
      rig
        ..feedLevel(-40, 1)
        ..feedLevel(kInputFloorDb, 130);

      expect(rig.quiet, 2);
    });

    test('a muted mic forgets the quiet so far', () {
      final rig = _Rig()..feedLevel(kInputFloorDb, 100);
      rig.dog.observe(kInputFloorDb, active: false);
      rig.feedLevel(kInputFloorDb, 100);

      expect(rig.quiet, 0);
    });
  });

  group('a capture counter that stands still', () {
    test('restarts after the stall span, then backs off and gives up', () {
      final rig = _Rig()..feed(false, 600);

      expect(rig.restarts, 3);
      expect(rig.gaveUp, 1);
    });

    test('restarts are spaced further apart each time', () {
      final rig = _Rig();
      final at = <int>[];
      for (var s = 1; s <= 300; s++) {
        final before = rig.restarts;
        rig.feed(false, 1);
        if (rig.restarts > before) at.add(s);
      }

      expect(at.length, 3);
      expect(at[1] - at[0], greaterThan(at[0]));
      expect(at[2] - at[1], greaterThan(at[1] - at[0]));
    });

    test('waits for the whole stall span', () {
      final rig = _Rig()..feed(false, 4);

      expect(rig.restarts, 0);
    });

    test('a counter that moves, or no verdict, never restarts', () {
      final rig = _Rig()
        ..feed(true, 600)
        ..feed(null, 600);

      expect(rig.restarts, 0);
    });

    test('a reading in between restarts the stall clock', () {
      final rig = _Rig();
      for (var i = 0; i < 100; i++) {
        rig
          ..feed(false, 4)
          ..feed(true, 1);
      }

      expect(rig.restarts, 0);
    });

    test('a blip after each restart does not refill the budget', () {
      final rig = _Rig();
      for (var i = 0; i < 40; i++) {
        rig
          ..feed(false, 45)
          ..feed(true, 1);
      }

      expect(rig.restarts, 3);
      expect(rig.gaveUp, 1);
    });

    test('a counter that moves for long enough earns its restarts back', () {
      final rig = _Rig()
        ..feed(false, 20)
        ..feed(true, 130)
        ..feed(false, 600);

      expect(rig.restarts, 4);
    });

    test('a counter that moves for long enough clears a give-up', () {
      final rig = _Rig()..feed(false, 600);
      rig.feed(true, 5);
      expect(rig.recovered, 0);
      rig.feed(true, 130);

      expect(rig.recovered, 1);
    });

    test('a muted mic forgets the stall so far', () {
      final rig = _Rig()..feed(false, 4);
      rig.dog.observeProgress(advancing: null, active: false);
      rig.feed(false, 4);

      expect(rig.restarts, 0);
    });
  });

  test('capture progress reads any change as movement, and a reset as unknown',
      () {
    final progress = CaptureProgress();

    expect(progress.advanced(null), isNull);
    expect(progress.advanced(1.5), isNull);
    expect(progress.advanced(3.0), isTrue);
    expect(progress.advanced(3.0), isFalse);
    expect(progress.advanced(0.1), isTrue);
    expect(progress.advanced(null), isNull);
    expect(progress.advanced(0.1), isNull);
    progress.reset();
    expect(progress.advanced(0.1), isNull);
  });
}
