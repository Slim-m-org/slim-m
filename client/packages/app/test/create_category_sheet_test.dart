// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/create_category_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCreateCategorySheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder _nameField() => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == 'Category name',
);

AppButton _primaryButton(WidgetTester tester) => tester.widget<AppButton>(
  find.byWidgetPredicate(
    (w) => w is AppButton && w.variant == AppButtonVariant.primary,
  ),
);

const _compactWidth = 500.0;
const _desktopWidth = 1100.0;
const _windowHeight = 900.0;

void main() {
  for (final width in [_compactWidth, _desktopWidth]) {
    testWidgets('renders without overflow at width $width', (tester) async {
      tester.view.physicalSize = Size(width, _windowHeight);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _openSheet(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Create a category'), findsOneWidget);
    });
  }

  testWidgets('the title reads as a heading, not a bolded paragraph', (
    tester,
  ) async {
    await _openSheet(tester);

    final title = tester.widget<Text>(find.text('Create a category'));
    expect(title.style?.fontSize, AppText.heading.fontSize);
  });

  testWidgets('the 64-char limit counts down before it is hit', (tester) async {
    await _openSheet(tester);

    expect(find.text('0/64'), findsOneWidget);

    await tester.enterText(_nameField(), 'Projects');
    await tester.pump();

    expect(find.text('8/64'), findsOneWidget);
  });

  testWidgets(
    'a name of astral characters counts characters, not utf-16 units',
    (tester) async {
      await _openSheet(tester);

      await tester.enterText(_nameField(), List.filled(40, '\u{1F600}').join());
      await tester.pump();

      expect(find.text('40/64'), findsOneWidget);
      expect(_primaryButton(tester).disabled, isFalse);
    },
  );

  testWidgets('names what is missing rather than sitting disabled mute', (
    tester,
  ) async {
    await _openSheet(tester);

    expect(_primaryButton(tester).label, 'Add a category name');
    expect(_primaryButton(tester).disabled, isTrue);

    await tester.enterText(_nameField(), 'Projects');
    await tester.pump();

    expect(_primaryButton(tester).label, 'Create category');
    expect(_primaryButton(tester).disabled, isFalse);

    // The server refuses past 64; say so here rather than after a round trip.
    await tester.enterText(_nameField(), 'a' * 65);
    await tester.pump();

    expect(_primaryButton(tester).label, 'Name is too long');
    expect(_primaryButton(tester).disabled, isTrue);
  });
}
