// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/widgets/activity_progress.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _host(DateTime Function() clock, api.ActivityProgress progress) =>
    ProviderScope(
      overrides: [activityClockProvider.overrideWithValue(clock)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.forest),
        home: Scaffold(body: ActivityProgressBar(progress: progress)),
      ),
    );

String _time(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('activity-progress-time'))).data!;

void main() {
  test('formats minutes and hours', () {
    expect(formatTrackTime(65000), '1:05');
    expect(formatTrackTime(3725000), '1:02:05');
  });

  testWidgets('ticks forward, then stops at the end of the track', (
    tester,
  ) async {
    var now = DateTime.fromMillisecondsSinceEpoch(10000);
    const progress = api.ActivityProgress(
      positionMs: 0,
      durationMs: 3000,
      sampledAtMs: 10000,
    );
    await tester.pumpWidget(_host(() => now, progress));
    expect(_time(tester), '0:00 / 0:03');

    now = DateTime.fromMillisecondsSinceEpoch(11000);
    await tester.pump(const Duration(seconds: 1));
    expect(_time(tester), '0:01 / 0:03');

    now = DateTime.fromMillisecondsSinceEpoch(99000);
    await tester.pump(const Duration(seconds: 1));
    expect(_time(tester), '0:03 / 0:03');
    expect(tester.hasRunningAnimations, isFalse);
    // A leftover periodic timer would fail the test at teardown.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a new sample re-anchors the bar', (tester) async {
    final now = DateTime.fromMillisecondsSinceEpoch(10000);
    await tester.pumpWidget(
      _host(
        () => now,
        const api.ActivityProgress(
          positionMs: 0,
          durationMs: 100000,
          sampledAtMs: 10000,
        ),
      ),
    );
    await tester.pumpWidget(
      _host(
        () => now,
        const api.ActivityProgress(
          positionMs: 50000,
          durationMs: 100000,
          sampledAtMs: 10000,
        ),
      ),
    );
    expect(_time(tester), '0:50 / 1:40');
  });
}
