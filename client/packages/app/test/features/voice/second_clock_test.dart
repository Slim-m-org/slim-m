// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared call clock runs only while a readout is mounted and the window is
/// on screen, focused or not, and one timer serves every readout.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/second_clock.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _app({bool enabled = true, int readouts = 3}) {
  final since = DateTime.now();
  return MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: TickerMode(
      enabled: enabled,
      child: Column(
        children: [
          for (var i = 0; i < readouts; i++) CallDuration(since: since),
        ],
      ),
    ),
  );
}

final clock = SecondClock.instance;

void _setLifecycle(WidgetTester tester, AppLifecycleState state) =>
    tester.binding.handleAppLifecycleStateChanged(state);

/// Counts the shared clock's ticks while [body] runs, and never leaves the counter subscribed.
Future<void> _countingTicks(
  Future<void> Function(int Function() ticks) body,
) async {
  var count = 0;
  void tick() => count++;
  clock.addListener(tick);
  try {
    await body(() => count);
  } finally {
    clock.removeListener(tick);
  }
}

void main() {
  testWidgets('three readouts share one running timer', (tester) async {
    await tester.pumpWidget(_app());
    expect(clock.isRunning, isTrue);

    await tester.pumpWidget(const SizedBox());
    expect(clock.isRunning, isFalse);
  });

  testWidgets('an unfocused window keeps every readout ticking', (
    tester,
  ) async {
    addTearDown(() => _setLifecycle(tester, AppLifecycleState.resumed));
    await tester.pumpWidget(_app());
    await _countingTicks((ticks) async {
      _setLifecycle(tester, AppLifecycleState.inactive);
      final before = ticks();
      await tester.pump(const Duration(seconds: 3));
      expect(clock.isRunning, isTrue);
      expect(ticks() - before, 3);
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a hidden window stops the timer and showing it catches up', (
    tester,
  ) async {
    addTearDown(() => _setLifecycle(tester, AppLifecycleState.resumed));
    await tester.pumpWidget(_app());
    await _countingTicks((ticks) async {
      _setLifecycle(tester, AppLifecycleState.inactive);
      _setLifecycle(tester, AppLifecycleState.hidden);
      expect(clock.isRunning, isFalse);
      final before = ticks();
      await tester.pump(const Duration(seconds: 3));
      expect(ticks(), before);

      _setLifecycle(tester, AppLifecycleState.inactive);
      expect(clock.isRunning, isTrue);
      expect(ticks(), before + 1);
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a covered readout does not subscribe', (tester) async {
    await tester.pumpWidget(_app(enabled: false));
    expect(clock.isRunning, isFalse);

    await tester.pumpWidget(_app());
    expect(clock.isRunning, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
