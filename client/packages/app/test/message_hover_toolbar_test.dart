// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The toolbar a message row reveals on hover or keyboard focus: which slots
/// it has, where it sits against the row and its neighbours, and that the
/// overflow opens the row's own context menu.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/emoji_picker.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_hover_toolbar.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/message_row_identity.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';
import 'package:slimm_app/src/action_labels.dart';

MessageActions _actions({
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

Widget _row(Message m, {bool grouped = false, MessageActions? actions}) =>
    MessageRow(
      key: ValueKey(m.id),
      message: m,
      grouped: grouped,
      showNewDivider: false,
      knownUsernames: const {},
      actions: actions ?? _actions(),
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

Future<TestGesture> _mouse(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: const Offset(-50, -50));
  return mouse;
}

Future<void> _hover(WidgetTester tester, TestGesture mouse, Finder row) async {
  await mouse.moveTo(tester.getCenter(row));
  await tester.pumpAndSettle();
}

final _plate = find.byKey(MessageHoverToolbar.plateKey);

/// The header's painted text, not its column-wide box, which says nothing about what the plate could hide.
Iterable<Rect> _headerTextRects(WidgetTester tester) => tester
    .widgetList(
      find.descendant(
        of: find.byType(MessageRowHeader),
        matching: find.byType(RichText),
      ),
    )
    .map((w) => tester.getRect(find.byWidget(w)));

void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('the toolbar shows on hover and is gone otherwise', (
    tester,
  ) async {
    await tester.pumpWidget(harness(_row(message())));
    await tester.pumpAndSettle();
    expect(_plate, findsNothing);

    final mouse = await _mouse(tester);
    await _hover(tester, mouse, find.byType(MessageRow));
    expect(_plate, findsOneWidget);

    await mouse.moveTo(const Offset(-50, -50));
    await tester.pumpAndSettle();
    expect(_plate, findsNothing);
  });

  testWidgets('keyboard focus reveals the toolbar and leaving hides it', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        Column(children: [_row(message()), const TextField()]),
        platform: TargetPlatform.linux,
      ),
    );
    await tester.pumpAndSettle();
    expect(_plate, findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_plate, findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(_plate, findsNothing);
  });

  testWidgets('a mouse click inside the toolbar does not pin it open', (
    tester,
  ) async {
    await tester.pumpWidget(harness(_row(message(), actions: _actions())));
    final mouse = await _mouse(tester);
    await _hover(tester, mouse, find.byType(MessageRow));
    await tester.tap(find.byKey(MessageHoverToolbar.replyKey));
    await tester.pumpAndSettle();

    await mouse.moveTo(const Offset(-50, -50));
    await tester.pumpAndSettle();
    expect(_plate, findsNothing);
  });

  for (final own in const [true, false]) {
    testWidgets('slots when the message is ${own ? 'yours' : 'not yours'}', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(_row(message(), actions: _actions(canEdit: own))),
      );
      final mouse = await _mouse(tester);
      await _hover(tester, mouse, find.byType(MessageRow));

      expect(find.byType(EmojiPickerButton), findsOneWidget);
      expect(find.byKey(MessageHoverToolbar.replyKey), findsOneWidget);
      expect(find.byKey(MessageHoverToolbar.threadKey), findsOneWidget);
      expect(find.byKey(MessageHoverToolbar.overflowKey), findsOneWidget);
      expect(
        find.byKey(MessageHoverToolbar.editKey),
        own ? findsOneWidget : findsNothing,
      );
      expect(
        find.descendant(of: _plate, matching: find.byType(AppIconButton)),
        findsNWidgets(own ? 5 : 4),
      );
    });
  }

  testWidgets('reply and edit run the row actions', (tester) async {
    var replied = 0;
    var edited = 0;
    await tester.pumpWidget(
      harness(
        _row(
          message(),
          actions: _actions(
            canEdit: true,
            onReply: () => replied++,
            onEdit: () => edited++,
          ),
        ),
      ),
    );
    final mouse = await _mouse(tester);
    await _hover(tester, mouse, find.byType(MessageRow));
    await tester.tap(find.byKey(MessageHoverToolbar.replyKey));
    await tester.tap(find.byKey(MessageHoverToolbar.editKey));
    expect((replied, edited), (1, 1));
  });

  testWidgets('no reply slot when the message cannot be replied to', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(_row(message(), actions: _actions(canReply: false))),
    );
    final mouse = await _mouse(tester);
    await _hover(tester, mouse, find.byType(MessageRow));

    expect(find.byKey(MessageHoverToolbar.replyKey), findsNothing);
    expect(find.byKey(MessageHoverToolbar.threadKey), findsOneWidget);
  });

  testWidgets('the overflow opens the existing context menu by the button', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(_row(message()), platform: TargetPlatform.linux),
    );
    final mouse = await _mouse(tester);
    await _hover(tester, mouse, find.byType(MessageRow));
    expect(find.text('Copy text'), findsNothing);

    await tester.tap(find.byKey(MessageHoverToolbar.overflowKey));
    await tester.pumpAndSettle();

    expect(find.text('Copy text'), findsOneWidget);
    expect(find.byTooltip(ActionLabels.addReaction), findsOneWidget);
    final button = tester.getRect(find.byKey(MessageHoverToolbar.overflowKey));
    final menu = tester.getRect(find.byType(AppMenu));
    expect(
      (menu.top - button.bottom).abs(),
      lessThan(24),
      reason: 'the menu opens beside the overflow, not at the row corner',
    );
  });

  group('geometry', () {
    testWidgets('the toolbar stays inside its row box', (tester) async {
      await tester.pumpWidget(harness(_row(message(content: 'one line'))));
      final mouse = await _mouse(tester);
      await _hover(tester, mouse, find.byType(MessageRow));

      final row = tester.getRect(find.byType(MessageRow));
      final plate = tester.getRect(_plate);
      expect(plate.top, greaterThanOrEqualTo(row.top));
      expect(plate.right, lessThanOrEqualTo(row.right));
      expect(plate.height, MessageHoverToolbar.height);
    });

    testWidgets('it never covers the row\'s own header line', (tester) async {
      await tester.pumpWidget(harness(_row(message(content: 'one line'))));
      final mouse = await _mouse(tester);
      await _hover(tester, mouse, find.byType(MessageRow));

      final plate = tester.getRect(_plate);
      expect(_headerTextRects(tester), isNotEmpty);
      for (final text in _headerTextRects(tester)) {
        expect(plate.overlaps(text), isFalse, reason: '$text under $plate');
      }
    });

    testWidgets('the header stays clear at the narrowest wide layout', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(kCompactWidth, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        harness(
          _row(
            message(authorDisplayName: 'Priya with a fairly long name'),
            actions: _actions(canEdit: true),
          ),
        ),
      );
      final mouse = await _mouse(tester);
      await _hover(tester, mouse, find.byType(MessageRow));

      expect(_headerTextRects(tester), isNotEmpty);
      for (final text in _headerTextRects(tester)) {
        expect(
          tester.getRect(_plate).overlaps(text),
          isFalse,
          reason: '$text vs ${tester.getRect(_plate)}',
        );
      }
    });

    testWidgets('the first row in a scrolled transcript is not clipped', (
      tester,
    ) async {
      const viewportKey = Key('viewport');
      await tester.pumpWidget(
        harness(
          SizedBox(
            key: viewportKey,
            height: 300,
            child: ListView(children: [_row(message(id: 'first'))]),
          ),
        ),
      );
      final mouse = await _mouse(tester);
      await _hover(tester, mouse, find.byType(MessageRow));

      final viewport = tester.getRect(find.byKey(viewportKey));
      final plate = tester.getRect(_plate);
      expect(plate.top, greaterThanOrEqualTo(viewport.top));
      expect(plate.bottom, lessThanOrEqualTo(viewport.bottom));
    });

    testWidgets('the whole plate responds in a tight grouped run', (
      tester,
    ) async {
      var replied = 0;
      final actions = _actions(onReply: () => replied++);
      await tester.pumpWidget(
        harness(
          ListView(
            children: [
              _row(
                message(id: 'a', content: 'one'),
                actions: actions,
              ),
              for (final id in const ['b', 'c', 'd'])
                _row(
                  message(id: id, content: 'line $id'),
                  grouped: true,
                  actions: actions,
                ),
            ],
          ),
        ),
      );
      final mouse = await _mouse(tester);
      final middle = find.byKey(const ValueKey('c'));
      await _hover(tester, mouse, middle);

      final rowRect = tester.getRect(middle);
      final plate = tester.getRect(_plate);
      expect(rowRect.height, greaterThanOrEqualTo(MessageHoverToolbar.height));
      expect(plate.top, greaterThanOrEqualTo(rowRect.top));
      expect(plate.bottom, lessThanOrEqualTo(rowRect.bottom));

      final x = tester.getCenter(find.byKey(MessageHoverToolbar.replyKey)).dx;
      for (final y in [plate.top + 1, plate.center.dy, plate.bottom - 1]) {
        await tester.tapAt(Offset(x, y));
        await tester.pumpAndSettle();
        await _hover(tester, mouse, middle);
      }
      expect(replied, 3, reason: 'top edge, centre and bottom edge all hit');
    });

    testWidgets('toolbars on adjacent rows never overlap', (tester) async {
      await tester.pumpWidget(
        harness(
          Column(
            children: [
              _row(message(id: 'a', content: 'one'), grouped: true),
              _row(message(id: 'b', content: 'two'), grouped: true),
              const TextField(),
            ],
          ),
          platform: TargetPlatform.linux,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      final mouse = await _mouse(tester);
      await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('b'))));
      await tester.pumpAndSettle();

      expect(_plate, findsNWidgets(2));
      expect(
        tester.getRect(_plate.first).overlaps(tester.getRect(_plate.last)),
        isFalse,
      );
    });

    testWidgets('a long first line in a headerless row stops short of it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(kCompactWidth, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const long =
          'a long first line that would otherwise run all the way '
          'across the pane and under the toolbar at this narrow width';
      await tester.pumpWidget(
        harness(_row(message(content: long), grouped: true)),
      );
      final mouse = await _mouse(tester);
      await _hover(tester, mouse, find.byType(MessageRow));

      final body = tester.getRect(find.textContaining('a long first line'));
      expect(body.right, lessThanOrEqualTo(tester.getRect(_plate).left));
    });

    testWidgets('a toolbar never reaches into the row above', (tester) async {
      await tester.pumpWidget(
        harness(
          ListView(
            children: [
              _row(message(id: 'a', content: 'one')),
              _row(message(id: 'b', content: 'two'), grouped: true),
            ],
          ),
        ),
      );
      final mouse = await _mouse(tester);
      await _hover(tester, mouse, find.byKey(const ValueKey('b')));

      final above = tester.getRect(find.byKey(const ValueKey('a')));
      expect(tester.getRect(_plate).overlaps(above), isFalse);
    });
  });

  testWidgets('the compact long-press sheet is unchanged', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(_row(message())));
    await tester.longPressAt(
      tester.getTopLeft(find.byType(MessageRow)) + const Offset(40, 20),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip(ActionLabels.addReaction), findsOneWidget);
    expect(find.byType(AppMenu), findsNothing, reason: 'a sheet, not a popup');
    expect(_plate, findsNothing);
  });

  group('a compact-width window with a mouse', () {
    Future<void> hoverAt390(
      WidgetTester tester,
      Message m, {
      bool grouped = false,
    }) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness(_row(m, grouped: grouped)));
      final mouse = await _mouse(tester);
      await _hover(tester, mouse, find.byType(MessageRow));
    }

    void expectPlateClear(WidgetTester tester) {
      if (_plate.evaluate().isEmpty) return;
      final plate = tester.getRect(_plate);
      final row = tester.getRect(find.byType(MessageRow));
      expect(plate.bottom, lessThanOrEqualTo(row.bottom), reason: 'overhang');
      for (final r in _headerTextRects(tester)) {
        expect(plate.overlaps(r), isFalse, reason: 'plate covers header $r');
      }
    }

    testWidgets('renders no toolbar, so nothing covers the header', (
      tester,
    ) async {
      await hoverAt390(tester, message(content: 'hello'));
      expect(_headerTextRects(tester), isNotEmpty);
      expect(_plate, findsNothing);
      expectPlateClear(tester);
    });

    testWidgets('renders no toolbar on a short grouped row', (tester) async {
      await hoverAt390(tester, message(content: 'one line'), grouped: true);
      expect(_plate, findsNothing);
      expectPlateClear(tester);
    });
  });

  testWidgets('a failed or pending message shows no toolbar', (tester) async {
    await tester.pumpWidget(
      harness(_row(message(pending: true, content: 'sending'))),
    );
    final mouse = await _mouse(tester);
    await _hover(tester, mouse, find.byType(MessageRow));
    expect(_plate, findsNothing);
  });
}
