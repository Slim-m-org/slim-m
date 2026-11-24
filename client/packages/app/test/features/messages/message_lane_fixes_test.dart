// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Message row details: the day label across a clock change, the thread chip's
/// screen reader action, and the jump highlight reporting arrival on unmount.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_jump.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_parts.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  group('formatMessageDay across a spring-forward', () {
    // Local-midnight to local-midnight spans 23 hours on the changeover day.
    test('counts calendar days, not elapsed 24-hour spans', () {
      final now = DateTime(2026, 3, 10, 12);
      final changeover = DateTime(2026, 3, 8, 12).millisecondsSinceEpoch;
      expect(formatMessageDay(changeover, now: now), 'March 8');
      final yesterday = DateTime(2026, 3, 9, 12).millisecondsSinceEpoch;
      expect(formatMessageDay(yesterday, now: now), 'Yesterday');
    });
  });

  testWidgets('the thread chip exposes a tap action to screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ThreadReplySummary(
              replyCount: 2,
              lastReplyAt: 1700000000000,
              unread: false,
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );

    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Open thread')),
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.semantics.tap(find.semantics.byLabel(RegExp('Open thread')));
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('a jump highlight that unmounts mid-scroll still reports', (
    tester,
  ) async {
    var arrived = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ListView(
            children: [
              MessageJumpHighlight(
                onArrived: () => arrived++,
                child: const Text('target'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pump();

    expect(arrived, 1);
    await tester.pump(const Duration(seconds: 5));
    expect(arrived, 1, reason: 'reported once, not again when the timers end');
  });
}
