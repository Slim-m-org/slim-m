// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared call clock runs only while a readout is mounted and the window is
/// on screen, focused or not, and one timer serves every readout. It reads the
/// app's own lifecycle, which corrects a minimise or a stale state the embedder reports.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
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

/// Points the clock at a fresh lifecycle provider for this test; returns its window events.
StreamController<DesktopWindowEventKind> _followNewLifecycle() {
  final events = StreamController<DesktopWindowEventKind>.broadcast(sync: true);
  final container = ProviderContainer(
    overrides: [
      appLifecycleProvider.overrideWith(
        (ref) =>
            AppLifecycleNotifier(mobile: false, windowEvents: events.stream),
      ),
    ],
  );
  clock.follow(container);
  addTearDown(() async {
    clock.follow(null);
    container.dispose();
    await events.close();
  });
  return events;
}

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
  setUp(_followNewLifecycle);

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

  testWidgets('a minimise the window reports stops the timer', (tester) async {
    addTearDown(() => _setLifecycle(tester, AppLifecycleState.resumed));
    final events = _followNewLifecycle();
    await tester.pumpWidget(_app());
    await _countingTicks((ticks) async {
      _setLifecycle(tester, AppLifecycleState.inactive);
      events.add(DesktopWindowEventKind.minimize);
      expect(clock.isRunning, isFalse);
      final before = ticks();
      await tester.pump(const Duration(seconds: 3));
      expect(ticks(), before);

      events.add(DesktopWindowEventKind.show);
      expect(clock.isRunning, isTrue);
      expect(ticks(), before + 1);
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('focus restarts a timer a stale hidden state stopped', (
    tester,
  ) async {
    addTearDown(() => _setLifecycle(tester, AppLifecycleState.resumed));
    final events = _followNewLifecycle();
    await tester.pumpWidget(_app());
    await _countingTicks((ticks) async {
      _setLifecycle(tester, AppLifecycleState.inactive);
      _setLifecycle(tester, AppLifecycleState.hidden);
      expect(clock.isRunning, isFalse);

      events.add(DesktopWindowEventKind.focus);
      expect(clock.isRunning, isTrue);
      final before = ticks();
      await tester.pump(const Duration(seconds: 3));
      expect(ticks() - before, 3);
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
