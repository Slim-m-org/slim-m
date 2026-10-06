// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone long-press sheet: reacting is one tap after the hold, not three,
/// because the sheet opens with the quick reactions as touch-sized tiles.
///
/// Driven through a real [MessageRow] at phone width. The layout is chosen by
/// width, so nothing here needs the desktop-host override: a 390-wide window on
/// any platform takes the sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_extras.dart' show MessageExtras;
import 'package:slimm_app/src/widgets/control_swatch_row.dart';
import 'package:slimm_app/src/widgets/emoji_picker.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/quick_reactions.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _phone = Size(390, 844);

MessageActions _actions() => const MessageActions(
  canReply: true,
  onReply: noop,
  canEdit: false,
  onEdit: noop,
  canDelete: false,
  onDelete: noop,
  canManagePins: false,
  pinned: false,
  onTogglePin: noop,
  canReport: true,
  onReport: noop,
  canBlockAuthor: true,
  onBlockAuthor: noop,
  canOpenThread: true,
  onOpenThread: noop,
  canCopyLink: true,
  onCopyLink: noop,
  canForward: true,
  onForward: noop,
  canSave: true,
  onSave: noop,
);

Future<void> _openSheet(
  WidgetTester tester, {
  ValueChanged<String>? onPick,
  List<api.ReactionSummary> reactions = const [],
}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    harness(
      MessageRow(
        message: message(),
        grouped: false,
        showNewDivider: false,
        knownUsernames: const {},
        actions: _actions(),
        editing: false,
        callbacks: MessageRowCallbacks(
          onRetry: noop,
          onDiscard: noop,
          onPickReaction: onPick ?? (_) {},
          onReactionTap: (_) {},
          onVote: (_) {},
          onSubmitEdit: (_) {},
          onCancelEdit: noop,
        ),
        extras: MessageExtras(reactions: reactions),
      ),
    ),
  );
  await tester.longPressAt(
    tester.getTopLeft(find.byType(MessageRow)) + const Offset(40, 20),
  );
  await tester.pumpAndSettle();
}

List<Rect> _tiles(WidgetTester tester) => [
  for (final t in tester.widgetList(
    find.descendant(
      of: find.byType(ControlSwatchRow),
      matching: find.byType(Tooltip),
    ),
  ))
    tester.getRect(find.byWidget(t)),
];

void main() {
  testWidgets('the sheet opens with five 44px reaction tiles and a plus', (
    tester,
  ) async {
    await _openSheet(tester);

    final tiles = _tiles(tester);
    expect(tiles, hasLength(kQuickReactions.length + 1));
    for (final tile in tiles) {
      expect(tile.height, AppSizes.rowTouch);
      expect(tile.top, tiles.first.top);
      expect(tile.width, greaterThanOrEqualTo(AppSizes.rowTouch));
    }
    expect(tiles.first.left, greaterThanOrEqualTo(0));
    expect(tiles.last.right, lessThanOrEqualTo(_phone.width));
    expect(find.byType(AppMenu), findsNothing, reason: 'a sheet, not a popup');
  });

  testWidgets('Reply and Reply in thread are the first two verbs', (
    tester,
  ) async {
    await _openSheet(tester);

    final verbs = tester
        .widgetList<AppMenuItem>(find.byType(AppMenuItem))
        .map((i) => i.label)
        .toList();
    expect(verbs.take(2), ['Reply', 'Reply in thread']);
    final reply = tester.getRect(find.text('Reply'));
    expect(reply.top, greaterThan(_tiles(tester).first.bottom));
  });

  testWidgets('one tap after the hold reacts and closes the sheet', (
    tester,
  ) async {
    String? picked;
    await _openSheet(tester, onPick: (e) => picked = e);

    await tester.tapAt(_tiles(tester)[1].center);
    await tester.pumpAndSettle();

    expect(picked, kQuickReactions[1].token);
    expect(find.byType(ControlSwatchRow), findsNothing);
    expect(find.byType(EmojiPickerPanel), findsNothing);
  });

  testWidgets('the plus is the way to the full picker', (tester) async {
    await _openSheet(tester);

    await tester.tapAt(_tiles(tester).last.center);
    await tester.pumpAndSettle();

    expect(find.byType(EmojiPickerPanel), findsOneWidget);
  });

  testWidgets('a reaction already left is selected in the sheet', (
    tester,
  ) async {
    await _openSheet(
      tester,
      reactions: [
        api.ReactionSummary(
          emoji: kQuickReactions.first.token,
          count: 2,
          reacted: true,
        ),
      ],
    );

    final row = tester.widget<ControlSwatchRow>(find.byType(ControlSwatchRow));
    expect(row.swatches.first.selected, isTrue);
    expect(row.swatches.skip(1).any((s) => s.selected), isFalse);
  });
}
