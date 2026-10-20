// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for the message hover toolbar suites.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_context_menu.dart';
import 'package:slimm_app/src/features/messages/widgets/message_hover_toolbar.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_data/data.dart';

import 'message_row_harness.dart';

MessageActions hoverActions({
  bool canReply = true,
  bool canEdit = false,
  VoidCallback? onReply,
  VoidCallback? onEdit,
}) => MessageActions(
  canReply: canReply,
  onReply: onReply ?? noop,
  canEdit: canEdit,
  onEdit: onEdit ?? noop,
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
  onOpenThread: noop,
  canCopyLink: false,
  onCopyLink: noop,
  canForward: false,
  onForward: noop,
  canSave: false,
  onSave: noop,
);

Widget hoverRow(Message m, {bool grouped = false, MessageActions? actions}) =>
    MessageRow(
      key: ValueKey(m.id),
      message: m,
      grouped: grouped,
      showNewDivider: false,
      knownUsernames: const {},
      actions: actions ?? hoverActions(),
      editing: false,
      callbacks: MessageRowCallbacks(
        onRetry: noop,
        onDiscard: noop,
        onPickReaction: (_) {},
        onReactionTap: (_) {},
        onVote: (_) {},
        onSubmitEdit: (_) {},
        onCancelEdit: noop,
      ),
    );

Future<TestGesture> hoverMouse(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: const Offset(-50, -50));
  return mouse;
}

Future<void> hoverHover(
  WidgetTester tester,
  TestGesture mouse,
  Finder row,
) async {
  await mouse.moveTo(tester.getCenter(row));
  await tester.pumpAndSettle();
}

final hoverPlate = find.byKey(MessageHoverToolbar.plateKey);

/// The header's painted text, not its column-wide box, which says nothing about what the plate could hide.
Iterable<Rect> hoverHeaderTextRects(WidgetTester tester) => tester
    .widgetList(
      find.descendant(
        of: find.byType(MessageRowHeader),
        matching: find.byType(RichText),
      ),
    )
    .map((w) => tester.getRect(find.byWidget(w)));
