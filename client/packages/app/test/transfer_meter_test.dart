// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/transfer_meter.dart';

class _Clock {
  DateTime now = DateTime(2026, 10, 15, 12);
  void advance(Duration by) => now = now.add(by);
}

void main() {
  test('a steady upload measures its rate and the time it has left', () {
    final clock = _Clock();
    final meter = TransferMeter(() => clock.now);
    meter.record(0);
    for (var i = 1; i <= 20; i++) {
      clock.advance(const Duration(seconds: 1));
      meter.record(i * 10 * 1000 * 1000);
    }
    expect(meter.bytesPerSecond, closeTo(10e6, 1));
    expect(
      meter.remaining(200e6.toInt(), 800e6.toInt()),
      const Duration(seconds: 60),
    );
  });

  test('nothing is estimated before anything moves', () {
    final clock = _Clock();
    final meter = TransferMeter(() => clock.now);
    meter.record(0);
    clock.advance(const Duration(seconds: 2));
    meter.record(0);
    expect(meter.bytesPerSecond, isNull);
    expect(meter.remaining(0, 100), isNull);
  });

  test('a burst moves the estimate gradually, not all at once', () {
    final clock = _Clock();
    final meter = TransferMeter(() => clock.now);
    meter.record(0);
    for (var i = 1; i <= 10; i++) {
      clock.advance(const Duration(seconds: 1));
      meter.record(i * 1000000);
    }
    clock.advance(const Duration(seconds: 1));
    meter.record(10000000 + 100000000);
    final rate = meter.bytesPerSecond!;
    expect(rate, greaterThan(1e6));
    expect(
      rate,
      lessThan(50e6),
      reason: 'one 100 MB/s second does not become the rate',
    );
  });

  test(
    'a resume that restarts lower measures from there instead of going negative',
    () {
      final clock = _Clock();
      final meter = TransferMeter(() => clock.now);
      meter.record(0);
      clock.advance(const Duration(seconds: 1));
      meter.record(5000000);
      clock.advance(const Duration(seconds: 1));
      meter.record(4000000);
      clock.advance(const Duration(seconds: 1));
      meter.record(9000000);
      expect(meter.bytesPerSecond, greaterThan(0));
    },
  );

  test('detail shows only once the upload has run ten seconds', () {
    final clock = _Clock();
    final meter = TransferMeter(() => clock.now);
    meter.record(0);
    clock.advance(const Duration(seconds: 9));
    meter.record(9000000);
    expect(meter.showsDetail, isFalse);
    clock.advance(const Duration(seconds: 1));
    meter.record(10000000);
    expect(meter.showsDetail, isTrue);
  });

  test('time left reads in seconds, minutes or hours', () {
    expect(formatTimeLeft(const Duration(seconds: 40)), 'about 40 s left');
    expect(formatTimeLeft(const Duration(seconds: 0)), 'about 1 s left');
    expect(
      formatTimeLeft(const Duration(minutes: 6, seconds: 10)),
      'about 7 min left',
    );
    expect(formatTimeLeft(const Duration(minutes: 90)), 'about 1.5 h left');
    expect(formatTimeLeft(const Duration(hours: 30)), 'about 30 h left');
  });
}
