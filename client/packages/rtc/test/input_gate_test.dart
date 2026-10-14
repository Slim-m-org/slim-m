// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The input gate monitor over a fake platform channel, and how its voice
/// reading decides the local speaking ring.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

class _FakeGate {
  final calls = <(String, Object?)>[];
  double levelDb = -70;
  bool voice = false;
  bool fail = false;

  Future<Object?> invoke(String method, [Object? args]) async {
    calls.add((method, args));
    if (fail) throw StateError('no gate in this build');
    if (method == 'getInputGate') return {'levelDb': levelDb, 'voice': voice};
    return null;
  }
}

void main() {
  test('configure sends the threshold and whether to silence', () async {
    final fake = _FakeGate();
    final gate = InputGateMonitor(invoke: fake.invoke, supported: true);
    await gate.configure(enabled: true, thresholdDb: -42);
    expect(fake.calls.single.$1, 'setInputGate');
    expect(fake.calls.single.$2, {'enabled': true, 'thresholdDb': -42.0});
  });

  test('an unsupported host never reaches the platform', () {
    fakeAsync((async) {
      final fake = _FakeGate();
      final gate = InputGateMonitor(invoke: fake.invoke, supported: false);
      gate.configure(enabled: true, thresholdDb: -42);
      gate.start(() {});
      async.elapse(const Duration(seconds: 1));
      expect(fake.calls, isEmpty);
      expect(gate.running, isFalse);
    });
  });

  test('polling reports levels and calls back only when voice flips', () {
    fakeAsync((async) {
      final fake = _FakeGate();
      final gate = InputGateMonitor(invoke: fake.invoke, supported: true);
      final levels = <double>[];
      gate.readings.listen((r) => levels.add(r.levelDb));
      var flips = 0;
      gate.start(() => flips++);

      async.elapse(const Duration(milliseconds: 160));
      expect(levels, [-70.0, -70.0, -70.0]);
      expect(flips, 0);

      fake
        ..voice = true
        ..levelDb = -30;
      async.elapse(const Duration(milliseconds: 100));
      expect(gate.voice, isTrue);
      expect(flips, 1, reason: 'two loud reads, one flip');

      gate.stop();
      expect(gate.voice, isFalse, reason: 'a stopped gate hears nothing');
      final count = fake.calls.length;
      async.elapse(const Duration(seconds: 1));
      expect(fake.calls.length, count);
    });
  });

  test('a platform error stops polling instead of retrying forever', () {
    fakeAsync((async) {
      final fake = _FakeGate()..fail = true;
      final gate = InputGateMonitor(invoke: fake.invoke, supported: true);
      gate.start(() {});
      async.elapse(const Duration(milliseconds: 500));
      expect(fake.calls.length, 1);
      expect(gate.running, isFalse);
    });
  });

  test('the meter spans the floor to full scale', () {
    expect(inputLevelFraction(kInputFloorDb), 0);
    expect(inputLevelFraction(-40), 0.5);
    expect(inputLevelFraction(0), 1);
    expect(inputLevelFraction(-200), 0);
  });

  group('isSpeakingNow', () {
    test('the gate wins over a lagging SFU report', () {
      expect(
        isSpeakingNow(
          reported: false,
          level: 0,
          sensitivity: 1,
          muted: false,
          voice: true,
        ),
        isTrue,
      );
      expect(
        isSpeakingNow(
          reported: true,
          level: 1,
          sensitivity: 1,
          muted: false,
          voice: false,
        ),
        isFalse,
      );
    });

    test('a muted mic never lights the ring, whatever the gate hears', () {
      expect(
        isSpeakingNow(
          reported: false,
          level: 0,
          sensitivity: 1,
          muted: true,
          voice: true,
        ),
        isFalse,
      );
    });

    test('without a gate the SFU report and threshold decide', () {
      expect(
        isSpeakingNow(
          reported: true,
          level: 0.3,
          sensitivity: 0.5,
          muted: false,
        ),
        isFalse,
      );
      expect(
        isSpeakingNow(
          reported: true,
          level: 0.6,
          sensitivity: 0.5,
          muted: false,
        ),
        isTrue,
      );
    });
  });
}
