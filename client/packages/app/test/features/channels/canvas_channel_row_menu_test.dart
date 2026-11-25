// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas channel row's menu, and what a screen reader hears for the row.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';

import '../../support/menu_gestures.dart';

import '../../support/canvas_rail_harness.dart';

void main() {
  group('the menu', () {
    const wanted = [
      'Open chat',
      'Mark as read',
      'Notifications',
      'Move to category...',
      'Channel settings',
      'Delete channel...',
    ];

    Future<void> expectMenu(WidgetTester tester, Channel channel) async {
      for (final label in wanted) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Open canvas'), findsNothing);
      expect(find.textContaining('Join'), findsNothing);
      expect(find.text('View details'), findsNothing);
      final tops = [for (final l in wanted) tester.getTopLeft(find.text(l)).dy];
      expect([...tops]..sort(), tops, reason: 'items keep the design order');
    }

    testWidgets('right-click at 1280 opens it', (tester) async {
      final r = RailHarness(
        tester,
        RailWire(
          viewers: {
            'c1': ['u-a'],
          },
        ),
      );
      final channel = canvasChannel('c1', 'board', cursor: 3, mentionedSeq: 3);
      await r.show([channel], width: 1280);
      await rightClickMenu(tester, find.text('board'));
      await expectMenu(tester, channel);
    });

    testWidgets('long-press at 390 opens the same one, with a call too', (
      tester,
    ) async {
      final r = RailHarness(
        tester,
        RailWire(
          call: {
            'c1': ['u-bob'],
          },
        ),
      );
      final channel = canvasChannel(
        'c1',
        'board',
        call: true,
        cursor: 3,
        mentionedSeq: 3,
      );
      await r.show([channel], width: 390);
      await longPressMenu(tester, find.text('board'));
      await expectMenu(tester, channel);
    });

    testWidgets('a voice channel keeps its own menu', (tester) async {
      final r = RailHarness(tester, RailWire());
      await r.show([voiceChannel('v1', 'lounge')], width: 1280);
      await rightClickMenu(tester, find.text('lounge'));
      expect(find.text('View details'), findsOneWidget);
      expect(find.text('Open chat'), findsOneWidget);
    });
  });

  group('what a screen reader hears', () {
    Future<String> label(
      WidgetTester tester,
      RailWire wire, {
      bool call = false,
    }) async {
      final r = RailHarness(tester, wire);
      await r.show([canvasChannel('c1', 'board', call: call)], width: 1280);
      return tester.getSemantics(r.row('c1')).label;
    }

    testWidgets('names the kind alone with nobody viewing', (tester) async {
      expect(await label(tester, RailWire()), 'board, canvas channel');
    });

    testWidgets('counts one viewer', (tester) async {
      expect(
        await label(
          tester,
          RailWire(
            viewers: {
              'c1': ['u-a'],
            },
          ),
        ),
        'board, canvas channel, 1 viewing',
      );
    });

    testWidgets('counts several and the call', (tester) async {
      expect(
        await label(
          tester,
          RailWire(
            viewers: {
              'c1': ['u-a', 'u-b', 'u-c'],
            },
            call: {
              'c1': ['u-bob', 'u-cy'],
            },
          ),
          call: true,
        ),
        'board, canvas channel, 3 viewing, 2 in the call',
      );
    });
  });
}
