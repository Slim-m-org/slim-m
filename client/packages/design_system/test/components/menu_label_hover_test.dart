// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget child, AppTokens tokens) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, tokens),
        home: Scaffold(body: Center(child: child)),
      ),
    );

/// The fill painted behind the row labelled [label].
Color? _rowFill(WidgetTester tester, String label) => tester
    .widgetList<AnimatedContainer>(
      find.descendant(
        of: find.widgetWithText(AppMenuItem, label),
        matching: find.byWidgetPredicate((w) => w is AnimatedContainer),
      ),
    )
    .map((c) => (c.decoration as BoxDecoration?)?.color)
    .whereType<Color>()
    .firstOrNull;

void main() {
  testWidgets('a heading lines up with the rows under it, not the middle', (
    tester,
  ) async {
    await _pump(
      tester,
      SizedBox(
        width: 280,
        child: AppMenu(
          children: [
            const AppMenuLabel('Microphone'),
            AppMenuItem(label: 'Clean Mic', onTap: () {}),
          ],
        ),
      ),
      AppTokens.dark,
    );
    final heading = tester.getTopLeft(find.text('MICROPHONE')).dx;
    final row = tester.getTopLeft(find.text('Clean Mic')).dx;
    expect((heading - row).abs(), lessThan(4));
  });

  testWidgets('a hovered row is lighter than a dark menu, never a hole', (
    tester,
  ) async {
    // Touch mode (the test default) suppresses FocusableActionDetector hover.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    const tokens = AppTokens.dark;
    await _pump(
      tester,
      SizedBox(
        width: 280,
        child: AppMenu(
          children: [AppMenuItem(label: 'Show 6 more', onTap: () {})],
        ),
      ),
      tokens,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.text('Show 6 more')));
    await tester.pump(const Duration(milliseconds: 300));

    final fill = _rowFill(tester, 'Show 6 more');
    expect(fill, isNotNull);
    final painted = Color.alphaBlend(fill!, tokens.surfaceRaised);
    expect(
      painted.computeLuminance(),
      greaterThan(tokens.surfaceRaised.computeLuminance()),
    );
  });
}
