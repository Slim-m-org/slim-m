// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The poll composer sheet's redesign: five identical fixed fields become a
/// real add/remove list with a stated minimum and maximum, the primary
/// button names what is missing rather than sitting disabled with no
/// explanation, and a live preview shows what "Send poll" will produce.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/poll_composer_sheet.dart';
import 'package:slimm_app/src/widgets/poll_view.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPollComposerSheet(context, 'c-general'),
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

Finder _questionField() => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == 'Ask a question',
);

Finder _optionField(int n) => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == 'Option $n',
);

Finder _addOptionButton() => find.widgetWithText(AppButton, 'Add option');

Finder _previewText(String text) =>
    find.descendant(of: find.byType(PollView), matching: find.text(text));

AppButton _primaryButton(WidgetTester tester) => tester.widget<AppButton>(
  find.byWidgetPredicate(
    (w) => w is AppButton && w.variant == AppButtonVariant.primary,
  ),
);

void main() {
  group('the option list', () {
    testWidgets('starts with exactly the two required fields', (tester) async {
      await _openSheet(tester);

      expect(_optionField(1), findsOneWidget);
      expect(_optionField(2), findsOneWidget);
      expect(_optionField(3), findsNothing);
      expect(
        find.byIcon(AppIcons.dismiss),
        findsNothing,
        reason: 'the two required fields carry no remove affordance',
      );
      expect(_addOptionButton(), findsOneWidget);
    });

    testWidgets(
      'growing it past the minimum gives each new row its own remove button',
      (tester) async {
        await _openSheet(tester);

        await tester.tap(_addOptionButton());
        await tester.pumpAndSettle();

        expect(_optionField(3), findsOneWidget);
        expect(find.byIcon(AppIcons.dismiss), findsOneWidget);

        await tester.tap(find.byIcon(AppIcons.dismiss));
        await tester.pumpAndSettle();

        expect(
          _optionField(3),
          findsNothing,
          reason: 'removing the third field returns to the required two',
        );
        expect(find.byIcon(AppIcons.dismiss), findsNothing);
      },
    );

    testWidgets('the add affordance retires at the maximum, and says why', (
      tester,
    ) async {
      await _openSheet(tester);

      await tester.tap(_addOptionButton());
      await tester.pumpAndSettle();
      await tester.tap(_addOptionButton());
      await tester.pumpAndSettle();

      expect(_optionField(4), findsOneWidget);
      expect(
        _addOptionButton(),
        findsNothing,
        reason: 'a fifth option is past what the server accepts',
      );
      expect(find.text('Maximum of 4 options.'), findsOneWidget);
    });
  });

  group('the primary button', () {
    testWidgets('names what is missing rather than sitting disabled mute', (
      tester,
    ) async {
      await _openSheet(tester);

      expect(_primaryButton(tester).label, 'Add a question');
      expect(_primaryButton(tester).disabled, isTrue);

      await tester.enterText(_questionField(), 'Board game night?');
      await tester.pump();

      expect(_primaryButton(tester).label, 'Add at least 2 options');
      expect(_primaryButton(tester).disabled, isTrue);

      await tester.enterText(_optionField(1), 'Catan');
      await tester.enterText(_optionField(2), 'Wingspan');
      await tester.pump();

      expect(_primaryButton(tester).label, 'Send poll');
      expect(_primaryButton(tester).disabled, isFalse);
    });

    testWidgets(
      'tapping it while incomplete sends nothing and closes nothing',
      (tester) async {
        await _openSheet(tester);

        await tester.tap(find.widgetWithText(AppButton, 'Add a question'));
        await tester.pump();

        expect(find.text('New poll'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('the preview', () {
    testWidgets('shows placeholder text for whatever has not been typed yet', (
      tester,
    ) async {
      await _openSheet(tester);

      expect(_previewText('Your question'), findsOneWidget);
      expect(_previewText('Option 1'), findsOneWidget);
      expect(_previewText('Option 2'), findsOneWidget);
    });

    testWidgets('updates live as the fields are typed', (tester) async {
      await _openSheet(tester);

      await tester.enterText(_questionField(), 'Board game night?');
      await tester.enterText(_optionField(1), 'Catan');
      await tester.pump();

      expect(_previewText('Board game night?'), findsOneWidget);
      expect(_previewText('Catan'), findsOneWidget);
      expect(_previewText('Your question'), findsNothing);
    });

    testWidgets('gains a row the moment a third option field is added', (
      tester,
    ) async {
      await _openSheet(tester);

      await tester.tap(_addOptionButton());
      await tester.pumpAndSettle();

      expect(_previewText('Option 3'), findsOneWidget);
    });
  });

  testWidgets('a closing time shows in the preview, and votes say anonymous', (
    tester,
  ) async {
    await _openSheet(tester);
    expect(find.textContaining('Votes are anonymous.'), findsOneWidget);
    expect(
      _previewText('No votes yet. Tap an option to vote.'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Closes'));
    await tester.tap(find.text('Closes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('In 1 day'));
    await tester.pumpAndSettle();

    expect(
      _previewText('No votes yet. Tap an option to vote. Closes in 1 day.'),
      findsOneWidget,
    );
  });
}
