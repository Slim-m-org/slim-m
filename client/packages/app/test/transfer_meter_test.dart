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

  test('detail shows only once the transfer has been measured two seconds', () {
    final clock = _Clock();
    final meter = TransferMeter(() => clock.now);
    meter.record(0);
    clock.advance(const Duration(seconds: 1));
    meter.record(1000000);
    expect(meter.showsDetail, isFalse);
    clock.advance(const Duration(seconds: 1));
    meter.record(2000000);
    expect(meter.showsDetail, isTrue);
  });

  test('a stall decays the rate instead of promising the old finish time', () {
    final clock = _Clock();
    final meter = TransferMeter(() => clock.now);
    meter.record(0);
    for (var i = 1; i <= 5; i++) {
      clock.advance(const Duration(seconds: 1));
      meter.record(i * 10000000);
    }
    final steady = meter.bytesPerSecond!;
    clock.advance(const Duration(seconds: 12));
    expect(meter.bytesPerSecond!, lessThan(steady / 10));
    final left = meter.remaining(50000000, 100000000)!;
    expect(left, greaterThan(const Duration(minutes: 1)));
  });

  test('a reset forgets the old link and waits to measure again', () {
    final clock = _Clock();
    final meter = TransferMeter(() => clock.now);
    meter.record(0);
    for (var i = 1; i <= 5; i++) {
      clock.advance(const Duration(seconds: 1));
      meter.record(i * 10000000);
    }
    meter.reset();
    expect(meter.bytesPerSecond, isNull);
    expect(meter.showsDetail, isFalse);
    meter.record(50000000);
    for (var i = 1; i <= 3; i++) {
      clock.advance(const Duration(seconds: 1));
      meter.record(50000000 + i * 1000000);
    }
    expect(meter.bytesPerSecond, closeTo(1e6, 1));
    expect(meter.showsDetail, isTrue);
  });

  test('chunk granularity does not change the rate', () {
    final fine = _Clock();
    final coarse = _Clock();
    final a = TransferMeter(() => fine.now)..record(0);
    final b = TransferMeter(() => coarse.now)..record(0);
    for (var i = 1; i <= 40; i++) {
      fine.advance(const Duration(milliseconds: 250));
      a.record(i * 2500000);
    }
    for (var i = 1; i <= 10; i++) {
      coarse.advance(const Duration(seconds: 1));
      b.record(i * 10000000);
    }
    expect(a.bytesPerSecond, closeTo(10e6, 10e6 * 0.02));
    expect(b.bytesPerSecond, closeTo(10e6, 10e6 * 0.02));
  });

  test('time left reads in seconds, minutes or hours', () {
    expect(formatTimeLeft(const Duration(seconds: 40)), '40 s left');
    expect(formatTimeLeft(const Duration(seconds: 0)), '1 s left');
    expect(
      formatTimeLeft(const Duration(minutes: 6, seconds: 10)),
      '7 min left',
    );
    expect(formatTimeLeft(const Duration(minutes: 90)), '1.5 h left');
    expect(formatTimeLeft(const Duration(hours: 30)), '30 h left');
  });

  test('rate reads in B, KB, MB or GB a second', () {
    expect(formatTransferRate(512), '512 B/s');
    expect(formatTransferRate(2048), '2.0 KB/s');
    expect(formatTransferRate(38 * 1024 * 1024), '38.0 MB/s');
    expect(formatTransferRate(2.5 * 1024 * 1024 * 1024), '2.5 GB/s');
  });

  group('formatTransferLine', () {
    TransferMeter steady(_Clock clock) {
      final meter = TransferMeter(() => clock.now)..record(0);
      for (var i = 1; i <= 4; i++) {
        clock.advance(const Duration(seconds: 1));
        meter.record(i * 10 * 1024 * 1024);
      }
      return meter;
    }

    test('joins percent, rate and time left once measured', () {
      final clock = _Clock();
      final meter = steady(clock);
      expect(
        formatTransferLine(
          sent: 40 * 1024 * 1024,
          total: 400 * 1024 * 1024,
          meter: meter,
        ),
        '10% · 10.0 MB/s · 36 s left',
      );
    });

    test('shows only percent and size before the estimate is stable', () {
      final clock = _Clock();
      final meter = TransferMeter(() => clock.now)..record(0);
      clock.advance(const Duration(seconds: 1));
      meter.record(1024 * 1024);
      expect(
        formatTransferLine(
          sent: 1024 * 1024,
          total: 100 * 1024 * 1024,
          meter: meter,
        ),
        '1% of 100.0 MB',
      );
    });

    test('drops the estimate while reconnecting', () {
      final clock = _Clock();
      final meter = steady(clock);
      expect(
        formatTransferLine(
          sent: 40 * 1024 * 1024,
          total: 400 * 1024 * 1024,
          meter: meter,
          reconnecting: true,
        ),
        'Reconnecting at 10%…',
      );
    });

    test('an unknown total shows bytes and rate without a percent', () {
      final clock = _Clock();
      final meter = steady(clock);
      expect(
        formatTransferLine(sent: 40 * 1024 * 1024, total: null, meter: meter),
        '40.0 MB · 10.0 MB/s',
      );
    });
  });
}
