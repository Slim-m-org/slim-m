// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Waiting for real async work in a test by polling the thing itself.
library;

import 'dart:async';

/// Polls [condition], which may be async, in real time until it holds.
///
/// A guessed delay encodes how fast the machine was the day it was written; a
/// poll costs nothing when the work is fast. Throws a [TimeoutException]
/// carrying [reason] when [timeout] passes first, so a hang fails here and not
/// at a later assertion about some unrelated value.
///
/// Inside `testWidgets` it only ticks under `tester.runAsync`, where time is real.
Future<void> pollUntil(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 5),
  String reason = 'the condition never became true',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (!DateTime.now().isBefore(deadline)) {
      throw TimeoutException(reason, timeout);
    }
    await Future<void>.delayed(interval);
  }
}
