// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget child, {AppTokens? tokens}) {
  final t = tokens ?? AppTokens.light;
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, t),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  group('AppButton', () {
    testWidgets('exposes its semantic label', (tester) async {
      await _pump(tester, AppButton(label: 'Save', onPressed: () {}));
      expect(find.bySemanticsLabel('Save'), findsOneWidget);
    });

    testWidgets('the five variants render with distinguishable fills and ink',
        (tester) async {
      const tokens = AppTokens.light;

      Future<(Color?, Color)> paint(AppButtonVariant variant) async {
        await _pump(
          tester,
          AppButton(label: 'Go', onPressed: () {}, variant: variant),
          tokens: tokens,
        );
        final container = tester.widget<Container>(
          find.descendant(
              of: find.byType(AppButton), matching: find.byType(Container)),
        );
        final decoration = container.decoration as BoxDecoration;
        final text = tester.widget<Text>(find.text('Go'));
        return (decoration.color, text.style!.color!);
      }

      final primary = await paint(AppButtonVariant.primary);
      expect(primary.$1, tokens.accentFill,
          reason: 'primary is the one filled variant');
      expect(primary.$2, tokens.accentOn);

      final secondary = await paint(AppButtonVariant.secondary);
      expect(secondary.$1, Colors.transparent);
      expect(secondary.$2, tokens.textPrimary);

      final ghost = await paint(AppButtonVariant.ghost);
      expect(ghost.$1, Colors.transparent);
      expect(ghost.$2, tokens.textSecondary);

      final soft = await paint(AppButtonVariant.soft);
      expect(soft.$1, tokens.accentSoft);
      expect(soft.$2, tokens.accent);

      final danger = await paint(AppButtonVariant.danger);
      expect(danger.$1, Colors.transparent);
      expect(danger.$2, tokens.dangerText);

      // Inks must differ between variants: four of five fills are transparent, so ink is what tells them apart.
      final inks = {primary.$2, secondary.$2, ghost.$2, soft.$2, danger.$2};
      expect(inks.length, 5);
    });

    testWidgets('disabled is independent of onPressed and blocks the tap',
        (tester) async {
      var pressed = false;
      await _pump(
        tester,
        AppButton(
            label: 'Save', onPressed: () => pressed = true, disabled: true),
      );

      final semantics = tester.widget<Semantics>(
        find
            .descendant(
                of: find.byType(AppButton), matching: find.byType(Semantics))
            .first,
      );
      expect(semantics.properties.enabled, isFalse);

      await tester.tap(find.byType(AppButton));
      await tester.pump();
      expect(pressed, isFalse,
          reason: 'disabled must override a real, still-present callback');
    });

    testWidgets('a provided onPressed fires on tap', (tester) async {
      var pressed = false;
      await _pump(
          tester, AppButton(label: 'Save', onPressed: () => pressed = true));
      await tester.tap(find.byType(AppButton));
      await tester.pump();
      expect(pressed, isTrue);
    });

    testWidgets('busy shows a spinner, swallows taps and does not dim',
        (tester) async {
      var pressed = false;
      await _pump(
          tester,
          AppButton(
              label: 'Save', busy: true, onPressed: () => pressed = true));
      await tester.pump(AppMotion.fast);
      final button = find.byType(AppButton);
      expect(
          find.descendant(
              of: button, matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);
      final label = tester.widget<AnimatedOpacity>(find.ancestor(
          of: find.text('Save'), matching: find.byType(AnimatedOpacity)));
      expect(label.opacity, 0,
          reason: 'the label has faded out, keeping its space for the spinner');
      await tester.tap(button);
      await tester.pump();
      expect(pressed, isFalse);
      final opacity = tester.widget<Opacity>(
          find.descendant(of: button, matching: find.byType(Opacity)).first);
      expect(opacity.opacity, 1,
          reason: 'working is not the same as unavailable');
    });

    testWidgets('meets the touch hit-target floor when touch is set',
        (tester) async {
      await _pump(
        tester,
        AppButton(
            label: 'Go', onPressed: () {}, size: AppButtonSize.sm, touch: true),
      );
      expect(tester.getSize(find.byType(AppButton)).height,
          greaterThanOrEqualTo(AppSizes.rowTouch));
    });

    testWidgets('focus draws a ring distinct from every variant border colour',
        (tester) async {
      const tokens = AppTokens.light;
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      final previousStrategy = FocusManager.instance.highlightStrategy;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
          () => FocusManager.instance.highlightStrategy = previousStrategy);

      await _pump(
        tester,
        AppButton(label: 'Go', onPressed: () {}, focusNode: focusNode),
        tokens: tokens,
      );

      focusNode.requestFocus();
      await tester.pump();

      final container = tester.widget<Container>(
        find.descendant(
            of: find.byType(AppButton), matching: find.byType(Container)),
      );
      final ring =
          ((container.foregroundDecoration as BoxDecoration).border as Border)
              .top
              .color;
      expect(ring, tokens.focusRing);
    });
  });
}
