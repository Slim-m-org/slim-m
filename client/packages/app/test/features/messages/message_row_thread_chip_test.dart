// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The thread summary under a message is a bordered chip that looks like the
/// thread pane it opens: a glyph, "N replies", the time in mono, an unread
/// dot and a chevron, not accent text that reads as a link in a paragraph.
///
/// Geometry, not presence: a chip that exists but whose contents spill out of
/// its border, or that is a slab on a phone, is the bug.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_parts.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _lastReply = 1700000000000;

Widget _chip({
  double width = 600,
  bool unread = false,
  VoidCallback? onTap,
  int replies = 3,
}) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: ThreadReplySummary(
              replyCount: replies,
              lastReplyAt: _lastReply,
              unread: unread,
              onTap: onTap,
            ),
          ),
        ),
      ),
    ),
  ),
);

Rect _rect(WidgetTester tester, Finder f) => tester.getRect(f);

void main() {
  testWidgets('it is a bordered chip holding every part inside the border', (
    tester,
  ) async {
    await tester.pumpWidget(_chip(unread: true, onTap: noop));

    final chip = _rect(tester, find.byKey(ThreadReplySummary.chipKey));
    final decoration =
        tester
                .widget<DecoratedBox>(find.byKey(ThreadReplySummary.chipKey))
                .decoration
            as BoxDecoration;
    expect(decoration.border, isNotNull, reason: 'a hairline border');
    expect(chip.height, AppSizes.controlSm);

    for (final part in [
      find.text('3 replies'),
      find.byKey(ThreadReplySummary.unreadDotKey),
      find.byIcon(AppIcons.chevronRight),
      find.byIcon(AppIcons.thread),
    ]) {
      final r = _rect(tester, part);
      expect(chip.contains(r.topLeft) && chip.contains(r.bottomRight), isTrue);
    }
  });

  testWidgets('the time is mono and the chevron closes the chip on the right', (
    tester,
  ) async {
    await tester.pumpWidget(_chip(onTap: noop));

    final time = tester.widget<Text>(
      find.descendant(
        of: find.byKey(ThreadReplySummary.chipKey),
        matching: find.byWidgetPredicate(
          (w) => w is Text && w.style?.fontFamily == AppFonts.mono,
        ),
      ),
    );
    expect(time.data, isNotEmpty);
    final count = _rect(tester, find.text('3 replies'));
    final timeRect = _rect(tester, find.text(time.data!));
    final chevron = _rect(tester, find.byIcon(AppIcons.chevronRight));
    expect(timeRect.left, greaterThan(count.right - 1));
    expect(chevron.left, greaterThan(timeRect.right - 1));
    final chip = _rect(tester, find.byKey(ThreadReplySummary.chipKey));
    expect(chip.right - chevron.right, lessThanOrEqualTo(AppSpacing.s12));
  });

  testWidgets('the unread dot is between the time and the chevron', (
    tester,
  ) async {
    await tester.pumpWidget(_chip(unread: true, onTap: noop));

    final dot = _rect(tester, find.byKey(ThreadReplySummary.unreadDotKey));
    final chevron = _rect(tester, find.byIcon(AppIcons.chevronRight));
    expect(dot.width, AppSpacing.s8);
    expect(dot.height, AppSpacing.s8);
    expect(dot.right, lessThanOrEqualTo(chevron.left));
    expect(find.byKey(ThreadReplySummary.unreadDotKey), findsOneWidget);

    await tester.pumpWidget(_chip(onTap: noop));
    expect(find.byKey(ThreadReplySummary.unreadDotKey), findsNothing);
  });

  testWidgets('the chip stays inside a phone-width row', (tester) async {
    await tester.pumpWidget(_chip(width: 342, unread: true, onTap: noop));

    final chip = _rect(tester, find.byKey(ThreadReplySummary.chipKey));
    expect(chip.right, lessThanOrEqualTo(342));
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a phone the hit area reaches the touch minimum', (
    tester,
  ) async {
    await tester.pumpWidget(_chip(width: 342, onTap: noop));

    final whole = _rect(tester, find.byType(ThreadReplySummary));
    expect(whole.height, greaterThanOrEqualTo(AppSizes.rowTouch));
    expect(
      _rect(tester, find.byKey(ThreadReplySummary.chipKey)).height,
      AppSizes.controlSm,
      reason: 'the drawn chip stays its size; only the hit area grows',
    );
  });

  testWidgets('an inert chip has no chevron and no tap handler', (
    tester,
  ) async {
    await tester.pumpWidget(_chip());

    expect(find.byIcon(AppIcons.chevronRight), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('tapping the chip opens the thread', (tester) async {
    var opened = 0;
    await tester.pumpWidget(_chip(onTap: () => opened++));

    await tester.tap(find.byKey(ThreadReplySummary.chipKey));
    expect(opened, 1);
  });
}
