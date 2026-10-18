// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A splash waiting on the update prompt has nothing left to animate.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _app(StartupPrompt? prompt) => MaterialApp(
  theme: buildTheme(Brightness.dark, AppTokens.dark),
  home: StartupScreen(prompt: prompt),
);

void main() {
  final prompt = StartupPrompt(
    title: 'Update available',
    primaryLabel: 'Update',
    onPrimary: () {},
    secondaryLabel: 'Later',
    onSecondary: () {},
  );

  testWidgets('the ticker stops once settled behind a prompt', (tester) async {
    await tester.pumpWidget(_app(prompt));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 16));

    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('clearing the prompt restarts the ticker', (tester) async {
    await tester.pumpWidget(_app(prompt));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(_app(null));
    await tester.pump(const Duration(milliseconds: 16));

    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });
}
