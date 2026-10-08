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

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

void main() {
  /// The one route back once panning or zooming has gone somewhere nothing
  /// is - see `worldLimit`'s own doc for why this was previously missing.
  /// An empty canvas has no content to fit, so the origin is still correct
  /// here - `cameraToFit`'s own fallback for a null `contentBounds`.
  testWidgets('the zoom chip\'s fit jumps an empty canvas back to the world '
      'origin', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    surfaceDocument(
      tester,
    ).setCamera(const Camera(x: 4000, y: -1500, zoom: 3.2));
    expect(
      surfaceDocument(tester).camera,
      const Camera(x: 4000, y: -1500, zoom: 3.2),
    );

    await tester.tap(find.byTooltip('Fit view'));
    await tester.pumpAndSettle();

    expect(surfaceDocument(tester).camera, const Camera());
  });

  /// With real content, Recenter fits that content into view rather than
  /// resetting to the origin - the bug this replaced: "Recenter" used to be
  /// "reset to origin" regardless of where the drawing actually lived.
  testWidgets('the zoom chip\'s fit fits content placed away from the '
      'origin into view, not the world origin', (tester) async {
    final fixture = CanvasPaneFixture()
      ..objects = [canvasNoteJson('note', x: 5000)];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    surfaceDocument(
      tester,
    ).setCamera(const Camera(x: -9000, y: -9000, zoom: 3.2));

    await tester.tap(find.byTooltip('Fit view'));
    await tester.pumpAndSettle();

    final view = surfaceDocument(tester).worldView;
    final bounds = surfaceDocument(tester).contentBounds!;
    expect(
      view.overlaps(bounds) && view.contains(bounds.center),
      isTrue,
      reason: 'the note at world x=5000 must land inside the new view',
    );
  });

  /// The desktop convention every other drawing surface honours: Delete or
  /// Backspace over the current Move-tool selection, not only the overflow
  /// menu's own "Delete" item.
  testWidgets('Delete removes the current selection and posts one remove op', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()..objects = [canvasNoteJson('note')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(15, 15)),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(surfaceDocument(tester).selectedObjectId.value, 'note');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();

    expect(fixture.postedOps, hasLength(1));
    expect(fixture.postedOps.single['kind'], 'remove');
    expect(fixture.postedOps.single['object_ids'], ['note']);
    expect(surfaceDocument(tester).objectCount.value, 0);
  });

  /// Backspace is the second key that shape, note and text tools already
  /// train a person to reach for; both must delete, not only one of them.
  testWidgets('Backspace also removes the current selection', (tester) async {
    final fixture = CanvasPaneFixture()..objects = [canvasNoteJson('note')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(15, 15)),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(fixture.postedOps, hasLength(1));
    expect(fixture.postedOps.single['kind'], 'remove');
  });

  /// Nothing selected must mean nothing happens - no crash reaching into a
  /// null id, and no op posted for a selection that was never there.
  testWidgets('Delete with nothing selected posts no op', (tester) async {
    final fixture = CanvasPaneFixture()..objects = [canvasNoteJson('note')];
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
      final fixture = CanvasPaneFixture(
        mePermissions: Perm.manageCanvas,
        channelPermissions: 0,
      )..objects = [canvasNoteJson('foreign', authorId: 'someone-else')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();
      final gesture = await tester.startGesture(
        screenFor(tester, const Offset(15, 15)),
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
        ..objects = [canvasObjectJson('a')];
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
