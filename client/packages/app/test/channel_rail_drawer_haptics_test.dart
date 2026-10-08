// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone channel drawer ticks once per slide decision, never per frame,
/// and stays silent on platforms without a haptic engine.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

List<String> _recordHaptics(WidgetTester tester) {
  final haptics = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String? ?? 'default');
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return haptics;
}

Future<({ProviderContainer container, SlimmDatabase db})> _pump(
  WidgetTester tester,
  double width,
) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter('/channels/c-general'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      '$platform: one tick when the drag crosses the threshold, none below it',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final fixture = await _pump(tester, 500);
        final haptics = _recordHaptics(tester);

        final gesture = await tester.startGesture(const Offset(5, 300));
        for (var i = 0; i < 3; i++) {
          await gesture.moveBy(const Offset(25, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(haptics, isEmpty, reason: 'below the threshold nothing ticks');

        for (var i = 0; i < 7; i++) {
          await gesture.moveBy(const Offset(25, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(haptics, ['HapticFeedbackType.selectionClick']);

        await gesture.up();
        await tester.pumpAndSettle();
        expect(
          haptics,
          hasLength(1),
          reason: 'the settle repeats the decision',
        );

        debugDefaultTargetPlatformOverride = null;
        await teardownFixture(tester, fixture.container, fixture.db);
      },
    );
  }

  testWidgets('no tick on a platform without a haptic engine', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final fixture = await _pump(tester, 500);
    final haptics = _recordHaptics(tester);

    await tester.dragFrom(const Offset(5, 300), const Offset(300, 0));
    await tester.pumpAndSettle();

    expect(haptics, isEmpty);
    debugDefaultTargetPlatformOverride = null;
    await teardownFixture(tester, fixture.container, fixture.db);
  });
}
