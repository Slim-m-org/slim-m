// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one property the hover overlay exists for: hovering a message must not
/// change its size.
///
/// The add-a-reaction control used to render inside the row, revealed on
/// hover, so an unreacted message grew by the button's height the moment a
/// pointer touched it - and every message below it moved. The owner reported
/// it as the log bouncing under the cursor.
///
/// This is measured rather than inspected: asserting the button is in a
/// `Stack` would pass just as well if someone put it back in the `Column`
/// inside one, and asserting on layout is what actually says the log holds
/// still.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/emoji_picker.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/reactions_row.dart';

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

void main() {
  testWidgets('hovering a message does not change its height', (tester) async {
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    final before = tester.getSize(find.byType(MessageRow));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(MessageRow)));
    await tester.pumpAndSettle();

    // The affordance really is revealed - otherwise this passes vacuously.
    expect(find.byType(EmojiPickerButton), findsOneWidget);

    final after = tester.getSize(find.byType(MessageRow));
    expect(
      after.height,
      before.height,
      reason: 'revealing the hover actions must not reflow the transcript',
    );
  });

  testWidgets('a message with no reactions renders no reactions row', (
    tester,
  ) async {
    // It used to render for the add-button alone, giving it height to grow.
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    expect(find.byType(ReactionsRow), findsOneWidget);
    expect(
      tester.getSize(find.byType(ReactionsRow)),
      Size.zero,
      reason: 'an unreacted message must occupy no space for reactions',
    );
  });
}
