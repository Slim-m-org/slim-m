// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone held upright: whether a call's camera bubbles land somewhere the
/// person holding it can actually see.
///
/// The reported symptom was "no portrait mode for voice canvas for mobile
/// people". `CanvasPresenceLayout` arranged every tile in one unbounded row,
/// so five participants spanned roughly 1220 world units - three screens
/// wide on a phone - and portrait showed one bubble with the rest reachable
/// only by panning sideways through empty world, along the axis portrait has
/// least of.
///
/// Asserted on the real, laid-out `RenderBox` of each tile through
/// `support/geometry.dart`, never on whether a tile widget exists: a tile
/// mounted at a world position 800 units off the right edge is present in
/// the tree and invisible on the screen, which is exactly the bug.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile.dart';

import '../../support/geometry.dart';
import '../../visual/canvas_assembled_scene.dart';
import '../../visual/canvas_assembled_snapshot_support.dart';

/// Every mounted tile's own laid-out rect, scoped to the interactive
/// presence layer so the face pile's own copies of the same names - which
/// are screen-anchored chrome, not tiles on the canvas - cannot answer for
/// one.
///
/// Only mounted tiles, deliberately: a bubble culled for sitting far outside
/// the viewport has no rect to read, and "did it mount" is the wrong
/// question anyway. What each assertion below asks is where the ones a
/// person can see actually landed.
List<Rect> _tileRects(WidgetTester tester) {
  final tiles = find.descendant(
    of: find.byType(CanvasPresenceLayer),
    matching: find.byType(CanvasPresenceManipulableTile),
  );
  return tiles
      .evaluate()
      .map((e) => tester.getRect(find.byWidget(e.widget)))
      .toList();
}

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required double height,
}) => renderCanvasAssembledPane(
  tester,
  name: 'unused-portrait-probe',
  width: width,
  height: height,
  theme: 'dark',
  document: buildEmptyDocument(),
  participants: busyParticipants,
);

void main() {
  testWidgets('every camera bubble on a five-person call lands inside a phone held '
      'upright, rather than strung off the right edge', (tester) async {
    await _pump(tester, width: 390, height: 844);

    final rects = _tileRects(tester);
    // The fixture has to genuinely disagree with the wide case below, or this passes at a viewport where one row happened to fit anyway.
    expect(
      rects.length,
      greaterThan(2),
      reason: 'fewer than three visible tiles is not a crowd to arrange',
    );
    final pane = viewportRect(tester);
    for (final rect in rects) {
      expect(
        rect.right,
        lessThanOrEqualTo(pane.right + 0.5),
        reason: 'a bubble past the right edge is one nobody can see',
      );
      expect(rect.left, greaterThanOrEqualTo(pane.left - 0.5));
    }
    // Genuinely more than one row here, against exactly one on the wide pane below: the two viewports have to disagree, or both assertions could be satisfied by an arrangement that never changed at all.
    expect(
      rects.map((r) => r.top).toSet().length,
      greaterThan(1),
      reason: 'portrait must spend the axis it actually has',
    );
  });

  testWidgets(
    'the same roster on a wide pane still sits on one row, so the wrap is '
    'the narrow case answering for itself rather than a new arrangement '
    'everywhere',
    (tester) async {
      await _pump(tester, width: 1400, height: 900);

      final rects = _tileRects(tester);
      expect(rects, hasLength(busyParticipants.length));
      expect(rects.map((r) => r.top).toSet(), hasLength(1));
    },
  );

  /// The same roster over roughly the same pixel count, transposed. A single
  /// viewport cannot tell a wrap that responds to the pane from one that
  /// always looked this way; two that genuinely disagree can.
  testWidgets('a landscape phone wraps into fewer rows than an upright one', (
    tester,
  ) async {
    await _pump(tester, width: 844, height: 390);

    final rows = _tileRects(tester).map((r) => r.top).toSet();

    expect(rows.length, greaterThan(1), reason: 'five tiles do not fit 844');
    expect(
      rows.length,
      lessThan(busyParticipants.length),
      reason: 'a wider pane must fit more than one tile per row',
    );
  });
}
