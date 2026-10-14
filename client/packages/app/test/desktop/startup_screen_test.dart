// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Discord-style startup screen: renders the brand mark, and honours
/// reduce-motion the same way every other animated surface in this app
/// does - through [AppFadeIn], not a bespoke animation of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/startup_lattice.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  testWidgets('draws the lattice mark and the wordmark', (tester) async {
    await tester.pumpWidget(const StartupApp());

    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is StartupLatticePainter,
      ),
      findsOneWidget,
    );
    expect(find.text('slim-m'), findsOneWidget);
  });

  testWidgets('fades in by default and holds no running animation once '
      'reduce-motion is on', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: StartupApp(),
      ),
    );
    await tester.pump();

    expect(
      tester.hasRunningAnimations,
      isFalse,
      reason: 'a loop nobody can see is noise, matching AppMotion elsewhere',
    );
  });

  testWidgets('animates in by default when motion is not reduced', (
    tester,
  ) async {
    await tester.pumpWidget(const StartupApp());
    await tester.pump();

    expect(tester.hasRunningAnimations, isTrue);
  });

  testWidgets('with no update, shows the plain status line', (tester) async {
    await tester.pumpWidget(const StartupApp(status: 'Connecting'));
    expect(find.text('Connecting'), findsOneWidget);
    expect(find.text('Get update'), findsNothing);
  });

  testWidgets('a prompt shows its title, detail and both actions, and the '
      'buttons fire their callbacks', (tester) async {
    var primary = false;
    var secondary = false;
    await tester.pumpWidget(
      StartupApp(
        status: 'ignored while asking',
        prompt: StartupPrompt(
          title: 'Version 0.70.0 is available',
          detail: updateActionHint(InstallFormat.rpm),
          primaryLabel: 'Get update',
          onPrimary: () => primary = true,
          secondaryLabel: 'Not now',
          onSecondary: () => secondary = true,
        ),
      ),
    );

    expect(find.text('Version 0.70.0 is available'), findsOneWidget);
    expect(find.text(updateActionHint(InstallFormat.rpm)), findsOneWidget);
    expect(find.text('ignored while asking'), findsNothing);

    await tester.tap(find.text('Not now'));
    expect(secondary, isTrue);
    await tester.tap(find.text('Get update'));
    expect(primary, isTrue);
  });

  test('the update hint is format-specific', () {
    expect(updateActionHint(InstallFormat.flatpak), contains('flatpak update'));
    expect(updateActionHint(InstallFormat.rpm), contains('package manager'));
    expect(updateActionHint(InstallFormat.appImage), contains('release page'));
  });
}
