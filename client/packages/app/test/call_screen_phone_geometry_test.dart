// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner's phone screenshots of a voice call (backlog 2026-10-02, "dock ui
/// on mobile a mess in canvas", "same for non canvas view"), measured on the
/// real shell at two phone sizes rather than described: nothing tappable
/// covers anything else, the dock stays a small part of the screen, and every
/// canvas tool is still on screen at touch size.
///
/// Width alone picks the phone branch (docs/design/desktop-vs-mobile.md, the
/// one rule); nothing here passes a platform.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/bot_call_controls.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';

import 'home_shell_harness.dart' show teardown;
import 'support/call_screen_phone_harness.dart';
import 'support/interactive_rects.dart';

const _phones = {'390x844': Size(390, 844), '360x640': Size(360, 640)};

/// Of the viewport height, all the dock's cards together.
const _maxDockFraction = 0.21;

const _canvasControls = [
  'Pan',
  'Pen',
  'Note',
  'Shape',
  'Eraser',
  'Undo',
  'More canvas actions',
  'Close canvas',
];

const _callControls = [
  'Mute',
  'Turn on camera',
  'Share a screen',
  'Leave call',
];

Rect _rect(WidgetTester tester, String label) =>
    tester.getRect(find.bySemanticsLabel(RegExp('^$label')).first);

void main() {
  for (final entry in _phones.entries) {
    for (final canvas in const [false, true]) {
      final name = '${entry.key} ${canvas ? 'canvas' : 'call'}';

      testWidgets('nothing tappable covers anything else at $name', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final s = await pumpCallScreen(tester, entry.value, canvas: canvas);

        // A call tile on the canvas is content the person moves, not a control.
        final found = tappables(tester);
        bool onCanvas(Tappable t) => t.label.contains("on this call's canvas");
        final all = [
          for (final t in found)
            if (!onCanvas(t)) t,
        ];
        expect(partialOverlaps(all), isEmpty);
        expect(
          textUnderTappables(
            tester,
            all,
            content: [
              for (final t in found)
                if (onCanvas(t)) t.rect,
            ],
          ),
          isEmpty,
        );

        semantics.dispose();
        await teardown(tester, s.container, s.db);
      });

      testWidgets('the dock is a small part of the screen at $name', (
        tester,
      ) async {
        final s = await pumpCallScreen(tester, entry.value, canvas: canvas);

        final cards = [
          for (final c in find.byType(FloatingDockCard).evaluate())
            tester.getRect(find.byWidget(c.widget)),
        ];
        final height = cards.map((r) => r.height).fold(0.0, (a, b) => a + b);
        expect(
          height / entry.value.height,
          lessThanOrEqualTo(_maxDockFraction),
          reason: 'cards $cards',
        );

        await teardown(tester, s.container, s.db);
      });

      testWidgets('every dock control is a 44dp target at $name', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final s = await pumpCallScreen(tester, entry.value, canvas: canvas);

        final names = [
          ..._callControls,
          if (canvas) ..._canvasControls else ...const ['Open canvas'],
          if (!canvas) ...const ['Play or pause', 'Back 30s', 'Stop'],
        ];
        final screen = Offset.zero & entry.value;
        for (final label in names) {
          final rect = _rect(tester, label);
          expect(screen.contains(rect.topLeft), isTrue, reason: label);
          expect(screen.contains(rect.bottomRight), isTrue, reason: label);
          expect(rect.width, greaterThanOrEqualTo(44), reason: '$label wide');
          expect(rect.height, greaterThanOrEqualTo(44), reason: '$label tall');
        }

        semantics.dispose();
        await teardown(tester, s.container, s.db);
      });
    }

    testWidgets(
      'a bot is one row of icon chips with its name at ${entry.key}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final s = await pumpCallScreen(tester, entry.value);

        const labels = ['Play or pause', 'Back 30s', 'Forward 30s', 'Stop'];
        final rects = [for (final l in labels) _rect(tester, l)];
        expect({for (final r in rects) r.top}, hasLength(1), reason: 'one row');
        final label = find.descendant(
          of: find.byType(BotCallControls),
          matching: find.text('Jellyfin'),
        );
        expect(label, findsOneWidget);
        final name = tester.getRect(label);
        expect(
          (name.center.dy - rects.first.center.dy).abs(),
          lessThan(rects.first.height / 2),
          reason: 'the name sits on the same row as the chips',
        );
        expect(find.text('Play or pause'), findsNothing, reason: 'icon only');

        semantics.dispose();
        await teardown(tester, s.container, s.db);
      },
    );
  }
}
