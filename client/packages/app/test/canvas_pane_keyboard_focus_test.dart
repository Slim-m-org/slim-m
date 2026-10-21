// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-096: the pane's keyboard focus is claimed only at mount, so a click on
/// the canvas after focus left must hand it back for Ctrl+Z to work.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets('clicking the canvas after focus left restores Ctrl+Z', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveTo(const Offset(160, 140));
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(fixture.postedOps, hasLength(1));
    expect(fixture.postedOps.single['kind'], 'remove');
  });
}
