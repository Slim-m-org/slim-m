// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// #2028: the snackbar fits a phone with room either side and still stops at
/// the sheet width on a wide window.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/app_snackbar.dart';
import 'package:slimm_design_system/design_system.dart';

Future<double> _snackbarWidth(WidgetTester tester, double screen) async {
  tester.view.physicalSize = Size(screen, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppSnackbar(context, 'Copied'),
              child: const Text('show'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('show'));
  await tester.pumpAndSettle();
  final card = find.descendant(
    of: find.byType(SnackBar),
    matching: find.byType(Material),
  );
  return tester.getSize(card.first).width;
}

void main() {
  testWidgets('on a phone it keeps a margin either side', (tester) async {
    expect(await _snackbarWidth(tester, 390), 390 - 2 * AppSpacing.s16);
  });

  testWidgets('on a wide window it stops at the sheet width', (tester) async {
    expect(await _snackbarWidth(tester, 1400), kSheetMaxWidth);
  });
}
