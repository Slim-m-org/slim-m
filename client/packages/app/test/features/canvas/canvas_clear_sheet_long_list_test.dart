// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The scoped-clear sheet with many authors on a short window: every row must
/// stay reachable instead of overflowing past the sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_clear_scope.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_clear_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('a long author list does not overflow and scrolls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => requestScopedCanvasClear(
                  context,
                  CanvasScopedClear(
                    clear: (_) async {},
                    authorIds: () => {for (var i = 0; i < 20; i++) 'u$i'},
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull, reason: 'sheet overflowed');
    final last = find.text('Unknown member').last;
    await tester.scrollUntilVisible(
      last,
      200,
      scrollable: find.byType(Scrollable).last,
    );
  });
}
