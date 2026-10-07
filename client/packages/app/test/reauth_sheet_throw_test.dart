// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A submit that throws rather than returning a failure must not leave the
/// proof sheet stuck on "Checking..." with its inputs disabled.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/reauth_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('a submit that throws puts the sheet back and says so', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showReauthSheet(
                context,
                title: 'Confirm',
                description: 'Prove it.',
                submitLabel: 'Go',
                onSubmit: (password, code) async => throw StateError('boom'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Go'));
    await tester.pumpAndSettle();

    expect(find.text('Checking...'), findsNothing);
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Go'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });
}
