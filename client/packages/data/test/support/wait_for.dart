// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Waiting on a drift stream by what it emitted, not by a guessed delay.
library;

import 'package:flutter_test/flutter_test.dart';

/// Polls [condition] until it holds, failing with [reason] after [timeout].
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String reason = 'the stream never emitted what the test waits for',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
