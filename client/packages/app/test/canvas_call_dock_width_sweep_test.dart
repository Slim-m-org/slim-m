// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop canvas dock at every pane width: no control is clipped, scrolled
/// or overlapped, and the row count only grows as the pane narrows. Asserted
/// by rect, with the pen or shape caret out (the widest tool strip).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'package:slimm_app/src/widgets/floating_dock_card.dart';

import 'support/canvas_call_dock_fixtures.dart';

const _controls = [
  'Pan',
  'Pen',
  'Note',
  'Shape',
  'Eraser',
  'Undo',
  'Redo',
  'Mute',
  'Turn on camera',
  'Share a screen',
  'Leave call',
];

Rect _rect(WidgetTester tester, String label) =>
    tester.getRect(find.bySemanticsLabel(RegExp('^$label')).first);

int _rowCount(WidgetTester tester) {
  final tops = <double>[];
  for (final label in _controls) {
    final mid = _rect(tester, label).center.dy;
    if (!tops.any((t) => (t - mid).abs() < 10)) tops.add(mid);
  }
  return tops.length;
}

Future<int> _pumpAt(
  WidgetTester tester,
  double pane,
  CanvasTool tool, {
  bool mustFit = true,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpCanvasCallDock(
    tester,
    withCall: true,
    canvas: buildCanvasDockData(canUndo: true, tool: tool),
    width: pane,
  );
  await tester.pumpAndSettle();
  final card = tester.getRect(find.byType(FloatingDockCard));
  final rects = [for (final c in _controls) _rect(tester, c)];
  for (var i = 0; i < rects.length; i++) {
    expect(
      card.inflate(0.5).contains(rects[i].topLeft) &&
          card.inflate(0.5).contains(rects[i].bottomRight),
      isTrue,
      reason: '${_controls[i]} inside the card at pane $pane ($tool)',
    );
    for (var j = i + 1; j < rects.length; j++) {
      expect(
        rects[i].overlaps(rects[j]),
        isFalse,
        reason: '${_controls[i]} overlaps ${_controls[j]} at pane $pane',
      );
    }
  }
  if (mustFit) {
    for (final s in tester.stateList<ScrollableState>(
      find.byType(Scrollable),
    )) {
      expect(s.position.maxScrollExtent, 0, reason: 'scrolls at pane $pane');
    }
  }
  return _rowCount(tester);
}

void main() {
  for (final tool in [CanvasTool.pen, CanvasTool.shape, CanvasTool.eraser]) {
    testWidgets('nothing clips or scrolls from 360 to 1100 wide ($tool)', (
      tester,
    ) async {
      var previous = 0;
      for (var pane = 1100.0; pane >= 360; pane -= 7) {
        final rows = await _pumpAt(tester, pane, tool);
        expect(rows, inInclusiveRange(1, 3));
        expect(rows, greaterThanOrEqualTo(previous), reason: 'at $pane');
        previous = rows;
      }
    });
  }

  testWidgets('the 795dp pane a 1280 window gets is one row', (tester) async {
    expect(await _pumpAt(tester, 795, CanvasTool.pen), 1);
    expect(tester.getSize(find.byType(FloatingDockCard)).height, lessThan(60));
  });

  testWidgets('a mid-width pane takes two rows, a narrow one three', (
    tester,
  ) async {
    expect(await _pumpAt(tester, 560, CanvasTool.pen), 2);
    expect(await _pumpAt(tester, 400, CanvasTool.pen), 2);
    expect(await _pumpAt(tester, 360, CanvasTool.pen), 3);
  });

  testWidgets('the thresholds sit just above what each layout needs', (
    tester,
  ) async {
    Future<double> hugged(double cap) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      await pumpCanvasCallDock(
        tester,
        withCall: true,
        canvas: buildCanvasDockData(canUndo: true, tool: CanvasTool.pen),
        width: cap,
        hug: true,
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(FloatingDockCard)).width;
    }

    Future<double> switchesAt(int rows, double from) async {
      for (var pane = from; pane < 1000; pane++) {
        if (await _pumpAt(tester, pane, CanvasTool.pen) <= rows) return pane;
      }
      return 1000;
    }

    const headroom = 90.0;
    final oneRow = await hugged(2000);
    expect(
      await switchesAt(1, oneRow - 100),
      inInclusiveRange(oneRow, oneRow + headroom),
    );
    await _pumpAt(tester, 560, CanvasTool.pen);
    final rows = [for (final c in _controls) _rect(tester, c)];
    final left = rows.map((r) => r.left).reduce(math.min);
    final right = rows.map((r) => r.right).reduce(math.max);
    final twoRow = right - left + 26;
    expect(
      await switchesAt(2, 300),
      inInclusiveRange(twoRow, twoRow + headroom),
    );
  });
}
