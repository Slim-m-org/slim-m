// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A refusal or timeout that lands while the canvas is fullscreen must not
/// hand the pen back on the way out, and a stroke finished under a refusal is
/// never placed. A second pane that mounts under a refusal (the page fade
/// between two panes of one channel) opens on Pan.
library;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_forbidden_message.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

const _refused = "You don't have permission to draw here right now.";

void _expectArmed(WidgetTester tester, String label) => expect(
  tester.getSemantics(find.bySemanticsLabel(label)),
  isSemantics(isToggled: true),
  reason: '$label should be the armed tool',
);

void _report(ProviderContainer container, String message) =>
    container.read(canvasEngineProvider('c1').notifier).reportError(message);

Future<(CanvasPaneFixture, ProviderContainer)> _pump(
  WidgetTester tester, {
  int? timedOutUntil,
}) async {
  final fixture = CanvasPaneFixture()..timedOutUntil = timedOutUntil;
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  return (fixture, container);
}

Future<void> _enterFullscreen(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More canvas actions'));
  await tester.pump();
  await tester.tap(find.text('Enter fullscreen'));
  await pumpFrames(tester, frames: 30);
}

Future<void> _exitFullscreen(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Show controls'));
  await pumpFrames(tester, frames: 30);
  await tester.tap(find.bySemanticsLabel('Exit fullscreen'));
  await pumpFrames(tester, frames: 30);
}

Future<void> _drag(WidgetTester tester) async {
  final gesture = await tester.startGesture(const Offset(100, 100));
  await gesture.moveTo(const Offset(160, 140));
  await gesture.moveTo(const Offset(220, 200));
  await gesture.up();
  await pumpFrames(tester, frames: 30);
}

void main() {
  for (final timedOut in [false, true]) {
    final name = timedOut ? 'a timeout' : 'a refusal';
    testWidgets('$name in fullscreen leaves Pan armed on the way out', (
      tester,
    ) async {
      final until = clock.now().add(const Duration(hours: 1));
      final (fixture, container) = await _pump(
        tester,
        timedOutUntil: timedOut ? until.millisecondsSinceEpoch : null,
      );
      _expectArmed(tester, 'Pen');
      await _enterFullscreen(tester);

      _report(
        container,
        timedOut
            ? canvasDrawForbiddenMessage(until.millisecondsSinceEpoch)
            : _refused,
      );
      await tester.pump();
      await _exitFullscreen(tester);

      _expectArmed(tester, 'Pan');
      await _drag(tester);
      expect(fixture.posted, isEmpty);
    });
  }

  testWidgets('a stroke finished after a refusal landed is not placed', (
    tester,
  ) async {
    final (fixture, container) = await _pump(tester);
    _expectArmed(tester, 'Pen');
    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveTo(const Offset(160, 140));

    _report(container, _refused);
    await tester.pump();
    await gesture.moveTo(const Offset(220, 200));
    await gesture.up();
    await pumpFrames(tester, frames: 30);

    expect(fixture.posted, isEmpty);
    expect(surfaceDocument(tester).objectCount.value, 0);
  });

  testWidgets('a second pane that mounts under a refusal opens on Pan', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await tester.pumpWidget(_panes(container, count: 1));
    await pumpFrames(tester);
    _report(container, _refused);
    await tester.pump();

    await tester.pumpWidget(_panes(container, count: 2));
    await pumpFrames(tester);

    final second = find.descendant(
      of: find.byKey(const ValueKey(1)),
      matching: find.bySemanticsLabel('Pan'),
    );
    expect(tester.getSemantics(second), isSemantics(isToggled: true));
  });
}

Widget _panes(ProviderContainer container, {required int count}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Row(
            children: [
              for (var i = 0; i < count; i++)
                Expanded(
                  child: CanvasPane(key: ValueKey(i), channelId: 'c1'),
                ),
            ],
          ),
        ),
      ),
    );
