// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A refused code clears the field and disables it while the request runs, so
/// focus has to come back or the next attempt starts with a mouse or a tab.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/totp_code_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('the field has focus again after a refused code', (tester) async {
    final answer = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showTotpCodeSheet(
                context,
                title: 'Code',
                description: 'Enter it.',
                submitLabel: 'Go',
                onSubmit: (code) => answer.future,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Go'));
    await tester.pump();
    answer.complete('That code was not accepted.');
    await tester.pumpAndSettle();

    expect(find.text('That code was not accepted.'), findsOneWidget);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);
  });
}
