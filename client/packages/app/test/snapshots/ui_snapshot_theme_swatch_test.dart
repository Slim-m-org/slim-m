// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Theme picker's swatch rows under every theme, so a swatch can be
/// checked against each menu surface. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_swatch.dart';
import 'package:slimm_app/src/providers/providers.dart' show AppThemeChoice;
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';

const _surfaces = <String, (Brightness, AppTokens)>{
  'dark': (Brightness.dark, AppTokens.dark),
  'light': (Brightness.light, AppTokens.light),
  'true-black': (Brightness.dark, AppTokens.trueBlack),
  'catppuccin': (Brightness.dark, AppTokens.mocha),
  'soft': (Brightness.dark, AppTokens.soft),
  'forest': (Brightness.dark, AppTokens.forest),
  'halloween': (Brightness.dark, AppTokens.halloween),
};

Widget _menu(AppTokens tokens) =>
    RepaintBoundary(key: snapshotBoundary, child: _menuBody(tokens));

Widget _menuBody(AppTokens tokens) => Container(
  width: 240,
  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
  color: tokens.surfaceRaised,
  child: Column(
    children: [
      for (final choice in AppThemeChoice.values)
        SizedBox(
          height: 36,
          child: Row(
            children: [
              const SizedBox(width: AppSpacing.s24),
              ThemeSwatch(choice: choice),
              const SizedBox(width: AppSpacing.s8),
              Text(
                themeLabel(choice),
                style: AppText.body.copyWith(color: tokens.textPrimary),
              ),
            ],
          ),
        ),
    ],
  ),
);

void main() {
  setUpAll(loadRealFonts);

  for (final entry in _surfaces.entries) {
    testWidgets('theme swatches on ${entry.key}', (tester) async {
      tester.view.physicalSize = const Size(240, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final (brightness, tokens) = entry.value;
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(brightness, tokens),
          home: Scaffold(body: Align(child: _menu(tokens))),
        ),
      );
      expect(
        find.byKey(themeSwatchOutlineKey),
        findsNWidgets(AppThemeChoice.values.length),
      );
      await writeSnapshot(tester, 'theme-swatch-${entry.key}');
    });
  }
}
