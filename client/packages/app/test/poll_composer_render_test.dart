// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renders the poll composer sheet driven into the states that matter
/// beyond the default empty one `ui_overlay_snapshot_test.dart` already
/// covers: filled and ready to send, all four options in use, and long
/// text at phone width. See `poll_render_test.dart`'s own doc for the two
/// rasteriser artifacts to expect and not chase.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/poll_composer_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

Finder _questionField() => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == 'Ask a question',
);

Finder _optionField(int n) => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == 'Option $n',
);

Finder _addOptionButton() => find.widgetWithText(AppButton, 'Add option');

Future<void> _openSheet(WidgetTester tester, Size size, String theme) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            theme == 'dark' ? Brightness.dark : Brightness.light,
            theme == 'dark' ? AppTokens.dark : AppTokens.light,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showPollComposerSheet(context, 'c-general'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('poll-composer-ready-to-send fits its viewport', (tester) async {
    await _openSheet(tester, const Size(1400, 900), 'dark');

    await tester.enterText(_questionField(), 'Board game night this Friday?');
    await tester.enterText(_optionField(1), 'Yes, count me in');
    await tester.enterText(_optionField(2), "No, can't make it");
    await tester.pump();

    await writeSnapshot(tester, 'poll-composer-ready-to-send');
    expect(tester.takeException(), isNull);
  });

  testWidgets('poll-composer-four-options fits its viewport', (tester) async {
    await _openSheet(tester, const Size(1400, 900), 'dark');

    await tester.enterText(_questionField(), 'Which map for the next event?');
    await tester.enterText(_optionField(1), 'Ruins');
    await tester.enterText(_optionField(2), 'Harbor');
    await tester.tap(_addOptionButton());
    await tester.pumpAndSettle();
    await tester.enterText(_optionField(3), 'Foundry');
    await tester.tap(_addOptionButton());
    await tester.pumpAndSettle();
    await tester.enterText(_optionField(4), 'Skip this week');
    await tester.pump();

    await writeSnapshot(tester, 'poll-composer-four-options');
    expect(tester.takeException(), isNull);
  });

  testWidgets('poll-composer-long-text-phone fits its viewport', (
    tester,
  ) async {
    await _openSheet(tester, const Size(390, 844), 'light');

    await tester.enterText(
      _questionField(),
      "Given everyone's schedules this month, which weekend works best "
      'for the whole group to get together for the game night we keep '
      'putting off?',
    );
    await tester.enterText(
      _optionField(1),
      'The first weekend, right after everyone is back from travel',
    );
    await tester.enterText(
      _optionField(2),
      'The last weekend of the month, before the long weekend starts',
    );
    await tester.pump();

    await writeSnapshot(tester, 'poll-composer-long-text-phone');
    expect(tester.takeException(), isNull);
  });
}
