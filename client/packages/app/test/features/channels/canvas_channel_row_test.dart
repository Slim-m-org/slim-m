// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas channel's rail row: one line at every rail width, who is viewing, its call beneath, its menu and what a screen reader hears.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

import '../../support/canvas_rail_harness.dart';

void main() {
  for (final (label, width, rail) in [
    ('the 900 rail', 900.0, 240.0),
    ('the 1280 rail', 1280.0, 248.0),
    ('the phone list', 390.0, 390.0),
  ]) {
    group('at $label', () {
      testWidgets('is one line: glyph, then name, then the facepile', (
        tester,
      ) async {
        final r = RailHarness(
          tester,
          RailWire(
            viewers: {
              'c1': ['u-a', 'u-b', 'u-c'],
            },
          ),
        );
        await r.show(
          [canvasChannel('c1', 'review-board')],
          width: width,
          railWidth: rail,
        );

        final row = r.rect(r.row('c1'));
        final glyph = r.rect(find.byIcon(AppIcons.canvas));
        final name = r.rect(find.text('review-board'));
        final first = r.rect(r.avatar('u-a'));
        expect(
          row.height,
          width < 600 ? greaterThanOrEqualTo(44) : lessThanOrEqualTo(38),
        );
        expect(name.height, lessThan(row.height));
        expect(glyph.right, lessThanOrEqualTo(name.left));
        expect(name.right, lessThanOrEqualTo(first.left));
        expect(r.rect(r.avatar('u-c')).right, lessThanOrEqualTo(row.right));
        expect(find.textContaining('+'), findsNothing);
      });

      testWidgets('keeps the facepile whole while a long name truncates', (
        tester,
      ) async {
        final viewers = {
          'c1': ['u-a', 'u-b', 'u-c', 'u-d', 'u-e'],
          'c2': ['u-a', 'u-b', 'u-c', 'u-d', 'u-e'],
        };
        final r = RailHarness(tester, RailWire(viewers: viewers));
        await r.show(
          [
            canvasChannel('c1', 'x'),
            canvasChannel(
              'c2',
              'a-canvas-name-that-is-far-too-long-for-this-rail-at-all',
            ),
          ],
          width: width,
          railWidth: rail,
        );

        double facepileWidth(String id) =>
            find
                .descendant(of: r.row(id), matching: find.text('+2'))
                .evaluate()
                .isEmpty
            ? 0
            : r
                      .rect(
                        find.descendant(
                          of: r.row(id),
                          matching: find.text('+2'),
                        ),
                      )
                      .right -
                  r
                      .rect(
                        find.descendant(
                          of: r.row(id),
                          matching: r.avatar('u-a'),
                        ),
                      )
                      .left;
        expect(facepileWidth('c2'), facepileWidth('c1'));
        expect(facepileWidth('c1'), greaterThan(0));
        final longName = r.rect(
          find.text('a-canvas-name-that-is-far-too-long-for-this-rail-at-all'),
        );
        final plus = r.rect(
          find.descendant(of: r.row('c2'), matching: find.text('+2')),
        );
        expect(
          longName.right,
          lessThanOrEqualTo(
            r
                .rect(
                  find.descendant(of: r.row('c2'), matching: r.avatar('u-a')),
                )
                .left,
          ),
        );
        expect(plus.right, lessThanOrEqualTo(r.rect(r.row('c2')).right));
        expect(r.rect(r.row('c2')).height, r.rect(r.row('c1')).height);
      });

      testWidgets('shows three avatars and "+n" past three', (tester) async {
        final r = RailHarness(
          tester,
          RailWire(
            viewers: {
              'c1': ['u-a', 'u-b', 'u-c', 'u-d', 'u-e'],
            },
          ),
        );
        await r.show(
          [canvasChannel('c1', 'board')],
          width: width,
          railWidth: rail,
        );

        expect(r.avatar('u-c'), findsOneWidget);
        expect(r.avatar('u-d'), findsNothing);
        expect(find.text('+2'), findsOneWidget);
        expect(
          r.rect(find.text('+2')).left,
          greaterThan(r.rect(r.avatar('u-c')).right - 1),
        );
      });
    });
  }

  testWidgets('shows no trailing mark with nobody viewing and no call', (
    tester,
  ) async {
    final r = RailHarness(tester, RailWire());
    await r.show([canvasChannel('c1', 'board')], width: 1280);

    expect(find.text('board'), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);
    expect(find.byKey(const ValueKey('u-a')), findsNothing);
  });

  testWidgets(
    'a live call lists its people beneath and cuts the facepile to two',
    (tester) async {
      final r = RailHarness(
        tester,
        RailWire(
          viewers: {
            'c1': ['u-a', 'u-b', 'u-c', 'u-d', 'u-ann'],
          },
          call: {
            'c1': ['u-ann', 'u-bob'],
          },
        ),
      );
      await r.show([canvasChannel('c1', 'board', call: true)], width: 1280);

      final row = r.rect(r.row('c1'));
      expect(r.avatar('u-a'), findsOneWidget);
      expect(r.avatar('u-b'), findsOneWidget);
      expect(r.avatar('u-c'), findsNothing);
      expect(find.text('+2'), findsOneWidget);
      expect(r.rect(find.text('u-bob')).top, greaterThanOrEqualTo(row.bottom));
      expect(r.rect(find.text('u-ann')).top, greaterThanOrEqualTo(row.bottom));
      expect(
        r.rect(find.text('u-bob')).left,
        greaterThan(r.rect(find.text('board')).left - 1),
      );
    },
  );

  testWidgets(
    'a call nobody is in adds no line, and a passive row asks for no roster',
    (tester) async {
      final r = RailHarness(
        tester,
        RailWire(
          viewers: {
            'c1': ['u-a'],
          },
        ),
      );
      await r.show([
        canvasChannel('c1', 'with-call', call: true),
        canvasChannel('c2', 'no-call'),
      ], width: 1280);

      final first = r.rect(r.row('c1'));
      final second = r.rect(r.row('c2'));
      expect(second.top, closeTo(first.bottom, 0.5));
      expect(r.wire.reads['/channels/c2/voice/roster'], isNull);
      expect(r.wire.reads['/channels/c1/voice/roster'], isNotNull);
    },
  );

  testWidgets('a call with no known start leaves no gap after the facepile', (
    tester,
  ) async {
    final r = RailHarness(
      tester,
      RailWire(
        viewers: {
          'c1': ['u-a'],
          'c2': ['u-b'],
        },
        call: {
          'c1': ['u-bob'],
        },
      ),
    );
    await r.show([
      canvasChannel('c1', 'with-call', call: true),
      canvasChannel('c2', 'no-call'),
    ], width: 1280);

    expect(
      r.rect(r.avatar('u-a')).right,
      closeTo(r.rect(r.avatar('u-b')).right, 0.5),
    );
  });

  testWidgets('many canvas rows read the viewers roster once', (tester) async {
    final r = RailHarness(
      tester,
      RailWire(
        viewers: {
          'c0': ['u-a'],
        },
      ),
    );
    await r.show([
      for (var i = 0; i < 6; i++) canvasChannel('c$i', 'board-$i'),
    ], width: 1280);

    expect(r.wire.reads['/presence/canvas-viewers'], 1);
    expect(
      r.wire.reads.keys.where((p) => p.contains('/voice/roster')),
      isEmpty,
    );
  });

  testWidgets('a mention keeps its dot beside the facepile', (tester) async {
    final r = RailHarness(
      tester,
      RailWire(
        viewers: {
          'c1': ['u-a'],
        },
      ),
    );
    await r.show([
      canvasChannel('c1', 'board', cursor: 5, lastReadSeq: 2, mentionedSeq: 5),
    ], width: 1280);

    final dot = r.rect(find.byKey(AppListRow.mentionDotKey));
    expect(dot.left, greaterThanOrEqualTo(r.rect(r.avatar('u-a')).right));
    expect(dot.right, lessThanOrEqualTo(r.rect(r.row('c1')).right));
  });

  testWidgets(
    'hovering puts the kebab after "+n" without overlapping anything',
    (tester) async {
      final r = RailHarness(
        tester,
        RailWire(
          viewers: {
            'c1': ['u-a', 'u-b', 'u-c', 'u-d', 'u-e'],
          },
        ),
      );
      await r.show(
        [canvasChannel('c1', 'new-designs-MVP-with-a-long-name')],
        width: 1280,
        railWidth: 248,
      );
      final idleLeft = r.rect(r.avatar('u-a')).left;
      await hoverRow(tester, r.row('c1'));

      final kebab = r.rect(
        find.descendant(
          of: r.row('c1'),
          matching: find.byIcon(AppIcons.moreVertical),
        ),
      );
      final plus = r.rect(find.text('+2'));
      final name = r.rect(find.text('new-designs-MVP-with-a-long-name'));
      final first = r.rect(r.avatar('u-a'));
      expect(
        r.rect(r.avatar('u-a')).left,
        lessThan(idleLeft),
        reason: 'the kebab takes its own slot only while hovered',
      );
      expect(kebab.left, greaterThanOrEqualTo(plus.right));
      expect(kebab.right, lessThanOrEqualTo(r.rect(r.row('c1')).right));
      expect(name.right, lessThanOrEqualTo(first.left));
      expect(kebab.overlaps(name), isFalse);
      expect(kebab.overlaps(first), isFalse);
    },
  );

  testWidgets('a tap opens the board and never joins the call', (tester) async {
    final r = RailHarness(
      tester,
      RailWire(
        call: {
          'c1': ['u-bob'],
        },
      ),
    );
    await r.show([canvasChannel('c1', 'board', call: true)], width: 1280);

    await tester.tap(find.text('board'));
    await pumpFrames(tester);

    expect(r.router.state.uri.toString(), '/channels/c1');
    expect(r.voice!.joins, isEmpty);
  });

  testWidgets('the selected board is accented', (tester) async {
    final r = RailHarness(tester, RailWire());
    await r.show([canvasChannel('c1', 'board')], width: 1280, selectedId: 'c1');

    final icon = tester.widget<Icon>(find.byIcon(AppIcons.canvas));
    expect(icon.color, AppTokens.light.accent);
  });
}
