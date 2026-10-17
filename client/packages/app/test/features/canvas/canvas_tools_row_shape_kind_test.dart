// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shape-kind picker in the overflow, and the row's own Shape button
/// reflecting whichever kind it armed - split out of `canvas_tools_row_test.dart`
/// for the same reason `canvas_bar_shape_kind_test.dart`, this file's
/// predecessor, already was.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_shape_icons.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_tools_row_fixtures.dart';

void main() {
  testWidgets(
    'the shape-kind picker only appears in the overflow while the shape '
    'tool is active, and picking one fires onShapeKindChanged',
    (tester) async {
      CanvasShapeKind? chosen;
      await tester.pumpWidget(
        wrapCanvasToolsRow(
          buildCanvasToolsRow(onShapeKindChanged: (kind) => chosen = kind),
        ),
      );
      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      expect(find.text('Ellipse'), findsNothing);

      await tester.pumpWidget(
        wrapCanvasToolsRow(
          buildCanvasToolsRow(
            tool: CanvasTool.shape,
            onShapeKindChanged: (kind) => chosen = kind,
          ),
        ),
      );
      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      expect(find.text('Ellipse'), findsOneWidget);

      await tester.tap(find.text('Ellipse'));
      await tester.pump();
      expect(chosen, CanvasShapeKind.ellipse);
    },
  );

  /// A control whose look never changes with its own state is one a person
  /// has to remember rather than read; this is what stops the Shape button
  /// staying the generic glyph no matter which primitive is armed.
  testWidgets("the Shape button's own icon reflects the currently armed kind", (
    tester,
  ) async {
    for (final kind in CanvasShapeKind.values) {
      await tester.pumpWidget(
        wrapCanvasToolsRow(buildCanvasToolsRow(shapeKind: kind)),
      );

      final button = tester.widget<AppIconButton>(
        find.ancestor(
          of: find.bySemanticsLabel('Shape'),
          matching: find.byType(AppIconButton),
        ),
      );
      expect(button.icon, canvasShapeKindIcon(kind), reason: 'kind: $kind');
      expect(
        button.tooltip,
        contains(canvasShapeKindLabel(kind)),
        reason: 'kind: $kind, for a screen reader on the same fact',
      );
    }
  });

  testWidgets('the Shape hint only points at the caret once it exists', (
    tester,
  ) async {
    AppIconButton shapeButton() => tester.widget<AppIconButton>(
      find.ancestor(
        of: find.bySemanticsLabel('Shape'),
        matching: find.byType(AppIconButton),
      ),
    );

    await tester.pumpWidget(wrapCanvasToolsRow(buildCanvasToolsRow()));
    expect(find.bySemanticsLabel('Shape options'), findsNothing);
    expect(shapeButton().tooltip, isNot(contains('caret')));

    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(tool: CanvasTool.shape)),
    );
    expect(find.bySemanticsLabel('Shape options'), findsOneWidget);
    expect(shapeButton().tooltip, contains('caret'));
  });
}
