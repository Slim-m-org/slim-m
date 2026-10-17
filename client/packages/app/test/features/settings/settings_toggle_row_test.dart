// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `SettingsToggleRow` exists instead of `AppListRow(trailing: AppToggle())`
/// for exactly one reason, and this is the test that reason has to survive:
/// three of these settings carry a whole sentence, and `AppListRow` is
/// deliberately single-line and ellipsizes to keep a rail's rhythm even.
///
/// A test that only asserted the label is present would pass against the
/// truncating version too, since `find.text` matches the widget's own string
/// rather than what was painted. The assertion is on rendered height instead:
/// the row must grow past one line at phone width rather than clip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_design_system/design_system.dart';

const _sentence = 'Play a sound when someone joins or leaves a call';

Widget _harness(Widget child, {double width = 320}) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  testWidgets('a sentence-length label wraps rather than truncating', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        SettingsToggleRow(
          label: _sentence,
          value: true,
          semanticLabel: 'Play join and leave sounds',
          onChanged: (_) {},
        ),
      ),
    );

    final height = tester.getSize(find.byType(SettingsToggleRow)).height;
    expect(
      height,
      greaterThan(AppSizes.rowPointer),
      reason:
          'at 320px this sentence does not fit on one line beside a toggle. '
          'A row that stayed at AppListRow height would be eliding the middle '
          'of the description of what the switch does.',
    );

    final label = tester.widget<Text>(find.text(_sentence));
    expect(
      label.overflow,
      isNot(TextOverflow.ellipsis),
      reason: 'nothing here may clip the sentence',
    );
  });

  testWidgets('a short label still renders as one line, so wrapping is a '
      'ceiling being lifted rather than height always added', (tester) async {
    await tester.pumpWidget(
      _harness(
        SettingsToggleRow(
          label: 'High contrast',
          value: false,
          semanticLabel: 'High contrast',
          onChanged: (_) {},
        ),
      ),
    );
    final short = tester.getSize(find.byType(SettingsToggleRow)).height;

    await tester.pumpWidget(
      _harness(
        SettingsToggleRow(
          label: _sentence,
          value: false,
          semanticLabel: 'Play join and leave sounds',
          onChanged: (_) {},
        ),
      ),
    );
    final wrapped = tester.getSize(find.byType(SettingsToggleRow)).height;

    expect(
      short,
      lessThan(wrapped),
      reason:
          'a row that reported the same height for both is one that clipped '
          'the long one, which is the whole failure this widget avoids',
    );
  });

  testWidgets('the row publishes no tap target of its own', (tester) async {
    var changes = 0;
    await tester.pumpWidget(
      _harness(
        SettingsToggleRow(
          label: 'High contrast',
          value: false,
          semanticLabel: 'High contrast',
          onChanged: (_) => changes++,
        ),
      ),
    );

    await tester.tap(find.text('High contrast'));
    await tester.pumpAndSettle();

    expect(
      changes,
      0,
      reason:
          'AppToggle is its own tap target, so a second one on the row fires '
          'both on a single tap - toggling the value and immediately '
          'toggling it back. Carried over from _HighContrastRow, which had '
          'this right before the three shapes were unified.',
    );

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();
    expect(changes, 1);
  });
}
