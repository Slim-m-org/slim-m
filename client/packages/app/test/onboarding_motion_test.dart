// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join flow's entrances: the three entry cards arrive as a stagger,
/// and the stepper grows into the sign-in form as a band rather than a cut.
///
/// Mid-flight reads, not settled ones: a settled read passes with the
/// stagger deleted, which is the vacuous shape this suite keeps finding.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_app/src/features/auth/widgets/onboarding_shell.dart';
import 'package:slimm_design_system/design_system.dart';

double _opacityAbove(WidgetTester tester, String text) => tester
    .widget<Opacity>(
      find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first,
    )
    .opacity;

void main() {
  testWidgets('the three entry cards arrive as a stagger, not one block', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: OnboardingScreen(onServerChosen: (server, invite) {}),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    // The first card is already fading in while the last has not started.
    expect(_opacityAbove(tester, 'I have an invite'), greaterThan(0));
    expect(_opacityAbove(tester, 'Join the official Space'), 0);

    await tester.pumpAndSettle();
    expect(_opacityAbove(tester, 'I have an invite'), 1);
    expect(_opacityAbove(tester, 'Join the official Space'), 1);
  });

  testWidgets('the stepper grows in as a band when a step appears', (
    tester,
  ) async {
    Widget shell(OnboardingStep? step) => MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: OnboardingShell(step: step, child: const Text('form')),
    );

    await tester.pumpWidget(shell(null));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingStepper), findsNothing);

    await tester.pumpWidget(shell(OnboardingStep.identity));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(OnboardingStepper), findsOneWidget);
    // Mid-reveal: mounted but still fading in through the band.
    final fading = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byType(OnboardingStepper),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(fading.opacity, greaterThan(0));
    expect(fading.opacity, lessThan(1));

    await tester.pumpAndSettle();
    expect(find.byType(OnboardingStepper), findsOneWidget);
  });
}
