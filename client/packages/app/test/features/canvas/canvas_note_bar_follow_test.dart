// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The style bar over a note being placed stays next to that note when the board pans or zooms.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_selection_bar.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

final _editorRect = find.byKey(const ValueKey('canvas-note-editor-rect'));
final _bar = find.byWidgetPredicate((w) => w is CanvasSelectionBar);

Future<void> _placeDraft(
  WidgetTester tester,
  Size size, {
  int permissions = Perm.manageCanvas,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture(mePermissions: permissions);
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, tool: 'Pen');
  await pumpFrames(tester);
  await tester.tap(find.bySemanticsLabel('Note'));
  await tester.pump();
  final gesture = await tester.startGesture(
    screenFor(tester, const Offset(300, 200)),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await pumpFrames(tester, frames: 15);
}

void main() {
  testWidgets('the bar stays above its note after a pan', (tester) async {
    await _placeDraft(tester, const Size(1280, 800));
    expect(_editorRect, findsOneWidget);
    expect(_bar, findsOneWidget);

    surfaceDocument(tester).setCamera(const Camera(x: -250, y: -120));
    await pumpFrames(tester, frames: 5);

    final note = tester.getRect(_editorRect);
    final bar = tester.getRect(_bar);
    expect(bar.bottom, lessThanOrEqualTo(note.top));
    expect(note.top - bar.bottom, lessThan(24));
    expect((bar.center.dx - note.center.dx).abs(), lessThan(1));
  });

  testWidgets('a plain member gets the bar over their own draft', (
    tester,
  ) async {
    await _placeDraft(tester, const Size(1280, 800), permissions: 0);
    expect(_editorRect, findsOneWidget);
    expect(_bar, findsOneWidget);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('panning the note out of view ends the edit at $width', (
      tester,
    ) async {
      await _placeDraft(tester, Size(width, 800));
      expect(_editorRect, findsOneWidget);

      surfaceDocument(tester).setCamera(const Camera(x: 3000, y: 3000));
      await pumpFrames(tester, frames: 5);

      expect(_editorRect, findsNothing);
      expect(_bar, findsNothing);
      expect(surfaceDocument(tester).objectCount.value, 0);
    });
  }
}
