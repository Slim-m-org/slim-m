// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One pane gutter for everything that has to line up with the message rows:
/// it follows window width, and the composer insets by the same amount.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/routing/breakpoints.dart';
import 'package:slimm_app/src/widgets/composer_bot_mention_help.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

Future<double> _gutterAt(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late double gutter;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          gutter = paneGutterOf(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return gutter;
}

void main() {
  testWidgets('a phone width gets the compact gutter, a wider one the wide', (
    tester,
  ) async {
    expect(
      await _gutterAt(tester, kCompactWidth - 1),
      AppSizes.paneGutterCompact,
    );
    expect(await _gutterAt(tester, kCompactWidth), AppSizes.paneGutter);
    expect(await _gutterAt(tester, 1400), AppSizes.paneGutter);
  });

  for (final width in [kCompactWidth - 1, kCompactWidth, 1400.0]) {
    testWidgets('the composer insets by the row gutter at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: Sends(),
          platform: TargetPlatform.linux,
        ),
      );
      final inset = tester
          .getTopLeft(find.byType(ComposerBotMentionHelpList))
          .dx;
      expect(inset, await _gutterAt(tester, width));
    });
  }
}
