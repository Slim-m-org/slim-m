// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call record's time axis starts exactly where the lanes start, so the
/// first time sits under the first minute of the call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_timeline_model.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_timeline_view.dart';
import 'package:slimm_design_system/design_system.dart';

const _min = 60000;

void main() {
  for (final compact in [true, false]) {
    testWidgets(
      'the first axis time aligns with the lanes (compact: $compact)',
      (tester) async {
        tester.view.physicalSize = Size(compact ? 390 : 900, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final model = CallTimelineModel.from(
          const api.VoiceCall(
            startedAt: 0,
            endedAt: 120 * _min,
            canvas: [],
            events: [
              api.VoiceCallEvent(
                at: 0,
                userId: 'nick',
                kind: api.VoiceCallEventKind.joined,
              ),
              api.VoiceCallEvent(
                at: 120 * _min,
                userId: 'nick',
                kind: api.VoiceCallEventKind.left,
              ),
            ],
          ),
          now: 0,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              userProfileProvider.overrideWith((ref, id) async => null),
            ],
            child: MaterialApp(
              theme: buildTheme(Brightness.light, AppTokens.light),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(AppSpacing.s16),
                  child: CallTimelineView(model: model, compact: compact),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final lane = tester.getRect(
          find.byWidgetPredicate(
            (w) =>
                w is CustomPaint &&
                w.painter.runtimeType.toString() == '_LanePainter',
          ),
        );
        final first = tester.getRect(
          find.textContaining(RegExp(r'^\d+:\d\d')).first,
        );
        expect(first.left, closeTo(lane.left, 0.5));
      },
    );
  }

  /// The details pane is 296 wide past the avatar, and "10:36 AM" is a character longer than "9:36 AM".
  testWidgets('three two-digit-hour times fit a narrow pane', (tester) async {
    tester.view.physicalSize = const Size(360, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final start = DateTime(2026, 1, 5, 10, 36).millisecondsSinceEpoch;
    final model = CallTimelineModel.from(
      api.VoiceCall(
        startedAt: start,
        endedAt: start + 32 * _min,
        canvas: const [],
        events: [
          api.VoiceCallEvent(
            at: start,
            userId: 'nick',
            kind: api.VoiceCallEventKind.joined,
          ),
        ],
      ),
      now: start + 32 * _min,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [userProfileProvider.overrideWith((ref, id) async => null)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(AppSpacing.s16),
              child: CallTimelineView(model: model, compact: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final times = find.textContaining(RegExp(r'^1[01]:\d\d'));
    expect(times, findsNWidgets(3));
    expect(tester.getRect(times.last).right, lessThanOrEqualTo(360 - 16));
  });
}
