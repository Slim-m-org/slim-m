// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'composer_harness.dart';

void main() {
  late TextEditingController controller;
  setUp(() => controller = TextEditingController());
  tearDown(() => controller.dispose());

  Future<void> open(WidgetTester tester, String text) async {
    controller.value = TextEditingValue(
      text: text,
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: Sends(),
        platform: TargetPlatform.linux,
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 0);
  }

  testWidgets('Backspace at caret 0 raises no framework error', (tester) async {
    await open(tester, 'hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(controller.text, 'hello');
  });

  testWidgets('Shift+Enter at caret 0 inserts a newline', (tester) async {
    await open(tester, 'hello');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(controller.text, '\nhello');
  });
}
