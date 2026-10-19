// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The toolbar a message row reveals on hover or keyboard focus: which slots
/// it has, where it sits against the row and its neighbours, and that the
/// overflow opens the row's own context menu.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker.dart';
import 'package:slimm_app/src/features/messages/widgets/message_hover_toolbar.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';
import 'package:slimm_app/src/action_labels.dart';
import 'message_hover_toolbar_support.dart';

void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('the toolbar shows on hover and is gone otherwise', (
    tester,
  ) async {
    await tester.pumpWidget(harness(hoverRow(message())));
    await tester.pumpAndSettle();
    expect(hoverPlate, findsNothing);

    final mouse = await hoverMouse(tester);
    await hoverHover(tester, mouse, find.byType(MessageRow));
    expect(hoverPlate, findsOneWidget);

    await mouse.moveTo(const Offset(-50, -50));
    await tester.pumpAndSettle();
    expect(hoverPlate, findsNothing);
  });

  testWidgets('keyboard focus reveals the toolbar and leaving hides it', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        Column(children: [hoverRow(message()), const TextField()]),
        platform: TargetPlatform.linux,
      ),
    );
    await tester.pumpAndSettle();
    expect(hoverPlate, findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(hoverPlate, findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(hoverPlate, findsNothing);
  });

  testWidgets('a mouse click inside the toolbar does not pin it open', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(hoverRow(message(), actions: hoverActions())),
    );
    final mouse = await hoverMouse(tester);
    await hoverHover(tester, mouse, find.byType(MessageRow));
    await tester.tap(find.byKey(MessageHoverToolbar.replyKey));
    await tester.pumpAndSettle();

    await mouse.moveTo(const Offset(-50, -50));
    await tester.pumpAndSettle();
    expect(hoverPlate, findsNothing);
  });

  for (final own in const [true, false]) {
    testWidgets('slots when the message is ${own ? 'yours' : 'not yours'}', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(hoverRow(message(), actions: hoverActions(canEdit: own))),
      );
      final mouse = await hoverMouse(tester);
      await hoverHover(tester, mouse, find.byType(MessageRow));

      expect(find.byType(EmojiPickerButton), findsOneWidget);
      expect(find.byKey(MessageHoverToolbar.replyKey), findsOneWidget);
      expect(find.byKey(MessageHoverToolbar.threadKey), findsOneWidget);
      expect(find.byKey(MessageHoverToolbar.overflowKey), findsOneWidget);
      expect(
        find.byKey(MessageHoverToolbar.editKey),
        own ? findsOneWidget : findsNothing,
      );
      expect(
        find.descendant(of: hoverPlate, matching: find.byType(AppIconButton)),
        findsNWidgets(own ? 5 : 4),
      );
    });
  }

  testWidgets('reply and edit run the row actions', (tester) async {
    var replied = 0;
    var edited = 0;
    await tester.pumpWidget(
      harness(
        hoverRow(
          message(),
          actions: hoverActions(
            canEdit: true,
            onReply: () => replied++,
            onEdit: () => edited++,
          ),
        ),
      ),
    );
    final mouse = await hoverMouse(tester);
    await hoverHover(tester, mouse, find.byType(MessageRow));
    await tester.tap(find.byKey(MessageHoverToolbar.replyKey));
    await tester.tap(find.byKey(MessageHoverToolbar.editKey));
    expect((replied, edited), (1, 1));
  });

  testWidgets('no reply slot when the message cannot be replied to', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(hoverRow(message(), actions: hoverActions(canReply: false))),
    );
    final mouse = await hoverMouse(tester);
    await hoverHover(tester, mouse, find.byType(MessageRow));

    expect(find.byKey(MessageHoverToolbar.replyKey), findsNothing);
    expect(find.byKey(MessageHoverToolbar.threadKey), findsOneWidget);
  });

  testWidgets('the overflow opens the existing context menu by the button', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(hoverRow(message()), platform: TargetPlatform.linux),
    );
    final mouse = await hoverMouse(tester);
    await hoverHover(tester, mouse, find.byType(MessageRow));
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

  testWidgets('the compact long-press sheet is unchanged', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(hoverRow(message())));
    await tester.longPressAt(
      tester.getTopLeft(find.byType(MessageRow)) + const Offset(40, 20),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip(ActionLabels.addReaction), findsOneWidget);
    expect(find.byType(AppMenu), findsNothing, reason: 'a sheet, not a popup');
    expect(hoverPlate, findsNothing);
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
      await tester.pumpWidget(harness(hoverRow(m, grouped: grouped)));
      final mouse = await hoverMouse(tester);
      await hoverHover(tester, mouse, find.byType(MessageRow));
    }

    void expectPlateClear(WidgetTester tester) {
      if (hoverPlate.evaluate().isEmpty) return;
      final plate = tester.getRect(hoverPlate);
      final row = tester.getRect(find.byType(MessageRow));
      expect(plate.bottom, lessThanOrEqualTo(row.bottom), reason: 'overhang');
      for (final r in hoverHeaderTextRects(tester)) {
        expect(plate.overlaps(r), isFalse, reason: 'plate covers header $r');
      }
    }

    testWidgets('renders no toolbar, so nothing covers the header', (
      tester,
    ) async {
      await hoverAt390(tester, message(content: 'hello'));
      expect(hoverHeaderTextRects(tester), isNotEmpty);
      expect(hoverPlate, findsNothing);
      expectPlateClear(tester);
    });

    testWidgets('renders no toolbar on a short grouped row', (tester) async {
      await hoverAt390(tester, message(content: 'one line'), grouped: true);
      expect(hoverPlate, findsNothing);
      expectPlateClear(tester);
    });
  });

  testWidgets('a failed or pending message shows no toolbar', (tester) async {
    await tester.pumpWidget(
      harness(hoverRow(message(pending: true, content: 'sending'))),
    );
    final mouse = await hoverMouse(tester);
    await hoverHover(tester, mouse, find.byType(MessageRow));
    expect(hoverPlate, findsNothing);
  });
}
