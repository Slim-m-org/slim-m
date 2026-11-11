// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [SettingsDisclosure] is a plain settings row that unfolds more rows, not a
/// box of its own inside the card.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_disclosure.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('the header is a list row and unfolds its children', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: SettingsDisclosure(
            title: 'Advanced',
            summary: 'All on',
            children: [Text('inner row')],
          ),
        ),
      ),
    );
    expect(find.text('inner row'), findsNothing);
    expect(find.byIcon(AppIcons.chevronRight), findsOneWidget);

    await tester.tap(find.text('Advanced'));
    await tester.pump();

    expect(find.text('inner row'), findsOneWidget);
    expect(find.byIcon(AppIcons.chevronDown), findsOneWidget);
  });

  testWidgets('a long summary ellipsizes before the title at 2x text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: SettingsDisclosure(
            title: 'Permissions',
            summary: 'None granted at all for this bot',
            children: [],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final title = tester.getSize(find.text('Permissions'));
    final summary = tester.getSize(
      find.text('None granted at all for this bot'),
    );
    expect(summary.width, lessThan(390 - title.width));
    final renderTitle = tester.renderObject<RenderParagraph>(
      find.text('Permissions'),
    );
    expect(renderTitle.didExceedMaxLines, isFalse);
    expect(title.width, greaterThan(250));
  });
}
