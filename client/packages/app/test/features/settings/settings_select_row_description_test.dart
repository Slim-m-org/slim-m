// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A select row's description wraps on a phone instead of being cut off.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';

const _description = 'How long this channel and its threads keep messages.';

void main() {
  testWidgets('a long description shows in full at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SettingsSelectRow<int>(
            label: 'Message retention',
            description: _description,
            value: 0,
            choices: const [
              SettingsChoice(value: 0, label: 'Space default (forever)'),
              SettingsChoice(value: 1, label: '30 days'),
            ],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    final text = tester.widget<Text>(find.text(_description));
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.getSize(find.text(_description)).height, greaterThan(18));
  });
}
