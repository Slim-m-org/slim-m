// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Repeated joins by one person fold into one "x N" row of "What happened".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_moment_runs.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_moments_view.dart';
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_timeline_model.dart';
import 'package:slimm_design_system/design_system.dart';

CallMoment _joined(int at, String who) =>
    CallMoment(at: at, kind: CallMomentKind.joined, userIds: [who]);

CallMoment _shared(int at, String who) => CallMoment(
  at: at,
  kind: CallMomentKind.shared,
  userIds: [who],
  durationMs: 60000,
);

void main() {
  group('foldMomentRuns', () {
    test('adjacent joins by one person become one run with the last time', () {
      final runs = foldMomentRuns([
        for (var i = 1; i <= 6; i++) _joined(i * 10, 'riley'),
      ]);
      expect(runs, hasLength(1));
      expect(runs.single.count, 6);
      expect(runs.single.first.at, 10);
      expect(runs.single.lastAt, 60);
    });

    test('someone else in between ends the run', () {
      final runs = foldMomentRuns([
        _joined(1, 'a'),
        _joined(2, 'b'),
        _joined(3, 'a'),
      ]);
      expect(runs.map((r) => r.count), [1, 1, 1]);
    });

    test('two different people joining in a row do not fold', () {
      final runs = foldMomentRuns([_joined(1, 'a'), _joined(2, 'b')]);
      expect(runs, hasLength(2));
    });

    test('shares, the start and the end are never folded', () {
      final runs = foldMomentRuns([
        const CallMoment(at: 0, kind: CallMomentKind.started, userIds: ['a']),
        const CallMoment(at: 1, kind: CallMomentKind.started, userIds: ['a']),
        _shared(2, 'a'),
        _shared(3, 'a'),
        const CallMoment(at: 4, kind: CallMomentKind.ended),
        const CallMoment(at: 5, kind: CallMomentKind.ended),
      ]);
      expect(runs.map((r) => r.count), [1, 1, 1, 1, 1, 1]);
    });

    test('a run keeps the order around it', () {
      final runs = foldMomentRuns([
        _joined(1, 'a'),
        _joined(2, 'a'),
        _shared(3, 'a'),
        _joined(4, 'a'),
      ]);
      expect(runs.map((r) => r.count), [2, 1, 1]);
    });

    test('nothing in gives nothing out', () {
      expect(foldMomentRuns(const []), isEmpty);
    });
  });

  group('the moments list with a run', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: CallMomentsView(
              moments: [for (var i = 0; i < 6; i++) _joined(i * 60000, 'a')],
              canvasObjectCount: 0,
              onOpenCanvas: () {},
            ),
          ),
        ),
      ),
    );

    testWidgets('six joins read as one row with a count', (tester) async {
      await pump(tester);

      expect(find.textContaining('joined'), findsOneWidget);
      expect(find.textContaining('×6'), findsOneWidget);
      expect(find.textContaining('last at'), findsOneWidget);
    });

    testWidgets('a screen reader hears the count', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);

      expect(
        find.bySemanticsLabel(RegExp('joined 6 times, last at')),
        findsOne,
      );
      handle.dispose();
    });
  });
}
