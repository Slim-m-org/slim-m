// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas tools row in isolation: the pen/eraser toggle, the undo
/// button's enabled state, and the clear control's gating and confirm.
/// `canvas_tools_row_shape_kind_test.dart` covers the shape-kind picker and
/// its armed icon; `canvas_tools_row_touch_reach_test.dart` covers the tool
/// strip's own scroll and edge-fade behaviour at a phone width;
/// `canvas_tools_row_accessibility_test.dart` covers semantics reachability,
/// tooltips and keyboard dismissal; `canvas_tools_row_self_bubble_test.dart`
/// covers the "Hide/Show my camera bubble" overflow item now that it lives
/// here rather than on `CanvasBar` - each split out once this file crossed
/// the 500-line hard limit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/canvas_tools_row_fixtures.dart';

void main() {
  testWidgets('tapping the eraser calls onToolChanged with eraser', (
    tester,
  ) async {
    CanvasTool? chosen;
    await tester.pumpWidget(
      wrapCanvasToolsRow(
        buildCanvasToolsRow(onToolChanged: (tool) => chosen = tool),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Eraser'));
    await tester.pump();

    expect(chosen, CanvasTool.eraser);
  });

  testWidgets('tapping the pen calls onToolChanged with pen', (tester) async {
    CanvasTool? chosen;
    await tester.pumpWidget(
      wrapCanvasToolsRow(
        buildCanvasToolsRow(
          tool: CanvasTool.eraser,
          onToolChanged: (tool) => chosen = tool,
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Pen'));
    await tester.pump();

    expect(chosen, CanvasTool.pen);
  });

  testWidgets('tapping pan calls onToolChanged with pan', (tester) async {
    CanvasTool? chosen;
    await tester.pumpWidget(
      wrapCanvasToolsRow(
        buildCanvasToolsRow(onToolChanged: (tool) => chosen = tool),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    expect(chosen, CanvasTool.pan);
  });

  testWidgets('tapping note or shape calls onToolChanged with that tool', (
    tester,
  ) async {
    CanvasTool? chosen;
    await tester.pumpWidget(
      wrapCanvasToolsRow(
        buildCanvasToolsRow(onToolChanged: (tool) => chosen = tool),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Note'));
    await tester.pump();
    expect(chosen, CanvasTool.note);

    await tester.tap(find.bySemanticsLabel('Shape'));
    await tester.pump();
    expect(chosen, CanvasTool.shape);
  });

  testWidgets('showTools false hides the five tools and keeps undo, the '
      'overflow', (tester) async {
    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(showTools: false)),
    );

    expect(find.bySemanticsLabel('Pen'), findsNothing);
    expect(find.bySemanticsLabel('Note'), findsNothing);
    expect(find.bySemanticsLabel('Shape'), findsNothing);
    expect(find.bySemanticsLabel('Eraser'), findsNothing);
    expect(find.bySemanticsLabel('Pan'), findsNothing);
    expect(find.bySemanticsLabel('Undo'), findsOneWidget);
    expect(find.bySemanticsLabel('More canvas actions'), findsOneWidget);
  });

  testWidgets('tapping paste image in the overflow calls onPasteImage', (
    tester,
  ) async {
    var pasted = 0;
    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(onPasteImage: () => pasted++)),
    );

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste image'));
    await tester.pump();

    expect(pasted, 1);
  });

  // screen-review canvas.md: the pen tool stayed selectable under an error banner, so a tap could pick a tool guaranteed to fail the identical write.
  testWidgets(
    'pen, note, shape and paste image are disabled while canDraw is false, '
    'eraser and pan stay live',
    (tester) async {
      var toolChanged = false;
      var pasted = false;
      await tester.pumpWidget(
        wrapCanvasToolsRow(
          buildCanvasToolsRow(
            canDraw: false,
            onToolChanged: (_) => toolChanged = true,
            onPasteImage: () => pasted = true,
          ),
        ),
      );

      for (final label in ['Pen', 'Note', 'Shape']) {
        final button = tester.widget<AppIconButton>(
          find.ancestor(
            of: find.bySemanticsLabel(label),
            matching: find.byType(AppIconButton),
          ),
        );
        expect(button.onPressed, isNull, reason: label);
      }
      await tester.tap(find.bySemanticsLabel('Pen'), warnIfMissed: false);
      await tester.pump();
      expect(toolChanged, isFalse);

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      final pasteItem = tester.widget<AppMenuItem>(
        find.widgetWithText(AppMenuItem, 'Paste image'),
      );
      expect(pasteItem.onTap, isNull);
      await tester.tap(find.text('Paste image'), warnIfMissed: false);
      await tester.pump();
      expect(pasted, isFalse);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();

      for (final label in ['Eraser', 'Pan']) {
        final button = tester.widget<AppIconButton>(
          find.ancestor(
            of: find.bySemanticsLabel(label),
            matching: find.byType(AppIconButton),
          ),
        );
        expect(button.onPressed, isNotNull, reason: label);
      }
    },
  );

  testWidgets('the overflow no longer carries Recenter view', (tester) async {
    await tester.pumpWidget(wrapCanvasToolsRow(buildCanvasToolsRow()));

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();

    expect(find.text('Recenter view'), findsNothing);
    expect(find.text('Paste image'), findsOneWidget);
  });

  testWidgets('redo sits right after undo and is dimmed with nothing to redo', (
    tester,
  ) async {
    var redone = 0;
    await tester.pumpWidget(
      wrapCanvasToolsRow(
        buildCanvasToolsRow(canUndo: true, onRedo: () => redone++),
      ),
    );

    final undo = tester.getRect(find.bySemanticsLabel('Undo'));
    final redo = tester.getRect(find.bySemanticsLabel('Redo'));
    expect(redo.left, greaterThan(undo.right - 1));
    expect(redo.left - undo.right, lessThan(12));
    final button = tester.widget<AppIconButton>(
      find.ancestor(
        of: find.bySemanticsLabel('Redo'),
        matching: find.byType(AppIconButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(button.tooltip, 'Nothing to redo yet');
    expect(redone, 0);
  });

  testWidgets('redo fires onRedo when canRedo is true', (tester) async {
    var redone = 0;
    await tester.pumpWidget(
      wrapCanvasToolsRow(
        buildCanvasToolsRow(canRedo: true, onRedo: () => redone++),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Redo'));
    await tester.pump();

    expect(redone, 1);
  });

  testWidgets('undo is disabled when canUndo is false', (tester) async {
    var undone = 0;
    await tester.pumpWidget(
      wrapCanvasToolsRow(
        buildCanvasToolsRow(canUndo: false, onUndo: () => undone++),
      ),
    );

    final button = tester.widget<AppIconButton>(
      find.ancestor(
        of: find.bySemanticsLabel('Undo'),
        matching: find.byType(AppIconButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(undone, 0);
  });

  testWidgets('undo fires onUndo when canUndo is true', (tester) async {
    var undone = 0;
    await tester.pumpWidget(
      wrapCanvasToolsRow(
        buildCanvasToolsRow(canUndo: true, onUndo: () => undone++),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Undo'));
    await tester.pump();

    expect(undone, 1);
  });

  testWidgets('the overflow is always present, but offers no Clear canvas item '
      'without MANAGE_CANVAS', (tester) async {
    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(canManage: false)),
    );
    expect(find.bySemanticsLabel('More canvas actions'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();

    expect(find.text('Paste image'), findsOneWidget);
    expect(find.text('Clear canvas'), findsNothing);
  });

  testWidgets('the overflow offers Clear canvas with MANAGE_CANVAS', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(canManage: true)),
    );

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();

    expect(find.text('Paste image'), findsOneWidget);
    expect(find.text('Clear canvas'), findsOneWidget);
  });

  testWidgets(
    'Bring to front and Send to back are absent with nothing selected',
    (tester) async {
      await tester.pumpWidget(
        wrapCanvasToolsRow(
          buildCanvasToolsRow(selection: ValueNotifier<String?>(null)),
        ),
      );

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();

      expect(find.text('Bring to front'), findsNothing);
      expect(find.text('Send to back'), findsNothing);
    },
  );

  testWidgets(
    'Bring to front and Send to back appear and fire with an object selected',
    (tester) async {
      String? front;
      String? back;
      await tester.pumpWidget(
        wrapCanvasToolsRow(
          buildCanvasToolsRow(
            selection: ValueNotifier<String?>('obj-1'),
            onBringToFront: (id) => front = id,
            onSendToBack: (id) => back = id,
          ),
        ),
      );

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      expect(find.text('Bring to front'), findsOneWidget);
      expect(find.text('Send to back'), findsOneWidget);

      await tester.tap(find.text('Bring to front'));
      await tester.pump();
      expect(front, 'obj-1');

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send to back'));
      await tester.pump();
      expect(back, 'obj-1');
    },
  );

  testWidgets(
    'Delete is absent with nothing selected, and fires with an object selected',
    (tester) async {
      await tester.pumpWidget(
        wrapCanvasToolsRow(
          buildCanvasToolsRow(selection: ValueNotifier<String?>(null)),
        ),
      );
      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);

      String? deleted;
      await tester.pumpWidget(
        wrapCanvasToolsRow(
          buildCanvasToolsRow(
            selection: ValueNotifier<String?>('obj-1'),
            onDeleteSelected: (id) => deleted = id,
          ),
        ),
      );
      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pump();
      expect(deleted, 'obj-1');
    },
  );

  testWidgets(
    'clearing goes through a menu, then a confirm that names no count, and '
    'only calls onClear once confirmed',
    (tester) async {
      var cleared = 0;
      await tester.pumpWidget(
        wrapCanvasToolsRow(
          buildCanvasToolsRow(canManage: true, onClear: () async => cleared++),
        ),
      );

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      expect(find.text('Clear canvas'), findsOneWidget);
      expect(cleared, 0, reason: 'opening the menu must not clear anything');

      await tester.tap(find.text('Clear canvas'));
      await tester.pumpAndSettle();

      expect(find.text('Clear this canvas?'), findsOneWidget);
      expect(
        find.textContaining('everything on this canvas'),
        findsOneWidget,
        reason: 'the pane holds only part of the canvas, so no count is true',
      );
      expect(cleared, 0);

      await tester.tap(find.text('Clear canvas').last);
      await tester.pumpAndSettle();

      expect(cleared, 1);
    },
  );

  testWidgets(
    'the overflow offers to show or hide the activity log, and its label '
    'says which',
    (tester) async {
      var toggled = 0;
      await tester.pumpWidget(
        wrapCanvasToolsRow(
          buildCanvasToolsRow(onToggleActivityLog: () => toggled++),
        ),
      );

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      expect(find.text('Show activity log'), findsOneWidget);
      expect(find.text('Hide activity log'), findsNothing);

      await tester.tap(find.text('Show activity log'));
      await tester.pump();
      expect(toggled, 1);
    },
  );

  testWidgets('the overflow label flips once the log is open', (tester) async {
    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(activityLogOpen: true)),
    );

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();

    expect(find.text('Hide activity log'), findsOneWidget);
    expect(find.text('Show activity log'), findsNothing);
  });

  testWidgets('cancelling the confirm never calls onClear', (tester) async {
    var cleared = 0;
    await tester.pumpWidget(
      wrapCanvasToolsRow(
        buildCanvasToolsRow(canManage: true, onClear: () async => cleared++),
      ),
    );

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear canvas'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep canvas'));
    await tester.pumpAndSettle();

    expect(cleared, 0);
  });
}
