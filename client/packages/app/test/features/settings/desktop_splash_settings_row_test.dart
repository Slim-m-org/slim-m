// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop startup-splash row inside the Desktop pane: one select
/// row, with Disabled where the old on/off toggle used to be. Picking a
/// duration persists it; picking Disabled persists it too. There is no
/// longer a separate toggle to hide or show anything.
///
/// The explicit desktop width matches `settings_select_row_test.dart`'s own harness: the row's
/// choices drop down anchored to it only at or above `kCompactWidth`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/providers/desktop_splash_preference.dart';
import 'package:slimm_app/src/features/settings/widgets/desktop_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _wrap() => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const Scaffold(
      body: SingleChildScrollView(child: DesktopSettingsSection()),
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the splash row shows, defaulting to Standard, with no toggle', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Startup splash'), findsOneWidget);
    expect(find.text('Standard (default)'), findsOneWidget);
    // The old on/off toggle is gone - Disabled is a choice instead.
    expect(
      find.byWidgetPredicate(
        (w) => w is AppToggle && w.semanticLabel == 'Startup splash',
      ),
      findsNothing,
    );
  });

  testWidgets('picking Long persists that choice', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(SettingsSelectRow<SplashDuration>));
    await tester.tap(find.byType(SettingsSelectRow<SplashDuration>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Long'));
    await tester.pumpAndSettle();

    expect(find.text('Long'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(desktopSplashDurationKey), 'long');
  });

  testWidgets('picking Disabled persists it, where the toggle-off used to be', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(SettingsSelectRow<SplashDuration>));
    await tester.tap(find.byType(SettingsSelectRow<SplashDuration>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disabled'));
    await tester.pumpAndSettle();

    expect(find.text('Disabled'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(desktopSplashDurationKey), 'disabled');
  });
}
