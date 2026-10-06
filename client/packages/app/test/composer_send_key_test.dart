// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Enter, numpad Enter and an active IME composition on the desktop send key.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'composer_harness.dart';

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });
  tearDown(() => controller.dispose());

  Future<void> pumpLinux(WidgetTester tester) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
      ),
    );
    await tester.pump(kThemeAnimationDuration);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'hello there');
    await tester.pump();
  }

  testWidgets('numpad enter sends like enter', (tester) async {
    await pumpLinux(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pump();
    expect(sends.count, 1);
  });

  testWidgets('enter does not send while an IME composition is active', (
    tester,
  ) async {
    await pumpLinux(tester);
    controller.value = const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sends.count, 0);
  });
}
