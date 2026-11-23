// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed message's Retry is the tonal primary action, and every action is
/// a full touch target on a phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_parts.dart';
import 'package:slimm_design_system/design_system.dart';

AppButton _button(WidgetTester tester, String label) =>
    tester.widget<AppButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is AppButton),
      ),
    );

void main() {
  testWidgets('Retry is tonal and the actions are 44dp tall on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: FailedRow(
            onRetry: () {},
            onDiscard: () {},
            onEdit: () {},
            reason: 'Could not send the message.',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(_button(tester, 'Retry').variant, AppButtonVariant.soft);
    for (final label in ['Retry', 'Edit', 'Discard']) {
      final hit = tester.getSize(
        find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is AppButton),
        ),
      );
      expect(hit.height, greaterThanOrEqualTo(44), reason: label);
    }
  });
}
