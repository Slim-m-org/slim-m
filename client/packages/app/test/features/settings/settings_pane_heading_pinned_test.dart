// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pane's heading and close stay in view while its content scrolls.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('beside the nav the heading and close do not scroll away', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: SettingsPanesScaffold(
          title: 'Settings',
          backTooltip: 'Back',
          backFallback: '/',
          initialPaneId: 'long',
          groups: [
            SettingsPaneGroup(
              label: 'You',
              panes: [
                SettingsPane(
                  id: 'long',
                  label: 'Long pane',
                  builder: (_) => Column(
                    children: [
                      for (var i = 0; i < 40; i++)
                        SizedBox(height: 48, child: Text('row $i')),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    final heading = find.text('Long pane').last;
    final top = tester.getTopLeft(heading);

    await tester.drag(find.text('row 3'), const Offset(0, -600));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.getTopLeft(find.text('row 0')).dy, lessThan(top.dy));
    expect(tester.getTopLeft(heading), top);
    expect(find.byTooltip('Close settings').hitTestable(), findsOneWidget);
  });
}
