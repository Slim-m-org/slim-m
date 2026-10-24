// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bringing off-board content back in updates the canvas dock's undo button.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets('bring into board enables undo button in canvas dock', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasNoteJson('far', x: 4000)];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    await pumpCanvasPane(tester, container, board: true);
    await tester.pumpAndSettle();

    final document = surfaceDocument(tester);
    expect(document.idsOutsideBoard, contains('far'));

    final bringIn = find.textContaining('bring in');
    expect(bringIn, findsOneWidget);
    await tester.tap(bringIn);
    await tester.pumpAndSettle();

    final undoFinder = find.byWidgetPredicate(
      (w) => w is AppIconButton && w.semanticLabel == 'Undo',
    );
    expect(undoFinder, findsOneWidget);
    final button = tester.widget<AppIconButton>(undoFinder);
    expect(
      button.onPressed,
      isNotNull,
      reason: 'undo must be enabled after bring-in',
    );
  });
}
