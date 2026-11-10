// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Proves `pollUntil` really waits for the condition and really fails when it
/// never holds, so a test using it cannot pass without the work happening.
library;

import 'dart:async';

import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:test/test.dart';

void main() {
  test('returns at once when the condition already holds', () async {
    final started = DateTime.now();

    await pollUntil(() => true, timeout: const Duration(seconds: 5));

    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 1)),
    );
  });

  test('polls until the condition flips', () async {
    var calls = 0;

    await pollUntil(() => ++calls >= 4,
        interval: const Duration(milliseconds: 1));

    expect(calls, 4);
  });

  test('fails with its reason and timeout when the condition never holds', () {
    expect(
      () => pollUntil(
        () => false,
        timeout: const Duration(milliseconds: 40),
        reason: 'the thing under test never happened',
      ),
      throwsA(
        isA<TimeoutException>()
            .having((e) => e.message, 'message',
                'the thing under test never happened')
            .having((e) => e.duration, 'duration',
                const Duration(milliseconds: 40)),
      ),
    );
  });

  test('waits on an async condition', () async {
    var calls = 0;

    await pollUntil(() async => ++calls >= 3);

    expect(calls, 3);
  });

  test('a condition that holds on the last poll still passes', () async {
    final flipsAt = DateTime.now().add(const Duration(milliseconds: 30));

    await pollUntil(
      () => DateTime.now().isAfter(flipsAt),
      timeout: const Duration(seconds: 5),
    );
  });
}
