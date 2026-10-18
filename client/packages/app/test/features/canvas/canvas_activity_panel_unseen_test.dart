// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The activity panel's relative ages refresh only while someone can see them.
library;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_panel.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('ages stop refreshing while the app is unfocused', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 1, 1, 12);
    await withClock(Clock(() => now), () async {
      final log = CanvasActivityLog(isBlocked: (_) => false)
        ..recordClearedLive('op-1');
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Scaffold(
              body: CanvasActivityPanel(
                activityLog: log,
                summary: 's',
                objectCount: 0,
              ),
            ),
          ),
        ),
      );
      String age() => tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join('|');

      now = now.add(const Duration(minutes: 5));
      await tester.pump(const Duration(seconds: 10));
      final focused = age();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      now = now.add(const Duration(hours: 3));
      await tester.pump(const Duration(seconds: 10));
      expect(age(), focused);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 10));
      expect(age(), isNot(focused));

      log.dispose();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
