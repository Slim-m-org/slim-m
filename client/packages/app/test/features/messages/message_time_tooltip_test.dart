// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hovering or long-pressing a message's time shows the full date and time,
/// in the full header and in the compact continuation gutter.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/format.dart';

import 'message_row_harness.dart';

const _epoch = 1700000000000;

Future<void> _pump(
  WidgetTester tester, {
  required bool grouped,
  TimeFormatPreference pref = TimeFormatPreference.h24,
}) => tester.pumpWidget(
  harness(
    MessageRow(
      message: message(createdAt: _epoch),
      grouped: grouped,
      showNewDivider: false,
      knownUsernames: const {},
      actions: noActions,
      editing: false,
      callbacks: MessageRowCallbacks(
        onRetry: () {},
        onDiscard: () {},
        onPickReaction: (_) {},
        onReactionTap: (_) {},
        onVote: (_) {},
        onSubmitEdit: (_) {},
        onCancelEdit: () {},
      ),
    ),
    overrides: [
      timeFormatControllerProvider.overrideWith(
        (ref) => TimeFormatController(ref)..state = pref,
      ),
    ],
  ),
);

Future<TestGesture> _hoverRow(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(find.byType(MessageRow)));
  await tester.pumpAndSettle();
  return mouse;
}

void main() {
  for (final grouped in [false, true]) {
    final where = grouped ? 'compact gutter' : 'full header';
    testWidgets('hovering the time shows the full date ($where)', (
      tester,
    ) async {
      await _pump(tester, grouped: grouped);
      final mouse = await _hoverRow(tester);
      final full = formatDateTime(_epoch, use24Hour: true);
      expect(find.text(full), findsNothing);
      await mouse.moveTo(tester.getCenter(find.byType(MessageTimeMark)));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(full), findsOneWidget);
    });

    testWidgets('long-press shows the full date ($where)', (tester) async {
      await _pump(tester, grouped: grouped);
      await _hoverRow(tester);
      final full = formatDateTime(_epoch, use24Hour: true);
      await tester.longPress(find.byType(MessageTimeMark));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(full), findsOneWidget);
    });
  }

  testWidgets('the full date honours the 12-hour setting', (tester) async {
    await _pump(tester, grouped: false, pref: TimeFormatPreference.h12);
    await tester.longPress(find.byType(MessageTimeMark));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(formatDateTime(_epoch, use24Hour: false)), findsOneWidget);
  });

  testWidgets('semantics carry the full date', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, grouped: false);
    expect(find.bySemanticsLabel(RegExp(r'\d{4}-\d{2}-\d{2}')), findsWidgets);
    handle.dispose();
  });

  testWidgets('the tooltip does not move the time mark', (tester) async {
    await _pump(tester, grouped: false);
    final before = tester.getRect(find.byType(MessageTimeMark));
    await tester.longPress(find.byType(MessageTimeMark));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(find.byType(MessageTimeMark)), before);
  });
}
