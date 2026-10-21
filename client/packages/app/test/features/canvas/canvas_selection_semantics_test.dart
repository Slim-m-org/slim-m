// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasSelectionSemantics]: the selected object's own accessibility
/// node, carrying a note's full text past the activity log's 80-character
/// cap.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_selection_semantics.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _note(String id, String text) => CanvasStrokeInput(
  id: id,
  seq: 1,
  zIndex: 1,
  x: 0,
  y: 0,
  w: 220,
  h: 140,
  points: const [],
  width: 0,
  colorKey: 'note',
  kind: CanvasObjectKind.note,
  text: text,
);

void main() {
  testWidgets('nothing selected contributes no semantics node at all', (
    tester,
  ) async {
    // Disposed manually, not via addTearDown: the pending-handle check runs before addTearDown callbacks fire (the same pending-timer trap CLAUDE.md already documents for a different check).
    final handle = tester.ensureSemantics();
    final document = CanvasDocument();
    addTearDown(document.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(children: [CanvasSelectionSemantics(document: document)]),
      ),
    );

    // byType, not bySemanticsLabel: an empty-labelled node would still pass a label-content check while being exactly the stop this must not add.
    expect(find.byType(Semantics), findsNothing);
    handle.dispose();
  });

  testWidgets(
    "a selected note's full text is reachable, well past the activity "
    'log\'s 80-character cap',
    (tester) async {
      final handle = tester.ensureSemantics();
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final longText = 'a' * 200;
      document.applyPlaced(_note('note-1', longText));

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [CanvasSelectionSemantics(document: document)],
          ),
        ),
      );
      document.selectedObjectId.value = 'note-1';
      await tester.pump();

      expect(
        find.bySemanticsLabel(RegExp('Selected note: a{200}')),
        findsOneWidget,
      );
      handle.dispose();
    },
  );

  testWidgets('deselecting removes the node again', (tester) async {
    final handle = tester.ensureSemantics();
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.applyPlaced(_note('note-1', 'hello'));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(children: [CanvasSelectionSemantics(document: document)]),
      ),
    );
    document.selectedObjectId.value = 'note-1';
    await tester.pump();
    expect(find.byType(Semantics), findsOneWidget);

    document.selectedObjectId.value = null;
    await tester.pump();
    expect(find.byType(Semantics), findsNothing);
    handle.dispose();
  });

  testWidgets(
    'a selected image or shape names its own kind, with no text field to '
    'name',
    (tester) async {
      final handle = tester.ensureSemantics();
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.applyPlaced(
        const CanvasStrokeInput(
          id: 'shape-1',
          seq: 1,
          zIndex: 1,
          x: 0,
          y: 0,
          w: 180,
          h: 120,
          points: [],
          width: 0,
          colorKey: 'shape',
          kind: CanvasObjectKind.shape,
        ),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [CanvasSelectionSemantics(document: document)],
          ),
        ),
      );
      document.selectedObjectId.value = 'shape-1';
      await tester.pump();

      expect(find.bySemanticsLabel('Selected shape'), findsOneWidget);
      handle.dispose();
    },
  );

  testWidgets(
    'a long-press action opens the actions menu for whatever is selected',
    (tester) async {
      final handle = tester.ensureSemantics();
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.applyPlaced(_note('note-1', 'hello'));

      final opened = <String>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              CanvasSelectionSemantics(
                document: document,
                onOpenActions: opened.add,
              ),
            ],
          ),
        ),
      );
      document.selectedObjectId.value = 'note-1';
      await tester.pump();

      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('^Selected')),
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.longPress),
        isTrue,
      );
      tester.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.longPress,
          nodeId: node.id,
          viewId: tester.view.viewId,
        ),
      );
      await tester.pump();
      expect(opened, ['note-1']);
      handle.dispose();
    },
  );

  testWidgets(
    'with no onOpenActions callback, the node carries no long-press action '
    'to invoke',
    (tester) async {
      final handle = tester.ensureSemantics();
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.applyPlaced(_note('note-1', 'hello'));

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [CanvasSelectionSemantics(document: document)],
          ),
        ),
      );
      document.selectedObjectId.value = 'note-1';
      await tester.pump();

      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('^Selected')),
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.longPress),
        isFalse,
      );
      handle.dispose();
    },
  );
}
