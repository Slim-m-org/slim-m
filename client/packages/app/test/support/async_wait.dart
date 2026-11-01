// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Waiting for real async work in a widget test without guessing how long it
/// takes.
///
/// `canvas_convergence_harness.dart`'s `settle()` drains microtasks, which is
/// the right tool when the work is instant and only ordering matters. This is
/// for the other case: a mocked HTTP round trip plus an image decode, which
/// needs real elapsed time, and where the usual reach is a
/// `Future.delayed(someGuess)` inside `tester.runAsync`.
///
/// A guessed delay encodes how fast the machine was the day it was written.
/// `canvas_pane_test.dart` waited 20ms for a fetch and decode; that held on a
/// developer box and was a coin toss on a loaded CI runner, which failed main
/// three times in four days. Polling for the thing you are actually waiting for
/// costs nothing when it is fast and only fails when it genuinely never
/// happened.
library;

import 'package:flutter_test/flutter_test.dart';

/// Polls [condition] until it holds, then settles the tree.
///
/// [condition] is read outside the widget pump, so it must be about model state
/// a pump is not required to observe - a hydrated image slot, a completed
/// fetch - and not about rendered pixels.
///
/// Fails with [reason] if [timeout] passes first, which is the honest outcome:
/// the thing under test did not happen, rather than the test not having waited.
Future<void> waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String reason = 'the condition never became true',
}) async {
  var satisfied = false;
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) {
        satisfied = true;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    satisfied = condition();
  });
  await tester.pumpAndSettle();
  if (!satisfied) {
    fail('$reason (waited ${timeout.inMilliseconds}ms)');
  }
}
