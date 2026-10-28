// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests that the in-place note editor clamps above the dock reservation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_editor.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_field.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  testWidgets('editor clamps its bottom position above document bottomInset', (
    tester,
  ) async {
    final document = CanvasDocument()
      ..setViewport(const Size(800, 600))
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'note-1',
          seq: 1,
          zIndex: 1,
          x: 100,
          y: 500,
          w: 200,
          h: 150,
          points: [],
          width: 0,
          colorKey: 'note',
          authorId: 'me',
          kind: CanvasObjectKind.note,
          text: 'test note',
        ),
      );

    document.setBottomInset(100);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: CanvasNoteEditor(
                document: document,
                objectId: 'note-1',
                onSave: (_) {},
                onCancel: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final panelFinder = find.byType(CanvasNoteField);
    expect(panelFinder, findsOneWidget);
    final renderBox = tester.renderObject<RenderBox>(panelFinder);
    final bottomEdge = renderBox
        .localToGlobal(Offset(0, renderBox.size.height))
        .dy;

    expect(bottomEdge, lessThanOrEqualTo(500.0));
  });
}
