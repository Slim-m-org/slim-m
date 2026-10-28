// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Escape closes a docked thread rather than swallowing the key in canvas.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/threads.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets('Escape closes a docked thread while canvas has focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    container.read(openThreadProvider.notifier).state = 'thread_1';

    await pumpCanvasPane(tester, container, board: true);
    await tester.pumpAndSettle();

    expect(container.read(openThreadProvider), 'thread_1');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(container.read(openThreadProvider), isNull);
  });
}
