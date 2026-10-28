// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

const _timing = MicRecoveryTiming(
  silence: Duration(seconds: 10),
  silentCooldown: Duration(seconds: 30),
  maxSilentRestarts: 3,
  recoveredAfter: Duration(minutes: 2),
);

class _Rig {
  _Rig() {
    dog = SilentMicWatchdog(
      timing: _timing,
      now: () => clock,
      onSilent: () => restarts++,
      onGaveUp: () => gaveUp++,
      onRecovered: () => recovered++,
    );
  }

  late final SilentMicWatchdog dog;
  var clock = DateTime(2026);
  var restarts = 0;
  var gaveUp = 0;
  var recovered = 0;

  /// Feeds [level] once a second for [seconds].
  void feed(double level, int seconds) {
    for (var i = 0; i < seconds; i++) {
      clock = clock.add(const Duration(seconds: 1));
      dog.observe(level, active: true);
    }
  }
}

void main() {
  test('a long run of exact silence restarts, then backs off and gives up', () {
    final rig = _Rig()..feed(kInputFloorDb, 600);

    expect(rig.restarts, 3);
    expect(rig.gaveUp, 1);
  });

  test('restarts are spaced further apart each time', () {
    final rig = _Rig();
    final at = <int>[];
    for (var s = 1; s <= 300; s++) {
      final before = rig.restarts;
      rig.feed(kInputFloorDb, 1);
      if (rig.restarts > before) at.add(s);
    }

    expect(at.length, 3);
    expect(at[1] - at[0], greaterThan(at[0]));
    expect(at[2] - at[1], greaterThan(at[1] - at[0]));
  });

  test('a blip after each restart does not refill the budget', () {
    final rig = _Rig();
    for (var i = 0; i < 40; i++) {
      rig.feed(kInputFloorDb, 45);
      rig.feed(-40, 1);
    }

    expect(rig.restarts, 3);
    expect(rig.gaveUp, 1);
  });

  test('a mic live for long enough earns its restarts back', () {
    final rig = _Rig()
      ..feed(kInputFloorDb, 60)
      ..feed(-40, 130)
      ..feed(kInputFloorDb, 60);

    expect(rig.restarts, 4);
  });

  test('readings that prove nothing never restart a gated or Strong mic', () {
    final rig = _Rig();
    for (var i = 0; i < 3600; i++) {
      rig.clock = rig.clock.add(const Duration(seconds: 1));
      rig.dog.pause();
    }

    expect(rig.restarts, 0);
  });

  test('silence before a paused stretch does not carry over it', () {
    final rig = _Rig()
      ..feed(kInputFloorDb, 8)
      ..dog.pause()
      ..feed(kInputFloorDb, 8);

    expect(rig.restarts, 0);
  });

  test('a mic that comes back after giving up is announced once it has held',
      () {
    final rig = _Rig()
      ..feed(kInputFloorDb, 600)
      ..feed(-40, 5);
    expect(rig.recovered, 0);
    rig.feed(-40, 130);

    expect(rig.recovered, 1);
  });

  test('muted resets everything', () {
    final rig = _Rig()..feed(kInputFloorDb, 9);
    rig.dog.observe(kInputFloorDb, active: false);
    rig.feed(kInputFloorDb, 9);

    expect(rig.restarts, 0);
  });

  test('a silence blamed on the gate gives back only its own restart', () {
    var clock = DateTime(2026);
    var gateStalled = false;
    var captureRestarts = 0;
    var gaveUp = 0;
    late final SilentMicWatchdog dog;
    dog = SilentMicWatchdog(
      timing: _timing,
      now: () => clock,
      onSilent: () {
        if (gateStalled) return dog.refundRestart();
        captureRestarts++;
      },
      onGaveUp: () => gaveUp++,
    );
    void feed(int seconds) {
      for (var i = 0; i < seconds; i++) {
        clock = clock.add(const Duration(seconds: 1));
        dog.observe(kInputFloorDb, active: true);
      }
    }

    feed(11);
    gateStalled = true;
    feed(200);
    gateStalled = false;
    feed(600);

    expect(captureRestarts, 3,
        reason: 'the first real restart was not refilled');
    expect(gaveUp, 1);
  });
}
