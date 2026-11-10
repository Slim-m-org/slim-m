// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Waiting for real async work in a test by polling the thing itself.
library;

import 'dart:async';

/// Polls [condition] in real time until it holds, instead of sleeping a guessed delay.
///
/// Throws a [TimeoutException] with [reason] on timeout, so a hang fails here and not at a later assertion; under `testWidgets` it needs `tester.runAsync`.
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
