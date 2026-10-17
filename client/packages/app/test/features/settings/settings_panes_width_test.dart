// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner's "settings UI on desktop is very flat" report (#39): a pane's
/// content used to stretch across whatever width the window happened to be,
/// rows and all, once the nav's own fixed 240px was spent. It has to stay
/// bounded to the design's content column even on a very wide window.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('a pane\'s content is capped at the design\'s content column, '
      'not the full width of a wide desktop window', (tester) async {
    tester.view.physicalSize = const Size(1400, 880);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: SettingsPanesScaffold(
          title: 'Settings',
          backTooltip: 'Back',
          backFallback: '/',
          groups: [
            SettingsPaneGroup(
              label: 'You',
              panes: [
                SettingsPane(
                  id: 'wide',
                  label: 'Wide pane',
                  builder: (context) =>
                      Container(key: const Key('pane-content'), height: 40),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final width = tester.getSize(find.byKey(const Key('pane-content'))).width;
    expect(
      width,
      lessThanOrEqualTo(kContentColumnMax),
      reason:
          'the pane must not stretch past the design\'s own content column '
          'just because the window is wide enough to let it',
    );
  });
}
