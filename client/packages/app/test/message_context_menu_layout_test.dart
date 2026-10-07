// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a compact layout the message context menu slides up as a bottom sheet,
/// matching every other modal in the app, rather than floating right under
/// the thumb that opened it. Wider layouts keep the floating follower
/// unchanged, and the reaction picker it opens still reaches the same panel
/// either way.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/widgets/emoji_picker.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

Future<void> _pump(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    harness(
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
    ),
  );
  await tester.pumpAndSettle();
}

// The avatar, not the text: here an ancestor recognizer swallows a text press.
Offset _pressPoint(WidgetTester tester) =>
    tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
    const Offset(30, 30);

void main() {
  testWidgets('a compact layout opens the menu as a bottom sheet', (
    tester,
  ) async {
    await _pump(tester, const Size(360, 800));

    await tester.longPressAt(_pressPoint(tester));
    await tester.pumpAndSettle();

    expect(
      find.byType(BottomSheet),
      findsOneWidget,
      reason: 'a phone long-press should slide the menu up as a sheet',
    );
    expect(
      find.byType(CustomSingleChildLayout),
      findsNothing,
      reason: 'the anchored floating layout should not also be mounted',
    );
    expect(find.text('Copy text'), findsOneWidget);
  });

  testWidgets('a wide layout keeps the floating follower', (tester) async {
    await _pump(tester, const Size(1000, 800));

    await tester.longPressAt(_pressPoint(tester));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
    expect(
      find.byType(CustomSingleChildLayout),
      findsOneWidget,
      reason: 'the menu should still be anchored to the row, not sheeted',
    );
    expect(find.text('Copy text'), findsOneWidget);
  });

  testWidgets('the reaction picker still opens from the compact sheet', (
    tester,
  ) async {
    await _pump(tester, const Size(360, 800));

    await tester.longPressAt(_pressPoint(tester));
    await tester.pumpAndSettle();
    expect(find.byTooltip(ActionLabels.addReaction), findsOneWidget);

    await tester.tap(find.byTooltip(ActionLabels.addReaction));
    await tester.pumpAndSettle();

    expect(
      find.byType(EmojiPickerPanel),
      findsOneWidget,
      reason: 'closing the context sheet must not swallow the picker it opens',
    );
  });

  // The reported bug: a fixed-width, bordered AppMenu nested inside the sheet.
  testWidgets('the compact sheet is one surface, spanning the full width', (
    tester,
  ) async {
    const window = Size(360, 800);
    await _pump(tester, window);

    await tester.longPressAt(_pressPoint(tester));
    await tester.pumpAndSettle();

    expect(
      find.byType(AppMenu),
      findsNothing,
      reason:
          'the sheet already draws one surface; AppMenu would nest a '
          'second, bordered card inside it',
    );
    expect(
      tester.getRect(find.byType(BottomSheet)).width,
      window.width,
      reason: 'a phone sheet should be edge to edge, not a floating card',
    );
  });
}
