// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Choosing a settings pane fades the new one in rather than teleporting it:
/// the pane body is an `AppFadeIn` keyed on the pane's id, so a swap restarts
/// the fade, and reduce motion lands it instantly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, {bool reduceMotion = false}) async {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      // A bare MediaQueryData would zero the size and force compact layout.
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(disableAnimations: reduceMotion),
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: SettingsPanesScaffold(
          title: 'Settings',
          backTooltip: 'Back',
          backFallback: '/',
          groups: [
            SettingsPaneGroup(
              label: 'You',
              panes: [
                SettingsPane(
                  id: 'a',
                  label: 'First',
                  builder: (_) => const Text('pane-a'),
                ),
                SettingsPane(
                  id: 'b',
                  label: 'Second',
                  builder: (_) => const Text('pane-b'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The pane body's own fade: the [Opacity] that [AppFadeIn] drives, found
/// through it so an unrelated Opacity elsewhere cannot answer.
double _paneOpacity(WidgetTester tester) {
  final fade = find.ancestor(
    of: find.textContaining('pane-'),
    matching: find.byType(AppFadeIn),
  );
  final opacity = find.descendant(of: fade, matching: find.byType(Opacity));
  return tester.widget<Opacity>(opacity.first).opacity;
}

void main() {
  testWidgets('switching panes fades the new one in', (tester) async {
    await _pump(tester);
    expect(find.text('pane-a'), findsOneWidget);

    await tester.tap(find.text('Second'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(find.text('pane-b'), findsOneWidget);
    final mid = _paneOpacity(tester);
    expect(mid, greaterThan(0));
    expect(mid, lessThan(1));

    await tester.pumpAndSettle();
    expect(_paneOpacity(tester), 1);
  });

  testWidgets('reduce motion lands the swapped pane instantly', (tester) async {
    await _pump(tester, reduceMotion: true);

    await tester.tap(find.text('Second'));
    await tester.pump();

    expect(find.text('pane-b'), findsOneWidget);
    expect(_paneOpacity(tester), 1);
  });
}
