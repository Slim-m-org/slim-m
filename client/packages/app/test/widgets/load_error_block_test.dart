// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inline load failure shared by settings cards and the member pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/load_error_block.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('shows the message and runs retry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _host(
        LoadErrorBlock(
          message: 'Could not load devices.',
          onRetry: () => retries++,
        ),
      ),
    );
    expect(find.text('Could not load devices.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('without a retry offers none', (tester) async {
    await tester.pumpWidget(
      _host(const LoadErrorBlock(message: 'Could not load members.')),
    );
    expect(find.text('Could not load members.'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('pads the message to the card rhythm', (tester) async {
    await tester.pumpWidget(
      _host(const LoadErrorBlock(message: 'Could not load this setting.')),
    );
    final text = tester.getTopLeft(find.text('Could not load this setting.'));
    expect(text.dx, greaterThanOrEqualTo(AppSpacing.s16));
  });
}
