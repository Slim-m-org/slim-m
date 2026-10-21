// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-089: Escape must dismiss an open canvas menu before the pane's own
/// fullscreen binding gets it.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';

import 'canvas_pane_harness.dart';

void main() {
  testWidgets('Escape closes the open menu and leaves fullscreen alone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture()
      ..objects = [canvasNoteJson('b', x: 50, seq: 2)];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    container.read(canvasFullscreenProvider.notifier).state = 'c1';
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tapAt(
      screenFor(tester, const Offset(60, 20)),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Send to back'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      find.text('Send to back'),
      findsNothing,
      reason: 'Escape dismisses the menu',
    );
    expect(
      container.read(canvasFullscreenProvider),
      'c1',
      reason: 'the menu consumed Escape, so fullscreen stays',
    );
  });
}
