// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How Enter behaves in the composer on a phone: a soft keyboard's return key
/// types a newline inside an open code fence, and a hardware keyboard on a
/// touch platform sends.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'composer_harness.dart';

final _field = find.byWidgetPredicate((w) => w is TextField);

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  Future<void> typeOn(
    WidgetTester tester,
    TargetPlatform platform,
    String text,
  ) async {
    await tester.pumpWidget(
      composerHarness(controller: controller, sends: sends, platform: platform),
    );
    await tester.tap(_field);
    await tester.enterText(_field, text);
    await tester.pump();
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      '${platform.name}: return inside an open fence types a newline',
      (tester) async {
        await typeOn(tester, platform, '```dart\nvar a = 1;');

        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pump();

        expect(sends.count, 0);
        expect(controller.text, '```dart\nvar a = 1;\n');
      },
    );

    testWidgets('${platform.name}: return outside a fence still sends', (
      tester,
    ) async {
      await typeOn(tester, platform, 'hello');

      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();

      expect(sends.count, 1);
    });

    testWidgets('${platform.name}: a hardware Enter sends once', (
      tester,
    ) async {
      await typeOn(tester, platform, 'hello');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sends.count, 1);
    });

    testWidgets(
      '${platform.name}: a key then the action for one press send once',
      (tester) async {
        await typeOn(tester, platform, 'hello');

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pump();

        expect(sends.count, 1);
      },
    );

    testWidgets(
      '${platform.name}: the action then a key for one press send once',
      (tester) async {
        await typeOn(tester, platform, 'hello');

        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(sends.count, 1);
      },
    );

    testWidgets('${platform.name}: Ctrl+Enter sends from inside a fence', (
      tester,
    ) async {
      await typeOn(tester, platform, '```\ncode');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(sends.count, 1);
    });
  }
}
