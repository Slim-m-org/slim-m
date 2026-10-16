// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The small shared parts the moderation, access and channel panes are built
/// from: danger card, value row, field, hairline and row feedback.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/settings_danger_card.dart';
import 'package:slimm_app/src/widgets/settings_field.dart';
import 'package:slimm_app/src/widgets/settings_hairline.dart';
import 'package:slimm_app/src/widgets/settings_row_feedback.dart';
import 'package:slimm_app/src/widgets/settings_section_header.dart';
import 'package:slimm_app/src/widgets/settings_value_row.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.dark, AppTokens.dark),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('the danger card shows its action and runs it on tap', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        SettingsDangerCard(
          title: 'Danger zone',
          message: 'Deletes it.',
          action: AppButton(label: 'Delete it', onPressed: () => taps++),
        ),
      ),
    );

    expect(find.text('Danger zone'), findsOneWidget);
    expect(find.text('Deletes it.'), findsOneWidget);
    await tester.tap(find.text('Delete it'));
    expect(taps, 1);
  });

  testWidgets('the danger card shows an error only when given one', (
    tester,
  ) async {
    Widget card({Widget? error}) => _host(
      SettingsDangerCard(
        title: 'Danger zone',
        message: 'Deletes it.',
        action: const SizedBox(),
        error: error,
      ),
    );
    await tester.pumpWidget(card());
    expect(find.byType(AppErrorState), findsNothing);

    await tester.pumpWidget(card(error: const AppErrorState(message: 'Nope')));
    expect(find.text('Nope'), findsOneWidget);
  });

  testWidgets('a value row puts the value at the card inset, mono on ask', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SettingsSectionCard(
          flush: true,
          children: [
            SettingsValueRow(label: 'Code', value: 'abc123', mono: true),
          ],
        ),
      ),
    );

    final card = tester.getRect(find.byType(SettingsSectionCard));
    expect(
      tester.getRect(find.text('abc123')).right,
      closeTo(card.right - 1 - AppSpacing.s16, 1),
    );
    expect(
      tester.widget<Text>(find.text('abc123')).style!.fontFamily,
      AppFonts.mono,
    );
  });

  testWidgets('a field labels its control and shows helper text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SettingsField(
          label: 'Name',
          helper: 'Shown to everyone.',
          child: SizedBox(height: 10),
        ),
      ),
    );

    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Shown to everyone.'), findsOneWidget);
  });

  testWidgets('a hairline is one logical pixel tall', (tester) async {
    await tester.pumpWidget(_host(const SettingsHairline()));

    expect(tester.getSize(find.byType(SettingsHairline)).height, 1);
  });

  testWidgets('row feedback shows its error and dismisses it', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      _host(
        SettingsRowFeedback(
          tick: 0,
          error: 'Could not save.',
          onDismiss: () => dismissed++,
        ),
      ),
    );

    expect(find.text('Could not save.'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    expect(dismissed, 1);
  });
}
