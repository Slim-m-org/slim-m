// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message with reactions shows its chips and no add-reaction control at
/// rest (owner, 2026-10-02: "this reaction ( + ) ui is not needed to be shown
/// all the time, if anything on hover").
///
/// A pointer reaches Add reaction through the hover toolbar, a finger through
/// the long-press menu (desktop-vs-mobile rule 3), and tapping a chip toggles
/// the viewer's own reaction. Hovering must not reflow the row.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/providers/message_extras.dart' show MessageExtras;
import 'package:slimm_app/src/widgets/emoji_picker.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/reactions_row.dart';

import 'message_row_harness.dart';

Widget _row(List<String> tapped) => harness(
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
      onReactionTap: (r) => tapped.add(r.emoji),
      onVote: (_) {},
      onSubmitEdit: (_) {},
      onCancelEdit: () {},
    ),
    extras: MessageExtras(
      reactions: const [
        api.ReactionSummary(emoji: '\u{1F440}', count: 1, reacted: false),
      ],
    ),
  ),
);

void main() {
  testWidgets('chips show no add control at rest and tapping one toggles', (
    tester,
  ) async {
    final tapped = <String>[];
    await tester.pumpWidget(_row(tapped));
    await tester.pumpAndSettle();

    expect(find.byType(ReactionsRow), findsOneWidget);
    expect(find.byType(EmojiPickerButton), findsNothing);
    expect(find.byTooltip(ActionLabels.addReaction), findsNothing);

    await tester.tap(find.text('1').first);
    expect(tapped, ['\u{1F440}']);
  });

  testWidgets('hover reveals Add reaction without reflowing the row', (
    tester,
  ) async {
    await tester.pumpWidget(_row([]));
    await tester.pumpAndSettle();
    final before = tester.getSize(find.byType(MessageRow));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(MessageRow)));
    await tester.pumpAndSettle();

    expect(find.byType(EmojiPickerButton), findsOneWidget);
    expect(tester.getSize(find.byType(MessageRow)), before);
  });
}
