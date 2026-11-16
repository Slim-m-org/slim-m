// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The field emoji panel opens under its button with the right edges level,
/// so a button at a field's end never hangs the panel past that field.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_field_picker.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker.dart';
import 'package:slimm_design_system/design_system.dart';

Future<Rect> _open(WidgetTester tester, {required double gapRight}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.only(right: gapRight, top: 40),
            child: EmojiFieldPicker(
              semanticLabel: 'Insert emoji',
              onSelect: (_) {},
              builder: (context, button) => Row(
                children: [
                  const Expanded(child: SizedBox(height: 40)),
                  button,
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final button = tester.getRect(find.byType(AppIconButton));
  await tester.tap(find.byType(AppIconButton));
  await tester.pumpAndSettle();
  return button;
}

void main() {
  const window = Rect.fromLTWH(0, 0, 1280, 800);

  testWidgets('a button at the window edge keeps the panel inside it', (
    tester,
  ) async {
    await _open(tester, gapRight: 0);
    final panel = tester.getRect(find.byType(EmojiPickerPanel));
    expect(window.contains(panel.topLeft), isTrue);
    expect(window.contains(panel.bottomRight), isTrue);
  });

  testWidgets('the panel ends where its button ends, not past it', (
    tester,
  ) async {
    final button = await _open(tester, gapRight: 300);
    final panel = tester.getRect(find.byType(EmojiPickerPanel));
    expect(panel.right, closeTo(button.right, 0.5));
    expect(panel.top, greaterThan(button.bottom));
  });
}
