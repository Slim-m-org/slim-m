// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tab inside the desktop GIF picker stays in the picker; it used to walk on
/// into the transcript and composer behind it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_picker_panel.dart';

import 'composer_harness.dart';
import '../../composer_picker_api.dart';

bool _focusInsidePanel() {
  final focus = FocusManager.instance.primaryFocus;
  final context = focus?.context;
  if (context == null) return false;
  var inside = false;
  context.visitAncestorElements((e) {
    if (e.widget is ComposerPickerPanel) inside = true;
    return !inside;
  });
  return inside;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final shift in [false, true]) {
    testWidgets('${shift ? 'Shift+Tab' : 'Tab'} never leaves the GIF picker', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: Sends(),
          platform: TargetPlatform.linux,
          apiBuilder: pickerApi(gifSearchEnabled: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(emojiButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('GIFs'));
      await tester.pumpAndSettle();
      expect(_focusInsidePanel(), isTrue);

      for (var i = 0; i < 12; i++) {
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(_focusInsidePanel(), isTrue, reason: 'tab press ${i + 1}');
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ComposerPickerPanel), findsNothing);
    });
  }
}
