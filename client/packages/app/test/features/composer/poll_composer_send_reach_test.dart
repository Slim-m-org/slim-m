// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Send stays on screen however tall the poll gets: the fields scroll above it.
/// At 1440x813 with four options a break-it tester found Send below the fold.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/poll_composer_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

Finder _field(String placeholder) => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == placeholder,
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  for (final size in const [Size(1440, 813), Size(1280, 600), Size(390, 640)]) {
    testWidgets('Send stays on screen with four options at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () =>
                        showPollComposerSheet(context, 'c-general'),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);

      await tester.enterText(_field('Ask a question'), 'poll race?');
      await tester.enterText(_field('Option 1'), 'yes');
      await tester.enterText(_field('Option 2'), 'no');
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('Add option'));
        await _settle(tester);
      }
      expect(_field('Option 4'), findsOneWidget);

      final send = find.widgetWithText(AppButton, 'Send poll');
      expect(send, findsOneWidget);
      final rect = tester.getRect(send);
      expect(
        rect.bottom,
        lessThanOrEqualTo(size.height),
        reason: 'Send sits below the fold at $size',
      );
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    });
  }
}
