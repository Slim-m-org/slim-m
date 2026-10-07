// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone long press highlights the row while its action sheet is up; every
/// way that sheet can end, and every way the press can be cancelled, must hand
/// the row back at rest. The owner's words: "Long pressing a message leaves it
/// stuck as pressed when a popup appears and then I click out".
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

Widget _row() => harness(
  ListView(
    children: [
      MessageRow(
        message: message(),
        grouped: false,
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
      const SizedBox(height: 1200),
    ],
  ),
);

Color? _fill(WidgetTester tester) {
  final decoration = tester
      .widget<AnimatedContainer>(find.byKey(MessageRow.hoverFillKey))
      .decoration;
  return (decoration as BoxDecoration?)?.color;
}

Offset _rowPoint(WidgetTester tester) =>
    tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
    const Offset(120, 20);

Future<void> _pumpPhone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_row());
  await tester.pumpAndSettle();
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.longPressAt(_rowPoint(tester));
  await tester.pumpAndSettle();
  expect(find.text('Copy text'), findsOneWidget, reason: 'sheet is up');
  expect(_fill(tester), AppTokens.light.surfaceRaised, reason: 'row marked');
}

void main() {
  testWidgets('tapping the scrim returns the row to rest', (tester) async {
    await _pumpPhone(tester);
    await _openSheet(tester);

    await tester.tapAt(const Offset(195, 40));
    await tester.pumpAndSettle();

    expect(find.text('Copy text'), findsNothing);
    expect(_fill(tester), Colors.transparent);
  });

  testWidgets('dragging the sheet down returns the row to rest', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSheet(tester);

    await tester.fling(find.text('Copy text'), const Offset(0, 600), 2000);
    await tester.pumpAndSettle();

    expect(find.text('Copy text'), findsNothing);
    expect(_fill(tester), Colors.transparent);
  });

  testWidgets('choosing an action returns the row to rest', (tester) async {
    await _pumpPhone(tester);
    await _openSheet(tester);

    await tester.tap(find.text('Copy text'));
    await tester.pumpAndSettle();

    expect(find.text('Copy text'), findsNothing);
    expect(_fill(tester), Colors.transparent);
  });

  testWidgets('the system back gesture returns the row to rest', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await _openSheet(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Copy text'), findsNothing);
    expect(_fill(tester), Colors.transparent);
  });

  testWidgets('a drag that takes over before the long press leaves no mark', (
    tester,
  ) async {
    await _pumpPhone(tester);

    final gesture = await tester.startGesture(_rowPoint(tester));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_fill(tester), Colors.transparent);
  });

  testWidgets('a system pointer cancel mid-hold leaves no mark', (
    tester,
  ) async {
    await _pumpPhone(tester);

    final gesture = await tester.startGesture(_rowPoint(tester));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(_fill(tester), Colors.transparent);
  });

  testWidgets('a sideways swipe across the row leaves no mark', (tester) async {
    await _pumpPhone(tester);

    final gesture = await tester.startGesture(_rowPoint(tester));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_fill(tester), Colors.transparent);
  });

  testWidgets('releasing the finger with the sheet up keeps it up', (
    tester,
  ) async {
    await _pumpPhone(tester);

    final gesture = await tester.startGesture(_rowPoint(tester));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('Copy text'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Copy text'), findsOneWidget);
    expect(_fill(tester), AppTokens.light.surfaceRaised);
  });
}
