// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression test for a menu that outlived the row it belongs to.
///
/// The menu is placed once, at the anchor read when it opens, on the grounds
/// that a scroll closes it first. That holds for a touch drag, which begins
/// with a pointer down [TapRegion] sees, and not for a wheel or a trackpad:
/// a pointer signal has no down event at all, so the list scrolled out from
/// under an open menu and left it hovering over a different message.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

void _noop() {}

const _noActions = MessageActions(
  canReply: false,
  onReply: _noop,
  canEdit: false,
  onEdit: _noop,
  canDelete: false,
  onDelete: _noop,
  canManagePins: false,
  pinned: false,
  onTogglePin: _noop,
  canReport: false,
  onReport: _noop,
  canBlockAuthor: false,
  onBlockAuthor: _noop,
  canOpenThread: false,
  onOpenThread: _noop,
  canCopyLink: false,
  onCopyLink: _noop,
  canForward: false,
  onForward: _noop,
  canSave: false,
  onSave: _noop,
);

Message _message(int index) => Message(
  id: 'm$index',
  channelId: 'c1',
  authorId: 'author-$index',
  authorDisplayName: 'Priya',
  seq: index,
  content: 'message $index',
  createdAt: 1700000000000 + index,
  pending: false,
  failed: false,
);

/// A list long enough to scroll, with each row keyed so the finder still
/// resolves to the same one after the viewport has moved.
Widget _harness() => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: ListView(
        children: [
          for (var i = 0; i < 40; i++)
            MessageRow(
              key: ValueKey('row-$i'),
              message: _message(i),
              grouped: false,
              showNewDivider: false,
              knownUsernames: const {},
              actions: _noActions,
              editing: false,
              callbacks: MessageRowCallbacks(
                onRetry: _noop,
                onDiscard: _noop,
                onPickReaction: (_) {},
                onReactionTap: (_) {},
                onVote: (_) {},
                onSubmitEdit: (_) {},
                onCancelEdit: _noop,
              ),
            ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('a wheel scroll closes the menu instead of stranding it over '
      'another message', (tester) async {
    await tester.pumpWidget(_harness());

    final region = find.descendant(
      of: find.byKey(const ValueKey('row-2')),
      matching: find.byType(MessageContextMenuRegion),
    );
    final anchor = tester.getTopLeft(region) + const Offset(30, 30);

    await tester.tapAt(
      anchor,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(
      find.byType(AppMenu),
      findsOneWidget,
      reason:
          'the right-click has to open a menu for the rest to mean '
          'anything',
    );
    final rowBefore = tester.getRect(region);

    // Well clear of the menu's own 200pt-wide column, which has a scroll view
    // of its own and would swallow the wheel before the list ever saw it.
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(600, 300)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 150)));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(region).top,
      lessThan(rowBefore.top),
      reason:
          'the wheel must actually move the list, or this test proves '
          'nothing about what the menu did while it moved',
    );
    expect(
      find.byType(AppMenu),
      findsNothing,
      reason:
          'a menu left open after its row has moved is anchored to '
          'whatever message now sits where that row was',
    );
  });

  testWidgets('a menu that was never open survives a scroll', (tester) async {
    await tester.pumpWidget(_harness());

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(200, 200)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 150)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AppMenu), findsNothing);
  });
}
