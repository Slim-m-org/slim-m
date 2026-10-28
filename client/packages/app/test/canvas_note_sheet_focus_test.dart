// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests that note sheet border shows focusRing when focused.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_note_sheet.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_field.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('note sheet container shows focus ring on focus', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCanvasNoteSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CanvasNoteField));
    await tester.pumpAndSettle();

    final container = tester.widget<Container>(
      find
          .ancestor(
            of: find.byType(CanvasNoteField),
            matching: find.byType(Container),
          )
          .first,
    );
    final border = (container.decoration as BoxDecoration).border! as Border;
    expect(border.top.color, AppTokens.light.focusRing);
  });
}
