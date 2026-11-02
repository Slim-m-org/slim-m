// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Escape with a drawing tool armed: close an open popover first, then drop a
/// half-drawn stroke, then put the tool down to Pan, and never leave
/// fullscreen in the same press.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_pane_harness.dart';

Future<void> _settle(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 500));

bool _active(WidgetTester tester, String label) =>
    tester
        .widget<AppIconButton>(
          find.ancestor(
            of: find.bySemanticsLabel(label),
            matching: find.byWidgetPredicate((w) => w is AppIconButton),
          ),
        )
        .active ==
    true;

Future<ProviderContainer> _open(
  WidgetTester tester,
  CanvasPaneFixture fixture,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await _settle(tester);
  return container;
}

Future<void> _escape(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await _settle(tester);
}

void main() {
  testWidgets('Escape with the pen armed puts the tool down to Pan', (
    tester,
  ) async {
    await _open(tester, CanvasPaneFixture());
    expect(_active(tester, 'Pen'), isTrue, reason: 'baseline');

    await _escape(tester);

    expect(_active(tester, 'Pan'), isTrue);
    expect(_active(tester, 'Pen'), isFalse);
  });

  testWidgets('Escape with Pan armed changes nothing', (tester) async {
    await _open(tester, CanvasPaneFixture());
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    await _escape(tester);

    expect(_active(tester, 'Pan'), isTrue);
  });

  testWidgets('Escape mid-stroke drops the stroke and keeps the pen armed', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    await _open(tester, fixture);

    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(200, 200)),
    );
    await gesture.moveTo(screenFor(tester, const Offset(260, 240)));
    await gesture.moveTo(screenFor(tester, const Offset(320, 260)));
    await _escape(tester);
    expect(_active(tester, 'Pen'), isTrue, reason: 'the stroke took the press');
    await gesture.up();
    await _settle(tester);

    expect(fixture.posted, isEmpty, reason: 'a cancelled stroke is never sent');

    await _escape(tester);
    expect(_active(tester, 'Pan'), isTrue, reason: 'the next press drops it');
  });

  testWidgets('Escape closes the open pen options before touching the tool', (
    tester,
  ) async {
    await _open(tester, CanvasPaneFixture());
    await tester.tap(find.byIcon(AppIcons.chevronDown).first);
    await _settle(tester);
    expect(find.byTooltip('Coral'), findsOneWidget, reason: 'baseline');

    await _escape(tester);

    expect(find.byTooltip('Coral'), findsNothing);
    expect(_active(tester, 'Pen'), isTrue);

    await _escape(tester);
    expect(_active(tester, 'Pan'), isTrue);
  });

  testWidgets('Escape in fullscreen drops the tool first, then leaves', (
    tester,
  ) async {
    final container = await _open(tester, CanvasPaneFixture());
    container.read(canvasFullscreenProvider.notifier).state = 'c1';
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await _settle(tester);

    await _escape(tester);
    expect(container.read(canvasFullscreenProvider), 'c1');

    await _escape(tester);
    expect(container.read(canvasFullscreenProvider), isNull);
  });
}
