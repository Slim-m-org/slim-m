// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner's desktop screenshot of a voice call with a Jellyfin share
/// (backlog 2026-10-02 seq 195, "UI for desktop voice call, for streaming and
/// such doesnt look good like mobile"), measured on the real shell at the
/// desktop sizes rather than described: participant tiles are never covered
/// by the stage or the dock, the share keeps its aspect ratio, the dock stays
/// slim, and a bot is one row of icon chips.
///
/// Width alone picks the layout (docs/design/desktop-vs-mobile.md, the one
/// rule); nothing here passes a platform.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/bot_call_controls.dart';
import 'package:slimm_app/src/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_app/src/widgets/screen_share_stage.dart';

import 'home_shell_harness.dart' show teardown;
import 'support/call_screen_phone_harness.dart';
import 'support/interactive_rects.dart';

const _desktops = {
  '1280x800': Size(1280, 800),
  '1600x900': Size(1600, 900),
  '1919x1078': Size(1919, 1078),
  '900x700': Size(900, 700),
};

/// Of the viewport height, all the dock's cards together.
double _maxDockFraction(Size size) => size.height >= 1000 ? 0.12 : 0.16;

List<Rect> _rects(WidgetTester tester, Finder finder) => [
  for (final e in finder.evaluate()) tester.getRect(find.byWidget(e.widget)),
];

void main() {
  for (final entry in _desktops.entries) {
    final size = entry.value;
    for (final share in const [true, false]) {
      final name = '${entry.key} ${share ? 'share' : 'no share'}';

      testWidgets('nothing tappable covers anything else at $name', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final s = await pumpCallScreen(tester, size, share: share);

        final all = tappables(tester);
        expect(partialOverlaps(all), isEmpty);
        expect(textUnderTappables(tester, all), isEmpty);

        semantics.dispose();
        await teardown(tester, s.container, s.db);
      });

      testWidgets('tiles sit clear of the dock and the stage at $name', (
        tester,
      ) async {
        final s = await pumpCallScreen(tester, size, share: share);

        final tiles = _rects(tester, find.byType(CallParticipantTile));
        expect(tiles, hasLength(2));
        final blockers = [
          ..._rects(tester, find.byType(FloatingDockCard)),
          ..._rects(tester, find.byType(ScreenShareStage)),
        ];
        final screen = Offset.zero & size;
        for (final tile in tiles) {
          expect(screen.contains(tile.topLeft), isTrue, reason: '$tile');
          expect(screen.contains(tile.bottomRight), isTrue, reason: '$tile');
          for (final blocker in blockers) {
            final inter = tile.intersect(blocker);
            final overlap = inter.width > 0 && inter.height > 0;
            expect(overlap, isFalse, reason: '$tile is under $blocker');
          }
        }

        await teardown(tester, s.container, s.db);
      });

      testWidgets('the dock is a small part of the screen at $name', (
        tester,
      ) async {
        final s = await pumpCallScreen(tester, size, share: share);

        final cards = _rects(tester, find.byType(FloatingDockCard));
        final height = cards.map((r) => r.height).fold(0.0, (a, b) => a + b);
        expect(
          height / size.height,
          lessThanOrEqualTo(_maxDockFraction(size)),
          reason: 'cards $cards',
        );
        final dock = cards.single;
        expect(
          dock.width,
          lessThan(size.width / 2),
          reason: 'the dock hugs its content',
        );

        await teardown(tester, s.container, s.db);
      });
    }

    testWidgets('the share keeps its aspect ratio and the room at '
        '${entry.key}', (tester) async {
      final s = await pumpCallScreen(tester, size);

      final stage = tester.getRect(find.byType(ScreenShareStage));
      expect(
        (stage.width - stage.height * 16 / 9).abs(),
        lessThanOrEqualTo(1),
        reason: 'stage $stage is 16:9',
      );
      final tile = _rects(tester, find.byType(CallParticipantTile)).first;
      expect(
        stage.bottom,
        lessThanOrEqualTo(tile.top),
        reason: 'the stage sits above the participant strip',
      );
      expect(
        stage.width * stage.height,
        greaterThan(size.width * size.height * 0.12),
        reason: 'the stage is the hero: $stage',
      );

      await teardown(tester, s.container, s.db);
    });

    testWidgets(
      'a bot is one row of icon chips with its name at ${entry.key}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final s = await pumpCallScreen(tester, size);

        const labels = ['Play or pause', 'Back 30s', 'Forward 30s', 'Stop'];
        final rects = [
          for (final l in labels)
            tester.getRect(find.bySemanticsLabel(RegExp('^$l')).first),
        ];
        expect({for (final r in rects) r.top}, hasLength(1), reason: 'one row');
        final label = find.descendant(
          of: find.byType(BotCallControls),
          matching: find.text('Jellyfin'),
        );
        expect(label, findsOneWidget);
        expect(find.text('Play or pause'), findsNothing, reason: 'icon only');

        semantics.dispose();
        await teardown(tester, s.container, s.db);
      },
    );
  }
}
