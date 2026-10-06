// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The context menu's forward and thread items, split from `message_context_menu_test.dart`
/// once that file crossed the 500-line hard ceiling in the merge that brought
/// forwarding and the thread cross-link together.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';

import 'message_row_harness.dart';

void main() {
  Widget row(MessageActions actions) => MessageRow(
    message: message(),
    grouped: false,
    showNewDivider: false,
    knownUsernames: const {},
    actions: actions,
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
  );

  Widget rowWith(MessageActions actions) => harness(row(actions));

  // Press the leading avatar; see message_context_menu_test.dart's own note.
  Offset pressPoint(WidgetTester tester) =>
      tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
      const Offset(30, 30);

  testWidgets('reply in thread is offered when allowed and reports its tap', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      rowWith(
        MessageActions(
          canReply: false,
          onReply: noop,
          canEdit: false,
          onEdit: noop,
          canDelete: false,
          onDelete: noop,
          canManagePins: false,
          pinned: false,
          onTogglePin: noop,
          canReport: false,
          onReport: noop,
          canBlockAuthor: false,
          onBlockAuthor: noop,
          canOpenThread: true,
          onOpenThread: () => opened = true,
          canCopyLink: false,
          onCopyLink: noop,
          canForward: false,
          onForward: noop,
          canSave: false,
          onSave: noop,
        ),
      ),
    );

    await tester.longPressAt(pressPoint(tester));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reply in thread'));
    expect(opened, isTrue);
  });

  testWidgets('forward is offered when allowed and reports its tap', (
    tester,
  ) async {
    var forwarded = false;
    await tester.pumpWidget(
      rowWith(
        MessageActions(
          canReply: false,
          onReply: noop,
          canEdit: false,
          onEdit: noop,
          canDelete: false,
          onDelete: noop,
          canManagePins: false,
          pinned: false,
          onTogglePin: noop,
          canReport: false,
          onReport: noop,
          canBlockAuthor: false,
          onBlockAuthor: noop,
          canOpenThread: false,
          onOpenThread: noop,
          canCopyLink: false,
          onCopyLink: noop,
          canForward: true,
          onForward: () => forwarded = true,
          canSave: false,
          onSave: noop,
        ),
      ),
    );

    await tester.longPressAt(pressPoint(tester));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Forward message'));
    expect(forwarded, isTrue);
  });

  testWidgets('forward is absent when the caller disallows it', (tester) async {
    await tester.pumpWidget(rowWith(noActions));

    await tester.longPressAt(pressPoint(tester));
    await tester.pumpAndSettle();

    expect(find.text('Forward message'), findsNothing);
  });
}
