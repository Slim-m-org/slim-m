// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A settings slider says its value once: an end the value sits on is not
/// shown again under the track.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_slider_row.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, double value) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: SettingsSliderRow(
        label: 'Space between groups',
        valueLabel: '${value.round()} px',
        value: value,
        min: 0,
        max: 16,
        minLabel: '0 px',
        maxLabel: '16 px',
        divisions: 16,
        onChanged: (_) {},
      ),
    ),
  ),
);

/// How many times the screen says [text].
int _said(WidgetTester tester, String text) =>
    find.semantics.byLabel(text).evaluate().length;

void main() {
  testWidgets('an end the value sits on is shown once, by the value', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    for (final (value, end, other) in [
      (0.0, '0 px', '16 px'),
      (16.0, '16 px', '0 px'),
    ]) {
      await _pump(tester, value);
      expect(_said(tester, end), 1, reason: '$value');
      expect(_said(tester, other), 1, reason: '$value');
    }

    await _pump(tester, 8);
    expect(_said(tester, '0 px'), 1);
    expect(_said(tester, '16 px'), 1);
    expect(_said(tester, '8 px'), 1);
    handle.dispose();
  });
}
