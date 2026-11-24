// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The troubleshooting heading follows the pane: the debug log breadcrumb and
/// its actions only show while the log itself is on screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/troubleshooting_pane.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [debugLogOpenProvider.overrideWith((ref) => true)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: TroubleshootingHeading()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the breadcrumb shows while the log is open on a wide window', (
    tester,
  ) async {
    await _pump(tester, 1200);
    expect(find.text('Debug log'), findsOneWidget);
  });

  testWidgets('a narrowed window drops the breadcrumb with the log', (
    tester,
  ) async {
    await _pump(tester, 600);
    expect(find.text('Debug log'), findsNothing);
    expect(find.text('Troubleshooting'), findsOneWidget);
  });
}
