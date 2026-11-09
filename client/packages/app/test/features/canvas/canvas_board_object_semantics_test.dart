// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasBoardObjectSemantics]: a crowd of drawings must not push notes and images out of a screen reader's reach.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_board_object_semantics.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _object(
  String id,
  int zIndex, {
  CanvasObjectKind kind = CanvasObjectKind.stroke,
  String? text,
}) => CanvasStrokeInput(
  id: id,
  seq: zIndex + 1,
  zIndex: zIndex,
  x: 10.0 + zIndex,
  y: 10,
  w: 30,
  h: 20,
  points: kind == CanvasObjectKind.stroke ? const [0, 0, 30, 20] : const [],
  width: 2,
  colorKey: 'ink',
  kind: kind,
  text: text,
);

void main() {
  testWidgets(
    'notes and images keep a node however many drawings are in view',
    (tester) async {
      final handle = tester.ensureSemantics();
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      addTearDown(document.dispose);
      for (var i = 0; i < 80; i++) {
        document.applyPlaced(_object('ink$i', i));
      }
      document
        ..applyPlaced(
          _object('note', 90, kind: CanvasObjectKind.note, text: 'budget'),
        )
        ..applyPlaced(_object('photo', 91, kind: CanvasObjectKind.image))
        ..refresh();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 800,
            height: 600,
            child: Stack(
              children: [
                CanvasBoardObjectSemantics(
                  document: document,
                  onOpenActions: (_) {},
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Note: budget'), findsOneWidget);
      expect(find.bySemanticsLabel('Image'), findsOneWidget);
      expect(find.bySemanticsLabel('Drawing'), findsNWidgets(38));
      handle.dispose();
    },
  );
}
