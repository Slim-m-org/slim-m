// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The settings app bar's title sits right after its back arrow, not a further 16dp along.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/screens/settings_screen_scaffold.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('the title starts where the back button ends at 390 wide', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const SettingsScreenScaffold(
          title: 'Themes',
          backTooltip: 'Back',
          backFallback: '/',
          child: Text('body'),
        ),
      ),
    );
    final back = tester.getRect(find.byTooltip('Back'));
    final title = tester.getTopLeft(find.text('Themes'));
    expect(title.dx, closeTo(back.right, 8));
    expect(title.dx, lessThan(60));
    expect(tester.getTopLeft(find.text('body')).dx, 16);
  });
}
