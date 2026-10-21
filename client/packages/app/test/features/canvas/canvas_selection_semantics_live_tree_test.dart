// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasSelectionSemantics] inside a loose Stack, as `canvas_pane_surface`
/// mounts it: the node must survive into the live semantics tree.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_selection_semantics.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

bool _anyNode(SemanticsNode node, bool Function(SemanticsNode) test) {
  if (test(node)) return true;
  var found = false;
  node.visitChildren((child) {
    found = found || _anyNode(child, test);
    return !found;
  });
  return found;
}

void main() {
  testWidgets('selected note node is non-empty in a loose Stack', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.applyPlaced(
      const CanvasStrokeInput(
        id: 'note-1',
        seq: 1,
        zIndex: 1,
        x: 0,
        y: 0,
        w: 220,
        h: 140,
        points: [],
        width: 0,
        colorKey: 'note',
        kind: CanvasObjectKind.note,
        text: 'hello',
      ),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 800,
            height: 600,
            child: Stack(
              children: [
                CanvasSelectionSemantics(
                  document: document,
                  onOpenActions: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    document.selectedObjectId.value = 'note-1';
    await tester.pump();

    final root =
        tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
    final reached = _anyNode(
      root,
      (n) => n.label.contains('Selected note') && !n.rect.isEmpty,
    );
    expect(
      reached,
      isTrue,
      reason: 'selected-object node must have a non-empty rect to reach AT',
    );
    handle.dispose();
  });
}
