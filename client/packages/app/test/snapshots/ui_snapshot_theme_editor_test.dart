// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme editor: a clean theme, then a colour being picked with a
/// contrast floor failing, side by side on desktop and stacked on a phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';

Future<void> _pause(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Makes primary text the colour of the surfaces, through the picker.
Future<void> _breakContrast(WidgetTester tester) async {
  final token = find.byKey(const Key('theme-token-textPrimary'));
  await tester.ensureVisible(token);
  await _pause(tester);
  await tester.tap(token);
  await _pause(tester);
  await tester.enterText(find.byKey(AppColourPicker.hexFieldKey), '#1F2127');
  await _pause(tester);
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in phoneAndDesktop) {
    testWidgets('theme editor at $viewport', (tester) async {
      await renderSurface(
        tester,
        '/settings/themes/edit',
        viewport,
        darkAndLight,
        'settings-theme-editor-$viewport-$darkAndLight',
      );
    });
    testWidgets('theme editor with a failing contrast at $viewport', (
      tester,
    ) async {
      await renderSurface(
        tester,
        '/settings/themes/edit',
        viewport,
        'dark',
        'settings-theme-editor-failing-$viewport-dark',
        afterSettle: _breakContrast,
      );
    });
  }
}
