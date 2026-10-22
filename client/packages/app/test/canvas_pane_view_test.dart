// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// the zoom chip's fit and Delete/Backspace over a selection, driven through the
/// full pane the same way `canvas_pane_ops_test.dart` drives erase, undo and
/// clear.
///
/// Split out once `canvas_pane_ops_test.dart` crossed the 500-line hard
/// limit adding these two: both act on the camera or the current selection
/// rather than on the ops controller's own undo stack, which is what the
/// original file is about. Both share `canvas_pane_harness.dart`'s fixture.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  /// The one route back once a temporary zoom has gone somewhere: the whole
  /// shared board when nothing is drawn.
  testWidgets('the zoom chip\'s fit brings the whole board back when empty', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true);
    await tester.pumpAndSettle();
    final document = surfaceDocument(tester);

    document.setCamera(const Camera(x: 4000, y: 1500, zoom: 3.2));
    expect(document.isFitted, isFalse);

    await tester.tap(find.byTooltip('Fit view'));
    await tester.pumpAndSettle();

    expect(document.isFitted, isTrue);
    expect(document.visibleBoard, canvasBoard);
  });

  testWidgets('the zoom chip\'s fit frames what is drawn', (tester) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasNoteJson('note', x: 1500)];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true);
    await tester.pumpAndSettle();
    final document = surfaceDocument(tester);
    final fitZoom = document.camera.zoom;

    await tester.tap(find.byTooltip('Fit view'));
    await tester.pumpAndSettle();

    expect(document.isFitted, isFalse);
    expect(document.camera.zoom, greaterThan(fitZoom));
    expect(document.contentBounds!.overlaps(document.worldView), isTrue);
  });

  testWidgets('the zoom chip\'s fit ignores objects outside the board', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()
      ..objects = [
        canvasNoteJson('note', x: 1500),
        canvasNoteJson('far', x: 9000, seq: 2),
      ];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true);
    await tester.pumpAndSettle();
    final document = surfaceDocument(tester);

    await tester.tap(find.byTooltip('Fit view'));
    await tester.pumpAndSettle();

    final bounds = document.boardContentBounds!;
    expect(bounds.right, lessThan(document.board!.right));
    expect(document.board!.contains(bounds.bottomRight), isTrue);
    expect(
      document.worldView.right,
      lessThanOrEqualTo(document.board!.right + 1),
    );
  });

  /// The desktop convention every other drawing surface honours: Delete or
  /// Backspace over the current Move-tool selection, not only the overflow
  /// menu's own "Delete" item.
  testWidgets('Delete removes the current selection for good', (tester) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasNoteJson('note', x: 400)];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    // A mouse click selects; a finger tap on a note opens its editor instead.
    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(415, 15)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(surfaceDocument(tester).selectedObjectId.value, 'note');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();

    expect(fixture.deletedObjects, ['note']);
    expect(fixture.postedOps, isEmpty);
    expect(surfaceDocument(tester).objectCount.value, 0);
  });

  /// Backspace is the second key that shape, note and text tools already
  /// train a person to reach for; both must delete, not only one of them.
  testWidgets('Backspace also removes the current selection', (tester) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasNoteJson('note', x: 400)];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(415, 15)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(fixture.deletedObjects, ['note']);
  });

  /// Nothing selected must mean nothing happens - no crash reaching into a
  /// null id, and no op posted for a selection that was never there.
  testWidgets('Delete with nothing selected posts no op', (tester) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasNoteJson('note', x: 400)];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    expect(surfaceDocument(tester).selectedObjectId.value, isNull);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();

    expect(fixture.postedOps, isEmpty);
    expect(surfaceDocument(tester).objectCount.value, 1);
  });

  /// docs/decisions/0011-per-channel-permissions.md, site 5's fourth call
  /// site, missed by that PR: `_onSelectStart`'s own local gate, not just
  /// the erase gate and the context menu.
  testWidgets(
    'the select tool cannot pick up another member\'s object when only the '
    'deployment-wide bit grants MANAGE_CANVAS, not the per-channel answer',
    (tester) async {
      final fixture =
          CanvasPaneFixture(
              mePermissions: Perm.manageCanvas,
              channelPermissions: 0,
            )
            ..objects = [
              canvasNoteJson('foreign', x: 400, authorId: 'someone-else'),
            ];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();
      final gesture = await tester.startGesture(
        screenFor(tester, const Offset(415, 15)),
      );
      await gesture.moveTo(screenFor(tester, const Offset(60, 60)));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(surfaceDocument(tester).selectedObjectId.value, isNull);
      expect(fixture.postedOps, isEmpty);
    },
  );

  /// canvas.md/overlays.md: the confirmation claimed clearing "cannot be
  /// undone" while the same dock's Undo control reverses it, server-backed.
  testWidgets(
    "the clear confirmation names the real Undo path, never claims it "
    "cannot be undone",
    (tester) async {
      final fixture = CanvasPaneFixture(mePermissions: Perm.manageCanvas)
        ..objects = [canvasObjectJson('a', x: 400)];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear canvas'));
      await tester.pumpAndSettle();

      expect(find.textContaining('cannot be undone'), findsNothing);
      expect(
        find.textContaining('You can undo this with Undo'),
        findsOneWidget,
      );
    },
  );
}
