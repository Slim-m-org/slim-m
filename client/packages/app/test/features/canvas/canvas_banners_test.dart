// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The board's notices are [StatusBanner]s: condition-bound ones outlast the timers.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_banners.dart';
import 'package:slimm_app/src/widgets/status_banner.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(
  WidgetTester tester, {
  String? callError,
  String? error,
  bool truncated = false,
  int ink = 0,
  VoidCallback? onDismiss,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Stack(
        children: [
          CanvasBanners(
            callError: callError,
            onRetryCall: () {},
            error: error,
            onDismissError: onDismiss ?? () {},
            onRetryError: () {},
            truncated: truncated,
            unsavedInk: ValueNotifier(ink),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('a call error is a StatusBanner that outlives every timer', (
    tester,
  ) async {
    await _pump(tester, callError: 'Could not join the call.');
    await tester.pump(const Duration(minutes: 5));
    expect(find.text('Could not join the call.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byIcon(AppIcons.dismiss), findsNothing);
  });

  testWidgets('truncated and unsaved-ink notices stay while true', (
    tester,
  ) async {
    await _pump(tester, truncated: true, ink: 2);
    await tester.pump(const Duration(minutes: 5));
    expect(find.textContaining('Zoom in to see it'), findsOneWidget);
    expect(find.textContaining('not saved yet'), findsOneWidget);
  });

  testWidgets('a canvas error is dismissed by its close button', (
    tester,
  ) async {
    var dismissed = 0;
    await _pump(tester, error: 'Save failed.', onDismiss: () => dismissed++);
    await tester.tap(find.byIcon(AppIcons.dismiss));
    await tester.pump();
    expect(dismissed, 1);
  });
}
