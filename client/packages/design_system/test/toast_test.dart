// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// AppToast draws its message and a severity glyph, and a tap runs its dismiss.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('renders the message with a per-severity leading glyph', (
    tester,
  ) async {
    for (final (severity, icon) in [
      (AppToastSeverity.success, AppIcons.check),
      (AppToastSeverity.info, AppIcons.info),
      (AppToastSeverity.warning, AppIcons.warning),
    ]) {
      await tester.pumpWidget(
        _wrap(AppToast(message: 'Done', severity: severity)),
      );
      expect(find.text('Done'), findsOneWidget);
      expect(find.byIcon(icon), findsOneWidget);
    }
  });

  testWidgets('the card casts an AppShadows token at the named max width', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const AppToast(message: 'Done')));
    final card = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(AppToast),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = card.decoration! as BoxDecoration;
    expect(decoration.boxShadow, AppShadows.canvasTile);
    expect(card.constraints!.maxWidth, kToastMaxWidth);
  });

  testWidgets('a tap runs onDismiss when one is given', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      _wrap(AppToast(message: 'Copied', onDismiss: () => dismissed++)),
    );

    await tester.tap(find.byType(AppToast));
    expect(dismissed, 1);
  });

  testWidgets('there is no dismiss glyph when no handler is given', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const AppToast(message: 'Auto only')));
    expect(find.byIcon(AppIcons.dismiss), findsNothing);
  });

  testWidgets(
      'draws in the token font with no decoration when no Material '
      'ancestor exists', (tester) async {
    final theme = buildTheme(Brightness.light, AppTokens.light);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: theme,
          child: const Center(child: AppToast(message: 'Saved')),
        ),
      ),
    );

    final rich = tester.widget<RichText>(
      find.descendant(
        of: find.text('Saved'),
        matching: find.byType(RichText),
      ),
    );
    final style = rich.text.style!;
    expect(style.decoration, anyOf(isNull, TextDecoration.none));
    expect(style.fontFamily, theme.textTheme.bodyMedium!.fontFamily);
    expect(style.fontFamily, isNotNull);
    expect(style.fontSize, AppText.body.fontSize);
  });
}
