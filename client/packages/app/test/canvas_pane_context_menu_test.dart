// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Report 4: a right-click over a canvas object, driven through the full
/// pane so the wiring from `_CanvasPaneState` down through `CanvasPaneBody`
/// to `CanvasObjectContextMenu` is what is actually under test, not just the
/// isolated widget `canvas_object_context_menu_test.dart` already covers.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets(
    'right-clicking an object reaches it: Send to back posts one reorder op',
    (tester) async {
      final fixture = CanvasPaneFixture()
        ..objects = [
          canvasObjectJson('a', seq: 1),
          canvasNoteJson('b', x: 400, seq: 2),
        ];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      final point = screenFor(tester, const Offset(410, 20));
      await tester.tapAt(point, buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Send to back'), findsOneWidget);
      await tester.tap(find.text('Send to back'));
      await tester.pumpAndSettle();

      expect(fixture.postedOps, hasLength(1));
      expect(fixture.postedOps.single['kind'], 'reorder');
      expect(fixture.postedOps.single['object_id'], 'b');
      expect(
        tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool,
        CanvasTool.pen,
        reason: 'the menu does not change the tool',
      );
    },
  );

  testWidgets('right-clicking empty canvas posts nothing and opens nothing', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasObjectJson('a', seq: 1)];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    final point = screenFor(tester, const Offset(500, 500));
    await tester.tapAt(point, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Send to back'), findsNothing);
    expect(fixture.postedOps, isEmpty);
    expect(surfaceDocument(tester).selectedObjectId.value, isNull);
  });

  testWidgets(
    "right-clicking somebody else's object without MANAGE_CANVAS reaches "
    'nothing',
    (tester) async {
      final fixture = CanvasPaneFixture()
        ..objects = [canvasNoteJson('b', x: 400, authorId: 'someone-else')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      final point = screenFor(tester, const Offset(410, 20));
      await tester.tapAt(point, buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Send to back'), findsNothing);
      expect(surfaceDocument(tester).selectedObjectId.value, isNull);
    },
  );
}
