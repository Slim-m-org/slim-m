// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the message hover toolbar sits against its row and the rows around it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_hover_toolbar.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_app/src/widgets/hover_reveal.dart';

import 'message_row_harness.dart';
import 'message_hover_toolbar_support.dart';

void main() {
  group('geometry', () {
    testWidgets('the toolbar stays inside its row box', (tester) async {
      await tester.pumpWidget(harness(hoverRow(message(content: 'one line'))));
      final mouse = await hoverMouse(tester);
      await hoverHover(tester, mouse, find.byType(MessageRow));

      final row = tester.getRect(find.byType(MessageRow));
      final plate = tester.getRect(hoverPlate);
      expect(plate.top, greaterThanOrEqualTo(row.top));
      expect(plate.right, lessThanOrEqualTo(row.right));
      expect(plate.height, MessageHoverToolbar.height);
    });

    testWidgets('it never covers the row\'s own header line', (tester) async {
      await tester.pumpWidget(harness(hoverRow(message(content: 'one line'))));
      final mouse = await hoverMouse(tester);
      await hoverHover(tester, mouse, find.byType(MessageRow));

      final plate = tester.getRect(hoverPlate);
      expect(hoverHeaderTextRects(tester), isNotEmpty);
      for (final text in hoverHeaderTextRects(tester)) {
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
          hoverRow(
            message(authorDisplayName: 'Priya with a fairly long name'),
            actions: hoverActions(canEdit: true),
          ),
        ),
      );
      final mouse = await hoverMouse(tester);
      await hoverHover(tester, mouse, find.byType(MessageRow));

      expect(hoverHeaderTextRects(tester), isNotEmpty);
      for (final text in hoverHeaderTextRects(tester)) {
        expect(
          tester.getRect(hoverPlate).overlaps(text),
          isFalse,
          reason: '$text vs ${tester.getRect(hoverPlate)}',
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
            child: ListView(children: [hoverRow(message(id: 'first'))]),
          ),
        ),
      );
      final mouse = await hoverMouse(tester);
      await hoverHover(tester, mouse, find.byType(MessageRow));

      final viewport = tester.getRect(find.byKey(viewportKey));
      final plate = tester.getRect(hoverPlate);
      expect(plate.top, greaterThanOrEqualTo(viewport.top));
      expect(plate.bottom, lessThanOrEqualTo(viewport.bottom));
    });

    testWidgets('the whole plate responds in a tight grouped run', (
      tester,
    ) async {
      var replied = 0;
      final actions = hoverActions(onReply: () => replied++);
      await tester.pumpWidget(
        harness(
          ListView(
            children: [
              hoverRow(
                message(id: 'a', content: 'one'),
                actions: actions,
              ),
              for (final id in const ['b', 'c', 'd'])
                hoverRow(
                  message(id: id, content: 'line $id'),
                  grouped: true,
                  actions: actions,
                ),
            ],
          ),
        ),
      );
      final mouse = await hoverMouse(tester);
      final middle = find.byKey(const ValueKey('c'));
      await hoverHover(tester, mouse, middle);

      final rowRect = tester.getRect(middle);
      final plate = tester.getRect(hoverPlate);
      expect(
        rowRect.height,
        lessThan(MessageHoverToolbar.height),
        reason: 'a one-line row keeps its density spacing',
      );
      expect(plate.top, rowRect.top);
      expect(plate.bottom, greaterThan(rowRect.bottom), reason: 'overhangs');

      final x = tester.getCenter(find.byKey(MessageHoverToolbar.replyKey)).dx;
      for (final y in [plate.top + 1, plate.center.dy, plate.bottom - 1]) {
        await tester.tapAt(Offset(x, y));
        await tester.pumpAndSettle();
        await hoverHover(tester, mouse, middle);
      }
      expect(replied, 3, reason: 'top edge, centre and bottom edge all hit');
    });

    testWidgets('moving from the row onto the overhanging plate keeps it', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          ListView(
            children: [
              hoverRow(message(id: 'a', content: 'one')),
              for (final id in const ['b', 'c'])
                hoverRow(message(id: id, content: 'line $id'), grouped: true),
            ],
          ),
        ),
      );
      final mouse = await hoverMouse(tester);
      final row = find.byKey(const ValueKey('b'));
      await hoverHover(tester, mouse, row);
      final plate = tester.getRect(hoverPlate);

      await mouse.moveTo(Offset(plate.center.dx, plate.bottom - 1));
      await tester.pumpAndSettle();
      expect(
        hoverPlate,
        findsOneWidget,
        reason: 'the next row is under the plate',
      );
      expect(tester.getRect(hoverPlate), plate);
    });

    testWidgets('the plate follows its row as the list scrolls', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        harness(
          SizedBox(
            height: 300,
            child: ListView(
              controller: controller,
              children: [
                hoverRow(message(id: 'a', content: 'head')),
                for (final id in const ['b', 'c', 'd', 'e', 'f'])
                  hoverRow(message(id: id, content: 'line $id'), grouped: true),
              ],
            ),
          ),
        ),
      );
      final mouse = await hoverMouse(tester);
      final row = find.byKey(const ValueKey('d'));
      await mouse.moveTo(tester.getTopLeft(row) + const Offset(100, 8));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(hoverPlate).dy, tester.getTopLeft(row).dy);

      controller.jumpTo(6);
      await tester.pump();
      await tester.pump(AppMotion.fast * 2);
      expect(hoverPlate, findsNothing, reason: 'hover is calm while scrolling');
      await tester.pump(kScrollSettle + kRowHoverIntent);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(row).dy, lessThan(300));
      expect(tester.getTopLeft(hoverPlate).dy, tester.getTopLeft(row).dy);
    });

    testWidgets('a row scrolled half out of the list shows no plate', (
      tester,
    ) async {
      final controller = ScrollController(initialScrollOffset: 10);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        harness(
          SizedBox(
            height: 300,
            child: ListView(
              controller: controller,
              children: [
                hoverRow(message(id: 'a', content: 'head')),
                for (var i = 0; i < 30; i++)
                  hoverRow(
                    message(id: 'r$i', content: 'line $i'),
                    grouped: true,
                  ),
              ],
            ),
          ),
        ),
      );
      final mouse = await hoverMouse(tester);
      final row = find.byKey(const ValueKey('a'));
      await mouse.moveTo(tester.getBottomLeft(row) + const Offset(100, -4));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(row).dy, lessThan(0));
      expect(
        hoverPlate,
        findsNothing,
        reason: 'it would float over the header',
      );
    });

    testWidgets('consecutive one-line follow-ups sit at the density pitch', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          ListView(
            children: [
              hoverRow(message(id: 'a', content: 'head')),
              for (final id in const ['b', 'c', 'd', 'e'])
                hoverRow(message(id: id, content: 'line $id'), grouped: true),
            ],
          ),
        ),
      );
      final tops = [
        for (final id in const ['b', 'c', 'd', 'e'])
          tester.getTopLeft(find.byKey(ValueKey(id))).dy,
      ];
      final pitches = [
        for (var i = 1; i < tops.length; i++) tops[i] - tops[i - 1],
      ];
      expect(pitches.toSet(), hasLength(1));
      expect(pitches.first, lessThan(MessageHoverToolbar.height));
    });

    testWidgets('toolbars on adjacent rows leave each other\'s buttons clear', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          Column(
            children: [
              hoverRow(message(id: 'a', content: 'one'), grouped: true),
              hoverRow(message(id: 'b', content: 'two'), grouped: true),
              const TextField(),
            ],
          ),
          platform: TargetPlatform.linux,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      final mouse = await hoverMouse(tester);
      await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('b'))));
      await tester.pumpAndSettle();

      expect(hoverPlate, findsNWidgets(2));
      final upper = tester.getRect(hoverPlate.first);
      final lower = tester.getRect(hoverPlate.last);
      expect(lower.top, greaterThan(upper.top));
      for (final key in [
        MessageHoverToolbar.replyKey,
        MessageHoverToolbar.overflowKey,
      ]) {
        final centre = tester.getCenter(find.byKey(key).first);
        expect(lower.contains(centre), isFalse, reason: '$key is covered');
      }
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
        harness(hoverRow(message(content: long), grouped: true)),
      );
      final mouse = await hoverMouse(tester);
      await hoverHover(tester, mouse, find.byType(MessageRow));

      final body = tester.getRect(find.textContaining('a long first line'));
      expect(body.right, lessThanOrEqualTo(tester.getRect(hoverPlate).left));
    });

    testWidgets('a toolbar never reaches into the row above', (tester) async {
      await tester.pumpWidget(
        harness(
          ListView(
            children: [
              hoverRow(message(id: 'a', content: 'one')),
              hoverRow(message(id: 'b', content: 'two'), grouped: true),
            ],
          ),
        ),
      );
      final mouse = await hoverMouse(tester);
      await hoverHover(tester, mouse, find.byKey(const ValueKey('b')));

      final above = tester.getRect(find.byKey(const ValueKey('a')));
      expect(tester.getRect(hoverPlate).overlaps(above), isFalse);
    });
  });
}
