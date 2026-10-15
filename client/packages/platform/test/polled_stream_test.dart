// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the shared poller behaves when a read is slow or never answers.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/polled_stream.dart';

const _tick = Duration(milliseconds: 20);

Future<void> _pause(int ticks) => Future<void>.delayed(_tick * ticks);

void main() {
  test('a read that never completes is not started again every tick', () async {
    var calls = 0;
    final sub = polledStream<int>(
      interval: _tick,
      readTimeout: const Duration(minutes: 5),
      read: () {
        calls++;
        return Completer<int?>().future;
      },
    ).listen((_) {});

    await _pause(10);
    await sub.cancel();
    expect(calls, 1);
  });

  test('a read past its timeout reads as nothing and polling resumes',
      () async {
    var calls = 0;
    final seen = <int?>[];
    final sub = polledStream<int>(
      interval: _tick,
      readTimeout: _tick * 2,
      read: () {
        calls++;
        return calls == 1 ? Completer<int?>().future : Future.value(7);
      },
    ).listen(seen.add);

    await _pause(15);
    await sub.cancel();
    expect(seen, [null, 7]);
  });

  test('a read that finishes frees the next tick', () async {
    var calls = 0;
    final sub = polledStream<int>(
      interval: _tick,
      read: () async => ++calls,
    ).listen((_) {});

    await _pause(10);
    await sub.cancel();
    expect(calls, greaterThan(3));
  });

  test(
      'cancel waits out a read part way through, so nothing is sent after it '
      'resolves', () async {
    final steps = <String>[];
    final secondStep = Completer<void>();
    final sub = polledStream<int>(
      interval: const Duration(hours: 1),
      read: () async {
        steps.add('first');
        await secondStep.future;
        steps.add('second');
        return 1;
      },
    ).listen((_) {});
    await _pause(1);

    final cancelled = sub.cancel();
    secondStep.complete();
    await cancelled;
    final atCancel = List.of(steps);
    await _pause(3);

    expect(atCancel, ['first', 'second']);
    expect(steps, atCancel);
  });
}
