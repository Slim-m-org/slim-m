// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Content past the board's edge is announced, can be brought back on through
/// the op log, and no tile or drag can leave the board. Decision 0080.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

CanvasStrokeInput _legacyShape(String id, Rect box) => CanvasStrokeInput(
  id: id,
  seq: 1,
  zIndex: 1,
  x: box.left,
  y: box.top,
  w: box.width,
  h: box.height,
  points: const [],
  width: 0,
  colorKey: 'ink',
  authorId: 'me',
  kind: CanvasObjectKind.shape,
  shapeKind: CanvasShapeKind.rectangle,
);

void main() {
  testWidgets('legacy content outside the board is announced and brought in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);
    final document = surfaceDocument(tester)
      ..applyPlaced(
        _legacyShape('far', const Rect.fromLTWH(2400, 1300, 300, 200)),
      )
      ..refresh();
    await tester.pump();

    final notice = find.text('1 outside the board - bring in');
    expect(notice, findsOneWidget);
    await tester.tap(notice);
    await tester.pumpAndSettle();

    final box = document.objectBounds('far')!;
    expect(
      canvasBoard.inflate(1e-6).contains(Offset(box.x + box.w, box.y + box.h)),
      isTrue,
    );
    expect(fixture.postedOps.single['kind'], 'move');
    expect(fixture.postedOps.single['object_id'], 'far');
    expect(document.outsideBoardCount.value, 0);
    expect(notice, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the pane holds tiles to the board', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);
    final overrides = container
        .read(canvasEngineProvider('c1').notifier)
        .tileOverrides;

    overrides.setRect('camera:a', const Rect.fromLTWH(1900, 1070, 220, 160));

    final rect = overrides.stateFor('camera:a').rect!;
    expect(rect.right, lessThanOrEqualTo(canvasBoard.right));
    expect(rect.bottom, lessThanOrEqualTo(canvasBoard.bottom));
    await tester.pumpWidget(const SizedBox());
  });
}
