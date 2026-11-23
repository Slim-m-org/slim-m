// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone settings menu's search field is a full touch row tall and its
/// box shares the cards' left and right edges.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_search.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_section_header.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: SettingsSearchArea(
          entries: const [],
          paneLabels: const {},
          onOpen: (_) {},
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.s16),
            children: const [
              SettingsSectionCard(
                key: Key('card'),
                children: [SizedBox(height: 40)],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('at 390 the field is 44dp tall and flush with the cards', (
    tester,
  ) async {
    await _pump(tester, 390);
    final field = tester.getRect(find.byKey(const Key('settings-search')));
    final card = tester.getRect(find.byKey(const Key('card')));
    expect(field.height, greaterThanOrEqualTo(44));
    expect(field.left, closeTo(card.left, 0.5));
    expect(field.right, closeTo(card.right, 0.5));
  });

  testWidgets('on a wide window the field keeps the compact 32dp height', (
    tester,
  ) async {
    await _pump(tester, 1280);
    final field = tester.getRect(find.byKey(const Key('settings-search')));
    expect(field.height, 32);
  });
}
