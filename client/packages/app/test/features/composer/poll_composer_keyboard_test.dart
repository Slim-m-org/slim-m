// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The New poll dialog by keyboard and screen reader: Tab walks every control
/// once and never stops in the inert preview, each field carries its own
/// name, and the dialog names itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/poll_composer_sheet.dart';
import 'package:slimm_app/src/features/composer/widgets/poll_view.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('Tab from an option never stops inside the preview', (
    tester,
  ) async {
    await _open(tester);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is AppInput && w.placeholder == 'Option 1',
      ),
    );
    await tester.pump();

    final preview = find.byWidgetPredicate((w) => w is PollView);
    final visited = <FocusNode>{};
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus!;
      visited.add(focus);
      final inPreview = find
          .descendant(
            of: preview,
            matching: find.byWidget(focus.context!.widget),
          )
          .evaluate()
          .isNotEmpty;
      expect(
        inPreview,
        isFalse,
        reason: 'press ${i + 1} landed in the preview',
      );
    }
    expect(visited.length, greaterThan(6));
  });

  testWidgets('the question field carries its name once it has text', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _open(tester);
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is AppInput && w.placeholder == 'Ask a question',
      ),
      'Lunch?',
    );
    await tester.pump();

    final field = tester.getSemantics(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is AppInput && w.placeholder == 'Ask a question',
        ),
        matching: find.byWidgetPredicate((w) => w is EditableText),
      ),
    );
    expect(field.getSemanticsData().flagsCollection.isTextField, isTrue);
    expect(field.label, contains('Poll question'));
    handle.dispose();
  });

  testWidgets('the dialog is a named route for assistive tech', (tester) async {
    final handle = tester.ensureSemantics();
    await _open(tester);
    expect(find.bySemanticsLabel('New poll'), findsWidgets);
    final named = tester.semantics.find(
      find.bySemanticsLabel('New poll').first,
    );
    final data = named.getSemanticsData();
    expect(data.flagsCollection.scopesRoute, isTrue);
    expect(data.flagsCollection.namesRoute, isTrue);
    handle.dispose();
  });
}
