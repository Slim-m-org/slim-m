// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Theme picker swatch keeps its outline above the colours.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_swatch.dart';
import 'package:slimm_app/src/providers/providers.dart' show AppThemeChoice;
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('the swatch outline paints over its cells in the token colour', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: ThemeSwatch(choice: AppThemeChoice.light)),
      ),
    );
    final outline = tester.widget<DecoratedBox>(
      find.byKey(themeSwatchOutlineKey),
    );
    expect(outline.position, DecorationPosition.foreground);
    final border = (outline.decoration as BoxDecoration).border! as Border;
    expect(border.top.color, AppTokens.dark.borderStrong);
  });
}
