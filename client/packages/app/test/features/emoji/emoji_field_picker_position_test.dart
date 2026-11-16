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

final _button = find.bySemanticsLabel('Insert emoji');
final _panel = find.byWidgetPredicate((w) => w is EmojiPickerPanel);

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
  final button = tester.getRect(_button);
  await tester.tap(_button);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return button;
}

void main() {
  const window = Rect.fromLTWH(0, 0, 1280, 800);

  testWidgets('a button at the window edge keeps the panel inside it', (
    tester,
  ) async {
    await _open(tester, gapRight: 0);
    final panel = tester.getRect(_panel);
    expect(window.contains(panel.topLeft), isTrue);
    expect(window.contains(panel.bottomRight), isTrue);
  });

  testWidgets('the panel ends where its button ends, not past it', (
    tester,
  ) async {
    final button = await _open(tester, gapRight: 300);
    final panel = tester.getRect(_panel);
    expect(panel.right, closeTo(button.right, 0.5));
    expect(panel.top, greaterThan(button.bottom));
  });
}
