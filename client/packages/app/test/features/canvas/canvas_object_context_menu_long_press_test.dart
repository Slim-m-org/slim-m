// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasObjectContextMenu]'s touch long-press path (desktop-vs-mobile rule
/// 3): gated to the Select tool, since every other tool's raw pointer-down
/// already commits a draw, erase or placement before the long-press timer
/// could fire. See `canvas_object_context_menu.dart`'s own library doc.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_context_menu.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _shape(String id, {required String authorId}) =>
    CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: 1,
      x: 100,
      y: 100,
      w: 80,
      h: 60,
      points: const [],
      width: 0,
      colorKey: 'shape',
      kind: CanvasObjectKind.shape,
      authorId: authorId,
    );

Widget _build({required CanvasDocument document, required CanvasTool tool}) =>
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: CanvasObjectContextMenu(
            document: document,
            canManage: false,
            selfId: 'me',
            requests: CanvasObjectMenuRequests(),
            tool: tool,
            onToolChanged: (_) {},
            onBringToFront: (_) {},
            onSendToBack: (_) {},
            onDeleteSelected: (_) {},
            onPasteImageAt: (_) {},
            onAddNoteAt: (_) {},
            onRecenter: () {},
          ),
        ),
      ),
    );

void main() {
  testWidgets(
    'a long press over an object with the Select tool active opens the same '
    'object menu a right-click would',
    (tester) async {
      final document = CanvasDocument()
        ..applyPlaced(_shape('a', authorId: 'me'));
      addTearDown(document.dispose);
      await tester.pumpWidget(_build(document: document, tool: CanvasTool.pan));

      await tester.longPressAt(const Offset(120, 120));
      await tester.pumpAndSettle();

      expect(find.text('Bring to front'), findsOneWidget);
      expect(find.text('Send to back'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(document.selectedObjectId.value, 'a');
    },
  );

  testWidgets(
    'a long press over empty canvas with the Select tool active opens the '
    'empty-space menu',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      await tester.pumpWidget(_build(document: document, tool: CanvasTool.pan));

      await tester.longPressAt(const Offset(200, 200));
      await tester.pumpAndSettle();

      expect(find.text('Paste image'), findsOneWidget);
      expect(find.text('Add note'), findsOneWidget);
      expect(find.text('Recenter view'), findsOneWidget);
    },
  );

  testWidgets(
    'a long press does nothing while a drawing tool is active, since its own '
    'pointer-down already committed a draw before the timer could fire',
    (tester) async {
      final document = CanvasDocument()
        ..applyPlaced(_shape('a', authorId: 'me'));
      addTearDown(document.dispose);
      await tester.pumpWidget(_build(document: document, tool: CanvasTool.pen));

      await tester.longPressAt(const Offset(120, 120));
      await tester.pumpAndSettle();

      expect(find.text('Bring to front'), findsNothing);
      expect(
        document.selectedObjectId.value,
        isNull,
        reason: 'the Pen tool never selects on its own pointer-down',
      );
    },
  );
}
