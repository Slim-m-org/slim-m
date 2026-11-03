// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tooltip is opaque in both themes, so text under it never shows through.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('tooltip is opaque in ${brightness.name}', (tester) async {
      final tokens =
          brightness == Brightness.dark ? AppTokens.dark : AppTokens.light;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(brightness, tokens),
          home: const Scaffold(
            body: Center(
              child: Tooltip(
                key: Key('tip'),
                message: 'A tip',
                child: SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      );
      final tip = tester.state<TooltipState>(find.byKey(const Key('tip')));
      tip.ensureTooltipVisible();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final box = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.text('A tip'),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final color = (box.decoration as BoxDecoration).color!;
      expect(color.a, 1.0);
      expect(color, tokens.textPrimary);
    });
  }
}
