// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane's erase, undo and clear controls, driven through the
/// full pane rather than the ops controller directly: this is what proves
/// the tool toggle, the undo button, Ctrl+Z and the overflow clear menu are
/// actually wired to it. `canvas_pane_test.dart` covers fetch, live frames
/// and a plain drag; `canvas_pane_view_test.dart` covers Recenter view and
/// Delete/Backspace over a selection, split out once this file crossed the
/// 500-line hard limit.
library;

import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_pane_harness.dart';

void main() {
  /// Undo is one op, not one per segment `splitStroke` might have minted:
  /// this is the property section 9 names as "the likeliest thing this
  /// slice breaks" if a future change issues a remove per id instead.
  testWidgets('the undo button removes a just-drawn stroke in one op', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveTo(const Offset(160, 140));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(fixture.posted, hasLength(1));
    expect(surfaceDocument(tester).objectCount.value, 1);

    await tester.tap(find.bySemanticsLabel('Undo'));
    await tester.pumpAndSettle();

    expect(fixture.postedOps, hasLength(1));
    expect(fixture.postedOps.single['kind'], 'remove');
    expect(fixture.postedOps.single['object_ids'], [
      fixture.posted.single['id'],
    ]);
    expect(surfaceDocument(tester).objectCount.value, 0);
  });

  testWidgets('Ctrl+Z undoes the last drawn gesture', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveTo(const Offset(160, 140));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(surfaceDocument(tester).objectCount.value, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(fixture.postedOps, hasLength(1));
    expect(fixture.postedOps.single['kind'], 'remove');
    expect(surfaceDocument(tester).objectCount.value, 0);
  });

  /// The reviewable criterion in the round: an eraser drag must visibly do
  /// nothing to ink it cannot touch, not send a request the server would
  /// refuse anyway.
  testWidgets(
    'the eraser leaves another member\'s stroke alone without MANAGE_CANVAS',
    (tester) async {
      final fixture = CanvasPaneFixture()
        ..objects = [
          canvasObjectJson('foreign', x: 0, authorId: 'someone-else'),
        ];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();
      expect(surfaceDocument(tester).objectCount.value, 1);

      await tester.tap(find.bySemanticsLabel('Eraser'));
      await tester.pump();

      final point = screenFor(tester, const Offset(10, 20));
      final gesture = await tester.startGesture(point);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(fixture.postedOps, isEmpty);
      expect(surfaceDocument(tester).objectCount.value, 1);
    },
  );

  testWidgets('the eraser removes another member\'s stroke with '
      'MANAGE_CANVAS, in one op', (tester) async {
    final fixture = CanvasPaneFixture(mePermissions: Perm.manageCanvas)
      ..objects = [canvasObjectJson('foreign', x: 0, authorId: 'someone-else')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    expect(surfaceDocument(tester).objectCount.value, 1);

    await tester.tap(find.bySemanticsLabel('Eraser'));
    await tester.pump();

    final point = screenFor(tester, const Offset(10, 20));
    final gesture = await tester.startGesture(point);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(fixture.postedOps, hasLength(1));
    expect(fixture.postedOps.single['kind'], 'remove');
    expect(fixture.postedOps.single['object_ids'], ['foreign']);
    expect(surfaceDocument(tester).objectCount.value, 0);
  });

  /// docs/decisions/0011-per-channel-permissions.md, site 5's third call
  /// site: `_onErase`'s own local gate, not just the context menu's.
  testWidgets('the eraser leaves another member\'s stroke alone when only the '
      'deployment-wide bit grants MANAGE_CANVAS, not the per-channel answer', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture(
      mePermissions: Perm.manageCanvas,
      channelPermissions: 0,
    )..objects = [canvasObjectJson('foreign', x: 0, authorId: 'someone-else')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    expect(surfaceDocument(tester).objectCount.value, 1);

    await tester.tap(find.bySemanticsLabel('Eraser'));
    await tester.pump();

    final point = screenFor(tester, const Offset(10, 20));
    final gesture = await tester.startGesture(point);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(fixture.postedOps, isEmpty);
    expect(surfaceDocument(tester).objectCount.value, 1);
  });

  /// The clear control is gated on MANAGE_CANVAS and hidden entirely below
  /// it, matching every other moderation control in this client.
  testWidgets(
    'the overflow offers no Clear canvas item without MANAGE_CANVAS',
    (tester) async {
      final fixture = CanvasPaneFixture()..objects = [canvasObjectJson('a')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();

      expect(find.text('Clear canvas'), findsNothing);
    },
  );

  /// docs/decisions/0011-per-channel-permissions.md, site 5: the deployment-
  /// wide bit is not the one that governs a channel-scoped bit like
  /// MANAGE_CANVAS. A caller whose base grants it but whose per-channel
  /// answer does not must see the same absence a caller with neither does.
  testWidgets(
    'the overflow offers no Clear canvas item when only the deployment-wide '
    'bit grants MANAGE_CANVAS, not the per-channel answer',
    (tester) async {
      final fixture = CanvasPaneFixture(
        mePermissions: Perm.manageCanvas,
        channelPermissions: 0,
      )..objects = [canvasObjectJson('a')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();

      expect(find.text('Clear canvas'), findsNothing);
    },
  );

  testWidgets(
    'the clear control reaches the canvas: confirm, then one clear op',
    (tester) async {
      final fixture = CanvasPaneFixture(mePermissions: Perm.manageCanvas)
        ..objects = [canvasObjectJson('a'), canvasObjectJson('b', x: 50)];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();
      expect(surfaceDocument(tester).objectCount.value, 2);

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear canvas'));
      await tester.pumpAndSettle();
      expect(find.textContaining('all 2 objects'), findsOneWidget);

      await tester.tap(find.text('Clear canvas').last);
      await tester.pumpAndSettle();

      expect(fixture.postedOps, hasLength(1));
      expect(fixture.postedOps.single['kind'], 'clear');
      expect(surfaceDocument(tester).objectCount.value, 0);
    },
  );

  /// `_onClear` was the one action of five (draw, move, erase, undo, clear)
  /// that never called `setState` after completing, so `CanvasBar`'s own
  /// `canUndo` prop kept whatever value it held at the pane's last build -
  /// stale for as long as nothing unrelated happened to rebuild it. Reachable
  /// only when a clear is the pane's *first* undoable action, since a prior
  /// draw, move or erase already leaves `canUndo` true and so already shows
  /// correctly by coincidence - the same shape as the thread bug where every
  /// existing test seeded a row a URL-opened thread never had.
  testWidgets(
    'the undo button reflects a clear that is the first undoable action',
    (tester) async {
      final fixture = CanvasPaneFixture(mePermissions: Perm.manageCanvas)
        ..objects = [canvasObjectJson('a')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      AppIconButton undoButton() => tester.widget<AppIconButton>(
        find.byWidgetPredicate(
          (w) => w is AppIconButton && w.semanticLabel == 'Undo',
        ),
      );
      expect(undoButton().onPressed, isNull);

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear canvas'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear canvas').last);
      await tester.pumpAndSettle();

      expect(fixture.postedOps, hasLength(1));
      expect(
        undoButton().onPressed,
        isNotNull,
        reason:
            'a clear pushes an undo entry just like a draw or an erase '
            'does, and the button must reflect that without needing an '
            'unrelated rebuild to happen along first',
      );
    },
  );

  /// The reviewable criterion for move: dragging an image with the select
  /// tool previews the new position at once and commits it as one op on
  /// release, the same "one gesture, one op" shape undo already relies on.
  testWidgets(
    'dragging with the select tool moves an image and posts one move op',
    (tester) async {
      final fixture = CanvasPaneFixture()..objects = [canvasImageJson('img')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();

      final start = screenFor(tester, const Offset(15, 15));
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(screenFor(tester, const Offset(45, 35)));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(fixture.postedOps, hasLength(1));
      expect(fixture.postedOps.single['kind'], 'move');
      expect(fixture.postedOps.single['object_id'], 'img');
      expect(fixture.postedOps.single['x'], 40);
      expect(fixture.postedOps.single['y'], 30);

      final bounds = surfaceDocument(tester).objectBounds('img')!;
      expect(bounds.x, 40);
      expect(bounds.y, 30);
    },
  );

  /// Move is scoped to box kinds: `beginSelect` hit-tests everything except
  /// a stroke, so a drag starting over one picks nothing up and submits
  /// nothing.
  testWidgets(
    'move is scoped to box kinds: dragging over a stroke does nothing',
    (tester) async {
      final fixture = CanvasPaneFixture()..objects = [canvasObjectJson('a')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();

      final start = screenFor(tester, const Offset(15, 15));
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(screenFor(tester, const Offset(45, 35)));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(fixture.postedOps, isEmpty);
      final bounds = surfaceDocument(tester).objectBounds('a')!;
      expect(bounds.x, 10);
      expect(bounds.y, 10);
    },
  );

  /// The positive half of the test above: a note is a box kind too, so the
  /// same drag that does nothing over a stroke does move a note.
  testWidgets(
    'dragging with the select tool moves a note and posts one move op',
    (tester) async {
      final fixture = CanvasPaneFixture()..objects = [canvasNoteJson('note')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();

      final start = screenFor(tester, const Offset(15, 15));
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(screenFor(tester, const Offset(45, 35)));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(fixture.postedOps, hasLength(1));
      expect(fixture.postedOps.single['kind'], 'move');
      expect(fixture.postedOps.single['object_id'], 'note');

      final bounds = surfaceDocument(tester).objectBounds('note')!;
      expect(bounds.x, 40);
      expect(bounds.y, 30);
    },
  );

  /// A note has no other way to be corrected or withdrawn once placed - see
  /// `canvas_note_sheet.dart`'s own doc for why there is no in-place edit -
  /// so selecting it and deleting it is the only route to fixing a mistake
  /// short of clearing the whole canvas.
  testWidgets(
    'selecting a note and choosing Delete removes it in one op, and undo '
    'restores it',
    (tester) async {
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

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(fixture.postedOps, hasLength(1));
      expect(fixture.postedOps.single['kind'], 'remove');
      expect(fixture.postedOps.single['object_ids'], ['note']);
      expect(surfaceDocument(tester).objectCount.value, 0);
      expect(
        surfaceDocument(tester).selectedObjectId.value,
        isNull,
        reason: 'a deleted object must not linger as the current selection',
      );

      await tester.tap(find.bySemanticsLabel('Undo'));
      await tester.pumpAndSettle();

      expect(fixture.postedOps, hasLength(2));
      expect(fixture.postedOps.last['kind'], 'restore');
      expect(fixture.postedOps.last['target_op'], 'server-op-1');
    },
  );

  /// A move already shows its new position optimistically (the property the
  /// first test above checks); a failed submit has to put that back, the
  /// same "put back what was already shown" shape a failed remove gets from
  /// a region read (`canvas_pane_remove_failure_test.dart`).
  testWidgets('a failed move reverts the object locally and shows an error', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture(opsPostStatus: 403)
      ..objects = [canvasImageJson('img')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    final start = screenFor(tester, const Offset(15, 15));
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(screenFor(tester, const Offset(45, 35)));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(fixture.postedOps, isEmpty);
    expect(find.text('That could not be moved.'), findsOneWidget);

    final bounds = surfaceDocument(tester).objectBounds('img')!;
    expect(bounds.x, 10, reason: 'a failed move must put the image back');
    expect(bounds.y, 10);
  });

  /// The server empties a restore frame's id list rather than exceed the
  /// bound a `remove` sets, so an empty list means "more than I can name",
  /// never "nothing". Applying it would clear no tombstone while advancing
  /// the cursor past the only op that could, leaving those objects invisible
  /// on this client permanently. Reachable only since clear got a caller.
  testWidgets('a restore frame carrying no ids asks the feed rather than '
      'advancing past it', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    final settled = fixture.opsGets;

    fixture.events.add(
      const api.CanvasObjectsRestored(
        channelId: 'c1',
        seq: 1,
        opId: 'op-1',
        objectIds: <String>[],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      fixture.opsGets,
      greaterThan(settled),
      reason:
          'an unenumerable restore must be reconciled from the feed, which '
          'carries the full list, rather than trusted as an empty apply',
    );
  });
}
