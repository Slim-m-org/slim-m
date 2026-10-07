// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the message row's background highlight: a hovered message shifts
/// colour so the floating reaction button reads as attached to it, and an
/// open context menu keeps that same shift for as long as the menu is open.
///
/// The owner's own words: "there are no sort of hover affects over a message
/// so it looks likes it floating there". [MessageRow.hoverFillKey] is the
/// same [AnimatedContainer] `HoverReveal`'s `hovered` (hover-or-pinned) bool
/// already drove for the reaction button, so both asks share one mechanism
/// rather than a second hover convention.
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
);

Color? _fillColor(WidgetTester tester) {
  final decoration = tester
      .widget<AnimatedContainer>(find.byKey(MessageRow.hoverFillKey))
      .decoration;
  return (decoration as BoxDecoration?)?.color;
}

void main() {
  testWidgets('an unhovered message paints no fill at all', (tester) async {
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    expect(_fillColor(tester), Colors.transparent);
  });

  testWidgets('hovering shifts the row to the same fill AppListRow uses', (
    tester,
  ) async {
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(MessageRow)));
    await tester.pumpAndSettle();

    expect(_fillColor(tester), AppTokens.light.surfaceRaised);
  });

  testWidgets('the pointer leaving un-hovers the row again', (tester) async {
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(MessageRow)));
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(2000, 2000));
    await tester.pumpAndSettle();

    expect(_fillColor(tester), Colors.transparent);
  });

  testWidgets(
    'an open context menu keeps the row marked with no mouse involved at all',
    (tester) async {
      await tester.pumpWidget(_row());
      await tester.pumpAndSettle();

      // A long-press is touch's route to the menu; nothing here is a mouse.
      await tester.longPressAt(
        tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
            const Offset(30, 30),
      );
      await tester.pumpAndSettle();

      expect(_fillColor(tester), AppTokens.light.surfaceRaised);
    },
  );

  testWidgets('closing the menu clears the highlight again', (tester) async {
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    await tester.longPressAt(
      tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
          const Offset(30, 30),
    );
    await tester.pumpAndSettle();
    expect(_fillColor(tester), AppTokens.light.surfaceRaised);

    // Tapping outside dismisses it, the same way any overlay here closes.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(_fillColor(tester), Colors.transparent);
  });
}
