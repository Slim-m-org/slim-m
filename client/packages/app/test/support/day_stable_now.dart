// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A wall-clock "now" that calendar-day assertions can seed data around without
/// the run straddling local midnight.
///
/// The app stamps a sent message with `DateTime.now()` itself, so a test cannot
/// pin that instant. What it can do is refuse to start within seconds of a
/// day boundary, which is the only window where "seeded just before now" and
/// "sent now" land on different days.
library;

import 'package:flutter_test/flutter_test.dart';

const _leadAfterMidnight = Duration(seconds: 10);
const _tailBeforeMidnight = Duration(seconds: 30);

/// How long to wait from [now] until it is at least [_leadAfterMidnight] past
/// and [_tailBeforeMidnight] short of a local midnight; zero when it already is.
Duration waitForStableDay(DateTime now) {
  final sinceMidnight = now.difference(DateTime(now.year, now.month, now.day));
  if (sinceMidnight < _leadAfterMidnight) {
    return _leadAfterMidnight - sinceMidnight;
  }
  final untilMidnight = DateTime(
    now.year,
    now.month,
    now.day + 1,
  ).difference(now);
  if (untilMidnight < _tailBeforeMidnight) {
    return untilMidnight + _leadAfterMidnight;
  }
  return Duration.zero;
}

/// Epoch milliseconds for "now", after waiting out [waitForStableDay] in real time.
Future<int> dayStableNowMs(WidgetTester tester) async {
  final wait = waitForStableDay(DateTime.now());
  if (wait > Duration.zero) {
    await tester.runAsync(() => Future<void>.delayed(wait));
  }
  return DateTime.now().millisecondsSinceEpoch;
}
