// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Editing a message draws a custom `:name:` as its emoji in place and saves the canonical text.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';

import 'message_row_harness.dart';

Widget _row(List<String> saved) => harness(
  Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 600,
      child: MessageRow(
        message: message(content: 'hi'),
        grouped: false,
        showNewDivider: false,
        knownUsernames: const {},
        customEmoji: const {'hehe': 'e-hehe'},
        actions: noActions,
        editing: true,
        callbacks: MessageRowCallbacks(
          onRetry: noop,
          onDiscard: noop,
          onPickReaction: (_) {},
          onReactionTap: (_) {},
          onVote: (_) {},
          onSubmitEdit: saved.add,
          onCancelEdit: noop,
        ),
      ),
    ),
  ),
  platform: TargetPlatform.linux,
);

final _editable = find.byWidgetPredicate((w) => w is EditableText);
final _inField = find.descendant(
  of: _editable,
  matching: find.byWidgetPredicate((w) => w is CustomEmojiImage),
);

void main() {
  testWidgets('an edit draws the emoji in the field and saves canonical text', (
    tester,
  ) async {
    final saved = <String>[];
    await tester.pumpWidget(_row(saved));
    await tester.pump();

    await tester.enterText(_editable, 'a :HeHe: b :nope:');
    await tester.pump();
    expect(_inField, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(saved, ['a :hehe: b :nope:']);
  });
}
