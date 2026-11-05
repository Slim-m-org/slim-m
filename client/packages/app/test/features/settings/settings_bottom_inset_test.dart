// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The home-indicator inset is scroll padding, not a permanent empty band.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/screens/settings_screen_scaffold.dart';
import 'package:slimm_design_system/design_system.dart';

const _inset = 34.0;
const _lastRow = Key('last-row');

Widget _harness() => MediaQuery(
  data: const MediaQueryData(
    size: Size(390, 844),
    padding: EdgeInsets.only(top: 47, bottom: _inset),
    viewPadding: EdgeInsets.only(top: 47, bottom: _inset),
  ),
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: SettingsScreenScaffold(
      title: 'Settings',
      backTooltip: 'Back',
      backFallback: '/',
      child: Column(
        children: [
          for (var i = 0; i < 30; i++) const SizedBox(height: 56),
          const SizedBox(key: _lastRow, height: 56),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('the last row scrolls into the home-indicator inset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_harness());
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('settings-scaffold-list')),
            matching: find.byWidgetPredicate((w) => w is Scrollable),
          ),
        )
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();

    final bottom = tester.getBottomLeft(find.byKey(_lastRow)).dy;
    expect(
      bottom,
      844 - _inset - 16,
      reason: 'content ends one gutter plus the inset above the screen edge',
    );
    final list = tester
        .getBottomLeft(find.byKey(const Key('settings-scaffold-list')))
        .dy;
    expect(list, 844, reason: 'the list itself reaches the screen edge');
  });
}
