// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Enter in the edit field confirms an IME candidate rather than saving.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_edit_field.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('Enter during a composition does not save', (tester) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Material(
          child: MessageEditField(
            initialContent: 'hello',
            onSubmit: saved.add,
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'helloni',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 5, end: 7),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(saved, isEmpty);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'helloni',
        selection: TextSelection.collapsed(offset: 7),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(saved, ['helloni']);
  });
}
