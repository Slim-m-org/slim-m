// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message menu's shape: five quick reactions and a "+" across the top,
/// the verbs under them, and report, block and select folded behind "More" so
/// Delete is the only red row on the page.
///
/// Geometry, not presence: a row of tiles that exists but stacks, overflows or
/// sits under the verbs would pass a find and fail the design.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/control_swatch_row.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/features/emoji/widgets/quick_reactions.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

MessageActions _actions({
  VoidCallback? onBlock,
  bool own = false,
  bool moderator = false,
  bool selecting = false,
  VoidCallback? onReport,
}) => MessageActions(
  canReply: true,
  onReply: noop,
  canEdit: own,
  onEdit: noop,
  canDelete: own || moderator,
  onDelete: noop,
  canManagePins: moderator,
  pinned: false,
  onTogglePin: noop,
  canReport: !own,
  onReport: onReport ?? noop,
  canBlockAuthor: !own,
  onBlockAuthor: onBlock ?? noop,
  canOpenThread: true,
  onOpenThread: noop,
  canCopyLink: true,
  onCopyLink: noop,
  canForward: true,
  onForward: noop,
  canSave: true,
  onSave: noop,
  onStartSelecting: selecting ? noop : null,
);

Future<void> _open(
  WidgetTester tester,
  MessageActions actions, {
  Size window = const Size(900, 900),
  ValueChanged<String>? onPick,
  VoidCallback? onAdd,
  Set<String> reacted = const {},
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    harness(
      MessageContextMenuRegion(
        content: 'hello',
        actions: actions,
        onAddReaction: onAdd ?? noop,
        onPickReaction: onPick ?? (_) {},
        reactedEmoji: reacted,
        child: const SizedBox(width: 400, height: 200),
      ),
    ),
  );
  final at =
      tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
      const Offset(20, 20);
  if (window.width < kCompactWidth) {
    await tester.longPressAt(at);
  } else {
    await tester.tapAt(
      at,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
  }
  await tester.pumpAndSettle();
}

Iterable<AppMenuItem> _items(WidgetTester tester) =>
    tester.widgetList<AppMenuItem>(find.byType(AppMenuItem));

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
  testWidgets(
    'five quick reactions and a plus lead the menu, level and equal',
    (tester) async {
      await _open(tester, _actions());

      final tiles = _tiles(tester);
      expect(tiles, hasLength(kQuickReactions.length + 1));
      for (final tile in tiles) {
        expect(tile.top, tiles.first.top, reason: 'one level row');
        expect(tile.height, AppSizes.rowPointer);
        expect(tile.width, closeTo(tiles.first.width, 0.5));
      }
      final firstVerb = tester.getRect(find.byType(AppMenuItem).first);
      expect(
        tiles.first.bottom,
        lessThanOrEqualTo(firstVerb.top),
        reason: 'the reactions sit above every verb',
      );
      final menu = tester.getRect(find.byType(AppMenu));
      expect(tiles.first.left, greaterThanOrEqualTo(menu.left));
      expect(tiles.last.right, lessThanOrEqualTo(menu.right));
    },
  );

  testWidgets('a quick tile reacts with its emoji and closes the menu', (
    tester,
  ) async {
    String? picked;
    await _open(tester, _actions(), onPick: (e) => picked = e);

    await tester.tapAt(_tiles(tester).first.center);
    await tester.pumpAndSettle();

    expect(picked, kQuickReactions.first.token);
    expect(find.byType(AppMenu), findsNothing);
  });

  testWidgets('a reaction the viewer already left is drawn selected', (
    tester,
  ) async {
    await _open(tester, _actions(), reacted: {kQuickReactions[1].token});

    final row = tester.widget<ControlSwatchRow>(find.byType(ControlSwatchRow));
    expect(row.swatches.map((s) => s.selected), [
      false,
      true,
      false,
      false,
      false,
      false,
    ]);
  });

  testWidgets('the plus tile opens the picker', (tester) async {
    var opened = 0;
    await _open(tester, _actions(), onAdd: () => opened++);

    await tester.tapAt(_tiles(tester).last.center);
    await tester.pumpAndSettle();

    expect(opened, 1);
    expect(find.byType(AppMenu), findsNothing);
  });

  testWidgets('a member sees at most eight rows on someone else message', (
    tester,
  ) async {
    await _open(tester, _actions());
    expect(_items(tester).length, lessThanOrEqualTo(8));
    expect(find.text('Report message'), findsNothing);
    expect(find.text('Block user'), findsNothing);
    expect(find.text('More'), findsOneWidget);
  });

  testWidgets('a member sees at most eight rows on their own message', (
    tester,
  ) async {
    await _open(tester, _actions(own: true));
    expect(_items(tester).length, lessThanOrEqualTo(8));
    expect(find.text('More'), findsNothing, reason: 'nothing to fold away');
  });

  testWidgets('Delete is the only red row on the page', (tester) async {
    await _open(tester, _actions(own: true, moderator: true, selecting: true));

    final danger = _items(
      tester,
    ).where((i) => i.tone == AppMenuItemTone.danger);
    expect(danger.map((i) => i.label), ['Delete']);
    expect(find.text('Select messages'), findsNothing);
  });

  testWidgets('More swaps in report, block and select, and Back returns', (
    tester,
  ) async {
    var reported = false;
    await _open(
      tester,
      _actions(
        moderator: true,
        selecting: true,
        onReport: () => reported = true,
      ),
    );

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Report message'), findsOneWidget);
    expect(find.text('Block user'), findsOneWidget);
    expect(find.text('Select messages'), findsOneWidget);
    expect(find.text('Reply'), findsNothing);
    expect(find.byType(ControlSwatchRow), findsNothing);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(find.byType(ControlSwatchRow), findsOneWidget);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report message'));
    await tester.pumpAndSettle();
    expect(reported, isTrue);
    expect(find.byType(AppMenu), findsNothing);
  });

  testWidgets('Block user runs from behind More and closes the menu', (
    tester,
  ) async {
    var blocked = false;
    await _open(tester, _actions(onBlock: () => blocked = true));

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block user'));
    await tester.pumpAndSettle();

    expect(blocked, isTrue);
    expect(find.byType(AppMenu), findsNothing);
  });

  group('compact sheet', () {
    const phone = Size(360, 800);

    testWidgets('quick tiles span the sheet at the touch row height', (
      tester,
    ) async {
      await _open(tester, _actions(), window: phone);

      final tiles = _tiles(tester);
      expect(tiles, hasLength(kQuickReactions.length + 1));
      for (final tile in tiles) {
        expect(tile.height, AppSizes.rowTouch);
        expect(tile.width, closeTo((phone.width - 2 * AppSpacing.s8) / 6, 1.5));
      }
      expect(
        tiles.first.bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(AppMenuItem).first).top),
      );
    });

    testWidgets('More works by touch and the sheet stays one surface', (
      tester,
    ) async {
      await _open(tester, _actions(), window: phone);

      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.text('Report message'), findsOneWidget);
      expect(find.byType(AppMenu), findsNothing, reason: 'no floating card');
      for (final item in tester.widgetList(find.byType(AppMenuItem))) {
        expect(item, isA<AppMenuItem>());
      }
      await tester.tap(find.text('Block user'));
      await tester.pumpAndSettle();
      expect(find.text('Block user'), findsNothing);
    });
  });
}
