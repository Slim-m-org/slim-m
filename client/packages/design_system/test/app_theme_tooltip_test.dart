// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tooltip is a raised plate in the current theme: opaque, so text under it
/// never shows through, edged strongly enough to stand apart from a raised
/// surface it sits on, and never the other theme's colours.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('tooltip follows the ${brightness.name} theme', (tester) async {
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
      final plate = box.decoration as BoxDecoration;
      expect(plate.color!.a, 1.0);
      expect(plate.color, tokens.surfaceRaised);
      expect((plate.border! as Border).top.color, tokens.borderStrong);
      final text = tester.widget<Text>(find.text('A tip'));
      final style = DefaultTextStyle.of(
        tester.element(find.text('A tip')),
      ).style.merge(text.style);
      expect(style.color, tokens.textPrimary);
    });
  }
}
