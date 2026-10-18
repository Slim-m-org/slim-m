// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared call clock runs only while a readout is mounted, visible and the
/// app is focused, and one timer serves every readout.
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

void main() {
  final clock = SecondClock.instance;

  testWidgets('three readouts share one running timer', (tester) async {
    await tester.pumpWidget(_app());
    expect(clock.isRunning, isTrue);

    await tester.pumpWidget(const SizedBox());
    expect(clock.isRunning, isFalse);
  });

  testWidgets('an unfocused app stops the timer and focus restarts it', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(clock.isRunning, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(clock.isRunning, isTrue);
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
